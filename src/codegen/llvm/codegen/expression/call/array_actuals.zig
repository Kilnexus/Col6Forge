const std = @import("std");
const ast = @import("../../../../input.zig");
const context = @import("../../context/mod.zig");
const common = @import("../../common.zig");
const memory = @import("../memory.zig");
const dispatch = @import("../dispatch/mod.zig");
const resolution = @import("../dispatch/resolution.zig");
const binary = @import("../binary.zig");
const utils = @import("../../utils.zig");
const llvm_types = @import("../../../types.zig");
const casting = @import("../casting.zig");
const procedure_pass = @import("../../../../../common/procedure_pass.zig");
const flatten_core = @import("../../../stmts/execution/assignment/flatten/core.zig");
const flatten_metadata = @import("../../../stmts/execution/assignment/flatten/metadata.zig");
const flatten_mod = @import("../../../stmts/execution/assignment/flatten/mod.zig");
const character_buffers = @import("../../../shared/character_buffers.zig");
const array_shape_checks = @import("../../../shared/array_shape_checks.zig");
const io_utils = @import("../../../stmts/io/utils.zig");
const elemental_char_intrinsics = @import("elemental_char_intrinsics.zig");
const elemental_search_intrinsics = @import("elemental_search_intrinsics.zig");
const shared = @import("shared.zig");
const array_actuals_support = @import("array_actuals_support.zig");
const analysis_dispatch = @import("array_actuals/analysis_dispatch.zig");
const runtime_utils = @import("array_actuals/runtime_utils.zig");
const constructors = @import("array_actuals/constructors.zig");
const substrings = @import("array_actuals/substrings.zig");
const known_functions = @import("array_actuals/known_functions.zig");
const descriptors = @import("array_actuals/descriptors.zig");
const reductions_intrinsics = @import("array_actuals/intrinsics/reductions.zig");
const shape_intrinsics = @import("array_actuals/intrinsics/shape_ops.zig");
const transfer_intrinsics = @import("array_actuals/intrinsics/transfer.zig");
const numeric_unary_intrinsics = @import("array_actuals/intrinsics/numeric_unary.zig");
const Expr = shared.Expr;
const IRType = shared.IRType;
const Context = shared.Context;
const ValueRef = shared.ValueRef;
const ArgPointerResult = shared.ArgPointerResult;
const MaterializedDescriptor = shared.MaterializedDescriptor;
const ArrayActualPlan = shared.ArrayActualPlan;
const validatedArrayActual = shared.validatedArrayActual;
pub fn materializeActualDescriptor(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    arg_sig: ast.sema.KnownProcedureSig.ArgSig,
) !MaterializedDescriptor {
    if (arg_sig.rank == 0) return error.InvalidAbiState;
    const actual = (try resolveArrayActual(ctx, builder, expr)) orelse return error.NonArrayDescriptorActualArgument;
    return materializeKnownActualDescriptor(ctx, builder, actual, arg_sig);
}

pub fn materializeKnownActualDescriptor(ctx: *Context, builder: anytype, actual: ArrayActualPlan, arg_sig: ast.sema.KnownProcedureSig.ArgSig) !MaterializedDescriptor {
    return descriptors.materializeKnownActualDescriptor(ctx, builder, actual, arg_sig, i64Const);
}

pub fn emitMaterializedArrayExprActual(ctx: *Context, builder: anytype, expr: *Expr) !?ArgPointerResult {
    return switch (expr.*) {
        .binary => |bin| emitBinaryArrayExprActual(ctx, builder, expr, bin),
        .unary => |un| switch (un.op) {
            .plus => emitMaterializedArrayExprActual(ctx, builder, un.expr),
            .minus => emitNegatedArrayExprActual(ctx, builder, un.expr),
            else => null,
        },
        else => null,
    };
}

fn emitBinaryArrayExprActual(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    bin: ast.BinaryExpr,
) !?ArgPointerResult {
    switch (bin.op) {
        .add, .sub, .mul, .div, .eq, .ne, .lt, .le, .gt, .ge, .and_, .or_, .eqv, .neqv => {},
        else => return null,
    }

    const left_array = try resolveArrayActual(ctx, builder, bin.left);
    const right_array = try resolveArrayActual(ctx, builder, bin.right);
    if (left_array == null and right_array == null) return null;

    const result_actual = left_array orelse right_array.?;
    const scalar_operand_ty = switch (bin.op) {
        .eq, .ne, .lt, .le, .gt, .ge, .and_, .or_, .eqv, .neqv => result_actual.elem_ty,
        else => try casting.exprType(ctx, expr),
    };
    const left_value = if (left_array == null)
        try emitScalarArrayBinaryOperand(ctx, builder, bin.left, scalar_operand_ty)
    else
        null;
    const right_value = if (right_array == null)
        try emitScalarArrayBinaryOperand(ctx, builder, bin.right, scalar_operand_ty)
    else
        null;

    if (left_array != null and right_array != null) {
        if (left_array.?.extents.len != right_array.?.extents.len) return null;
        try emitRequireSameArrayShape(ctx, builder, left_array.?.extents, right_array.?.extents);
    } else if ((left_value == null and left_array == null) or (right_value == null and right_array == null)) {
        return null;
    }

    const result_ty: IRType = switch (bin.op) {
        .eq, .ne, .lt, .le, .gt, .ge, .and_, .or_, .eqv, .neqv => .i1,
        else => try casting.exprType(ctx, expr),
    };
    if (!isMaterializableArrayElementType(result_ty)) return null;

    const elem_count = try emitExtentProductI64(ctx, builder, result_actual.extents);
    const dst_ptr = try emitHeapArrayTempPointer(ctx, builder, result_ty, elem_count);
    const multipliers = try emitContiguousMultipliers(ctx, builder, result_actual.extents);

    try emitBinaryArrayActualLoop(
        ctx,
        builder,
        bin.op,
        left_array,
        left_value,
        right_array,
        right_value,
        dst_ptr,
        result_ty,
        elem_count,
    );
    try emitMaybeFreeOwnedArrayActual(ctx, builder, left_array);
    try emitMaybeFreeOwnedArrayActual(ctx, builder, right_array);

    return .{
        .ptr = dst_ptr,
        .owned_heap_ptr = dst_ptr,
        .descriptor_actual = try validatedArrayActual(.{
            .base_ptr = dst_ptr,
            .elem_ty = result_ty,
            .extents = result_actual.extents,
            .multipliers = multipliers,
            .address_scale = i64Const(ctx, 1),
            .storage = .materialized_temp,
            .owned_heap_ptr = dst_ptr,
            .contiguous = true,
        }),
    };
}

