const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const procedure_pass = @import("../../../../common/procedure_pass.zig");
const context = @import("../../context.zig");
const symbols = @import("../../../symbol/mod.zig");
const symbols_mod = @import("../../resolve_symbols.zig");
const binding_search = @import("../../type_bound_binding_search.zig");
const procedure_interfaces = @import("../../check_statements/procedure_interfaces.zig");
const diagnostics = @import("diagnostics.zig");

const setBindingDiagnostic = diagnostics.setBindingDiagnostic;
const setBindingDiagnosticWithRelated = diagnostics.setBindingDiagnosticWithRelated;

pub fn validateDerivedBinding(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    binding: ast.TypeBoundProcedureBinding,
    binding_idx: usize,
) ?anyerror {
    if (binding.syntax_error_message) |message| {
        setBindingDiagnostic(self, binding, message);
        return error.DuplicateDeclaration;
    }
    if (binding.deferred and !derived.abstract) {
        setBindingDiagnostic(self, binding, "is not ABSTRACT");
        return error.DuplicateDeclaration;
    }
    if (binding.deferred and binding.interface_name == null) {
        setBindingDiagnostic(self, binding, "Interface must be specified");
        return error.DuplicateDeclaration;
    }
    if (binding.deferred and binding.non_overridable) {
        setBindingDiagnostic(self, binding, "cannot both be DEFERRED and NON_OVERRIDABLE");
        return error.DuplicateDeclaration;
    }
    if (binding.deferred and binding.implementation_name != null) {
        setBindingDiagnostic(self, binding, "binding is invalid for DEFERRED");
        return error.DuplicateDeclaration;
    }
    if (binding.interface_name) |iface_name| {
        if (bindingInterfaceIsGeneric(self, iface_name)) {
            setBindingDiagnostic(self, binding, "may not be generic");
            return error.UnexpectedTypeDecl;
        }
        if (bindingInterfaceIsStatementFunction(self, iface_name)) {
            setBindingDiagnostic(self, binding, "may not be a statement function");
            return error.UnexpectedTypeDecl;
        }
        if (symbols_mod.isIntrinsicName(iface_name)) {
            setBindingDiagnostic(self, binding, "Intrinsic procedure");
            return error.UnexpectedTypeDecl;
        }
    }
    if (binding.interface_name) |iface_name| {
        if (!bindingInterfaceExists(self, binding, iface_name)) {
            setBindingDiagnostic(self, binding, "must be explicit");
            return error.UnexpectedTypeDecl;
        }
    }
    if (binding.is_generic) {
        if (validateGenericBindingTarget(self, derived, binding)) |err| return err;
        return null;
    }
    if (findEarlierParsedGenericBindingIndex(derived.bindings, binding.name, binding_idx) != null) {
        setBindingDiagnostic(self, binding, "already a procedure");
        return error.DuplicateDeclaration;
    }
    if (ancestorHasGenericBinding(self, derived.parent_name, binding.name)) {
        setBindingDiagnostic(self, binding, "Cannot overwrite GENERIC");
        return error.DuplicateDeclaration;
    }
    if (binding.deferred and bindingOverridesConcreteParent(self, derived, binding.name)) {
        setBindingDiagnostic(self, binding, "must not be DEFERRED");
        return error.DuplicateDeclaration;
    }
    if (bindingOverridesNonOverridableParent(self, derived, binding.name)) {
        setBindingDiagnostic(self, binding, "NON_OVERRIDABLE");
        return error.DuplicateDeclaration;
    }
    if (derived.abstract and !binding.deferred and binding.interface_name != null and !bindingImplementationExists(self, binding)) {
        setBindingDiagnostic(self, binding, "should be declared DEFERRED");
        return error.DuplicateDeclaration;
    }
    if (validateBindingOverrideCompatibility(self, derived, binding)) |err| {
        return err;
    }
    if (validateBindingImplementationReference(self, binding)) |err| {
        return err;
    }
    if (validatePassedObjectDummyConstraints(self, binding)) |err| {
        return err;
    }
    return null;
}

