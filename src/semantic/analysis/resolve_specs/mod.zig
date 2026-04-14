const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common_diag = @import("../../../common/diagnostic.zig");
const catalog = @import("../../../common/error_catalog.zig");
const procedure_pass = @import("../../../common/procedure_pass.zig");
const context = @import("../context.zig");
const symbols = @import("../../symbol/mod.zig");
const symbols_mod = @import("../resolve_symbols.zig");
const constants = @import("../resolve_const.zig");
const expressions = @import("../resolve_expr.zig");
const decls = @import("../resolve_decls.zig");
const binding_diagnostics = @import("bindings/diagnostics.zig");
const binding_validation = @import("bindings/validation.zig");
const bind_entities = @import("bind_entities.zig");
const check_const = @import("../check_const.zig");
const helpers = @import("helpers.zig");
const interfaces = @import("interfaces.zig");
const equivalence = @import("equivalence.zig");
const procedure_interfaces = @import("../check_statements/procedure_interfaces.zig");

const resolvedDeclTypeSpec = helpers.resolvedDeclTypeSpec;
const ensureImplicitRuleNoOverlap = helpers.ensureImplicitRuleNoOverlap;
const setAttributeConflictDiagnostic = helpers.setAttributeConflictDiagnostic;
const setSourceDiagnostic = helpers.setSourceDiagnostic;
const setParameterNotConstantDiagnostic = helpers.setParameterNotConstantDiagnostic;
const setParameterTypeMismatchDiagnostic = helpers.setParameterTypeMismatchDiagnostic;
const hasCurrentUnitExplicitInterfaceProcedure = helpers.hasCurrentUnitExplicitInterfaceProcedure;
const hasCommonBlock = helpers.hasCommonBlock;
const applyImplicitRuleToExistingSymbols = helpers.applyImplicitRuleToExistingSymbols;
const setBindingDiagnostic = binding_diagnostics.setBindingDiagnostic;
const setBindingDiagnosticWithRelated = binding_diagnostics.setBindingDiagnosticWithRelated;
const setSourceDiagnosticWithRelated = binding_diagnostics.setSourceDiagnosticWithRelated;
const bindingInterfaceIsGeneric = binding_validation.bindingInterfaceIsGeneric;
const bindingInterfaceIsStatementFunction = binding_validation.bindingInterfaceIsStatementFunction;
const findParsedBindingByName = binding_validation.findParsedBindingByName;
const findUnitDerivedTypeDeclSource = binding_validation.findUnitDerivedTypeDeclSource;
const typeHasDeferredBindingRequirement = binding_validation.typeHasDeferredBindingRequirement;
const validateDerivedBinding = binding_validation.validateDerivedBinding;
const validateGenericBindingFamilies = binding_validation.validateGenericBindingFamilies;
const EquivalenceDesignator = equivalence.EquivalenceDesignator;
const EquivalenceDesignatorKey = equivalence.EquivalenceDesignatorKey;
const equivalenceTypeCompatible = equivalence.equivalenceTypeCompatible;
const unionEquivalence = equivalence.unionEquivalence;
const subNoOverflow = equivalence.subNoOverflow;