fn emitRequireSameArrayShape(
    ctx: *Context,
    builder: anytype,
    lhs_extents: []const ValueRef,
    rhs_extents: []const ValueRef,
) !void {
    return array_shape_checks.emitRequireEqualExtents(
        ctx,
        builder,
        lhs_extents,
        rhs_extents,
        error.InvalidAbiState,
        "array_shape_ok",
        "array_shape_fail",
    );
}

fn emitScalarArrayBinaryOperand(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    target_ty: IRType,
) !?ValueRef {
    if (target_ty == .i8) {
        if (dispatch.constantCharacterLenForExpr(ctx, expr)) |char_len| {
            if (char_len == 1) {
                const char_plan = (try dispatch.emitCharacterValuePlan(ctx, builder, expr)) orelse return null;
                const byte_name = try ctx.nextTemp();
                try builder.load(byte_name, .i8, char_plan.ptr);
                return .{ .name = byte_name, .ty = .i8, .is_ptr = false };
            }
        }
    }
    const scalar_raw = try dispatch.emitExpr(ctx, builder, expr);
    if (scalar_raw.ty == .ptr) return null;
    return if (scalar_raw.ty == target_ty) scalar_raw else try casting.coerce(ctx, builder, scalar_raw, target_ty);
}

fn emitNegatedArrayExprActual(ctx: *Context, builder: anytype, expr: *Expr) !?ArgPointerResult {
    const src_actual = (try resolveArrayActual(ctx, builder, expr)) orelse return null;
    if (!isNegatableArrayElementType(src_actual.elem_ty)) return null;

    const elem_count = try emitExtentProductI64(ctx, builder, src_actual.extents);
    const dst_ptr = try emitHeapArrayTempPointer(ctx, builder, src_actual.elem_ty, elem_count);
    const multipliers = try emitContiguousMultipliers(ctx, builder, src_actual.extents);
    try emitNegatedArrayActualLoop(
        ctx,
        builder,
        src_actual.base_ptr,
        src_actual.elem_ty,
        src_actual.extents,
        src_actual.multipliers,
        src_actual.address_scale,
        src_actual.contiguous,
        dst_ptr,
        elem_count,
    );
    try emitMaybeFreeOwnedArrayActual(ctx, builder, src_actual);
    return .{
        .ptr = dst_ptr,
        .owned_heap_ptr = dst_ptr,
        .descriptor_actual = try validatedArrayActual(.{
            .base_ptr = dst_ptr,
            .elem_ty = src_actual.elem_ty,
            .extents = src_actual.extents,
            .multipliers = multipliers,
            .address_scale = i64Const(ctx, 1),
            .storage = .materialized_temp,
            .owned_heap_ptr = dst_ptr,
            .contiguous = true,
        }),
    };
}

