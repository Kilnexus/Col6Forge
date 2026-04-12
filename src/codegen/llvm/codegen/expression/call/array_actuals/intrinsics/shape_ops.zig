const std = @import("std");
const ast = @import("../../../../../../input.zig");
const memory = @import("../../../memory.zig");
const dispatch = @import("../../../dispatch/mod.zig");
const casting = @import("../../../casting.zig");
const flatten_core = @import("../../../../../stmts/execution/assignment/flatten/core.zig");
const flatten_metadata = @import("../../../../../stmts/execution/assignment/flatten/metadata.zig");
const shared = @import("../../shared.zig");
const support = @import("../../array_actuals_support.zig");

const Context = shared.Context;
const Expr = shared.Expr;
const IRType = shared.IRType;
const ValueRef = shared.ValueRef;
const ArrayActualPlan = shared.ArrayActualPlan;

const BoundsSubject = union(enum) {
    symbol: ast.sema.Symbol,
    component: ast.ComponentExpr,
};

pub fn analyzeIntrinsicBoundsActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    hooks: anytype,
) !?ArrayActualPlan {
    const BoundsMode = enum {
        lbound,
        ubound,
        shape,
    };
    const mode = if (std.ascii.eqlIgnoreCase(call.name, "lbound"))
        BoundsMode.lbound
    else if (std.ascii.eqlIgnoreCase(call.name, "ubound"))
        BoundsMode.ubound
    else if (std.ascii.eqlIgnoreCase(call.name, "shape"))
        BoundsMode.shape
    else
        return null;
    if (call.args.len == 0 or call.args.len > 2) return null;

    const resolved_extents = if (shouldUseExtentBounds(ctx, call.args[0]))
        try shapeSubjectExtents(ctx, builder, call.args[0], hooks)
    else
        null;
    const subject = if (resolved_extents == null) arrayBoundsSubject(ctx, call.args[0]) else null;
    const rank: usize = if (resolved_extents) |extents|
        extents.len
    else switch (subject orelse return null) {
        .symbol => |sym| sym.dims.len,
        .component => |comp| blk: {
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse return error.UnknownSymbol;
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse return error.UnknownSymbol;
            break :blk component.dims.len;
        },
    };
    if (mode != .shape and call.args.len == 2) {
        const second = hooks.evalConstIntArg(ctx, call.args[1]) orelse return null;
        if (second >= 1 and second <= rank) return null;
    }

    const result_ty: IRType = if (call.args.len == 2) blk: {
        const kind_value = hooks.evalConstIntArg(ctx, call.args[1]) orelse return null;
        break :blk if (kind_value >= 8) .i64 else .i32;
    } else ctx.defaultIntegerIRType();
    const extents = try ctx.allocator.alloc(ValueRef, 1);
    extents[0] = support.i64Const(ctx, @intCast(rank));
    const multipliers = try ctx.allocator.alloc(ValueRef, 1);
    multipliers[0] = support.i64Const(ctx, 1);
    const dst_ptr = try support.emitHeapArrayTempPointer(ctx, builder, result_ty, extents[0]);
    switch (mode) {
        .lbound => {
            if (resolved_extents) |subject_extents| {
                try emitExtentBoundsVectorLoop(ctx, builder, subject_extents, true, dst_ptr, result_ty);
            } else {
                try emitBoundsVectorLoop(ctx, builder, subject.?, true, rank, dst_ptr, result_ty);
            }
        },
        .ubound => {
            if (resolved_extents) |subject_extents| {
                try emitExtentBoundsVectorLoop(ctx, builder, subject_extents, false, dst_ptr, result_ty);
            } else {
                try emitBoundsVectorLoop(ctx, builder, subject.?, false, rank, dst_ptr, result_ty);
            }
        },
        .shape => {
            const subject_extents = resolved_extents orelse try shapeSubjectExtents(ctx, builder, call.args[0], hooks) orelse return null;
            for (subject_extents, 0..) |extent, idx| {
                const coerced = if (extent.ty == result_ty) extent else try casting.coerce(ctx, builder, extent, result_ty);
                const elem_ptr_name = try ctx.nextTemp();
                try builder.gep(elem_ptr_name, result_ty, dst_ptr, support.i64Const(ctx, @intCast(idx)));
                try builder.store(coerced, .{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true });
            }
        },
    }

    return .{
        .base_ptr = dst_ptr,
        .elem_ty = result_ty,
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = support.i64Const(ctx, 1),
        .storage = .materialized_temp,
        .owned_heap_ptr = dst_ptr,
        .contiguous = true,
    };
}

