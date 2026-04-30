const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const symbols = @import("../../../symbol/mod.zig");
const context = @import("../../context.zig");
const symbols_mod = @import("../../resolve_symbols.zig");

pub fn structureConstructorTypeSpec(
    self: *context.Context,
    name: []const u8,
    sym: symbols.Symbol,
) ?symbols.TypeSpec {
    const info = symbols_mod.lookupDerivedType(self, name) orelse return null;
    const local_derived_shadow = sym.is_host_associated and symbols_mod.hasLocalDerivedType(self, name);
    if (sym.is_intrinsic or (!local_derived_shadow and sym.is_external) or sym.dims.len != 0) return null;
    if (symbols_mod.lookupKnownProcedureSig(self, name) != null) return null;
    if (!local_derived_shadow and sym.type_explicit and sym.loweredKind() != .derived) return null;
    return symbols.TypeSpec.fromDerived(info.name);
}

pub fn validateStructureConstructorActuals(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
    ctor_spec: symbols.TypeSpec,
    comptime deps: anytype,
) anyerror!void {
    const type_name = ctor_spec.derived_type_name orelse return error.InvalidArgumentCount;
    const components = try collectStructureConstructorComponents(self, type_name);
    if (args.len != components.len) return error.InvalidArgumentCount;
    for (args, 0..) |arg, idx| {
        const actual_spec = try deps.exprTypeSpecCached(self, arg);
        const component = components[idx];
        try rejectCharacterPointerLengthMismatch(self, arg, component, actual_spec);
        if (!deps.dummyArgTypeCompatible(self, component.type_spec, actual_spec)) {
            _ = name;
            return error.ArgumentTypeMismatch;
        }
    }
}

fn collectStructureConstructorComponents(
    self: *context.Context,
    type_name: []const u8,
) anyerror![]const context.Context.DerivedTypeInfo.ComponentInfo {
    var components = std.array_list.Managed(context.Context.DerivedTypeInfo.ComponentInfo).init(self.arena);
    try appendStructureConstructorComponents(self, type_name, &components);
    return components.toOwnedSlice();
}

fn appendStructureConstructorComponents(
    self: *context.Context,
    type_name: []const u8,
    out: *std.array_list.Managed(context.Context.DerivedTypeInfo.ComponentInfo),
) anyerror!void {
    const derived = symbols_mod.lookupDerivedType(self, type_name) orelse return error.InvalidArgumentCount;
    if (derived.parent_name) |parent_name| {
        try appendStructureConstructorComponents(self, parent_name, out);
    }
    for (derived.components) |component| {
        try out.append(component);
    }
}

fn rejectCharacterPointerLengthMismatch(
    self: *context.Context,
    arg: *ast.Expr,
    component: context.Context.DerivedTypeInfo.ComponentInfo,
    actual_spec: symbols.TypeSpec,
) anyerror!void {
    const component_spec = component.type_spec;
    if (!component.pointer or component_spec.lowered_kind != .character or actual_spec.lowered_kind != .character) return;
    if (component_spec.char_len_kind == .deferred or actual_spec.char_len_kind == .deferred) return;
    const component_len = component_spec.char_len orelse return;
    const actual_len = actual_spec.char_len orelse return;
    if (component_len == actual_len) return;
    const message = std.fmt.allocPrint(
        self.arena,
        "Unequal character lengths ({d}/{d})",
        .{ component_len, actual_len },
    ) catch "Unequal character lengths";
    const source = self.sourceForExpr(arg) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
    );
    return error.ArgumentTypeMismatch;
}