pub fn analyzeAddressableArrayActual(ctx: *Context, builder: anytype, expr: *Expr) anyerror!?ArrayActualPlan {
    return switch (expr.*) {
        .unary => |un| switch (un.op) {
            .plus => analyzeAddressableArrayActual(ctx, builder, un.expr),
            else => null,
        },
        .identifier => |name| blk: {
            const sym = ctx.findSymbol(name) orelse break :blk null;
            if (sym.dims.len == 0) break :blk null;
            const extents = try emitSymbolDimExtents(ctx, builder, sym);
            const multipliers = try emitSymbolDimMultipliers(ctx, builder, sym);
            break :blk try validatedArrayActual(.{
                .base_ptr = try ctx.getPointer(name),
                .elem_ty = common.symbolElementIRType(sym, ctx.options.target_layout),
                .extents = extents,
                .multipliers = multipliers,
                .address_scale = try actualAddressScaleForSymbol(ctx, builder, name, sym),
                .storage = .direct,
                .contiguous = true,
            });
        },
        .call_or_subscript => |call| blk: {
            var kind = ctx.ref_kinds.get(@as(usize, @intFromPtr(expr))) orelse .unknown;
            const sym_opt = ctx.findSymbol(call.name);
            if (kind == .unknown) {
                if (sym_opt) |sym| {
                    if (sym.dims.len > 0) {
                        kind = .subscript;
                    } else if (sym.is_external or sym.is_intrinsic or sym.kind == .function) {
                        kind = .call;
                    }
                } else if (ctx.lookupKnownProcedureSig(call.name) != null) {
                    kind = .call;
                }
            }
            if (kind == .call) {
                if (try shape_intrinsics.analyzeIntrinsicBoundsActual(ctx, builder, call, .{
                    .resolveArrayActual = resolveArrayActual,
                    .evalConstIntArg = evalConstIntArg,
                    .analyzeAddressableArrayActual = analyzeAddressableArrayActual,
                    .analyzeKnownArrayProcedureComponentActual = analyzeKnownArrayProcedureComponentActual,
                    .staticIntExprValue = constructors.staticIntExprValue,
                })) |actual| break :blk actual;
                if (try analyzeElementalArrayFunctionActual(ctx, builder, call)) |actual| break :blk actual;
                if (try analyzeKnownArrayFunctionActual(ctx, builder, call)) |actual| break :blk actual;
                break :blk null;
            }
            const sym = sym_opt orelse break :blk null;
            if (sym.dims.len == 0 or call.args.len != sym.dims.len) break :blk null;
            if (try analyzeVectorSubscriptActual(ctx, builder, sym, call)) |actual| break :blk actual;

            var section_rank: usize = 0;
            for (call.args) |arg| {
                if (arg.* == .dim_range) section_rank += 1;
            }
            if (section_rank == 0) break :blk null;

            const extents = try ctx.allocator.alloc(ValueRef, section_rank);
            const multipliers = try ctx.allocator.alloc(ValueRef, section_rank);
            var out_idx: usize = 0;
            for (call.args, 0..) |arg, idx| {
                if (arg.* != .dim_range) continue;
                const range = arg.dim_range;
                const lower = if (range.lower) |lower_expr|
                    try emitIndexI64(ctx, builder, lower_expr)
                else
                    try memory.emitSymbolDimLower(ctx, builder, sym, idx);
                const upper = try emitSectionUpperI64(ctx, builder, sym, idx, range);
                const step = if (range.stride) |step_expr|
                    try emitIndexI64(ctx, builder, step_expr)
                else
                    i64Const(ctx, 1);

                extents[out_idx] = try emitTripletCountI64(ctx, builder, lower, upper, step);
                const sym_multiplier = try memory.emitSymbolDimMultiplier(ctx, builder, sym, idx);
                multipliers[out_idx] = try emitMulI64(ctx, builder, sym_multiplier, step);
                out_idx += 1;
            }
            break :blk try validatedArrayActual(.{
                .base_ptr = try emitSectionBasePtr(ctx, builder, sym, call),
                .elem_ty = common.symbolElementIRType(sym, ctx.options.target_layout),
                .extents = extents,
                .multipliers = multipliers,
                .address_scale = try actualAddressScaleForSymbol(ctx, builder, call.name, sym),
                .storage = .direct,
                .contiguous = false,
            });
        },
        .component => |comp| blk: {
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse break :blk null;
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse break :blk null;
            if (component.procedure) {
                if (!comp.has_parens) break :blk null;
                if (try analyzeKnownArrayProcedureComponentActual(ctx, builder, comp, component)) |actual| break :blk actual;
                break :blk null;
            }
            if (try analyzeAddressableDataComponentArrayActual(ctx, builder, comp, component)) |actual| break :blk actual;
            break :blk null;
        },
        .substring => |sub| blk: {
            if (try substrings.lowerSubstringArraySectionToCall(ctx, sub)) |lowered_call| {
                var call_expr = ast.Expr{ .call_or_subscript = lowered_call };
                try ctx.ref_kinds.put(@as(usize, @intFromPtr(&call_expr)), .subscript);
                break :blk try analyzeAddressableArrayActual(ctx, builder, &call_expr);
            }
            if (try substrings.materializeCharacterSubstringSectionActual(ctx, builder, sub, .{
                .analyzeAddressableArrayActual = analyzeAddressableArrayActual,
                .emitIndexI64 = emitIndexI64,
                .emitSubI64 = emitSubI64,
                .emitExtentProductI64 = emitExtentProductI64,
                .emitHeapArrayTempPointerScaled = emitHeapArrayTempPointerScaled,
                .emitContiguousMultipliers = emitContiguousMultipliers,
                .emitArrayActualElementPtr = emitArrayActualElementPtr,
                .emitAddI64 = emitAddI64,
                .emitMaybeFreeOwnedArrayActual = emitMaybeFreeOwnedArrayActual,
                .i64Const = i64Const,
            })) |actual| break :blk actual;
            break :blk null;
        },
        else => null,
    };
}

