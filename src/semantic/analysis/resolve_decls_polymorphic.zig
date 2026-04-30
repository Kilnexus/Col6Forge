const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");
const symbols_mod = @import("resolve_symbols.zig");

pub fn validateTypeDecl(
    self: *context.Context,
    decl: ast.TypeDecl,
    declared_type: symbols.TypeSpec,
    sym: symbols.Symbol,
) !void {
    try validatePureIntentOutPolymorphicFinalizerConstraint(self, decl, declared_type, sym);
    try validatePureFunctionResultPolymorphicAllocatable(self, declared_type, sym);
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

fn validatePureFunctionResultPolymorphicAllocatable(
    self: *context.Context,
    declared_type: symbols.TypeSpec,
    sym: symbols.Symbol,
) !void {
    if (!self.unit.pure or self.unit.kind != .function) return;
    if (!isFunctionResultSymbol(self, sym.name)) return;
    if (declared_type.polymorphic and sym.is_allocatable) {
        emitPureFunctionResultDiagnostic(self, "function result is polymorphic allocatable");
        return error.InvalidUnlimitedPolymorphicEntity;
    }
    if (declared_type.lowered_kind != .derived) return;
    const derived_name = declared_type.derived_type_name orelse return;
    if (!derivedTypeHasPolymorphicAllocatableComponent(self, derived_name)) return;
    emitPureFunctionResultDiagnostic(self, "function result has polymorphic allocatable component");
    return error.InvalidUnlimitedPolymorphicEntity;
}

fn isFunctionResultSymbol(self: *context.Context, name: []const u8) bool {
    const result_name = self.unit.result_name orelse self.unit.name;
    return std.ascii.eqlIgnoreCase(name, result_name);
}

fn derivedTypeHasPolymorphicAllocatableComponent(self: *context.Context, derived_name: []const u8) bool {
    const info = symbols_mod.lookupDerivedType(self, derived_name) orelse return false;
    for (info.components) |component| {
        if (component.allocatable and component.type_spec.polymorphic) return true;
        if (component.type_spec.lowered_kind != .derived) continue;
        const component_type_name = component.type_spec.derived_type_name orelse continue;
        if (std.ascii.eqlIgnoreCase(component_type_name, derived_name)) continue;
        if (derivedTypeHasPolymorphicAllocatableComponent(self, component_type_name)) return true;
    }
    return false;
}

fn emitPureFunctionResultDiagnostic(self: *context.Context, message: []const u8) void {
    const source = self.unit.source;
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_unlimited_polymorphic_entity.code,
        message,
        source.text,
    );
}

fn validatePureIntentOutPolymorphicFinalizerConstraint(
    self: *context.Context,
    decl: ast.TypeDecl,
    declared_type: symbols.TypeSpec,
    sym: symbols.Symbol,
) !void {
    if (!self.unit.pure) return;
    if (sym.storage != .dummy or decl.intent != .out) return;
    if (declared_type.lowered_kind != .derived or !declared_type.polymorphic) return;
    const derived_name = declared_type.derived_type_name orelse return;
    if (!symbols_mod.derivedTypeHasImpureFinalizer(self, derived_name)) return;

    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnosticDetailed(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.invalid_unlimited_polymorphic_entity.code,
        "may not be polymorphic",
        decl_source.text,
        &.{.{ .text = "A PURE procedure may not have a polymorphic INTENT(OUT) dummy when finalization could invoke an impure FINAL subroutine." }},
        &.{.{ .text = "Make the dummy nonpolymorphic, or make the FINAL subroutine PURE." }},
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

pub fn validateInitializer(
    self: *context.Context,
    decl: ast.TypeDecl,
    declared_type: symbols.TypeSpec,
    item: ast.Declarator,
) !void {
    if (!decl.allocatable or !declared_type.polymorphic or item.init == null) return;

    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnosticDetailed(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.duplicate_declaration.code,
        "cannot have an initializer",
        decl_source.text,
        &.{.{ .text = "An allocatable polymorphic entity may not have a declarator initializer." }},
        &.{.{ .text = "Remove the initializer, or make the entity nonpolymorphic or nonallocatable." }},
    );
    return error.DuplicateDeclaration;
}
