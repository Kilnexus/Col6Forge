const ast = @import("../../ast/nodes.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");
const constants = @import("resolve_const.zig");

pub fn applySelectTypeCharacterClauseLength(
    self: *context.Context,
    base_spec: symbols.TypeSpec,
    clause: ast.SelectTypeClause,
) !symbols.TypeSpec {
    if (clause.char_len_deferred) return base_spec.withCharacterLength(.deferred, null);
    const len_expr = clause.char_len orelse return base_spec.withCharacterLength(.constant, 1);
    if (len_expr.* == .literal and len_expr.literal.kind == .assumed_size) {
        return base_spec.withCharacterLength(.assumed, null);
    }
    if (try constants.evalConst(self, len_expr)) |value| {
        return switch (value) {
            .integer => |int_val| base_spec.withCharacterLength(.constant, if (int_val < 0) 0 else @as(usize, @intCast(int_val))),
            else => error.InvalidCharLen,
        };
    }
    return error.InvalidCharLen;
}
