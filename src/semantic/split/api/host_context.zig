const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../../context.zig");
const symbols = @import("../../symbol/mod.zig");
const symbol_lookup = @import("../symbol_lookup.zig");

pub fn refreshHostContextFromAnalyzer(
    known_host_symbols: *std.StringHashMap(symbols.Symbol),
    known_host_derived_types: *std.StringHashMap(context.Context.DerivedTypeInfo),
    known_host_interface_sources: *std.StringHashMap(ast.DeclSource),
    known_host_abstract_interfaces: *std.StringHashMap(void),
    arena: std.mem.Allocator,
    host_symbols: []const symbols.Symbol,
    derived_types: *const std.StringHashMap(context.Context.DerivedTypeInfo),
    unit: ast.ProgramUnit,
) !void {
    known_host_symbols.clearRetainingCapacity();
    known_host_derived_types.clearRetainingCapacity();
    known_host_interface_sources.clearRetainingCapacity();
    known_host_abstract_interfaces.clearRetainingCapacity();
    try symbol_lookup.collectHostSymbols(known_host_symbols, arena, host_symbols, derived_types);
    try collectHostDerivedTypes(known_host_derived_types, arena, derived_types);
    try collectHostExplicitInterfaceSources(known_host_interface_sources, arena, unit);
    try collectHostAbstractInterfaceProcedures(known_host_abstract_interfaces, arena, unit);
}

fn collectHostDerivedTypes(
    out: *std.StringHashMap(context.Context.DerivedTypeInfo),
    arena: std.mem.Allocator,
    source: *const std.StringHashMap(context.Context.DerivedTypeInfo),
) !void {
    var it = source.iterator();
    while (it.next()) |entry| {
        const key = try symbol_lookup.lowerDup(arena, entry.key_ptr.*);
        try out.put(key, entry.value_ptr.*);
    }
}

fn collectHostExplicitInterfaceSources(
    out: *std.StringHashMap(ast.DeclSource),
    arena: std.mem.Allocator,
    unit: ast.ProgramUnit,
) !void {
    for (unit.decls, 0..) |decl, decl_idx| {
        if (decl != .interface_block) continue;
        const decl_source = if (decl_idx < unit.decl_sources.len) unit.decl_sources[decl_idx] else continue;
        for (decl.interface_block.specific_procedures, 0..) |procedure_name, idx| {
            const key = try symbol_lookup.lowerDup(arena, try std.fmt.allocPrint(arena, "generic_specific::{s}", .{procedure_name}));
            const source = if (idx < decl.interface_block.specific_procedure_sources.len)
                decl.interface_block.specific_procedure_sources[idx]
            else
                decl_source;
            try out.put(key, source);
        }
        for (decl.interface_block.module_procedures, 0..) |procedure_name, idx| {
            const key = try symbol_lookup.lowerDup(arena, try std.fmt.allocPrint(arena, "generic_specific::{s}", .{procedure_name}));
            const source = if (idx < decl.interface_block.module_procedure_sources.len)
                decl.interface_block.module_procedure_sources[idx]
            else
                decl_source;
            try out.put(key, source);
        }
        for (decl.interface_block.procedures) |procedure_name| {
            const key = try symbol_lookup.lowerDup(arena, procedure_name);
            try out.put(key, decl_source);
        }
        for (decl.interface_block.procedure_headers) |proc_header| {
            const key = try symbol_lookup.lowerDup(arena, proc_header.name);
            try out.put(key, decl_source);
        }
    }
}

fn collectHostAbstractInterfaceProcedures(
    out: *std.StringHashMap(void),
    arena: std.mem.Allocator,
    unit: ast.ProgramUnit,
) !void {
    for (unit.decls) |decl| {
        if (decl != .interface_block) continue;
        if (!decl.interface_block.abstract) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            const key = try symbol_lookup.lowerDup(arena, proc_header.name);
            try out.put(key, {});
        }
    }
}