fn validateGenericBindingTarget(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    binding: ast.TypeBoundProcedureBinding,
) ?anyerror {
    const target_name = binding.implementation_name orelse {
        setBindingDiagnostic(self, binding, "Undefined specific binding");
        return error.UnexpectedTypeDecl;
    };
    if (findParsedBindingByName(derived.bindings, target_name)) |target| {
        if (!target.is_generic) return null;
        setBindingDiagnostic(self, binding, "must target a specific binding");
        return error.UnexpectedTypeDecl;
    }
    if (findAncestorBindingByName(self, derived.parent_name, target_name)) |target| {
        if (!target.is_generic) return null;
        setBindingDiagnostic(self, binding, "must target a specific binding");
        return error.UnexpectedTypeDecl;
    }
    setBindingDiagnostic(self, binding, "Undefined specific binding");
    return error.UnexpectedTypeDecl;
}

pub fn validateGenericBindingFamilies(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
) ?anyerror {
    var handled = std.StringHashMap(void).init(self.arena);
    var first_error: ?anyerror = null;

    for (derived.bindings) |binding| {
        if (!binding.is_generic) continue;
        if (handled.contains(binding.name)) continue;
        handled.put(binding.name, {}) catch return error.OutOfMemory;
        if (validateGenericBindingFamily(self, derived, binding.name)) |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_error == null) first_error = err;
        }
    }
    return first_error;
}

fn validateGenericBindingFamily(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    generic_name: []const u8,
) ?anyerror {
    var current_family_list = std.array_list.Managed(ast.TypeBoundProcedureBinding).init(self.arena);
    for (derived.bindings) |binding| {
        if (!binding.is_generic) continue;
        if (!std.ascii.eqlIgnoreCase(binding.name, generic_name)) continue;
        current_family_list.append(binding) catch return error.OutOfMemory;
    }
    const current_family = current_family_list.items;
    if (current_family.len == 0) return null;

    var first_error: ?anyerror = null;
    const first_current = current_family[0];
    const first_current_idx = firstCurrentGenericBindingIndex(derived.bindings, generic_name).?;

    if (findEarlierParsedNonGenericBindingByName(derived.bindings, generic_name, first_current_idx) != null) {
        setBindingDiagnostic(self, first_current, "already a non-generic procedure");
        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
        first_error = error.DuplicateDeclaration;
    }
    if (ancestorHasNonGenericBinding(self, derived.parent_name, generic_name)) {
        setBindingDiagnostic(self, first_current, "cannot overwrite specific");
        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
        if (first_error == null) first_error = error.DuplicateDeclaration;
    }

    if (validateGenericBindingAccess(self, derived, current_family)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }
    if (validateGenericBindingDuplicates(self, derived, current_family)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }
    if (validateGenericBindingKinds(self, derived, current_family)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }
    if (validateGenericBindingAmbiguity(self, derived, current_family)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    return first_error;
}

fn validateGenericBindingAccess(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    current_family: []const ast.TypeBoundProcedureBinding,
) ?anyerror {
    const inherited_binding = firstAncestorGenericBindingByName(self, derived.parent_name, current_family[0].name);
    const expected_private = if (inherited_binding) |binding| binding.private else current_family[0].private;

    for (current_family, 0..) |binding, idx| {
        if (idx == 0 and inherited_binding == null) continue;
        if (binding.private == expected_private) continue;
        setBindingDiagnostic(self, binding, "same access");
        return error.DuplicateDeclaration;
    }
    return null;
}

fn validateGenericBindingDuplicates(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    current_family: []const ast.TypeBoundProcedureBinding,
) ?anyerror {
    var seen = std.StringHashMap(void).init(self.arena);
    collectAncestorGenericBindingTargets(self, derived.parent_name, current_family[0].name, &seen);

    for (current_family) |binding| {
        const target_name = binding.implementation_name orelse continue;
        if (seen.contains(target_name)) {
            setBindingDiagnostic(self, binding, "already defined as specific binding");
            return error.DuplicateDeclaration;
        }
        seen.put(target_name, {}) catch return error.OutOfMemory;
    }
    return null;
}

fn validateGenericBindingKinds(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    current_family: []const ast.TypeBoundProcedureBinding,
) ?anyerror {
    var baseline_kind: ?ast.ProgramUnitKind = null;

    var parent_name = derived.parent_name;
    while (parent_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse break;
        for (parent.bindings) |binding| {
            if (!binding.is_generic or !std.ascii.eqlIgnoreCase(binding.name, current_family[0].name)) continue;
            const target = genericBindingInfoTargetSpecific(self, parent, binding) orelse continue;
            baseline_kind = target.sig.kind;
            break;
        }
        if (baseline_kind != null) break;
        parent_name = parent.parent_name;
    }

    for (current_family) |binding| {
        const target = genericBindingTargetSpecific(self, derived, binding) orelse continue;
        const sig = target.sig;
        if (baseline_kind == null) {
            baseline_kind = sig.kind;
            continue;
        }
        if (baseline_kind.? == sig.kind) continue;
        setBindingDiagnosticWithRelated(self, current_family[0], "mixed FUNCTION/SUBROUTINE", &.{target.source}, "generic family first established here");
        return error.DuplicateDeclaration;
    }
    return null;
}

fn validateGenericBindingAmbiguity(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    current_family: []const ast.TypeBoundProcedureBinding,
) ?anyerror {
    var specifics = std.array_list.Managed(GenericBindingSpecific).init(self.arena);
    collectAncestorGenericBindingSpecifics(self, derived.parent_name, current_family[0].name, &specifics);
    var unresolved_current_specifics: usize = 0;
    for (current_family) |binding| {
        const target = genericBindingTargetSpecific(self, derived, binding) orelse {
            unresolved_current_specifics += 1;
            continue;
        };
        specifics.append(target) catch return error.OutOfMemory;
    }

    if (unresolved_current_specifics >= 2) {
        setBindingDiagnostic(self, current_family[0], "are ambiguous");
        return error.DuplicateDeclaration;
    }

    var i: usize = 0;
    while (i < specifics.items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < specifics.items.len) : (j += 1) {
            if (!genericBindingSpecificAmbiguous(specifics.items[i], specifics.items[j])) continue;
            const related = [_]ast.DeclSource{ specifics.items[i].source, specifics.items[j].source };
            setBindingDiagnosticWithRelated(self, current_family[0], "are ambiguous", related[0..], "conflicting generic binding specific here");
            return error.DuplicateDeclaration;
        }
    }
    return null;
}