fn shouldUseExtentBounds(ctx: *Context, expr_node: *Expr) bool {
    return switch (expr_node.*) {
        .call_or_subscript => |call| call.args.len != 0,
        .component => |comp| comp.args.len != 0,
        .substring => |sub| blk: {
            const sym = ctx.findSymbol(sub.name) orelse break :blk false;
            break :blk sym.dims.len != 0;
        },
        else => false,
    };
}

pub fn analyzeIntrinsicTransposeActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    hooks: anytype,
) !?ArrayActualPlan {
    if (!std.ascii.eqlIgnoreCase(call.name, "transpose")) return null;
    if (call.args.len != 1) return error.InvalidIntrinsicCall;

    const source_actual = (try hooks.resolveArrayActual(ctx, builder, call.args[0])) orelse return null;
    try source_actual.validate();
    if (source_actual.extents.len != 2 or source_actual.multipliers.len != 2) return error.InvalidIntrinsicCall;

    const extents = try ctx.allocator.alloc(ValueRef, 2);
    extents[0] = source_actual.extents[1];
    extents[1] = source_actual.extents[0];

    const multipliers = try ctx.allocator.alloc(ValueRef, 2);
    multipliers[0] = source_actual.multipliers[1];
    multipliers[1] = source_actual.multipliers[0];

    return .{
        .base_ptr = source_actual.base_ptr,
        .elem_ty = source_actual.elem_ty,
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = source_actual.address_scale,
        .storage = source_actual.storage,
        .owned_heap_ptr = source_actual.owned_heap_ptr,
        .contiguous = false,
    };
}

pub fn analyzeIntrinsicReshapeActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    hooks: anytype,
) !?ArrayActualPlan {
    if (!std.ascii.eqlIgnoreCase(call.name, "reshape")) return null;
    if (call.args.len != 2) return null;

    const extents = try reshapeResultExtents(ctx, builder, call.args[1], hooks) orelse return null;
    if (flatten_metadata.reshapeShapeProduct(ctx, call.args[1])) |expected_count| {
        if (try flatten_core.flattenArrayValuedExprItems(ctx, call.args[0])) |flat_items| {
            if (flat_items.len != expected_count or flat_items.len == 0) return null;

            const elem_ty = try casting.exprType(ctx, flat_items[0]);
            if (!support.isMaterializableArrayElementType(elem_ty)) return null;

            const dst_ptr = try support.emitHeapArrayTempPointer(ctx, builder, elem_ty, support.i64Const(ctx, @intCast(flat_items.len)));
            for (flat_items, 0..) |item, idx| {
                const value = try dispatch.emitExpr(ctx, builder, item);
                const coerced = if (value.ty == elem_ty) value else try casting.coerce(ctx, builder, value, elem_ty);
                const elem_ptr_name = try ctx.nextTemp();
                try builder.gep(elem_ptr_name, elem_ty, dst_ptr, support.i64Const(ctx, @intCast(idx)));
                try builder.store(coerced, .{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true });
            }

            return .{
                .base_ptr = dst_ptr,
                .elem_ty = elem_ty,
                .extents = extents,
                .multipliers = try support.emitContiguousMultipliers(ctx, builder, extents),
                .address_scale = support.i64Const(ctx, 1),
                .storage = .materialized_temp,
                .owned_heap_ptr = dst_ptr,
                .contiguous = true,
            };
        }
    }

    const source_actual = (try hooks.resolveArrayActual(ctx, builder, call.args[0])) orelse return null;
    try source_actual.validate();
    const source_count = try support.emitExtentProductI64(ctx, builder, source_actual.extents);
    const result_count = try support.emitExtentProductI64(ctx, builder, extents);
    try support.emitRequireEqualI64(ctx, builder, source_count, result_count, "reshape_count");

    if (!source_actual.contiguous) {
        if (!support.isMaterializableArrayElementType(source_actual.elem_ty)) return null;
        if (!support.valueRefEquals(source_actual.address_scale, support.i64Const(ctx, 1))) return null;

        const dst_ptr = try support.emitHeapArrayTempPointer(ctx, builder, source_actual.elem_ty, result_count);
        try support.emitIntrinsicArrayConversionLoop(
            ctx,
            builder,
            source_actual.base_ptr,
            source_actual.elem_ty,
            source_actual.extents,
            source_actual.multipliers,
            source_actual.address_scale,
            source_actual.contiguous,
            dst_ptr,
            source_actual.elem_ty,
            result_count,
        );
        try support.emitMaybeFreeOwnedArrayActual(ctx, builder, source_actual);

        return .{
            .base_ptr = dst_ptr,
            .elem_ty = source_actual.elem_ty,
            .extents = extents,
            .multipliers = try support.emitContiguousMultipliers(ctx, builder, extents),
            .address_scale = support.i64Const(ctx, 1),
            .storage = .materialized_temp,
            .owned_heap_ptr = dst_ptr,
            .contiguous = true,
        };
    }

    return .{
        .base_ptr = source_actual.base_ptr,
        .elem_ty = source_actual.elem_ty,
        .extents = extents,
        .multipliers = try support.emitContiguousMultipliers(ctx, builder, extents),
        .address_scale = source_actual.address_scale,
        .storage = source_actual.storage,
        .owned_heap_ptr = source_actual.owned_heap_ptr,
        .contiguous = true,
    };
}

