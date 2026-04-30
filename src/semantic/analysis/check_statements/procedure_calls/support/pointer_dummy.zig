const ast = @import("../../../../../ast/nodes.zig");
const context = @import("../../../context.zig");
const expr_attributes = @import("../../../expr_attributes.zig");
const diagnostics = @import("../../procedure_call_diagnostics.zig");

pub fn checkActual(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
) anyerror!void {
    if (!formal.pointer) return;
    if (formal.intent == .in) {
        if (expr_attributes.isPointerEntity(self, actual_expr) or expr_attributes.isCAddressableDataTarget(self, actual_expr)) return;
    } else if (expr_attributes.isPointerEntity(self, actual_expr)) {
        return;
    }
    return diagnostics.emitProcedureActualCallDiagnostic(
        self,
        callee_name,
        formal.name,
        actual_expr,
        error.InvalidArgumentCount,
        "must be a pointer",
    );
}