pub fn bindingInterfaceIsGeneric(self: *context.Context, iface_name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const generic_name = decl.interface_block.name orelse continue;
        if (std.ascii.eqlIgnoreCase(generic_name, iface_name)) return true;
    }
    return false;
}

pub fn bindingInterfaceIsStatementFunction(self: *context.Context, iface_name: []const u8) bool {
    for (self.unit.stmts) |stmt| {
        if (stmt.node != .assignment) continue;
        const target = stmt.node.assignment.target;
        if (target.* != .call_or_subscript) continue;
        if (!std.ascii.eqlIgnoreCase(target.call_or_subscript.name, iface_name)) continue;
        if (target.call_or_subscript.args.len == 0) continue;
        for (target.call_or_subscript.args) |arg| {
            if (arg.* != .identifier) return false;
        }
        return true;
    }
    return false;
}

fn bindingInterfaceExists(
    self: *context.Context,
    binding: ast.TypeBoundProcedureBinding,
    iface_name: []const u8,
) bool {
    if (lookupQualifiedProcedureSig(self, binding.owner_name, iface_name) != null) return true;
    return symbols_mod.lookupKnownProcedureSig(self, iface_name) != null;
}

fn bindingImplementationExists(self: *context.Context, binding: ast.TypeBoundProcedureBinding) bool {
    const impl_name = binding.implementation_name orelse binding.name;
    if (lookupQualifiedProcedureSig(self, binding.owner_name, impl_name) != null) return true;
    return symbols_mod.lookupKnownProcedureSig(self, impl_name) != null;
}

fn validateBindingImplementationReference(
    self: *context.Context,
    binding: ast.TypeBoundProcedureBinding,
) ?anyerror {
    if (binding.deferred or binding.interface_name != null) return null;
    if (binding.owner_kind != .module) {
        setBindingDiagnostic(self, binding, "must be a module procedure");
        return error.UnexpectedTypeDecl;
    }

    const impl_name = binding.implementation_name orelse binding.name;
    if (procedure_interfaces.isAbstractInterfaceProcedure(self, impl_name)) {
        setBindingDiagnostic(self, binding, "explicit interface required");
        return error.UnexpectedTypeDecl;
    }
    if (bindingImplementationExists(self, binding)) return null;
    if (bindingHasVisibleSpecificInterface(self, impl_name) and !procedure_interfaces.isAbstractInterfaceProcedure(self, impl_name)) return null;
    if (bindingHasProcedureDeclWithoutExplicitInterface(self, impl_name)) {
        setBindingDiagnostic(self, binding, "explicit interface required");
        return error.UnexpectedTypeDecl;
    }

    setBindingDiagnostic(self, binding, "must be a module procedure");
    return error.UnexpectedTypeDecl;
}

