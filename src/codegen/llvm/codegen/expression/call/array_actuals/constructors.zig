const std = @import("std");
const ast = @import("../../../../../input.zig");
const memory = @import("../../memory.zig");
const dispatch = @import("../../dispatch/mod.zig");
const casting = @import("../../casting.zig");
const flatten_mod = @import("../../../../stmts/execution/assignment/flatten/mod.zig");
const io_utils = @import("../../../../stmts/io/utils.zig");
const character_buffers = @import("../../../../shared/character_buffers.zig");
const shared = @import("../shared.zig");
const support = @import("../array_actuals_support.zig");

const Context = shared.Context;
const Expr = shared.Expr;
const IRType = shared.IRType;
const ValueRef = shared.ValueRef;
const ArrayActualPlan = shared.ArrayActualPlan;

pub fn analyzeRuntimeGeneratedArrayConstructorActual(
    ctx: *Context,
    builder: anytype,
    ctor: ast.ArrayConstructor,
) !?ArrayActualPlan {
    if (ctor.items.len != 1) return null;
    if (ctor.items[0].* != .implied_do) return null;
    const implied = ctor.items[0].implied_do;
    if (implied.items.len != 1) return null;
    if (!flatten_mod.isRuntimeWholeArrayImpliedDo(ctx, implied)) return null;

    const item_expr = implied.items[0];
    const elem_ty = try casting.exprType(ctx, item_expr);
    if (elem_ty == .ptr or elem_ty == .void or elem_ty == .i8 or elem_ty == .v2f32) return null;

    var loop_count = try io_utils.emitImpliedFinalCount(ctx, builder, implied.start, implied.end, implied.step);
    if (loop_count.ty != .i64) loop_count = try casting.coerce(ctx, builder, loop_count, .i64);
    const dst_ptr = try support.emitHeapArrayTempPointer(ctx, builder, elem_ty, loop_count);

    const iter_sym = ctx.findSymbol(implied.var_name) orelse return null;
    const iter_ptr = try ctx.getPointer(implied.var_name);
    const iter_ty = ctx.typeFromKind(iter_sym.loweredKind());

    var start_val = try dispatch.emitExpr(ctx, builder, implied.start);
    if (start_val.ty != iter_ty) start_val = try casting.coerce(ctx, builder, start_val, iter_ty);
    var step_val = if (implied.step) |step_expr|
        try dispatch.emitExpr(ctx, builder, step_expr)
    else
        support.i64Const(ctx, 1);
    if (step_val.ty != iter_ty) step_val = try casting.coerce(ctx, builder, step_val, iter_ty);

    const iter_saved_ptr_name = try ctx.nextTemp();
    try builder.alloca(iter_saved_ptr_name, iter_ty);
    const iter_saved_ptr = ValueRef{ .name = iter_saved_ptr_name, .ty = .ptr, .is_ptr = true };
    const iter_saved_name = try ctx.nextTemp();
    try builder.load(iter_saved_name, iter_ty, iter_ptr);
    try builder.store(.{ .name = iter_saved_name, .ty = iter_ty, .is_ptr = false }, iter_saved_ptr);

    const idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(idx_ptr_name, .i64);
    const idx_ptr = ValueRef{ .name = idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(support.i64Const(ctx, 0), idx_ptr);
    try builder.store(start_val, iter_ptr);

    const loop_head = try ctx.nextLabel("ctor_runtime_head");
    const loop_body = try ctx.nextLabel("ctor_runtime_body");
    const loop_exit = try ctx.nextLabel("ctor_runtime_exit");
    try builder.br(loop_head);

    try builder.label(loop_head);
    const idx_name = try ctx.nextTemp();
    try builder.load(idx_name, .i64, idx_ptr);
    const idx_val = ValueRef{ .name = idx_name, .ty = .i64, .is_ptr = false };
    const cond_name = try ctx.nextTemp();
    try builder.compare(cond_name, "icmp", "slt", .i64, idx_val, loop_count);
    try builder.brCond(.{ .name = cond_name, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    const elem_ptr_name = try ctx.nextTemp();
    try builder.gep(elem_ptr_name, elem_ty, dst_ptr, idx_val);
    var value = try dispatch.emitExpr(ctx, builder, item_expr);
    if (value.ty != elem_ty) value = try casting.coerce(ctx, builder, value, elem_ty);
    try builder.store(value, .{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true });

    const cur_iter_name = try ctx.nextTemp();
    try builder.load(cur_iter_name, iter_ty, iter_ptr);
    const next_iter_name = try ctx.nextTemp();
    try builder.binary(next_iter_name, "add", iter_ty, .{ .name = cur_iter_name, .ty = iter_ty, .is_ptr = false }, step_val);
    try builder.store(.{ .name = next_iter_name, .ty = iter_ty, .is_ptr = false }, iter_ptr);

    const next_idx_name = try ctx.nextTemp();
    try builder.binary(next_idx_name, "add", .i64, idx_val, support.i64Const(ctx, 1));
    try builder.store(.{ .name = next_idx_name, .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_head);

    try builder.label(loop_exit);
    const restore_name = try ctx.nextTemp();
    try builder.load(restore_name, iter_ty, iter_saved_ptr);
    try builder.store(.{ .name = restore_name, .ty = iter_ty, .is_ptr = false }, iter_ptr);

    const extents = try ctx.allocator.alloc(ValueRef, 1);
    extents[0] = loop_count;
    const multipliers = try ctx.allocator.alloc(ValueRef, 1);
    multipliers[0] = support.i64Const(ctx, 1);
    return .{
        .base_ptr = dst_ptr,
        .elem_ty = elem_ty,
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = support.i64Const(ctx, 1),
        .storage = .materialized_temp,
        .owned_heap_ptr = dst_ptr,
        .contiguous = true,
    };
}

pub fn analyzeStaticZeroSizedArrayConstructorActual(
    ctx: *Context,
    builder: anytype,
    ctor: ast.ArrayConstructor,
) anyerror!?ArrayActualPlan {
    const elem_count = staticArrayConstructorCount(ctor) orelse return null;
    if (elem_count != 0) return null;

    const elem_info = arrayConstructorElementInfo(ctx, ctor) orelse return null;
    const buf_name = try ctx.nextTemp();
    switch (elem_info.elem_ty) {
        .i8 => try builder.alloca(buf_name, .i8),
        else => try builder.alloca(buf_name, elem_info.elem_ty),
    }
    const extents = try ctx.allocator.alloc(ValueRef, 1);
    extents[0] = support.i64Const(ctx, 0);
    const multipliers = try ctx.allocator.alloc(ValueRef, 1);
    multipliers[0] = support.i64Const(ctx, 1);
    return .{
        .base_ptr = .{ .name = buf_name, .ty = .ptr, .is_ptr = true },
        .elem_ty = elem_info.elem_ty,
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = elem_info.address_scale,
        .storage = .materialized_temp,
        .contiguous = false,
    };
}

pub fn analyzeStaticMaterializedArrayConstructorActual(
    ctx: *Context,
    builder: anytype,
    ctor: ast.ArrayConstructor,
) anyerror!?ArrayActualPlan {
    const elem_count = staticArrayConstructorCount(ctor) orelse return null;
    if (elem_count == 0) return null;
    if (!arrayConstructorHasOnlyScalarItems(ctor)) return null;

    const elem_info = arrayConstructorElementInfo(ctx, ctor) orelse return null;
    if (elem_info.elem_ty == .i8 and elem_count == 1) return null;
    const base_ptr = try support.emitHeapArrayTempPointerScaled(
        ctx,
        builder,
        elem_info.elem_ty,
        support.i64Const(ctx, @intCast(elem_count)),
        elem_info.address_scale,
    );

    for (ctor.items, 0..) |item, idx| {
        if (elem_info.elem_ty == .i8) {
            const dst_ptr = try character_buffers.emitContiguousCharacterElementPtr(
                ctx,
                builder,
                base_ptr,
                elem_info.address_scale,
                support.i64Const(ctx, @intCast(idx)),
            );
            const plan = (try dispatch.emitCharacterValuePlan(ctx, builder, item)) orelse return null;
            var src_len = plan.logical_len;
            if (src_len.ty != .i64) src_len = try casting.coerce(ctx, builder, src_len, .i64);
            try character_buffers.emitCopyCharacterBytesPadded(ctx, builder, dst_ptr, elem_info.address_scale, plan.ptr, src_len);
        } else {
            const value = try dispatch.emitExpr(ctx, builder, item);
            const coerced = try casting.coerce(ctx, builder, value, elem_info.elem_ty);
            const elem_ptr_name = try ctx.nextTemp();
            try builder.gep(elem_ptr_name, elem_info.elem_ty, base_ptr, support.i64Const(ctx, @intCast(idx)));
            try builder.store(coerced, .{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true });
        }
    }

    const extents = try ctx.allocator.alloc(ValueRef, 1);
    extents[0] = support.i64Const(ctx, @intCast(elem_count));
    const multipliers = try ctx.allocator.alloc(ValueRef, 1);
    multipliers[0] = support.i64Const(ctx, 1);
    return .{
        .base_ptr = base_ptr,
        .elem_ty = elem_info.elem_ty,
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = elem_info.address_scale,
        .storage = .materialized_temp,
        .owned_heap_ptr = base_ptr,
        .contiguous = true,
    };
}

pub fn emitSymbolDimExtents(ctx: *Context, builder: anytype, sym: ast.sema.Symbol) ![]ValueRef {
    const extents = try ctx.allocator.alloc(ValueRef, sym.dims.len);
    for (sym.dims, 0..) |dim, idx| {
        extents[idx] = memory.emitSymbolDimExtent(ctx, builder, sym, idx) catch |err| switch (err) {
            error.UnknownSymbol => memory.emitDimValue(ctx, builder, dim) catch |inner| switch (inner) {
                error.UnknownSymbol => support.i64Const(ctx, 1),
                else => return inner,
            },
            else => return err,
        };
        if (extents[idx].ty != .i64) {
            extents[idx] = try casting.coerce(ctx, builder, extents[idx], .i64);
        }
    }
    return extents;
}

pub fn emitSymbolDimMultipliers(ctx: *Context, builder: anytype, sym: ast.sema.Symbol) ![]ValueRef {
    const multipliers = try ctx.allocator.alloc(ValueRef, sym.dims.len);
    var stride = support.i64Const(ctx, 1);
    for (sym.dims, 0..) |dim, idx| {
        multipliers[idx] = stride;
        var extent = memory.emitSymbolDimExtent(ctx, builder, sym, idx) catch |err| switch (err) {
            error.UnknownSymbol => memory.emitDimValue(ctx, builder, dim) catch |inner| switch (inner) {
                error.UnknownSymbol => support.i64Const(ctx, 1),
                else => return inner,
            },
            else => return err,
        };
        if (extent.ty != .i64) {
            extent = try casting.coerce(ctx, builder, extent, .i64);
        }
        stride = try support.emitMulI64(ctx, builder, stride, extent);
    }
    return multipliers;
}

pub fn staticIntExprValue(expr: *Expr) ?i64 {
    return switch (expr.*) {
        .literal => |lit| if (lit.kind == .integer) std.fmt.parseInt(i64, lit.text, 10) catch null else null,
        .unary => |un| {
            const value = staticIntExprValue(un.expr) orelse return null;
            return switch (un.op) {
                .plus => value,
                .minus => -value,
                else => null,
            };
        },
        .binary => |bin| {
            const left = staticIntExprValue(bin.left) orelse return null;
            const right = staticIntExprValue(bin.right) orelse return null;
            return switch (bin.op) {
                .add => left + right,
                .sub => left - right,
                .mul => left * right,
                .div => if (right == 0) null else @divTrunc(left, right),
                else => null,
            };
        },
        else => null,
    };
}

const ArrayConstructorElementInfo = struct {
    elem_ty: IRType,
    address_scale: ValueRef,
};

fn arrayConstructorElementInfo(ctx: *Context, ctor: ast.ArrayConstructor) ?ArrayConstructorElementInfo {
    const representative = arrayConstructorRepresentativeExpr(ctor) orelse {
        const type_spec = ctor.type_spec orelse return null;
        return switch (type_spec.type_kind) {
            .character, .derived => null,
            else => .{
                .elem_ty = ctx.typeFromKind(type_spec.type_kind),
                .address_scale = support.i64Const(ctx, 1),
            },
        };
    };
    if (dispatch.isCharacterExpr(ctx, representative)) {
        const char_len = dispatch.constantCharacterLenForExpr(ctx, representative) orelse return null;
        return .{
            .elem_ty = .i8,
            .address_scale = support.i64Const(ctx, @intCast(char_len)),
        };
    }
    const elem_ty = casting.exprType(ctx, representative) catch return null;
    return .{
        .elem_ty = elem_ty,
        .address_scale = support.i64Const(ctx, 1),
    };
}

fn arrayConstructorRepresentativeExpr(ctor: ast.ArrayConstructor) ?*Expr {
    for (ctor.items) |item| {
        if (item.* == .implied_do) {
            if (item.implied_do.items.len == 0) continue;
            return item.implied_do.items[0];
        }
        return item;
    }
    return null;
}

fn arrayConstructorHasOnlyScalarItems(ctor: ast.ArrayConstructor) bool {
    for (ctor.items) |item| {
        if (item.* == .implied_do) return false;
    }
    return true;
}

fn staticArrayConstructorCount(ctor: ast.ArrayConstructor) ?usize {
    var total: usize = 0;
    for (ctor.items) |item| {
        total = std.math.add(usize, total, staticArrayConstructorItemCount(item) orelse return null) catch return null;
    }
    return total;
}

fn staticArrayConstructorItemCount(expr: *Expr) ?usize {
    return switch (expr.*) {
        .implied_do => |implied| blk: {
            const trip_count = staticImpliedDoTripCount(implied) orelse return null;
            var per_iter: usize = 0;
            for (implied.items) |item| {
                per_iter = std.math.add(usize, per_iter, staticArrayConstructorItemCount(item) orelse return null) catch return null;
            }
            break :blk std.math.mul(usize, trip_count, per_iter) catch return null;
        },
        else => 1,
    };
}

fn staticImpliedDoTripCount(implied: ast.ImpliedDo) ?usize {
    const start = staticIntExprValue(implied.start) orelse return null;
    const finish = staticIntExprValue(implied.end) orelse return null;
    const step = if (implied.step) |step_expr| staticIntExprValue(step_expr) orelse return null else 1;
    if (step == 0) return null;
    if (step > 0) {
        if (start > finish) return 0;
        const span = finish - start;
        return std.math.cast(usize, @divTrunc(span, step) + 1);
    }
    if (start < finish) return 0;
    const span = start - finish;
    return std.math.cast(usize, @divTrunc(span, -step) + 1);
}
