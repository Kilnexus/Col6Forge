const std = @import("std");
const ast = @import("../../../../input.zig");
const common = @import("../../common.zig");
const utils = @import("../../utils.zig");
const evaluator = @import("../../../../../semantic/evaluator.zig");
const binary = @import("../binary.zig");
const casting = @import("../casting.zig");
const array_actuals = @import("../call/array_actuals.zig");
const call_shared = @import("../call/shared.zig");
const dispatch = @import("../dispatch/mod.zig");
const memory = @import("../memory.zig");
const shared = @import("shared.zig");
const bounds_support = @import("../array_bounds_support.zig");
const reductions = @import("arrays/reductions.zig");
const Expr = shared.Expr;
const IRType = shared.IRType;
const Context = shared.Context;
const ValueRef = shared.ValueRef;
const EmitError = shared.EmitError;
const ArrayActualPlan = call_shared.ArrayActualPlan;
const isIntegerType = shared.isIntegerType;
const isRealType = shared.isRealType;
const shapeSubjectExtents = array_actuals.shapeSubjectExtents;
pub fn emitIntrinsicSum(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len == 1) {
        if (try array_actuals.resolveArrayActual(ctx, builder, args[0])) |actual| {
            return emitScalarArraySumReduction(ctx, builder, actual, null);
        }
    } else if (args.len == 2) {
        const actual = (try array_actuals.resolveArrayActual(ctx, builder, args[0])) orelse return error.InvalidIntrinsicCall;
        try actual.validate();
        if (evalConstIntArg(ctx, args[1])) |dim_value| {
            if (actual.extents.len != 1 or dim_value != 1) return error.InvalidIntrinsicCall;
            return emitScalarArraySumReduction(ctx, builder, actual, null);
        }
        const mask = try analyzeScalarSumMask(ctx, builder, args[1], actual);
        return emitScalarArraySumReduction(ctx, builder, actual, mask);
    } else if (args.len == 3) {
        const actual = (try array_actuals.resolveArrayActual(ctx, builder, args[0])) orelse return error.InvalidIntrinsicCall;
        try actual.validate();
        const dim_value = evalConstIntArg(ctx, args[1]) orelse return error.InvalidIntrinsicCall;
        if (actual.extents.len != 1 or dim_value != 1) return error.InvalidIntrinsicCall;
        const mask = try analyzeScalarSumMask(ctx, builder, args[2], actual);
        return emitScalarArraySumReduction(ctx, builder, actual, mask);
    } else {
        return error.InvalidIntrinsicCall;
    }

    const acc_ty = try inferSumAccumulatorType(ctx, args[0]);
    const acc_ptr_name = try ctx.nextTemp();
    try builder.alloca(acc_ptr_name, acc_ty);
    const acc_ptr = ValueRef{ .name = acc_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(utils.zeroValue(acc_ty), acc_ptr);
    try emitSumAccumulator(ctx, builder, acc_ptr, acc_ty, args[0]);

    const acc_name = try ctx.nextTemp();
    try builder.load(acc_name, acc_ty, acc_ptr);
    return .{ .name = acc_name, .ty = acc_ty, .is_ptr = false };
}

