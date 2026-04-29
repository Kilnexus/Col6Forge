const std = @import("std");
const ast = @import("../../../../../input.zig");
const context = @import("../../../../codegen/context/mod.zig");
const evaluator = @import("../../../../../../semantic/evaluator.zig");
const const_eval = @import("const_eval.zig");
const metadata = @import("metadata.zig");

const Context = context.Context;
const EmitError = anyerror;

pub fn isRuntimeWholeArrayImpliedDo(ctx: *Context, implied: ast.ImpliedDo) bool {
    return !const_eval.isStaticImpliedDoBound(ctx, implied.start) or
        !const_eval.isStaticImpliedDoBound(ctx, implied.end) or
        (implied.step != null and !const_eval.isStaticImpliedDoBound(ctx, implied.step.?));
}

pub fn isScalarExprForWholeArrayGeneration(ctx: *Context, expr_node: *ast.Expr) bool {
    return flattenArrayValuedExprItems(ctx, expr_node) catch null == null;
}

fn appendFlattenedConstructorItems(
    ctx: *Context,
    out: *std.array_list.Managed(*ast.Expr),
    items: []const *ast.Expr,
) EmitError!void {
    for (items) |item| {
        if (try appendFlattenedArrayValuedExpr(ctx, out, item)) continue;
        try out.append(item);
    }
}

fn appendFlattenedArrayValuedExpr(
    ctx: *Context,
    out: *std.array_list.Managed(*ast.Expr),
    expr_node: *ast.Expr,
) EmitError!bool {
    switch (expr_node.*) {
        .identifier => |name| {
            const items = try flattenParameterArrayIdentifier(ctx, name) orelse return false;
            for (items) |item| {
                try out.append(item);
            }
            return true;
        },
        .array_constructor => |ctor| {
            try appendFlattenedConstructorItems(ctx, out, ctor.items);
            return true;
        },
        .implied_do => |implied| {
            const items = try expandStaticImpliedDoItems(ctx, implied) orelse return false;
            for (items) |item| {
                if (try appendFlattenedArrayValuedExpr(ctx, out, item)) continue;
                try out.append(item);
            }
            return true;
        },
        .unary => |un| {
            const inner_items = try flattenArrayValuedExprItems(ctx, un.expr) orelse return false;
            for (inner_items) |item| {
                const scalar_expr = try ctx.allocator.create(ast.Expr);
                scalar_expr.* = .{ .unary = .{
                    .op = un.op,
                    .expr = item,
                } };
                try out.append(scalar_expr);
            }
            return true;
        },
        .call_or_subscript => |call| {
            const items = try flattenIntrinsicArrayValuedCall(ctx, call) orelse return false;
            for (items) |item| {
                try out.append(item);
            }
            return true;
        },
        .binary => |bin| {
            const left_items = try flattenArrayValuedExprItems(ctx, bin.left);
            const right_items = try flattenArrayValuedExprItems(ctx, bin.right);
            if (left_items == null and right_items == null) return false;
            const item_count = if (left_items) |items_| items_.len else right_items.?.len;
            if (left_items != null and right_items != null and left_items.?.len != right_items.?.len) return false;

            var idx: usize = 0;
            while (idx < item_count) : (idx += 1) {
                const scalar_expr = try ctx.allocator.create(ast.Expr);
                scalar_expr.* = .{ .binary = .{
                    .op = bin.op,
                    .left = if (left_items) |items_| items_[idx] else bin.left,
                    .right = if (right_items) |items_| items_[idx] else bin.right,
                } };
                try out.append(scalar_expr);
            }
            return true;
        },
        else => return false,
    }
}

pub fn flattenArrayValuedExprItems(ctx: *Context, expr_node: *ast.Expr) EmitError!?[]const *ast.Expr {
    var items = std.array_list.Managed(*ast.Expr).init(ctx.allocator);
    if (!(try appendFlattenedArrayValuedExpr(ctx, &items, expr_node))) return null;
    return try items.toOwnedSlice();
}

