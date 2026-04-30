const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const resolve_const = @import("../resolve_const.zig");

pub const CheckError = anyerror;

pub fn rejectDivisionByZero(
    self: *context.Context,
    expr_node: *ast.Expr,
    bin: ast.BinaryExpr,
    comptime deps: anytype,
) CheckError!void {
    if (bin.op != .div) return;
    if (shouldDeferArrayConstructorDivisionByZero(bin, deps)) return;
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

pub fn rejectZeroStride(self: *context.Context, stride: *ast.Expr) CheckError!void {
    const value = (try resolve_const.evalConst(self, stride)) orelse return;
    const zero = switch (value) {
        .integer => |int| int == 0,
        else => false,
    };
    if (!zero) return;
    const source = self.sourceForExpr(stride) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_subscript_section.code,
        "Illegal stride of zero",
        source.text,
    );
    return error.InvalidSubscript;
}

fn shouldDeferArrayConstructorDivisionByZero(bin: ast.BinaryExpr, comptime deps: anytype) bool {
    const defer_array_ctor = comptime if (@hasField(@TypeOf(deps), "defer_array_constructor_division_by_zero"))
        deps.defer_array_constructor_division_by_zero
    else
        false;
    return defer_array_ctor and (isArrayConstructor(bin.left) or isArrayConstructor(bin.right));
}

fn isArrayConstructor(expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .array_constructor => true,
        else => false,
    };
}
