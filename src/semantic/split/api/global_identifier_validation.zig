const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common_diag = @import("../../../common/diagnostic.zig");
const catalog = @import("../../../common/error_catalog.zig");
const diagnostic = @import("../../diagnostic.zig");
const procedure_call_diagnostics = @import("../../analysis/check_statements/procedure_call_diagnostics.zig");

const ProcedureEntity = struct {
    source: ast.DeclSource,
    owner_name: ?[]const u8,
    kind: ast.ProgramUnitKind,
    name: []const u8,
    bind_name: ?[]const u8,
};

pub fn validateProgram(
    arena: std.mem.Allocator,
    program: ast.Program,
    diag_bag: *diagnostic.Bag,
) !void {
    var procedures = std.array_list.Managed(ProcedureEntity).init(arena);
    defer procedures.deinit();

    for (program.units) |unit| {
        if (procedureEntity(unit)) |entity| {
            try procedures.append(entity);
        }
    }
    if (procedures.items.len < 2) return;

    const first_conflicts = try arena.alloc(?usize, procedures.items.len);
    @memset(first_conflicts, null);

    for (procedures.items, 0..) |current, i| {
        var j: usize = i + 1;
        while (j < procedures.items.len) : (j += 1) {
            const other = procedures.items[j];
            if (!sameGlobalIdentifier(current, other)) continue;
            if (first_conflicts[i] == null) first_conflicts[i] = j;
            if (first_conflicts[j] == null) first_conflicts[j] = i;
        }
    }

    var saw_conflict = false;
    for (procedures.items, 0..) |current, i| {
        const other_idx = first_conflicts[i] orelse continue;
        saw_conflict = true;
        emitProcedureConflictDiagnostic(diag_bag, arena, current, procedures.items[other_idx]);
    }
    if (saw_conflict) return error.DuplicateDeclaration;
}

fn procedureEntity(unit: ast.ProgramUnit) ?ProcedureEntity {
    if (unit.kind != .function and unit.kind != .subroutine) return null;
    if (unit.owner_name != null and unit.bind_name == null) return null;
    return .{
        .source = unit.source,
        .owner_name = unit.owner_name,
        .kind = unit.kind,
        .name = unit.name,
        .bind_name = unit.bind_name,
    };
}

fn sameGlobalIdentifier(a: ProcedureEntity, b: ProcedureEntity) bool {
    const a_name = a.bind_name orelse a.name;
    const b_name = b.bind_name orelse b.name;
    return std.ascii.eqlIgnoreCase(a_name, b_name);
}

fn emitProcedureConflictDiagnostic(
    diag_bag: *diagnostic.Bag,
    arena: std.mem.Allocator,
    current: ProcedureEntity,
    other: ProcedureEntity,
) void {
    const current_source = current.source;
    const other_source = other.source;
    const line = if (current_source.line == 0) 1 else current_source.line;
    const column = if (current_source.column == 0) 1 else current_source.column;
    const secondary = [_]common_diag.DiagnosticSpan{
        procedure_call_diagnostics.diagnosticSpanFromSource(other_source, "conflicting entity here"),
    };
    const message = conflictMessage(arena, current, other) catch return;

    diag_bag.setStructured(
        line,
        column,
        catalog.semantic.duplicate_declaration.code,
        message,
        current_source.text,
        "conflicting global identifier here",
        &.{.{ .text = "Two externally visible procedures lower to the same global identifier." }},
        &.{.{ .text = "Rename one procedure, or give one BIND(C) procedure a distinct NAME= binding label." }},
        secondary[0..],
    );
}

fn conflictMessage(
    arena: std.mem.Allocator,
    current: ProcedureEntity,
    other: ProcedureEntity,
) ![]const u8 {
    const current_kind = procedureKindName(other.kind);
    if (current.bind_name) |bind_name| {
        if (current.owner_name != null) {
            const proc_name = try lowerDup(arena, current.name);
            const bind_lower = try lowerDup(arena, bind_name);
            return std.fmt.allocPrint(
                arena,
                "Procedure '{s}' with binding label '{s}' at .1. uses the same global identifier as entity at .2.",
                .{ proc_name, bind_lower },
            );
        }
        const bind_lower = try lowerDup(arena, bind_name);
        return std.fmt.allocPrint(
            arena,
            "Global binding name '{s}' at .1. is already being used as a {s} at .2.",
            .{ bind_lower, current_kind },
        );
    }

    const global_name = try lowerDup(arena, current.name);
    return std.fmt.allocPrint(
        arena,
        "Global name '{s}' at .1. is already being used as a {s} at .2.",
        .{ global_name, current_kind },
    );
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