fn flattenIntrinsicArrayValuedCall(ctx: *Context, call: ast.CallOrSubscript) EmitError!?[]const *ast.Expr {
    if (std.ascii.eqlIgnoreCase(call.name, "reshape")) {
        if (call.args.len != 2) return null;

        const source_items = try flattenArrayValuedExprItems(ctx, call.args[0]) orelse return null;
        const expected_count = metadata.reshapeShapeProduct(ctx, call.args[1]) orelse return null;
        if (source_items.len != expected_count) return null;
        return source_items;
    }
    if (std.ascii.eqlIgnoreCase(call.name, "cshift") or std.ascii.eqlIgnoreCase(call.name, "eoshift")) {
        if (call.args.len < 2 or call.args.len > 3) return null;
        return flattenArrayValuedExprItems(ctx, call.args[0]);
    }
    if (std.ascii.eqlIgnoreCase(call.name, "unpack")) {
        if (call.args.len != 3) return null;
        const vector_items = try flattenArrayValuedExprItems(ctx, call.args[0]) orelse return null;
        const mask_items = try flattenArrayValuedExprItems(ctx, call.args[1]) orelse return null;
        var result = std.array_list.Managed(*ast.Expr).init(ctx.allocator);
        errdefer result.deinit();

        var vector_idx: usize = 0;
        for (mask_items) |mask_item| {
            const take_vector = try evalStaticLogicalExpr(ctx, mask_item) orelse return null;
            if (take_vector) {
                if (vector_idx >= vector_items.len) return null;
                try result.append(vector_items[vector_idx]);
                vector_idx += 1;
            } else {
                try result.append(call.args[2]);
            }
        }
        return try result.toOwnedSlice();
    }
    return null;
}

fn flattenParameterArrayIdentifier(ctx: *Context, name: []const u8) EmitError!?[]const *ast.Expr {
    const sym = ctx.findSymbol(name) orelse return null;
    if (sym.dims.len == 0) return null;
    if (ctx.static_array_values.get(name)) |items| return items;
    const init_expr = metadata.findDeclaratorInitializerExpr(ctx, name) orelse return null;
    return flattenArrayValuedExprItems(ctx, init_expr);
}

fn expandStaticImpliedDoItems(ctx: *Context, implied: ast.ImpliedDo) EmitError!?[]const *ast.Expr {
    const start_val = try evalStaticIntExpr(ctx, implied.start) orelse return null;
    const end_val = try evalStaticIntExpr(ctx, implied.end) orelse return null;
    const step_val = if (implied.step) |step_expr|
        (try evalStaticIntExpr(ctx, step_expr)) orelse return null
    else
        1;
    if (step_val == 0) return null;

    var result = std.array_list.Managed(*ast.Expr).init(ctx.allocator);
    errdefer result.deinit();

    var idx = start_val;
    if (step_val > 0) {
        while (idx <= end_val) : (idx += step_val) {
            const iter_expr = try makeIntegerLiteralExpr(ctx, idx);
            for (implied.items) |item| {
                try result.append(try cloneExprWithSubst(ctx, item, implied.var_name, iter_expr));
            }
        }
    } else {
        while (idx >= end_val) : (idx += step_val) {
            const iter_expr = try makeIntegerLiteralExpr(ctx, idx);
            for (implied.items) |item| {
                try result.append(try cloneExprWithSubst(ctx, item, implied.var_name, iter_expr));
            }
        }
    }
    return try result.toOwnedSlice();
}

fn makeIntegerLiteralExpr(ctx: *Context, value: i64) EmitError!*ast.Expr {
    const node = try ctx.allocator.create(ast.Expr);
    node.* = .{ .literal = .{
        .kind = .integer,
        .text = try ctx.intLiteral(value),
    } };
    return node;
}

