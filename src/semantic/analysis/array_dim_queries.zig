const ast = @import("../../ast/nodes.zig");
const context = @import("context.zig");
const symbols_mod = @import("resolve_symbols.zig");

pub fn resolveArrayLowerBound(
    self: *context.Context,
    name: []const u8,
    dim: usize,
    comptime evalLowerFn: fn (*context.Context, *ast.Expr) ?i64,
) ?i64 {
    if (dim == 0) return null;
    const idx = symbols_mod.findSymbolIndex(self, name) orelse return null;
    const sym = self.symbols.items[idx];
    if (sym.dims.len == 0 or dim > sym.dims.len) return null;
    return evalLowerFn(self, sym.dims[dim - 1]);
}