pub fn applySpec(self: *context.Context, decl: ast.Decl) !void {
    switch (decl) {
        .implicit => |imp| {
            for (imp.rules) |rule| {
                const resolved_rule_type = try resolvedDeclTypeSpec(
                    self,
                    rule.type_kind,
                    rule.derived_type_name,
                    rule.kind_selector,
                    rule.polymorphic,
                    false,
                );
                if (resolved_rule_type.lowered_kind == .derived and !resolved_rule_type.polymorphic) {
                    if (resolved_rule_type.derived_type_name) |derived_name| {
                        const derived_info = symbols_mod.lookupDerivedType(self, derived_name) orelse return error.UnexpectedTypeDecl;
                        if (derived_info.abstract) {
                            const message = std.fmt.allocPrint(self.arena, "ABSTRACT type '{s}' used", .{derived_name}) catch "ABSTRACT type used";
                            setAttributeConflictDiagnostic(self, message);
                            return error.UnexpectedTypeDecl;
                        }
                    }
                }
                const resolved_rule_kind = resolved_rule_type.lowered_kind;
                try ensureImplicitRuleNoOverlap(self, rule.start, rule.end);
                var char_len: ?usize = null;
                if (resolved_rule_kind == .character) {
                    char_len = 1;
                    if (rule.char_len) |len_expr| {
                        if (len_expr.* == .literal and len_expr.literal.kind == .assumed_size) {
                            // Assumed-length CHARACTER*(*) isn't a constant length; fall back to 1.
                            char_len = 1;
                        } else {
                            if (try constants.evalConst(self, len_expr)) |value| {
                                switch (value) {
                                    .integer => |int_val| {
                                        if (int_val <= 0) return error.InvalidCharLen;
                                        char_len = @intCast(int_val);
                                    },
                                    .real, .complex, .logical, .string => {
                                        if (emitImplicitCharLenTypingDiagnostics(self, len_expr)) return error.InvalidCharLen;
                                        return error.InvalidCharLen;
                                    },
                                }
                            } else {
                                if (emitImplicitCharLenTypingDiagnostics(self, len_expr)) return error.InvalidCharLen;
                                return error.InvalidCharLen;
                            }
                        }
                    }
                }
                const implicit_spec = resolved_rule_type.withCharacterLength(
                    if (resolved_rule_kind == .character) .constant else .none,
                    if (resolved_rule_kind == .character) char_len orelse 1 else null,
                );
                const implicit_rule = symbols.ImplicitRule.init(rule.start, rule.end, implicit_spec);
                try self.implicit.append(implicit_rule);
                applyImplicitRuleToExistingSymbols(self, implicit_rule);
            }
        },
        .procedure => return error.UnexpectedTypeDecl,
        .bind_entity => |bind_entity_decl| {
            try bind_entities.applyBindEntity(self, bind_entity_decl);
        },
        .derived_type_def => |derived| {
            if (isImportedPreludeDecl(self)) return;
            try validateDerivedTypeDef(self, derived);
        },
        .import => {},
        .intent => {},
        .optional => {},
        .interface_block => |interface_block| {
            try interfaces.validateExplicitInterfaceBlock(self, interface_block);
        },
        .dimension => |dim| {
            for (dim.items) |item| {
                if (!dim.pointer and hasCurrentUnitExplicitInterfaceProcedure(self, item.name)) {
                    setAttributeConflictDiagnostic(
                        self,
                        if (dim.allocatable)
                            "function result declared outside of INTERFACE body"
                        else
                            "function result declared outside its INTERFACE body",
                    );
                    return error.DuplicateDeclaration;
                }
                const idx = try symbols_mod.ensureDeclaredSymbol(self, item.name);
                if (item.dims.len > 0 and self.symbols.items[idx].dims.len > 0) {
                    emitDuplicateDimensionDiagnostic(self, item.name);
                    return error.DuplicateDeclaration;
                }
                self.symbols.items[idx].dims = item.dims;
                if (dim.allocatable) {
                    self.symbols.items[idx].is_allocatable = true;
                }
                if (dim.pointer) {
                    self.symbols.items[idx].is_pointer = true;
                }
            }
        },
        .parameter => |param| {
            for (param.assigns) |assign| {
                const idx = try symbols_mod.ensureDeclaredSymbol(self, assign.name);
                var sym = &self.symbols.items[idx];
                sym.kind = .parameter;
                sym.storage = .local;
                if (sym.dims.len != 0) {
                    if (sym.isCharacter() and sym.effectiveCharLenKind() != .constant) {
                        if (inferCharacterParameterLength(self, assign.value)) |char_len| {
                            sym.applyTypeSpec(sym.type_spec.withCharacterLength(.constant, char_len));
                        }
                    }
                    continue;
                }
                const assigned_value = check_const.checkParameterAssign(self, assign) catch |err| {
                    if (err == error.ParameterNotConstant) {
                        setParameterNotConstantDiagnostic(self, assign.name);
                    }
                    return err;
                };
                const const_val = check_const.coerceParameterValue(
                    self,
                    sym.type_spec,
                    assigned_value,
                ) catch |err| {
                    if (err == error.ParameterTypeMismatch) {
                        setParameterTypeMismatchDiagnostic(self, assign.name, sym.loweredKind(), assigned_value);
                    }
                    return err;
                };
                sym.const_value = const_val;

                if (sym.isCharacter() and sym.effectiveCharLenKind() != .constant) {
                    switch (const_val) {
                        .string => |bytes| {
                            sym.applyTypeSpec(sym.type_spec.withCharacterLength(.constant, constStringLogicalLen(bytes)));
                        },
                        else => {
                            sym.applyTypeSpec(sym.type_spec.withCharacterLength(sym.effectiveCharLenKind(), null));
                        },
                    }
                }
            }
        },
        .common => |common| {
            for (common.blocks) |block| {
                for (block.items) |item| {
                    try decls.applyDeclarator(self, symbols_mod.implicitTypeSpec(self, item.name), item, .common, false, false, false, false);
                }
            }
        },
        .equivalence => |eqv| {
            for (eqv.groups) |group| {
                var root: ?EquivalenceDesignator = null;
                var seen = std.AutoHashMap(EquivalenceDesignatorKey, void).init(self.arena);
                for (group.items) |expr_node| {
                    try expressions.resolveExpr(self, expr_node);

                    const designator = try equivalence.equivalenceDesignator(self, expr_node);
                    const sym = self.symbols.items[designator.symbol_idx];
                    if (sym.kind == .parameter or sym.kind == .function or sym.is_intrinsic) {
                        return error.InvalidEquivalence;
                    }
                    const designator_key = EquivalenceDesignatorKey{
                        .symbol_idx = designator.symbol_idx,
                        .byte_offset = designator.byte_offset,
                    };
                    if (seen.contains(designator_key)) return error.InvalidEquivalence;
                    try seen.put(designator_key, {});

                    if (root) |base| {
                        if (!equivalenceTypeCompatible(base.type_spec, designator.type_spec)) {
                            return error.InvalidEquivalence;
                        }
                        const relation = subNoOverflow(base.byte_offset, designator.byte_offset) orelse
                            return error.InvalidEquivalence;
                        const merged = try unionEquivalence(self, base.name, designator.name, relation);
                        if (!merged) return error.EquivalenceCycle;
                    } else {
                        root = designator;
                    }
                }
            }
        },
        .external => |ext| {
            for (ext.names) |name| {
                if (hasCurrentUnitExplicitInterfaceProcedure(self, name)) {
                    setAttributeConflictDiagnostic(self, "Duplicate EXTERNAL attribute");
                    return error.DuplicateDeclaration;
                }
                const idx = try symbols_mod.ensureDeclaredSymbol(self, name);
                if (self.symbols.items[idx].is_intrinsic) {
                    setAttributeConflictDiagnostic(self, "EXTERNAL attribute conflicts with INTRINSIC attribute");
                    return error.DuplicateDeclaration;
                }
                self.symbols.items[idx].is_external = true;
            }
        },
        .intrinsic => |intr| {
            for (intr.names) |name| {
                if (hasCurrentUnitExplicitInterfaceProcedure(self, name)) {
                    setAttributeConflictDiagnostic(self, "EXTERNAL attribute conflicts with INTRINSIC attribute");
                    return error.DuplicateDeclaration;
                }
                const idx = try symbols_mod.ensureDeclaredSymbol(self, name);
                if (self.symbols.items[idx].is_external) {
                    setAttributeConflictDiagnostic(self, "EXTERNAL attribute conflicts with INTRINSIC attribute");
                    return error.DuplicateDeclaration;
                }
                self.symbols.items[idx].is_intrinsic = true;
            }
        },
        .save => |save_decl| {
            if (!save_decl.save_all) {
                for (save_decl.items) |save_item| {
                    switch (save_item) {
                        .name => |name| {
                            _ = try symbols_mod.ensureDeclaredSymbol(self, name);
                        },
                        .common => |block_name| {
                            if (!(try hasCommonBlock(self, block_name))) return error.UnknownCommonBlock;
                        },
                    }
                }
            }
        },
        .type_decl => return error.UnexpectedTypeDecl,
    }
}

