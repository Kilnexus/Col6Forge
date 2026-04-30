const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const context = @import("../../../context.zig");
const resolve_expr = @import("../../../resolve_expr.zig");
const expr_diagnostics = @import("../../../expr_diagnostics.zig");

pub const CheckError = anyerror;

pub fn checkExprArgs(self: *context.Context, name: []const u8, args: []*ast.Expr) CheckError!void {
    const is_cshift = std.ascii.eqlIgnoreCase(name, "cshift");
    const is_eoshift = std.ascii.eqlIgnoreCase(name, "eoshift");
    if (!is_cshift and !is_eoshift) return;
    if (args.len > 1) {
        const shift_spec = try resolve_expr.exprTypeSpec(self, args[1]);
        if (shift_spec.lowered_kind != .integer) {
            return expr_diagnostics.emitExprInvalidArgument(self, args[1], "must be INTEGER");
        }
    }
    if (is_eoshift and args.len < 3 and args.len > 0) {
        const array_spec = try resolve_expr.exprTypeSpec(self, args[0]);
        if (array_spec.lowered_kind == .derived) {
            return expr_diagnostics.emitExprInvalidArgument(self, args[0], "Missing 'boundary' argument to 'eoshift' intrinsic");
        }
    }
}
