const ast = @import("../../ast/nodes.zig");

pub fn hasDeferredShape(dims: []const *ast.Expr) bool {
    for (dims) |dim| {
        switch (dim.*) {
            .dim_range => |range| {
                if (range.assumed_shape and range.lower == null) continue;
                return false;
            },
            else => return false,
        }
    }
    return dims.len != 0;
}