fn analyzeAddressableDataComponentArrayActual(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    component: context.DerivedComponentLayout,
) !?ArrayActualPlan {
    if (component.type_spec.lowered_kind == .character) return null;
    if (component.dims.len == 0) {
        if (component.pointer or component.allocatable or component.type_spec.lowered_kind == .derived) return null;
        if (comp.has_parens or comp.args.len != 0) return null;

        const projected_view = try memory.emitProjectedComponentArrayView(ctx, builder, comp) orelse return null;
        const base_actual = (try resolveArrayActual(ctx, builder, comp.base)) orelse return null;
        if (!valueRefEquals(base_actual.address_scale, i64Const(ctx, 1))) return null;

        const elem_size = byteSizeForIRType(projected_view.elem_ty);
        if (elem_size == 0 or projected_view.stride_bytes == 0 or projected_view.stride_bytes % elem_size != 0) return null;
        const projected_scale: i64 = @intCast(projected_view.stride_bytes / elem_size);

        return try validatedArrayActual(.{
            .base_ptr = projected_view.base_ptr,
            .elem_ty = projected_view.elem_ty,
            .extents = base_actual.extents,
            .multipliers = base_actual.multipliers,
            .address_scale = i64Const(ctx, projected_scale),
            .storage = base_actual.storage,
            .owned_heap_ptr = base_actual.owned_heap_ptr,
            .contiguous = base_actual.contiguous and projected_scale == 1,
        });
    }
    if (!(component.pointer or component.allocatable)) {
        if (comp.args.len == 0) return null;
        if (comp.args.len != component.dims.len) return null;

        var section_rank: usize = 0;
        for (comp.args) |arg| {
            if (arg.* == .dim_range) section_rank += 1;
        }
        if (section_rank == 0) return null;

        const extents = try ctx.allocator.alloc(ValueRef, section_rank);
        const multipliers = try ctx.allocator.alloc(ValueRef, section_rank);
        var out_idx: usize = 0;
        for (comp.args, 0..) |arg, idx| {
            if (arg.* != .dim_range) continue;
            const range = arg.dim_range;
            const lower = if (range.lower) |lower_expr|
                try emitIndexI64(ctx, builder, lower_expr)
            else
                try memory.emitDimLower(ctx, builder, component.dims[idx]);
            const upper = try emitStaticComponentSectionUpperI64(ctx, builder, component, idx, range);
            const step = if (range.stride) |step_expr|
                try emitIndexI64(ctx, builder, step_expr)
            else
                i64Const(ctx, 1);
            extents[out_idx] = try emitTripletCountI64(ctx, builder, lower, upper, step);
            const multiplier = try emitStaticComponentDimMultiplier(ctx, builder, component.dims, idx);
            multipliers[out_idx] = try emitMulI64(ctx, builder, multiplier, step);
            out_idx += 1;
        }

        return .{
            .base_ptr = try emitStaticComponentSectionBasePtr(ctx, builder, comp, component),
            .elem_ty = llvm_types.typeFromKindWithLayout(component.type_spec.lowered_kind, ctx.options.target_layout),
            .extents = extents,
            .multipliers = multipliers,
            .address_scale = i64Const(ctx, 1),
            .storage = .direct,
            .contiguous = false,
        };
    }

    if (comp.args.len == 0) {
        return .{
            .base_ptr = try memory.emitLoadedComponentDataPtr(ctx, builder, comp),
            .elem_ty = llvm_types.typeFromKindWithLayout(component.type_spec.lowered_kind, ctx.options.target_layout),
            .extents = try emitComponentDimExtents(ctx, builder, comp, component.dims.len),
            .multipliers = try emitComponentDimMultipliers(ctx, builder, comp, component.dims.len),
            .address_scale = i64Const(ctx, 1),
            .storage = .direct,
            .contiguous = true,
        };
    }
    if (comp.args.len != component.dims.len) return null;

    var section_rank: usize = 0;
    for (comp.args) |arg| {
        if (arg.* == .dim_range) section_rank += 1;
    }
    if (section_rank == 0) return null;

    const extents = try ctx.allocator.alloc(ValueRef, section_rank);
    const multipliers = try ctx.allocator.alloc(ValueRef, section_rank);
    var out_idx: usize = 0;
    for (comp.args, 0..) |arg, idx| {
        if (arg.* != .dim_range) continue;
        const range = arg.dim_range;
        const lower = if (range.lower) |lower_expr|
            try emitIndexI64(ctx, builder, lower_expr)
        else
            try memory.emitComponentDimLower(ctx, builder, comp, idx);
        const upper = try emitComponentSectionUpperI64(ctx, builder, comp, idx, range);
        const step = if (range.stride) |step_expr|
            try emitIndexI64(ctx, builder, step_expr)
        else
            i64Const(ctx, 1);
        extents[out_idx] = try emitTripletCountI64(ctx, builder, lower, upper, step);
        const multiplier = try memory.emitComponentDimMultiplier(ctx, builder, comp, idx);
        multipliers[out_idx] = try emitMulI64(ctx, builder, multiplier, step);
        out_idx += 1;
    }

    return .{
        .base_ptr = try emitComponentSectionBasePtr(ctx, builder, comp),
        .elem_ty = llvm_types.typeFromKindWithLayout(component.type_spec.lowered_kind, ctx.options.target_layout),
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = i64Const(ctx, 1),
        .storage = .direct,
        .contiguous = false,
    };
}

fn emitStaticComponentSectionUpperI64(
    ctx: *Context,
    builder: anytype,
    component: context.DerivedComponentLayout,
    dim_index: usize,
    range: ast.DimRange,
) !ValueRef {
    if (range.assumed_shape or (range.upper.* == .literal and range.upper.literal.kind == .assumed_size)) {
        const lower = try memory.emitDimLower(ctx, builder, component.dims[dim_index]);
        const extent = try emitStaticComponentDimExtent(ctx, builder, component.dims[dim_index]);
        return try emitAddI64(ctx, builder, lower, try emitSubI64(ctx, builder, extent, i64Const(ctx, 1)));
    }
    return emitIndexI64(ctx, builder, range.upper);
}

fn emitStaticComponentDimExtent(
    ctx: *Context,
    builder: anytype,
    dim: *Expr,
) !ValueRef {
    var extent = try memory.emitDimValue(ctx, builder, dim);
    if (extent.ty != .i64) extent = try casting.coerce(ctx, builder, extent, .i64);
    return extent;
}

fn emitStaticComponentDimMultiplier(
    ctx: *Context,
    builder: anytype,
    dims: []*Expr,
    dim_index: usize,
) !ValueRef {
    var stride = i64Const(ctx, 1);
    var idx: usize = 0;
    while (idx < dim_index) : (idx += 1) {
        const extent = try emitStaticComponentDimExtent(ctx, builder, dims[idx]);
        stride = try emitMulI64(ctx, builder, stride, extent);
    }
    return stride;
}

