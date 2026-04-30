const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const context = @import("context.zig");
const deferred_shape = @import("deferred_shape.zig");

pub fn validateTypeDecl(self: *context.Context, decl: ast.TypeDecl, item: ast.Declarator) !void {
    if (!decl.parameter) return;
    if (!deferred_shape.hasDeferredShape(item.dims)) return;
    const source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.duplicate_declaration.code,
        "PARAMETER array cannot be automatic or of deferred shape",
        source.text,
    );
    return error.DuplicateDeclaration;
}
