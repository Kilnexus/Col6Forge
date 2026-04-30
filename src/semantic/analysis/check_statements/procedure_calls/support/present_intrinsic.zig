const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const context = @import("../../../context.zig");

pub fn checkActual(
    self: *context.Context,
    expr_node: *ast.Expr,
    emitDiagnostic: fn (*context.Context, *ast.Expr, []const u8) anyerror,
) anyerror!void {
    if (!exprIsOptionalDummySubobject(self, expr_node)) return;
    return emitDiagnostic(self, expr_node, "must not be a subobject");
}

fn exprIsOptionalDummySubobject(self: *context.Context, expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .identifier => false,
        .call_or_subscript => |call| optionalDummyNameDeclared(self, call.name),
        .substring => |sub| optionalDummyNameDeclared(self, sub.name),
        .component => |comp| rootDesignatorIsOptionalDummy(self, comp.base),
        else => false,
    };
}

fn rootDesignatorIsOptionalDummy(self: *context.Context, expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .identifier => |name| optionalDummyNameDeclared(self, name),
        .call_or_subscript => |call| optionalDummyNameDeclared(self, call.name),
        .substring => |sub| optionalDummyNameDeclared(self, sub.name),
        .component => |comp| rootDesignatorIsOptionalDummy(self, comp.base),
        else => false,
    };
}

fn optionalDummyNameDeclared(self: *context.Context, name: []const u8) bool {
    var idx: usize = 0;
    while (idx < self.unit.decls.len) : (idx += 1) {
        const decl = self.unit.decls[idx];
        switch (decl) {
            .type_decl => |type_decl| {
                if (type_decl.optional and declaratorsContain(type_decl.items, name)) return true;
            },
            .procedure => |procedure_decl| {
                if (procedure_decl.optional and declaratorsContain(procedure_decl.items, name)) return true;
            },
            .optional => |optional_decl| {
                if (namesContain(optional_decl.names, name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn declaratorsContain(items: []const ast.Declarator, name: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
    }
    return false;
}

fn namesContain(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
    }
    return false;
}
