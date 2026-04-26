const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const context = @import("context.zig");

pub fn emitExprAssignmentMismatch(
    self: *context.Context,
    expr: *ast.Expr,
    message: []const u8,
) anyerror {
    const source = self.sourceForExpr(expr) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
    );
    return error.AssignmentTypeMismatch;
}

pub fn emitExprInvalidArgument(
    self: *context.Context,
    expr: *ast.Expr,
    message: []const u8,
) anyerror {
    const source = self.sourceForExpr(expr) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_argument_count.code,
        message,
        source.text,
    );
    return error.InvalidArgumentCount;
}