fn cloneExprWithSubst(
    ctx: *Context,
    node: *ast.Expr,
    name: []const u8,
    replacement: *ast.Expr,
) EmitError!*ast.Expr {
    const cloned = try ctx.allocator.create(ast.Expr);
    switch (node.*) {
        .identifier => |ident| {
            if (std.ascii.eqlIgnoreCase(ident, name)) {
                cloned.* = replacement.*;
                return cloned;
            }
            cloned.* = .{ .identifier = ident };
        },
        .array_constructor => |ctor| {
            const items = try ctx.allocator.alloc(*ast.Expr, ctor.items.len);
            for (ctor.items, 0..) |item, idx| {
                items[idx] = try cloneExprWithSubst(ctx, item, name, replacement);
            }
            cloned.* = .{ .array_constructor = .{ .type_spec = ctor.type_spec, .items = items } };
        },
        .literal => |lit| cloned.* = .{ .literal = lit },
        .unary => |un| {
            cloned.* = .{ .unary = .{
                .op = un.op,
                .expr = try cloneExprWithSubst(ctx, un.expr, name, replacement),
            } };
        },
        .binary => |bin| {
            cloned.* = .{ .binary = .{
                .op = bin.op,
                .left = try cloneExprWithSubst(ctx, bin.left, name, replacement),
                .right = try cloneExprWithSubst(ctx, bin.right, name, replacement),
            } };
        },
        .complex_literal => |lit| {
            cloned.* = .{ .complex_literal = .{
                .real = try cloneExprWithSubst(ctx, lit.real, name, replacement),
                .imag = try cloneExprWithSubst(ctx, lit.imag, name, replacement),
            } };
        },
        .call_or_subscript => |call| {
            const args = try ctx.allocator.alloc(*ast.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, arg, name, replacement);
            }
            cloned.* = .{ .call_or_subscript = .{ .name = call.name, .args = args } };
            if (ctx.ref_kinds.get(@as(usize, @intFromPtr(node)))) |kind| {
                try ctx.ref_kinds.put(@as(usize, @intFromPtr(cloned)), kind);
            }
        },
        .substring => |sub| {
            const args = try ctx.allocator.alloc(*ast.Expr, sub.args.len);
            for (sub.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, arg, name, replacement);
            }
            cloned.* = .{ .substring = .{
                .name = sub.name,
                .args = args,
                .start = if (sub.start) |start_expr| try cloneExprWithSubst(ctx, start_expr, name, replacement) else null,
                .end = if (sub.end) |end_expr| try cloneExprWithSubst(ctx, end_expr, name, replacement) else null,
            } };
        },
        .component => |comp| {
            const args = try ctx.allocator.alloc(*ast.Expr, comp.args.len);
            for (comp.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, arg, name, replacement);
            }
            cloned.* = .{ .component = .{
                .base = try cloneExprWithSubst(ctx, comp.base, name, replacement),
                .name = comp.name,
                .args = args,
                .has_parens = comp.has_parens,
            } };
        },
        .dim_range => |range| {
            cloned.* = .{ .dim_range = .{
                .lower = if (range.lower) |lower| try cloneExprWithSubst(ctx, lower, name, replacement) else null,
                .upper = try cloneExprWithSubst(ctx, range.upper, name, replacement),
                .stride = if (range.stride) |stride_expr| try cloneExprWithSubst(ctx, stride_expr, name, replacement) else null,
                .assumed_shape = range.assumed_shape,
            } };
        },
        .implied_do => |implied| {
            if (std.ascii.eqlIgnoreCase(implied.var_name, name)) {
                cloned.* = .{ .implied_do = implied };
            } else {
                const items = try ctx.allocator.alloc(*ast.Expr, implied.items.len);
                for (implied.items, 0..) |item, idx| {
                    items[idx] = try cloneExprWithSubst(ctx, item, name, replacement);
                }
                cloned.* = .{ .implied_do = .{
                    .items = items,
                    .var_name = implied.var_name,
                    .start = try cloneExprWithSubst(ctx, implied.start, name, replacement),
                    .end = try cloneExprWithSubst(ctx, implied.end, name, replacement),
                    .step = if (implied.step) |step_expr| try cloneExprWithSubst(ctx, step_expr, name, replacement) else null,
                } };
            }
        },
    }
    return cloned;
}