pub fn emitIntrinsicCount(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len == 0 or args.len > 3) return error.InvalidIntrinsicCall;
    const actual = (try array_actuals.resolveArrayActual(ctx, builder, args[0])) orelse return error.InvalidIntrinsicCall;
    try actual.validate();
    var requested_dim: ?usize = null;
    var result_ty = ctx.defaultIntegerIRType();

    if (args.len >= 2) {
        const second = evalConstIntArg(ctx, args[1]) orelse return error.UnsupportedIntrinsicType;
        if (second >= 1 and second <= actual.extents.len) {
            requested_dim = @intCast(second - 1);
        } else {
            result_ty = integerKindToIRType(second) orelse return error.UnsupportedIntrinsicType;
        }
    }
    if (args.len == 3) {
        const third = evalConstIntArg(ctx, args[2]) orelse return error.UnsupportedIntrinsicType;
        if (requested_dim == null) {
            if (third < 1 or third > actual.extents.len) return error.InvalidIntrinsicCall;
            requested_dim = @intCast(third - 1);
        } else {
            result_ty = integerKindToIRType(third) orelse return error.UnsupportedIntrinsicType;
        }
    }
    if (requested_dim != null) return error.InvalidIntrinsicCall;

    const count_ptr_name = try ctx.nextTemp();
    try builder.alloca(count_ptr_name, result_ty);
    const count_ptr = ValueRef{ .name = count_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(utils.zeroValue(result_ty), count_ptr);

    var elem_count = try ctx.constI64(1);
    for (actual.extents) |extent| {
        elem_count = try binary.emitMul(ctx, builder, elem_count, extent);
    }

    const loop_preheader = try ctx.nextLabel("count_scalar_preheader");
    const loop_body = try ctx.nextLabel("count_scalar_body");
    const loop_exit = try ctx.nextLabel("count_scalar_exit");
    const idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(idx_ptr_name, .i64);
    const idx_ptr = ValueRef{ .name = idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(try ctx.constI64(0), idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_preheader);
    const idx_name = try ctx.nextTemp();
    try builder.load(idx_name, .i64, idx_ptr);
    const idx_val = ValueRef{ .name = idx_name, .ty = .i64, .is_ptr = false };
    const cond_name = try ctx.nextTemp();
    try builder.compare(cond_name, "icmp", "slt", .i64, idx_val, elem_count);
    try builder.brCond(.{ .name = cond_name, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    const mask_val = try emitLogicalCast(ctx, builder, try array_actuals.emitArrayActualElement(ctx, builder, idx_val, actual));
    const current_name = try ctx.nextTemp();
    try builder.load(current_name, result_ty, count_ptr);
    const current = ValueRef{ .name = current_name, .ty = result_ty, .is_ptr = false };
    const one = if (result_ty == .i64) ValueRef{ .name = "1", .ty = .i64, .is_ptr = false } else ValueRef{ .name = "1", .ty = .i32, .is_ptr = false };
    const updated = try binary.emitAdd(ctx, builder, current, one);
    const store_name = try ctx.nextTemp();
    try builder.select(store_name, result_ty, mask_val, updated, current);
    try builder.store(.{ .name = store_name, .ty = result_ty, .is_ptr = false }, count_ptr);
    const next_name = try ctx.nextTemp();
    try builder.binary(next_name, "add", .i64, idx_val, try ctx.constI64(1));
    try builder.store(.{ .name = next_name, .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_exit);
    try array_actuals.emitOwnedHeapActualFree(ctx, builder, actual.owned_heap_ptr);
    const out_name = try ctx.nextTemp();
    try builder.load(out_name, result_ty, count_ptr);
    return .{ .name = out_name, .ty = result_ty, .is_ptr = false };
}

const ScalarSumMask = struct {
    scalar_value: ?ValueRef = null,
    array_actual: ?ArrayActualPlan = null,
};

fn analyzeScalarSumMask(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    source_actual: ArrayActualPlan,
) EmitError!?ScalarSumMask {
    if (try array_actuals.resolveArrayActual(ctx, builder, expr)) |actual| {
        try actual.validate();
        if (actual.extents.len != source_actual.extents.len) return error.InvalidIntrinsicCall;
        return .{ .array_actual = actual };
    }
    return .{ .scalar_value = try emitLogicalCast(ctx, builder, try dispatch.emitExpr(ctx, builder, expr)) };
}

fn emitScalarSumMaskValue(
    ctx: *Context,
    builder: anytype,
    mask: ScalarSumMask,
    idx_val: ValueRef,
) EmitError!ValueRef {
    if (mask.array_actual) |actual| {
        return emitLogicalCast(ctx, builder, try array_actuals.emitArrayActualElement(ctx, builder, idx_val, actual));
    }
    return mask.scalar_value orelse .{ .name = "1", .ty = .i1, .is_ptr = false };
}

fn emitScalarArraySumReduction(
    ctx: *Context,
    builder: anytype,
    actual: ArrayActualPlan,
    mask: ?ScalarSumMask,
) EmitError!ValueRef {
    try actual.validate();

    const acc_ty = actual.elem_ty;
    const acc_ptr_name = try ctx.nextTemp();
    try builder.alloca(acc_ptr_name, acc_ty);
    const acc_ptr = ValueRef{ .name = acc_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(utils.zeroValue(acc_ty), acc_ptr);

    var elem_count = try ctx.constI64(1);
    for (actual.extents) |extent| {
        elem_count = try binary.emitMul(ctx, builder, elem_count, extent);
    }
    const loop_preheader = try ctx.nextLabel("sum_scalar_array_preheader");
    const loop_body = try ctx.nextLabel("sum_scalar_array_body");
    const loop_exit = try ctx.nextLabel("sum_scalar_array_exit");
    const idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(idx_ptr_name, .i64);
    const idx_ptr = ValueRef{ .name = idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(try ctx.constI64(0), idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_preheader);
    const idx_name = try ctx.nextTemp();
    try builder.load(idx_name, .i64, idx_ptr);
    const idx_val = ValueRef{ .name = idx_name, .ty = .i64, .is_ptr = false };
    const cond_name = try ctx.nextTemp();
    try builder.compare(cond_name, "icmp", "slt", .i64, idx_val, elem_count);
    try builder.brCond(.{ .name = cond_name, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    const src_val = try array_actuals.emitArrayActualElement(ctx, builder, idx_val, actual);
    const current_name = try ctx.nextTemp();
    try builder.load(current_name, acc_ty, acc_ptr);
    const current = ValueRef{ .name = current_name, .ty = acc_ty, .is_ptr = false };
    const updated = try binary.emitAdd(ctx, builder, current, src_val);
    if (mask) |resolved_mask| {
        const mask_val = try emitScalarSumMaskValue(ctx, builder, resolved_mask, idx_val);
        const store_name = try ctx.nextTemp();
        try builder.select(store_name, acc_ty, mask_val, updated, current);
        try builder.store(.{ .name = store_name, .ty = acc_ty, .is_ptr = false }, acc_ptr);
    } else {
        try builder.store(updated, acc_ptr);
    }

    const next_name = try ctx.nextTemp();
    try builder.binary(next_name, "add", .i64, idx_val, try ctx.constI64(1));
    try builder.store(.{ .name = next_name, .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_exit);
    const acc_name = try ctx.nextTemp();
    try builder.load(acc_name, acc_ty, acc_ptr);
    if (mask) |resolved_mask| {
        if (resolved_mask.array_actual) |mask_actual| {
            try array_actuals.emitOwnedHeapActualFree(ctx, builder, mask_actual.owned_heap_ptr);
        }
    }
    try array_actuals.emitOwnedHeapActualFree(ctx, builder, actual.owned_heap_ptr);
    return .{ .name = acc_name, .ty = acc_ty, .is_ptr = false };
}

fn inferSumAccumulatorType(ctx: *Context, expr_node: *Expr) EmitError!IRType {
    return switch (expr_node.*) {
        .array_constructor => |ctor| blk: {
            for (ctor.items) |item| {
                break :blk try inferSumAccumulatorType(ctx, item);
            }
            return error.UnsupportedArrayConstructor;
        },
        .implied_do => |implied| blk: {
            for (implied.items) |item| {
                break :blk try inferSumAccumulatorType(ctx, item);
            }
            return error.UnsupportedArrayConstructor;
        },
        else => casting.exprType(ctx, expr_node),
    };
}

fn emitSumAccumulator(
    ctx: *Context,
    builder: anytype,
    acc_ptr: ValueRef,
    acc_ty: IRType,
    expr_node: *Expr,
) EmitError!void {
    switch (expr_node.*) {
        .array_constructor => |ctor| {
            for (ctor.items) |item| {
                try emitSumAccumulator(ctx, builder, acc_ptr, acc_ty, item);
            }
        },
        .implied_do => |implied| try emitSumImpliedDo(ctx, builder, acc_ptr, acc_ty, implied),
        else => {
            const value = try dispatch.emitExpr(ctx, builder, expr_node);
            const coerced = if (value.ty == acc_ty) value else try casting.coerce(ctx, builder, value, acc_ty);
            const current_name = try ctx.nextTemp();
            try builder.load(current_name, acc_ty, acc_ptr);
            const current = ValueRef{ .name = current_name, .ty = acc_ty, .is_ptr = false };
            const updated = try binary.emitBinary(ctx, builder, .add, current, coerced);
            try builder.store(updated, acc_ptr);
        },
    }
}

fn emitSumImpliedDo(
    ctx: *Context,
    builder: anytype,
    acc_ptr: ValueRef,
    acc_ty: IRType,
    implied: ast.ImpliedDo,
) EmitError!void {
    const iter_sym = ctx.findSymbol(implied.var_name) orelse return error.UnknownSymbol;
    const iter_ptr = try ctx.getPointer(implied.var_name);
    const iter_ty = ctx.typeFromKind(iter_sym.loweredKind());

    var start_val = try dispatch.emitExpr(ctx, builder, implied.start);
    if (start_val.ty != iter_ty) start_val = try casting.coerce(ctx, builder, start_val, iter_ty);
    var step_val = if (implied.step) |step_expr|
        try dispatch.emitExpr(ctx, builder, step_expr)
    else
        ValueRef{ .name = "1", .ty = .i64, .is_ptr = false };
    if (step_val.ty != iter_ty) step_val = try casting.coerce(ctx, builder, step_val, iter_ty);
    var loop_count = try emitSumImpliedCount(ctx, builder, implied);
    if (loop_count.ty != .i64) loop_count = try casting.coerce(ctx, builder, loop_count, .i64);

    const iter_saved_ptr_name = try ctx.nextTemp();
    try builder.alloca(iter_saved_ptr_name, iter_ty);
    const iter_saved_ptr = ValueRef{ .name = iter_saved_ptr_name, .ty = .ptr, .is_ptr = true };
    const iter_saved_name = try ctx.nextTemp();
    try builder.load(iter_saved_name, iter_ty, iter_ptr);
    try builder.store(.{ .name = iter_saved_name, .ty = iter_ty, .is_ptr = false }, iter_saved_ptr);

    const loop_idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(loop_idx_ptr_name, .i64);
    const loop_idx_ptr = ValueRef{ .name = loop_idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(.{ .name = "0", .ty = .i64, .is_ptr = false }, loop_idx_ptr);
    try builder.store(start_val, iter_ptr);

    const loop_head = try ctx.nextLabel("sum_implied_head");
    const loop_body = try ctx.nextLabel("sum_implied_body");
    const loop_exit = try ctx.nextLabel("sum_implied_exit");
    try builder.br(loop_head);

    try builder.label(loop_head);
    const loop_idx_name = try ctx.nextTemp();
    try builder.load(loop_idx_name, .i64, loop_idx_ptr);
    const loop_idx = ValueRef{ .name = loop_idx_name, .ty = .i64, .is_ptr = false };
    const cond_name = try ctx.nextTemp();
    try builder.compare(cond_name, "icmp", "slt", .i64, loop_idx, loop_count);
    try builder.brCond(.{ .name = cond_name, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    for (implied.items) |item| {
        try emitSumAccumulator(ctx, builder, acc_ptr, acc_ty, item);
    }

    const cur_iter_name = try ctx.nextTemp();
    try builder.load(cur_iter_name, iter_ty, iter_ptr);
    const next_iter_name = try ctx.nextTemp();
    try builder.binary(next_iter_name, "add", iter_ty, .{ .name = cur_iter_name, .ty = iter_ty, .is_ptr = false }, step_val);
    try builder.store(.{ .name = next_iter_name, .ty = iter_ty, .is_ptr = false }, iter_ptr);

    const next_loop_idx_name = try ctx.nextTemp();
    try builder.binary(next_loop_idx_name, "add", .i64, loop_idx, .{ .name = "1", .ty = .i64, .is_ptr = false });
    try builder.store(.{ .name = next_loop_idx_name, .ty = .i64, .is_ptr = false }, loop_idx_ptr);
    try builder.br(loop_head);

    try builder.label(loop_exit);
    const iter_restore_name = try ctx.nextTemp();
    try builder.load(iter_restore_name, iter_ty, iter_saved_ptr);
    try builder.store(.{ .name = iter_restore_name, .ty = iter_ty, .is_ptr = false }, iter_ptr);
}

fn emitSumImpliedCount(ctx: *Context, builder: anytype, implied: ast.ImpliedDo) EmitError!ValueRef {
    var start = try dispatch.emitExpr(ctx, builder, implied.start);
    if (start.ty != .i64) start = try casting.coerce(ctx, builder, start, .i64);
    var end_val = try dispatch.emitExpr(ctx, builder, implied.end);
    if (end_val.ty != .i64) end_val = try casting.coerce(ctx, builder, end_val, .i64);
    const diff = try binary.emitBinary(ctx, builder, .sub, end_val, start);
    var step = if (implied.step) |step_expr|
        try dispatch.emitExpr(ctx, builder, step_expr)
    else
        ValueRef{ .name = "1", .ty = .i64, .is_ptr = false };
    if (step.ty != .i64) step = try casting.coerce(ctx, builder, step, .i64);
    const quot = try binary.emitBinary(ctx, builder, .div, diff, step);
    return binary.emitBinary(ctx, builder, .add, quot, .{ .name = "1", .ty = .i64, .is_ptr = false });
}

fn emitLogicalCast(ctx: *Context, builder: anytype, value: ValueRef) EmitError!ValueRef {
    if (value.ty == .i1) return value;
    if (isIntegerType(value.ty)) {
        const tmp = try ctx.nextTemp();
        try builder.compare(tmp, "icmp", "ne", value.ty, value, utils.zeroValue(value.ty));
        return .{ .name = tmp, .ty = .i1, .is_ptr = false };
    }
    if (isRealType(value.ty)) {
        const tmp = try ctx.nextTemp();
        try builder.compare(tmp, "fcmp", "one", value.ty, value, utils.zeroValue(value.ty));
        return .{ .name = tmp, .ty = .i1, .is_ptr = false };
    }
    return error.UnsupportedIntrinsicType;
}

pub fn emitIntrinsicAny(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    return emitIntrinsicLogicalReduction(ctx, builder, args, false);
}

pub fn emitIntrinsicAll(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    return emitIntrinsicLogicalReduction(ctx, builder, args, true);
}

fn emitIntrinsicLogicalReduction(ctx: *Context, builder: anytype, args: []*Expr, require_all: bool) EmitError!ValueRef {
    if (args.len != 1) return error.InvalidIntrinsicCall;
    const shape_reduced = if (require_all)
        try reductions.emitShapeCompareAllReduction(ctx, builder, args[0])
    else
        try reductions.emitShapeCompareAnyReduction(ctx, builder, args[0]);
    if (shape_reduced) |reduced| {
        return reduced;
    }
    const array_reduced = if (require_all)
        try reductions.emitWholeArrayAllReduction(ctx, builder, args[0])
    else
        try reductions.emitWholeArrayAnyReduction(ctx, builder, args[0]);
    if (array_reduced) |reduced| {
        return reduced;
    }
    if (try array_actuals.resolveArrayActual(ctx, builder, args[0])) |actual| {
        return emitScalarArrayLogicalReduction(ctx, builder, actual, require_all);
    }
    const value = try dispatch.emitExpr(ctx, builder, args[0]);
    return emitLogicalCast(ctx, builder, value);
}

fn emitScalarArrayLogicalReduction(
    ctx: *Context,
    builder: anytype,
    actual: ArrayActualPlan,
    require_all: bool,
) EmitError!ValueRef {
    try actual.validate();

    var elem_count = try ctx.constI64(1);
    for (actual.extents) |extent| {
        elem_count = try binary.emitMul(ctx, builder, elem_count, extent);
    }

    const init = if (require_all)
        ValueRef{ .name = "1", .ty = .i1, .is_ptr = false }
    else
        ValueRef{ .name = "0", .ty = .i1, .is_ptr = false };
    const acc_ptr_name = try ctx.nextTemp();
    try builder.alloca(acc_ptr_name, .i1);
    const acc_ptr = ValueRef{ .name = acc_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(init, acc_ptr);

    const loop_preheader = try ctx.nextLabel(if (require_all) "all_actual_preheader" else "any_actual_preheader");
    const loop_body = try ctx.nextLabel(if (require_all) "all_actual_body" else "any_actual_body");
    const loop_exit = try ctx.nextLabel(if (require_all) "all_actual_exit" else "any_actual_exit");
    const idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(idx_ptr_name, .i64);
    const idx_ptr = ValueRef{ .name = idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(.{ .name = "0", .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_preheader);
    const idx_name = try ctx.nextTemp();
    try builder.load(idx_name, .i64, idx_ptr);
    const idx_val = ValueRef{ .name = idx_name, .ty = .i64, .is_ptr = false };
    const cond_name = try ctx.nextTemp();
    try builder.compare(cond_name, "icmp", "slt", .i64, idx_val, elem_count);
    try builder.brCond(.{ .name = cond_name, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    const elem = try array_actuals.emitArrayActualElement(ctx, builder, idx_val, actual);
    const elem_logical = try emitLogicalCast(ctx, builder, elem);
    const current_name = try ctx.nextTemp();
    try builder.load(current_name, .i1, acc_ptr);
    const current = ValueRef{ .name = current_name, .ty = .i1, .is_ptr = false };
    const updated = if (require_all)
        try binary.emitBinary(ctx, builder, .and_, current, elem_logical)
    else
        try binary.emitBinary(ctx, builder, .or_, current, elem_logical);
    try builder.store(updated, acc_ptr);
    const next_name = try ctx.nextTemp();
    try builder.binary(next_name, "add", .i64, idx_val, .{ .name = "1", .ty = .i64, .is_ptr = false });
    try builder.store(.{ .name = next_name, .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_exit);
    try array_actuals.emitOwnedHeapActualFree(ctx, builder, actual.owned_heap_ptr);
    const out_name = try ctx.nextTemp();
    try builder.load(out_name, .i1, acc_ptr);
    return .{ .name = out_name, .ty = .i1, .is_ptr = false };
}

fn oneIndexValue(ctx: *Context) EmitError!ValueRef {
    return try ctx.constI64(1);
}

fn emitArrayDimExtentExpr(ctx: *Context, builder: anytype, expr: *Expr) EmitError!ValueRef {
    switch (expr.*) {
        .literal => |lit| {
            if (lit.kind == .assumed_size) return oneIndexValue(ctx);
        },
        .dim_range => |range| {
            if (range.upper.* == .literal and range.upper.literal.kind == .assumed_size) {
                return oneIndexValue(ctx);
            }
            var upper = try dispatch.emitExpr(ctx, builder, range.upper);
            upper = try casting.coerce(ctx, builder, upper, .i64);
            var lower = try oneIndexValue(ctx);
            if (range.lower) |lower_expr| {
                lower = try dispatch.emitExpr(ctx, builder, lower_expr);
                lower = try casting.coerce(ctx, builder, lower, .i64);
            }
            const diff = try binary.emitSub(ctx, builder, upper, lower);
            return binary.emitAdd(ctx, builder, diff, try oneIndexValue(ctx));
        },
        else => {},
    }
    const value = try dispatch.emitExpr(ctx, builder, expr);
    return casting.coerce(ctx, builder, value, .i64);
}

fn emitComponentDimExtentValue(ctx: *Context, builder: anytype, comp: ast.ComponentExpr, dim_index: usize) EmitError!ValueRef {
    const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse return error.UnknownSymbol;
    const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse return error.UnknownSymbol;
    if (component.pointer or component.allocatable) {
        return bounds_support.emitComponentDimExtentValue(ctx, builder, comp, dim_index);
    }
    return emitArrayDimExtentExpr(ctx, builder, component.dims[dim_index]);
}

const SizeArraySubject = union(enum) {
    symbol: ast.sema.Symbol,
    component: ast.ComponentExpr,
};

fn lookupArraySubjectForSize(ctx: *Context, expr: *Expr) ?SizeArraySubject {
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

pub fn emitIntrinsicSize(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len < 1 or args.len > 3) return error.InvalidIntrinsicCall;
    if (try shapeSubjectExtents(ctx, builder, args[0])) |extents| {
        return emitIntrinsicSizeForExtents(ctx, builder, extents, args);
    }

    const subject = lookupArraySubjectForSize(ctx, args[0]) orelse return error.UnsupportedIntrinsicType;
    const rank: usize = switch (subject) {
        .symbol => |sym| sym.dims.len,
        .component => |comp| blk: {
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse return error.UnknownSymbol;
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse return error.UnknownSymbol;
            break :blk component.dims.len;
        },
    };
    var requested_dim: ?usize = null;
    var result_ty = ctx.defaultIntegerIRType();

    if (args.len == 2) {
        if (evalConstIntArg(ctx, args[1])) |second| {
            if (second >= 1 and second <= rank) {
                requested_dim = @intCast(second - 1);
            } else {
                result_ty = integerKindToIRType(second) orelse return error.UnsupportedIntrinsicType;
            }
        }
    } else if (args.len == 3) {
        const dim_value = evalConstIntArg(ctx, args[1]) orelse return error.UnsupportedIntrinsicType;
        if (dim_value < 1 or dim_value > rank) return error.InvalidIntrinsicCall;
        requested_dim = @intCast(dim_value - 1);
        const kind_value = evalConstIntArg(ctx, args[2]) orelse return error.UnsupportedIntrinsicType;
        result_ty = integerKindToIRType(kind_value) orelse return error.UnsupportedIntrinsicType;
    }

    if (requested_dim == null and args.len >= 2) {
        return emitIntrinsicSizeDynamicDim(ctx, builder, subject, args[1], rank, result_ty);
    }

    var value = blk: {
        if (requested_dim) |dim_index| {
            break :blk switch (subject) {
                .symbol => |sym| try memory.emitSymbolDimExtent(ctx, builder, sym, dim_index),
                .component => |comp| try emitComponentDimExtentValue(ctx, builder, comp, dim_index),
            };
        }

        var total = try oneIndexValue(ctx);
        var dim_index: usize = 0;
        while (dim_index < rank) : (dim_index += 1) {
            const extent = switch (subject) {
                .symbol => |sym| try memory.emitSymbolDimExtent(ctx, builder, sym, dim_index),
                .component => |comp| try emitComponentDimExtentValue(ctx, builder, comp, dim_index),
            };
            total = try binary.emitMul(ctx, builder, total, extent);
        }
        break :blk total;
    };
    if (value.ty != result_ty) {
        value = try casting.coerce(ctx, builder, value, result_ty);
    }
    return value;
}

fn emitIntrinsicSizeDynamicDim(
    ctx: *Context,
    builder: anytype,
    subject: SizeArraySubject,
    dim_expr: *Expr,
    rank: usize,
    result_ty: IRType,
) EmitError!ValueRef {
    var dim_value = try dispatch.emitExpr(ctx, builder, dim_expr);
    if (dim_value.ty != .i64) dim_value = try casting.coerce(ctx, builder, dim_value, .i64);

    var result = utils.zeroValue(result_ty);
    var dim_index: usize = 0;
    while (dim_index < rank) : (dim_index += 1) {
        var candidate = switch (subject) {
            .symbol => |sym| try memory.emitSymbolDimExtent(ctx, builder, sym, dim_index),
            .component => |comp| try emitComponentDimExtentValue(ctx, builder, comp, dim_index),
        };
        if (candidate.ty != result_ty) candidate = try casting.coerce(ctx, builder, candidate, result_ty);

        const cond_name = try ctx.nextTemp();
        try builder.compare(cond_name, "icmp", "eq", .i64, dim_value, try ctx.constI64(@intCast(dim_index + 1)));
        const next_name = try ctx.nextTemp();
        try builder.select(next_name, result_ty, .{ .name = cond_name, .ty = .i1, .is_ptr = false }, candidate, result);
        result = .{ .name = next_name, .ty = result_ty, .is_ptr = false };
    }
    return result;
}

fn emitIntrinsicSizeForExtents(
    ctx: *Context,
    builder: anytype,
    extents: []const ValueRef,
    args: []*Expr,
) EmitError!ValueRef {
    const rank = extents.len;
    var requested_dim: ?usize = null;
    var result_ty = ctx.defaultIntegerIRType();

    if (args.len == 2) {
        if (evalConstIntArg(ctx, args[1])) |second| {
            if (second >= 1 and second <= rank) {
                requested_dim = @intCast(second - 1);
            } else {
                result_ty = integerKindToIRType(second) orelse return error.UnsupportedIntrinsicType;
            }
        }
    } else if (args.len == 3) {
        const dim_value = evalConstIntArg(ctx, args[1]) orelse return error.UnsupportedIntrinsicType;
        if (dim_value < 1 or dim_value > rank) return error.InvalidIntrinsicCall;
        requested_dim = @intCast(dim_value - 1);
        const kind_value = evalConstIntArg(ctx, args[2]) orelse return error.UnsupportedIntrinsicType;
        result_ty = integerKindToIRType(kind_value) orelse return error.UnsupportedIntrinsicType;
    }

    if (requested_dim == null and args.len >= 2) {
        return emitIntrinsicSizeDynamicDimForExtents(ctx, builder, extents, args[1], result_ty);
    }

    var value = blk: {
        if (requested_dim) |dim_index| break :blk extents[dim_index];

        var total = try oneIndexValue(ctx);
        for (extents) |extent| {
            total = try binary.emitMul(ctx, builder, total, extent);
        }
        break :blk total;
    };
    if (value.ty != result_ty) {
        value = try casting.coerce(ctx, builder, value, result_ty);
    }
    return value;
}

fn emitIntrinsicSizeDynamicDimForExtents(
    ctx: *Context,
    builder: anytype,
    extents: []const ValueRef,
    dim_expr: *Expr,
    result_ty: IRType,
) EmitError!ValueRef {
    var dim_value = try dispatch.emitExpr(ctx, builder, dim_expr);
    if (dim_value.ty != .i64) dim_value = try casting.coerce(ctx, builder, dim_value, .i64);

    var result = utils.zeroValue(result_ty);
    for (extents, 0..) |extent, dim_index| {
        var candidate = extent;
        if (candidate.ty != result_ty) candidate = try casting.coerce(ctx, builder, candidate, result_ty);

        const cond_name = try ctx.nextTemp();
        try builder.compare(cond_name, "icmp", "eq", .i64, dim_value, try ctx.constI64(@intCast(dim_index + 1)));
        const next_name = try ctx.nextTemp();
        try builder.select(next_name, result_ty, .{ .name = cond_name, .ty = .i1, .is_ptr = false }, candidate, result);
        result = .{ .name = next_name, .ty = result_ty, .is_ptr = false };
    }
    return result;
}

pub fn emitIntrinsicLbound(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    return emitIntrinsicBoundsScalar(ctx, builder, args, true);
}

pub fn emitIntrinsicUbound(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    return emitIntrinsicBoundsScalar(ctx, builder, args, false);
}

pub fn emitIntrinsicRank(ctx: *Context, _: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len != 1) return error.InvalidIntrinsicCall;
    const subject = lookupArraySubjectForSize(ctx, args[0]) orelse return error.UnsupportedIntrinsicType;
    return switch (subject) {
        .symbol => |sym| blk: {
            if (ctx.runtimeArrayDescriptor(sym.name)) |desc| {
                break :blk try ctx.constDefaultInteger(@intCast(desc.rank));
            }
            break :blk try ctx.constDefaultInteger(@intCast(sym.dims.len));
        },
        .component => |comp| blk: {
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse return error.UnknownSymbol;
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse return error.UnknownSymbol;
            break :blk try ctx.constDefaultInteger(@intCast(component.dims.len));
        },
    };
}

fn evalConstIntArg(ctx: *Context, expr: *Expr) ?i64 {
    const value = evaluator.evalConst(expr, .{
        .ctx = ctx,
        .resolveFn = resolveCodegenConstValue,
        .arrayExtentFn = resolveCodegenArrayExtent,
    }) catch return null;
    return switch (value orelse return null) {
        .integer => |v| v,
        else => null,
    };
}

fn resolveCodegenConstValue(raw_ctx: *anyopaque, name: []const u8) ?ast.sema.ConstValue {
    const ctx: *Context = @ptrCast(@alignCast(raw_ctx));
    const sym = ctx.findSymbol(name) orelse return null;
    if (sym.kind != .parameter) return null;
    return sym.const_value;
}

fn resolveCodegenArrayExtent(raw_ctx: *anyopaque, name: []const u8, dim: ?usize) ?i64 {
    const ctx: *Context = @ptrCast(@alignCast(raw_ctx));
    const sym = ctx.findSymbol(name) orelse return null;
    if (sym.dims.len == 0) return null;
    const dims = if (dim) |dim_index|
        sym.dims[dim_index .. dim_index + 1]
    else
        sym.dims;
    const extent = common.arrayElementCount(ctx.sem, dims) catch return null;
    return @intCast(extent);
}

fn integerKindToIRType(kind_value: i64) ?IRType {
    if (kind_value <= 0) return null;
    if (kind_value >= 8) return .i64;
    return .i32;
}

fn emitIntrinsicBoundsScalar(ctx: *Context, builder: anytype, args: []*Expr, comptime use_lower: bool) EmitError!ValueRef {
    if (args.len < 1 or args.len > 3) return error.InvalidIntrinsicCall;
    if (bounds_support.shouldUseExtentBounds(ctx, args[0])) {
        if (try shapeSubjectExtents(ctx, builder, args[0])) |extents| {
            return emitIntrinsicBoundsScalarForExtents(ctx, builder, extents, args, use_lower);
        }
    }
    const subject = lookupArraySubjectForSize(ctx, args[0]) orelse return error.UnsupportedIntrinsicType;
    const rank: usize = switch (subject) {
        .symbol => |sym| sym.dims.len,
        .component => |comp| blk: {
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse return error.UnknownSymbol;
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse return error.UnknownSymbol;
            break :blk component.dims.len;
        },
    };
    var requested_dim: ?usize = null;
    var result_ty = ctx.defaultIntegerIRType();

    if (args.len == 2) {
        if (evalConstIntArg(ctx, args[1])) |second| {
            if (second >= 1 and second <= rank) {
                requested_dim = @intCast(second - 1);
            } else {
                result_ty = integerKindToIRType(second) orelse return error.UnsupportedIntrinsicType;
            }
        }
    } else if (args.len == 3) {
        const dim_value = evalConstIntArg(ctx, args[1]) orelse return error.UnsupportedIntrinsicType;
        if (dim_value < 1 or dim_value > rank) return error.InvalidIntrinsicCall;
        requested_dim = @intCast(dim_value - 1);
        const kind_value = evalConstIntArg(ctx, args[2]) orelse return error.UnsupportedIntrinsicType;
        result_ty = integerKindToIRType(kind_value) orelse return error.UnsupportedIntrinsicType;
    }

    if (requested_dim == null and args.len == 1 and rank == 1) {
        requested_dim = 0;
    }

    if (requested_dim == null and args.len >= 2) {
        return emitIntrinsicBoundsDynamicDim(ctx, builder, subject, args[1], rank, result_ty, use_lower);
    }

    const dim_index = requested_dim orelse return error.InvalidIntrinsicCall;
    var value = switch (subject) {
        .symbol => |sym| if (use_lower)
            try memory.emitSymbolDimLower(ctx, builder, sym, dim_index)
        else blk: {
            const lower = try memory.emitSymbolDimLower(ctx, builder, sym, dim_index);
            const extent = try memory.emitSymbolDimExtent(ctx, builder, sym, dim_index);
            break :blk try binary.emitAdd(ctx, builder, lower, try binary.emitSub(ctx, builder, extent, try oneIndexValue(ctx)));
        },
        .component => |comp| if (use_lower)
            try bounds_support.emitComponentDimLowerValue(ctx, builder, comp, dim_index)
        else blk: {
            const lower = try bounds_support.emitComponentDimLowerValue(ctx, builder, comp, dim_index);
            const extent = try emitComponentDimExtentValue(ctx, builder, comp, dim_index);
            break :blk try binary.emitAdd(ctx, builder, lower, try binary.emitSub(ctx, builder, extent, try oneIndexValue(ctx)));
        },
    };
    if (value.ty != result_ty) value = try casting.coerce(ctx, builder, value, result_ty);
    return value;
}

fn emitIntrinsicBoundsScalarForExtents(
    ctx: *Context,
    builder: anytype,
    extents: []const ValueRef,
    args: []*Expr,
    comptime use_lower: bool,
) EmitError!ValueRef {
    const rank = extents.len;
    var requested_dim: ?usize = null;
    var result_ty = ctx.defaultIntegerIRType();

    if (args.len == 2) {
        if (evalConstIntArg(ctx, args[1])) |second| {
            if (second >= 1 and second <= rank) {
                requested_dim = @intCast(second - 1);
            } else {
                result_ty = integerKindToIRType(second) orelse return error.UnsupportedIntrinsicType;
            }
        }
    } else if (args.len == 3) {
        const dim_value = evalConstIntArg(ctx, args[1]) orelse return error.UnsupportedIntrinsicType;
        if (dim_value < 1 or dim_value > rank) return error.InvalidIntrinsicCall;
        requested_dim = @intCast(dim_value - 1);
        const kind_value = evalConstIntArg(ctx, args[2]) orelse return error.UnsupportedIntrinsicType;
        result_ty = integerKindToIRType(kind_value) orelse return error.UnsupportedIntrinsicType;
    }

    if (requested_dim == null and args.len == 1 and rank == 1) {
        requested_dim = 0;
    }

    if (requested_dim == null and args.len >= 2) {
        return emitIntrinsicBoundsDynamicDimForExtents(ctx, builder, extents, args[1], result_ty, use_lower);
    }

    const dim_index = requested_dim orelse return error.InvalidIntrinsicCall;
    var value = if (use_lower)
        try oneIndexValue(ctx)
    else
        extents[dim_index];
    if (value.ty != result_ty) value = try casting.coerce(ctx, builder, value, result_ty);
    return value;
}

fn emitIntrinsicBoundsDynamicDimForExtents(
    ctx: *Context,
    builder: anytype,
    extents: []const ValueRef,
    dim_expr: *Expr,
    result_ty: IRType,
    comptime use_lower: bool,
) EmitError!ValueRef {
    var dim_value = try dispatch.emitExpr(ctx, builder, dim_expr);
    if (dim_value.ty != .i64) dim_value = try casting.coerce(ctx, builder, dim_value, .i64);

    var result = if (use_lower)
        try casting.coerce(ctx, builder, try oneIndexValue(ctx), result_ty)
    else
        utils.zeroValue(result_ty);

    for (extents, 0..) |extent, dim_index| {
        var candidate = if (use_lower)
            try oneIndexValue(ctx)
        else
            extent;
        if (candidate.ty != result_ty) candidate = try casting.coerce(ctx, builder, candidate, result_ty);

        const cond_name = try ctx.nextTemp();
        try builder.compare(cond_name, "icmp", "eq", .i64, dim_value, try ctx.constI64(@intCast(dim_index + 1)));
        const next_name = try ctx.nextTemp();
        try builder.select(next_name, result_ty, .{ .name = cond_name, .ty = .i1, .is_ptr = false }, candidate, result);
        result = .{ .name = next_name, .ty = result_ty, .is_ptr = false };
    }
    return result;
}

fn emitIntrinsicBoundsDynamicDim(
    ctx: *Context,
    builder: anytype,
    subject: SizeArraySubject,
    dim_expr: *Expr,
    rank: usize,
    result_ty: IRType,
    comptime use_lower: bool,
) EmitError!ValueRef {
    var dim_value = try dispatch.emitExpr(ctx, builder, dim_expr);
    if (dim_value.ty != .i64) dim_value = try casting.coerce(ctx, builder, dim_value, .i64);

    var result = if (use_lower)
        try casting.coerce(ctx, builder, try oneIndexValue(ctx), result_ty)
    else
        utils.zeroValue(result_ty);

    var dim_index: usize = 0;
    while (dim_index < rank) : (dim_index += 1) {
        var candidate = switch (subject) {
            .symbol => |sym| if (use_lower)
                try memory.emitSymbolDimLower(ctx, builder, sym, dim_index)
            else blk: {
                const lower = try memory.emitSymbolDimLower(ctx, builder, sym, dim_index);
                const extent = try memory.emitSymbolDimExtent(ctx, builder, sym, dim_index);
                break :blk try binary.emitAdd(ctx, builder, lower, try binary.emitSub(ctx, builder, extent, try oneIndexValue(ctx)));
            },
            .component => |comp| if (use_lower)
                try bounds_support.emitComponentDimLowerValue(ctx, builder, comp, dim_index)
            else blk: {
                const lower = try bounds_support.emitComponentDimLowerValue(ctx, builder, comp, dim_index);
                const extent = try emitComponentDimExtentValue(ctx, builder, comp, dim_index);
                break :blk try binary.emitAdd(ctx, builder, lower, try binary.emitSub(ctx, builder, extent, try oneIndexValue(ctx)));
            },
        };
        if (candidate.ty != result_ty) candidate = try casting.coerce(ctx, builder, candidate, result_ty);

        const cond_name = try ctx.nextTemp();
        try builder.compare(cond_name, "icmp", "eq", .i64, dim_value, try ctx.constI64(@intCast(dim_index + 1)));
        const next_name = try ctx.nextTemp();
        try builder.select(next_name, result_ty, .{ .name = cond_name, .ty = .i1, .is_ptr = false }, candidate, result);
        result = .{ .name = next_name, .ty = result_ty, .is_ptr = false };
    }
    return result;
}

pub fn emitIntrinsicAllocated(args: []*Expr) EmitError!ValueRef {
    if (args.len != 1) return error.InvalidIntrinsicCall;
    return .{ .name = "1", .ty = .i1, .is_ptr = false };
}

fn isGuaranteedContiguousInquiryArg(ctx: *Context, expr_node: *Expr) bool {
    return switch (expr_node.*) {
        .identifier => |name| blk: {
            const sym = ctx.findSymbol(name) orelse break :blk false;
            if (sym.dims.len == 0) break :blk false;
            break :blk sym.is_allocatable or (sym.is_pointer and sym.contiguous);
        },
        else => false,
    };
}

pub fn emitIntrinsicIsContiguous(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len != 1) return error.InvalidIntrinsicCall;
    if (isGuaranteedContiguousInquiryArg(ctx, args[0])) {
        return .{ .name = "1", .ty = .i1, .is_ptr = false };
    }
    if (try array_actuals.analyzeAddressableArrayActual(ctx, builder, args[0])) |actual| {
        return .{ .name = if (actual.contiguous) "1" else "0", .ty = .i1, .is_ptr = false };
    }
    return .{ .name = "1", .ty = .i1, .is_ptr = false };
}

pub fn emitIntrinsicInternalLiteralSubstring(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    const plan = (try dispatch.emitInternalLiteralSubstringPlan(ctx, builder, args)) orelse return error.UnsupportedIntrinsicType;
    return .{ .name = plan.ptr.name, .ty = .ptr, .is_ptr = false };
}
