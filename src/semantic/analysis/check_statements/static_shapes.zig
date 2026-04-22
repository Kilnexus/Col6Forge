const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../context.zig");
const resolve_const = @import("../resolve_const.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");

pub fn staticShapeForExpr(self: *context.Context, expr_node: *ast.Expr) ?[]const i64 {
    return switch (expr_node.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk null;
            break :blk staticShapeForDims(self, self.symbols.items[idx].dims);
        },
        .array_constructor => |ctor| blk: {
            const count = staticArrayConstructorElementCount(self, ctor) orelse break :blk null;
            const out = self.arena.alloc(i64, 1) catch return null;
            out[0] = count;
            break :blk out;
        },
        .call_or_subscript => |call| staticShapeForCallOrSubscript(self, expr_node, call),
        .substring => |sub| staticShapeForSubstring(self, sub),
        .unary => |un| staticShapeForExpr(self, un.expr),
        .binary => |bin| staticShapeForBinary(self, bin),
        .implied_do => |implied| blk: {
            const count = staticImpliedDoElementCount(self, implied) orelse break :blk null;
            const out = self.arena.alloc(i64, 1) catch return null;
            out[0] = count;
            break :blk out;
        },
        else => null,
    };
}

fn staticShapeForBinary(
    self: *context.Context,
    bin: ast.BinaryExpr,
) ?[]const i64 {
    const left_rank = resolve_expr.exprRank(self, bin.left);
    const right_rank = resolve_expr.exprRank(self, bin.right);
    if (left_rank == 0 and right_rank == 0) return null;
    if (left_rank == 0) return staticShapeForExpr(self, bin.right);
    if (right_rank == 0) return staticShapeForExpr(self, bin.left);

    const left_shape = staticShapeForExpr(self, bin.left) orelse return null;
    const right_shape = staticShapeForExpr(self, bin.right) orelse return null;
    if (left_shape.len != right_shape.len) return null;
    for (left_shape, right_shape) |lhs, rhs| {
        if (lhs != rhs) return null;
    }
    return left_shape;
}

pub fn staticShapeForDims(self: *context.Context, dims: []*ast.Expr) ?[]const i64 {
    if (dims.len == 0) return null;
    const out = self.arena.alloc(i64, dims.len) catch return null;
    for (dims, 0..) |dim_expr, idx| {
        out[idx] = staticDimExtent(self, dim_expr) orelse return null;
    }
    return out;
}

pub fn staticIntValue(self: *context.Context, expr_node: *ast.Expr) ?i64 {
    const value = resolve_const.evalConst(self, expr_node) catch return null;
    return switch (value orelse return null) {
        .integer => |v| v,
        else => null,
    };
}

fn staticShapeForCallOrSubscript(
    self: *context.Context,
    expr_node: *ast.Expr,
    call: ast.CallOrSubscript,
) ?[]const i64 {
    if (std.ascii.eqlIgnoreCase(call.name, "sum") or std.ascii.eqlIgnoreCase(call.name, "product")) {
        if (call.args.len < 2) return null;
        const base_shape = staticShapeForExpr(self, call.args[0]) orelse return null;
        const dim = staticIntValue(self, call.args[1]) orelse return null;
        if (dim <= 0) return null;
        const dim_index: usize = @intCast(dim - 1);
        if (dim_index >= base_shape.len) return null;
        if (base_shape.len == 1) {
            const out = self.arena.alloc(i64, 0) catch return null;
            return out;
        }
        const out = self.arena.alloc(i64, base_shape.len - 1) catch return null;
        var out_idx: usize = 0;
        for (base_shape, 0..) |extent, idx| {
            if (idx == dim_index) continue;
            out[out_idx] = extent;
            out_idx += 1;
        }
        return out;
    }

    if (std.ascii.eqlIgnoreCase(call.name, "matmul")) {
        if (call.args.len != 2) return null;
        const lhs_shape = staticShapeForExpr(self, call.args[0]) orelse return null;
        const rhs_shape = staticShapeForExpr(self, call.args[1]) orelse return null;
        const lhs_rank = resolve_expr.exprRank(self, call.args[0]);
        const rhs_rank = resolve_expr.exprRank(self, call.args[1]);
        if (!((lhs_rank == 1 or lhs_rank == 2) and (rhs_rank == 1 or rhs_rank == 2))) return null;
        const lhs_inner = if (lhs_rank == 1) lhs_shape[0] else lhs_shape[1];
        const rhs_inner = rhs_shape[0];
        if (lhs_inner != rhs_inner) return null;

        if (lhs_rank == 2 and rhs_rank == 2) {
            const out = self.arena.alloc(i64, 2) catch return null;
            out[0] = lhs_shape[0];
            out[1] = rhs_shape[1];
            return out;
        }
        if (lhs_rank == 2 and rhs_rank == 1) {
            const out = self.arena.alloc(i64, 1) catch return null;
            out[0] = lhs_shape[0];
            return out;
        }
        if (lhs_rank == 1 and rhs_rank == 2) {
            const out = self.arena.alloc(i64, 1) catch return null;
            out[0] = rhs_shape[1];
            return out;
        }
        return self.arena.alloc(i64, 0) catch null;
    }

    return staticShapeForSubscript(self, expr_node, call);
}

