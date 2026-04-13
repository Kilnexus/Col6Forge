const std = @import("std");
const ast = @import("../ast/nodes.zig");

pub fn stmtUsesWholeSelectorArray(stmt: ast.Stmt, selector_name: []const u8) bool {
    return switch (stmt.node) {
        .write => |write| blk: {
            for (write.args) |arg| {
                if (exprIsBareIdentifier(arg, selector_name)) break :blk true;
            }
            break :blk false;
        },
        .read => |read| blk: {
            for (read.args) |arg| {
                if (exprIsBareIdentifier(arg, selector_name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn exprIsBareIdentifier(expr_node: *ast.Expr, name: []const u8) bool {
    return switch (expr_node.*) {
        .identifier => |ident| std.ascii.eqlIgnoreCase(ident, name),
        else => false,
    };
}
