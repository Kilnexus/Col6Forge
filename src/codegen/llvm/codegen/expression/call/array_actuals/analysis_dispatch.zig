const std = @import("std");
const ast = @import("../../../../../input.zig");
const context = @import("../../../context/mod.zig");
const common = @import("../../../common.zig");
const evaluator = @import("../../../../../../semantic/evaluator.zig");
const known_functions = @import("known_functions.zig");
const shared = @import("../shared.zig");

const Expr = shared.Expr;
const Context = shared.Context;
const ArrayActualPlan = shared.ArrayActualPlan;

pub fn evalConstIntArg(ctx: *Context, expr: *Expr) ?i64 {
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
    const count = common.arrayElementCount(ctx.sem, dims) catch return null;
    return std.math.cast(i64, count);
}

pub fn analyzeKnownArrayFunctionActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    comptime hooks: anytype,
) !?ArrayActualPlan {
    return known_functions.analyzeKnownArrayFunctionActual(ctx, builder, call, .{
        .resolveArrayActual = hooks.resolveArrayActual,
        .emitRequireSameArrayShape = hooks.emitRequireSameArrayShape,
        .emitExtentProductI64 = hooks.emitExtentProductI64,
        .emitHeapArrayTempPointer = hooks.emitHeapArrayTempPointer,
        .emitHeapArrayTempPointerScaled = hooks.emitHeapArrayTempPointerScaled,
        .emitContiguousMultipliers = hooks.emitContiguousMultipliers,
        .emitOwnedHeapArgFrees = hooks.emitOwnedHeapArgFrees,
        .emitMaybeFreeOwnedArrayActual = hooks.emitMaybeFreeOwnedArrayActual,
        .emitArrayActualElement = hooks.emitArrayActualElement,
        .materializeKnownActualDescriptor = hooks.materializeKnownActualDescriptor,
        .materializeActualDescriptor = hooks.materializeActualDescriptor,
        .emitCharacterLengthArg = hooks.emitCharacterLengthArg,
        .emitMulI64 = hooks.emitMulI64,
        .emitAddI64 = hooks.emitAddI64,
        .emitSubI64 = hooks.emitSubI64,
        .i64Const = hooks.i64Const,
    });
}

pub fn analyzeElementalArrayFunctionActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    comptime hooks: anytype,
) !?ArrayActualPlan {
    return known_functions.analyzeElementalArrayFunctionActual(ctx, builder, call, .{
        .resolveArrayActual = hooks.resolveArrayActual,
        .emitRequireSameArrayShape = hooks.emitRequireSameArrayShape,
        .emitExtentProductI64 = hooks.emitExtentProductI64,
        .emitHeapArrayTempPointer = hooks.emitHeapArrayTempPointer,
        .emitContiguousMultipliers = hooks.emitContiguousMultipliers,
        .emitMaybeFreeOwnedArrayActual = hooks.emitMaybeFreeOwnedArrayActual,
        .emitArrayActualElement = hooks.emitArrayActualElement,
        .emitMulI64 = hooks.emitMulI64,
        .emitAddI64 = hooks.emitAddI64,
        .emitSubI64 = hooks.emitSubI64,
        .i64Const = hooks.i64Const,
    });
}

pub fn analyzeKnownArrayProcedureComponentActual(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    component: context.DerivedComponentLayout,
    comptime hooks: anytype,
) !?ArrayActualPlan {
    return known_functions.analyzeKnownArrayProcedureComponentActual(ctx, builder, comp, component, .{
        .resolveArrayActual = hooks.resolveArrayActual,
        .emitExtentProductI64 = hooks.emitExtentProductI64,
        .emitHeapArrayTempPointer = hooks.emitHeapArrayTempPointer,
        .emitHeapArrayTempPointerScaled = hooks.emitHeapArrayTempPointerScaled,
        .emitContiguousMultipliers = hooks.emitContiguousMultipliers,
        .emitOwnedHeapArgFrees = hooks.emitOwnedHeapArgFrees,
        .materializeKnownActualDescriptor = hooks.materializeKnownActualDescriptor,
        .materializeActualDescriptor = hooks.materializeActualDescriptor,
        .emitCharacterLengthArg = hooks.emitCharacterLengthArg,
        .emitMulI64 = hooks.emitMulI64,
        .emitAddI64 = hooks.emitAddI64,
        .emitSubI64 = hooks.emitSubI64,
        .i64Const = hooks.i64Const,
    });
}

pub fn analyzeSingleItemArrayConstructorActual(
    ctx: *Context,
    builder: anytype,
    ctor: ast.ArrayConstructor,
    comptime hooks: anytype,
) !?ArrayActualPlan {
    if (ctor.items.len != 1) return null;
    if (ctor.items[0].* == .implied_do) return null;
    return try hooks.resolveArrayActual(ctx, builder, ctor.items[0]);
}
