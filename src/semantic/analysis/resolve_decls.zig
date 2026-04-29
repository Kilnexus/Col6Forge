const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const common_diag = @import("../../common/diagnostic.zig");
const catalog = @import("../../common/error_catalog.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");
const symbols_mod = @import("resolve_symbols.zig");
const constants = @import("resolve_const.zig");
const resolve_expr = @import("resolve_expr.zig");
const type_kind_selector = @import("../type_kind_selector.zig");
const procedure_interfaces = @import("check_statements/procedure_interfaces.zig");
const common_entity_queries = @import("common_entity_queries.zig");
const decl_diag = @import("resolve_decls_diag_helpers.zig");
const decl_initializers = @import("resolve_decls_initializers.zig");
const spec_expr = @import("resolve_decls_spec_expr.zig");
const polymorphic_decls = @import("resolve_decls_polymorphic.zig");
const assumed_size = @import("assumed_size.zig");
const deferred_shape = @import("deferred_shape.zig");
const decl_scan = @import("decl_scan.zig");

const StorageClass = symbols.StorageClass;
const CharacterLengthKind = symbols.CharacterLengthKind;
pub const DeclarationAspect = enum {
    explicit_type,
    dimensions,
};
pub fn applyTypeDecl(self: *context.Context, decl: ast.TypeDecl) !void {
    var resolved_type = try resolvedDeclTypeSpec(self, decl.type_kind, decl.derived_type_name, decl.kind_selector, decl.polymorphic, decl.assumed_type);
    resolved_type = resolved_type.withPolymorphic(decl.polymorphic).withAssumedType(decl.assumed_type);
    var first_err: ?anyerror = null;
    for (decl.items) |item| {
        var effective_type = resolved_type;
        var effective_item = item;
        if (decl.pointer and procedure_interfaces.isAbstractInterfaceProcedure(self, item.name)) {
            const source = self.current_decl_source orelse ast.DeclSource{};
            self.setDiagnosticDetailed(
                if (source.line == 0) 1 else source.line,
                if (source.column == 0) 1 else source.column,
                catalog.semantic.duplicate_declaration.code,
                "PROCEDURE POINTER attribute conflicts with ABSTRACT attribute",
                source.text,
                &.{.{ .text = "This name is already bound to an ABSTRACT interface procedure in the current scope." }},
                &.{.{ .text = "Rename the data pointer object or use a different explicit interface name." }},
            );
            return error.DuplicateDeclaration;
        }
        if (decl.type_kind == .character and decl.kind_selector == null) {
            if (try decl_initializers.isoCBindingCharacterKindShorthandType(self, item.char_len)) |shorthand_type| {
                effective_type = shorthand_type;
                effective_item.char_len = null;
            }
        }
        try applyDeclarator(self, effective_type, effective_item, .local, true, decl.allocatable, decl.pointer, decl.target, decl.contiguous, decl.parameter);
        const idx = symbols_mod.findSymbolIndex(self, item.name) orelse return error.UnknownSymbol;
        validateElementalDummyDeclaration(self, decl, effective_item, self.symbols.items[idx]) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        validateValueIntentDeclaration(self, decl) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        validateElementalFunctionResultDeclaration(self, decl, effective_item) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        validateFunctionResultInitializer(self, effective_item) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        try assumed_size.validateDerivedIntentOutAssumedSizeDummy(self, decl, effective_item, effective_type);
        decl_initializers.validateOldStyleInitializer(self, effective_item, self.symbols.items[idx]) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        polymorphic_decls.validateTypeDecl(self, decl, effective_type, self.symbols.items[idx]) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        polymorphic_decls.validateInitializer(self, decl, effective_type, item) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        if (decl.external) {
            self.symbols.items[idx].is_external = true;
            try validateExternalCharacterDeclarator(self, self.symbols.items[idx], item);
        }
        try validateKnownFunctionResultDeclaration(self, self.symbols.items[idx], true);
        decl_initializers.validateCharacterArrayConstructorInitializer(self, self.symbols.items[idx], item.init) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        decl_initializers.validateDataPointerInitializer(self, decl, effective_type, effective_item) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
        decl_initializers.validateDeclaratorInitializer(self, item.init) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
    }
    if (first_err) |err| return err;
}

fn validateValueIntentDeclaration(self: *context.Context, decl: ast.TypeDecl) !void {
    if (!decl.value_attr) return;
    const intent = decl.intent orelse return;
    switch (intent) {
        .in => return,
        .inout => {
            emitCurrentDeclDiagnostic(self, "VALUE attribute conflicts with INTENT.INOUT. attribute");
            return error.InvalidArgumentCount;
        },
        .out => {
            emitCurrentDeclDiagnostic(self, "VALUE attribute conflicts with INTENT.OUT. attribute");
            return error.InvalidArgumentCount;
        },
    }
}