fn emitStaticComponentSectionBasePtr(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    component: context.DerivedComponentLayout,
) !ValueRef {
    var offset = i64Const(ctx, 0);
    for (comp.args, 0..) |arg, idx| {
        const idx_val = if (arg.* == .dim_range)
            if (arg.dim_range.lower) |lower_expr|
                try emitIndexI64(ctx, builder, lower_expr)
            else
                try memory.emitDimLower(ctx, builder, component.dims[idx])
        else
            try emitIndexI64(ctx, builder, arg);

        const lower = try memory.emitDimLower(ctx, builder, component.dims[idx]);
        const idx_adj = try emitSubI64(ctx, builder, idx_val, lower);
        const stride = try emitStaticComponentDimMultiplier(ctx, builder, component.dims, idx);
        const term = try emitMulI64(ctx, builder, idx_adj, stride);
        offset = try emitAddI64(ctx, builder, offset, term);
    }

    if (component.elem_size != 1) {
        offset = try emitMulI64(ctx, builder, offset, i64Const(ctx, @intCast(component.elem_size)));
    }
    const base_ptr = try memory.emitComponentStoragePtr(ctx, builder, comp);
    const gep_name = try ctx.nextTemp();
    try builder.gep(gep_name, .i8, base_ptr, offset);
    return .{ .name = gep_name, .ty = .ptr, .is_ptr = true };
}

const VectorSubscriptArg = union(enum) {
    scalar: *Expr,
    vector: ArrayActualPlan,
};

fn analyzeVectorSubscriptActual(
    ctx: *Context,
    builder: anytype,
    sym: ast.sema.Symbol,
    call: ast.CallOrSubscript,
) !?ArrayActualPlan {
    var vector_rank: usize = 0;
    for (call.args) |arg| {
        if (arg.* == .dim_range) return null;
        if (isArrayValuedExpr(ctx, arg)) vector_rank += 1;
    }
    if (vector_rank == 0) return null;

    const args = try ctx.allocator.alloc(VectorSubscriptArg, call.args.len);
    const extents = try ctx.allocator.alloc(ValueRef, vector_rank);
    var out_idx: usize = 0;
    for (call.args, 0..) |arg, idx| {
        if (!isArrayValuedExpr(ctx, arg)) {
            args[idx] = .{ .scalar = arg };
            continue;
        }
        const vector_actual = (try resolveVectorSubscriptArgActual(ctx, builder, arg)) orelse return null;
        try vector_actual.validate();
        if (vector_actual.extents.len != 1) return null;
        extents[out_idx] = vector_actual.extents[0];
        out_idx += 1;
        args[idx] = .{ .vector = vector_actual };
    }

    const elem_ty = common.symbolElementIRType(sym, ctx.options.target_layout);
    const elem_count = try emitExtentProductI64(ctx, builder, extents);
    const dst_ptr = try emitHeapArrayTempPointer(ctx, builder, elem_ty, elem_count);
    const multipliers = try emitContiguousMultipliers(ctx, builder, extents);
    try emitVectorSubscriptMaterializationLoop(ctx, builder, sym, args, extents, dst_ptr, elem_ty, elem_count);

    for (args) |arg| {
        switch (arg) {
            .vector => |actual| try emitMaybeFreeOwnedArrayActual(ctx, builder, actual),
            .scalar => {},
        }
    }

    return .{
        .base_ptr = dst_ptr,
        .elem_ty = elem_ty,
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = try actualAddressScaleForSymbol(ctx, builder, call.name, sym),
        .storage = .materialized_temp,
        .owned_heap_ptr = dst_ptr,
        .contiguous = true,
    };
}

fn resolveVectorSubscriptArgActual(ctx: *Context, builder: anytype, expr: *Expr) !?ArrayActualPlan {
    if (try resolveArrayActual(ctx, builder, expr)) |actual| return actual;
    const flat_items = try flatten_core.flattenArrayValuedExprItems(ctx, expr) orelse return null;
    if (flat_items.len == 0) return null;

    const elem_ty = try casting.exprType(ctx, flat_items[0]);
    if (!isMaterializableArrayElementType(elem_ty)) return null;
    const base_ptr = try emitHeapArrayTempPointer(ctx, builder, elem_ty, i64Const(ctx, @intCast(flat_items.len)));
    for (flat_items, 0..) |item, idx| {
        const value = try dispatch.emitExpr(ctx, builder, item);
        const coerced = if (value.ty == elem_ty) value else try casting.coerce(ctx, builder, value, elem_ty);
        const elem_ptr_name = try ctx.nextTemp();
        try builder.gep(elem_ptr_name, elem_ty, base_ptr, i64Const(ctx, @intCast(idx)));
        try builder.store(coerced, .{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true });
    }

    const extents = try ctx.allocator.alloc(ValueRef, 1);
    extents[0] = i64Const(ctx, @intCast(flat_items.len));
    const multipliers = try ctx.allocator.alloc(ValueRef, 1);
    multipliers[0] = i64Const(ctx, 1);
    return .{
        .base_ptr = base_ptr,
        .elem_ty = elem_ty,
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = i64Const(ctx, 1),
        .storage = .materialized_temp,
        .owned_heap_ptr = base_ptr,
        .contiguous = true,
    };
}