pub fn shapeSubjectExtents(
    ctx: *Context,
    builder: anytype,
    expr_node: *Expr,
    hooks: anytype,
) !?[]ValueRef {
    const actual = switch (expr_node.*) {
        .component => |comp| blk: {
            if (!comp.has_parens) {
                if (try hooks.resolveArrayActual(ctx, builder, expr_node)) |actual| break :blk actual;
                break :blk (try hooks.analyzeAddressableArrayActual(ctx, builder, expr_node)) orelse return null;
            }
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse return null;
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse return null;
            break :blk (try hooks.analyzeKnownArrayProcedureComponentActual(ctx, builder, comp, component)) orelse return null;
        },
        else => blk: {
            if (try hooks.resolveArrayActual(ctx, builder, expr_node)) |actual| break :blk actual;
            break :blk (try hooks.analyzeAddressableArrayActual(ctx, builder, expr_node)) orelse return null;
        },
    };
    try actual.validate();
    return actual.extents;
}

fn arrayBoundsSubject(ctx: *Context, expr: *Expr) ?BoundsSubject {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const sym = ctx.findSymbol(name) orelse break :blk null;
            if (sym.dims.len == 0) break :blk null;
            break :blk .{ .symbol = sym };
        },
        .call_or_subscript => |call| blk: {
            const sym = ctx.findSymbol(call.name) orelse break :blk null;
            if (sym.dims.len == 0) break :blk null;
            break :blk .{ .symbol = sym };
        },
        .component => |comp| blk: {
            if (comp.has_parens or comp.args.len != 0) break :blk null;
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse break :blk null;
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse break :blk null;
            if (component.dims.len == 0) break :blk null;
            break :blk .{ .component = comp };
        },
        else => null,
    };
}

fn reshapeResultExtents(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    hooks: anytype,
) !?[]ValueRef {
    if (expr.* == .call_or_subscript and std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "shape") and expr.call_or_subscript.args.len == 1) {
        return shapeSubjectExtents(ctx, builder, expr.call_or_subscript.args[0], hooks);
    }
    if (expr.* != .array_constructor) return null;

    const ctor = expr.array_constructor;
    const extents = try ctx.allocator.alloc(ValueRef, ctor.items.len);
    for (ctor.items, 0..) |item, idx| {
        const value = hooks.staticIntExprValue(item) orelse return null;
        extents[idx] = support.i64Const(ctx, value);
    }
    return extents;
}

fn emitMaskedSelectValue(
    ctx: *Context,
    builder: anytype,
    ty: IRType,
    cond: ValueRef,
    when_true: ValueRef,
    when_false: ValueRef,
) !ValueRef {
    const select_name = try ctx.nextTemp();
    try builder.select(select_name, ty, cond, when_true, when_false);
    return .{ .name = select_name, .ty = ty, .is_ptr = false };
}