fn bindingHasVisibleSpecificInterface(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        if (decl.interface_block.name != null) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return true;
        }
        for (decl.interface_block.specific_procedures) |proc_name| {
            if (std.ascii.eqlIgnoreCase(proc_name, name)) return true;
        }
        for (decl.interface_block.procedures) |proc_name| {
            if (std.ascii.eqlIgnoreCase(proc_name, name)) return true;
        }
        for (decl.interface_block.module_procedures) |proc_name| {
            if (std.ascii.eqlIgnoreCase(proc_name, name)) return true;
        }
    }
    return false;
}

fn bindingHasProcedureDeclWithoutExplicitInterface(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .procedure) continue;
        for (decl.procedure.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            return decl.procedure.interface == .none;
        }
    }
    if (symbols_mod.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.is_external and !sym.type_explicit) return true;
    }
    return false;
}

fn bindingOverridesConcreteParent(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    binding_name: []const u8,
) bool {
    var parent_name = derived.parent_name;
    while (parent_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse return false;
        if (findResolvedBindingByName(parent.bindings, binding_name)) |binding| {
            return !binding.deferred;
        }
        parent_name = parent.parent_name;
    }
    return false;
}

pub fn typeHasDeferredBindingRequirement(self: *context.Context, derived: ast.DerivedTypeDef) bool {
    for (derived.bindings) |binding| {
        if (binding.deferred) return true;
    }

    var handled = std.StringHashMap(void).init(self.arena);
    var parent_name = derived.parent_name;
    while (parent_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse break;
        for (parent.bindings) |binding| {
            if (handled.contains(binding.name)) continue;
            handled.put(binding.name, {}) catch return true;

            if (findParsedBindingByName(derived.bindings, binding.name)) |override| {
                if (override.deferred) return true;
                continue;
            }
            if (binding.deferred) return true;
        }
        parent_name = parent.parent_name;
    }
    return false;
}

fn bindingOverridesNonOverridableParent(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    binding_name: []const u8,
) bool {
    var parent_name = derived.parent_name;
    while (parent_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse return false;
        if (findResolvedBindingByName(parent.bindings, binding_name)) |binding| {
            return binding.non_overridable;
        }
        parent_name = parent.parent_name;
    }
    return false;
}

