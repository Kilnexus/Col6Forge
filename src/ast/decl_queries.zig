const ast = @import("nodes.zig");

pub fn exportedName(decl_node: ast.Decl) ?[]const u8 {
    return switch (decl_node) {
        .derived_type_def => |derived| derived.name,
        .interface_block => |interface_block| interface_block.name,
        .type_decl => |type_decl| if (type_decl.items.len == 1) type_decl.items[0].name else null,
        .procedure => |procedure_decl| if (procedure_decl.items.len == 1) procedure_decl.items[0].name else null,
        .parameter => |parameter_decl| if (parameter_decl.assigns.len == 1) parameter_decl.assigns[0].name else null,
        else => null,
    };
}
