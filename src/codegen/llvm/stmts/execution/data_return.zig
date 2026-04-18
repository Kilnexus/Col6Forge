const std = @import("std");
const ast = @import("../../../input.zig");
const common = @import("../../codegen/common.zig");
const context = @import("../../codegen/context/mod.zig");
const expr = @import("../../codegen/expression/mod.zig");
const utils = @import("../../codegen/utils.zig");
const llvm_types = @import("../../types.zig");
const assignment_mod = @import("assignment/mod.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

pub fn emitData(ctx: *Context, builder: anytype, data: ast.DataStmt) EmitError!void {
    for (data.inits) |init| {
        if (init.repeat_count > 1) {
            if (try emitRepeatedDataInit(ctx, builder, init)) {
                continue;
            }
        }
        var target_ptr: ValueRef = undefined;
        var target_len: ?usize = null;
        if (init.target.* == .call_or_subscript) {
            const call = init.target.call_or_subscript;
            const sym = ctx.findSymbol(call.name) orelse return error.UnknownSymbol;
            if (sym.isCharacter()) {
                target_len = common.constantCharacterLen(sym) orelse return error.NonConstantCharacterLength;
            }
            if (sym.dims.len > 1 and call.args.len == 1) {
                target_ptr = try expr.emitLinearSubscriptPtr(ctx, builder, call);
            } else {
                target_ptr = try expr.emitLValue(ctx, builder, init.target);
            }
        } else {
            if (assignment_mod.charLenForExpr(ctx, init.target)) |char_len| {
                target_len = char_len;
            }
            target_ptr = try expr.emitLValue(ctx, builder, init.target);
        }
        if (target_len) |char_len| {
            var effective_value_expr = init.value;
            var parameter_string_literal: ast.Expr = undefined;
            if (init.value.* == .identifier) {
                const name = init.value.identifier;
                if (ctx.findSymbol(name)) |sym| {
                    if (sym.kind == .parameter and sym.const_value != null) {
                        switch (sym.const_value.?) {
                            .string => |bytes| {
                                parameter_string_literal = .{
                                    .literal = .{
                                        .kind = .string,
                                        .text = bytes,
                                    },
                                };
                                effective_value_expr = &parameter_string_literal;
                            },
                            else => {},
                        }
                    }
                }
            }
            try assignment_mod.storeCharacterValue(ctx, builder, target_ptr, char_len, effective_value_expr);
            const const_value = try assignment_mod.evalCharConst(ctx, effective_value_expr, char_len);
            assignment_mod.trackCharAssignment(ctx, init.target, const_value);
            continue;
        }
        const value = try expr.emitExpr(ctx, builder, init.value);
        const target_ty = if (assignment_mod.targetExprSymbol(ctx, init.target)) |sym|
            common.symbolStorageIRType(sym, ctx.options.target_layout)
        else
            try expr.exprType(ctx, init.target);
        const coerced = try expr.coerce(ctx, builder, value, target_ty);
        try builder.store(coerced, target_ptr);
    }
}

fn emitRepeatedDataInit(ctx: *Context, builder: anytype, init: ast.DataInit) EmitError!bool {
    if (init.target.* != .identifier) return false;
    const name = init.target.identifier;
    const sym = ctx.findSymbol(name) orelse return error.UnknownSymbol;
    if (sym.dims.len == 0) return false;
    if (sym.isCharacter()) return false;

    const repeat_i64 = std.math.cast(i64, init.repeat_count) orelse return error.DataExpansionTooLarge;
    const count = assignment_mod.constI64(ctx, repeat_i64);
    const base_ptr = ctx.locals.get(name) orelse return error.UnknownSymbol;
    const elem_ty = common.symbolStorageIRType(sym, ctx.options.target_layout);
    const value = try expr.emitExpr(ctx, builder, init.value);
    const coerced = try expr.coerce(ctx, builder, value, elem_ty);
    try assignment_mod.emitLinearFillLoop(ctx, builder, base_ptr, elem_ty, count, coerced);
    return true;
}

pub fn emitReturnStmt(ctx: *Context, builder: anytype, ret: ast.ReturnStmt) EmitError!void {
    if (ret.value) |value| {
        if (ctx.unit.kind == .subroutine) {
            const raw = try expr.emitExpr(ctx, builder, value);
            const coerced = try expr.coerceCheckedI32(ctx, builder, raw);
            try ctx.emitHeapTempFrees(builder);
            try builder.retValue(.i32, coerced.name);
            return;
        }
    }
    try emitDefaultReturn(ctx, builder);
}

pub fn emitDefaultReturn(ctx: *Context, builder: anytype) EmitError!void {
    if (ctx.unit.kind == .function) {
        const return_symbol_name = functionReturnSymbolName(ctx.unit);
        const sym = ctx.findSymbol(return_symbol_name) orelse return error.UnknownSymbol;
        if (sym.isCharacter()) {
            try ctx.emitHeapTempFrees(builder);
            try builder.retVoid();
            return;
        }
        const ret_ty = if (sym.is_pointer) llvm_types.IRType.ptr else ctx.typeFromKind(sym.loweredKind());
        const abi_ret_ty = ctx.abiFunctionReturnType(ret_ty);
        const ret_ptr = ctx.locals.get(return_symbol_name) orelse return error.UnknownSymbol;
        if (sym.dims.len != 0 or ctx.abiUsesHiddenResultPtr(ret_ty)) {
            // Hidden-result ABI returns through the caller-provided pointer; function returns void.
            try emitHiddenArrayResultFinalize(ctx, builder, return_symbol_name, sym, ret_ptr);
            try ctx.emitHeapTempFrees(builder);
            try builder.retVoid();
            return;
        }
        const ret_val: ValueRef = blk: {
            if (std.mem.eql(u8, ret_ptr.name, "null")) break :blk utils.zeroValue(abi_ret_ty);
            if (sym.is_pointer) {
                const tmp = try ctx.nextTemp();
                try builder.load(tmp, .ptr, ret_ptr);
                break :blk .{ .name = tmp, .ty = .ptr, .is_ptr = false };
            }
            if (sym.loweredKind() == .logical) {
                const storage_ty = common.symbolStorageIRType(sym, ctx.options.target_layout);
                break :blk try expr.loadValue(ctx, builder, ret_ptr, storage_ty);
            }
            break :blk try expr.loadValue(ctx, builder, ret_ptr, ret_ty);
        };
        if (ret_ty == .complex_f32 and (ctx.abiReturnType(ret_ty) == .i64 or ctx.abiReturnType(ret_ty) == .v2f32)) {
            // ABI boundary returns COMPLEX*8 using a target-specific packed form.
            const complex_abi_ret_ty = ctx.abiReturnType(ret_ty);
            const pack_slot = try ctx.nextTemp();
            // Use the ABI return type for the spill slot so vector-return targets
            // keep the stronger alignment they require.
            try builder.alloca(pack_slot, complex_abi_ret_ty);
            const pack_ptr = ValueRef{ .name = pack_slot, .ty = .ptr, .is_ptr = true };
            try builder.store(ret_val, pack_ptr);
            const packed_tmp = try ctx.nextTemp();
            try builder.load(packed_tmp, complex_abi_ret_ty, pack_ptr);
            try ctx.emitHeapTempFrees(builder);
            try builder.retValue(complex_abi_ret_ty, packed_tmp);
            return;
        }
        try ctx.emitHeapTempFrees(builder);
        try builder.retValue(abi_ret_ty, ret_val.name);
        return;
    }
    if (ctx.unit.kind == .subroutine and unitHasAltReturn(ctx.unit)) {
        try ctx.emitHeapTempFrees(builder);
        try builder.retValue(.i32, "0");
        return;
    }
    try ctx.emitHeapTempFrees(builder);
    try builder.retVoid();
}

fn functionReturnSymbolName(unit: ast.ProgramUnit) []const u8 {
    if (unit.kind != .function) return unit.name;
    if (unit.result_name) |name| return name;
    return unit.name;
}

fn emitHiddenArrayResultFinalize(
    ctx: *Context,
    builder: anytype,
    return_symbol_name: []const u8,
    sym: ast.sema.Symbol,
    ret_ptr: ValueRef,
) EmitError!void {
    const hidden = ctx.hidden_result_array_abi orelse return;
    if (sym.dims.len == 0) return;
    if (hidden.rank != sym.dims.len) return error.InvalidAbiState;

    const result_data_ptr = if (sym.is_pointer) blk: {
        const loaded_name = try ctx.nextTemp();
        try builder.load(loaded_name, .ptr, ret_ptr);
        break :blk ValueRef{ .name = loaded_name, .ty = .ptr, .is_ptr = false };
    } else ret_ptr;
    try builder.store(result_data_ptr, hidden.slot_ptr);

    const desc = ctx.runtimeArrayDescriptor(return_symbol_name) orelse return error.InvalidAbiState;
    for (0..desc.rank) |idx| {
        const offset = try ctx.constI64(@intCast(idx));

        const extent_name = try ctx.nextTemp();
        try builder.load(extent_name, .i64, desc.extent_slots[idx]);
        const extent_ptr_name = try ctx.nextTemp();
        try builder.gep(extent_ptr_name, .i64, hidden.extent_base, offset);
        try builder.store(.{ .name = extent_name, .ty = .i64, .is_ptr = false }, .{ .name = extent_ptr_name, .ty = .ptr, .is_ptr = true });

        const multiplier_name = try ctx.nextTemp();
        try builder.load(multiplier_name, .i64, desc.multiplier_slots[idx]);
        const multiplier_ptr_name = try ctx.nextTemp();
        try builder.gep(multiplier_ptr_name, .i64, hidden.multiplier_base, offset);
        try builder.store(.{ .name = multiplier_name, .ty = .i64, .is_ptr = false }, .{ .name = multiplier_ptr_name, .ty = .ptr, .is_ptr = true });
    }
}

pub fn unitHasAltReturn(unit: ast.ProgramUnit) bool {
    if (unit.alt_return_dummy_count != 0) return true;
    for (unit.stmts) |stmt| {
        if (stmtHasAltReturn(stmt)) return true;
    }
    return false;
}

fn stmtHasAltReturn(stmt: ast.Stmt) bool {
    return stmtNodeHasAltReturn(stmt.node);
}

fn stmtNodeHasAltReturn(node: ast.StmtNode) bool {
    switch (node) {
        .ret => return node.ret.value != null,
        .if_single => |ifs| return stmtNodeHasAltReturn(ifs.stmt.*),
        .if_block => |ifb| {
            for (ifb.then_stmts) |inner| {
                if (stmtHasAltReturn(inner)) return true;
            }
            for (ifb.else_stmts) |inner| {
                if (stmtHasAltReturn(inner)) return true;
            }
            return false;
        },
        else => return false,
    }
}