fn emitBoundsVectorLoop(
    ctx: *Context,
    builder: anytype,
    subject: BoundsSubject,
    use_lower: bool,
    rank: usize,
    dst_ptr: ValueRef,
    result_ty: IRType,
) !void {
    const idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(idx_ptr_name, .i64);
    const idx_ptr = ValueRef{ .name = idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(support.i64Const(ctx, 0), idx_ptr);
    const loop_preheader = try ctx.nextLabel("bounds_vector_preheader");
    const loop_body = try ctx.nextLabel("bounds_vector_body");
    const loop_exit = try ctx.nextLabel("bounds_vector_exit");
    try builder.br(loop_preheader);

    try builder.label(loop_preheader);
    const idx_name = try ctx.nextTemp();
    try builder.load(idx_name, .i64, idx_ptr);
    const idx_val = ValueRef{ .name = idx_name, .ty = .i64, .is_ptr = false };
    const cond_name = try ctx.nextTemp();
    try builder.compare(cond_name, "icmp", "slt", .i64, idx_val, support.i64Const(ctx, @intCast(rank)));
    try builder.brCond(.{ .name = cond_name, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    var dim_idx: usize = 0;
    while (dim_idx < rank) : (dim_idx += 1) {
        const cmp_name = try ctx.nextTemp();
        try builder.compare(cmp_name, "icmp", "eq", .i64, idx_val, support.i64Const(ctx, @intCast(dim_idx)));
        const is_match = ValueRef{ .name = cmp_name, .ty = .i1, .is_ptr = false };
        const elem_ptr_name = try ctx.nextTemp();
        try builder.gep(elem_ptr_name, result_ty, dst_ptr, idx_val);
        const elem_ptr = ValueRef{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true };
        const current_name = try ctx.nextTemp();
        try builder.load(current_name, result_ty, elem_ptr);
        const current = ValueRef{ .name = current_name, .ty = result_ty, .is_ptr = false };
        var bound = switch (subject) {
            .symbol => |sym| blk: {
                if (use_lower) break :blk try memory.emitSymbolDimLower(ctx, builder, sym, dim_idx);
                const lower = try memory.emitSymbolDimLower(ctx, builder, sym, dim_idx);
                const extent = try memory.emitSymbolDimExtent(ctx, builder, sym, dim_idx);
                break :blk try support.emitAddI64(ctx, builder, lower, try support.emitSubI64(ctx, builder, extent, support.i64Const(ctx, 1)));
            },
            .component => |comp| blk: {
                if (use_lower) break :blk try memory.emitComponentDimLower(ctx, builder, comp, dim_idx);
                const lower = try memory.emitComponentDimLower(ctx, builder, comp, dim_idx);
                const extent = try memory.emitComponentDimExtent(ctx, builder, comp, dim_idx);
                break :blk try support.emitAddI64(ctx, builder, lower, try support.emitSubI64(ctx, builder, extent, support.i64Const(ctx, 1)));
            },
        };
        if (bound.ty != result_ty) bound = try casting.coerce(ctx, builder, bound, result_ty);
        const store_val = try emitMaskedSelectValue(ctx, builder, result_ty, is_match, bound, current);
        try builder.store(store_val, elem_ptr);
    }

    const next_name = try ctx.nextTemp();
    try builder.binary(next_name, "add", .i64, idx_val, support.i64Const(ctx, 1));
    try builder.store(.{ .name = next_name, .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_exit);
}

fn emitExtentBoundsVectorLoop(
    ctx: *Context,
    builder: anytype,
    extents: []const ValueRef,
    use_lower: bool,
    dst_ptr: ValueRef,
    result_ty: IRType,
) !void {
    for (extents, 0..) |extent, idx| {
        var bound = if (use_lower)
            support.i64Const(ctx, 1)
        else
            extent;
        if (bound.ty != result_ty) bound = try casting.coerce(ctx, builder, bound, result_ty);
        const elem_ptr_name = try ctx.nextTemp();
        try builder.gep(elem_ptr_name, result_ty, dst_ptr, support.i64Const(ctx, @intCast(idx)));
        try builder.store(bound, .{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true });
    }
}
