const ast = @import("../../../../../ast/nodes.zig");
const common_diag = @import("../../../../../common/diagnostic.zig");
const catalog = @import("../../../../../common/error_catalog.zig");
const context = @import("../../../context.zig");
const do_iterators = @import("../../do_iterators.zig");

pub fn rejectActiveDoControlForIntent(
    self: *context.Context,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
) anyerror!void {
    const intent = formal.intent orelse return;
    if (intent != .out and intent != .inout) return;
    const control = do_iterators.activeControlForDefinition(self, actual_expr) orelse return;
    const source = self.sourceForExpr(actual_expr) orelse ast.SourceRef{};
    const related = [_]common_diag.DiagnosticSpan{.{
        .file_path = "",
        .line = if (control.source.line == 0) 1 else control.source.line,
        .column = if (control.source.column == 0) 1 else control.source.column,
        .line_text = control.source.text,
        .label = "DO loop begins here",
    }};
    const message = switch (intent) {
        .out => "Active DO variable actual argument is not definable; INTENT(OUT) gives it an undefined value",
        .inout => "Active DO variable actual argument is not definable for INTENT(INOUT)",
        else => unreachable,
    };
    self.setDiagnosticStructured(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
        "active DO variable used as definable actual argument",
        &.{},
        &.{},
        related[0..],
    );
    return error.AssignmentTypeMismatch;
}
