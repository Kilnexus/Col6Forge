const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const procedure_pass = @import("../../../common/procedure_pass.zig");
const context = @import("../context.zig");
const symbols = @import("../../symbol/mod.zig");
const symbols_mod = @import("../resolve_symbols.zig");
const constants = @import("../resolve_const.zig");
const bind_c_shared = @import("bind_c_shared.zig");
const decl_initializers = @import("../resolve_decls_initializers.zig");
const helpers = @import("helpers.zig");
const binding_diagnostics = @import("bindings/diagnostics.zig");
const binding_validation = @import("bindings/validation.zig");

const resolvedDeclTypeSpec = helpers.resolvedDeclTypeSpec;
const setAttributeConflictDiagnostic = helpers.setAttributeConflictDiagnostic;
const setSourceDiagnostic = helpers.setSourceDiagnostic;
const setBindingDiagnosticWithRelated = binding_diagnostics.setBindingDiagnosticWithRelated;
const setSourceDiagnosticWithRelated = binding_diagnostics.setSourceDiagnosticWithRelated;
const bindingInterfaceIsGeneric = binding_validation.bindingInterfaceIsGeneric;
const bindingInterfaceIsStatementFunction = binding_validation.bindingInterfaceIsStatementFunction;
const findParsedBindingByName = binding_validation.findParsedBindingByName;
const findUnitDerivedTypeDeclSource = binding_validation.findUnitDerivedTypeDeclSource;
const typeHasDeferredBindingRequirement = binding_validation.typeHasDeferredBindingRequirement;
const validateDerivedBinding = binding_validation.validateDerivedBinding;
const validateGenericBindingFamilies = binding_validation.validateGenericBindingFamilies;

