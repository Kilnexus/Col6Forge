const std = @import("std");
const ast = @import("../../../ast/nodes.zig");

const Program = ast.Program;
const ProgramUnit = ast.ProgramUnit;

pub fn expandEntries(arena: std.mem.Allocator, program: Program) !Program {
    var units = std.array_list.Managed(ProgramUnit).init(arena);
    for (program.units) |unit| {
        if (unit.kind != .subroutine and unit.kind != .function) {
            try units.append(unit);
            continue;
        }

        var first_entry_idx: ?usize = null;
        for (unit.stmts, 0..) |stmt_item, idx| {
            if (stmt_item.node == .entry) {
                first_entry_idx = idx;
                break;
            }
        }

        if (first_entry_idx != null) {
            const synthetic_entry_iface = try makeVisibleSiblingEntryInterface(arena, unit, unit.name);
            const primary_decls = if (synthetic_entry_iface) |iface|
                try prependDecl(arena, unit.decls, .{ .interface_block = iface })
            else
                unit.decls;
            const primary_decl_sources = if (synthetic_entry_iface != null)
                try prependDeclSource(arena, unit.decl_sources, .{})
            else
                unit.decl_sources;
            try units.append(.{
                .kind = unit.kind,
                .name = unit.name,
                .source = unit.source,
                .owner_name = unit.owner_name,
                .owner_kind = unit.owner_kind,
                .is_module_procedure = unit.is_module_procedure,
                .pure = unit.pure,
                .elemental = unit.elemental,
                .recursive = unit.recursive,
                .prelude_decl_count = unit.prelude_decl_count + @as(usize, if (synthetic_entry_iface != null) 1 else 0),
                .bind_name = unit.bind_name,
                .result_name = unit.result_name,
                .args = unit.args,
                .alt_return_dummy_count = unit.alt_return_dummy_count,
                .decls = primary_decls,
                .decl_sources = primary_decl_sources,
                .stmts = try nonEntryStatementsFrom(arena, unit.stmts, 0),
                .expr_sources = unit.expr_sources,
            });
        } else {
            try units.append(unit);
        }

        for (unit.stmts, 0..) |stmt_item, idx| {
            if (stmt_item.node != .entry) continue;
            const entry = stmt_item.node.entry;
            const synthetic_entry_iface = try makeVisibleSiblingEntryInterface(arena, unit, entry.name);
            const entry_decls = if (synthetic_entry_iface) |iface|
                try prependDecl(arena, unit.decls, .{ .interface_block = iface })
            else
                unit.decls;
            const entry_decl_sources = if (synthetic_entry_iface != null)
                try prependDeclSource(arena, unit.decl_sources, .{})
            else
                unit.decl_sources;

            try units.append(.{
                .kind = unit.kind,
                .name = entry.name,
                .source = .{
                    .line = stmt_item.source_line,
                    .column = stmt_item.source_column,
                    .text = stmt_item.source_text,
                },
                .owner_name = unit.owner_name,
                .owner_kind = unit.owner_kind,
                .is_module_procedure = unit.is_module_procedure,
                .pure = unit.pure,
                .elemental = unit.elemental,
                .recursive = unit.recursive,
                .prelude_decl_count = unit.prelude_decl_count + @as(usize, if (synthetic_entry_iface != null) 1 else 0),
                .bind_name = unit.bind_name,
                .result_name = entry.result_name,
                .args = entry.args,
                .alt_return_dummy_count = entry.alt_return_dummy_count,
                .decls = entry_decls,
                .decl_sources = entry_decl_sources,
                .stmts = try nonEntryStatementsFrom(arena, unit.stmts, idx + 1),
                .expr_sources = unit.expr_sources,
            });
        }
    }
    return .{ .units = try units.toOwnedSlice() };
}

fn makeVisibleSiblingEntryInterface(
    arena: std.mem.Allocator,
    unit: ProgramUnit,
    current_name: []const u8,
) !?ast.InterfaceBlock {
    var headers = std.array_list.Managed(ast.InterfaceProcedure).init(arena);

    if (!std.ascii.eqlIgnoreCase(unit.name, current_name)) {
        try headers.append(.{
            .kind = unit.kind,
            .name = unit.name,
            .pure = unit.pure,
            .elemental = unit.elemental,
            .recursive = unit.recursive,
            .bind_name = unit.bind_name,
            .result_name = unit.result_name,
            .args = unit.args,
            .alt_return_dummy_count = unit.alt_return_dummy_count,
        });
    }
    for (unit.stmts) |stmt_item| {
        if (stmt_item.node != .entry) continue;
        const entry = stmt_item.node.entry;
        if (std.ascii.eqlIgnoreCase(entry.name, current_name)) continue;
        try headers.append(.{
            .kind = unit.kind,
            .name = entry.name,
            .pure = unit.pure,
            .elemental = unit.elemental,
            .recursive = unit.recursive,
            .bind_name = unit.bind_name,
            .result_name = entry.result_name,
            .args = entry.args,
            .alt_return_dummy_count = entry.alt_return_dummy_count,
        });
    }
    if (headers.items.len == 0) return null;
    return .{
        .procedure_headers = try headers.toOwnedSlice(),
    };
}

fn prependDecl(arena: std.mem.Allocator, decls: []const ast.Decl, first: ast.Decl) ![]ast.Decl {
    const out = try arena.alloc(ast.Decl, decls.len + 1);
    out[0] = first;
    @memcpy(out[1..], decls);
    return out;
}

fn prependDeclSource(arena: std.mem.Allocator, decl_sources: []const ast.DeclSource, first: ast.DeclSource) ![]ast.DeclSource {
    const out = try arena.alloc(ast.DeclSource, decl_sources.len + 1);
    out[0] = first;
    @memcpy(out[1..], decl_sources);
    return out;
}

fn nonEntryStatementsFrom(
    arena: std.mem.Allocator,
    stmts: []const ast.Stmt,
    start_idx: usize,
) ![]ast.Stmt {
    var out = std.array_list.Managed(ast.Stmt).init(arena);
    var skipping_entry_private_prefix = false;
    var idx = start_idx;
    while (idx < stmts.len) : (idx += 1) {
        const stmt = stmts[idx];
        if (stmt.node == .entry) {
            skipping_entry_private_prefix = true;
            continue;
        }
        if (skipping_entry_private_prefix) {
            if (stmt.label == null) continue;
            skipping_entry_private_prefix = false;
        }
        try out.append(stmt);
    }
    return out.toOwnedSlice();
}
