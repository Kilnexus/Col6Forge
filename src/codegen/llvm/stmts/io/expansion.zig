const std = @import("std");
const ast = @import("../../../input.zig");
const llvm_types = @import("../../types.zig");
const common = @import("../../codegen/common.zig");
const context = @import("../../codegen/context/mod.zig");
const expr = @import("../../codegen/expression/mod.zig");
const complex = @import("../../codegen/expression/complex.zig");
const array_actuals = @import("../../codegen/expression/call/array_actuals.zig");
const utils = @import("../../codegen/utils.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;
const max_implied_do_expansion: usize = 1_000_000;
const max_implied_do_iterations: usize = 65_536;
const max_static_array_arg_expansion: usize = 4096;

const io_utils = @import("utils.zig");
const implied_helpers = @import("implied_helpers.zig");
const collapsed_sections = @import("expansion/collapsed_sections.zig");

const ComplexFixup = io_utils.ComplexFixup;
const charLenForExpr = io_utils.charLenForExpr;
const evalConstIntSem = io_utils.evalConstIntSem;
const intLiteralValue = io_utils.intLiteralValue;
const emitCollapsedRangeSubscriptValue = collapsed_sections.emitCollapsedRangeSubscriptValue;
const emitCollapsedSubstringSectionValue = collapsed_sections.emitCollapsedSubstringSectionValue;
const emitCollapsedComponentSectionValue = collapsed_sections.emitCollapsedComponentSectionValue;
const emitCollapsedUnknownCountWholeArrayValue = collapsed_sections.emitCollapsedUnknownCountWholeArrayValue;
const impliedLoopDim = implied_helpers.impliedLoopDim;
const resolveArrayActual = array_actuals.resolveArrayActual;
const emitArrayActualElement = array_actuals.emitArrayActualElement;
const emitArrayActualElementPtr = array_actuals.emitArrayActualElementPtr;
const emitOwnedHeapActualFree = array_actuals.emitOwnedHeapActualFree;

pub const ExpandedReadTargets = struct {
    ptrs: std.array_list.Managed(ValueRef),
    types: std.array_list.Managed(llvm_types.IRType),
    char_lens: std.array_list.Managed(usize),
    complex_fixups: std.array_list.Managed(ComplexFixup),
    implied_finals: []const ImpliedDoFinalState = &.{},
    owns_implied_finals: bool = false,

    pub fn init(allocator: std.mem.Allocator) ExpandedReadTargets {
        return .{
            .ptrs = std.array_list.Managed(ValueRef).init(allocator),
            .types = std.array_list.Managed(llvm_types.IRType).init(allocator),
            .char_lens = std.array_list.Managed(usize).init(allocator),
            .complex_fixups = std.array_list.Managed(ComplexFixup).init(allocator),
        };
    }

    pub fn deinit(self: *ExpandedReadTargets) void {
        self.ptrs.deinit();
        self.types.deinit();
        self.char_lens.deinit();
        self.complex_fixups.deinit();
        if (self.owns_implied_finals) self.ptrs.allocator.free(self.implied_finals);
    }
};
pub const ExpandedWriteValues = struct {
    values: std.array_list.Managed(ValueRef),
    char_lens: std.array_list.Managed(usize),
    source_ptrs: std.array_list.Managed(?ValueRef),
    implied_finals: []const ImpliedDoFinalState = &.{},
    owns_implied_finals: bool = false,

    pub fn init(allocator: std.mem.Allocator) ExpandedWriteValues {
        return .{
            .values = std.array_list.Managed(ValueRef).init(allocator),
            .char_lens = std.array_list.Managed(usize).init(allocator),
            .source_ptrs = std.array_list.Managed(?ValueRef).init(allocator),
        };
    }

    pub fn deinit(self: *ExpandedWriteValues) void {
        self.values.deinit();
        self.char_lens.deinit();
        self.source_ptrs.deinit();
        if (self.owns_implied_finals) self.values.allocator.free(self.implied_finals);
    }
};

fn appendWriteValue(expanded: *ExpandedWriteValues, value: ValueRef, char_len: usize, source_ptr: ?ValueRef) !void {
    try expanded.values.append(value);
    try expanded.char_lens.append(char_len);
    try expanded.source_ptrs.append(source_ptr);
}

fn appendResolvedArrayWriteValues(
    ctx: *Context,
    builder: anytype,
    expanded: *ExpandedWriteValues,
    arg: *ast.Expr,
) EmitError!bool {
    const actual = (try resolveArrayActual(ctx, builder, arg)) orelse return false;
    const elem_count = constantArrayActualElemCount(actual) orelse return false;
    if (elem_count > max_static_array_arg_expansion) return error.ArrayArgTooLargeForPackedIo;

    if (actual.elem_ty == .i8) {
        const char_len = constantArrayActualAddressScale(actual) orelse return false;
        var idx: usize = 0;
        while (idx < elem_count) : (idx += 1) {
            const idx_val = ValueRef{ .name = try ctx.intLiteral(@intCast(idx)), .ty = .i64, .is_ptr = false };
            const src_ptr = try emitArrayActualElementPtr(
                ctx,
                builder,
                actual.base_ptr,
                actual.elem_ty,
                actual.extents,
                actual.multipliers,
                actual.address_scale,
                actual.contiguous,
                idx_val,
            );
            const buf_name = try ctx.nextTemp();
            if (char_len <= 1) {
                try builder.alloca(buf_name, .i8);
            } else {
                try builder.allocaArray(buf_name, .i8, char_len);
            }
            const buf_ptr = ValueRef{ .name = buf_name, .ty = .ptr, .is_ptr = true };
            try emitIoMemcpyBytes(ctx, builder, buf_ptr, src_ptr, try ctx.constI64(@intCast(char_len)));
            try appendWriteValue(
                expanded,
                .{ .name = buf_name, .ty = .ptr, .is_ptr = false },
                char_len,
                buf_ptr,
            );
        }
    } else {
        var idx: usize = 0;
        while (idx < elem_count) : (idx += 1) {
            const idx_val = ValueRef{ .name = try ctx.intLiteral(@intCast(idx)), .ty = .i64, .is_ptr = false };
            const elem_ptr = try emitArrayActualElementPtr(
                ctx,
                builder,
                actual.base_ptr,
                actual.elem_ty,
                actual.extents,
                actual.multipliers,
                actual.address_scale,
                actual.contiguous,
                idx_val,
            );
            const value = try emitArrayActualElement(ctx, builder, idx_val, actual);
            try appendWriteValue(expanded, value, 0, elem_ptr);
        }
    }

    try emitOwnedHeapActualFree(ctx, builder, actual.owned_heap_ptr);
    return true;
}

fn constantArrayActualElemCount(actual: anytype) ?usize {
    var total: usize = 1;
    for (actual.extents) |extent| {
        if (extent.is_ptr or extent.ty != .i64) return null;
        const parsed = std.fmt.parseInt(i64, extent.name, 10) catch return null;
        if (parsed < 0) return null;
        total = std.math.mul(usize, total, std.math.cast(usize, parsed) orelse return null) catch return null;
    }
    return total;
}

fn constantArrayActualAddressScale(actual: anytype) ?usize {
    if (actual.address_scale.is_ptr or actual.address_scale.ty != .i64) return null;
    const parsed = std.fmt.parseInt(i64, actual.address_scale.name, 10) catch return null;
    if (parsed < 0) return null;
    return std.math.cast(usize, parsed);
}

fn emitIoMemcpyBytes(ctx: *Context, builder: anytype, dst_ptr: ValueRef, src_ptr: ValueRef, size: ValueRef) EmitError!void {
    const memcpy_name = try ctx.ensureDeclRaw("llvm.memcpy.p0.p0.i64", .void, &[_]llvm_types.IRType{ .ptr, .ptr, .i64, .i1 }, false);
    try builder.callTyped(null, .void, memcpy_name, &.{ dst_ptr, src_ptr, size, .{ .name = "false", .ty = .i1, .is_ptr = false } });
}

pub const ExpandedIoArgs = struct {
    items: []*ast.Expr,
    implied_finals: []const ImpliedDoFinalState = &.{},
    clone_arena: ?std.heap.ArenaAllocator = null,
    owns_items: bool = false,
    owns_implied_finals: bool = false,

    pub fn deinit(self: *ExpandedIoArgs, allocator: std.mem.Allocator) void {
        if (self.owns_items) {
            allocator.free(self.items);
        }
        if (self.owns_implied_finals) {
            allocator.free(self.implied_finals);
        }
        if (self.clone_arena) |*arena| {
            arena.deinit();
        }
    }
};

pub const ImpliedDoFinalState = struct {
    var_name: []const u8,
    value: i64,
};

pub fn expandReadTargets(ctx: *Context, builder: anytype, args: []*ast.Expr) EmitError!ExpandedReadTargets {
    var expanded = ExpandedReadTargets.init(ctx.allocator);
    var flat_args = try expandIoArgs(ctx, args);
    defer flat_args.deinit(ctx.allocator);
    expanded.implied_finals = flat_args.implied_finals;
    expanded.owns_implied_finals = flat_args.owns_implied_finals;
    flat_args.owns_implied_finals = false;
    for (flat_args.items) |arg| {
        if (arg.* == .identifier) {
            const sym = ctx.findSymbol(arg.identifier) orelse return error.UnknownSymbol;
            if (sym.dims.len > 0) {
                const elem_count = ctx.arrayElemCountForSymbol(sym) catch return error.ArrayDimNotConstant;
                if (elem_count > max_static_array_arg_expansion) return error.ArrayArgTooLargeForPackedIo;
                const base_ptr = try ctx.getPointer(sym.name);
                const elem_ty = common.symbolElementIRType(sym, ctx.options.target_layout);
                const char_len = common.symbolCharacterLenOrOne(sym);
                const char_scale: ?ValueRef = if (sym.isCharacter() and char_len > 1)
                    .{ .name = try ctx.intLiteral(@intCast(char_len)), .ty = .i32, .is_ptr = false }
                else
                    null;
                var idx: usize = 0;
                while (idx < elem_count) : (idx += 1) {
                    var offset_val = ValueRef{ .name = try ctx.intLiteral(@intCast(idx)), .ty = .i32, .is_ptr = false };
                    if (char_scale) |scale| {
                        offset_val = try expr.emitMul(ctx, builder, offset_val, scale);
                    }
                    const ptr_name = try ctx.nextTemp();
                    try builder.gep(ptr_name, elem_ty, base_ptr, offset_val);
                    const elem_ptr = ValueRef{ .name = ptr_name, .ty = .ptr, .is_ptr = true };
                    if (complex.isComplexType(elem_ty)) {
                        const elem_real_ty = complex.complexElemType(elem_ty) orelse return error.UnsupportedComplexType;
                        const real_tmp = try ctx.nextTemp();
                        try builder.alloca(real_tmp, elem_real_ty);
                        const real_ptr = ValueRef{ .name = real_tmp, .ty = .ptr, .is_ptr = true };
                        const imag_tmp = try ctx.nextTemp();
                        try builder.alloca(imag_tmp, elem_real_ty);
                        const imag_ptr = ValueRef{ .name = imag_tmp, .ty = .ptr, .is_ptr = true };

                        try expanded.ptrs.append(real_ptr);
                        try expanded.types.append(elem_real_ty);
                        try expanded.char_lens.append(0);
                        try expanded.ptrs.append(imag_ptr);
                        try expanded.types.append(elem_real_ty);
                        try expanded.char_lens.append(0);
                        try expanded.complex_fixups.append(.{
                            .target_ptr = elem_ptr,
                            .elem_ty = elem_real_ty,
                            .real_ptr = real_ptr,
                            .imag_ptr = imag_ptr,
                        });
                    } else {
                        try expanded.ptrs.append(elem_ptr);
                        try expanded.types.append(if (sym.isCharacter()) llvm_types.IRType.ptr else elem_ty);
                        try expanded.char_lens.append(if (sym.isCharacter()) char_len else 0);
                    }
                }
                continue;
            }
        }
        const ptr = try expr.emitLValue(ctx, builder, arg);
        const ty = try expr.exprType(ctx, arg);
        if (complex.isComplexType(ty)) {
            const elem_real_ty = complex.complexElemType(ty) orelse return error.UnsupportedComplexType;
            const real_tmp = try ctx.nextTemp();
            try builder.alloca(real_tmp, elem_real_ty);
            const real_ptr = ValueRef{ .name = real_tmp, .ty = .ptr, .is_ptr = true };
            const imag_tmp = try ctx.nextTemp();
            try builder.alloca(imag_tmp, elem_real_ty);
            const imag_ptr = ValueRef{ .name = imag_tmp, .ty = .ptr, .is_ptr = true };

            try expanded.ptrs.append(real_ptr);
            try expanded.types.append(elem_real_ty);
            try expanded.char_lens.append(0);
            try expanded.ptrs.append(imag_ptr);
            try expanded.types.append(elem_real_ty);
            try expanded.char_lens.append(0);
            try expanded.complex_fixups.append(.{
                .target_ptr = ptr,
                .elem_ty = elem_real_ty,
                .real_ptr = real_ptr,
                .imag_ptr = imag_ptr,
            });
        } else {
            try expanded.ptrs.append(ptr);
            try expanded.types.append(ty);
            try expanded.char_lens.append(if (ty == .ptr) (charLenForExpr(ctx, arg) orelse 1) else 0);
        }
    }
    return expanded;
}
pub fn applyComplexFixups(ctx: *Context, builder: anytype, expanded: *ExpandedReadTargets) EmitError!void {
    for (expanded.complex_fixups.items) |fixup| {
        const real_tmp = try ctx.nextTemp();
        try builder.load(real_tmp, fixup.elem_ty, fixup.real_ptr);
        const imag_tmp = try ctx.nextTemp();
        try builder.load(imag_tmp, fixup.elem_ty, fixup.imag_ptr);
        const real_val = ValueRef{ .name = real_tmp, .ty = fixup.elem_ty, .is_ptr = false };
        const imag_val = ValueRef{ .name = imag_tmp, .ty = fixup.elem_ty, .is_ptr = false };
        const complex_ty: llvm_types.IRType = if (fixup.elem_ty == .f64) .complex_f64 else .complex_f32;
        const complex_val = try complex.buildComplex(ctx, builder, real_val, imag_val, complex_ty);
        try builder.store(complex_val, fixup.target_ptr);
    }
}
pub fn expandIoArgs(ctx: *Context, args: []*ast.Expr) EmitError!ExpandedIoArgs {
    var needs_expansion = false;
    for (args) |arg| {
        if (ioArgNeedsExpansion(arg)) {
            needs_expansion = true;
            break;
        }
    }
    if (!needs_expansion) {
        return .{
            .items = args,
            .clone_arena = null,
            .owns_items = false,
        };
    }

    var clone_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    errdefer clone_arena.deinit();

    var expanded = std.array_list.Managed(*ast.Expr).init(ctx.allocator);
    errdefer expanded.deinit();
    var implied_finals = std.array_list.Managed(ImpliedDoFinalState).init(ctx.allocator);
    errdefer implied_finals.deinit();
    const clone_allocator = clone_arena.allocator();

    for (args) |arg| {
        try appendExpandedIoArg(ctx, clone_allocator, &expanded, &implied_finals, arg);
    }

    return .{
        .items = try expanded.toOwnedSlice(),
        .implied_finals = try implied_finals.toOwnedSlice(),
        .clone_arena = clone_arena,
        .owns_items = true,
        .owns_implied_finals = true,
    };
}
fn appendExpandedIoArg(
    ctx: *Context,
    clone_allocator: std.mem.Allocator,
    expanded: *std.array_list.Managed(*ast.Expr),
    implied_finals: *std.array_list.Managed(ImpliedDoFinalState),
    arg: *ast.Expr,
) EmitError!void {
    if (try flattenIoArrayValuedExpr(ctx, clone_allocator, arg)) |items| {
        for (items) |item| {
            try appendExpandedIoArg(ctx, clone_allocator, expanded, implied_finals, item);
        }
        return;
    }
    if (arg.* == .implied_do) {
        const implied_expanded = try expandImpliedDo(ctx, clone_allocator, arg.implied_do);
        defer ctx.allocator.free(implied_expanded);
        for (implied_expanded) |item| {
            try appendExpandedIoArg(ctx, clone_allocator, expanded, implied_finals, item.expr);
        }
        try implied_finals.append(.{
            .var_name = arg.implied_do.var_name,
            .value = try impliedFinalValue(ctx, arg.implied_do),
        });
        return;
    }
    if (arg.* == .array_constructor) {
        for (arg.array_constructor.items) |item| {
            try appendExpandedIoArg(ctx, clone_allocator, expanded, implied_finals, item);
        }
        return;
    }
    try expanded.append(arg);
}

const ExpandedImpliedItem = struct {
    expr: *ast.Expr,
};

fn flattenIoArrayValuedExpr(
    ctx: *Context,
    allocator: std.mem.Allocator,
    arg: *ast.Expr,
) EmitError!?[]*ast.Expr {
    return switch (arg.*) {
        .array_constructor => |ctor| blk: {
            if (ctor.type_spec != null or ctor.items.len == 0) break :blk null;
            const items = try allocator.alloc(*ast.Expr, ctor.items.len);
            @memcpy(items, ctor.items);
            break :blk items;
        },
        .unary => |un| blk: {
            const inner_items = try flattenIoArrayValuedExpr(ctx, allocator, un.expr) orelse break :blk null;
            const items = try allocator.alloc(*ast.Expr, inner_items.len);
            for (inner_items, 0..) |item, idx| {
                const scalar_expr = try allocator.create(ast.Expr);
                scalar_expr.* = .{ .unary = .{
                    .op = un.op,
                    .expr = item,
                } };
                items[idx] = scalar_expr;
            }
            break :blk items;
        },
        .binary => |bin| blk: {
            const left_items = try flattenIoArrayValuedExpr(ctx, allocator, bin.left);
            const right_items = try flattenIoArrayValuedExpr(ctx, allocator, bin.right);
            if (left_items == null and right_items == null) break :blk null;

            const item_count = if (left_items) |items_| items_.len else right_items.?.len;
            if (left_items != null and right_items != null and left_items.?.len != right_items.?.len) break :blk null;

            const items = try allocator.alloc(*ast.Expr, item_count);
            var idx: usize = 0;
            while (idx < item_count) : (idx += 1) {
                const scalar_expr = try allocator.create(ast.Expr);
                scalar_expr.* = .{ .binary = .{
                    .op = bin.op,
                    .left = if (left_items) |items_| items_[idx] else bin.left,
                    .right = if (right_items) |items_| items_[idx] else bin.right,
                } };
                items[idx] = scalar_expr;
            }
            break :blk items;
        },
        .call_or_subscript => |call| flattenVectorSubscriptItems(ctx, allocator, call),
        else => null,
    };
}

fn ioArgNeedsExpansion(arg: *ast.Expr) bool {
    return switch (arg.*) {
        .implied_do, .array_constructor => true,
        .unary => |un| ioArgNeedsExpansion(un.expr),
        .binary => |bin| ioArgNeedsExpansion(bin.left) or ioArgNeedsExpansion(bin.right),
        .complex_literal => |lit| ioArgNeedsExpansion(lit.real) or ioArgNeedsExpansion(lit.imag),
        .call_or_subscript => |call| blk: {
            for (call.args) |sub_arg| {
                if (ioArgNeedsExpansion(sub_arg)) break :blk true;
            }
            break :blk false;
        },
        .substring => |sub| blk: {
            for (sub.args) |sub_arg| {
                if (ioArgNeedsExpansion(sub_arg)) break :blk true;
            }
            if (sub.start) |start_expr| {
                if (ioArgNeedsExpansion(start_expr)) break :blk true;
            }
            if (sub.end) |end_expr| {
                if (ioArgNeedsExpansion(end_expr)) break :blk true;
            }
            break :blk false;
        },
        .component => |comp| blk: {
            if (ioArgNeedsExpansion(comp.base)) break :blk true;
            for (comp.args) |sub_arg| {
                if (ioArgNeedsExpansion(sub_arg)) break :blk true;
            }
            break :blk false;
        },
        .dim_range => |range| blk: {
            if (range.lower) |lower| {
                if (ioArgNeedsExpansion(lower)) break :blk true;
            }
            if (ioArgNeedsExpansion(range.upper)) break :blk true;
            if (range.stride) |stride_expr| {
                if (ioArgNeedsExpansion(stride_expr)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn flattenVectorSubscriptItems(
    ctx: *Context,
    allocator: std.mem.Allocator,
    call: ast.CallOrSubscript,
) EmitError!?[]*ast.Expr {
    const sym = ctx.findSymbol(call.name) orelse return null;
    if (sym.dims.len == 0 or call.args.len != sym.dims.len) return null;

    var vector_dim: ?usize = null;
    for (call.args, 0..) |arg, idx| {
        if (arg.* != .array_constructor) continue;
        if (vector_dim != null) return null;
        vector_dim = idx;
    }
    const dim_idx = vector_dim orelse return null;
    const ctor = call.args[dim_idx].array_constructor;
    if (ctor.type_spec != null or ctor.items.len == 0) return null;

    const items = try allocator.alloc(*ast.Expr, ctor.items.len);
    for (ctor.items, 0..) |item, idx| {
        const scalar_args = try allocator.alloc(*ast.Expr, call.args.len);
        for (call.args, 0..) |arg, arg_idx| {
            scalar_args[arg_idx] = if (arg_idx == dim_idx) item else arg;
        }
        const scalar_ref = try allocator.create(ast.Expr);
        scalar_ref.* = .{ .call_or_subscript = .{
            .name = call.name,
            .args = scalar_args,
        } };
        items[idx] = scalar_ref;
    }
    return items;
}

fn expandImpliedDo(ctx: *Context, clone_allocator: std.mem.Allocator, implied: ast.ImpliedDo) EmitError![]ExpandedImpliedItem {
    const start_val_opt = try evalImpliedDoBound(ctx, implied.start);
    const end_val_opt = try evalImpliedDoBound(ctx, implied.end);
    const step_val_opt = if (implied.step) |step| try evalImpliedDoBound(ctx, step) else 1;

    // Conservative fallback for runtime-bounded implied-DO lists:
    // keep codegen moving by emitting at least one element.
    const start_val = start_val_opt orelse 1;
    const step_val = step_val_opt orelse 1;
    if (step_val == 0) return error.UnsupportedImpliedDo;

    var end_val = end_val_opt;
    if (end_val == null) {
        end_val = inferImpliedDoEndFromItems(ctx, implied);
    }
    const end_val_final = end_val orelse start_val;
    const iter_count = try impliedDoIterationCount(start_val, end_val_final, step_val);
    if (iter_count > max_implied_do_iterations) return error.ImpliedDoExpansionTooLarge;
    const expanded_len = std.math.mul(usize, iter_count, implied.items.len) catch return error.ImpliedDoExpansionTooLarge;
    if (expanded_len > max_implied_do_expansion) return error.ImpliedDoExpansionTooLarge;

    var expanded = std.array_list.Managed(ExpandedImpliedItem).init(ctx.allocator);
    errdefer expanded.deinit();
    try expanded.ensureTotalCapacity(expanded_len);

    var idx: i64 = start_val;
    var emitted: usize = 0;
    if (step_val > 0) {
        while (idx <= end_val_final) : (idx += step_val) {
            var iter_expr = ast.Expr{
                .literal = .{
                    .kind = .integer,
                    .text = try ctx.intLiteral(idx),
                },
            };
            for (implied.items) |item| {
                if (emitted >= max_implied_do_expansion) return error.ImpliedDoExpansionTooLarge;
                const clone = try cloneExprWithSubst(ctx, clone_allocator, item, implied.var_name, &iter_expr);
                try expanded.append(.{ .expr = clone });
                emitted += 1;
            }
        }
    } else {
        while (idx >= end_val_final) : (idx += step_val) {
            var iter_expr = ast.Expr{
                .literal = .{
                    .kind = .integer,
                    .text = try ctx.intLiteral(idx),
                },
            };
            for (implied.items) |item| {
                if (emitted >= max_implied_do_expansion) return error.ImpliedDoExpansionTooLarge;
                const clone = try cloneExprWithSubst(ctx, clone_allocator, item, implied.var_name, &iter_expr);
                try expanded.append(.{ .expr = clone });
                emitted += 1;
            }
        }
    }

    return expanded.toOwnedSlice();
}

fn impliedFinalValue(ctx: *Context, implied: ast.ImpliedDo) EmitError!i64 {
    const start_val = (try evalImpliedDoBound(ctx, implied.start)) orelse 1;
    const step_val = if (implied.step) |step|
        (try evalImpliedDoBound(ctx, step)) orelse 1
    else
        1;
    if (step_val == 0) return error.UnsupportedImpliedDo;
    var end_val = (try evalImpliedDoBound(ctx, implied.end));
    if (end_val == null) {
        end_val = inferImpliedDoEndFromItems(ctx, implied);
    }
    const end_val_final = end_val orelse start_val;
    const iter_count = try impliedDoIterationCount(start_val, end_val_final, step_val);
    if (iter_count == 0) return start_val;
    return start_val + (step_val * @as(i64, @intCast(iter_count)));
}

fn impliedDoIterationCount(start_val: i64, end_val: i64, step_val: i64) EmitError!usize {
    var count: usize = 0;
    var idx = start_val;
    if (step_val > 0) {
        while (idx <= end_val) {
            if (count >= max_implied_do_expansion) return error.ImpliedDoExpansionTooLarge;
            count += 1;
            idx = std.math.add(i64, idx, step_val) catch return error.ImpliedDoExpansionTooLarge;
        }
        return count;
    }

    while (idx >= end_val) {
        if (count >= max_implied_do_expansion) return error.ImpliedDoExpansionTooLarge;
        count += 1;
        idx = std.math.add(i64, idx, step_val) catch return error.ImpliedDoExpansionTooLarge;
    }
    return count;
}
fn evalImpliedDoBound(ctx: *Context, node: *ast.Expr) EmitError!?i64 {
    if (try evalConstIntSem(ctx, node)) |value| return value;
    return intLiteralValue(node);
}
fn inferImpliedDoEndFromItems(ctx: *Context, implied: ast.ImpliedDo) ?i64 {
    for (implied.items) |item| {
        if (item.* != .call_or_subscript) continue;
        const call = item.call_or_subscript;
        const loop_dim = impliedLoopDim(call.args, implied.var_name) orelse continue;
        const sym = ctx.findSymbol(call.name) orelse continue;
        if (sym.dims.len == 0 or loop_dim >= sym.dims.len) continue;
        const extent = staticDimExtent(ctx, sym.dims[loop_dim]) orelse continue;
        return extent;
    }
    return null;
}
fn staticIntValue(ctx: *Context, node: *ast.Expr) ?i64 {
    return (evalConstIntSem(ctx, node) catch null) orelse intLiteralValue(node);
}
fn staticDimExtent(ctx: *Context, dim: *ast.Expr) ?i64 {
    return switch (dim.*) {
        .dim_range => |range| blk: {
            if (range.stride != null) break :blk null;
            const upper = staticIntValue(ctx, range.upper) orelse break :blk null;
            const lower = if (range.lower) |lower_expr| staticIntValue(ctx, lower_expr) orelse break :blk null else 1;
            if (upper < lower) break :blk 0;
            const diff = std.math.sub(i64, upper, lower) catch break :blk null;
            break :blk std.math.add(i64, diff, 1) catch null;
        },
        else => staticIntValue(ctx, dim),
    };
}
fn cloneExprWithSubst(
    ctx: *Context,
    allocator: std.mem.Allocator,
    node: *ast.Expr,
    name: []const u8,
    replacement: *ast.Expr,
) EmitError!*ast.Expr {
    const cloned = try allocator.create(ast.Expr);
    switch (node.*) {
        .identifier => |ident| {
            if (std.ascii.eqlIgnoreCase(ident, name)) {
                cloned.* = replacement.*;
                return cloned;
            }
            cloned.* = .{ .identifier = ident };
        },
        .array_constructor => |ctor| {
            const items = try allocator.alloc(*ast.Expr, ctor.items.len);
            for (ctor.items, 0..) |item, idx| {
                items[idx] = try cloneExprWithSubst(ctx, allocator, item, name, replacement);
            }
            cloned.* = .{ .array_constructor = .{ .type_spec = ctor.type_spec, .items = items } };
        },
        .literal => |lit| {
            cloned.* = .{ .literal = lit };
        },
        .unary => |un| {
            const expr_node = try cloneExprWithSubst(ctx, allocator, un.expr, name, replacement);
            cloned.* = .{ .unary = .{ .op = un.op, .expr = expr_node } };
        },
        .binary => |bin| {
            const left = try cloneExprWithSubst(ctx, allocator, bin.left, name, replacement);
            const right = try cloneExprWithSubst(ctx, allocator, bin.right, name, replacement);
            cloned.* = .{ .binary = .{ .op = bin.op, .left = left, .right = right } };
        },
        .complex_literal => |lit| {
            const real = try cloneExprWithSubst(ctx, allocator, lit.real, name, replacement);
            const imag = try cloneExprWithSubst(ctx, allocator, lit.imag, name, replacement);
            cloned.* = .{ .complex_literal = .{ .real = real, .imag = imag } };
        },
        .call_or_subscript => |call| {
            const args = try allocator.alloc(*ast.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, allocator, arg, name, replacement);
            }
            cloned.* = .{ .call_or_subscript = .{ .name = call.name, .args = args } };
            if (ctx.ref_kinds.get(@as(usize, @intFromPtr(node)))) |kind| {
                try ctx.ref_kinds.put(@as(usize, @intFromPtr(cloned)), kind);
            }
        },
        .substring => |sub| {
            const args = try allocator.alloc(*ast.Expr, sub.args.len);
            for (sub.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, allocator, arg, name, replacement);
            }
            const start_expr = if (sub.start) |s| try cloneExprWithSubst(ctx, allocator, s, name, replacement) else null;
            const end_expr = if (sub.end) |e| try cloneExprWithSubst(ctx, allocator, e, name, replacement) else null;
            cloned.* = .{ .substring = .{ .name = sub.name, .args = args, .start = start_expr, .end = end_expr } };
        },
        .component => |comp| {
            const base = try cloneExprWithSubst(ctx, allocator, comp.base, name, replacement);
            const args = try allocator.alloc(*ast.Expr, comp.args.len);
            for (comp.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, allocator, arg, name, replacement);
            }
            cloned.* = .{ .component = .{ .base = base, .name = comp.name, .args = args, .has_parens = comp.has_parens } };
        },
        .dim_range => |range| {
            const lower = if (range.lower) |l| try cloneExprWithSubst(ctx, allocator, l, name, replacement) else null;
            const upper = try cloneExprWithSubst(ctx, allocator, range.upper, name, replacement);
            const stride = if (range.stride) |s| try cloneExprWithSubst(ctx, allocator, s, name, replacement) else null;
            cloned.* = .{ .dim_range = .{ .lower = lower, .upper = upper, .stride = stride, .assumed_shape = range.assumed_shape } };
        },
        .implied_do => |implied| {
            if (std.ascii.eqlIgnoreCase(implied.var_name, name)) {
                const items = implied.items;
                const start_expr = implied.start;
                const end_expr = implied.end;
                const step_expr = implied.step;
                cloned.* = .{
                    .implied_do = .{
                        .items = items,
                        .var_name = implied.var_name,
                        .start = start_expr,
                        .end = end_expr,
                        .step = step_expr,
                    },
                };
            } else {
                const items = try cloneExprListWithSubst(ctx, allocator, implied.items, name, replacement);
                const start_expr = try cloneExprWithSubst(ctx, allocator, implied.start, name, replacement);
                const end_expr = try cloneExprWithSubst(ctx, allocator, implied.end, name, replacement);
                const step_expr = if (implied.step) |step| try cloneExprWithSubst(ctx, allocator, step, name, replacement) else null;
                cloned.* = .{
                    .implied_do = .{
                        .items = items,
                        .var_name = implied.var_name,
                        .start = start_expr,
                        .end = end_expr,
                        .step = step_expr,
                    },
                };
            }
        },
    }
    return cloned;
}
fn cloneExprListWithSubst(
    ctx: *Context,
    allocator: std.mem.Allocator,
    items: []*ast.Expr,
    name: []const u8,
    replacement: *ast.Expr,
) EmitError![]*ast.Expr {
    const cloned = try allocator.alloc(*ast.Expr, items.len);
    for (items, 0..) |item, idx| {
        cloned[idx] = try cloneExprWithSubst(ctx, allocator, item, name, replacement);
    }
    return cloned;
}

pub fn expandWriteArgs(ctx: *Context, builder: anytype, args: []*ast.Expr) EmitError!ExpandedWriteValues {
    var expanded = ExpandedWriteValues.init(ctx.allocator);
    var flat_args = try expandIoArgs(ctx, args);
    defer flat_args.deinit(ctx.allocator);
    expanded.implied_finals = flat_args.implied_finals;
    expanded.owns_implied_finals = flat_args.owns_implied_finals;
    flat_args.owns_implied_finals = false;
    for (flat_args.items) |arg| {
        if (try appendResolvedArrayWriteValues(ctx, builder, &expanded, arg)) {
            continue;
        }
        if (arg.* == .identifier) {
            const sym = ctx.findSymbol(arg.identifier) orelse return error.UnknownSymbol;
            if (sym.dims.len > 0) {
                const elem_count = ctx.arrayElemCountForSymbol(sym) catch |err| switch (err) {
                    error.ArrayDimNotConstant => {
                        if (try emitCollapsedUnknownCountWholeArrayValue(ctx, builder, sym.name)) |value| {
                            const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
                            try appendWriteValue(&expanded, value, len, null);
                            continue;
                        }
                        return err;
                    },
                    else => return err,
                };
                if (elem_count > max_static_array_arg_expansion) return error.ArrayArgTooLargeForPackedIo;
                const base_ptr = try ctx.getPointer(sym.name);
                const elem_ty = common.symbolElementIRType(sym, ctx.options.target_layout);
                const char_len = common.symbolCharacterLenOrOne(sym);
                const char_scale: ?ValueRef = if (sym.isCharacter() and char_len > 1)
                    .{ .name = try ctx.intLiteral(@intCast(char_len)), .ty = .i32, .is_ptr = false }
                else
                    null;
                var idx: usize = 0;
                while (idx < elem_count) : (idx += 1) {
                    var offset_val = ValueRef{ .name = try ctx.intLiteral(@intCast(idx)), .ty = .i32, .is_ptr = false };
                    if (char_scale) |scale| {
                        offset_val = try expr.emitMul(ctx, builder, offset_val, scale);
                    }
                    const ptr_name = try ctx.nextTemp();
                    try builder.gep(ptr_name, elem_ty, base_ptr, offset_val);
                    if (sym.isCharacter()) {
                        try appendWriteValue(&expanded, .{ .name = ptr_name, .ty = .ptr, .is_ptr = false }, char_len, .{ .name = ptr_name, .ty = .ptr, .is_ptr = true });
                    } else {
                        const tmp = try ctx.nextTemp();
                        try builder.load(tmp, elem_ty, .{ .name = ptr_name, .ty = .ptr, .is_ptr = true });
                        const loaded = ValueRef{ .name = tmp, .ty = elem_ty, .is_ptr = false };
                        if (complex.isComplexType(loaded.ty)) {
                            const real = try complex.extractComplex(ctx, builder, loaded, 0);
                            const imag = try complex.extractComplex(ctx, builder, loaded, 1);
                            try appendWriteValue(&expanded, real, 0, null);
                            try appendWriteValue(&expanded, imag, 0, null);
                        } else {
                            try appendWriteValue(&expanded, loaded, 0, null);
                        }
                    }
                }
                continue;
            }
        }
        if (arg.* == .call_or_subscript) {
            if (try emitCollapsedRangeSubscriptValue(ctx, builder, arg.call_or_subscript)) |value| {
                if (complex.isComplexType(value.ty)) {
                    const real = try complex.extractComplex(ctx, builder, value, 0);
                    const imag = try complex.extractComplex(ctx, builder, value, 1);
                    try appendWriteValue(&expanded, real, 0, null);
                    try appendWriteValue(&expanded, imag, 0, null);
                } else {
                    const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
                    try appendWriteValue(&expanded, value, len, null);
                }
                continue;
            }
        }
        if (try emitCollapsedSubstringSectionValue(ctx, builder, arg)) |value| {
            if (complex.isComplexType(value.ty)) {
                const real = try complex.extractComplex(ctx, builder, value, 0);
                const imag = try complex.extractComplex(ctx, builder, value, 1);
                try appendWriteValue(&expanded, real, 0, null);
                try appendWriteValue(&expanded, imag, 0, null);
            } else {
                const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
                try appendWriteValue(&expanded, value, len, null);
            }
            continue;
        }
        if (try emitCollapsedComponentSectionValue(ctx, builder, arg)) |value| {
            if (complex.isComplexType(value.ty)) {
                const real = try complex.extractComplex(ctx, builder, value, 0);
                const imag = try complex.extractComplex(ctx, builder, value, 1);
                try appendWriteValue(&expanded, real, 0, null);
                try appendWriteValue(&expanded, imag, 0, null);
            } else {
                const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
                try appendWriteValue(&expanded, value, len, null);
            }
            continue;
        }
        const source_ptr = expr.emitLValue(ctx, builder, arg) catch null;
        const value = try expr.emitExpr(ctx, builder, arg);
        if (complex.isComplexType(value.ty)) {
            const real = try complex.extractComplex(ctx, builder, value, 0);
            const imag = try complex.extractComplex(ctx, builder, value, 1);
            try appendWriteValue(&expanded, real, 0, null);
            try appendWriteValue(&expanded, imag, 0, null);
        } else {
            const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
            try appendWriteValue(&expanded, value, len, source_ptr);
        }
    }
    return expanded;
}
pub fn expandWriteArgsList(ctx: *Context, builder: anytype, args: []*ast.Expr) EmitError!ExpandedWriteValues {
    var expanded = ExpandedWriteValues.init(ctx.allocator);
    var flat_args = try expandIoArgs(ctx, args);
    defer flat_args.deinit(ctx.allocator);
    expanded.implied_finals = flat_args.implied_finals;
    expanded.owns_implied_finals = flat_args.owns_implied_finals;
    flat_args.owns_implied_finals = false;
    for (flat_args.items) |arg| {
        if (try appendResolvedArrayWriteValues(ctx, builder, &expanded, arg)) {
            continue;
        }
        if (arg.* == .identifier) {
            const sym = ctx.findSymbol(arg.identifier) orelse return error.UnknownSymbol;
            if (sym.dims.len > 0) {
                const elem_count = ctx.arrayElemCountForSymbol(sym) catch |err| switch (err) {
                    error.ArrayDimNotConstant => {
                        if (try emitCollapsedUnknownCountWholeArrayValue(ctx, builder, sym.name)) |value| {
                            const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
                            try appendWriteValue(&expanded, value, len, null);
                            continue;
                        }
                        return err;
                    },
                    else => return err,
                };
                if (elem_count > max_static_array_arg_expansion) return error.ArrayArgTooLargeForPackedIo;
                const base_ptr = try ctx.getPointer(sym.name);
                const elem_ty = common.symbolElementIRType(sym, ctx.options.target_layout);
                const char_len = common.symbolCharacterLenOrOne(sym);
                if (sym.isCharacter()) {
                    const total_len = elem_count * char_len;
                    try appendWriteValue(&expanded, .{ .name = base_ptr.name, .ty = .ptr, .is_ptr = true }, total_len, .{ .name = base_ptr.name, .ty = .ptr, .is_ptr = true });
                } else {
                    var idx: usize = 0;
                    while (idx < elem_count) : (idx += 1) {
                        const offset_val = ValueRef{ .name = try ctx.intLiteral(@intCast(idx)), .ty = .i32, .is_ptr = false };
                        const ptr_name = try ctx.nextTemp();
                        try builder.gep(ptr_name, elem_ty, base_ptr, offset_val);
                        const tmp = try ctx.nextTemp();
                        try builder.load(tmp, elem_ty, .{ .name = ptr_name, .ty = .ptr, .is_ptr = true });
                        const loaded = ValueRef{ .name = tmp, .ty = elem_ty, .is_ptr = false };
                        try appendWriteValue(&expanded, loaded, 0, .{ .name = ptr_name, .ty = .ptr, .is_ptr = true });
                    }
                }
                continue;
            }
        }
        if (arg.* == .call_or_subscript) {
            if (try emitCollapsedRangeSubscriptValue(ctx, builder, arg.call_or_subscript)) |value| {
                const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
                try appendWriteValue(&expanded, value, len, null);
                continue;
            }
        }
        if (try emitCollapsedSubstringSectionValue(ctx, builder, arg)) |value| {
            const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
            try appendWriteValue(&expanded, value, len, null);
            continue;
        }
        if (try emitCollapsedComponentSectionValue(ctx, builder, arg)) |value| {
            const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
            try appendWriteValue(&expanded, value, len, null);
            continue;
        }
        const source_ptr = expr.emitLValue(ctx, builder, arg) catch null;
        const value = try expr.emitExpr(ctx, builder, arg);
        const len = if (value.ty == .ptr) charLenForExpr(ctx, arg) orelse 1 else 0;
        try appendWriteValue(&expanded, value, len, source_ptr);
    }
    return expanded;
}

pub fn emitImpliedDoFinalStores(
    ctx: *Context,
    builder: anytype,
    finals: []const ImpliedDoFinalState,
) EmitError!void {
    for (finals) |final_state| {
        const sym = ctx.findSymbol(final_state.var_name) orelse return error.UnknownSymbol;
        const ptr = try ctx.getPointer(final_state.var_name);
        const ty = ctx.typeFromKind(sym.loweredKind());
        var value = ValueRef{
            .name = try ctx.intLiteral(final_state.value),
            .ty = .i32,
            .is_ptr = false,
        };
        if (ty != .i32) {
            value = try expr.coerce(ctx, builder, value, ty);
        }
        try builder.store(value, ptr);
    }
}