pub fn lowerCommonName(self: *context.Context, name: []const u8, buf: *[64]u8) ![]const u8 {
    if (name.len <= buf.len) {
        for (name, 0..) |ch, idx| buf.*[idx] = std.ascii.toLower(ch);
        return buf[0..name.len];
    }
    const owned = try self.arena.alloc(u8, name.len);
    for (name, 0..) |ch, idx| owned[idx] = std.ascii.toLower(ch);
    return owned;
}
pub fn validateDerivedTypeDef(self: *context.Context, derived: ast.DerivedTypeDef) !void {
    var first_error: ?anyerror = null;

    if (derivedTypeNameIsIntrinsicType(derived.name)) {
        setAttributeConflictDiagnostic(self, "cannot be the same as an intrinsic type");
        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
        first_error = error.DuplicateDeclaration;
    }

    if (derived.abstract and (derived.bind_c or derived.sequence)) {
        setAttributeConflictDiagnostic(self, "must not be ABSTRACT");
        first_error = error.DuplicateDeclaration;
    }
    if (derived.sequence and derived.bindings.len != 0) {
        setAttributeConflictDiagnostic(self, "SEQUENCE");
        if (first_error == null) first_error = error.DuplicateDeclaration;
    }
    if (derived.bind_c and derived.bindings.len != 0) {
        setAttributeConflictDiagnostic(self, "BIND");
        if (first_error == null) first_error = error.DuplicateDeclaration;
    }

    if (validateBindCCharacterComponents(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }
    if (validateSequenceOrBindCPolymorphicComponents(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }
    if (validateBindCInteroperableComponents(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    if (validateDerivedDescriptorComponentShapes(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    if (validateDerivedPointerComponentInitializers(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    if (validateDerivedOldStyleComponentInitializers(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    if (validateDerivedDuplicateComponents(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    for (derived.components, 0..) |type_decl, component_idx| {
        if (type_decl.type_kind != .derived) continue;
        const derived_name = type_decl.derived_type_name orelse continue;
        if (symbols_mod.hasDerivedType(self, derived_name)) continue;
        const component_source = if (component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};
        if (findUnitDerivedTypeDeclSource(self, derived_name)) |decl_source| {
            setSourceDiagnosticWithRelated(
                self,
                component_source,
                "has not been declared",
                &.{decl_source},
                "derived type declared later here",
            );
        } else {
            setSourceDiagnostic(self, component_source, "has not been declared");
        }
        if (first_error == null) first_error = error.UnexpectedTypeDecl;
    }

    if (validateDerivedMemberNameCollisions(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    if (validateDerivedProcedureComponents(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    for (derived.bindings, 0..) |binding, binding_idx| {
        if (validateDerivedBinding(self, derived, binding, binding_idx)) |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_error == null) first_error = err;
        }
    }

    if (validateGenericBindingFamilies(self, derived)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    if (!derived.abstract and typeHasDeferredBindingRequirement(self, derived)) {
        setAttributeConflictDiagnostic(self, "must be ABSTRACT");
        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
        if (first_error == null) first_error = error.DuplicateDeclaration;
    }

    if (first_error) |err| return err;
}

fn validateDerivedDescriptorComponentShapes(self: *context.Context, derived: ast.DerivedTypeDef) ?anyerror {
    var first_error: ?anyerror = null;
    for (derived.components, 0..) |type_decl, component_idx| {
        if (!type_decl.allocatable and !type_decl.pointer) continue;
        const source = if (component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};
        for (type_decl.items) |item| {
            if (type_decl.allocatable and item.init != null) {
                setSourceDiagnostic(self, source, "Initialization of allocatable component is not allowed");
                if (first_error == null) first_error = error.DuplicateDeclaration;
            }
            if (item.dims.len != 0 and !componentDimsAreDeferredShape(item.dims)) {
                const attr = if (type_decl.allocatable) "ALLOCATABLE" else "POINTER";
                const message = std.fmt.allocPrint(self.arena, "{s} array must have a deferred shape", .{attr}) catch "array must have a deferred shape";
                setSourceDiagnostic(self, source, message);
                if (first_error == null) first_error = error.DuplicateDeclaration;
            }
            if (type_decl.type_kind == .character and item.char_len != null and item.char_len.?.* == .literal and item.char_len.?.literal.kind == .assumed_size) {
                setSourceDiagnostic(self, source, "needs to be a constant specification");
                if (first_error == null) first_error = error.InvalidCharLen;
            }
        }
    }
    return first_error;
}

fn validateDerivedPointerComponentInitializers(self: *context.Context, derived: ast.DerivedTypeDef) ?anyerror {
    var first_error: ?anyerror = null;
    const original_source = self.current_decl_source;
    defer self.setCurrentDeclSource(original_source);

    for (derived.components, 0..) |type_decl, component_idx| {
        if (!type_decl.pointer) continue;
        const source = if (component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};
        self.setCurrentDeclSource(source);
        const spec = resolvedDeclTypeSpec(
            self,
            type_decl.type_kind,
            type_decl.derived_type_name,
            type_decl.kind_selector,
            type_decl.polymorphic,
            type_decl.assumed_type,
        ) catch |err| {
            if (first_error == null) first_error = err;
            continue;
        };
        for (type_decl.items) |item| {
            decl_initializers.validateDataPointerInitializer(self, type_decl, spec, item) catch |err| {
                if (!self.usesExplicitDiagnosticBag()) return err;
                if (first_error == null) first_error = err;
                continue;
            };
        }
    }
    return first_error;
}

fn validateDerivedOldStyleComponentInitializers(self: *context.Context, derived: ast.DerivedTypeDef) ?anyerror {
    var first_error: ?anyerror = null;
    const original_source = self.current_decl_source;
    defer self.setCurrentDeclSource(original_source);

    for (derived.component_sources) |source| {
        if (decl_initializers.validateDerivedOldStyleComponentInitializer(self, source)) |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_error == null) first_error = err;
        }
    }
    return first_error;
}

fn derivedTypeNameIsIntrinsicType(name: []const u8) bool {
    const intrinsic_types = [_][]const u8{
        "integer",
        "real",
        "complex",
        "character",
        "logical",
        "doubleprecision",
        "doublecomplex",
        "double",
    };
    for (intrinsic_types) |intrinsic_type| {
        if (std.ascii.eqlIgnoreCase(name, intrinsic_type)) return true;
    }
    return false;
}

pub fn equivalenceNameHasBindC(unit: ast.ProgramUnit, name: []const u8) bool {
    for (unit.decls) |decl| {
        switch (decl) {
            .bind_entity => |bind_entity| {
                for (bind_entity.names) |bind_name| {
                    if (std.ascii.eqlIgnoreCase(bind_name, name)) return true;
                }
            },
            .type_decl => |type_decl| {
                if (!type_decl.bind_c) continue;
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

pub fn equivalenceNameIsUseAssociated(unit: ast.ProgramUnit, name: []const u8) bool {
    for (unit.use_imports) |use_stmt| {
        if (!use_stmt.has_only) continue;
        for (use_stmt.only_items) |item| {
            if (std.ascii.eqlIgnoreCase(item.local_name, name)) return true;
        }
    }
    for (unit.stmts) |stmt| {
        if (stmt.node != .use_stmt) continue;
        const use_stmt = stmt.node.use_stmt;
        if (!use_stmt.has_only) continue;
        for (use_stmt.only_items) |item| {
            if (std.ascii.eqlIgnoreCase(item.local_name, name)) return true;
        }
    }
    return false;
}

pub fn emitPureEquivalenceAssignmentDiagnostics(self: *context.Context, group: ast.EquivalenceGroup) void {
    for (self.unit.stmts) |stmt| {
        if (stmt.node != .assignment) continue;
        const target_name = exprRootName(stmt.node.assignment.target) orelse continue;
        if (!equivalenceGroupMentionsName(group, target_name)) continue;
        self.setDiagnostic(
            if (stmt.source_line == 0) 1 else stmt.source_line,
            if (stmt.source_column == 0) 1 else stmt.source_column,
            catalog.semantic.assignment_type_mismatch.code,
            "cannot be used in a variable definition context",
            stmt.source_text,
        );
    }
}

fn equivalenceGroupMentionsName(group: ast.EquivalenceGroup, name: []const u8) bool {
    for (group.items) |item| {
        const item_name = exprRootName(item) orelse continue;
        if (std.ascii.eqlIgnoreCase(item_name, name)) return true;
    }
    return false;
}

fn exprRootName(expr: *ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .identifier => |name| name,
        .call_or_subscript => |call| call.name,
        .substring => |sub| sub.name,
        .component => |comp| exprRootName(comp.base),
        else => null,
    };
}

pub fn equivalenceInitializersConflict(self: *context.Context, a_idx: usize, b_idx: usize) bool {
    const a_value = equivalenceInitializerValue(self, self.symbols.items[a_idx]) orelse return false;
    const b_value = equivalenceInitializerValue(self, self.symbols.items[b_idx]) orelse return false;
    return !constValuesEqual(a_value, b_value);
}

fn equivalenceInitializerValue(self: *context.Context, sym: symbols.Symbol) ?symbols.ConstValue {
    if (sym.const_value) |value| return value;
    if (declarationInitializerValue(self, sym.name)) |value| return value;
    if (sym.type_spec.lowered_kind != .derived) return null;
    const derived_name = sym.type_spec.derived_type_name orelse return null;
    for (self.unit.decls) |decl| {
        if (decl != .derived_type_def) continue;
        if (!std.ascii.eqlIgnoreCase(decl.derived_type_def.name, derived_name)) continue;
        for (decl.derived_type_def.components) |component_decl| {
            for (component_decl.items) |item| {
                const init = item.init orelse continue;
                return constants.evalConst(self, init) catch null;
            }
        }
    }
    return null;
}

fn declarationInitializerValue(self: *context.Context, name: []const u8) ?symbols.ConstValue {
    for (self.unit.decls) |decl| {
        if (decl != .type_decl) continue;
        for (decl.type_decl.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            const init = item.init orelse return null;
            return constants.evalConst(self, init) catch null;
        }
    }
    return null;
}

fn constValuesEqual(a: symbols.ConstValue, b: symbols.ConstValue) bool {
    return switch (a) {
        .integer => |v| switch (b) {
            .integer => |other| other == v,
            else => false,
        },
        .real => |v| switch (b) {
            .real => |other| other.value == v.value and other.is_double == v.is_double,
            else => false,
        },
        .complex => |v| switch (b) {
            .complex => |other| other.real == v.real and other.imag == v.imag and other.is_double == v.is_double,
            else => false,
        },
        .logical => |v| switch (b) {
            .logical => |other| other == v,
            else => false,
        },
        .string => |v| switch (b) {
            .string => |other| std.mem.eql(u8, other, v),
            else => false,
        },
    };
}

fn validateDerivedDuplicateComponents(self: *context.Context, derived: ast.DerivedTypeDef) ?anyerror {
    var seen = std.StringHashMap(ast.DeclSource).init(self.arena);
    for (derived.components, 0..) |type_decl, component_idx| {
        const source = if (component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};
        for (type_decl.items) |item| {
            var key_buf: [64]u8 = undefined;
            const key = lowerCommonName(self, item.name, &key_buf) catch item.name;
            if (seen.contains(key)) {
                setSourceDiagnostic(self, source, "already declared at");
                return error.DuplicateDeclaration;
            }
            seen.put(if (key.len <= key_buf.len) self.arena.dupe(u8, key) catch key else key, source) catch {};
        }
    }
    return null;
}

fn componentDimsAreDeferredShape(dims: []const *ast.Expr) bool {
    if (dims.len == 0) return false;
    for (dims) |dim| {
        if (dim.* != .dim_range) return false;
        const range = dim.dim_range;
        if (!range.assumed_shape or range.lower != null) return false;
    }
    return true;
}

fn validateBindCCharacterComponents(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
) ?anyerror {
    if (!derived.bind_c) return null;

    for (derived.components, 0..) |type_decl, component_idx| {
        if (type_decl.type_kind != .character) continue;
        const source = if (component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};

        for (type_decl.items) |item| {
            if (bind_c_shared.characterDeclaratorHasLengthOne(item)) continue;
            setSourceDiagnostic(self, source, "BIND(C) CHARACTER component must have length one");
            return error.InvalidCharLen;
        }
    }

    return null;
}

fn validateBindCInteroperableComponents(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
) ?anyerror {
    if (!derived.bind_c) return null;

    var first_error: ?anyerror = null;
    var header_reported = false;

    for (derived.components, 0..) |type_decl, component_idx| {
        const source = if (component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};

        if (type_decl.pointer) {
            if (!header_reported) {
                emitBindCDerivedTypeHeaderDiagnostic(self);
                header_reported = true;
            }
            setSourceDiagnostic(self, source, "cannot have the POINTER attribute");
            if (!self.usesExplicitDiagnosticBag()) return error.UnexpectedTypeDecl;
            if (first_error == null) first_error = error.UnexpectedTypeDecl;
        }

        if (type_decl.allocatable) {
            if (!header_reported) {
                emitBindCDerivedTypeHeaderDiagnostic(self);
                header_reported = true;
            }
            setSourceDiagnostic(self, source, "cannot have the ALLOCATABLE attribute");
            if (!self.usesExplicitDiagnosticBag()) return error.UnexpectedTypeDecl;
            if (first_error == null) first_error = error.UnexpectedTypeDecl;
        }

        if (type_decl.type_kind != .derived) continue;
        const derived_name = type_decl.derived_type_name orelse continue;
        const nested = symbols_mod.lookupDerivedType(self, derived_name) orelse continue;
        if (nested.bind_c) continue;

        if (!header_reported) {
            emitBindCDerivedTypeHeaderDiagnostic(self);
            header_reported = true;
        }
        setSourceDiagnostic(self, nested.source, "must have the BIND attribute");
        if (!self.usesExplicitDiagnosticBag()) return error.UnexpectedTypeDecl;
        if (first_error == null) first_error = error.UnexpectedTypeDecl;
    }

    for (derived.procedure_components, 0..) |procedure_decl, component_idx| {
        const source = if (component_idx < derived.procedure_component_sources.len)
            derived.procedure_component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};

        if (!header_reported) {
            emitBindCDerivedTypeHeaderDiagnostic(self);
            header_reported = true;
        }
        _ = procedure_decl;
        setSourceDiagnostic(self, source, "procedure pointer component cannot be a member of a BIND(C) derived type");
        if (!self.usesExplicitDiagnosticBag()) return error.UnexpectedTypeDecl;
        if (first_error == null) first_error = error.UnexpectedTypeDecl;
    }

    return first_error;
}

fn validateSequenceOrBindCPolymorphicComponents(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
) ?anyerror {
    if (!derived.sequence and !derived.bind_c) return null;

    var first_error: ?anyerror = null;
    for (derived.components, 0..) |type_decl, component_idx| {
        if (!type_decl.polymorphic) continue;
        const source = if (component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};

        for (type_decl.items) |item| {
            const message = std.fmt.allocPrint(
                self.arena,
                "Polymorphic component {s} at .1. in SEQUENCE or BIND(C) type",
                .{item.name},
            ) catch "Polymorphic component at .1. in SEQUENCE or BIND(C) type";
            setSourceDiagnostic(self, source, message);
            if (!self.usesExplicitDiagnosticBag()) return error.UnexpectedTypeDecl;
            if (first_error == null) first_error = error.UnexpectedTypeDecl;
        }
    }

    return first_error;
}

fn emitBindCDerivedTypeHeaderDiagnostic(self: *context.Context) void {
    const source = self.current_decl_source orelse ast.DeclSource{};
    setSourceDiagnostic(self, source, "BIND(C) derived type has non-interoperable component");
}

fn validateDerivedProcedureComponents(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
) ?anyerror {
    var first_error: ?anyerror = null;

    for (derived.procedure_components, 0..) |procedure_decl, component_idx| {
        const component_source = if (component_idx < derived.procedure_component_sources.len)
            derived.procedure_component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};
        if (validateDerivedProcedureComponent(self, derived, procedure_decl, component_source)) |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_error == null) first_error = err;
        }
    }

    return first_error;
}

fn validateDerivedProcedureComponent(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    procedure_decl: ast.ProcedureDecl,
    source: ast.DeclSource,
) ?anyerror {
    var first_error: ?anyerror = null;

    if (!procedure_decl.pointer) {
        setSourceDiagnostic(self, source, "POINTER attribute is required for procedure pointer component");
        if (!self.usesExplicitDiagnosticBag()) return error.UnexpectedTypeDecl;
        first_error = error.UnexpectedTypeDecl;
    }

    for (procedure_decl.items) |item| {
        if (item.dims.len == 0) continue;
        setSourceDiagnostic(self, source, "must be scalar");
        if (!self.usesExplicitDiagnosticBag()) return error.UnexpectedTypeDecl;
        if (first_error == null) first_error = error.UnexpectedTypeDecl;
        break;
    }

    if (validateDerivedProcedureComponentInterface(self, procedure_decl, source)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }

    if (!procedure_decl.nopass) {
        if (validateDerivedProcedureComponentPassConstraints(self, derived, procedure_decl, source)) |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_error == null) first_error = err;
        }
    }

    return first_error;
}

fn validateDerivedProcedureComponentInterface(
    self: *context.Context,
    procedure_decl: ast.ProcedureDecl,
    source: ast.DeclSource,
) ?anyerror {
    if (procedure_decl.interface == .none and procedureComponentUsesBareProcedureKeyword(source.text)) {
        setSourceDiagnostic(self, source, "Syntax error");
        return error.UnexpectedTypeDecl;
    }

    const iface_name = switch (procedure_decl.interface) {
        .name => |name| name,
        else => return null,
    };

    if (bindingInterfaceIsGeneric(self, iface_name)) {
        setSourceDiagnostic(self, source, "may not be generic");
        return error.UnexpectedTypeDecl;
    }
    if (bindingInterfaceIsStatementFunction(self, iface_name)) {
        setSourceDiagnostic(self, source, "may not be a statement function");
        return error.UnexpectedTypeDecl;
    }
    if (symbols_mod.isIntrinsicName(iface_name)) {
        setSourceDiagnostic(self, source, "Intrinsic procedure");
        return error.UnexpectedTypeDecl;
    }
    if (symbols_mod.lookupKnownProcedureSig(self, iface_name) == null) {
        setSourceDiagnostic(self, source, "must be explicit");
        return error.UnexpectedTypeDecl;
    }
    return null;
}

fn procedureComponentUsesBareProcedureKeyword(line_text: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line_text, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "procedure")) return false;
    if (trimmed.len <= "procedure".len) return true;

    var idx: usize = "procedure".len;
    while (idx < trimmed.len and (trimmed[idx] == ' ' or trimmed[idx] == '\t')) : (idx += 1) {}
    return idx >= trimmed.len or trimmed[idx] != '(';
}

fn validateDerivedProcedureComponentPassConstraints(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
    procedure_decl: ast.ProcedureDecl,
    source: ast.DeclSource,
) ?anyerror {
    const sig = switch (procedure_decl.interface) {
        .name => |iface_name| symbols_mod.lookupKnownProcedureSig(self, iface_name),
        else => null,
    } orelse {
        setSourceDiagnostic(self, source, "NOPASS or explicit interface required");
        return error.UnexpectedTypeDecl;
    };

    if (sig.args.len == 0) {
        setSourceDiagnostic(self, source, "must have at least one argument");
        return error.UnexpectedTypeDecl;
    }

    const pass_idx: ?usize = if (procedure_decl.pass_name) |pass_name|
        procedure_pass.procedurePassArgIndex(sig.args, pass_name)
    else
        0;

    if (pass_idx == null) {
        const message = if (procedure_decl.pass_name) |pass_name|
            std.fmt.allocPrint(self.arena, "has no argument '{s}'", .{pass_name}) catch "has no argument"
        else
            "must have at least one argument";
        setSourceDiagnostic(self, source, message);
        return error.UnexpectedTypeDecl;
    }

    const pass_arg = sig.args[pass_idx.?];
    if (pass_arg.rank != 0) {
        setSourceDiagnostic(self, source, "must be scalar");
        return error.UnexpectedTypeDecl;
    }
    if (pass_arg.pointer) {
        setSourceDiagnostic(self, source, "may not have the POINTER attribute");
        return error.UnexpectedTypeDecl;
    }
    if (pass_arg.allocatable) {
        setSourceDiagnostic(self, source, "may not be ALLOCATABLE");
        return error.UnexpectedTypeDecl;
    }
    if (pass_arg.type_spec.lowered_kind != .derived or
        pass_arg.type_spec.derived_type_name == null or
        !std.ascii.eqlIgnoreCase(pass_arg.type_spec.derived_type_name.?, derived.name))
    {
        setSourceDiagnostic(self, source, "must be of the derived type");
        return error.UnexpectedTypeDecl;
    }
    if (!pass_arg.type_spec.polymorphic) {
        setSourceDiagnostic(self, source, "Non-polymorphic passed-object dummy argument");
        return error.UnexpectedTypeDecl;
    }

    return null;
}

fn validateDerivedMemberNameCollisions(
    self: *context.Context,
    derived: ast.DerivedTypeDef,
) ?anyerror {
    for (derived.components, 0..) |type_decl, component_idx| {
        const component_source = if (component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            self.current_decl_source orelse ast.DeclSource{};
        for (type_decl.items) |item| {
            if (findParsedBindingByName(derived.bindings, item.name)) |binding| {
                setSourceDiagnosticWithRelated(
                    self,
                    component_source,
                    "same name as a component",
                    &.{binding.source},
                    "conflicting binding here",
                );
                return error.DuplicateDeclaration;
            }
            if (findAncestorMemberSource(self, derived.parent_name, item.name)) |prior_source| {
                setSourceDiagnosticWithRelated(
                    self,
                    component_source,
                    "same name",
                    &.{prior_source},
                    "inherited member here",
                );
                return error.DuplicateDeclaration;
            }
        }
    }

    for (derived.bindings) |binding| {
        if (findAncestorComponentSource(self, derived.parent_name, binding.name)) |prior_source| {
            setBindingDiagnosticWithRelated(self, binding, "same name as an inherited component", &.{prior_source}, "inherited component here");
            return error.DuplicateDeclaration;
        }
    }
    return null;
}

fn derivedAncestorHasMemberName(
    self: *context.Context,
    parent_name: ?[]const u8,
    target_name: []const u8,
) bool {
    var current_name = parent_name;
    while (current_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse return false;
        for (parent.components) |component| {
            if (std.ascii.eqlIgnoreCase(component.name, target_name)) return true;
        }
        for (parent.bindings) |binding| {
            if (std.ascii.eqlIgnoreCase(binding.name, target_name)) return true;
        }
        current_name = parent.parent_name;
    }
    return false;
}

fn findAncestorMemberSource(
    self: *context.Context,
    parent_name: ?[]const u8,
    target_name: []const u8,
) ?ast.DeclSource {
    var current_name = parent_name;
    while (current_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse return null;
        for (parent.components) |component| {
            if (std.ascii.eqlIgnoreCase(component.name, target_name)) return component.source;
        }
        for (parent.bindings) |binding| {
            if (std.ascii.eqlIgnoreCase(binding.name, target_name)) return binding.source;
        }
        current_name = parent.parent_name;
    }
    return null;
}

fn derivedAncestorHasComponentName(
    self: *context.Context,
    parent_name: ?[]const u8,
    target_name: []const u8,
) bool {
    var current_name = parent_name;
    while (current_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse return false;
        for (parent.components) |component| {
            if (std.ascii.eqlIgnoreCase(component.name, target_name)) return true;
        }
        current_name = parent.parent_name;
    }
    return false;
}

fn findAncestorComponentSource(
    self: *context.Context,
    parent_name: ?[]const u8,
    target_name: []const u8,
) ?ast.DeclSource {
    var current_name = parent_name;
    while (current_name) |name| {
        const parent = symbols_mod.lookupDerivedType(self, name) orelse return null;
        for (parent.components) |component| {
            if (std.ascii.eqlIgnoreCase(component.name, target_name)) return component.source;
        }
        current_name = parent.parent_name;
    }
    return null;
}
