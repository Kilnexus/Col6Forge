const std = @import("std");
const ast = @import("../../../../../input.zig");
const context = @import("../../../context/mod.zig");
const common = @import("../../../common.zig");
const memory = @import("../../memory.zig");
const dispatch = @import("../../dispatch/mod.zig");
const resolution = @import("../../dispatch/resolution.zig");
const llvm_types = @import("../../../../types.zig");
const casting = @import("../../casting.zig");
const procedure_pass = @import("../../../../../../common/procedure_pass.zig");
const shared = @import("../shared.zig");

const Expr = shared.Expr;
const IRType = shared.IRType;
const Context = shared.Context;
const ValueRef = shared.ValueRef;
const ArgPointerResult = shared.ArgPointerResult;
const ArrayActualPlan = shared.ArrayActualPlan;
const validatedArrayActual = shared.validatedArrayActual;

pub fn analyzeKnownArrayFunctionActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    comptime hooks: anytype,
) !?ArrayActualPlan {
    const sig = ctx.lookupKnownProcedureSig(call.name) orelse return null;
    if (sig.result_rank == 0) return null;
    const result_spec = sig.result_type_spec orelse return null;
    if (sig.is_pointer or sig.result_allocatable) {
        return try analyzeKnownDynamicArrayFunctionActual(ctx, builder, call, sig, result_spec, hooks);
    }

    const extents = try materializeKnownArrayResultExtents(ctx, builder, sig, call.args, hooks) orelse return null;
    const result_storage = try knownArrayResultStorageInfo(ctx, result_spec, hooks);
    const elem_count = try hooks.emitExtentProductI64(ctx, builder, extents);
    const result_ptr = try hooks.emitHeapArrayTempPointerScaled(ctx, builder, result_storage.elem_ty, elem_count, result_storage.address_scale);

    var abi_args = std.array_list.Managed(ValueRef).init(ctx.allocator);
    defer abi_args.deinit();
    var owned_heap_args = std.array_list.Managed(ValueRef).init(ctx.allocator);
    defer owned_heap_args.deinit();
    try abi_args.append(result_ptr);
    try appendKnownArrayProcedureCallArgs(
        ctx,
        builder,
        &abi_args,
        &owned_heap_args,
        call.args,
        sig,
        result_storage.abi_char_len,
        hooks,
    );

    const fn_name = try resolution.ensureExternalDeclForCall(ctx, call.name, .void, call.args, result_storage.abi_char_len != null);
    try builder.callTyped(null, .void, fn_name, abi_args.items);
    try hooks.emitOwnedHeapArgFrees(ctx, builder, owned_heap_args.items);

    return try validatedArrayActual(.{
        .base_ptr = result_ptr,
        .elem_ty = result_storage.elem_ty,
        .extents = extents,
        .multipliers = try hooks.emitContiguousMultipliers(ctx, builder, extents),
        .address_scale = result_storage.address_scale,
        .storage = .materialized_temp,
        .owned_heap_ptr = result_ptr,
        .contiguous = true,
    });
}

fn analyzeKnownDynamicArrayFunctionActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    sig: ast.sema.KnownProcedureSig,
    result_spec: ast.TypeSpec,
    comptime hooks: anytype,
) !?ArrayActualPlan {
    if (sig.result_rank == 0) return null;

    const result_storage = try knownArrayResultStorageInfo(ctx, result_spec, hooks);
    const result_slot_name = try ctx.nextTemp();
    try builder.alloca(result_slot_name, .ptr);
    const result_slot = ValueRef{ .name = result_slot_name, .ty = .ptr, .is_ptr = true };
    try builder.store(.{ .name = "null", .ty = .ptr, .is_ptr = false }, result_slot);

    const extent_base_name = try ctx.nextTemp();
    if (sig.result_rank == 1) {
        try builder.alloca(extent_base_name, .i64);
    } else {
        try builder.allocaArray(extent_base_name, .i64, sig.result_rank);
    }
    const extent_base = ValueRef{ .name = extent_base_name, .ty = .ptr, .is_ptr = true };

    const multiplier_base_name = try ctx.nextTemp();
    if (sig.result_rank == 1) {
        try builder.alloca(multiplier_base_name, .i64);
    } else {
        try builder.allocaArray(multiplier_base_name, .i64, sig.result_rank);
    }
    const multiplier_base = ValueRef{ .name = multiplier_base_name, .ty = .ptr, .is_ptr = true };

    for (0..sig.result_rank) |idx| {
        const offset = hooks.i64Const(ctx, @intCast(idx));

        const extent_ptr_name = try ctx.nextTemp();
        try builder.gep(extent_ptr_name, .i64, extent_base, offset);
        try builder.store(hooks.i64Const(ctx, 0), .{ .name = extent_ptr_name, .ty = .ptr, .is_ptr = true });

        const multiplier_ptr_name = try ctx.nextTemp();
        try builder.gep(multiplier_ptr_name, .i64, multiplier_base, offset);
        try builder.store(hooks.i64Const(ctx, if (idx == 0) 1 else 0), .{ .name = multiplier_ptr_name, .ty = .ptr, .is_ptr = true });
    }

    var abi_args = std.array_list.Managed(ValueRef).init(ctx.allocator);
    defer abi_args.deinit();
    var owned_heap_args = std.array_list.Managed(ValueRef).init(ctx.allocator);
    defer owned_heap_args.deinit();
    try abi_args.append(result_slot);
    try abi_args.append(extent_base);
    try abi_args.append(multiplier_base);
    try appendKnownArrayProcedureCallArgs(
        ctx,
        builder,
        &abi_args,
        &owned_heap_args,
        call.args,
        sig,
        result_storage.abi_char_len,
        hooks,
    );

    const fn_name = try resolution.ensureExternalDeclForCall(ctx, call.name, .ptr, call.args, result_storage.abi_char_len != null);
    try builder.callTyped(null, .void, fn_name, abi_args.items);
    try hooks.emitOwnedHeapArgFrees(ctx, builder, owned_heap_args.items);

    const loaded_result_name = try ctx.nextTemp();
    try builder.load(loaded_result_name, .ptr, result_slot);
    const result_ptr = ValueRef{ .name = loaded_result_name, .ty = .ptr, .is_ptr = true };

    const extents = try ctx.allocator.alloc(ValueRef, sig.result_rank);
    const multipliers = try ctx.allocator.alloc(ValueRef, sig.result_rank);
    for (0..sig.result_rank) |idx| {
        const offset = hooks.i64Const(ctx, @intCast(idx));

        const extent_ptr_name = try ctx.nextTemp();
        try builder.gep(extent_ptr_name, .i64, extent_base, offset);
        const extent_name = try ctx.nextTemp();
        try builder.load(extent_name, .i64, .{ .name = extent_ptr_name, .ty = .ptr, .is_ptr = true });
        extents[idx] = .{ .name = extent_name, .ty = .i64, .is_ptr = false };

        const multiplier_ptr_name = try ctx.nextTemp();
        try builder.gep(multiplier_ptr_name, .i64, multiplier_base, offset);
        const multiplier_name = try ctx.nextTemp();
        try builder.load(multiplier_name, .i64, .{ .name = multiplier_ptr_name, .ty = .ptr, .is_ptr = true });
        multipliers[idx] = .{ .name = multiplier_name, .ty = .i64, .is_ptr = false };
    }

    return try validatedArrayActual(.{
        .base_ptr = result_ptr,
        .elem_ty = result_storage.elem_ty,
        .extents = extents,
        .multipliers = multipliers,
        .address_scale = result_storage.address_scale,
        .storage = .materialized_temp,
        .owned_heap_ptr = if (sig.result_allocatable) result_ptr else null,
        .contiguous = true,
    });
}

pub fn analyzeElementalArrayFunctionActual(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    comptime hooks: anytype,
) !?ArrayActualPlan {
    const sig = ctx.lookupKnownProcedureSig(call.name) orelse return null;
    if (!sig.elemental or sig.result_rank != 0) return null;
    const result_spec = sig.result_type_spec orelse return null;
    if (result_spec.lowered_kind == .character) return null;

    var basis: ?ArrayActualPlan = null;
    var array_arg_count: usize = 0;
    for (call.args) |arg| {
        if (try hooks.resolveArrayActual(ctx, builder, arg)) |actual| {
            try actual.validate();
            if (actual.extents.len == 0) return null;
            if (basis) |base_actual| {
                if (base_actual.extents.len != actual.extents.len) return null;
                try hooks.emitRequireSameArrayShape(ctx, builder, base_actual.extents, actual.extents);
            } else {
                basis = actual;
            }
            array_arg_count += 1;
        }
    }
    const result_basis = basis orelse return null;
    if (array_arg_count == 0) return null;

    for (sig.args) |arg_sig| {
        if (arg_sig.requires_descriptor or arg_sig.rank != 0 or arg_sig.pointer or arg_sig.allocatable or arg_sig.is_procedure or arg_sig.type_spec.lowered_kind == .character or arg_sig.type_spec.lowered_kind == .derived or arg_sig.value_attr) {
            return null;
        }
    }

    const elem_ty = storageIRTypeForProcedureResult(ctx, result_spec);
    if (ctx.abiUsesHiddenResultPtr(elem_ty)) return null;
    const elem_count = try hooks.emitExtentProductI64(ctx, builder, result_basis.extents);
    const result_ptr = try hooks.emitHeapArrayTempPointer(ctx, builder, elem_ty, elem_count);
    const multipliers = try hooks.emitContiguousMultipliers(ctx, builder, result_basis.extents);
    const fn_name = try resolution.ensureExternalDeclForCall(ctx, call.name, elem_ty, call.args, false);

    try emitElementalArrayFunctionLoop(ctx, builder, call, sig, fn_name, result_ptr, elem_ty, elem_count, hooks);
    for (call.args) |arg| {
        if (try hooks.resolveArrayActual(ctx, builder, arg)) |actual| {
            try hooks.emitMaybeFreeOwnedArrayActual(ctx, builder, actual);
        }
    }

    return try validatedArrayActual(.{
        .base_ptr = result_ptr,
        .elem_ty = elem_ty,
        .extents = result_basis.extents,
        .multipliers = multipliers,
        .address_scale = hooks.i64Const(ctx, 1),
        .storage = .materialized_temp,
        .owned_heap_ptr = result_ptr,
        .contiguous = true,
    });
}

