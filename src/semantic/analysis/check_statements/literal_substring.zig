const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const resolve_expr = @import("../resolve_expr.zig");

const internal_literal_substring_name = "__col6forge_substring";

pub fn isLiteralSubstringCall(name: []const u8) bool {
    return std.mem.eql(u8, name, internal_literal_substring_name);
}

pub fn checkBounds(self: *context.Context, args: []*ast.Expr) anyerror!void {
    if (args.len < 3) return;
    try checkIntegerBound(self, args[1]);
    try checkIntegerBound(self, args[2]);
}

fn checkIntegerBound(self: *context.Context, expr_node: *ast.Expr) anyerror!void {
    const spec = try resolve_expr.exprTypeSpec(self, expr_node);
    if (spec.lowered_kind == .integer) return;

    const source = self.sourceForExpr(expr_node) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_subscript_type.code,
        "must be of type INTEGER",
        source.text,
    );
    return error.InvalidSubscript;
}