fn evalStaticIntExpr(ctx: *Context, expr_node: *ast.Expr) EmitError!?i64 {
    switch (expr_node.*) {
        .call_or_subscript => |call| {
            if (std.ascii.eqlIgnoreCase(call.name, "lbound")) {
                if (call.args.len == 0 or call.args.len > 2) return null;
                const target_name = switch (call.args[0].*) {
                    .identifier => |ident| ident,
                    else => return null,
                };
                const dim_idx = if (call.args.len == 2) blk: {
                    const dim_val = (try evalStaticIntExpr(ctx, call.args[1])) orelse return null;
                    if (dim_val <= 0) return null;
                    break :blk @as(usize, @intCast(dim_val - 1));
                } else 0;
                const sym = ctx.findSymbol(target_name) orelse return null;
                if (dim_idx >= sym.dims.len) return null;
                return const_eval.evalStaticDimLower(ctx, sym.dims[dim_idx], evalStaticIntExpr) orelse return null;
            }
            if (std.ascii.eqlIgnoreCase(call.name, "ubound")) {
                if (call.args.len == 0 or call.args.len > 2) return null;
                const target_name = switch (call.args[0].*) {
                    .identifier => |ident| ident,
                    else => return null,
                };
                const dim_idx = if (call.args.len == 2) blk: {
                    const dim_val = (try evalStaticIntExpr(ctx, call.args[1])) orelse return null;
                    if (dim_val <= 0) return null;
                    break :blk @as(usize, @intCast(dim_val - 1));
                } else 0;
                const sym = ctx.findSymbol(target_name) orelse return null;
                if (dim_idx >= sym.dims.len) return null;
                const lower = const_eval.evalStaticDimLower(ctx, sym.dims[dim_idx], evalStaticIntExpr) orelse return null;
                const extent = const_eval.evalStaticDimExtent(ctx, sym.dims[dim_idx], evalStaticIntExpr) orelse return null;
                return lower + extent - 1;
            }
            if (try evalStaticParameterArrayElementInt(ctx, call)) |value| return value;
        },
        else => {},
    }

    const resolver = evaluator.ConstResolver{
        .ctx = ctx,
        .resolveFn = const_eval.resolveStaticConstValue,
        .arrayExtentFn = const_eval.resolveStaticArrayExtent,
    };
    const value = try evaluator.evalConst(expr_node, resolver) orelse return null;
    return switch (value) {
        .integer => |int_value| int_value,
        else => null,
    };
}

fn evalStaticLogicalExpr(ctx: *Context, expr_node: *ast.Expr) EmitError!?bool {
    return switch (expr_node.*) {
        .literal => |lit| switch (lit.kind) {
            .logical => const_eval.parseStaticLogicalLiteral(lit.text),
            .integer => blk: {
                const value = std.fmt.parseInt(i64, lit.text, 10) catch break :blk null;
                break :blk value != 0;
            },
            else => null,
        },
        .identifier => |name| blk: {
            const sym = ctx.findSymbol(name) orelse break :blk null;
            if (sym.kind != .parameter or sym.const_value == null) break :blk null;
            break :blk switch (sym.const_value.?) {
                .logical => |value| value,
                else => null,
            };
        },
        .unary => |un| if (un.op == .not) blk: {
            const inner = (try evalStaticLogicalExpr(ctx, un.expr)) orelse break :blk null;
            break :blk !inner;
        } else null,
        .binary => |bin| switch (bin.op) {
            .and_ => blk: {
                const lhs = (try evalStaticLogicalExpr(ctx, bin.left)) orelse break :blk null;
                const rhs = (try evalStaticLogicalExpr(ctx, bin.right)) orelse break :blk null;
                break :blk lhs and rhs;
            },
            .or_ => blk: {
                const lhs = (try evalStaticLogicalExpr(ctx, bin.left)) orelse break :blk null;
                const rhs = (try evalStaticLogicalExpr(ctx, bin.right)) orelse break :blk null;
                break :blk lhs or rhs;
            },
            .eq, .ne, .lt, .le, .gt, .ge => blk: {
                const lhs = (try evalStaticIntExpr(ctx, bin.left)) orelse break :blk null;
                const rhs = (try evalStaticIntExpr(ctx, bin.right)) orelse break :blk null;
                break :blk switch (bin.op) {
                    .eq => lhs == rhs,
                    .ne => lhs != rhs,
                    .lt => lhs < rhs,
                    .le => lhs <= rhs,
                    .gt => lhs > rhs,
                    .ge => lhs >= rhs,
                    else => unreachable,
                };
            },
            else => null,
        },
        .call_or_subscript => |call| blk: {
            if (!std.ascii.eqlIgnoreCase(call.name, "any") or call.args.len != 1) break :blk null;
            const items = try flattenArrayValuedExprItems(ctx, call.args[0]) orelse break :blk null;
            for (items) |item| {
                const item_value = (try evalStaticLogicalExpr(ctx, item)) orelse break :blk null;
                if (item_value) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        else => null,
    };
}

fn evalStaticParameterArrayElementInt(ctx: *Context, call: ast.CallOrSubscript) EmitError!?i64 {
    const sym = ctx.findSymbol(call.name) orelse return null;
    if (sym.dims.len == 0 or call.args.len != sym.dims.len) return null;

    const items = try flattenParameterArrayIdentifier(ctx, call.name) orelse return null;
    const linear_index = try const_eval.evalStaticArrayLinearIndex(ctx, sym, call.args, evalStaticIntExpr) orelse return null;
    if (linear_index >= items.len) return null;
    return evalStaticIntExpr(ctx, items[linear_index]);
}