fn emitElementalArrayFunctionLoop(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    sig: ast.sema.KnownProcedureSig,
    fn_name: []const u8,
    result_ptr: ValueRef,
    elem_ty: IRType,
    elem_count: ValueRef,
    comptime hooks: anytype,
) !void {
    const abi_ret_ty = ctx.abiFunctionReturnType(elem_ty);
    const loop_preheader = try ctx.nextLabel("elemental_array_call_preheader");
    const loop_body = try ctx.nextLabel("elemental_array_call_body");
    const loop_exit = try ctx.nextLabel("elemental_array_call_exit");
    const idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(idx_ptr_name, .i64);
    const idx_ptr = ValueRef{ .name = idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(hooks.i64Const(ctx, 0), idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_preheader);
    const idx_name = try ctx.nextTemp();
    try builder.load(idx_name, .i64, idx_ptr);
    const idx_val = ValueRef{ .name = idx_name, .ty = .i64, .is_ptr = false };
    const cond_name = try ctx.nextTemp();
    try builder.compare(cond_name, "icmp", "slt", .i64, idx_val, elem_count);
    try builder.brCond(.{ .name = cond_name, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    var abi_args = std.array_list.Managed(ValueRef).init(ctx.allocator);
    defer abi_args.deinit();
    for (call.args, 0..) |arg, idx| {
        const value = if (try hooks.resolveArrayActual(ctx, builder, arg)) |actual|
            try hooks.emitArrayActualElement(ctx, builder, idx_val, actual)
        else
            try dispatch.emitExpr(ctx, builder, arg);
        try abi_args.append(try emitScalarAbiArgPointer(ctx, builder, value, if (idx < sig.args.len) sig.args[idx].type_spec.lowered_kind == .logical else value.ty == .i1));
    }
    const call_tmp = try ctx.nextTemp();
    try builder.callTyped(call_tmp, abi_ret_ty, fn_name, abi_args.items);
    const scalar_result = if (abi_ret_ty == elem_ty)
        ValueRef{ .name = call_tmp, .ty = elem_ty, .is_ptr = false }
    else
        try casting.coerce(ctx, builder, .{ .name = call_tmp, .ty = abi_ret_ty, .is_ptr = false }, elem_ty);
    const dst_elem_ptr_name = try ctx.nextTemp();
    try builder.gep(dst_elem_ptr_name, elem_ty, result_ptr, idx_val);
    try builder.store(scalar_result, .{ .name = dst_elem_ptr_name, .ty = .ptr, .is_ptr = true });

    const next_name = try ctx.nextTemp();
    try builder.binary(next_name, "add", .i64, idx_val, hooks.i64Const(ctx, 1));
    try builder.store(.{ .name = next_name, .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_preheader);

    try builder.label(loop_exit);
}

fn emitScalarAbiArgPointer(ctx: *Context, builder: anytype, value: ValueRef, logical_arg: bool) !ValueRef {
    if (value.ty == .ptr) return value;
    const alloc_ty = if (logical_arg or value.ty == .i1) ctx.defaultIntegerIRType() else value.ty;
    const tmp = try ctx.nextTemp();
    try builder.alloca(tmp, alloc_ty);
    const ptr = ValueRef{ .name = tmp, .ty = .ptr, .is_ptr = true };
    const stored = if (alloc_ty == value.ty) value else try casting.coerce(ctx, builder, value, alloc_ty);
    try builder.store(stored, ptr);
    return ptr;
}

pub fn analyzeKnownArrayProcedureComponentActual(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    component: context.DerivedComponentLayout,
    comptime hooks: anytype,
) !?ArrayActualPlan {
    const proc_sig = component.procedure_sig orelse return null;
    if (proc_sig.result_rank == 0) return null;
    const result_spec = proc_sig.result_type_spec orelse return null;

    const actuals = try buildProcedureComponentArrayActuals(ctx, comp, component, proc_sig);
    defer ctx.allocator.free(actuals);
    const extents = try materializeKnownArrayResultExtents(ctx, builder, proc_sig, actuals, hooks) orelse return null;
    const result_storage = try knownArrayResultStorageInfo(ctx, result_spec, hooks);
    const elem_count = try hooks.emitExtentProductI64(ctx, builder, extents);
    const result_ptr = try hooks.emitHeapArrayTempPointerScaled(ctx, builder, result_storage.elem_ty, elem_count, result_storage.address_scale);

    var abi_args = std.array_list.Managed(ValueRef).init(ctx.allocator);
    defer abi_args.deinit();
    var owned_heap_args = std.array_list.Managed(ValueRef).init(ctx.allocator);
    defer owned_heap_args.deinit();
    try abi_args.append(result_ptr);
    try appendKnownArrayProcedureCallArgs(
        ctx,
        builder,
        &abi_args,
        &owned_heap_args,
        actuals,
        proc_sig,
        result_storage.abi_char_len,
        hooks,
    );

    const slot_ptr = try memory.emitComponentStoragePtr(ctx, builder, .{
        .base = comp.base,
        .name = comp.name,
        .args = &.{},
        .has_parens = false,
    });
    const fn_ptr_name = try ctx.nextTemp();
    try builder.load(fn_ptr_name, .ptr, slot_ptr);
    try builder.callIndirectTyped(null, .void, fn_ptr_name, abi_args.items);
    try hooks.emitOwnedHeapArgFrees(ctx, builder, owned_heap_args.items);

    return try validatedArrayActual(.{
        .base_ptr = result_ptr,
        .elem_ty = result_storage.elem_ty,
        .extents = extents,
        .multipliers = try hooks.emitContiguousMultipliers(ctx, builder, extents),
        .address_scale = result_storage.address_scale,
        .storage = .materialized_temp,
        .owned_heap_ptr = result_ptr,
        .contiguous = true,
    });
}

const ArrayResultStorageInfo = struct {
    elem_ty: IRType,
    address_scale: ValueRef,
    abi_char_len: ?ValueRef = null,
};

fn knownArrayResultStorageInfo(
    ctx: *Context,
    result_spec: ast.TypeSpec,
    comptime hooks: anytype,
) !ArrayResultStorageInfo {
    if (result_spec.lowered_kind == .character) {
        const char_len = result_spec.char_len orelse 1;
        return .{
            .elem_ty = .i8,
            .address_scale = hooks.i64Const(ctx, @intCast(char_len)),
            .abi_char_len = try ctx.abiCharacterLenConst(@intCast(char_len)),
        };
    }
    if (result_spec.lowered_kind == .derived) {
        const derived_name = result_spec.derived_type_name orelse return error.UnknownSymbol;
        const layout = ctx.findDerivedTypeLayout(derived_name) orelse return error.UnknownSymbol;
        return .{
            .elem_ty = .i8,
            .address_scale = hooks.i64Const(ctx, @intCast(layout.size)),
        };
    }
    return .{
        .elem_ty = storageIRTypeForProcedureResult(ctx, result_spec),
        .address_scale = hooks.i64Const(ctx, 1),
    };
}

fn appendKnownArrayProcedureCallArgs(
    ctx: *Context,
    builder: anytype,
    abi_args: *std.array_list.Managed(ValueRef),
    owned_heap_args: *std.array_list.Managed(ValueRef),
    args: []*Expr,
    sig: ast.sema.KnownProcedureSig,
    result_len: ?ValueRef,
    comptime hooks: anytype,
) !void {
    var resolved_args = std.array_list.Managed(ArgPointerResult).init(ctx.allocator);
    defer resolved_args.deinit();

    for (args) |arg| {
        const resolved = try emitKnownArrayFunctionArgPointer(ctx, builder, arg, hooks);
        try resolved_args.append(resolved);
        try abi_args.append(resolved.ptr);
        if (resolved.owned_heap_ptr) |heap_ptr| {
            try owned_heap_args.append(heap_ptr);
        }
    }
    for (args, 0..) |arg, idx| {
        if (idx >= sig.args.len or !sig.args[idx].requires_descriptor) continue;
        const desc = if (resolved_args.items[idx].descriptor_actual) |actual|
            try hooks.materializeKnownActualDescriptor(ctx, builder, actual, sig.args[idx])
        else
            try hooks.materializeActualDescriptor(ctx, builder, arg, sig.args[idx]);
        try abi_args.append(desc.extent_ptr);
        try abi_args.append(desc.multiplier_ptr);
    }
    if (result_len) |len_val| {
        try abi_args.append(len_val);
    }
    for (args) |arg| {
        if (try hooks.emitCharacterLengthArg(ctx, builder, arg)) |len_val| {
            try abi_args.append(len_val);
        }
    }
}

fn emitKnownArrayFunctionArgPointer(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    comptime hooks: anytype,
) !ArgPointerResult {
    if (try hooks.resolveArrayActual(ctx, builder, expr)) |actual| {
        return .{ .ptr = actual.base_ptr, .owned_heap_ptr = actual.owned_heap_ptr, .descriptor_actual = actual };
    }
    if (try dispatch.emitCharacterValuePlan(ctx, builder, expr)) |char_value| {
        return .{ .ptr = char_value.ptr };
    }

    const value = try dispatch.emitExpr(ctx, builder, expr);
    if (value.ty == .ptr) {
        return .{ .ptr = .{ .name = value.name, .ty = .ptr, .is_ptr = true } };
    }
    const alloc_ty = if (value.ty == .i1) ctx.defaultIntegerIRType() else value.ty;
    const tmp = try ctx.nextTemp();
    try builder.alloca(tmp, alloc_ty);
    const ptr = ValueRef{ .name = tmp, .ty = .ptr, .is_ptr = true };
    const stored = if (alloc_ty == value.ty) value else try casting.coerce(ctx, builder, value, alloc_ty);
    try builder.store(stored, ptr);
    return .{ .ptr = ptr };
}

fn materializeKnownArrayResultExtents(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    comptime hooks: anytype,
) !?[]ValueRef {
    if (sig.result_shape_signature.len == 0) return null;
    const extents = try ctx.allocator.alloc(ValueRef, sig.result_shape_signature.len);
    for (sig.result_shape_signature, 0..) |shape, idx| {
        if (std.fmt.parseInt(i64, shape, 10)) |parsed| {
            extents[idx] = hooks.i64Const(ctx, parsed);
            continue;
        } else |_| {}

        if (parseSizeShapeRef(shape)) |size_ref| {
            extents[idx] = (try emitKnownShapeDesignatorDimExtent(ctx, builder, sig, args, size_ref.designator, size_ref.dim_index, hooks)) orelse return null;
            continue;
        }

        extents[idx] = (try emitKnownShapeExprExtent(ctx, builder, sig, args, shape, hooks)) orelse return null;
    }
    return extents;
}

const SizeShapeRef = struct {
    designator: []const u8,
    dim_index: usize,
};

fn parseSizeShapeRef(shape: []const u8) ?SizeShapeRef {
    const trimmed = std.mem.trim(u8, shape, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "size(") or trimmed.len < 8) return null;
    if (trimmed[trimmed.len - 1] != ')') return null;
    const inner = trimmed[5 .. trimmed.len - 1];
    const comma = std.mem.lastIndexOfScalar(u8, inner, ',') orelse return null;
    const designator = std.mem.trim(u8, inner[0..comma], " \t");
    const dim_text = std.mem.trim(u8, inner[comma + 1 ..], " \t");
    const dim = std.fmt.parseInt(usize, dim_text, 10) catch return null;
    if (designator.len == 0 or dim == 0) return null;
    return .{ .designator = designator, .dim_index = dim - 1 };
}

fn procedureArgIndex(sig: ast.sema.KnownProcedureSig, name: []const u8) ?usize {
    for (sig.args, 0..) |arg, idx| {
        if (std.ascii.eqlIgnoreCase(arg.name, name)) return idx;
    }
    return null;
}

fn emitKnownActualDimExtent(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    dim_index: usize,
    comptime hooks: anytype,
) !ValueRef {
    const actual = (try hooks.resolveArrayActual(ctx, builder, expr)) orelse return error.UnsupportedIntrinsicType;
    try actual.validate();
    if (dim_index >= actual.extents.len) return error.InvalidIntrinsicCall;
    return actual.extents[dim_index];
}

fn emitKnownShapeDesignatorDimExtent(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    designator: []const u8,
    dim_index: usize,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    const actual_expr = (try buildKnownShapeDesignatorExpr(ctx, sig, args, designator)) orelse return null;
    return try emitKnownActualDimExtent(ctx, builder, actual_expr, dim_index, hooks);
}

fn buildKnownShapeDesignatorExpr(
    ctx: *Context,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    designator: []const u8,
) !?*Expr {
    var parts = std.mem.splitScalar(u8, designator, '%');
    const root_raw = parts.next() orelse return null;
    const root = std.mem.trim(u8, root_raw, " \t");
    if (root.len == 0) return null;

    var current: *Expr = blk: {
        if (procedureArgIndex(sig, root)) |actual_idx| {
            if (actual_idx >= args.len) return null;
            break :blk args[actual_idx];
        }
        if (ctx.findSymbol(root) == null) return null;
        const ident = try ctx.allocator.create(ast.Expr);
        ident.* = .{ .identifier = root };
        break :blk ident;
    };

    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) return null;
        const node = try ctx.allocator.create(ast.Expr);
        node.* = .{ .component = .{
            .base = current,
            .name = part,
            .args = &.{},
            .has_parens = false,
        } };
        current = node;
    }

    return current;
}

const ShapeExprParser = struct {
    text: []const u8,
    index: usize = 0,

    fn skipSpaces(self: *ShapeExprParser) void {
        while (self.index < self.text.len and std.ascii.isWhitespace(self.text[self.index])) : (self.index += 1) {}
    }

    fn consume(self: *ShapeExprParser, ch: u8) bool {
        self.skipSpaces();
        if (self.index >= self.text.len or self.text[self.index] != ch) return false;
        self.index += 1;
        return true;
    }

    fn parseIdentifier(self: *ShapeExprParser) ?[]const u8 {
        self.skipSpaces();
        if (self.index >= self.text.len) return null;
        const start = self.index;
        const first = self.text[self.index];
        if (!std.ascii.isAlphabetic(first) and first != '_') return null;
        self.index += 1;
        while (self.index < self.text.len) : (self.index += 1) {
            const ch = self.text[self.index];
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') break;
        }
        return self.text[start..self.index];
    }

    fn parseDesignator(self: *ShapeExprParser) ?[]const u8 {
        self.skipSpaces();
        const start = self.index;
        _ = self.parseIdentifier() orelse return null;
        while (true) {
            const saved = self.index;
            if (!self.consume('%')) break;
            _ = self.parseIdentifier() orelse {
                self.index = saved;
                return null;
            };
        }
        return self.text[start..self.index];
    }

    fn parseInteger(self: *ShapeExprParser) ?i64 {
        self.skipSpaces();
        if (self.index >= self.text.len) return null;
        const start = self.index;
        if (self.text[self.index] == '+' or self.text[self.index] == '-') self.index += 1;
        const digits_start = self.index;
        while (self.index < self.text.len and std.ascii.isDigit(self.text[self.index])) : (self.index += 1) {}
        if (digits_start == self.index) {
            self.index = start;
            return null;
        }
        return std.fmt.parseInt(i64, self.text[start..self.index], 10) catch null;
    }
};

fn emitKnownShapeExprExtent(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    shape: []const u8,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    var parser: ShapeExprParser = .{ .text = shape };
    const value = (try parseKnownShapeExpr(ctx, builder, sig, args, &parser, hooks)) orelse return null;
    parser.skipSpaces();
    if (parser.index != parser.text.len) return null;
    return value;
}

fn parseKnownShapeExpr(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    parser: *ShapeExprParser,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    var value = (try parseKnownShapeTerm(ctx, builder, sig, args, parser, hooks)) orelse return null;
    while (true) {
        if (parser.consume('+')) {
            const rhs = (try parseKnownShapeTerm(ctx, builder, sig, args, parser, hooks)) orelse return null;
            value = try hooks.emitAddI64(ctx, builder, value, rhs);
            continue;
        }
        if (parser.consume('-')) {
            const rhs = (try parseKnownShapeTerm(ctx, builder, sig, args, parser, hooks)) orelse return null;
            value = try hooks.emitSubI64(ctx, builder, value, rhs);
            continue;
        }
        break;
    }
    return value;
}

fn parseKnownShapeTerm(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    parser: *ShapeExprParser,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    var value = (try parseKnownShapeFactor(ctx, builder, sig, args, parser, hooks)) orelse return null;
    while (true) {
        if (parser.consume('*')) {
            const rhs = (try parseKnownShapeFactor(ctx, builder, sig, args, parser, hooks)) orelse return null;
            value = try hooks.emitMulI64(ctx, builder, value, rhs);
            continue;
        }
        if (parser.consume('/')) {
            const rhs = (try parseKnownShapeFactor(ctx, builder, sig, args, parser, hooks)) orelse return null;
            const div_name = try ctx.nextTemp();
            try builder.binary(div_name, "sdiv", .i64, value, rhs);
            value = .{ .name = div_name, .ty = .i64, .is_ptr = false };
            continue;
        }
        break;
    }
    return value;
}

fn parseKnownShapeFactor(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    parser: *ShapeExprParser,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    if (parser.consume('+')) return parseKnownShapeFactor(ctx, builder, sig, args, parser, hooks);
    if (parser.consume('-')) {
        const inner = (try parseKnownShapeFactor(ctx, builder, sig, args, parser, hooks)) orelse return null;
        return try hooks.emitSubI64(ctx, builder, hooks.i64Const(ctx, 0), inner);
    }
    if (parser.consume('(')) {
        const inner = (try parseKnownShapeExpr(ctx, builder, sig, args, parser, hooks)) orelse return null;
        if (!parser.consume(')')) return null;
        return inner;
    }
    if (parser.parseInteger()) |value| return hooks.i64Const(ctx, value);
    const designator = parser.parseDesignator() orelse return null;
    if (parser.consume('(')) {
        if (std.ascii.eqlIgnoreCase(designator, "len")) {
            return parseKnownShapeLenCall(ctx, builder, sig, args, parser);
        }
        if (std.ascii.eqlIgnoreCase(designator, "size")) {
            return parseKnownShapeSizeCall(ctx, builder, sig, args, parser, hooks);
        }
        if (std.ascii.eqlIgnoreCase(designator, "min") or std.ascii.eqlIgnoreCase(designator, "max")) {
            return parseKnownShapeMinMaxCall(ctx, builder, sig, args, parser, designator, hooks);
        }
        if (!parser.consume(')')) return null;
        return emitKnownShapeZeroArgCallValue(ctx, builder, designator);
    }
    return emitKnownShapeDesignatorValue(ctx, builder, sig, args, designator, hooks);
}

fn parseKnownShapeLenCall(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    parser: *ShapeExprParser,
) anyerror!?ValueRef {
    const len_name = parser.parseDesignator() orelse return null;
    const actual_expr = (try buildKnownShapeDesignatorExpr(ctx, sig, args, len_name)) orelse return null;
    if (!parser.consume(')')) return null;
    var len_val = (try dispatch.emitAbiCharacterLenValue(ctx, builder, actual_expr)) orelse return null;
    if (len_val.ty != .i64) len_val = try casting.coerce(ctx, builder, len_val, .i64);
    return len_val;
}

fn parseKnownShapeSizeCall(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    parser: *ShapeExprParser,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    const size_name = parser.parseDesignator() orelse return null;
    const actual_expr = (try buildKnownShapeDesignatorExpr(ctx, sig, args, size_name)) orelse return null;

    if (parser.consume(')')) {
        return emitKnownActualElemCount(ctx, builder, actual_expr, hooks);
    }
    if (!parser.consume(',')) return null;

    const keyword_start = parser.index;
    if (parser.parseIdentifier()) |maybe_kw| {
        if (std.ascii.eqlIgnoreCase(maybe_kw, "dim")) {
            if (!parser.consume('=')) return null;
        } else {
            parser.index = keyword_start;
        }
    }

    const dim_value = parser.parseInteger() orelse return null;
    if (dim_value <= 0 or !parser.consume(')')) return null;
    return try emitKnownActualDimExtent(ctx, builder, actual_expr, @intCast(dim_value - 1), hooks);
}

fn parseKnownShapeMinMaxCall(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    parser: *ShapeExprParser,
    name: []const u8,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    const lhs = (try parseKnownShapeExpr(ctx, builder, sig, args, parser, hooks)) orelse return null;
    if (!parser.consume(',')) return null;
    const rhs = (try parseKnownShapeExpr(ctx, builder, sig, args, parser, hooks)) orelse return null;
    if (!parser.consume(')')) return null;

    const cmp_tmp = try ctx.nextTemp();
    const pred = if (std.ascii.eqlIgnoreCase(name, "min")) "sle" else "sge";
    try builder.compare(cmp_tmp, "icmp", pred, .i64, lhs, rhs);

    const select_tmp = try ctx.nextTemp();
    try builder.select(
        select_tmp,
        .i64,
        .{ .name = cmp_tmp, .ty = .i1, .is_ptr = false },
        lhs,
        rhs,
    );
    return .{ .name = select_tmp, .ty = .i64, .is_ptr = false };
}

fn emitKnownShapeIdentifierValue(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    name: []const u8,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    if (procedureArgIndex(sig, name)) |actual_idx| {
        if (actual_idx >= args.len) return null;
        if (try hooks.resolveArrayActual(ctx, builder, args[actual_idx])) |_| return null;
        var value = try dispatch.emitExpr(ctx, builder, args[actual_idx]);
        if (value.ty == .ptr) return null;
        if (value.ty != .i64) value = try casting.coerce(ctx, builder, value, .i64);
        return value;
    }

    const sym = ctx.findSymbol(name) orelse return null;
    if (sym.dims.len != 0 or sym.loweredKind() != .integer or sym.is_pointer or sym.isCharacter()) return null;
    if (sym.kind == .parameter) {
        if (sym.const_value) |cv| {
            const raw = casting.emitConstTyped(ctx, builder, cv, sym.loweredKind());
            return if (raw.ty == .i64) raw else try casting.coerce(ctx, builder, raw, .i64);
        }
    }

    const ptr = try ctx.getPointer(name);
    const load_ty = common.symbolStorageIRType(sym, ctx.options.target_layout);
    const tmp = try ctx.nextTemp();
    try builder.load(tmp, load_ty, ptr);
    var value = ValueRef{ .name = tmp, .ty = load_ty, .is_ptr = false };
    if (value.ty != .i64) value = try casting.coerce(ctx, builder, value, .i64);
    return value;
}

fn emitKnownShapeDesignatorValue(
    ctx: *Context,
    builder: anytype,
    sig: ast.sema.KnownProcedureSig,
    args: []*Expr,
    designator: []const u8,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    if (std.mem.indexOfScalar(u8, designator, '%') == null) {
        return emitKnownShapeIdentifierValue(ctx, builder, sig, args, designator, hooks);
    }
    const expr_node = (try buildKnownShapeDesignatorExpr(ctx, sig, args, designator)) orelse return null;
    if (try hooks.resolveArrayActual(ctx, builder, expr_node)) |_| return null;
    var value = try dispatch.emitExpr(ctx, builder, expr_node);
    if (value.ty == .ptr) return null;
    if (value.ty != .i64) value = try casting.coerce(ctx, builder, value, .i64);
    return value;
}

fn emitKnownActualElemCount(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    comptime hooks: anytype,
) anyerror!?ValueRef {
    const actual = (try hooks.resolveArrayActual(ctx, builder, expr)) orelse return null;
    try actual.validate();
    return try hooks.emitExtentProductI64(ctx, builder, actual.extents);
}

fn emitKnownShapeZeroArgCallValue(
    ctx: *Context,
    builder: anytype,
    name: []const u8,
) anyerror!?ValueRef {
    if (ctx.findSymbol(name) == null and ctx.lookupKnownProcedureSig(name) == null) {
        const ret_ty = ctx.defaultIntegerIRType();
        const callee = if (try ctx.ensureIntrinsicWrapper(name)) |wrapper|
            wrapper
        else
            try ctx.ensureDecl(name, ret_ty);
        const tmp = try ctx.nextTemp();
        try builder.callTyped(tmp, ret_ty, callee, &.{});
        var value = ValueRef{ .name = tmp, .ty = ret_ty, .is_ptr = false };
        if (value.ty != .i64) value = try casting.coerce(ctx, builder, value, .i64);
        return value;
    }
    const call_expr = try ctx.allocator.create(ast.Expr);
    call_expr.* = .{ .call_or_subscript = .{
        .name = name,
        .args = @constCast(&[_]*Expr{}),
    } };
    var value = try dispatch.emitExpr(ctx, builder, call_expr);
    if (value.ty == .ptr) return null;
    if (value.ty != .i64) value = try casting.coerce(ctx, builder, value, .i64);
    return value;
}

fn buildProcedureComponentArrayActuals(
    ctx: *Context,
    comp: ast.ComponentExpr,
    component: context.DerivedComponentLayout,
    proc_sig: ast.sema.KnownProcedureSig,
) ![]*Expr {
    const extra: usize = if (component.procedure_nopass) 0 else 1;
    const actuals = try ctx.allocator.alloc(*Expr, comp.args.len + extra);
    const pass_idx = if (component.procedure_nopass) null else procedure_pass.procedurePassArgIndex(proc_sig.args, component.procedure_pass_name);
    var actual_idx: usize = 0;
    var comp_idx: usize = 0;
    while (actual_idx < actuals.len) : (actual_idx += 1) {
        if (pass_idx != null and actual_idx == pass_idx.?) {
            actuals[actual_idx] = comp.base;
            continue;
        }
        actuals[actual_idx] = comp.args[comp_idx];
        comp_idx += 1;
    }
    return actuals;
}

fn storageIRTypeForProcedureResult(ctx: *Context, spec: ast.TypeSpec) IRType {
    return if (spec.lowered_kind == .logical)
        llvm_types.defaultIntegerType(ctx.options.target_layout)
    else
        ctx.typeFromKind(spec.lowered_kind);
}
