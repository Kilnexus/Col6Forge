const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../context.zig");

pub fn wrapsIdentifierInParens(self: *context.Context, expr: *ast.Expr) bool {
    const name = switch (expr.*) {
        .identifier => |ident| ident,
        else => return false,
    };
    const source = self.sourceForExpr(expr) orelse return false;
    if (source.column == 0) return false;
    const start = source.column - 1;
    if (start >= source.text.len or start + name.len > source.text.len) return false;
    if (!std.ascii.eqlIgnoreCase(source.text[start .. start + name.len], name)) return false;

    var left = start;
    while (left > 0 and std.ascii.isWhitespace(source.text[left - 1])) : (left -= 1) {}
    if (left == 0 or source.text[left - 1] != '(') return false;

    var right = start + name.len;
    while (right < source.text.len and std.ascii.isWhitespace(source.text[right])) : (right += 1) {}
    return right < source.text.len and source.text[right] == ')';
}
