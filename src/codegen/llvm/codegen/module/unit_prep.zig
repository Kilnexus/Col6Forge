const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const input = @import("../../../input.zig");
const context = @import("../context/mod.zig");
const utils = @import("../utils.zig");
const function_type = @import("../../../../semantic/split/function_type.zig");
const procedure_inference = @import("../../../../semantic/split/api/procedure_inference.zig");

const Program = input.Program;

pub const PreludeState = struct {
    program_mangled: ?[]const u8 = null,
    block_data_mangled: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) PreludeState {
        return .{ .block_data_mangled = std.array_list.Managed([]const u8).init(allocator) };
    }

    pub fn deinit(self: *PreludeState) void {
        self.block_data_mangled.deinit();
    }
};

pub fn collectPreludeState(
    scratch: std.mem.Allocator,
    program: Program,
    option_sigs: []const input.sema.KnownProcedureSig,
    defined: *std.StringHashMap(void),
    known_procedure_sigs: *context.CaseInsensitiveStringHashMap(input.sema.KnownProcedureSig),
) !PreludeState {
    var state = PreludeState.init(scratch);
    errdefer state.deinit();

    for (option_sigs) |sig| {
        try known_procedure_sigs.put(sig.name, sig);
    }
    for (program.units) |unit| {
        try installExplicitInterfaceProcedureSigs(scratch, known_procedure_sigs, unit);
        try installProcedureDeclaratorAliases(scratch, known_procedure_sigs, unit);
        if (unit.kind == .module) continue;
        const mangled = try utils.mangleProcedureUnitName(scratch, unit);
        try defined.put(mangled, {});
        switch (unit.kind) {
            .module => unreachable,
            .program => {
                if (state.program_mangled != null) return error.MultipleProgramUnits;
                state.program_mangled = mangled;
            },
            .block_data => {
                try state.block_data_mangled.append(mangled);
            },
            .function, .subroutine => {
                const sig: input.sema.KnownProcedureSig = .{
                    .name = unit.name,
                    .kind = unit.kind,
                    .arg_count = unit.args.len,
                    .alt_return_count = unit.alt_return_dummy_count,
                    .args = try input.sema.inferProcedureArgSigs(scratch, unit),
                    .pure = unit.pure,
                    .elemental = unit.elemental,
                    .is_pointer = function_type.inferProcedureIsPointer(unit),
                    .result_rank = if (unit.kind == .function) function_type.inferFunctionResultRank(unit) else 0,
                    .result_type_spec = if (unit.kind == .function) function_type.inferFunctionTypeSpec(unit) else null,
                    .result_shape_signature = if (unit.kind == .function) try function_type.inferFunctionResultShapeSignature(scratch, unit) else &.{},
                    .result_allocatable = if (unit.kind == .function) function_type.inferFunctionResultAllocatable(unit) else false,
                    .result_contiguous = if (unit.kind == .function) function_type.inferFunctionResultContiguous(unit) else false,
                    .result_procedure_pointer = if (unit.kind == .function) function_type.inferFunctionResultIsProcedurePointer(unit) else false,
                    .actual_requires_explicit_interface = unit.owner_name != null,
                };
                try known_procedure_sigs.put(unit.name, sig);
                if (unit.owner_name) |owner_name| {
                    const qualified = try std.fmt.allocPrint(scratch, "{s}::{s}", .{ owner_name, unit.name });
                    try known_procedure_sigs.put(qualified, sig);
                }
            },
        }
    }

    return state;
}

pub fn prepareCodegenUnitWithOwnerDecls(
    arena: std.mem.Allocator,
    program: Program,
    unit: input.ProgramUnit,
) !input.ProgramUnit {
    const owner_name = unit.owner_name orelse return unit;
    if (unit.owner_kind != .procedure) return unit;
    const owner_unit = findOwnerUnit(program, owner_name) orelse return unit;
    if (owner_unit.decls.len == 0) return unit;

    var combined_decls = std.array_list.Managed(input.Decl).init(arena);
    try combined_decls.appendSlice(owner_unit.decls);
    try combined_decls.appendSlice(unit.decls);

    var combined_sources = std.array_list.Managed(ast.DeclSource).init(arena);
    try combined_sources.appendSlice(owner_unit.decl_sources);
    try combined_sources.appendSlice(unit.decl_sources);

    var prepared = unit;
    prepared.decls = try combined_decls.toOwnedSlice();
    prepared.decl_sources = try combined_sources.toOwnedSlice();
    return prepared;
}

