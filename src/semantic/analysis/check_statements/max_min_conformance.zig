const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../context.zig");
const resolve_expr = @import("../resolve_expr.zig");
const expr_diagnostics = @import("../expr_diagnostics.zig");
const leaf_helpers = @import("leaf_helpers.zig");
const static_shapes = @import("static_shapes.zig");

pub fn checkStaticMaxMinConformance(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) anyerror!void {
    if (!leaf_helpers.isHomogeneousMaxMinIntrinsic(name)) return;

    var expected_rank: ?usize = null;
    var expected_shape: ?[]const i64 = null;
    for (args) |arg| {
        // MIN/MAX scalar actuals broadcast; array actuals must be mutually conformable.
        const actual_rank = resolve_expr.exprRank(self, arg);
        if (actual_rank == 0) continue;
        if (expected_rank == null) {
            expected_rank = actual_rank;
            expected_shape = static_shapes.staticShapeForExpr(self, arg);
            continue;
        }
        if (expected_rank.? != actual_rank) {
            return expr_diagnostics.emitExprAssignmentMismatch(self, arg, "Incompatible ranks");
        }
        const actual_shape = static_shapes.staticShapeForExpr(self, arg) orelse continue;
        const prior_shape = expected_shape orelse {
            expected_shape = actual_shape;
            continue;
        };
        if (prior_shape.len != actual_shape.len) {
            return expr_diagnostics.emitExprAssignmentMismatch(self, arg, "Different shape for arguments");
        }
        for (prior_shape, actual_shape) |expected_extent, actual_extent| {
            if (expected_extent != actual_extent) {
                return expr_diagnostics.emitExprAssignmentMismatch(self, arg, "Different shape for arguments");
            }
        }
    }
}
