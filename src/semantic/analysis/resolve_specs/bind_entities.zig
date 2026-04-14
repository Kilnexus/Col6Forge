const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const constants = @import("../resolve_const.zig");
const resolve_expr = @import("../resolve_expr.zig");
const symbols_mod = @import("../resolve_symbols.zig");
const bind_c_shared = @import("bind_c_shared.zig");
const decl_diag = @import("../resolve_decls_diag_helpers.zig");

pub fn validateTypeDeclBinding(self: *context.Context, decl: ast.TypeDecl) !void {
    if (!decl.bind_c) return;
    try validateBindingSpec(self, decl.items.len, decl.bind_name_expr);
    try validateTypeDeclBindCContext(self, decl);
}

pub fn applyBindEntity(self: *context.Context, decl: ast.BindEntityDecl) !void {
    try validateBindingSpec(self, decl.names.len + decl.common_blocks.len, decl.bind_name_expr);
    try validateBindEntityContext(self, decl);
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
    decl_diag.emitCurrentDeclSimpleDiagnostic(self, catalog.semantic.invalid_argument_count.code, message);
}

fn validateTypeDeclBindCContext(self: *context.Context, decl: ast.TypeDecl) !void {
    if (self.unit.kind != .module) {
        emitCurrentDeclDiagnostic(self, invalidTypeDeclBindCMessage(decl));
        return error.UnexpectedTypeDecl;
    }

    if (decl.type_kind != .character) return;
    for (decl.items) |item| {
        if (bind_c_shared.characterDeclaratorHasLengthOne(item)) continue;
        emitCurrentDeclDiagnostic(self, "BIND(C) CHARACTER entity must have length one");
        return error.InvalidCharLen;
    }
}

fn validateBindEntityContext(self: *context.Context, decl: ast.BindEntityDecl) !void {
    if (decl.names.len == 0) return;

    for (decl.names) |name| {
        if (bindEntityNameIsProcedure(self, name) or self.unit.kind != .module) {
            const message = std.fmt.allocPrint(
                self.arena,
                "'{s}' cannot be BIND(C); BIND(C) statement can only be used for variables or common blocks",
                .{name},
            ) catch "BIND(C) statement can only be used for variables or common blocks";
            emitCurrentDeclDiagnostic(self, message);
            return error.UnexpectedTypeDecl;
        }
    }
}

fn invalidTypeDeclBindCMessage(decl: ast.TypeDecl) []const u8 {
    if (decl.type_kind == .integer and decl.items.len == 1 and decl.items[0].dims.len == 0) {
        return "Entity cannot be declared with BIND(C)";
    }
    return "Entity cannot be BIND(C)";
}

fn bindEntityNameIsProcedure(self: *context.Context, name: []const u8) bool {
    if (self.unit.kind == .subroutine and std.ascii.eqlIgnoreCase(self.unit.name, name)) return true;
    if (self.unit.kind == .function) {
        const result_name = self.unit.result_name orelse self.unit.name;
        if (std.ascii.eqlIgnoreCase(self.unit.name, name) or std.ascii.eqlIgnoreCase(result_name, name)) return true;
    }
    return symbols_mod.lookupKnownProcedureSig(self, name) != null;
}

fn emitCurrentDeclDiagnostic(self: *context.Context, message: []const u8) void {
    decl_diag.emitCurrentDeclSimpleDiagnostic(self, catalog.semantic.unexpected_type_decl.code, message);
}
