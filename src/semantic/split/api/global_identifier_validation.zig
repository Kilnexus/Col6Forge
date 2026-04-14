const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common_diag = @import("../../../common/diagnostic.zig");
const catalog = @import("../../../common/error_catalog.zig");
const diagnostic = @import("../../diagnostic.zig");
const procedure_call_diagnostics = @import("../../analysis/check_statements/procedure_call_diagnostics.zig");
const literals = @import("../../evaluator/literals.zig");

const EntityKind = enum {
    module_unit,
    procedure,
    variable,
};

const GlobalEntity = struct {
    source: ast.DeclSource,
    owner_name: ?[]const u8 = null,
    kind: EntityKind,
    unit_kind: ?ast.ProgramUnitKind = null,
    name: []const u8,
    bind_label: ?[]const u8 = null,
    interface_header: bool = false,
};

pub fn validateProgram(
    arena: std.mem.Allocator,
    program: ast.Program,
    diag_bag: *diagnostic.Bag,
) !void {
    var entities = std.array_list.Managed(GlobalEntity).init(arena);
    defer entities.deinit();

    for (program.units) |unit| {
        try appendUnitEntities(arena, &entities, unit);
    }
    if (entities.items.len < 2) return;

    const first_conflicts = try arena.alloc(?usize, entities.items.len);
    @memset(first_conflicts, null);
    var failed_modules = std.StringHashMap(void).init(arena);

    for (entities.items, 0..) |current, i| {
        var j: usize = i + 1;
        while (j < entities.items.len) : (j += 1) {
            const other = entities.items[j];
            if (!sameGlobalIdentifier(current, other)) continue;
            if (first_conflicts[i] == null) first_conflicts[i] = j;
            if (first_conflicts[j] == null) first_conflicts[j] = i;
            if (current.owner_name != null and other.owner_name != null and !std.ascii.eqlIgnoreCase(current.owner_name.?, other.owner_name.?)) {
                try failed_modules.put(other.owner_name.?, {});
            }
        }
    }

    var saw_conflict = false;
    for (entities.items, 0..) |current, i| {
        const other_idx = first_conflicts[i] orelse continue;
        saw_conflict = true;
        emitConflictDiagnostic(diag_bag, arena, current, entities.items[other_idx]);
    }
    if (failed_modules.count() != 0) {
        emitFailedModuleUseDiagnostics(diag_bag, program, &failed_modules);
    }
    if (saw_conflict) return error.DuplicateDeclaration;
}

fn emitFailedModuleUseDiagnostics(
    diag_bag: *diagnostic.Bag,
    program: ast.Program,
    failed_modules: *const std.StringHashMap(void),
) void {
    for (program.units) |unit| {
        for (unit.use_imports) |use_stmt| {
            if (!failed_modules.contains(use_stmt.module_name)) continue;
            const source = use_stmt.source;
            diag_bag.set(
                if (source.line == 0) 1 else source.line,
                if (source.column == 0) 1 else source.column,
                catalog.semantic.duplicate_declaration.code,
                "Cannot open module file",
                source.text,
            );
        }
        for (unit.stmts) |stmt_node| {
            if (stmt_node.node != .use_stmt) continue;
            const use_stmt = stmt_node.node.use_stmt;
            if (!failed_modules.contains(use_stmt.module_name)) continue;
            diag_bag.set(
                if (stmt_node.source_line == 0) 1 else stmt_node.source_line,
                if (stmt_node.source_column == 0) 1 else stmt_node.source_column,
                catalog.semantic.duplicate_declaration.code,
                "Cannot open module file",
                stmt_node.source_text,
            );
        }
    }
}