fn staticShapeForSubscript(
    self: *context.Context,
    expr_node: *ast.Expr,
    call: ast.CallOrSubscript,
) ?[]const i64 {
    _ = expr_node;
    const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse return null;
    const sym = self.symbols.items[idx];
    if (sym.dims.len == 0 or call.args.len != sym.dims.len) return null;

    var rank: usize = 0;
    for (call.args) |arg| {
        if (arg.* == .dim_range) rank += 1;
    }
    if (rank == 0) return null;

    const out = self.arena.alloc(i64, rank) catch return null;
    var out_idx: usize = 0;
    for (call.args) |arg| {
        if (arg.* != .dim_range) continue;
        out[out_idx] = staticDimExtent(self, arg) orelse return null;
        out_idx += 1;
    }
    return out;
}

fn staticShapeForSubstring(
    self: *context.Context,
    sub: ast.SubstringExpr,
) ?[]const i64 {
    if (sub.args.len != 0) return null;
    const idx = resolve_symbols.findSymbolIndex(self, sub.name) orelse return null;
    const sym = self.symbols.items[idx];
    if (sym.dims.len != 1) return null;

    const dim_expr = sym.dims[0];
    const extent = if (sub.start == null and sub.end == null)
        staticDimExtent(self, dim_expr)
    else
        staticSubstringSectionExtent(self, dim_expr, sub);
    const out = self.arena.alloc(i64, 1) catch return null;
    out[0] = extent orelse return null;
    return out;
}

fn staticSubstringSectionExtent(
    self: *context.Context,
    dim_expr: *ast.Expr,
    sub: ast.SubstringExpr,
) ?i64 {
    switch (dim_expr.*) {
        .dim_range => |range| {
            var compat_range = ast.Expr{ .dim_range = .{
                .lower = if (sub.start) |start_expr| start_expr else range.lower,
                .upper = if (sub.end) |end_expr| end_expr else range.upper,
            } };
            return staticDimExtent(self, &compat_range);
        },
        else => {
            var compat_range = ast.Expr{ .dim_range = .{
                .lower = if (sub.start) |start_expr| start_expr else null,
                .upper = if (sub.end) |end_expr| end_expr else dim_expr,
            } };
            return staticDimExtent(self, &compat_range);
        },
    }
}

fn staticDimExtent(self: *context.Context, expr_node: *ast.Expr) ?i64 {
    return switch (expr_node.*) {
        .dim_range => |range| blk: {
            if (range.stride != null) break :blk null;
            const maybe_upper = staticIntValue(self, range.upper);
            const maybe_lower = if (range.lower) |lower_expr| staticIntValue(self, lower_expr) else 1;
            if (maybe_upper != null and maybe_lower != null) {
                const upper = maybe_upper.?;
                const lower = maybe_lower.?;
                if (upper < lower) break :blk 0;
                break :blk upper - lower + 1;
            }

            const upper_affine = affineIntExpr(range.upper) orelse break :blk null;
            const lower_affine = if (range.lower) |lower_expr|
                affineIntExpr(lower_expr) orelse break :blk null
            else
                AffineIntExpr{ .base_name = null, .offset = 1 };
            if (!sameAffineBase(upper_affine.base_name, lower_affine.base_name)) break :blk null;
            break :blk upper_affine.offset - lower_affine.offset + 1;
        },
        else => staticIntValue(self, expr_node),
    };
}