fn validateFunctionResultInitializer(self: *context.Context, item: ast.Declarator) !void {
    if (item.init == null) return;
    if (self.unit.kind != .function) return;
    const result_name = self.unit.result_name orelse self.unit.name;
    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) return;
    const source = self.unit.source;
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "function result cannot have an initializer",
        source.text,
    );
    return error.InvalidInitializer;
}

fn validateElementalFunctionResultDeclaration(
    self: *context.Context,
    decl: ast.TypeDecl,
    item: ast.Declarator,
) !void {
    if (!self.unit.elemental or self.unit.kind != .function) return;
    const result_name = self.unit.result_name orelse self.unit.name;
    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) return;
    if (item.dims.len != 0) {
        emitSourceDiagnostic(self, self.unit.source, "must have a scalar result");
        return error.InvalidArgumentCount;
    }
    if (decl.pointer) {
        emitCurrentDeclDiagnostic(self, "POINTER attribute conflicts with ELEMENTAL attribute");
        return error.InvalidArgumentCount;
    }
    if (decl.allocatable) {
        emitCurrentDeclDiagnostic(self, "shall not have an ALLOCATABLE or POINTER attribute");
        return error.InvalidArgumentCount;
    }
}

fn validateElementalDummyDeclaration(
    self: *context.Context,
    decl: ast.TypeDecl,
    item: ast.Declarator,
    sym: symbols.Symbol,
) !void {
    if (!self.unit.elemental or sym.storage != .dummy) return;
    if (item.dims.len != 0) {
        emitCurrentDeclDiagnostic(self, "must be scalar");
        return error.InvalidArgumentCount;
    }
    if (decl.pointer) {
        emitCurrentDeclDiagnostic(self, "POINTER attribute");
        return error.InvalidArgumentCount;
    }
    if (decl.allocatable) {
        emitCurrentDeclDiagnostic(self, "ALLOCATABLE attribute");
        return error.InvalidArgumentCount;
    }
    if (decl.intent == null and !decl.value_attr and !dummyHasSeparateIntentOrValue(self, item.name)) {
        const message = std.fmt.allocPrint(
            self.arena,
            "Argument '{s}' of elemental procedure '{s}' must have its INTENT specified or have the VALUE attribute",
            .{ item.name, self.unit.name },
        ) catch "must have its INTENT specified or have the VALUE attribute";
        emitCurrentDeclDiagnostic(self, message);
        return error.InvalidArgumentCount;
    }
}

