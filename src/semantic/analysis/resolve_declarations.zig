const ast = @import("../../ast/nodes.zig");
const context = @import("context.zig");
const decls = @import("resolve_decls.zig");
const specs = @import("resolve_specs/mod.zig");
const bind_entities = @import("resolve_specs/bind_entities.zig");

pub fn applyDecl(self: *context.Context, decl: ast.Decl) !void {
    switch (decl) {
        .type_decl => |type_decl| {
            try decls.applyTypeDecl(self, type_decl);
            try bind_entities.validateTypeDeclBinding(self, type_decl);
        },
        .procedure => |procedure_decl| try decls.applyProcedureDecl(self, procedure_decl),
        else => try specs.applySpec(self, decl),
    }
}