fn emitVectorSubscriptMaterializationLoop(
    ctx: *Context,
    builder: anytype,
    sym: ast.sema.Symbol,
    args: []const VectorSubscriptArg,
    result_extents: []const ValueRef,
    dst_ptr: ValueRef,
    elem_ty: IRType,
    elem_count: ValueRef,
) !void {
    var base_ptr = try ctx.getPointer(sym.name);
    if (sym.is_pointer) {
        const loaded_name = try ctx.nextTemp();
        try builder.load(loaded_name, .ptr, base_ptr);
        base_ptr = .{ .name = loaded_name, .ty = .ptr, .is_ptr = true };
    }

    const loop_preheader = try ctx.nextLabel("vector_subscript_preheader");
    const loop_body = try ctx.nextLabel("vector_subscript_body");
    const loop_exit = try ctx.nextLabel("vector_subscript_exit");
    const idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(idx_ptr_name, .i64);
    const idx_ptr = ValueRef{ .name = idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(i64Const(ctx, 0), idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_preheader);
    const idx_name = try ctx.nextTemp();
    try builder.load(idx_name, .i64, idx_ptr);
    const idx_val = ValueRef{ .name = idx_name, .ty = .i64, .is_ptr = false };
    const cond_name = try ctx.nextTemp();
    try builder.compare(cond_name, "icmp", "slt", .i64, idx_val, elem_count);
    try builder.brCond(.{ .name = cond_name, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    const src_elem_ptr = try emitVectorSubscriptSourcePtr(ctx, builder, sym, base_ptr, elem_ty, args, result_extents, idx_val);
    const src_val_name = try ctx.nextTemp();
    try builder.load(src_val_name, elem_ty, src_elem_ptr);
    const dst_elem_ptr_name = try ctx.nextTemp();
    try builder.gep(dst_elem_ptr_name, elem_ty, dst_ptr, idx_val);
    try builder.store(.{ .name = src_val_name, .ty = elem_ty, .is_ptr = false }, .{ .name = dst_elem_ptr_name, .ty = .ptr, .is_ptr = true });

    const next_name = try ctx.nextTemp();
    try builder.binary(next_name, "add", .i64, idx_val, i64Const(ctx, 1));
    try builder.store(.{ .name = next_name, .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_exit);
}

fn emitVectorSubscriptSourcePtr(
    ctx: *Context,
    builder: anytype,
    sym: ast.sema.Symbol,
    base_ptr: ValueRef,
    elem_ty: IRType,
    args: []const VectorSubscriptArg,
    result_extents: []const ValueRef,
    linear_idx: ValueRef,
) !ValueRef {
    var remaining = linear_idx;
    var vector_dim_idx: usize = 0;
    var offset = i64Const(ctx, 0);

    for (args, 0..) |arg, src_dim_idx| {
        const subscript = switch (arg) {
            .scalar => |expr| try emitIndexI64(ctx, builder, expr),
            .vector => |actual| blk: {
                const coord = if (vector_dim_idx + 1 == result_extents.len)
                    remaining
                else blk2: {
                    const coord_tmp = try ctx.nextTemp();
                    try builder.binary(coord_tmp, "srem", .i64, remaining, result_extents[vector_dim_idx]);
                    const next_remaining_tmp = try ctx.nextTemp();
                    try builder.binary(next_remaining_tmp, "sdiv", .i64, remaining, result_extents[vector_dim_idx]);
                    remaining = .{ .name = next_remaining_tmp, .ty = .i64, .is_ptr = false };
                    break :blk2 ValueRef{ .name = coord_tmp, .ty = .i64, .is_ptr = false };
                };
                vector_dim_idx += 1;
                var value = try emitArrayActualElement(ctx, builder, coord, actual);
                if (value.ty != .i64) value = try casting.coerce(ctx, builder, value, .i64);
                break :blk value;
            },
        };
        const lb = try memory.emitSymbolDimLower(ctx, builder, sym, src_dim_idx);
        const idx_adj = try emitSubI64(ctx, builder, subscript, lb);
        const stride = try memory.emitSymbolDimMultiplier(ctx, builder, sym, src_dim_idx);
        const term = try emitMulI64(ctx, builder, idx_adj, stride);
        offset = try emitAddI64(ctx, builder, offset, term);
    }

    if (sym.isCharacter()) {
        offset = try emitMulI64(ctx, builder, offset, try actualAddressScaleForSymbol(ctx, builder, sym.name, sym));
    }
    const ptr_name = try ctx.nextTemp();
    try builder.gep(ptr_name, elem_ty, base_ptr, offset);
    return .{ .name = ptr_name, .ty = .ptr, .is_ptr = true };
}

fn analyzeKnownArrayFunctionActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
) !?ArrayActualPlan {
    return analysis_dispatch.analyzeKnownArrayFunctionActual(ctx, builder, call, .{
        .resolveArrayActual = resolveArrayActual,
        .emitRequireSameArrayShape = emitRequireSameArrayShape,
        .emitExtentProductI64 = emitExtentProductI64,
        .emitHeapArrayTempPointer = emitHeapArrayTempPointer,
        .emitHeapArrayTempPointerScaled = emitHeapArrayTempPointerScaled,
        .emitContiguousMultipliers = emitContiguousMultipliers,
        .emitOwnedHeapArgFrees = emitOwnedHeapArgFrees,
        .emitMaybeFreeOwnedArrayActual = emitMaybeFreeOwnedArrayActual,
        .emitArrayActualElement = emitArrayActualElement,
        .materializeKnownActualDescriptor = materializeKnownActualDescriptor,
        .materializeActualDescriptor = materializeActualDescriptor,
        .emitCharacterLengthArg = emitCharacterLengthArg,
        .emitMulI64 = emitMulI64,
        .emitAddI64 = emitAddI64,
        .emitSubI64 = emitSubI64,
        .i64Const = i64Const,
    });
}

fn analyzeElementalArrayFunctionActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
) !?ArrayActualPlan {
    return analysis_dispatch.analyzeElementalArrayFunctionActual(ctx, builder, call, .{
        .resolveArrayActual = resolveArrayActual,
        .emitRequireSameArrayShape = emitRequireSameArrayShape,
        .emitExtentProductI64 = emitExtentProductI64,
        .emitHeapArrayTempPointer = emitHeapArrayTempPointer,
        .emitContiguousMultipliers = emitContiguousMultipliers,
        .emitMaybeFreeOwnedArrayActual = emitMaybeFreeOwnedArrayActual,
        .emitArrayActualElement = emitArrayActualElement,
        .emitMulI64 = emitMulI64,
        .emitAddI64 = emitAddI64,
        .emitSubI64 = emitSubI64,
        .i64Const = i64Const,
    });
}

fn analyzeKnownArrayProcedureComponentActual(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    component: context.DerivedComponentLayout,
) !?ArrayActualPlan {
    return analysis_dispatch.analyzeKnownArrayProcedureComponentActual(ctx, builder, comp, component, .{
        .resolveArrayActual = resolveArrayActual,
        .emitExtentProductI64 = emitExtentProductI64,
        .emitHeapArrayTempPointer = emitHeapArrayTempPointer,
        .emitHeapArrayTempPointerScaled = emitHeapArrayTempPointerScaled,
        .emitContiguousMultipliers = emitContiguousMultipliers,
        .emitOwnedHeapArgFrees = emitOwnedHeapArgFrees,
        .materializeKnownActualDescriptor = materializeKnownActualDescriptor,
        .materializeActualDescriptor = materializeActualDescriptor,
        .emitCharacterLengthArg = emitCharacterLengthArg,
        .emitMulI64 = emitMulI64,
        .emitAddI64 = emitAddI64,
        .emitSubI64 = emitSubI64,
        .i64Const = i64Const,
    });
}

pub fn resolveArrayActual(ctx: *Context, builder: anytype, expr: *Expr) anyerror!?ArrayActualPlan {
    if (expr.* == .call_or_subscript and
        (std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "lbound") or std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "ubound")))
    {
        if (try shape_intrinsics.analyzeIntrinsicBoundsActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
            .evalConstIntArg = evalConstIntArg,
            .analyzeAddressableArrayActual = analyzeAddressableArrayActual,
            .analyzeKnownArrayProcedureComponentActual = analyzeKnownArrayProcedureComponentActual,
            .staticIntExprValue = constructors.staticIntExprValue,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
    }
    if (try analyzeAddressableArrayActual(ctx, builder, expr)) |actual| return try validatedArrayActual(actual);
    if (expr.* == .array_constructor) {
        if (try analysis_dispatch.analyzeSingleItemArrayConstructorActual(ctx, builder, expr.array_constructor, .{
            .resolveArrayActual = resolveArrayActual,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
        if (try constructors.analyzeStaticZeroSizedArrayConstructorActual(ctx, builder, expr.array_constructor)) |actual| {
            return try validatedArrayActual(actual);
        }
        if (try constructors.analyzeStaticMaterializedArrayConstructorActual(ctx, builder, expr.array_constructor)) |actual| {
            return try validatedArrayActual(actual);
        }
        if (try constructors.analyzeRuntimeGeneratedArrayConstructorActual(ctx, builder, expr.array_constructor)) |actual| {
            return try validatedArrayActual(actual);
        }
    }
    if (expr.* == .call_or_subscript and std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "merge")) {
        if (try reductions_intrinsics.analyzeIntrinsicMergeActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
            .emitRequireSameArrayShape = emitRequireSameArrayShape,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
    }
    if (expr.* == .call_or_subscript and std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "sum")) {
        if (try reductions_intrinsics.analyzeIntrinsicSumDimActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
            .evalConstIntArg = evalConstIntArg,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
    }
    if (expr.* == .call_or_subscript and std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "count")) {
        if (try reductions_intrinsics.analyzeIntrinsicCountDimActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
            .evalConstIntArg = evalConstIntArg,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
    }
    if (expr.* == .call_or_subscript and std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "reshape")) {
        if (try shape_intrinsics.analyzeIntrinsicReshapeActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
            .analyzeAddressableArrayActual = analyzeAddressableArrayActual,
            .analyzeKnownArrayProcedureComponentActual = analyzeKnownArrayProcedureComponentActual,
            .staticIntExprValue = constructors.staticIntExprValue,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
    }
    if (expr.* == .call_or_subscript and std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "transpose")) {
        if (try shape_intrinsics.analyzeIntrinsicTransposeActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
    }
    if (expr.* == .call_or_subscript and std.ascii.eqlIgnoreCase(expr.call_or_subscript.name, "transfer")) {
        if (try transfer_intrinsics.analyzeIntrinsicTransferActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
        return null;
    }
    if (expr.* == .call_or_subscript) {
        if (try elemental_search_intrinsics.analyzeElementalSearchArrayActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
            .emitRequireSameArrayShape = emitRequireSameArrayShape,
            .emitOwnedHeapActualFree = emitOwnedHeapActualFree,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
        if (try elemental_char_intrinsics.analyzeElementalCharCodeArrayActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
            .emitArrayActualElement = emitArrayActualElement,
            .emitOwnedHeapActualFree = emitOwnedHeapActualFree,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
        if (try numeric_unary_intrinsics.analyzeElementalUnaryFloatIntrinsicActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
            .emitArrayActualElement = emitArrayActualElement,
            .emitOwnedHeapActualFree = emitOwnedHeapActualFree,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
    }
    if (expr.* == .call_or_subscript and isIntrinsicArrayConversionArg(ctx, expr.call_or_subscript)) {
        if (try transfer_intrinsics.analyzeIntrinsicConversionActual(ctx, builder, expr.call_or_subscript, .{
            .resolveArrayActual = resolveArrayActual,
        })) |actual| {
            return try validatedArrayActual(actual);
        }
        return null;
    }
    if (try emitMaterializedArrayExprActual(ctx, builder, expr)) |materialized| {
        const actual = materialized.descriptor_actual orelse return null;
        return try validatedArrayActual(actual);
    }
    return null;
}
// Array constructor and symbol-dimension helpers now live in array_actuals/constructors.zig.
pub fn shapeSubjectExtents(ctx: *Context, builder: anytype, expr_node: *Expr) !?[]ValueRef {
    return runtime_utils.shapeSubjectExtents(ctx, builder, expr_node, .{
        .resolveArrayActual = resolveArrayActual,
        .analyzeAddressableArrayActual = analyzeAddressableArrayActual,
        .analyzeKnownArrayProcedureComponentActual = analyzeKnownArrayProcedureComponentActual,
    });
}
pub const emitOwnedHeapArgFrees = runtime_utils.emitOwnedHeapArgFrees;
pub const isCharacterActualArg = runtime_utils.isCharacterActualArg;
pub const emitCharacterLengthArg = runtime_utils.emitCharacterLengthArg;
pub const allocaCharBuffer = runtime_utils.allocaCharBuffer;
pub fn emitIntrinsicArrayConversionArgPointer(ctx: *Context, builder: anytype, call: ast.CallOrSubscript) !ArgPointerResult {
    return runtime_utils.emitIntrinsicArrayConversionArgPointer(ctx, builder, call, .{
        .resolveArrayActual = resolveArrayActual,
    });
}

pub const emitMulI64 = array_actuals_support.emitMulI64;
const emitAddI64 = array_actuals_support.emitAddI64;
const emitSubI64 = array_actuals_support.emitSubI64;
pub const emitSectionBasePtr = array_actuals_support.emitSectionBasePtr;
const emitSectionUpperI64 = array_actuals_support.emitSectionUpperI64;
const emitTripletCountI64 = array_actuals_support.emitTripletCountI64;
pub const emitRequireEqualI64 = array_actuals_support.emitRequireEqualI64;
const emitComponentDimExtents = array_actuals_support.emitComponentDimExtents;
const emitComponentDimMultipliers = array_actuals_support.emitComponentDimMultipliers;
const emitComponentSectionBasePtr = array_actuals_support.emitComponentSectionBasePtr;
const emitComponentSectionUpperI64 = array_actuals_support.emitComponentSectionUpperI64;
pub const emitExtentProductI64 = array_actuals_support.emitExtentProductI64;
const emitContiguousMultipliers = array_actuals_support.emitContiguousMultipliers;
const emitSymbolDimExtents = constructors.emitSymbolDimExtents;
const emitSymbolDimMultipliers = constructors.emitSymbolDimMultipliers;
const emitIntrinsicArrayConversionLoop = array_actuals_support.emitIntrinsicArrayConversionLoop;
const emitMemcpyBytes = array_actuals_support.emitMemcpyBytes;
const emitMemsetByte = array_actuals_support.emitMemsetByte;
const emitMinI64 = array_actuals_support.emitMinI64;
const isNegatableArrayElementType = array_actuals_support.isNegatableArrayElementType;
const isMaterializableArrayElementType = array_actuals_support.isMaterializableArrayElementType;
const emitBinaryArrayActualLoop = array_actuals_support.emitBinaryArrayActualLoop;
pub const emitArrayActualElement = array_actuals_support.emitArrayActualElement;
pub const emitArrayActualElementPtr = array_actuals_support.emitArrayActualElementPtr;
const emitNegatedArrayActualLoop = array_actuals_support.emitNegatedArrayActualLoop;
const actualAddressScaleForSymbol = array_actuals_support.actualAddressScaleForSymbol;
pub const isIntrinsicArrayConversionArg = array_actuals_support.isIntrinsicArrayConversionArg;
pub const unpackComplexF32Return = array_actuals_support.unpackComplexF32Return;
const evalConstIntArg = analysis_dispatch.evalConstIntArg;
const emitIndexI64 = array_actuals_support.emitIndexI64;
const isArrayValuedExpr = array_actuals_support.isArrayValuedExpr;
const i64Const = array_actuals_support.i64Const;
const i1Const = array_actuals_support.i1Const;
pub const valueRefEquals = array_actuals_support.valueRefEquals;
const byteSizeForIRType = array_actuals_support.byteSizeForIRType;
const emitHeapArrayTempPointer = array_actuals_support.emitHeapArrayTempPointer;
const emitHeapArrayTempPointerScaled = array_actuals_support.emitHeapArrayTempPointerScaled;
const emitHeapAllocBytes = array_actuals_support.emitHeapAllocBytes;
const emitMaybeFreeOwnedArrayActual = array_actuals_support.emitMaybeFreeOwnedArrayActual;
pub const emitOwnedHeapActualFree = array_actuals_support.emitOwnedHeapActualFree;