fn emitDuplicateDimensionDiagnostic(self: *context.Context, target_name: []const u8) void {
    const current_decl = self.current_decl_source orelse return;
    const prior_decl = decls.findPriorDeclaratorSource(self, target_name, .dimensions) orelse return;
    const secondary_spans = [_]common_diag.DiagnosticSpan{.{
        .file_path = "",
        .line = if (prior_decl.line == 0) 1 else prior_decl.line,
        .column = if (prior_decl.column == 0) 1 else prior_decl.column,
        .end_column = @max(
            (if (prior_decl.column == 0) 1 else prior_decl.column) + 1,
            prior_decl.text.len + 1,
        ),
        .line_text = prior_decl.text,
        .label = "first declaration here",
    }};
    self.setDiagnosticStructured(
        if (current_decl.line == 0) 1 else current_decl.line,
        if (current_decl.column == 0) 1 else current_decl.column,
        catalog.semantic.duplicate_declaration.code,
        catalog.semantic.duplicate_declaration.message,
        current_decl.text,
        "redeclared here",
        &.{.{ .text = "A symbol's shape must not be declared twice in the same scoping unit." }},
        &.{.{ .text = "Keep the DIMENSION information on only one declaration of this symbol." }},
        secondary_spans[0..],
    );
}

fn emitImplicitCharLenTypingDiagnostics(self: *context.Context, expr: *ast.Expr) bool {
    if (!exprHasIdentifier(expr)) return false;
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    const line = if (decl_source.line == 0) 1 else decl_source.line;
    const column = if (decl_source.column == 0) 1 else decl_source.column;
    if (currentFunctionResultNeedsType(self) and exprMentionsCurrentFunctionResult(self, expr)) {
        self.setDiagnostic(
            line,
            column,
            catalog.semantic.invalid_char_len.code,
            "has no IMPLICIT type",
            decl_source.text,
        );
    }
    self.setDiagnostic(
        line,
        column,
        catalog.semantic.invalid_char_len.code,
        "used before it is typed",
        decl_source.text,
    );
    return true;
}