fn appendUnitEntities(
    arena: std.mem.Allocator,
    entities: *std.array_list.Managed(GlobalEntity),
    unit: ast.ProgramUnit,
) !void {
    _ = arena;
    if (unit.kind == .module) {
        try entities.append(.{
            .source = unit.source,
            .kind = .module_unit,
            .unit_kind = .module,
            .name = unit.name,
            .bind_label = null,
        });
    }

    if (procedureEntity(unit)) |entity| {
        try entities.append(entity);
    }

    for (unit.decls, 0..) |decl, decl_idx| {
        const decl_source = if (decl_idx < unit.decl_sources.len) unit.decl_sources[decl_idx] else ast.DeclSource{};
        switch (decl) {
            .type_decl => |type_decl| {
                if (!type_decl.bind_c) continue;
                if (type_decl.bind_name_expr != null and type_decl.items.len != 1) continue;
                for (type_decl.items) |item| {
                    const bind_label = bindingLabelFromExpr(type_decl.bind_name_expr) orelse item.name;
                    try entities.append(.{
                        .source = decl_source,
                        .owner_name = if (unit.kind == .module) unit.name else null,
                        .kind = .variable,
                        .unit_kind = unit.kind,
                        .name = item.name,
                        .bind_label = bind_label,
                    });
                }
            },
            .bind_entity => |bind_entity_decl| {
                if (bind_entity_decl.bind_name_expr != null and bind_entity_decl.names.len != 1) continue;
                for (bind_entity_decl.names) |name| {
                    const bind_label = bindingLabelFromExpr(bind_entity_decl.bind_name_expr) orelse name;
                    try entities.append(.{
                        .source = decl_source,
                        .owner_name = if (unit.kind == .module) unit.name else null,
                        .kind = .variable,
                        .unit_kind = unit.kind,
                        .name = name,
                        .bind_label = bind_label,
                    });
                }
            },
            .interface_block => |interface_block| {
                for (interface_block.procedure_headers) |proc_header| {
                    if (!proc_header.bind_c and proc_header.bind_name == null) continue;
                    try entities.append(.{
                        .source = proc_header.source,
                        .owner_name = unit.name,
                        .kind = .procedure,
                        .unit_kind = proc_header.kind,
                        .name = proc_header.name,
                        .bind_label = proc_header.bind_name orelse proc_header.name,
                        .interface_header = true,
                    });
                }
            },
            else => {},
        }
    }
}

fn procedureEntity(unit: ast.ProgramUnit) ?GlobalEntity {
    if (unit.kind != .function and unit.kind != .subroutine) return null;
    if (unit.owner_name != null and !unit.bind_c and unit.bind_name == null) return null;
    return .{
        .source = unit.source,
        .owner_name = unit.owner_name,
        .kind = .procedure,
        .unit_kind = unit.kind,
        .name = unit.name,
        .bind_label = if (unit.bind_c or unit.bind_name != null or unit.owner_name != null) (unit.bind_name orelse unit.name) else null,
    };
}

fn bindingLabelFromExpr(expr: ?*ast.Expr) ?[]const u8 {
    const node = expr orelse return null;
    return switch (node.*) {
        .literal => |lit| switch (lit.kind) {
            .string, .hollerith => literals.decodeLiteralBytes(lit, null) catch null,
            else => null,
        },
        .binary => |bin| blk: {
            if (bin.op != .concat) break :blk null;
            const left = bindingLabelFromExpr(bin.left) orelse break :blk null;
            const right = bindingLabelFromExpr(bin.right) orelse break :blk null;
            break :blk std.mem.concat(std.heap.page_allocator, u8, &.{ left, right }) catch null;
        },
        else => null,
    };
}

fn sameGlobalIdentifier(a: GlobalEntity, b: GlobalEntity) bool {
    if (a.interface_header and b.interface_header and a.unit_kind == b.unit_kind) return false;
    const a_name = a.bind_label orelse a.name;
    const b_name = b.bind_label orelse b.name;
    return std.ascii.eqlIgnoreCase(a_name, b_name);
}

