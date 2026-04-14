const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const constants = @import("../resolve_const.zig");
const resolve_expr = @import("../resolve_expr.zig");

pub fn validateTypeDeclBinding(self: *context.Context, decl: ast.TypeDecl) !void {
    if (!decl.bind_c) return;
    try validateBindingSpec(self, decl.items.len, decl.bind_name_expr);
}

pub fn applyBindEntity(self: *context.Context, decl: ast.BindEntityDecl) !void {
    try validateBindingSpec(self, decl.names.len, decl.bind_name_expr);
}

fn validateBindingSpec(
    self: *context.Context,
    item_count: usize,
    bind_name_expr: ?*ast.Expr,
) !void {
    const expr = bind_name_expr orelse return;
    if (item_count > 1) {
        emitBindNameDiagnostic(self, "Multiple identifiers provided with single NAME= specifier");
        return error.DuplicateDeclaration;
    }

    const type_spec = resolve_expr.exprTypeSpec(self, expr) catch null;
    if (type_spec == null or type_spec.?.lowered_kind != .character or type_spec.?.kind_value orelse 1 != 1 or resolve_expr.exprRank(self, expr) != 0) {
        emitBindNameDiagnostic(self, "scalar of default character kind");
        return error.InvalidArgumentCount;
    }

    const value = try constants.evalConst(self, expr);
    switch (value orelse {
        emitBindNameDiagnostic(self, "constant expression");
        return error.InvalidArgumentCount;
    }) {
        .string => {},
        else => {
            emitBindNameDiagnostic(self, "scalar of default character kind");
            return error.InvalidArgumentCount;
        },
    }
}

fn emitBindNameDiagnostic(self: *context.Context, message: []const u8) void {
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnostic(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.invalid_argument_count.code,
        message,
        decl_source.text,
    );
}
