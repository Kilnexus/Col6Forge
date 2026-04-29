const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const expr_diagnostics = @import("../expr_diagnostics.zig");

const CheckError = anyerror;

pub fn emitCurrentStmtConstraint(self: *context.Context, message: []const u8) CheckError {
    const stmt = self.current_stmt orelse return error.AssignmentTypeMismatch;
    self.setDiagnostic(
        if (stmt.source_line == 0) 1 else stmt.source_line,
        if (stmt.source_column == 0) 1 else stmt.source_column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        stmt.source_text,
    );
    return error.AssignmentTypeMismatch;
}

pub fn emitExprConstraint(self: *context.Context, expr_node: *ast.Expr, message: []const u8) CheckError {
    return expr_diagnostics.emitExprAssignmentMismatch(self, expr_node, message);
}
