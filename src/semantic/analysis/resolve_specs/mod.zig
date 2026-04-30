const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const decl_queries = @import("../../../ast/decl_queries.zig");
const common_diag = @import("../../../common/diagnostic.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const symbols = @import("../../symbol/mod.zig");
const literal_utils = @import("../../evaluator/literals.zig");
const symbols_mod = @import("../resolve_symbols.zig");
const constants = @import("../resolve_const.zig");
const expressions = @import("../resolve_expr.zig");
const decls = @import("../resolve_decls.zig");
const bind_entities = @import("bind_entities.zig");
const check_const = @import("../check_const.zig");
const helpers = @import("helpers.zig");
const interfaces = @import("interfaces.zig");
const equivalence = @import("equivalence.zig");
const procedure_interfaces = @import("../check_statements/procedure_interfaces.zig");
const assumed_size = @import("../assumed_size.zig");
const decl_scan = @import("../decl_scan.zig");
const validation_helpers = @import("validation_helpers.zig");

const resolvedDeclTypeSpec = helpers.resolvedDeclTypeSpec;
const ensureImplicitRuleNoOverlap = helpers.ensureImplicitRuleNoOverlap;
const setAttributeConflictDiagnostic = helpers.setAttributeConflictDiagnostic;
const setSourceDiagnostic = helpers.setSourceDiagnostic;
const setParameterNotConstantDiagnostic = helpers.setParameterNotConstantDiagnostic;
const setParameterTypeMismatchDiagnostic = helpers.setParameterTypeMismatchDiagnostic;
const hasCurrentUnitExplicitInterfaceProcedure = helpers.hasCurrentUnitExplicitInterfaceProcedure;
const hasCommonBlock = helpers.hasCommonBlock;
const applyImplicitRuleToExistingSymbols = helpers.applyImplicitRuleToExistingSymbols;
const EquivalenceDesignator = equivalence.EquivalenceDesignator;
const EquivalenceDesignatorKey = equivalence.EquivalenceDesignatorKey;
const equivalenceTypeCompatible = equivalence.equivalenceTypeCompatible;
const equivalenceConnected = equivalence.equivalenceConnected;
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
            try validation_helpers.validateDerivedTypeDef(self, derived);
        },
        .import => {},
        .intent => {},
        .optional => {},
        .value => |value_decl| {
            var first_error: ?anyerror = null;
            for (value_decl.names) |name| {
                validateCharacterValueDummy(self, name) catch |err| {
                    if (!self.usesExplicitDiagnosticBag()) return err;
                    if (first_error == null) first_error = err;
                    continue;
                };
            }
            if (first_error) |err| return err;
        },
        .interface_block => |interface_block| {
            try interfaces.validateExplicitInterfaceBlock(self, interface_block);
        },
        .dimension => |dim| {
            for (dim.items) |item| {
                if (self.unit.elemental and self.unit.kind == .function) {
                    const result_name = self.unit.result_name orelse self.unit.name;
                    if (std.ascii.eqlIgnoreCase(item.name, result_name)) {
                        if (dim.pointer) {
                            setAttributeConflictDiagnostic(self, "POINTER attribute conflicts with ELEMENTAL attribute");
                            return error.DuplicateDeclaration;
                        }
                        if (item.dims.len != 0) {
                            setSourceDiagnostic(self, self.unit.source, "must have a scalar result");
                            return error.DuplicateDeclaration;
                        }
                    }
                }
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
                try assumed_size.validateDeclaratorDims(self, item, self.symbols.items[idx].storage, false);
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
                if (parameterValueIllegalBozIntrinsicMessage(assign.value)) |message| {
                    setSourceDiagnostic(self, self.current_decl_source orelse ast.DeclSource{}, message);
                    return error.InvalidArgumentCount;
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
            var seen_common_items = std.StringHashMap(void).init(self.arena);
            var first_error: ?anyerror = null;
            for (common.blocks) |block| {
                if (block.name) |block_name| {
                    if (symbols_mod.findSymbolIndex(self, block_name)) |idx| {
                        const sym = self.symbols.items[idx];
                        if (sym.kind == .parameter or sym.is_intrinsic) {
                            setAttributeConflictDiagnostic(self, "COMMON block name conflicts with existing symbol");
                            if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                            if (first_error == null) first_error = error.DuplicateDeclaration;
                            continue;
                        }
                    }
                }
                for (block.items) |item| {
                    if (commonNameIsUseAssociated(self, item.name)) {
                        setAttributeConflictDiagnostic(self, "COMMON entity is USE associated from module");
                        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                        if (first_error == null) first_error = error.DuplicateDeclaration;
                        continue;
                    } else if (symbols_mod.findSymbolIndex(self, item.name)) |idx| {
                        const sym = self.symbols.items[idx];
                        if (sym.is_host_associated) {
                            setAttributeConflictDiagnostic(self, "COMMON entity is USE associated from module");
                            if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                            if (first_error == null) first_error = error.DuplicateDeclaration;
                            continue;
                        }
                    }
                    if (implicitNoneActive(self) and symbols_mod.findSymbolIndex(self, item.name) == null and !decl_scan.declaresNameLaterInCurrentUnit(self, item.name)) {
                        setAttributeConflictDiagnostic(self, "has no IMPLICIT type");
                        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                        if (first_error == null) first_error = error.DuplicateDeclaration;
                        continue;
                    }
                    var key_buf: [64]u8 = undefined;
                    const key = validation_helpers.lowerCommonName(self, item.name, &key_buf) catch item.name;
                    if (seen_common_items.contains(key)) {
                        setAttributeConflictDiagnostic(self, "is already in a COMMON block");
                        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                        if (first_error == null) first_error = error.DuplicateDeclaration;
                        continue;
                    }
                    if (commonEntityHasSaveAttribute(self.unit, item.name)) {
                        setAttributeConflictDiagnostic(self, "conflicts with SAVE attribute");
                        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                        if (first_error == null) first_error = error.DuplicateDeclaration;
                        continue;
                    }
                    try seen_common_items.put(if (key.ptr == key_buf[0..].ptr) try self.arena.dupe(u8, key) else key, {});
                    try decls.applyDeclarator(self, symbols_mod.implicitTypeSpec(self, item.name), item, .common, false, false, false, false, false, false);
                }
            }
            if (first_error) |err| return err;
        },
        .equivalence => |eqv| {
            var first_error: ?anyerror = null;
            for (eqv.groups) |group| {
                var root: ?EquivalenceDesignator = null;
                var seen = std.AutoHashMap(EquivalenceDesignatorKey, void).init(self.arena);
                for (group.items) |expr_node| {
                    expressions.resolveExpr(self, expr_node) catch |err| {
                        if (!self.usesExplicitDiagnosticBag()) return err;
                        if (first_error == null) first_error = err;
                        continue;
                    };

                    const designator = equivalence.equivalenceDesignator(self, expr_node) catch |err| {
                        if (!self.usesExplicitDiagnosticBag()) return err;
                        if (first_error == null) first_error = err;
                        continue;
                    };
                    const sym = self.symbols.items[designator.symbol_idx];
                    if (sym.kind == .parameter or sym.kind == .function or sym.is_intrinsic) {
                        setAttributeConflictDiagnostic(self, "EQUIVALENCE object is not a variable");
                        if (!self.usesExplicitDiagnosticBag()) return error.InvalidEquivalence;
                        if (first_error == null) first_error = error.InvalidEquivalence;
                        continue;
                    }
                    if (sym.is_host_associated or validation_helpers.equivalenceNameIsUseAssociated(self.unit, designator.name)) {
                        setAttributeConflictDiagnostic(self, "conflicts with USE ASSOCIATED attribute");
                        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                        if (first_error == null) first_error = error.DuplicateDeclaration;
                        continue;
                    }
                    if (sym.is_target) {
                        setAttributeConflictDiagnostic(self, "conflicts with TARGET attribute");
                        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                        if (first_error == null) first_error = error.DuplicateDeclaration;
                        continue;
                    }
                    if (validation_helpers.equivalenceNameHasBindC(self.unit, designator.name)) {
                        setAttributeConflictDiagnostic(self, "EQUIVALENCE attribute conflicts with BIND");
                        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                        if (first_error == null) first_error = error.DuplicateDeclaration;
                        continue;
                    }
                    if (self.unit.pure and sym.storage == .common) {
                        setAttributeConflictDiagnostic(self, "EQUIVALENCE object in the pure procedure");
                        validation_helpers.emitPureEquivalenceAssignmentDiagnostics(self, group);
                        if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                        if (first_error == null) first_error = error.DuplicateDeclaration;
                        continue;
                    }
                    const designator_key = EquivalenceDesignatorKey{
                        .symbol_idx = designator.symbol_idx,
                        .byte_offset = designator.byte_offset,
                    };
                    if (seen.contains(designator_key)) {
                        setAttributeConflictDiagnostic(self, "Duplicate EQUIVALENCE object");
                        if (!self.usesExplicitDiagnosticBag()) return error.InvalidEquivalence;
                        if (first_error == null) first_error = error.InvalidEquivalence;
                        continue;
                    }
                    try seen.put(designator_key, {});

                    if (root) |base| {
                        if (!equivalenceTypeCompatible(base.type_spec, designator.type_spec)) {
                            setAttributeConflictDiagnostic(self, "EQUIVALENCE objects have incompatible types");
                            if (!self.usesExplicitDiagnosticBag()) return error.InvalidEquivalence;
                            if (first_error == null) first_error = error.InvalidEquivalence;
                            continue;
                        }
                        if (validation_helpers.equivalenceInitializersConflict(self, base.symbol_idx, designator.symbol_idx)) {
                            setAttributeConflictDiagnostic(self, "Overlapping unequal initializers");
                            if (!self.usesExplicitDiagnosticBag()) return error.InvalidEquivalence;
                            if (first_error == null) first_error = error.InvalidEquivalence;
                            continue;
                        }
                        const relation = subNoOverflow(base.byte_offset, designator.byte_offset) orelse
                            return error.InvalidEquivalence;
                        const merged = unionEquivalence(self, base.name, designator.name, relation) catch |err| {
                            if (!self.usesExplicitDiagnosticBag()) return err;
                            if (first_error == null) first_error = err;
                            continue;
                        };
                        if (commonEquivalenceOverlap(self)) {
                            setAttributeConflictDiagnostic(self, "indirectly overlap COMMON; equivalenced to another COMMON");
                            if (!self.usesExplicitDiagnosticBag()) return error.InvalidEquivalence;
                            if (first_error == null) first_error = error.InvalidEquivalence;
                            continue;
                        }
                        if (!merged) {
                            if (!self.usesExplicitDiagnosticBag()) return error.EquivalenceCycle;
                            if (first_error == null) first_error = error.EquivalenceCycle;
                            continue;
                        }
                    } else {
                        root = designator;
                    }
                }
            }
            if (first_error) |err| return err;
        },
        .external => |ext| {
            for (ext.names) |name| {
                if (try hasCommonBlock(self, name)) {
                    setAttributeConflictDiagnostic(self, "COMMON block cannot have the EXTERNAL attribute");
                    return error.DuplicateDeclaration;
                }
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
                            if (implicitNoneActive(self) and symbols_mod.findSymbolIndex(self, name) == null and !decl_scan.declaresNameLaterInCurrentUnit(self, name)) {
                                setAttributeConflictDiagnostic(self, "has no IMPLICIT type");
                                return error.DuplicateDeclaration;
                            }
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

fn validateCharacterValueDummy(self: *context.Context, name: []const u8) !void {
    if (!currentUnitHasDummyArg(self, name)) return;
    const idx = symbols_mod.findSymbolIndex(self, name) orelse return;
    const sym = self.symbols.items[idx];
    if (sym.type_spec.lowered_kind != .character) return;
    if (sym.type_spec.char_len_kind != .constant) {
        setSourceDiagnostic(self, self.unit.source, "VALUE attribute must have constant length");
        return error.InvalidArgumentCount;
    }
    if (valueDummyUsesCCharKind(self, name) and (sym.type_spec.char_len orelse 1) != 1) {
        setSourceDiagnostic(self, self.unit.source, "VALUE attribute must have length one");
        return error.InvalidArgumentCount;
    }
}

fn currentUnitHasDummyArg(self: *const context.Context, name: []const u8) bool {
    for (self.unit.args) |arg| {
        if (std.ascii.eqlIgnoreCase(arg, name)) return true;
    }
    return false;
}

fn valueDummyUsesCCharKind(self: *const context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .type_decl) continue;
        const type_decl = decl.type_decl;
        if (type_decl.type_kind != .character) continue;
        for (type_decl.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            const selector = type_decl.kind_selector orelse return false;
            return exprReferencesIdentifier(selector, "c_char");
        }
    }
    return false;
}

fn exprReferencesIdentifier(expr: *ast.Expr, name: []const u8) bool {
    return switch (expr.*) {
        .identifier => |ident| std.ascii.eqlIgnoreCase(ident, name),
        .unary => |un| exprReferencesIdentifier(un.expr, name),
        .binary => |bin| exprReferencesIdentifier(bin.left, name) or exprReferencesIdentifier(bin.right, name),
        .call_or_subscript => |call| blk: {
            if (std.ascii.eqlIgnoreCase(call.name, name)) break :blk true;
            for (call.args) |arg| {
                if (exprReferencesIdentifier(arg, name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn implicitNoneActive(self: *const context.Context) bool {
    const limit = self.current_decl_index orelse self.unit.decls.len;
    var active = false;
    var decl_idx: usize = 0;
    while (decl_idx < limit and decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        const decl = self.unit.decls[decl_idx];
        if (decl != .implicit) continue;
        active = decl.implicit.rules.len == 0;
    }
    return active;
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

fn parameterValueIllegalBozIntrinsicMessage(expr_node: *ast.Expr) ?[]const u8 {
    switch (expr_node.*) {
        .call_or_subscript => |call| {
            if (call.args.len > 0 and exprIsBozLiteral(call.args[0])) {
                if (std.ascii.eqlIgnoreCase(call.name, "c_sizeof")) return "cannot appear";
                if (std.ascii.eqlIgnoreCase(call.name, "sizeof")) return "cannot be an actual";
            }
            for (call.args) |arg| {
                if (parameterValueIllegalBozIntrinsicMessage(arg)) |message| return message;
            }
            return null;
        },
        .unary => |unary| return parameterValueIllegalBozIntrinsicMessage(unary.expr),
        .binary => |binary| return parameterValueIllegalBozIntrinsicMessage(binary.left) orelse parameterValueIllegalBozIntrinsicMessage(binary.right),
        .array_constructor => |ctor| {
            for (ctor.items) |item| {
                if (parameterValueIllegalBozIntrinsicMessage(item)) |message| return message;
            }
            return null;
        },
        .complex_literal => |lit| return parameterValueIllegalBozIntrinsicMessage(lit.real) orelse parameterValueIllegalBozIntrinsicMessage(lit.imag),
        .substring => |sub| {
            for (sub.args) |arg| {
                if (parameterValueIllegalBozIntrinsicMessage(arg)) |message| return message;
            }
            if (sub.start) |start| if (parameterValueIllegalBozIntrinsicMessage(start)) |message| return message;
            if (sub.end) |end| if (parameterValueIllegalBozIntrinsicMessage(end)) |message| return message;
            return null;
        },
        .component => |comp| {
            if (parameterValueIllegalBozIntrinsicMessage(comp.base)) |message| return message;
            for (comp.args) |arg| {
                if (parameterValueIllegalBozIntrinsicMessage(arg)) |message| return message;
            }
            return null;
        },
        .dim_range => |range| {
            if (range.lower) |lower| if (parameterValueIllegalBozIntrinsicMessage(lower)) |message| return message;
            if (parameterValueIllegalBozIntrinsicMessage(range.upper)) |message| return message;
            if (range.stride) |stride| if (parameterValueIllegalBozIntrinsicMessage(stride)) |message| return message;
            return null;
        },
        .implied_do => |implied_do| {
            for (implied_do.items) |item| {
                if (parameterValueIllegalBozIntrinsicMessage(item)) |message| return message;
            }
            if (parameterValueIllegalBozIntrinsicMessage(implied_do.start)) |message| return message;
            if (parameterValueIllegalBozIntrinsicMessage(implied_do.end)) |message| return message;
            if (implied_do.step) |step| if (parameterValueIllegalBozIntrinsicMessage(step)) |message| return message;
            return null;
        },
        .identifier, .literal => return null,
    }
}

fn exprIsBozLiteral(expr_node: *ast.Expr) bool {
    if (expr_node.* != .literal or expr_node.literal.kind != .string) return false;
    return literal_utils.parseBozInt(expr_node.literal.text) catch null != null;
}

fn commonNameIsUseAssociated(self: *context.Context, name: []const u8) bool {
    var decl_idx: usize = 0;
    while (decl_idx < self.unit.prelude_decl_count and decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        const source = if (decl_idx < self.unit.decl_sources.len) self.unit.decl_sources[decl_idx] else ast.DeclSource{};
        const owner_name = source.owner_name orelse continue;
        if (self.unit.owner_name) |unit_owner| {
            if (std.ascii.eqlIgnoreCase(unit_owner, owner_name)) continue;
        }
        const exported_name = decl_queries.exportedName(self.unit.decls[decl_idx]) orelse continue;
        if (std.ascii.eqlIgnoreCase(exported_name, name)) return true;
    }
    return false;
}

fn commonEntityHasSaveAttribute(unit: ast.ProgramUnit, name: []const u8) bool {
    for (unit.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                if (!type_decl.save) continue;
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .save => |save_decl| {
                if (save_decl.save_all) return true;
                for (save_decl.items) |save_item| {
                    switch (save_item) {
                        .name => |save_name| if (std.ascii.eqlIgnoreCase(save_name, name)) return true,
                        .common => {},
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn commonEquivalenceOverlap(self: *context.Context) bool {
    var first_name: ?[]const u8 = null;
    var first_block: ?[]const u8 = null;
    for (self.unit.decls) |decl| {
        if (decl != .common) continue;
        for (decl.common.blocks) |block| {
            for (block.items) |item| {
                if (first_name == null) {
                    first_name = item.name;
                    first_block = block.name;
                    continue;
                }
                if (commonBlockNameEqual(first_block, block.name)) continue;
                if (equivalenceConnected(self, first_name.?, item.name)) return true;
            }
        }
    }
    return false;
}

fn commonBlockNameEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.ascii.eqlIgnoreCase(a.?, b.?);
}

fn isImportedPreludeDecl(self: *context.Context) bool {
    const decl_idx = self.current_decl_index orelse return false;
    if (decl_idx >= self.unit.prelude_decl_count) return false;
    const decl_source = self.current_decl_source orelse return false;
    return decl_source.owner_name != null;
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
