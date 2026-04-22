const std = @import("std");
const ast = @import("../../../ast/nodes.zig");

const Decl = ast.Decl;

pub fn annotateDeclBindingOwners(
    allocator: std.mem.Allocator,
    decls: []const Decl,
    owner_name: []const u8,
    owner_kind: ast.LexicalOwnerKind,
) ![]const Decl {
    if (decls.len == 0) return decls;

    var needs_copy = false;
    for (decls) |decl_node| {
        if (decl_node != .derived_type_def) continue;
        for (decl_node.derived_type_def.bindings) |binding| {
            if (binding.owner_name == null or binding.owner_kind == null) {
                needs_copy = true;
                break;
            }
        }
        if (needs_copy) break;
    }
    if (!needs_copy) return decls;

    const annotated = try allocator.alloc(Decl, decls.len);
    for (decls, 0..) |decl_node, idx| {
        annotated[idx] = switch (decl_node) {
            .derived_type_def => |derived| .{ .derived_type_def = try annotateDerivedBindingOwners(allocator, derived, owner_name, owner_kind) },
            else => decl_node,
        };
    }
    return annotated;
}

fn annotateDerivedBindingOwners(
    allocator: std.mem.Allocator,
    derived: ast.DerivedTypeDef,
    owner_name: []const u8,
    owner_kind: ast.LexicalOwnerKind,
) !ast.DerivedTypeDef {
    var needs_copy = false;
    for (derived.bindings) |binding| {
        if (binding.owner_name == null or binding.owner_kind == null) {
            needs_copy = true;
            break;
        }
    }
    if (!needs_copy) return derived;

    const bindings = try allocator.alloc(ast.TypeBoundProcedureBinding, derived.bindings.len);
    for (derived.bindings, 0..) |binding, idx| {
        bindings[idx] = binding;
        if (bindings[idx].owner_name == null) bindings[idx].owner_name = owner_name;
        if (bindings[idx].owner_kind == null) bindings[idx].owner_kind = owner_kind;
    }

    return .{
        .name = derived.name,
        .parent_name = derived.parent_name,
        .abstract = derived.abstract,
        .sequence = derived.sequence,
        .bind_c = derived.bind_c,
        .components = derived.components,
        .component_sources = derived.component_sources,
        .procedure_components = derived.procedure_components,
        .procedure_component_sources = derived.procedure_component_sources,
        .bindings = bindings,
        .final_subroutines = derived.final_subroutines,
    };
}