fn staticArrayConstructorElementCount(
    self: *context.Context,
    ctor: ast.ArrayConstructor,
) ?i64 {
    var total: i64 = 0;
    for (ctor.items) |item| {
        const count = staticElementCountForExpr(self, item) orelse return null;
        total = std.math.add(i64, total, count) catch return null;
    }
    return total;
}

fn staticImpliedDoElementCount(
    self: *context.Context,
    implied: ast.ImpliedDo,
) ?i64 {
    const start = staticIntValue(self, implied.start) orelse return null;
    const end = staticIntValue(self, implied.end) orelse return null;
    const step = if (implied.step) |step_expr| staticIntValue(self, step_expr) orelse return null else 1;
    const iterations = impliedDoIterationCount(start, end, step) orelse return null;

    var per_iteration: i64 = 0;
    for (implied.items) |item| {
        const count = staticElementCountForExpr(self, item) orelse return null;
        per_iteration = std.math.add(i64, per_iteration, count) catch return null;
    }
    return std.math.mul(i64, iterations, per_iteration) catch return null;
}

fn staticElementCountForExpr(self: *context.Context, expr_node: *ast.Expr) ?i64 {
    if (resolve_expr.exprRank(self, expr_node) == 0) return 1;
    const shape = staticShapeForExpr(self, expr_node) orelse return null;
    return shapeElementCount(shape);
}

fn shapeElementCount(shape: []const i64) ?i64 {
    var total: i64 = 1;
    for (shape) |extent| {
        total = std.math.mul(i64, total, extent) catch return null;
    }
    return total;
}

fn impliedDoIterationCount(start: i64, end: i64, step: i64) ?i64 {
    if (step == 0) return null;
    if (step > 0) {
        if (start > end) return 0;
        return @divTrunc(end - start, step) + 1;
    }
    if (start < end) return 0;
    return @divTrunc(start - end, -step) + 1;
}

const AffineIntExpr = struct {
    base_name: ?[]const u8,
    offset: i64,
};

fn affineIntExpr(expr_node: *ast.Expr) ?AffineIntExpr {
    return switch (expr_node.*) {
        .identifier => |name| .{ .base_name = name, .offset = 0 },
        .literal => |lit| blk: {
            if (lit.kind != .integer) break :blk null;
            break :blk .{ .base_name = null, .offset = std.fmt.parseInt(i64, lit.text, 10) catch return null };
        },
        .unary => |un| blk: {
            const inner = affineIntExpr(un.expr) orelse break :blk null;
            break :blk switch (un.op) {
                .plus => inner,
                .minus => if (inner.base_name == null) .{ .base_name = null, .offset = -inner.offset } else null,
                else => null,
            };
        },
        .binary => |bin| blk: {
            const left = affineIntExpr(bin.left) orelse break :blk null;
            const right = affineIntExpr(bin.right) orelse break :blk null;
            switch (bin.op) {
                .add => {
                    if (left.base_name != null and right.base_name != null) break :blk null;
                    if (left.base_name) |name| break :blk .{ .base_name = name, .offset = left.offset + right.offset };
                    if (right.base_name) |name| break :blk .{ .base_name = name, .offset = left.offset + right.offset };
                    break :blk .{ .base_name = null, .offset = left.offset + right.offset };
                },
                .sub => {
                    if (left.base_name != null and right.base_name != null) break :blk null;
                    if (left.base_name) |name| {
                        if (right.base_name != null) break :blk null;
                        break :blk .{ .base_name = name, .offset = left.offset - right.offset };
                    }
                    if (right.base_name != null) break :blk null;
                    break :blk .{ .base_name = null, .offset = left.offset - right.offset };
                },
                else => break :blk null,
            }
        },
        else => null,
    };
}

fn sameAffineBase(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.ascii.eqlIgnoreCase(lhs.?, rhs.?);
}