fn installExplicitInterfaceProcedureSigs(
    arena: std.mem.Allocator,
    known_procedure_sigs: *context.CaseInsensitiveStringHashMap(input.sema.KnownProcedureSig),
    unit: input.ProgramUnit,
) !void {
    for (unit.decls) |decl| {
        if (decl != .interface_block) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            const sig: input.sema.KnownProcedureSig = .{
                .name = proc_header.name,
                .kind = proc_header.kind,
                .arg_count = proc_header.args.len,
                .alt_return_count = proc_header.alt_return_dummy_count,
                .args = try procedure_inference.inferInterfaceProcedureArgSigs(arena, unit, proc_header),
                .pure = proc_header.pure,
                .elemental = proc_header.elemental,
                .is_pointer = if (proc_header.kind == .function)
                    procedure_inference.interfaceProcedureResultAttrs(proc_header).pointer
                else
                    false,
                .result_rank = input.sema.interfaceProcedureResultRank(proc_header),
                .result_type_spec = if (proc_header.kind == .function)
                    procedure_inference.interfaceProcedureResultTypeSpec(unit, proc_header)
                else
                    null,
                .result_shape_signature = if (proc_header.kind == .function)
                    try procedure_inference.interfaceProcedureResultShapeSignature(arena, proc_header)
                else
                    &.{},
                .result_allocatable = if (proc_header.kind == .function)
                    procedure_inference.interfaceProcedureResultAttrs(proc_header).allocatable
                else
                    false,
                .result_contiguous = if (proc_header.kind == .function)
                    procedure_inference.interfaceProcedureResultAttrs(proc_header).contiguous
                else
                    false,
                .result_procedure_pointer = if (proc_header.kind == .function)
                    procedure_inference.interfaceProcedureResultAttrs(proc_header).procedure_pointer
                else
                    false,
            };
            try known_procedure_sigs.put(proc_header.name, sig);
            const qualified = try std.fmt.allocPrint(arena, "{s}::{s}", .{ unit.name, proc_header.name });
            try known_procedure_sigs.put(qualified, sig);
        }
    }
}

fn installProcedureDeclaratorAliases(
    arena: std.mem.Allocator,
    known_procedure_sigs: *context.CaseInsensitiveStringHashMap(input.sema.KnownProcedureSig),
    unit: input.ProgramUnit,
) !void {
    for (unit.decls) |decl| {
        if (decl != .procedure) continue;
        const iface_name = switch (decl.procedure.interface) {
            .name => |name| name,
            else => continue,
        };
        const sig = lookupUnitScopedKnownProcedureSig(known_procedure_sigs, unit, iface_name) orelse continue;
        for (decl.procedure.items) |item| {
            var alias_sig = sig;
            alias_sig.name = item.name;
            const qualified = try std.fmt.allocPrint(arena, "{s}::{s}", .{ unit.name, item.name });
            try known_procedure_sigs.put(qualified, alias_sig);
        }
    }
}

fn lookupUnitScopedKnownProcedureSig(
    known_procedure_sigs: *const context.CaseInsensitiveStringHashMap(input.sema.KnownProcedureSig),
    unit: input.ProgramUnit,
    name: []const u8,
) ?input.sema.KnownProcedureSig {
    var key_buf: [256]u8 = undefined;
    if (std.fmt.bufPrint(&key_buf, "{s}::{s}", .{ unit.name, name })) |qualified| {
        if (known_procedure_sigs.get(qualified)) |sig| return sig;
    } else |_| {}
    if (unit.owner_name) |owner_name| {
        if (std.fmt.bufPrint(&key_buf, "{s}::{s}", .{ owner_name, name })) |qualified| {
            if (known_procedure_sigs.get(qualified)) |sig| return sig;
        } else |_| {}
    }
    return known_procedure_sigs.get(name);
}

fn findOwnerUnit(program: Program, owner_name: []const u8) ?input.ProgramUnit {
    for (program.units) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate.name, owner_name) and candidate.kind != .module) {
            return candidate;
        }
    }
    return null;
}
