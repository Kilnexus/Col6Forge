const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const intrinsics = @import("../../analysis/intrinsics.zig");
const context = @import("../../context.zig");
const symbols = @import("../../symbol/mod.zig");
const symbol_lookup = @import("../symbol_lookup.zig");
const infer = @import("procedure_inference.zig");

pub fn installSingleTargetGenericInterfaces(
    arena: std.mem.Allocator,
    program: ast.Program,
    known_function_type_specs: *std.StringHashMap(symbols.TypeSpec),
    known_procedure_sigs: *std.StringHashMap(context.Context.ProcedureSig),
) !void {
    for (program.units) |unit| {
        for (unit.decls) |decl| {
            if (decl != .interface_block) continue;
            const interface_block = decl.interface_block;
            const generic_name = interface_block.name orelse continue;
            if (intrinsics.isIntrinsicName(generic_name)) continue;
            const target_name = singleTargetInterfaceProcedureName(interface_block) orelse continue;

            const proc_sig = lookupCaseInsensitiveOrQualifiedSuffix(
                context.Context.ProcedureSig,
                known_procedure_sigs,
                target_name,
            ) orelse continue;
            const proc_key = try symbol_lookup.lowerDup(arena, generic_name);
            try known_procedure_sigs.put(proc_key, proc_sig);

            if (proc_sig.kind != .function) continue;
            const type_spec = lookupCaseInsensitiveOrQualifiedSuffix(
                symbols.TypeSpec,
                known_function_type_specs,
                target_name,
            ) orelse continue;
            const type_key = try symbol_lookup.lowerDup(arena, generic_name);
            try known_function_type_specs.put(type_key, type_spec);
        }
    }
}

pub fn installExplicitInterfaceProcedures(
    arena: std.mem.Allocator,
    program: ast.Program,
    known_function_type_specs: *std.StringHashMap(symbols.TypeSpec),
    known_procedure_sigs: *std.StringHashMap(context.Context.ProcedureSig),
) !void {
    for (program.units) |unit| {
        for (unit.decls) |decl| {
            if (decl != .interface_block) continue;
            for (decl.interface_block.procedure_headers) |proc_header| {
                // Parser-generated sibling ENTRY visibility shims carry no source
                // location and must not overwrite the real known procedure sig.
                if (proc_header.source.line == 0 and
                    lookupCaseInsensitive(context.Context.ProcedureSig, known_procedure_sigs, proc_header.name) != null)
                {
                    continue;
                }
                if (lookupCaseInsensitive(context.Context.ProcedureSig, known_procedure_sigs, proc_header.name)) |existing_sig| {
                    if (existing_sig.definition_known_from_current_program) {
                        continue;
                    }
                }
                const proc_sig: context.Context.ProcedureSig = .{
                    .kind = proc_header.kind,
                    .arg_count = proc_header.args.len,
                    .alt_return_count = proc_header.alt_return_dummy_count,
                    .args = try infer.inferInterfaceProcedureArgSigs(arena, unit, proc_header),
                    .pure = proc_header.pure,
                    .elemental = proc_header.elemental,
                    .is_pointer = if (proc_header.kind == .function) infer.interfaceProcedureResultAttrs(proc_header).pointer else false,
                    .result_rank = infer.interfaceProcedureResultRank(proc_header),
                    .result_type_spec = if (proc_header.kind == .function) infer.interfaceProcedureResultTypeSpec(unit, proc_header) else null,
                    .result_shape_signature = if (proc_header.kind == .function) try infer.interfaceProcedureResultShapeSignature(arena, proc_header) else &.{},
                    .result_allocatable = if (proc_header.kind == .function) infer.interfaceProcedureResultAttrs(proc_header).allocatable else false,
                    .result_contiguous = if (proc_header.kind == .function) infer.interfaceProcedureResultAttrs(proc_header).contiguous else false,
                    .result_procedure_pointer = if (proc_header.kind == .function) infer.interfaceProcedureResultAttrs(proc_header).procedure_pointer else false,
                };
                const proc_key = try symbol_lookup.lowerDup(arena, proc_header.name);
                try known_procedure_sigs.put(proc_key, proc_sig);
                const owner_name = unit.owner_name orelse unit.name;
                const qualified_proc_key = try std.fmt.allocPrint(arena, "{s}::{s}", .{ owner_name, proc_header.name });
                try known_procedure_sigs.put(qualified_proc_key, proc_sig);
                if (proc_header.kind != .function) continue;
                const result_type = infer.interfaceProcedureResultTypeSpec(unit, proc_header) orelse continue;
                const type_key = try symbol_lookup.lowerDup(arena, proc_header.name);
                try known_function_type_specs.put(type_key, result_type);
                const qualified_type_key = try std.fmt.allocPrint(arena, "{s}::{s}", .{ owner_name, proc_header.name });
                try known_function_type_specs.put(qualified_type_key, result_type);
            }
        }
    }
}

fn singleTargetInterfaceProcedureName(interface_block: ast.InterfaceBlock) ?[]const u8 {
    const module_count = interface_block.module_procedures.len;
    const specific_count = interface_block.specific_procedures.len;
    const procedure_count = interface_block.procedures.len;
    const total = module_count + specific_count + procedure_count;
    if (total != 1) return null;
    if (module_count == 1) return interface_block.module_procedures[0];
    if (specific_count == 1) return interface_block.specific_procedures[0];
    return interface_block.procedures[0];
}

fn lookupCaseInsensitive(
    comptime T: type,
    map: *const std.StringHashMap(T),
    name: []const u8,
) ?T {
    var key_buf: [64]u8 = undefined;
    if (name.len <= key_buf.len) {
        for (name, 0..) |ch, i| key_buf[i] = std.ascii.toLower(ch);
        return map.get(key_buf[0..name.len]);
    }
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*.len != name.len) continue;
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn lookupCaseInsensitiveOrQualifiedSuffix(
    comptime T: type,
    map: *const std.StringHashMap(T),
    name: []const u8,
) ?T {
    if (lookupCaseInsensitive(T, map, name)) |exact| return exact;

    var match: ?T = null;
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const sep = std.mem.lastIndexOf(u8, key, "::") orelse continue;
        if (!std.ascii.eqlIgnoreCase(key[sep + 2 ..], name)) continue;
        if (match != null) return null;
        match = entry.value_ptr.*;
    }
    return match;
}
