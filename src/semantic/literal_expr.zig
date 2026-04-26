const std = @import("std");
const ast = @import("../ast/nodes.zig");

pub fn integer(comptime T: type, expr: *ast.Expr) ?T {
    return switch (expr.*) {
        .literal => |lit| switch (lit.kind) {
            .integer => std.fmt.parseInt(T, lit.text, 10) catch null,
            else => null,
        },
        else => null,
    };
}