fn emitConflictDiagnostic(
    diag_bag: *diagnostic.Bag,
    arena: std.mem.Allocator,
    current: GlobalEntity,
    other: GlobalEntity,
) void {
    const subject = preferredSubject(current, other);
    const current_source = current.source;
    const other_source = other.source;
    const line = if (current_source.line == 0) 1 else current_source.line;
    const column = if (current_source.column == 0) 1 else current_source.column;
    const secondary = [_]common_diag.DiagnosticSpan{
        procedure_call_diagnostics.diagnosticSpanFromSource(other_source, "conflicting entity here"),
    };
    const message = conflictMessage(arena, subject, other) catch return;

    diag_bag.setStructured(
        line,
        column,
        catalog.semantic.duplicate_declaration.code,
        message,
        current_source.text,
        "conflicting global identifier here",
        &.{.{ .text = "Two externally visible entities lower to the same global identifier." }},
        &.{.{ .text = "Rename one entity, or give one BIND(C) entity a distinct NAME= binding label." }},
        secondary[0..],
    );
}

fn preferredSubject(a: GlobalEntity, b: GlobalEntity) GlobalEntity {
    if (a.kind == .variable and b.kind == .variable) return b;
    if (a.kind == .variable and b.kind == .procedure and sameOwner(a, b)) return a;
    if (b.kind == .variable and a.kind == .procedure and sameOwner(a, b)) return b;
    if (a.kind == .procedure and a.owner_name != null) return a;
    if (b.kind == .procedure and b.owner_name != null) return b;
    if (a.bind_label != null and b.bind_label == null) return a;
    if (b.bind_label != null and a.bind_label == null) return b;
    return a;
}

fn sameOwner(a: GlobalEntity, b: GlobalEntity) bool {
    if (a.owner_name == null or b.owner_name == null) return false;
    return std.ascii.eqlIgnoreCase(a.owner_name.?, b.owner_name.?);
}

fn conflictMessage(
    arena: std.mem.Allocator,
    subject: GlobalEntity,
    other: GlobalEntity,
) ![]const u8 {
    switch (subject.kind) {
        .variable => {
            const var_name = try lowerDup(arena, subject.name);
            const bind_label = try lowerDup(arena, subject.bind_label orelse subject.name);
            if (subject.owner_name != null and other.kind == .variable and other.owner_name != null) {
                const owner_name = try lowerDup(arena, subject.owner_name.?);
                const other_owner = try lowerDup(arena, other.owner_name.?);
                return std.fmt.allocPrint(
                    arena,
                    "Variable '{s}' from module '{s}' with binding label '{s}' at .1. uses the same global identifier as entity at .2. from module '{s}'",
                    .{ var_name, owner_name, bind_label, other_owner },
                );
            }
            return std.fmt.allocPrint(
                arena,
                "Variable '{s}' with binding label '{s}' at .1. uses the same global identifier as entity at .2.",
                .{ var_name, bind_label },
            );
        },
        .procedure => {
            const proc_name = try lowerDup(arena, subject.name);
            if (subject.owner_name != null) {
                const bind_label = try lowerDup(arena, subject.bind_label orelse subject.name);
                return std.fmt.allocPrint(
                    arena,
                    "Procedure '{s}' with binding label '{s}' at .1. uses the same global identifier as entity at .2.",
                    .{ proc_name, bind_label },
                );
            }
            if (subject.bind_label) |bind_label| {
                const bind_lower = try lowerDup(arena, bind_label);
                return std.fmt.allocPrint(
                    arena,
                    "Global binding name '{s}' at .1. is already being used as a {s} at .2.",
                    .{ bind_lower, procedureKindName(other.unit_kind orelse .subroutine) },
                );
            }
            return std.fmt.allocPrint(
                arena,
                "Global name '{s}' at .1. is already being used as a {s} at .2.",
                .{ proc_name, procedureKindName(other.unit_kind orelse .subroutine) },
            );
        },
        .module_unit => {
            const label = try lowerDup(arena, subject.name);
            return std.fmt.allocPrint(
                arena,
                "Global name '{s}' at .1. is already being used at .2.",
                .{label},
            );
        },
    }
}

fn procedureKindName(kind: ast.ProgramUnitKind) []const u8 {
    return switch (kind) {
        .function => "FUNCTION",
        .subroutine => "SUBROUTINE",
        else => "PROCEDURE",
    };
}

fn lowerDup(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    for (text, 0..) |ch, idx| out[idx] = std.ascii.toLower(ch);
    return out;
}