fn validateBindingOverrideCompatibility(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    binding: ast.TypeBoundProcedureBinding,
) ?anyerror {
    const parent_binding = findOverriddenParentBinding(self, derived, binding.name) orelse return null;
    const child_sig = bindingReferenceSig(self, binding) orelse return null;
    const parent_sig = bindingInfoReferenceSig(self, parent_binding) orelse return null;
    const parent_related = [_]ast.DeclSource{parent_binding.source};

    if (parent_sig.pure and !child_sig.pure) {
        setBindingDiagnosticWithRelated(self, binding, "must also be PURE", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (parent_sig.elemental and !child_sig.elemental) {
        setBindingDiagnosticWithRelated(self, binding, "must also be ELEMENTAL", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (!parent_sig.elemental and child_sig.elemental) {
        setBindingDiagnosticWithRelated(self, binding, "must not be ELEMENTAL", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (parent_sig.arg_count != child_sig.arg_count) {
        setBindingDiagnosticWithRelated(self, binding, "same number of formal arguments", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (parent_sig.kind == .subroutine and child_sig.kind != .subroutine) {
        setBindingDiagnosticWithRelated(self, binding, "must also be a SUBROUTINE", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (parent_sig.kind == .function and child_sig.kind != .function) {
        setBindingDiagnosticWithRelated(self, binding, "must also be a FUNCTION", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (parent_sig.kind == .function and child_sig.kind == .function and !bindingFunctionResultsMatch(parent_sig, child_sig)) {
        setBindingDiagnosticWithRelated(self, binding, "Type mismatch in function result", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (!parent_binding.private and binding.private) {
        setBindingDiagnosticWithRelated(self, binding, "must not be PRIVATE", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (parent_binding.nopass and !binding.nopass) {
        setBindingDiagnosticWithRelated(self, binding, "must also be NOPASS", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }
    if (!parent_binding.nopass and binding.nopass) {
        setBindingDiagnosticWithRelated(self, binding, "must also be PASS", parent_related[0..], "overridden parent binding here");
        return error.DuplicateDeclaration;
    }

    if (!parent_binding.nopass and !binding.nopass) {
        const parent_pass_idx = procedure_pass.procedurePassArgIndex(parent_sig.args, parent_binding.pass_name) orelse return null;
        const child_pass_idx = procedure_pass.procedurePassArgIndex(child_sig.args, binding.pass_name) orelse return null;
        if (parent_pass_idx != child_pass_idx) {
            setBindingDiagnosticWithRelated(self, binding, "same position", parent_related[0..], "overridden parent binding here");
            return error.DuplicateDeclaration;
        }
        if (validateOverridingDummyArguments(self, binding, parent_sig, child_sig, child_pass_idx)) |err| {
            return err;
        }
        return null;
    }

    if (validateOverridingDummyArguments(self, binding, parent_sig, child_sig, null)) |err| {
        return err;
    }
    return null;
}

fn findOverriddenParentBinding(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    binding_name: []const u8,
) ?context.Context.DerivedTypeInfo.BindingInfo {
    var parent_name = derived.parent_name;
    while (parent_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse return null;
        if (findResolvedBindingByName(parent.bindings, binding_name)) |binding| return binding;
        parent_name = parent.parent_name;
    }
    return null;
}

fn bindingInfoReferenceSig(
    self: *context.Context,
    binding: context.Context.DerivedTypeInfo.BindingInfo,
) ?context.Context.ProcedureSig {
    if (binding.interface_name) |iface_name| {
        if (lookupQualifiedProcedureSig(self, binding.owner_name, iface_name)) |sig| return sig;
        if (symbols_mod.lookupKnownProcedureSig(self, iface_name)) |sig| return sig;
    }
    const impl_name = binding.implementation_name orelse binding.name;
    if (lookupQualifiedProcedureSig(self, binding.owner_name, impl_name)) |sig| return sig;
    return symbols_mod.lookupKnownProcedureSig(self, impl_name);
}

fn bindingFunctionResultsMatch(
    parent_sig: context.Context.ProcedureSig,
    child_sig: context.Context.ProcedureSig,
) bool {
    const parent_result = parent_sig.result_type_spec orelse return child_sig.result_type_spec == null;
    const child_result = child_sig.result_type_spec orelse return false;
    if (parent_sig.result_rank != child_sig.result_rank) return false;
    return typeSpecsMatchForOverride(parent_result, child_result);
}

fn validateOverridingDummyArguments(
    self: *context.Context,
    binding: ast.TypeBoundProcedureBinding,
    parent_sig: context.Context.ProcedureSig,
    child_sig: context.Context.ProcedureSig,
    pass_idx: ?usize,
) ?anyerror {
    for (parent_sig.args, child_sig.args, 0..) |parent_arg, child_arg, idx| {
        if (pass_idx != null and idx == pass_idx.?) continue;
        if (!std.ascii.eqlIgnoreCase(parent_arg.name, child_arg.name)) {
            const message = std.fmt.allocPrint(self.arena, "should be named '{s}'", .{parent_arg.name}) catch "dummy argument name mismatch";
            setBindingDiagnostic(self, binding, message);
            return error.DuplicateDeclaration;
        }
        if (!typeSpecsMatchForOverride(parent_arg.type_spec, child_arg.type_spec) or parent_arg.rank != child_arg.rank) {
            const message = std.fmt.allocPrint(self.arena, "Type mismatch in argument '{s}'", .{parent_arg.name}) catch "dummy argument type mismatch";
            setBindingDiagnostic(self, binding, message);
            return error.DuplicateDeclaration;
        }
    }
    return null;
}

fn typeSpecsMatchForOverride(a: symbols.TypeSpec, b: symbols.TypeSpec) bool {
    if (a.lowered_kind != b.lowered_kind) return false;
    if (a.kind_value != null and b.kind_value != null and a.kind_value.? != b.kind_value.?) return false;
    if (a.lowered_kind == .character) {
        if (a.char_len_kind != b.char_len_kind) return false;
        if (a.char_len != b.char_len) return false;
    }
    if (a.lowered_kind == .derived) {
        if (a.polymorphic != b.polymorphic) return false;
        if (a.derived_type_name == null or b.derived_type_name == null) {
            return a.derived_type_name == null and b.derived_type_name == null;
        }
        if (!std.ascii.eqlIgnoreCase(a.derived_type_name.?, b.derived_type_name.?)) return false;
    }
    return true;
}

fn validatePassedObjectDummyConstraints(
    self: *context.Context,
    binding: ast.TypeBoundProcedureBinding,
) ?anyerror {
    if (binding.nopass) return null;

    const sig = bindingReferenceSig(self, binding) orelse return null;
    if (sig.args.len == 0) {
        setBindingDiagnostic(self, binding, "at least one argument");
        return error.DuplicateDeclaration;
    }
    const pass_idx = procedure_pass.procedurePassArgIndex(sig.args, binding.pass_name) orelse {
        if (binding.pass_name) |pass_name| {
            const message = std.fmt.allocPrint(self.arena, "no argument '{s}'", .{pass_name}) catch "no PASS argument";
            setBindingDiagnostic(self, binding, message);
            return error.DuplicateDeclaration;
        }
        setBindingDiagnostic(self, binding, "at least one argument");
        return error.DuplicateDeclaration;
    };
    if (pass_idx >= sig.args.len) return null;

    const pass_arg = sig.args[pass_idx];
    if (pass_arg.type_spec.lowered_kind != .derived or !pass_arg.type_spec.polymorphic) {
        setBindingDiagnostic(self, binding, "Non-polymorphic passed-object dummy argument");
        return error.DuplicateDeclaration;
    }
    if (pass_arg.rank != 0) {
        setBindingDiagnostic(self, binding, "must be scalar");
        return error.DuplicateDeclaration;
    }
    if (pass_arg.pointer) {
        setBindingDiagnostic(self, binding, "must not be POINTER");
        return error.DuplicateDeclaration;
    }
    if (pass_arg.allocatable) {
        setBindingDiagnostic(self, binding, "must not be ALLOCATABLE");
        return error.DuplicateDeclaration;
    }
    return null;
}

pub fn findUnitDerivedTypeDeclSource(self: *context.Context, target_name: []const u8) ?ast.DeclSource {
    for (self.unit.decls, 0..) |decl, decl_idx| {
        if (decl != .derived_type_def) continue;
        if (!std.ascii.eqlIgnoreCase(decl.derived_type_def.name, target_name)) continue;
        if (decl_idx < self.unit.decl_sources.len) return self.unit.decl_sources[decl_idx];
        return null;
    }
    return null;
}

fn bindingReferenceSig(
    self: *context.Context,
    binding: ast.TypeBoundProcedureBinding,
) ?context.Context.ProcedureSig {
    if (binding.interface_name) |iface_name| {
        if (lookupQualifiedProcedureSig(self, binding.owner_name, iface_name)) |sig| return sig;
        if (symbols_mod.lookupKnownProcedureSig(self, iface_name)) |sig| return sig;
    }
    const impl_name = binding.implementation_name orelse binding.name;
    if (lookupQualifiedProcedureSig(self, binding.owner_name, impl_name)) |sig| return sig;
    return symbols_mod.lookupKnownProcedureSig(self, impl_name);
}

const GenericBindingSpecific = struct {
    sig: context.Context.ProcedureSig,
    pass_idx: ?usize,
    source: ast.DeclSource,
};

fn genericBindingTargetSpecific(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    binding: ast.TypeBoundProcedureBinding,
) ?GenericBindingSpecific {
    const target_name = binding.implementation_name orelse return null;
    if (findParsedBindingByName(derived.bindings, target_name)) |target| {
        if (target.is_generic) return null;
        const sig = bindingReferenceSig(self, target) orelse return null;
        return .{
            .sig = sig,
            .pass_idx = if (target.nopass) null else procedure_pass.procedurePassArgIndex(sig.args, target.pass_name),
            .source = target.source,
        };
    }
    if (findAncestorBindingByName(self, derived.parent_name, target_name)) |target| {
        if (target.is_generic) return null;
        const sig = bindingInfoReferenceSig(self, target) orelse return null;
        return .{
            .sig = sig,
            .pass_idx = if (target.nopass) null else procedure_pass.procedurePassArgIndex(sig.args, target.pass_name),
            .source = target.source,
        };
    }
    return null;
}

fn genericBindingInfoTargetSpecific(
    self: *context.Context,
    derived: context.Context.DerivedTypeInfo,
    binding: context.Context.DerivedTypeInfo.BindingInfo,
) ?GenericBindingSpecific {
    const target_name = binding.implementation_name orelse return null;
    if (findResolvedBindingByName(derived.bindings, target_name)) |target| {
        if (target.is_generic) return null;
        const sig = bindingInfoReferenceSig(self, target) orelse return null;
        return .{
            .sig = sig,
            .pass_idx = if (target.nopass) null else procedure_pass.procedurePassArgIndex(sig.args, target.pass_name),
            .source = target.source,
        };
    }
    if (findAncestorBindingByName(self, derived.parent_name, target_name)) |target| {
        if (target.is_generic) return null;
        const sig = bindingInfoReferenceSig(self, target) orelse return null;
        return .{
            .sig = sig,
            .pass_idx = if (target.nopass) null else procedure_pass.procedurePassArgIndex(sig.args, target.pass_name),
            .source = target.source,
        };
    }
    return null;
}

fn lookupQualifiedProcedureSig(
    self: *context.Context,
    owner_name: ?[]const u8,
    proc_name: []const u8,
) ?context.Context.ProcedureSig {
    const owner = owner_name orelse return null;
    const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner, proc_name }) catch return null;
    return symbols_mod.lookupKnownProcedureSig(self, qualified);
}

fn firstCurrentGenericBindingIndex(
    bindings: []const ast.TypeBoundProcedureBinding,
    name: []const u8,
) ?usize {
    for (bindings, 0..) |binding, idx| {
        if (!binding.is_generic) continue;
        if (std.ascii.eqlIgnoreCase(binding.name, name)) return idx;
    }
    return null;
}

fn findEarlierParsedGenericBindingIndex(
    bindings: []const ast.TypeBoundProcedureBinding,
    name: []const u8,
    before_idx: usize,
) ?usize {
    var idx: usize = 0;
    while (idx < before_idx and idx < bindings.len) : (idx += 1) {
        if (!bindings[idx].is_generic) continue;
        if (std.ascii.eqlIgnoreCase(bindings[idx].name, name)) return idx;
    }
    return null;
}

fn findEarlierParsedNonGenericBindingByName(
    bindings: []const ast.TypeBoundProcedureBinding,
    name: []const u8,
    before_idx: usize,
) ?ast.TypeBoundProcedureBinding {
    var idx: usize = 0;
    while (idx < before_idx and idx < bindings.len) : (idx += 1) {
        if (bindings[idx].is_generic) continue;
        if (std.ascii.eqlIgnoreCase(bindings[idx].name, name)) return bindings[idx];
    }
    return null;
}

fn ancestorHasGenericBinding(
    self: *context.Context,
    parent_name: ?[]const u8,
    name: []const u8,
) bool {
    return firstAncestorGenericBindingByName(self, parent_name, name) != null;
}

fn ancestorHasNonGenericBinding(
    self: *context.Context,
    parent_name: ?[]const u8,
    name: []const u8,
) bool {
    var current_name = parent_name;
    while (current_name) |parent| {
        const derived = symbols_mod.lookupDerivedType(self, parent) orelse return false;
        for (derived.bindings) |binding| {
            if (binding.is_generic) continue;
            if (std.ascii.eqlIgnoreCase(binding.name, name)) return true;
        }
        current_name = derived.parent_name;
    }
    return false;
}

fn firstAncestorGenericBindingByName(
    self: *context.Context,
    parent_name: ?[]const u8,
    name: []const u8,
) ?context.Context.DerivedTypeInfo.BindingInfo {
    var current_name = parent_name;
    while (current_name) |parent| {
        const derived = symbols_mod.lookupDerivedType(self, parent) orelse return null;
        for (derived.bindings) |binding| {
            if (!binding.is_generic) continue;
            if (std.ascii.eqlIgnoreCase(binding.name, name)) return binding;
        }
        current_name = derived.parent_name;
    }
    return null;
}

fn collectAncestorGenericBindingTargets(
    self: *context.Context,
    parent_name: ?[]const u8,
    name: []const u8,
    seen: *std.StringHashMap(void),
) void {
    var current_name = parent_name;
    while (current_name) |parent| {
        const derived = symbols_mod.lookupDerivedType(self, parent) orelse return;
        for (derived.bindings) |binding| {
            if (!binding.is_generic) continue;
            if (!std.ascii.eqlIgnoreCase(binding.name, name)) continue;
            const target_name = binding.implementation_name orelse continue;
            seen.put(target_name, {}) catch return;
        }
        current_name = derived.parent_name;
    }
}

fn collectAncestorGenericBindingSpecifics(
    self: *context.Context,
    parent_name: ?[]const u8,
    name: []const u8,
    specifics: *std.array_list.Managed(GenericBindingSpecific),
) void {
    var current_name = parent_name;
    while (current_name) |parent| {
        const derived = symbols_mod.lookupDerivedType(self, parent) orelse return;
        for (derived.bindings) |binding| {
            if (!binding.is_generic) continue;
            if (!std.ascii.eqlIgnoreCase(binding.name, name)) continue;
            const target = genericBindingInfoTargetSpecific(self, derived, binding) orelse continue;
            specifics.append(target) catch return;
        }
        current_name = derived.parent_name;
    }
}

fn genericBindingSpecificAmbiguous(a: GenericBindingSpecific, b: GenericBindingSpecific) bool {
    if (a.sig.kind != b.sig.kind) return false;
    if (genericBindingRequiredArgCount(a) != genericBindingRequiredArgCount(b)) return false;

    var a_idx: usize = 0;
    var b_idx: usize = 0;
    while (true) {
        while (genericBindingShouldSkipArg(a, a_idx)) : (a_idx += 1) {}
        while (genericBindingShouldSkipArg(b, b_idx)) : (b_idx += 1) {}
        if (a_idx >= a.sig.args.len or b_idx >= b.sig.args.len) {
            return a_idx >= a.sig.args.len and b_idx >= b.sig.args.len;
        }
        if (!genericBindingArgEquivalent(a.sig.args[a_idx], b.sig.args[b_idx])) return false;
        a_idx += 1;
        b_idx += 1;
    }
}

fn genericBindingRequiredArgCount(specific: GenericBindingSpecific) usize {
    var count: usize = 0;
    for (specific.sig.args, 0..) |arg, idx| {
        if (specific.pass_idx != null and idx == specific.pass_idx.?) continue;
        if (!arg.optional) count += 1;
    }
    return count;
}

fn genericBindingShouldSkipArg(specific: GenericBindingSpecific, idx: usize) bool {
    if (idx >= specific.sig.args.len) return false;
    if (specific.pass_idx != null and idx == specific.pass_idx.?) return true;
    return specific.sig.args[idx].optional;
}

fn genericBindingArgEquivalent(a: context.Context.ProcedureSig.ArgSig, b: context.Context.ProcedureSig.ArgSig) bool {
    if (a.is_procedure or b.is_procedure) return a.is_procedure and b.is_procedure;
    if (a.rank != b.rank) return false;
    if (a.pointer != b.pointer) return false;
    if (a.allocatable != b.allocatable) return false;
    if (a.type_spec.lowered_kind != b.type_spec.lowered_kind) return false;
    if (a.type_spec.lowered_kind == .derived) {
        if (a.type_spec.derived_type_name == null or b.type_spec.derived_type_name == null) {
            return a.type_spec.derived_type_name == null and b.type_spec.derived_type_name == null;
        }
        return std.ascii.eqlIgnoreCase(a.type_spec.derived_type_name.?, b.type_spec.derived_type_name.?);
    }
    return true;
}

fn findResolvedBindingByName(
    bindings: []const context.Context.DerivedTypeInfo.BindingInfo,
    name: []const u8,
) ?context.Context.DerivedTypeInfo.BindingInfo {
    return binding_search.findBindingByName(bindings, name, .{});
}

fn findAncestorBindingByName(
    self: *context.Context,
    parent_name: ?[]const u8,
    name: []const u8,
) ?context.Context.DerivedTypeInfo.BindingInfo {
    return binding_search.findAncestorBindingByName(self, parent_name, name, .{});
}

pub fn findParsedBindingByName(
    bindings: []const ast.TypeBoundProcedureBinding,
    name: []const u8,
) ?ast.TypeBoundProcedureBinding {
    for (bindings) |binding| {
        if (std.ascii.eqlIgnoreCase(binding.name, name)) return binding;
    }
    return null;
}
