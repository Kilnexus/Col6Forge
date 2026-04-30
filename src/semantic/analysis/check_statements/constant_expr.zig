const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const resolve_const = @import("../resolve_const.zig");

pub const CheckError = anyerror;

pub fn rejectDivisionByZero(
    self: *context.Context,
    expr_node: *ast.Expr,
    bin: ast.BinaryExpr,
) CheckError!void {
    if (bin.op != .div) return;
    const value = (try resolve_const.evalConst(self, bin.right)) orelse return;
    const zero = switch (value) {
        .integer => |int| int == 0,
        .real => |real| real.value == 0.0,
        .complex => |complex| complex.real == 0.0 and complex.imag == 0.0,
        else => false,
    };
    if (!zero) return;
    const source = self.sourceForExpr(expr_node) orelse self.sourceForExpr(bin.right) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.division_by_zero.code,
        "Division by zero at compile time",
        source.text,
    );
    return error.DivisionByZero;
}
