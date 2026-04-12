const std = @import("std");
const ast = @import("../../../../input.zig");
const context = @import("../../../codegen/context/mod.zig");
const expr = @import("../../../codegen/expression/mod.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;
const EmitError = anyerror;

fn makeIntegerLiteralExpr(ctx: *Context, value: i64) EmitError!*ast.Expr {
    const node = try ctx.allocator.create(ast.Expr);
    node.* = .{
        .literal = .{
            .kind = .integer,
            .text = try ctx.intLiteral(value),
        },
    };
    return node;
}

fn collapseRangeArgForIo(
    ctx: *Context,
    declared_dim: *ast.Expr,
    arg: *ast.Expr,
    owned_literals: *std.array_list.Managed(*ast.Expr),
) EmitError!*ast.Expr {
    if (arg.* != .dim_range) return arg;
    const range = arg.dim_range;
    if (range.lower) |lower| return lower;
    if (declared_dim.* == .dim_range) {
        if (declared_dim.dim_range.lower) |lower| return lower;
    }
    const fallback_one = try makeIntegerLiteralExpr(ctx, 1);
    try owned_literals.append(fallback_one);
    return fallback_one;
}

pub fn emitCollapsedRangeSubscriptValue(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
) EmitError!?ValueRef {
    const sym = ctx.findSymbol(call.name) orelse return null;
    if (sym.dims.len == 0) return null;
    if (call.args.len != sym.dims.len) return null;

    var has_range = false;
    for (call.args) |arg| {
        if (arg.* == .dim_range) {
            has_range = true;
            break;
        }
    }
    if (!has_range) return null;

    var owned_literals = std.array_list.Managed(*ast.Expr).init(ctx.allocator);
    defer {
        for (owned_literals.items) |node| {
            ctx.allocator.destroy(node);
        }
        owned_literals.deinit();
    }

    const lowered_args = try ctx.allocator.alloc(*ast.Expr, call.args.len);
    defer ctx.allocator.free(lowered_args);
    for (call.args, 0..) |arg, idx| {
        lowered_args[idx] = try collapseRangeArgForIo(ctx, sym.dims[idx], arg, &owned_literals);
    }

    var lowered_expr = ast.Expr{
        .call_or_subscript = .{
            .name = call.name,
            .args = lowered_args,
        },
    };
    return try expr.emitExpr(ctx, builder, &lowered_expr);
}

pub fn emitCollapsedSubstringSectionValue(
    ctx: *Context,
    builder: anytype,
    expr_node: *ast.Expr,
) EmitError!?ValueRef {
    if (expr_node.* != .substring) return null;
    const sub = expr_node.substring;
    const kind = ctx.ref_kinds.get(@as(usize, @intFromPtr(expr_node))) orelse .unknown;
    if (kind != .subscript) return null;

    const sym = ctx.findSymbol(sub.name) orelse return null;
    if (sym.dims.len != 1 or sub.args.len != 0) return null;

    var assumed_size = ast.Expr{ .literal = .{ .kind = .assumed_size, .text = "*" } };
    const upper_expr = sub.end orelse &assumed_size;
    var range_expr = ast.Expr{ .dim_range = .{
        .lower = sub.start,
        .upper = upper_expr,
        .stride = null,
        .assumed_shape = false,
    } };
    var args = [_]*ast.Expr{&range_expr};
    return emitCollapsedRangeSubscriptValue(ctx, builder, .{
        .name = sub.name,
        .args = args[0..],
    });
}

fn lowerCollapsedSectionExpr(
    ctx: *Context,
    expr_node: *ast.Expr,
    owned_literals: *std.array_list.Managed(*ast.Expr),
) EmitError!?*ast.Expr {
    return switch (expr_node.*) {
        .call_or_subscript => |call| blk: {
            const sym = ctx.findSymbol(call.name) orelse break :blk null;
            if (sym.dims.len == 0 or call.args.len != sym.dims.len) break :blk null;

            var changed = false;
            const lowered_args = try ctx.allocator.alloc(*ast.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| {
                lowered_args[idx] = try collapseRangeArgForIo(ctx, sym.dims[idx], arg, owned_literals);
                if (lowered_args[idx] != arg) changed = true;
            }
            if (!changed) break :blk null;

            const lowered = try ctx.allocator.create(ast.Expr);
            lowered.* = .{ .call_or_subscript = .{
                .name = call.name,
                .args = lowered_args,
            } };
            break :blk lowered;
        },
        .component => |comp| blk: {
            const lowered_base = (try lowerCollapsedSectionExpr(ctx, comp.base, owned_literals)) orelse comp.base;
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse {
                if (lowered_base == comp.base) break :blk null;
                const lowered = try ctx.allocator.create(ast.Expr);
                lowered.* = .{ .component = .{
                    .base = lowered_base,
                    .name = comp.name,
                    .args = comp.args,
                    .has_parens = comp.has_parens,
                } };
                break :blk lowered;
            };
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse break :blk null;
            if (component.procedure) break :blk null;

            var changed = lowered_base != comp.base;
            var lowered_args = comp.args;
            if (comp.args.len != 0 and comp.args.len == component.dims.len) {
                lowered_args = try ctx.allocator.alloc(*ast.Expr, comp.args.len);
                for (comp.args, 0..) |arg, idx| {
                    lowered_args[idx] = try collapseRangeArgForIo(ctx, component.dims[idx], arg, owned_literals);
                    if (lowered_args[idx] != arg) changed = true;
                }
            }
            if (!changed) break :blk null;

            const lowered = try ctx.allocator.create(ast.Expr);
            lowered.* = .{ .component = .{
                .base = lowered_base,
                .name = comp.name,
                .args = lowered_args,
                .has_parens = comp.has_parens,
            } };
            break :blk lowered;
        },
        else => null,
    };
}

pub fn emitCollapsedComponentSectionValue(
    ctx: *Context,
    builder: anytype,
    expr_node: *ast.Expr,
) EmitError!?ValueRef {
    var owned_literals = std.array_list.Managed(*ast.Expr).init(ctx.allocator);
    defer {
        for (owned_literals.items) |node| {
            ctx.allocator.destroy(node);
        }
        owned_literals.deinit();
    }

    const lowered = (try lowerCollapsedSectionExpr(ctx, expr_node, &owned_literals)) orelse return null;
    return try expr.emitExpr(ctx, builder, lowered);
}

pub fn emitCollapsedUnknownCountWholeArrayValue(
    ctx: *Context,
    builder: anytype,
    name: []const u8,
) EmitError!?ValueRef {
    const assumed = try ctx.allocator.create(ast.Expr);
    assumed.* = .{ .literal = .{ .kind = .assumed_size, .text = "*" } };
    const stride = try makeIntegerLiteralExpr(ctx, 1);
    const range = try ctx.allocator.create(ast.Expr);
    range.* = .{ .dim_range = .{
        .lower = null,
        .upper = assumed,
        .stride = stride,
        .assumed_shape = false,
    } };
    var args = [_]*ast.Expr{range};
    return emitCollapsedRangeSubscriptValue(ctx, builder, .{
        .name = name,
        .args = args[0..],
    });
}
