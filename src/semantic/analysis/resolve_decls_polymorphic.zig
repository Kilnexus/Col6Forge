const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");

pub fn validateTypeDecl(
    self: *context.Context,
    decl: ast.TypeDecl,
    declared_type: symbols.TypeSpec,
    sym: symbols.Symbol,
) !void {
    if (declared_type.lowered_kind != .derived or !declared_type.polymorphic) return;
    if (self.unit.kind == .function) {
        const result_name = self.unit.result_name orelse self.unit.name;
        if (std.ascii.eqlIgnoreCase(sym.name, result_name) and declared_type.derived_type_name == null) return;
    }
    if (sym.storage == .dummy or sym.is_allocatable or sym.is_pointer) return;

    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    const line = if (decl_source.line == 0) 1 else decl_source.line;
    const column = if (decl_source.column == 0) 1 else decl_source.column;
    if (decl.parameter or hasSeparateParameterSpec(self, sym.name)) {
        self.setDiagnosticDetailed(
            line,
            column,
            catalog.semantic.invalid_unlimited_polymorphic_entity.code,
            "cannot have the PARAMETER attribute",
            decl_source.text,
            &.{.{ .text = "A polymorphic entity may not be declared with the PARAMETER attribute." }},
            &.{.{ .text = "Remove PARAMETER or make the entity nonpolymorphic." }},
        );
        return error.InvalidUnlimitedPolymorphicEntity;
    }

    self.setDiagnosticDetailed(
        line,
        column,
        catalog.semantic.invalid_unlimited_polymorphic_entity.code,
        "must be dummy, allocatable or pointer",
        decl_source.text,
        &.{.{ .text = "A polymorphic data entity must be a dummy argument, POINTER, or ALLOCATABLE object." }},
        &.{.{ .text = "Add POINTER or ALLOCATABLE, or move this CLASS entity to a dummy argument list." }},
    );
    return error.InvalidUnlimitedPolymorphicEntity;
}

pub fn hasSeparateParameterSpec(self: *context.Context, target_name: []const u8) bool {
    for (self.unit.decls) |decl| {
        switch (decl) {
            .parameter => |param_decl| {
                for (param_decl.assigns) |assign| {
                    if (std.ascii.eqlIgnoreCase(assign.name, target_name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}