fn dummyHasSeparateIntentOrValue(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |unit_decl| {
        switch (unit_decl) {
            .intent => |intent_decl| {
                for (intent_decl.names) |intent_name| {
                    if (std.ascii.eqlIgnoreCase(intent_name, name)) return true;
                }
            },
            .value => |value_decl| {
                for (value_decl.names) |value_name| {
                    if (std.ascii.eqlIgnoreCase(value_name, name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn emitCurrentDeclDiagnostic(self: *context.Context, message: []const u8) void {
    const source = self.current_decl_source orelse ast.DeclSource{};
    emitSourceDiagnostic(self, source, message);
}

fn emitSourceDiagnostic(self: *context.Context, source: ast.DeclSource, message: []const u8) void {
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_argument_count.code,
        message,
        source.text,
    );
}

pub fn validateDeclaratorInitializer(self: *context.Context, init_expr: ?*ast.Expr) !void {
    return decl_initializers.validateDeclaratorInitializer(self, init_expr);
}
fn characterExprLogicalLen(self: *context.Context, expr: *ast.Expr) ?usize {
    return decl_initializers.characterExprLogicalLen(self, expr);
}

pub fn applyProcedureDecl(self: *context.Context, decl: ast.ProcedureDecl) !void {
    if (decl.save and !decl.pointer) {
        const source = self.current_decl_source orelse ast.DeclSource{};
        self.setDiagnosticStructured(
            if (source.line == 0) 1 else source.line,
            if (source.column == 0) 1 else source.column,
            catalog.semantic.duplicate_declaration.code,
            "SAVE attribute conflicts with PROCEDURE attribute",
            source.text,
            "conflicting declaration here",
            &.{},
            &.{},
            &.{},
        );
        return error.DuplicateDeclaration;
    }
    var first_err: ?anyerror = null;
    for (decl.items) |item| {
        if (common_entity_queries.currentUnitDeclaresCommonEntity(self.unit, item.name)) {
            const source = self.current_decl_source orelse ast.DeclSource{};
            self.setDiagnosticStructured(
                if (source.line == 0) 1 else source.line,
                if (source.column == 0) 1 else source.column,
                catalog.semantic.duplicate_declaration.code,
                "PROCEDURE attribute conflicts with COMMON attribute",
                source.text,
                "conflicting declaration here",
                &.{.{ .text = "A COMMON block entity cannot also be declared with the PROCEDURE attribute." }},
                &.{.{ .text = "Remove the PROCEDURE declaration or take the entity out of the COMMON block." }},
                &.{},
            );
            return error.DuplicateDeclaration;
        }
        const resolved = try resolveProcedureDeclarator(self, decl.interface, item.name);
        if (decl.pointer) {
            if (resolved.sig) |sig| {
                if (sig.elemental) {
                    const source = self.current_decl_source orelse ast.DeclSource{};
                    const message = std.fmt.allocPrint(
                        self.arena,
                        "Procedure pointer '{s}' at .1. shall not be elemental",
                        .{item.name},
                    ) catch "Procedure pointer shall not be elemental";
                    self.setDiagnosticDetailed(
                        if (source.line == 0) 1 else source.line,
                        if (source.column == 0) 1 else source.column,
                        catalog.semantic.duplicate_declaration.code,
                        message,
                        source.text,
                        &.{.{ .text = "An ELEMENTAL procedure cannot be the declared interface of a procedure pointer object." }},
                        &.{.{ .text = "Use a non-ELEMENTAL explicit interface for this procedure pointer declaration." }},
                    );
                    return error.DuplicateDeclaration;
                }
            }
        }
        try applyDeclarator(self, resolved.type_spec, item, .local, resolved.explicit_type, false, decl.pointer, false, false, false);

        const idx = symbols_mod.findSymbolIndex(self, item.name) orelse return error.UnknownSymbol;
        var sym = &self.symbols.items[idx];
        if (sym.storage == .common) {
            const source = self.current_decl_source orelse ast.DeclSource{};
            self.setDiagnosticStructured(
                if (source.line == 0) 1 else source.line,
                if (source.column == 0) 1 else source.column,
                catalog.semantic.duplicate_declaration.code,
                "PROCEDURE attribute conflicts with COMMON attribute",
                source.text,
                "conflicting declaration here",
                &.{.{ .text = "A COMMON block entity cannot also be declared with the PROCEDURE attribute." }},
                &.{.{ .text = "Remove the PROCEDURE declaration or take the entity out of the COMMON block." }},
                &.{},
            );
            return error.DuplicateDeclaration;
        }
        try validateKnownFunctionResultDeclaration(self, sym.*, false);
        if (resolved.kind) |kind| {
            sym.kind = kind;
        }
        if (sym.storage == .dummy or !decl.pointer) {
            sym.is_external = true;
        }
        decl_initializers.validateProcedurePointerInitializer(self, decl, item) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            continue;
        };
    }
    if (first_err) |err| return err;
}

// applyDeclarator mutates the symbol table entry for `item.name` in-place.
// It may set type, dimensions, storage class, and CHARACTER length depending
// on declaration context.
pub fn applyDeclarator(
    self: *context.Context,
    type_spec: symbols.TypeSpec,
    item: ast.Declarator,
    storage: StorageClass,
    explicit_type: bool,
    allocatable: bool,
    pointer: bool,
    target: bool,
    contiguous: bool,
    allow_parameter_implied_shape: bool,
) !void {
    try validateConcreteAbstractTypeUse(self, type_spec);
    const idx = try symbols_mod.ensureDeclaredSymbol(self, item.name);
    var sym = &self.symbols.items[idx];
    if (explicit_type and sym.type_explicit) {
        emitDuplicateDeclaratorDiagnostic(self, item.name, .explicit_type);
        return error.DuplicateDeclaration;
    }
    if (explicit_type) {
        sym.applyTypeSpec(type_spec);
        sym.type_explicit = true;
    } else if (!sym.type_explicit) {
        sym.applyTypeSpec(type_spec);
    }
    if (item.dims.len > 0) {
        if (sym.dims.len > 0) {
            // Do not silently overwrite previously declared shape.
            emitDuplicateDeclaratorDiagnostic(self, item.name, .dimensions);
            return error.DuplicateDeclaration;
        }
        try assumed_size.validateDeclaratorDims(self, item, if (sym.storage == .dummy) .dummy else storage, allow_parameter_implied_shape);
        sym.dims = item.dims;
        try spec_expr.validateDeclaratorDimensionExprs(self, item.dims);
    }
    if (storage == .common) {
        sym.storage = .common;
    } else if (sym.storage != .dummy and sym.storage != .common) {
        sym.storage = storage;
    }
    if (allocatable) {
        sym.is_allocatable = true;
        if (sym.dims.len != 0 and !deferred_shape.hasDeferredShape(sym.dims)) {
            emitDescriptorArrayShapeDiagnostic(self, "ALLOCATABLE");
            return error.DuplicateDeclaration;
        }
    }
    if (pointer) {
        sym.is_pointer = true;
        if (sym.dims.len != 0 and !deferred_shape.hasDeferredShape(sym.dims)) {
            emitDescriptorArrayShapeDiagnostic(self, "POINTER");
            return error.DuplicateDeclaration;
        }
    }
    if (target) {
        sym.is_target = true;
    }
    if (contiguous) {
        if (item.dims.len == 0) {
            emitContiguousArrayRequirementDiagnostic(self, item.name);
            return error.InvalidArgumentCount;
        }
        sym.contiguous = true;
    }
    if (item.no_arg_check) {
        sym.no_arg_check = true;
    }
    if (sym.loweredKind() == .derived and sym.type_spec.polymorphic and sym.type_spec.derived_type_name == null and sym.storage != .dummy and !sym.is_allocatable and !sym.is_pointer) {
        const decl_source = self.current_decl_source orelse ast.DeclSource{};
        if (polymorphic_decls.hasSeparateParameterSpec(self, item.name)) {
            self.setDiagnosticDetailed(
                if (decl_source.line == 0) 1 else decl_source.line,
                if (decl_source.column == 0) 1 else decl_source.column,
                catalog.semantic.invalid_unlimited_polymorphic_entity.code,
                "cannot have the PARAMETER attribute",
                decl_source.text,
                &.{.{ .text = "A polymorphic entity may not be declared with the PARAMETER attribute." }},
                &.{.{ .text = "Remove PARAMETER or make the entity nonpolymorphic." }},
            );
            if (!self.usesExplicitDiagnosticBag()) return error.InvalidUnlimitedPolymorphicEntity;
            return;
        }
        self.setDiagnosticDetailed(
            if (decl_source.line == 0) 1 else decl_source.line,
            if (decl_source.column == 0) 1 else decl_source.column,
            catalog.semantic.invalid_unlimited_polymorphic_entity.code,
            catalog.semantic.invalid_unlimited_polymorphic_entity.message,
            decl_source.text,
            &.{.{ .text = "Unlimited polymorphic entities must be dummy arguments, POINTERs, or ALLOCATABLE objects." }},
            &.{.{ .text = "Make this CLASS(*) entity a dummy, POINTER, or ALLOCATABLE object." }},
        );
        if (!self.usesExplicitDiagnosticBag()) return error.InvalidUnlimitedPolymorphicEntity;
        return;
    }
    if (sym.type_spec.assumed_type and sym.storage != .dummy) {
        const decl_source = self.current_decl_source orelse ast.DeclSource{};
        const message = std.fmt.allocPrint(
            self.arena,
            "Assumed type of variable '{s}' is only permitted for dummy arguments",
            .{item.name},
        ) catch "Assumed type of variable is only permitted for dummy arguments";
        self.setDiagnosticDetailed(
            if (decl_source.line == 0) 1 else decl_source.line,
            if (decl_source.column == 0) 1 else decl_source.column,
            catalog.semantic.invalid_unlimited_polymorphic_entity.code,
            message,
            decl_source.text,
            &.{.{ .text = "TYPE(*) may only describe an assumed-type dummy argument." }},
            &.{.{ .text = "Move this entity into a dummy argument list or use a concrete TYPE declaration." }},
        );
        if (!self.usesExplicitDiagnosticBag()) return error.InvalidUnlimitedPolymorphicEntity;
        return;
    }

    // Use the resolved symbol type after declaration merge. Non-type declarations
    // (e.g. COMMON/DIMENSION) must not accidentally erase CHARACTER length.
    if (!sym.isCharacter()) {
        sym.applyTypeSpec(sym.type_spec.withCharacterLength(.none, null));
        return;
    }

    var length: usize = if (sym.effectiveCharLenKind() == .constant)
        sym.effectiveCharLen() orelse 1
    else
        1;
    if (item.char_len_deferred) {
        if (allowsDeferredCharacterLength(self, sym.*)) {
            sym.applyTypeSpec(sym.type_spec.withCharacterLength(.deferred, null));
            return;
        }
        return error.InvalidCharLen;
    }
    if (item.char_len) |len_expr| {
        if (len_expr.* == .literal and len_expr.literal.kind == .assumed_size) {
            sym.applyTypeSpec(sym.type_spec.withCharacterLength(.assumed, null));
            return;
        }
        const runtime_char_len_ok = allowsNonConstantCharacterLengthExpr(self, sym.*);
        if (!runtime_char_len_ok) {
            try spec_expr.validateRestrictedSpecExpr(self, len_expr);
        }
        if (try constants.evalConst(self, len_expr)) |value| {
            switch (value) {
                .integer => |int_val| {
                    length = if (int_val < 0) 0 else @as(usize, @intCast(int_val));
                },
                .real, .complex, .logical, .string => {
                    if (decl_diag.emitCharacterLenTypingDiagnostic(self, len_expr)) return error.InvalidCharLen;
                    return error.InvalidCharLen;
                },
            }
        } else {
            // Explicit LEN expressions inside procedures may denote automatic
            // CHARACTER objects whose length is only known at entry.
            if (runtime_char_len_ok) {
                sym.applyTypeSpec(sym.type_spec.withCharacterLength(.deferred, null));
                return;
            }
            if (decl_diag.emitCharacterLenTypingDiagnostic(self, len_expr)) return error.InvalidCharLen;
            return error.InvalidCharLen;
        }
    } else if (!explicit_type and sym.effectiveCharLenKind() != .constant) {
        if (symbols_mod.implicitCharLen(self, item.name)) |implicit_len| {
            length = implicit_len;
        }
    }
    sym.applyTypeSpec(sym.type_spec.withCharacterLength(.constant, length));
}

fn emitDescriptorArrayShapeDiagnostic(self: *context.Context, attr_name: []const u8) void {
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    const message = std.fmt.allocPrint(
        self.arena,
        "{s} array must have a deferred shape or assumed rank",
        .{attr_name},
    ) catch "array must have a deferred shape or assumed rank";
    const help = std.fmt.allocPrint(
        self.arena,
        "Use ':' or assumed-rank form for each {s} array dimension.",
        .{attr_name},
    ) catch "Use ':' or assumed-rank form for each descriptor array dimension.";
    self.setDiagnosticDetailed(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.duplicate_declaration.code,
        message,
        decl_source.text,
        &.{.{ .text = "A POINTER or ALLOCATABLE array declaration may not use explicit shape bounds." }},
        &.{.{ .text = help }},
    );
}

pub fn findPriorDeclaratorSource(
    self: *context.Context,
    target_name: []const u8,
    aspect: DeclarationAspect,
) ?ast.DeclSource {
    const current_decl_idx = self.current_decl_index orelse return null;
    var decl_idx: usize = 0;
    while (decl_idx < current_decl_idx and decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        if (!declarationMatchesAspect(self.unit.decls[decl_idx], target_name, aspect)) continue;
        if (decl_idx < self.unit.decl_sources.len) return self.unit.decl_sources[decl_idx];
        return null;
    }
    return null;
}

fn emitDuplicateDeclaratorDiagnostic(
    self: *context.Context,
    target_name: []const u8,
    aspect: DeclarationAspect,
) void {
    const current_decl = self.current_decl_source orelse return;
    const prior_decl = findPriorDeclaratorSource(self, target_name, aspect) orelse return;
    const secondary_spans = [_]common_diag.DiagnosticSpan{
        declSourceToSecondarySpan(prior_decl, "first declaration here"),
    };
    self.setDiagnosticStructured(
        if (current_decl.line == 0) 1 else current_decl.line,
        if (current_decl.column == 0) 1 else current_decl.column,
        catalog.semantic.duplicate_declaration.code,
        catalog.semantic.duplicate_declaration.message,
        current_decl.text,
        "redeclared here",
        &.{.{ .text = "A symbol's type and shape must not be declared twice in the same scoping unit." }},
        &.{.{ .text = "Remove the duplicate declaration, or keep the type/shape information in a single declaration." }},
        secondary_spans[0..],
    );
}

fn declSourceToSecondarySpan(source: ast.DeclSource, label: []const u8) common_diag.DiagnosticSpan {
    const line = if (source.line == 0) 1 else source.line;
    const column = if (source.column == 0) 1 else source.column;
    return .{
        .file_path = "",
        .line = line,
        .column = column,
        .end_column = @max(column + 1, source.text.len + 1),
        .line_text = source.text,
        .label = label,
    };
}

fn emitContiguousArrayRequirementDiagnostic(
    self: *context.Context,
    target_name: []const u8,
) void {
    const current_decl = self.current_decl_source orelse return;
    const line = if (current_decl.line == 0) 1 else current_decl.line;
    const column = if (current_decl.column == 0) 1 else current_decl.column;
    const message = std.fmt.allocPrint(self.arena, "'{s}' has the CONTIGUOUS attribute but is not an array", .{target_name}) catch "Entity has the CONTIGUOUS attribute but is not an array";
    self.setDiagnosticDetailed(
        line,
        column,
        catalog.semantic.invalid_argument_count.code,
        message,
        current_decl.text,
        &.{.{ .text = "CONTIGUOUS is only valid on array entities in the declaration model." }},
        &.{.{ .text = "Add an array declarator, or drop CONTIGUOUS from the scalar declaration." }},
    );
}

fn declarationMatchesAspect(decl: ast.Decl, target_name: []const u8, aspect: DeclarationAspect) bool {
    return switch (decl) {
        .type_decl => |type_decl| declaratorsMatchAspect(type_decl.items, target_name, aspect),
        .procedure => |procedure_decl| aspect == .dimensions and declaratorsMatchAspect(procedure_decl.items, target_name, aspect),
        .dimension => |dim_decl| aspect == .dimensions and declaratorsMatchAspect(dim_decl.items, target_name, aspect),
        .common => |common_decl| aspect == .dimensions and commonDeclMatchesAspect(common_decl, target_name),
        else => false,
    };
}

fn commonDeclMatchesAspect(common_decl: ast.CommonDecl, target_name: []const u8) bool {
    for (common_decl.blocks) |block| {
        if (declaratorsMatchAspect(block.items, target_name, .dimensions)) return true;
    }
    return false;
}

fn declaratorsMatchAspect(
    items: []const ast.Declarator,
    target_name: []const u8,
    aspect: DeclarationAspect,
) bool {
    for (items) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, target_name)) continue;
        return switch (aspect) {
            .explicit_type => true,
            .dimensions => item.dims.len > 0,
        };
    }
    return false;
}

fn validateConcreteAbstractTypeUse(self: *context.Context, type_spec: symbols.TypeSpec) !void {
    if (type_spec.lowered_kind != .derived or type_spec.polymorphic) return;
    const derived_name = type_spec.derived_type_name orelse return;
    const derived_info = symbols_mod.lookupDerivedType(self, derived_name) orelse return error.UnexpectedTypeDecl;
    if (!derived_info.abstract) return;

    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    const line = if (decl_source.line == 0) 1 else decl_source.line;
    const column = if (decl_source.column == 0) 1 else decl_source.column;
    const message = std.fmt.allocPrint(self.arena, "is of the ABSTRACT type '{s}'", .{derived_name}) catch "is of the ABSTRACT type";
    if (derived_info.source.line != 0 or derived_info.source.column != 0) {
        const related = [_]common_diag.DiagnosticSpan{
            declSourceToSecondarySpan(derived_info.source, "abstract type declared here"),
        };
        self.setDiagnosticStructured(
            line,
            column,
            catalog.semantic.unexpected_type_decl.code,
            message,
            decl_source.text,
            "concrete abstract-type entity here",
            &.{.{ .text = "A nonpolymorphic entity may not have an ABSTRACT derived type." }},
            &.{.{ .text = "Declare this entity as CLASS(...), POINTER, or ALLOCATABLE, or use a concrete extension type instead." }},
            related[0..],
        );
    } else {
        self.setDiagnosticDetailed(
            line,
            column,
            catalog.semantic.unexpected_type_decl.code,
            message,
            decl_source.text,
            &.{.{ .text = "A nonpolymorphic entity may not have an ABSTRACT derived type." }},
            &.{.{ .text = "Declare this entity as CLASS(...), POINTER, or ALLOCATABLE, or use a concrete extension type instead." }},
        );
    }
    return error.UnexpectedTypeDecl;
}

fn validateExternalCharacterDeclarator(
    self: *context.Context,
    sym: symbols.Symbol,
    item: ast.Declarator,
) !void {
    if (!sym.isCharacter()) return;
    const known_spec = symbols_mod.lookupKnownFunctionResolvedSpec(self, sym.name) orelse return;
    if (known_spec.lowered_kind != .character or known_spec.char_len_kind != .constant) return;
    const len_expr = item.char_len orelse return;
    if (item.char_len_deferred) {
        decl_diag.emitExternalCharacterLenDiagnostic(self);
        return error.InvalidCharLen;
    }
    if (len_expr.* == .literal and len_expr.literal.kind == .assumed_size) return;
    if (try constants.evalConst(self, len_expr)) |_| return;
    decl_diag.emitExternalCharacterLenDiagnostic(self);
    return error.InvalidCharLen;
}

fn validateKnownFunctionResultDeclaration(
    self: *context.Context,
    sym: symbols.Symbol,
    prefer_length_message: bool,
) !void {
    if (sym.storage == .dummy) return;
    const has_visible_explicit_interface = procedure_interfaces.calleeHasVisibleExplicitInterface(self, sym.name);
    if (self.unit.kind == .function) {
        const result_name = self.unit.result_name orelse self.unit.name;
        if (std.ascii.eqlIgnoreCase(sym.name, result_name)) return;
    }
    if (self.unit.kind == .function and self.unit.owner_name == null and self.unit.prelude_decl_count == 0) return;
    if (self.unit.kind != .function and !has_visible_explicit_interface) return;
    const known_sig = symbols_mod.lookupKnownProcedureSig(self, sym.name) orelse return;
    if (known_sig.kind != .function) return;
    const known_spec = symbols_mod.lookupKnownFunctionResolvedSpec(self, sym.name) orelse return;
    const message = functionResultMismatchMessage(sym.type_spec, known_spec, prefer_length_message) orelse return;
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    const line = if (decl_source.line == 0) 1 else decl_source.line;
    const column = if (decl_source.column == 0) 1 else decl_source.column;
    if (procedure_interfaces.findVisibleProcedureSource(self, sym.name)) |known_source| {
        const related = [_]common_diag.DiagnosticSpan{
            declSourceToSecondarySpan(known_source, "visible known function here"),
        };
        self.setDiagnosticStructured(
            line,
            column,
            catalog.semantic.invalid_argument_count.code,
            message,
            decl_source.text,
            "function result declaration conflicts here",
            &.{.{ .text = "The local declaration disagrees with the visible known function result type." }},
            &.{.{ .text = "Make the function result declaration match the visible function definition or interface." }},
            related[0..],
        );
    } else {
        self.setDiagnosticDetailed(
            line,
            column,
            catalog.semantic.invalid_argument_count.code,
            message,
            decl_source.text,
            &.{.{ .text = "The local declaration disagrees with the visible known function result type." }},
            &.{.{ .text = "Make the function result declaration match the visible function definition or interface." }},
        );
    }
    return error.InvalidArgumentCount;
}

fn functionResultMismatchMessage(
    declared: symbols.TypeSpec,
    known: symbols.TypeSpec,
    prefer_length_message: bool,
) ?[]const u8 {
    if (declared.lowered_kind == .character and known.lowered_kind == .character) {
        if (declared.char_len_kind != .constant and known.char_len_kind != .constant) return null;
        if (declared.char_len_kind != known.char_len_kind or declared.char_len != known.char_len) {
            return if (prefer_length_message) "Character length mismatch" else "Character length mismatch in function result";
        }
    }
    if (declared.lowered_kind != known.lowered_kind) return "Return type mismatch of function";
    if (!compatibleKindValue(declared.kind_value, known.kind_value)) return "Return type mismatch of function";
    if (declared.polymorphic != known.polymorphic) return "Return type mismatch of function";
    if (declared.assumed_type != known.assumed_type) return "Return type mismatch of function";
    if (declared.lowered_kind == .derived) {
        const declared_name = declared.derived_type_name orelse return "Return type mismatch of function";
        const known_name = known.derived_type_name orelse return "Return type mismatch of function";
        if (!std.ascii.eqlIgnoreCase(declared_name, known_name)) return "Return type mismatch of function";
    }
    return null;
}

fn compatibleKindValue(a: ?i64, b: ?i64) bool {
    if (a == null or b == null) return true;
    return a == b;
}

fn allowsDeferredCharacterLength(self: *context.Context, sym: symbols.Symbol) bool {
    if (sym.storage == .dummy) return true;
    if (sym.kind == .function) return true;
    if (self.unit.kind == .function) {
        const result_name = self.unit.result_name orelse self.unit.name;
        if (std.ascii.eqlIgnoreCase(sym.name, result_name)) return true;
    }
    if (sym.is_allocatable) return true;
    if (sym.is_pointer) return true;
    return false;
}

fn allowsNonConstantCharacterLengthExpr(self: *context.Context, sym: symbols.Symbol) bool {
    if (allowsDeferredCharacterLength(self, sym)) return true;
    if (sym.storage != .local) return false;
    return self.unit.kind == .subroutine or self.unit.kind == .function;
}

const ResolvedProcedureDecl = struct {
    type_spec: symbols.TypeSpec,
    explicit_type: bool,
    kind: ?symbols.SymbolKind = null,
    sig: ?context.Context.ProcedureSig = null,
    interface_name: ?[]const u8 = null,
};

fn resolveProcedureDeclarator(
    self: *context.Context,
    procedure_interface: ast.ProcedureInterface,
    item_name: []const u8,
) !ResolvedProcedureDecl {
    return switch (procedure_interface) {
        .none => .{
            .type_spec = symbols_mod.implicitTypeSpec(self, item_name),
            .explicit_type = false,
        },
        .name => |name| blk: {
            if (symbols_mod.lookupKnownProcedureSig(self, name)) |sig| {
                const kind: symbols.SymbolKind = switch (sig.kind) {
                    .module => .variable,
                    .function => .function,
                    .subroutine => .subroutine,
                    else => .variable,
                };
                const type_spec = if (sig.kind == .function)
                    symbols_mod.lookupKnownFunctionResolvedSpec(self, name) orelse symbols_mod.implicitTypeSpec(self, item_name)
                else
                    symbols_mod.implicitTypeSpec(self, item_name);
                break :blk .{
                    .type_spec = type_spec,
                    .explicit_type = sig.kind == .function,
                    .kind = kind,
                    .sig = sig,
                    .interface_name = name,
                };
            }
            break :blk .{
                .type_spec = symbols_mod.implicitTypeSpec(self, item_name),
                .explicit_type = false,
                .interface_name = name,
            };
        },
        .type_spec => |type_spec| .{
            .type_spec = try resolvedDeclTypeSpec(
                self,
                type_spec.type_kind,
                type_spec.derived_type_name,
                type_spec.kind_selector,
                type_spec.polymorphic,
                type_spec.assumed_type,
            ),
            .explicit_type = true,
            .kind = .function,
        },
    };
}

pub fn resolvedDeclTypeSpec(
    self: *context.Context,
    base_type_kind: ast.TypeKind,
    derived_type_name: ?[]const u8,
    kind_selector: ?*ast.Expr,
    polymorphic: bool,
    assumed_type: bool,
) !symbols.TypeSpec {
    if (base_type_kind == .derived) {
        const name = derived_type_name orelse {
            if (polymorphic) return symbols.TypeSpec.fromKind(.derived).withPolymorphic(true);
            if (assumed_type) return symbols.TypeSpec.fromKind(.derived).withAssumedType(true);
            return error.UnexpectedTypeDecl;
        };
        if (!symbols_mod.hasDerivedType(self, name)) {
            const current_source = self.current_decl_source orelse ast.DeclSource{};
            self.setDiagnostic(
                if (current_source.line == 0) 1 else current_source.line,
                if (current_source.column == 0) 1 else current_source.column,
                catalog.semantic.unexpected_type_decl.code,
                "is being used before it is defined",
                current_source.text,
            );
            return error.UnexpectedTypeDecl;
        }
        return symbols.TypeSpec.fromDerived(name);
    }
    if (kind_selector == null) return symbols.TypeSpec.fromResolvedKind(base_type_kind, base_type_kind, null);
    switch (kind_selector.?.*) {
        .call_or_subscript => |call| {
            if (!symbols_mod.isIntrinsicName(call.name) and procedure_interfaces.hasVisibleProcedureReference(self, call.name)) {
                const current_source = self.current_decl_source orelse ast.DeclSource{};
                if (procedure_interfaces.findVisibleProcedureSource(self, call.name)) |proc_source| {
                    const related = [_]common_diag.DiagnosticSpan{
                        declSourceToSecondarySpan(proc_source, "visible procedure selected here"),
                    };
                    self.setDiagnosticStructured(
                        if (current_source.line == 0) 1 else current_source.line,
                        if (current_source.column == 0) 1 else current_source.column,
                        catalog.semantic.unexpected_type_decl.code,
                        "must be an intrinsic",
                        current_source.text,
                        "invalid kind selector here",
                        &.{.{ .text = "Type kind selectors that look like procedure references must resolve to intrinsic kind selector procedures." }},
                        &.{.{ .text = "Use an intrinsic kind selector or replace this procedure reference with a constant kind value." }},
                        related[0..],
                    );
                } else {
                    self.setDiagnosticDetailed(
                        if (current_source.line == 0) 1 else current_source.line,
                        if (current_source.column == 0) 1 else current_source.column,
                        catalog.semantic.unexpected_type_decl.code,
                        "must be an intrinsic",
                        current_source.text,
                        &.{.{ .text = "Type kind selectors that look like procedure references must resolve to intrinsic kind selector procedures." }},
                        &.{.{ .text = "Use an intrinsic kind selector or replace this procedure reference with a constant kind value." }},
                    );
                }
                return error.UnexpectedTypeDecl;
            }
        },
        else => {},
    }
    const selector_value = try constants.evalConst(self, kind_selector.?);
    const resolved_spec = type_kind_selector.resolveSpecWithConst(base_type_kind, kind_selector, selector_value);
    try validateResolvedTypeKindSelector(self, base_type_kind, resolved_spec);
    return resolved_spec;
}

fn validateResolvedTypeKindSelector(
    self: *context.Context,
    base_type_kind: ast.TypeKind,
    resolved_spec: symbols.TypeSpec,
) !void {
    if (base_type_kind != .character) return;
    const kind_value = resolved_spec.kind_value orelse return;
    if (kind_value == 1 or kind_value == 4) return;
    const current_source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnostic(
        if (current_source.line == 0) 1 else current_source.line,
        if (current_source.column == 0) 1 else current_source.column,
        catalog.semantic.unexpected_type_decl.code,
        "is not supported for CHARACTER",
        current_source.text,
    );
    return error.UnexpectedTypeDecl;
}
