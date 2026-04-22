const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");

pub fn shapeSignatureForDims(arena: std.mem.Allocator, dims: []const *ast.Expr) ![]const []const u8 {
    if (dims.len == 0) return &.{};
    const out = try arena.alloc([]const u8, dims.len);
    for (dims, 0..) |dim, idx| {
        out[idx] = try dimensionExtentSignature(arena, dim);
    }
    return out;
}

fn dimensionExtentSignature(arena: std.mem.Allocator, dim: *ast.Expr) ![]const u8 {
    return switch (dim.*) {
        .dim_range => |range| blk: {
            if (range.assumed_shape and range.lower == null) break :blk ":";
            const lower = range.lower orelse break :blk try exprCanonicalText(arena, range.upper);
            if (try linearExprFromAst(arena, range.upper)) |upper_linear| {
                if (try linearExprFromAst(arena, lower)) |lower_linear| {
                    const extent = try linearExprAddConst(
                        arena,
                        try linearExprSub(arena, upper_linear, lower_linear),
                        1,
                    );
                    break :blk try linearExprCanonicalText(arena, extent);
                }
            }
            break :blk try std.fmt.allocPrint(
                arena,
                "({s})-({s})+1",
                .{ try exprCanonicalText(arena, range.upper), try exprCanonicalText(arena, lower) },
            );
        },
        else => try exprCanonicalText(arena, dim),
    };
}

const LinearExpr = struct {
    terms: std.StringHashMap(i64),
    constant: i64 = 0,

    fn init(arena: std.mem.Allocator) LinearExpr {
        return .{ .terms = std.StringHashMap(i64).init(arena) };
    }
};

fn linearExprFromAst(arena: std.mem.Allocator, expr_node: *ast.Expr) !?LinearExpr {
    return switch (expr_node.*) {
        .identifier => |name| blk: {
            var expr = LinearExpr.init(arena);
            try expr.terms.put(name, 1);
            break :blk expr;
        },
        .literal => |lit| switch (lit.kind) {
            .integer => blk: {
                var expr = LinearExpr.init(arena);
                expr.constant = std.fmt.parseInt(i64, lit.text, 10) catch return null;
                break :blk expr;
            },
            else => null,
        },
        .unary => |un| blk: {
            var inner = (try linearExprFromAst(arena, un.expr)) orelse break :blk null;
            switch (un.op) {
                .plus => break :blk inner,
                .minus => {
                    var it = inner.terms.iterator();
                    while (it.next()) |entry| entry.value_ptr.* *= -1;
                    inner.constant *= -1;
                    break :blk inner;
                },
                else => break :blk null,
            }
        },
        .binary => |bin| blk: {
            const left = (try linearExprFromAst(arena, bin.left)) orelse break :blk null;
            const right = (try linearExprFromAst(arena, bin.right)) orelse break :blk null;
            break :blk switch (bin.op) {
                .add => try linearExprCombine(arena, left, right, 1),
                .sub => try linearExprCombine(arena, left, right, -1),
                else => null,
            };
        },
        else => null,
    };
}

fn linearExprCombine(
    arena: std.mem.Allocator,
    left: LinearExpr,
    right: LinearExpr,
    right_sign: i64,
) !?LinearExpr {
    var out = LinearExpr.init(arena);
    out.constant = left.constant + right_sign * right.constant;
    var left_it = left.terms.iterator();
    while (left_it.next()) |entry| {
        try out.terms.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    var right_it = right.terms.iterator();
    while (right_it.next()) |entry_in| {
        const entry = try out.terms.getOrPut(entry_in.key_ptr.*);
        if (entry.found_existing) {
            entry.value_ptr.* += right_sign * entry_in.value_ptr.*;
        } else {
            entry.value_ptr.* = right_sign * entry_in.value_ptr.*;
        }
    }
    return out;
}

fn linearExprSub(arena: std.mem.Allocator, left: LinearExpr, right: LinearExpr) !LinearExpr {
    return (try linearExprCombine(arena, left, right, -1)).?;
}

fn linearExprAddConst(arena: std.mem.Allocator, expr: LinearExpr, constant: i64) !LinearExpr {
    var out = LinearExpr.init(arena);
    out.constant = expr.constant + constant;
    var it = expr.terms.iterator();
    while (it.next()) |entry| {
        try out.terms.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

fn linearExprCanonicalText(arena: std.mem.Allocator, expr: LinearExpr) ![]const u8 {
    var parts = std.array_list.Managed([]const u8).init(arena);
    defer parts.deinit();

    var it = expr.terms.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const coeff = entry.value_ptr.*;
        if (coeff == 0) continue;
        if (coeff == 1) {
            try parts.append(try std.fmt.allocPrint(arena, "{s}", .{name}));
        } else if (coeff == -1) {
            try parts.append(try std.fmt.allocPrint(arena, "-{s}", .{name}));
        } else {
            try parts.append(try std.fmt.allocPrint(arena, "{d}*{s}", .{ coeff, name }));
        }
    }
    if (expr.constant != 0 or parts.items.len == 0) {
        try parts.append(try std.fmt.allocPrint(arena, "{d}", .{expr.constant}));
    }
    return joinSignedTerms(arena, parts.items);
}

fn joinSignedTerms(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(arena);
    defer out.deinit();
    for (parts, 0..) |part, idx| {
        if (idx == 0) {
            try out.appendSlice(part);
            continue;
        }
        if (part.len != 0 and part[0] == '-') {
            try out.appendSlice(part);
        } else {
            try out.append('+');
            try out.appendSlice(part);
        }
    }
    return out.toOwnedSlice();
}

fn exprCanonicalText(arena: std.mem.Allocator, expr_node: *ast.Expr) ![]const u8 {
    return switch (expr_node.*) {
        .identifier => |name| std.ascii.allocLowerString(arena, name),
        .literal => |lit| try arena.dupe(u8, lit.text),
        .component => |comp| blk: {
            const base = try exprCanonicalText(arena, comp.base);
            const name = try std.ascii.allocLowerString(arena, comp.name);
            if (comp.args.len == 0) {
                break :blk try std.fmt.allocPrint(arena, "{s}%{s}", .{ base, name });
            }
            var args = std.array_list.Managed([]const u8).init(arena);
            defer args.deinit();
            for (comp.args) |arg| try args.append(try exprCanonicalText(arena, arg));
            break :blk try std.fmt.allocPrint(arena, "{s}%{s}({s})", .{ base, name, try std.mem.join(arena, ",", args.items) });
        },
        .unary => |un| try std.fmt.allocPrint(arena, "{s}{s}", .{
            switch (un.op) {
                .plus => "+",
                .minus => "-",
                .not => ".not.",
            },
            try exprCanonicalText(arena, un.expr),
        }),
        .binary => |bin| try std.fmt.allocPrint(arena, "({s}){s}({s})", .{
            try exprCanonicalText(arena, bin.left),
            switch (bin.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                .concat => "//",
                .power => "**",
                .eq => "==",
                .ne => "/=",
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
                .and_ => ".and.",
                .or_ => ".or.",
                .eqv => ".eqv.",
                .neqv => ".neqv.",
            },
            try exprCanonicalText(arena, bin.right),
        }),
        .call_or_subscript => |call| blk: {
            var args = std.array_list.Managed([]const u8).init(arena);
            defer args.deinit();
            for (call.args) |arg| try args.append(try exprCanonicalText(arena, arg));
            break :blk try std.fmt.allocPrint(arena, "{s}({s})", .{ call.name, try std.mem.join(arena, ",", args.items) });
        },
        else => "<expr>",
    };
}
