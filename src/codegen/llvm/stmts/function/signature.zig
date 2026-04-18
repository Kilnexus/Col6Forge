const std = @import("std");
const ast = @import("../../../input.zig");
const llvm_types = @import("../../types.zig");
const context = @import("../../codegen/context/mod.zig");
const expression = @import("../../codegen/expression/mod.zig");
const execution = @import("../execution/mod.zig");
const utils = @import("../../codegen/utils.zig");
const locals_mod = @import("locals.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

pub const SignatureInfo = struct {
    return_symbol_name: []const u8,
    unit_has_contains: bool,
    uses_explicit_result_name: bool,
    has_alt_return: bool,
    return_ty: ?llvm_types.IRType,
    uses_hidden_result_ptr: bool,
    is_character_function: bool,
    is_complex_sret_function: bool,
    is_array_result_function: bool,
    uses_dynamic_array_result_abi: bool,
    func_name: []const u8,
};

pub fn analyze(ctx: *Context) EmitError!SignatureInfo {
    const return_symbol_name = functionReturnSymbolName(ctx.unit);
    const unit_has_contains = unitHasContains(ctx.unit);
    const uses_explicit_result_name = ctx.unit.kind == .function and
        !std.ascii.eqlIgnoreCase(return_symbol_name, ctx.unit.name);

    const func_name = utils.mangleProcedureUnitName(ctx.allocator, ctx.unit) catch return error.OutOfMemory;
    const has_alt_return = ctx.unit.kind == .subroutine and execution.unitHasAltReturn(ctx.unit);

    var return_ty: ?llvm_types.IRType = null;
    var is_character_function = false;
    var is_complex_sret_function = false;
    var is_array_result_function = false;
    var uses_dynamic_array_result_abi = false;
    var uses_hidden_result_ptr = false;
    if (ctx.unit.kind == .function) {
        const sym = ctx.findSymbol(return_symbol_name) orelse return error.UnknownSymbol;
        is_character_function = sym.isCharacter();
        is_array_result_function = sym.dims.len != 0;
        uses_dynamic_array_result_abi = is_array_result_function and (sym.is_pointer or sym.is_allocatable);
        is_complex_sret_function = ctx.abiUsesHiddenResultPtr(ctx.typeFromKind(sym.loweredKind()));
        uses_hidden_result_ptr = is_character_function or is_complex_sret_function or is_array_result_function;
        if (!uses_hidden_result_ptr) {
            const nominal_ret_ty = if (sym.is_pointer) llvm_types.IRType.ptr else ctx.typeFromKind(sym.loweredKind());
            return_ty = ctx.abiFunctionReturnType(nominal_ret_ty);
        }
    } else if (has_alt_return) {
        return_ty = .i32;
    }

    return .{
        .return_symbol_name = return_symbol_name,
        .unit_has_contains = unit_has_contains,
        .uses_explicit_result_name = uses_explicit_result_name,
        .has_alt_return = has_alt_return,
        .return_ty = return_ty,
        .uses_hidden_result_ptr = uses_hidden_result_ptr,
        .is_character_function = is_character_function,
        .is_complex_sret_function = is_complex_sret_function,
        .is_array_result_function = is_array_result_function,
        .uses_dynamic_array_result_abi = uses_dynamic_array_result_abi,
        .func_name = func_name,
    };
}

pub fn emit(ctx: *Context, builder: anytype, info: SignatureInfo) EmitError!void {
    if (info.return_ty) |ret_ty| {
        try builder.defineStartWithRet(ret_ty, info.func_name);
    } else {
        try builder.defineStart(info.func_name);
    }

    var ptr_arg_names = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer ptr_arg_names.deinit();
    var char_dummy_names = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer char_dummy_names.deinit();
    var descriptor_dummy_names = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer descriptor_dummy_names.deinit();
    var descriptor_extent_args = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer descriptor_extent_args.deinit();
    var descriptor_multiplier_args = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer descriptor_multiplier_args.deinit();
    var result_descriptor_extent_arg: ?[]const u8 = null;
    var result_descriptor_multiplier_arg: ?[]const u8 = null;
    var char_dummy_len_args = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer char_dummy_len_args.deinit();

    var result_len_arg_name: ?[]const u8 = null;
    const has_hidden_result_arg = info.uses_hidden_result_ptr;

    var next_arg_index: usize = 0;
    if (has_hidden_result_arg) {
        const result_arg_name = try utils.formatTempName(ctx.allocator, "arg", next_arg_index);
        try builder.defineArgPtr(result_arg_name, next_arg_index == 0);
        try ptr_arg_names.append(result_arg_name);
        next_arg_index += 1;
        if (info.uses_dynamic_array_result_abi) {
            const extent_name = try utils.formatTempName(ctx.allocator, "arg", next_arg_index);
            try builder.defineArgPtr(extent_name, next_arg_index == 0);
            result_descriptor_extent_arg = extent_name;
            next_arg_index += 1;

            const multiplier_name = try utils.formatTempName(ctx.allocator, "arg", next_arg_index);
            try builder.defineArgPtr(multiplier_name, next_arg_index == 0);
            result_descriptor_multiplier_arg = multiplier_name;
            next_arg_index += 1;
        }
    }

    for (ctx.unit.args, 0..) |_, idx| {
        const arg_name = try utils.formatTempName(ctx.allocator, "arg", next_arg_index);
        try builder.defineArgPtr(arg_name, next_arg_index == 0);
        try ptr_arg_names.append(arg_name);
        const formal_name = ctx.unit.args[idx];
        if (ctx.findSymbol(formal_name)) |sym| {
            if (sym.storage == .dummy and sym.isCharacter()) {
                try char_dummy_names.append(formal_name);
            }
            if (sym.storage == .dummy and locals_mod.symbolHasDeferredDims(sym)) {
                try descriptor_dummy_names.append(formal_name);
            }
        }
        next_arg_index += 1;
    }

    for (descriptor_dummy_names.items) |_| {
        const extent_name = try utils.formatTempName(ctx.allocator, "arg", next_arg_index);
        try builder.defineArgPtr(extent_name, next_arg_index == 0);
        try descriptor_extent_args.append(extent_name);
        next_arg_index += 1;

        const multiplier_name = try utils.formatTempName(ctx.allocator, "arg", next_arg_index);
        try builder.defineArgPtr(multiplier_name, next_arg_index == 0);
        try descriptor_multiplier_args.append(multiplier_name);
        next_arg_index += 1;
    }

    const abi_char_len_ty = ctx.abiCharacterLenType();
    if (info.is_character_function) {
        const arg_name = try utils.formatTempName(ctx.allocator, "arg", next_arg_index);
        try builder.defineArg(abi_char_len_ty, arg_name, next_arg_index == 0);
        result_len_arg_name = arg_name;
        next_arg_index += 1;
    }

    for (char_dummy_names.items) |_| {
        const arg_name = try utils.formatTempName(ctx.allocator, "arg", next_arg_index);
        try builder.defineArg(abi_char_len_ty, arg_name, next_arg_index == 0);
        try char_dummy_len_args.append(arg_name);
        next_arg_index += 1;
    }

    try builder.defineEnd();
    try builder.entryLabel();

    if (has_hidden_result_arg) {
        const result_ptr_name = ptr_arg_names.items[0];
        const result_ptr = ValueRef{ .name = result_ptr_name, .ty = .ptr, .is_ptr = true };
        if (info.uses_dynamic_array_result_abi) {
            const sym = ctx.findSymbol(info.return_symbol_name) orelse return error.UnknownSymbol;
            const extent_name = result_descriptor_extent_arg orelse return error.InvalidAbiState;
            const multiplier_name = result_descriptor_multiplier_arg orelse return error.InvalidAbiState;
            ctx.hidden_result_array_abi = .{
                .slot_ptr = result_ptr,
                .extent_base = .{ .name = extent_name, .ty = .ptr, .is_ptr = true },
                .multiplier_base = .{ .name = multiplier_name, .ty = .ptr, .is_ptr = true },
                .rank = sym.dims.len,
            };

            if (sym.is_pointer) {
                const slot_name = try ctx.nextTemp();
                try builder.alloca(slot_name, .ptr);
                const local_slot = ValueRef{ .name = slot_name, .ty = .ptr, .is_ptr = true };
                try builder.store(.{ .name = "null", .ty = .ptr, .is_ptr = false }, local_slot);
                try ctx.locals.put(info.return_symbol_name, local_slot);
                if (!std.ascii.eqlIgnoreCase(info.return_symbol_name, ctx.unit.name)) {
                    try ctx.locals.put(ctx.unit.name, local_slot);
                }
            } else {
                const local_ptr = ValueRef{ .name = "null", .ty = .ptr, .is_ptr = true };
                try ctx.locals.put(info.return_symbol_name, local_ptr);
                if (!std.ascii.eqlIgnoreCase(info.return_symbol_name, ctx.unit.name)) {
                    try ctx.locals.put(ctx.unit.name, local_ptr);
                }
            }
            try locals_mod.installDeferredArrayDescriptorForSymbol(ctx, builder, sym);
        } else {
            try ctx.locals.put(info.return_symbol_name, result_ptr);
            if (!std.ascii.eqlIgnoreCase(info.return_symbol_name, ctx.unit.name)) {
                try ctx.locals.put(ctx.unit.name, result_ptr);
            }
        }
    }

    if (result_len_arg_name) |len_name| {
        var len_ref = ValueRef{ .name = len_name, .ty = abi_char_len_ty, .is_ptr = false };
        if (abi_char_len_ty != .i32) {
            len_ref = try expression.coerce(ctx, builder, len_ref, .i32);
        }
        try ctx.char_arg_lens.put(info.return_symbol_name, len_ref);
        if (!std.ascii.eqlIgnoreCase(info.return_symbol_name, ctx.unit.name)) {
            try ctx.char_arg_lens.put(ctx.unit.name, len_ref);
        }
    }

    for (char_dummy_names.items, 0..) |formal_name, idx| {
        const len_name = char_dummy_len_args.items[idx];
        var len_ref = ValueRef{ .name = len_name, .ty = abi_char_len_ty, .is_ptr = false };
        if (abi_char_len_ty != .i32) {
            len_ref = try expression.coerce(ctx, builder, len_ref, .i32);
        }
        try ctx.char_arg_lens.put(formal_name, len_ref);
    }

    const ptr_arg_offset: usize = if (has_hidden_result_arg) 1 else 0;
    for (ctx.unit.args, 0..) |arg, idx| {
        const arg_name = ptr_arg_names.items[idx + ptr_arg_offset];
        try ctx.locals.put(arg, .{ .name = arg_name, .ty = .ptr, .is_ptr = true });
    }

    for (descriptor_dummy_names.items, 0..) |formal_name, idx| {
        const sym = ctx.findSymbol(formal_name) orelse return error.UnknownSymbol;
        try locals_mod.installIncomingArrayDescriptor(
            ctx,
            builder,
            sym,
            .{ .name = descriptor_extent_args.items[idx], .ty = .ptr, .is_ptr = true },
            .{ .name = descriptor_multiplier_args.items[idx], .ty = .ptr, .is_ptr = true },
        );
    }
}

fn functionReturnSymbolName(unit: ast.ProgramUnit) []const u8 {
    if (unit.kind != .function) return unit.name;
    if (unit.result_name) |name| return name;
    return unit.name;
}

fn unitHasContains(unit: ast.ProgramUnit) bool {
    for (unit.stmts) |stmt| {
        if (stmt.node != .cont) continue;
        const text = std.mem.trim(u8, stmt.source_text, " \t");
        if (std.ascii.eqlIgnoreCase(text, "contains")) return true;
    }
    return false;
}
