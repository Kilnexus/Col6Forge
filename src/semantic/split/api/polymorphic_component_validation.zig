const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const diagnostic = @import("../../diagnostic.zig");

pub fn validateProgram(
    program: ast.Program,
    diag_bag: *diagnostic.Bag,
) !void {
    var saw_error = false;
    for (program.units) |unit| {
        for (unit.decls, 0..) |decl, decl_idx| {
            if (decl != .derived_type_def) continue;
            const derived = decl.derived_type_def;
            for (derived.components, 0..) |type_decl, component_idx| {
                if (!type_decl.polymorphic or type_decl.allocatable or type_decl.pointer) continue;
                const source = if (derived.component_sources.len > 0 and component_idx < derived.component_sources.len)
                    derived.component_sources[component_idx]
                else if (decl_idx < unit.decl_sources.len)
                    unit.decl_sources[decl_idx]
                else
                    ast.DeclSource{};
                diag_bag.setDetailed(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.invalid_unlimited_polymorphic_entity.code,
                    "must be allocatable or pointer",
                    source.text,
                    &.{.{ .text = "A polymorphic derived-type component must have the ALLOCATABLE or POINTER attribute." }},
                    &.{.{ .text = "Add ALLOCATABLE or POINTER to this CLASS component declaration." }},
                );
                saw_error = true;
            }
        }
    }
    if (saw_error) return error.InvalidUnlimitedPolymorphicEntity;
}
