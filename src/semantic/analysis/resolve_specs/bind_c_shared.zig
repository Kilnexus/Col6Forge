const std = @import("std");
const ast = @import("../../../ast/nodes.zig");

pub fn characterDeclaratorHasLengthOne(item: ast.Declarator) bool {
    const len_expr = item.char_len orelse return true;
    return switch (len_expr.*) {
        .literal => |lit| lit.kind == .integer and std.mem.eql(u8, lit.text, "1"),
        else => false,
    };
}