fn currentFunctionResultNeedsType(self: *context.Context) bool {
    if (self.unit.kind != .function) return false;
    const result_name = self.unit.result_name orelse self.unit.name;
    const idx = symbols_mod.findSymbolIndex(self, result_name) orelse return true;
    return !self.symbols.items[idx].type_explicit;
}

fn exprMentionsCurrentFunctionResult(self: *context.Context, expr: *ast.Expr) bool {
    const result_name = self.unit.result_name orelse self.unit.name;
    return exprMentionsIdentifier(expr, result_name);
}

fn exprHasIdentifier(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => true,
        .unary => |un| exprHasIdentifier(un.expr),
        .binary => |bin| exprHasIdentifier(bin.left) or exprHasIdentifier(bin.right),
        .call_or_subscript => |call| blk: {
            for (call.args) |arg| {
                if (exprHasIdentifier(arg)) break :blk true;
            }
            break :blk false;
        },
        .component => |comp| exprHasIdentifier(comp.base),
        .substring => |sub| blk: {
            if (exprHasIdentifierInSlice(sub.args)) break :blk true;
            if (sub.start != null and exprHasIdentifier(sub.start.?)) break :blk true;
            if (sub.end != null and exprHasIdentifier(sub.end.?)) break :blk true;
            break :blk false;
        },
        .dim_range => |range| blk: {
            if (range.lower != null and exprHasIdentifier(range.lower.?)) break :blk true;
            if (exprHasIdentifier(range.upper)) break :blk true;
            if (range.stride != null and exprHasIdentifier(range.stride.?)) break :blk true;
            break :blk false;
        },
        .array_constructor => |ctor| exprHasIdentifierInSlice(ctor.items),
        .complex_literal => |lit| exprHasIdentifier(lit.real) or exprHasIdentifier(lit.imag),
        .implied_do => |ido| exprHasIdentifierInSlice(ido.items) or exprHasIdentifier(ido.start) or exprHasIdentifier(ido.end) or (ido.step != null and exprHasIdentifier(ido.step.?)),
        else => false,
    };
}

fn exprHasIdentifierInSlice(items: []const *ast.Expr) bool {
    for (items) |item| {
        if (exprHasIdentifier(item)) return true;
    }
    return false;
}

