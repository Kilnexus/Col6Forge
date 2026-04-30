const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const context = @import("context.zig");

pub fn validateOptionalDummyLength(
    self: *context.Context,
    item: ast.Declarator,
) !void {
    if (self.unit.kind != .function) return;
    const result_name = self.unit.result_name orelse self.unit.name;
    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) return;
    const len_expr = item.char_len orelse return;
    if (!exprReferencesOptionalDummy(self, len_expr)) return;

    const source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_char_len.code,
        "cannot be OPTIONAL",
        source.text,
    );
    return error.InvalidCharLen;
}

fn exprReferencesOptionalDummy(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| dummyIsOptional(self, name),
        .literal => false,
        .array_constructor => |ctor| exprListReferencesOptionalDummy(self, ctor.items),
        .call_or_subscript => |call| exprListReferencesOptionalDummy(self, call.args),
        .substring => |sub| exprListReferencesOptionalDummy(self, sub.args) or
            (sub.start != null and exprReferencesOptionalDummy(self, sub.start.?)) or
            (sub.end != null and exprReferencesOptionalDummy(self, sub.end.?)),
        .component => |comp| exprReferencesOptionalDummy(self, comp.base) or exprListReferencesOptionalDummy(self, comp.args),
        .dim_range => |range| (range.lower != null and exprReferencesOptionalDummy(self, range.lower.?)) or
            exprReferencesOptionalDummy(self, range.upper) or
            (range.stride != null and exprReferencesOptionalDummy(self, range.stride.?)),
        .unary => |un| exprReferencesOptionalDummy(self, un.expr),
        .binary => |bin| exprReferencesOptionalDummy(self, bin.left) or exprReferencesOptionalDummy(self, bin.right),
        .complex_literal => |lit| exprReferencesOptionalDummy(self, lit.real) or exprReferencesOptionalDummy(self, lit.imag),
        .implied_do => |implied| exprListReferencesOptionalDummy(self, implied.items) or
            exprReferencesOptionalDummy(self, implied.start) or
            exprReferencesOptionalDummy(self, implied.end) or
            (implied.step != null and exprReferencesOptionalDummy(self, implied.step.?)),
    };
}

fn exprListReferencesOptionalDummy(self: *context.Context, exprs: []const *ast.Expr) bool {
    for (exprs) |expr| {
        if (exprReferencesOptionalDummy(self, expr)) return true;
    }
    return false;
}

fn dummyIsOptional(self: *context.Context, name: []const u8) bool {
    for (self.unit.args) |arg_name| {
        if (std.ascii.eqlIgnoreCase(arg_name, name)) break;
    } else return false;

    for (self.unit.decls) |decl| {
        switch (decl) {
            .optional => |optional_decl| {
                for (optional_decl.names) |decl_name| {
                    if (std.ascii.eqlIgnoreCase(decl_name, name)) return true;
                }
            },
            .type_decl => |type_decl| {
                if (!type_decl.optional) continue;
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}