fn exprMentionsIdentifier(expr: *ast.Expr, name: []const u8) bool {
    return switch (expr.*) {
        .identifier => |ident| std.ascii.eqlIgnoreCase(ident, name),
        .unary => |un| exprMentionsIdentifier(un.expr, name),
        .binary => |bin| exprMentionsIdentifier(bin.left, name) or exprMentionsIdentifier(bin.right, name),
        .call_or_subscript => |call| blk: {
            if (std.ascii.eqlIgnoreCase(call.name, name)) break :blk true;
            for (call.args) |arg| {
                if (exprMentionsIdentifier(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .component => |comp| exprMentionsIdentifier(comp.base, name),
        .substring => |sub| blk: {
            if (std.ascii.eqlIgnoreCase(sub.name, name)) break :blk true;
            if (exprMentionsIdentifierInSlice(sub.args, name)) break :blk true;
            if (sub.start != null and exprMentionsIdentifier(sub.start.?, name)) break :blk true;
            if (sub.end != null and exprMentionsIdentifier(sub.end.?, name)) break :blk true;
            break :blk false;
        },
        .dim_range => |range| blk: {
            if (range.lower != null and exprMentionsIdentifier(range.lower.?, name)) break :blk true;
            if (exprMentionsIdentifier(range.upper, name)) break :blk true;
            if (range.stride != null and exprMentionsIdentifier(range.stride.?, name)) break :blk true;
            break :blk false;
        },
        .array_constructor => |ctor| exprMentionsIdentifierInSlice(ctor.items, name),
        .complex_literal => |lit| exprMentionsIdentifier(lit.real, name) or exprMentionsIdentifier(lit.imag, name),
        .implied_do => |ido| exprMentionsIdentifierInSlice(ido.items, name) or exprMentionsIdentifier(ido.start, name) or exprMentionsIdentifier(ido.end, name) or (ido.step != null and exprMentionsIdentifier(ido.step.?, name)),
        else => false,
    };
}

fn exprMentionsIdentifierInSlice(items: []const *ast.Expr, name: []const u8) bool {
    for (items) |item| {
        if (exprMentionsIdentifier(item, name)) return true;
    }
    return false;
}

fn isImportedPreludeDecl(self: *context.Context) bool {
    const decl_idx = self.current_decl_index orelse return false;
    if (decl_idx >= self.unit.prelude_decl_count) return false;
    const decl_source = self.current_decl_source orelse return false;
    return decl_source.owner_name != null;
}

fn validateDerivedTypeDef(self: *context.Context, derived: ast.DerivedTypeDef) !void {
    var first_error: ?anyerror = null;

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

pub fn applyTypeDeclParameter(self: *context.Context, decl: ast.TypeDecl) !void {
    if (!decl.parameter) return;

    for (decl.items) |item| {
        const init_expr = item.init orelse {
            setParameterNotConstantDiagnostic(self, item.name);
            return error.ParameterNotConstant;
        };
        const idx = try symbols_mod.ensureDeclaredSymbol(self, item.name);
        var sym = &self.symbols.items[idx];
        sym.kind = .parameter;
        sym.storage = .local;

        if (sym.dims.len != 0) {
            if (sym.isCharacter() and sym.effectiveCharLenKind() != .constant) {
                if (inferCharacterParameterLength(self, init_expr)) |char_len| {
                    sym.applyTypeSpec(sym.type_spec.withCharacterLength(.constant, char_len));
                }
            }
            continue;
        }

        const assign = ast.ParamAssign{
            .name = item.name,
            .value = init_expr,
        };
        const assigned_value = check_const.checkParameterAssign(self, assign) catch |err| {
            if (err == error.ParameterNotConstant) {
                setParameterNotConstantDiagnostic(self, item.name);
            }
            return err;
        };
        const const_val = check_const.coerceParameterValue(
            self,
            sym.type_spec,
            assigned_value,
        ) catch |err| {
            if (err == error.ParameterTypeMismatch) {
                setParameterTypeMismatchDiagnostic(self, item.name, sym.loweredKind(), assigned_value);
            }
            return err;
        };
        sym.const_value = const_val;

        if (sym.isCharacter() and sym.effectiveCharLenKind() != .constant) {
            switch (const_val) {
                .string => |bytes| {
                    sym.applyTypeSpec(sym.type_spec.withCharacterLength(.constant, constStringLogicalLen(bytes)));
                },
                else => {
                    sym.applyTypeSpec(sym.type_spec.withCharacterLength(sym.effectiveCharLenKind(), null));
                },
            }
        }
    }
}

fn inferCharacterParameterLength(self: *context.Context, expr: *ast.Expr) ?usize {
    if (constants.evalConst(self, expr) catch null) |value| {
        return switch (value) {
            .string => |bytes| constStringLogicalLen(bytes),
            else => null,
        };
    }
    return switch (expr.*) {
        .array_constructor => |ctor| blk: {
            var max_len: usize = 0;
            for (ctor.items) |item| {
                const item_len = inferCharacterParameterLength(self, item) orelse continue;
                max_len = @max(max_len, item_len);
            }
            break :blk if (max_len == 0) null else max_len;
        },
        else => null,
    };
}

fn constStringLogicalLen(bytes: []const u8) usize {
    return std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
}
