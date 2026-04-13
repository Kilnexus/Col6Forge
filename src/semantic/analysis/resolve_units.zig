const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const common_diag = @import("../../common/diagnostic.zig");
const catalog = @import("../../common/error_catalog.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");
const decls = @import("resolve_decls.zig");
const decl_diag = @import("resolve_decls_diag_helpers.zig");
const specs = @import("resolve_specs/mod.zig");
const statements = @import("resolve_statements.zig");
const symbols_mod = @import("resolve_symbols.zig");
const rewrite_calls = @import("rewrite_calls.zig");
const resolve_data = @import("resolve_data.zig");
const constants = @import("resolve_const.zig");
const scope = @import("../scope.zig");
const evaluator = @import("../evaluator.zig");

pub const Resolver = struct {
    ctx: *context.Context,
    initial_implicit: []const symbols.ImplicitRule,

    pub fn init(ctx: *context.Context, initial_implicit: []const symbols.ImplicitRule) Resolver {
        return .{
            .ctx = ctx,
            .initial_implicit = initial_implicit,
        };
    }

    pub fn run(self: *Resolver) !void {
        const ctx = self.ctx;
        var first_stmt_error: ?anyerror = null;
        try ctx.initScopeTree();
        _ = try ctx.pushScopeWithOwner(unitScopeKind(ctx.unit.kind), ctx.unit.name, ctx.unit.kind);
        try symbols_mod.initImplicitDefaults(ctx);
        try symbols_mod.installBuiltinConstants(ctx);
        for (self.initial_implicit) |rule| {
            try ctx.implicit.append(rule);
        }
        try symbols_mod.installUnitSymbol(ctx);
        try symbols_mod.installDummyArgs(ctx);
        emitHostDummyNameConflictDiagnostic(ctx);
        try statements.preinstallUseImports(ctx);
        for (ctx.unit.decls, 0..) |decl, decl_idx| {
            if (shouldSkipMirroredHostDecl(ctx, decl, decl_idx)) continue;
            if (decl == .derived_type_def) {
                const decl_source = if (decl_idx < ctx.unit.decl_sources.len) ctx.unit.decl_sources[decl_idx] else ast.DeclSource{};
                ctx.setCurrentDeclSource(decl_source);
                try symbols_mod.registerDerivedType(ctx, .{
                    .name = decl.derived_type_def.name,
                    .source = decl_source,
                    .parent_name = decl.derived_type_def.parent_name,
                    .abstract = decl.derived_type_def.abstract,
                    .sequence = decl.derived_type_def.sequence,
                    .bind_c = decl.derived_type_def.bind_c,
                    .components = try buildDerivedComponentInfo(ctx, decl.derived_type_def),
                    .bindings = try buildDerivedBindingInfo(ctx, decl.derived_type_def, decl_source),
                });
                ctx.setCurrentDeclSource(null);
            }
        }
        maybeEmitImplicitFunctionResultDiagnostic(ctx);
        if (ctx.unit.decl_sources.len != 0) {
            std.debug.assert(ctx.unit.decl_sources.len == ctx.unit.decls.len);
        }
        for (ctx.unit.decls, 0..) |decl, decl_idx| {
            ctx.setCurrentDeclIndex(decl_idx);
            if (decl_idx < ctx.unit.decl_sources.len) {
                ctx.setCurrentDeclSource(ctx.unit.decl_sources[decl_idx]);
            } else {
                ctx.setCurrentDeclSource(null);
            }
            if (shouldSkipMirroredHostDecl(ctx, decl, decl_idx)) {
                ctx.setCurrentDeclSource(null);
                ctx.setCurrentDeclIndex(null);
                continue;
            }
            switch (decl) {
                .type_decl => |type_decl| {
                    decls.applyTypeDecl(ctx, type_decl) catch |err| {
                        maybeSetFunctionTypeDeclDiagnostic(ctx, type_decl, err);
                        if (!ctx.usesExplicitDiagnosticBag()) return err;
                        if (first_stmt_error == null) first_stmt_error = err;
                        if (!hasCustomCurrentDiagnostic(ctx)) ctx.recordSemanticError(err);
                        continue;
                    };
                    specs.applyTypeDeclParameter(ctx, type_decl) catch |err| {
                        if (!ctx.usesExplicitDiagnosticBag()) return err;
                        if (first_stmt_error == null) first_stmt_error = err;
                        if (!hasCustomCurrentDiagnostic(ctx)) ctx.recordSemanticError(err);
                    };
                },
                .procedure => |procedure_decl| decls.applyProcedureDecl(ctx, procedure_decl) catch |err| {
                    if (!ctx.usesExplicitDiagnosticBag()) return err;
                    if (first_stmt_error == null) first_stmt_error = err;
                    ctx.recordSemanticError(err);
                },
                .derived_type_def => specs.applySpec(ctx, decl) catch |err| {
                    if (!ctx.usesExplicitDiagnosticBag()) return err;
                    if (first_stmt_error == null) first_stmt_error = err;
                    if (!hasCustomCurrentDiagnostic(ctx)) ctx.recordSemanticError(err);
                },
                else => specs.applySpec(ctx, decl) catch |err| {
                    if (!ctx.usesExplicitDiagnosticBag()) return err;
                    if (first_stmt_error == null) first_stmt_error = err;
                    ctx.recordSemanticError(err);
                },
            }
            ctx.setCurrentDeclSource(null);
            ctx.setCurrentDeclIndex(null);
        }
        if (ctx.unit.owner_name != null) {
            if (findExplicitInterfaceDeclSource(ctx, ctx.unit.name)) |decl_source| {
                const allow_module_match = ctx.unit.owner_kind == .module and ctx.unit.is_module_procedure;
                if (!allow_module_match) {
                    ctx.setCurrentDeclSource(decl_source);
                    const has_custom_diag = ctx.unit.owner_kind == .module and !ctx.unit.is_module_procedure;
                    if (ctx.unit.owner_kind == .module and !ctx.unit.is_module_procedure) {
                        ctx.setDiagnosticStructured(
                            if (decl_source.line == 0) 1 else decl_source.line,
                            if (decl_source.column == 0) 1 else decl_source.column,
                            catalog.semantic.has_explicit_interface.code,
                            "procedure defined in interface body; PROCEDURE attribute conflicts with PROCEDURE attribute",
                            decl_source.text,
                            "explicit interface definition conflicts here",
                            &.{
                                .{ .text = "(1) explicit interface definition is here" },
                                .{ .text = "A procedure body nested in an INTERFACE block already provides the explicit interface for that name." },
                            },
                            &.{.{ .text = "Remove the separate PROCEDURE-style declaration or move the implementation out of the INTERFACE body." }},
                            &.{},
                        );
                    }
                    if (!ctx.usesExplicitDiagnosticBag()) return error.HasExplicitInterface;
                    if (first_stmt_error == null) first_stmt_error = error.HasExplicitInterface;
                    if (!has_custom_diag) {
                        ctx.recordSemanticError(error.HasExplicitInterface);
                    }
                    ctx.setCurrentDeclSource(null);
                }
            }
        }
        try validateAssumedCharacterLengths(ctx);
        try resolve_data.lowerDataStatements(ctx);
        // First pass resolves statement-level symbol/shape ambiguity (e.g. statement
        // function disambiguation) before intrinsic-array conversion lowering.
        for (ctx.unit.stmts) |stmt| {
            statements.resolveStmt(ctx, stmt) catch |err| {
                if (!ctx.usesExplicitDiagnosticBag()) return err;
                if (first_stmt_error == null) first_stmt_error = err;
                ctx.recordSemanticError(err);
                continue;
            };
        }
        // Intrinsic array-conversion lowering is mandatory for currently supported
        // backend forms. Unsupported shapes must remain fatal here.
        if (first_stmt_error == null) {
            try rewrite_calls.lowerLegacyDialectLoops(ctx);
            try rewrite_calls.lowerIntrinsicArrayConversions(ctx);

            // Re-resolve rewritten statements and refresh reference/type caches against
            // the final lowered AST.
            clearStmtResolutionCaches(ctx);
            for (ctx.unit.stmts) |stmt| {
                statements.resolveStmt(ctx, stmt) catch |err| {
                    if (!ctx.usesExplicitDiagnosticBag()) return err;
                    if (first_stmt_error == null) first_stmt_error = err;
                    ctx.recordSemanticError(err);
                    continue;
                };
            }
        }
        if (first_stmt_error) |err| return err;
        ctx.popScope();
    }
};

fn shouldSkipMirroredHostDecl(ctx: *context.Context, decl: ast.Decl, decl_idx: usize) bool {
    if (ctx.unit.owner_name == null) return false;
    if (decl_idx >= ctx.unit.prelude_decl_count) return false;
    return switch (decl) {
        .type_decl, .parameter => true,
        .derived_type_def => |derived| symbols_mod.hasKnownHostDerivedType(ctx, derived.name),
        else => false,
    };
}

fn unitScopeKind(kind: ast.ProgramUnitKind) scope.ScopeKind {
    return switch (kind) {
        .module => .module,
        .program, .function, .subroutine, .block_data => .procedure,
    };
}

fn validateAssumedCharacterLengths(ctx: *context.Context) !void {
    for (ctx.symbols.items) |sym| {
        if (!sym.isCharacter()) continue;
        if (sym.effectiveCharLenKind() != .assumed) continue;
        if (sym.storage == .dummy) continue;
        if (sym.kind == .parameter) continue;
        if (sym.kind == .function) {
            if (invalidAssumedCharacterResultOwner(ctx)) |owner_role| {
                if (findTypeDeclSource(ctx, sym.name)) |decl_source| {
                    ctx.setCurrentDeclSource(decl_source);
                    ctx.setDiagnosticDetailed(
                        if (decl_source.line == 0) 1 else decl_source.line,
                        if (decl_source.column == 0) 1 else decl_source.column,
                        catalog.semantic.invalid_char_len.code,
                        try std.fmt.allocPrint(ctx.arena, "assumed character length is not valid for a {s} result", .{owner_role}),
                        decl_source.text,
                        &.{.{ .text = "Only external CHARACTER function results may use assumed length in this form." }},
                        &.{.{ .text = "Declare a constant CHARACTER length for the contained procedure result, or move the function out as an external procedure." }},
                    );
                }
                return error.InvalidCharLen;
            }
            continue;
        }
        if (findTypeDeclSource(ctx, sym.name)) |decl_source| {
            ctx.setCurrentDeclSource(decl_source);
            ctx.setDiagnosticDetailed(
                if (decl_source.line == 0) 1 else decl_source.line,
                if (decl_source.column == 0) 1 else decl_source.column,
                catalog.semantic.invalid_char_len.code,
                "assumed character length is only valid for dummy arguments or function results",
                decl_source.text,
                &.{.{ .text = "An assumed CHARACTER length declaration outside a dummy argument or function result is not semantically valid." }},
                &.{.{ .text = "Use a constant CHARACTER length, or make the entity a dummy argument, POINTER, ALLOCATABLE, or function result." }},
            );
        } else {
            ctx.setCurrentDeclSource(findTypeDeclSource(ctx, sym.name));
        }
        return error.InvalidCharLen;
    }
}

fn invalidAssumedCharacterResultOwner(ctx: *context.Context) ?[]const u8 {
    const owner_kind = ctx.unit.owner_kind orelse return null;
    return switch (owner_kind) {
        .module => "module procedure",
        .procedure => "internal function",
    };
}

fn findTypeDeclSource(ctx: *context.Context, target_name: []const u8) ?ast.DeclSource {
    for (ctx.unit.decls, 0..) |decl, decl_idx| {
        if (decl != .type_decl) continue;
        const type_decl = decl.type_decl;
        for (type_decl.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, target_name)) continue;
            if (decl_idx < ctx.unit.decl_sources.len) {
                return ctx.unit.decl_sources[decl_idx];
            }
            return null;
        }
    }
    return null;
}

fn findExplicitInterfaceDeclSource(ctx: *context.Context, target_name: []const u8) ?ast.DeclSource {
    for (ctx.unit.decls, 0..) |decl, decl_idx| {
        if (decl != .interface_block) continue;
        for (decl.interface_block.procedures) |procedure_name| {
            if (!std.ascii.eqlIgnoreCase(procedure_name, target_name)) continue;
            if (decl_idx < ctx.unit.decl_sources.len) return ctx.unit.decl_sources[decl_idx];
            return null;
        }
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (!std.ascii.eqlIgnoreCase(proc_header.name, target_name)) continue;
            if (decl_idx < ctx.unit.decl_sources.len) return ctx.unit.decl_sources[decl_idx];
            return null;
        }
    }
    var it = ctx.known_host_interface_sources.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, target_name)) return entry.value_ptr.*;
    }
    return null;
}

fn clearStmtResolutionCaches(ctx: *context.Context) void {
    ctx.refs.clearRetainingCapacity();
    ctx.ref_kind_index.clearRetainingCapacity();
    ctx.ref_symbol_index.clearRetainingCapacity();
    ctx.expr_type_cache.clearRetainingCapacity();
    ctx.expr_type_spec_cache.clearRetainingCapacity();
}

fn maybeSetFunctionTypeDeclDiagnostic(ctx: *context.Context, type_decl: ast.TypeDecl, err: anyerror) void {
    if (err != error.UnexpectedTypeDecl) return;
    if (ctx.unit.kind != .function) return;
    const result_name = ctx.unit.result_name orelse ctx.unit.name;
    for (type_decl.items) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
        const decl_source = ctx.current_decl_source orelse return;
        const line = if (decl_source.line == 0) 1 else decl_source.line;
        const column = if (decl_source.column == 0) 1 else decl_source.column;
        const related_source = findExplicitInterfaceDeclSource(ctx, ctx.unit.name);
        if (related_source) |source| {
            const related = [_]common_diag.DiagnosticSpan{.{
                .file_path = "",
                .line = if (source.line == 0) 1 else source.line,
                .column = if (source.column == 0) 1 else source.column,
                .end_column = @max((if (source.column == 0) 1 else source.column) + 1, source.text.len + 1),
                .line_text = source.text,
                .label = "visible explicit interface here",
            }};
            ctx.setDiagnosticStructured(
                line,
                column,
                catalog.semantic.unexpected_type_decl.code,
                "invalid type for function result",
                decl_source.text,
                "function result declaration conflicts here",
                &.{
                    .{ .text = "The local function result declaration does not match the visible explicit interface." },
                    .{ .text = "Type mismatch" },
                },
                &.{.{ .text = "Make the function result declaration agree with the explicit interface, or remove the conflicting declaration." }},
                related[0..],
            );
        } else {
            ctx.setDiagnosticDetailed(
                line,
                column,
                catalog.semantic.unexpected_type_decl.code,
                "invalid type for function result",
                decl_source.text,
                &.{
                    .{ .text = "The local function result declaration does not match the visible explicit interface." },
                    .{ .text = "Type mismatch" },
                },
                &.{.{ .text = "Make the function result declaration agree with the explicit interface, or remove the conflicting declaration." }},
            );
        }
        return;
    }
}

fn hasCustomCurrentDiagnostic(ctx: *context.Context) bool {
    if (!ctx.usesExplicitDiagnosticBag()) return ctx.hasDiagnostic();
    if (ctx.current_decl_source) |decl_source| {
        if (ctx.diag_bag) |bag| {
            const diag_entry = bag.latest() orelse return false;
            return diag_entry.line == (if (decl_source.line == 0) 1 else decl_source.line) and
                diag_entry.column == (if (decl_source.column == 0) 1 else decl_source.column);
        }
    }
    return false;
}

fn maybeEmitImplicitFunctionResultDiagnostic(ctx: *context.Context) void {
    if (ctx.unit.kind != .function) return;
    if (!unitHasImplicitNone(ctx)) return;
    if (functionHeaderProvidesExplicitResultType(ctx)) return;
    if (!unitDeclaresUnknownDerivedType(ctx)) return;
    decl_diag.emitCurrentFunctionNoImplicitDiagnostic(ctx);
}

fn unitHasImplicitNone(ctx: *const context.Context) bool {
    for (ctx.unit.decls) |decl| {
        if (decl != .implicit) continue;
        if (decl.implicit.rules.len == 0) return true;
    }
    return false;
}

fn functionHeaderProvidesExplicitResultType(ctx: *const context.Context) bool {
    const result_name = ctx.unit.result_name orelse ctx.unit.name;
    for (ctx.unit.decls, 0..) |decl, decl_idx| {
        if (decl_idx >= ctx.unit.decl_sources.len) continue;
        const decl_source = ctx.unit.decl_sources[decl_idx];
        if (std.ascii.indexOfIgnoreCase(decl_source.text, "function") == null) continue;
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, result_name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn unitDeclaresUnknownDerivedType(ctx: *const context.Context) bool {
    for (ctx.unit.decls) |decl| {
        if (decl != .type_decl) continue;
        const type_decl = decl.type_decl;
        if (type_decl.type_kind != .derived or type_decl.polymorphic or type_decl.assumed_type) continue;
        const derived_name = type_decl.derived_type_name orelse continue;
        if (!symbols_mod.hasDerivedType(ctx, derived_name)) return true;
    }
    return false;
}

fn emitHostDummyNameConflictDiagnostic(ctx: *context.Context) void {
    if (ctx.unit.owner_name == null) return;
    if (symbols_mod.lookupHostAssociatedParameter(ctx, ctx.unit.name)) |host_sym| {
        if (host_sym.storage != .dummy) return;
        const source_line = if (ctx.unit.stmts.len > 0 and ctx.unit.stmts[0].source_line != 0) ctx.unit.stmts[0].source_line else 1;
        const source_col = if (ctx.unit.stmts.len > 0 and ctx.unit.stmts[0].source_column != 0) ctx.unit.stmts[0].source_column else 1;
        const source_text = if (ctx.unit.stmts.len > 0) ctx.unit.stmts[0].source_text else "";
        ctx.setDiagnostic(
            source_line,
            source_col,
            catalog.semantic.duplicate_declaration.code,
            "conflicts with DUMMY argument",
            source_text,
        );
    }
}

fn buildDerivedComponentInfo(
    ctx: *context.Context,
    derived: ast.DerivedTypeDef,
) ![]const context.Context.DerivedTypeInfo.ComponentInfo {
    var components = std.array_list.Managed(context.Context.DerivedTypeInfo.ComponentInfo).init(ctx.arena);
    const prior_decl_source = ctx.current_decl_source;
    for (derived.components, 0..) |type_decl, component_idx| {
        const component_source = if (derived.component_sources.len > 0 and component_idx < derived.component_sources.len)
            derived.component_sources[component_idx]
        else
            ctx.current_decl_source;
        ctx.setCurrentDeclSource(component_source);
        for (type_decl.items) |item| {
            try decls.validateDeclaratorInitializer(ctx, item.init);
            var spec = symbols.TypeSpec.fromResolvedKind(type_decl.type_kind, type_decl.type_kind, null);
            if (type_decl.type_kind == .derived) {
                if (type_decl.derived_type_name) |name| {
                    spec = symbols.TypeSpec.fromDerived(name);
                } else if (type_decl.polymorphic) {
                    spec = symbols.TypeSpec.fromKind(.derived).withPolymorphic(true);
                } else {
                    return error.UnexpectedTypeDecl;
                }
            }
            spec = spec.withPolymorphic(type_decl.polymorphic);
            if (spec.lowered_kind == .character) {
                if (item.char_len_deferred) {
                    spec = spec.withCharacterLength(.deferred, null);
                } else if (item.char_len != null) {
                    const length = try resolveDerivedCharacterComponentLen(ctx, item.char_len.?);
                    spec = spec.withCharacterLength(.constant, length);
                } else {
                    spec = spec.withCharacterLength(.constant, 1);
                }
            }
            try components.append(.{
                .name = item.name,
                .source = component_source orelse ast.DeclSource{},
                .type_spec = spec,
                .dims = item.dims,
                .pointer = type_decl.pointer,
                .allocatable = type_decl.allocatable,
            });
        }
        ctx.setCurrentDeclSource(prior_decl_source);
    }
    for (derived.procedure_components, 0..) |procedure_decl, component_idx| {
        const component_source = if (derived.procedure_component_sources.len > 0 and component_idx < derived.procedure_component_sources.len)
            derived.procedure_component_sources[component_idx]
        else
            ctx.current_decl_source;
        ctx.setCurrentDeclSource(component_source);
        for (procedure_decl.items) |item| {
            const sig = try resolveDerivedProcedureComponentSig(ctx, derived.name, procedure_decl);
            const spec = try resolveDerivedProcedureComponentTypeSpec(ctx, derived.name, procedure_decl, item.name, sig);
            try components.append(.{
                .name = item.name,
                .type_spec = spec,
                .dims = &.{},
                .pointer = procedure_decl.pointer,
                .allocatable = false,
                .procedure = true,
                .procedure_sig = sig,
                .procedure_kind = derivedProcedureComponentKind(ctx, procedure_decl, sig),
                .procedure_has_explicit_interface = derivedProcedureComponentHasExplicitInterface(procedure_decl, sig),
                .procedure_nopass = procedure_decl.nopass,
                .procedure_pass_name = procedure_decl.pass_name,
                .interface_name = switch (procedure_decl.interface) {
                    .name => |interface_name| interface_name,
                    else => null,
                },
            });
        }
        ctx.setCurrentDeclSource(prior_decl_source);
    }
    return try components.toOwnedSlice();
}

fn resolveDerivedProcedureComponentSig(
    ctx: *context.Context,
    enclosing_derived_name: []const u8,
    procedure_decl: ast.ProcedureDecl,
) !?context.Context.ProcedureSig {
    return switch (procedure_decl.interface) {
        .none => null,
        .name => |interface_name| symbols_mod.lookupKnownProcedureSig(ctx, interface_name),
        .type_spec => |type_spec| .{
            .kind = .function,
            .arg_count = 0,
            .args = &.{},
            .result_type_spec = try resolveDerivedProcedureTypeSpec(ctx, enclosing_derived_name, type_spec),
        },
    };
}

fn resolveDerivedProcedureComponentTypeSpec(
    ctx: *context.Context,
    enclosing_derived_name: []const u8,
    procedure_decl: ast.ProcedureDecl,
    item_name: []const u8,
    sig: ?context.Context.ProcedureSig,
) !symbols.TypeSpec {
    if (sig) |resolved_sig| {
        if (resolved_sig.result_type_spec) |result_spec| return result_spec;
    }
    return switch (procedure_decl.interface) {
        .type_spec => |type_spec| try resolveDerivedProcedureTypeSpec(ctx, enclosing_derived_name, type_spec),
        else => symbols_mod.implicitTypeSpec(ctx, item_name),
    };
}

fn resolveDerivedProcedureTypeSpec(
    ctx: *context.Context,
    enclosing_derived_name: []const u8,
    type_spec: ast.ProcedureTypeSpec,
) !symbols.TypeSpec {
    if (type_spec.type_kind == .derived) {
        if (type_spec.derived_type_name) |derived_name| {
            if (std.ascii.eqlIgnoreCase(derived_name, enclosing_derived_name)) {
                return symbols.TypeSpec.fromDerived(enclosing_derived_name).withPolymorphic(type_spec.polymorphic).withAssumedType(type_spec.assumed_type);
            }
        }
    }
    return decls.resolvedDeclTypeSpec(
        ctx,
        type_spec.type_kind,
        type_spec.derived_type_name,
        type_spec.kind_selector,
        type_spec.polymorphic,
        type_spec.assumed_type,
    );
}

fn derivedProcedureComponentKind(
    ctx: *context.Context,
    procedure_decl: ast.ProcedureDecl,
    sig: ?context.Context.ProcedureSig,
) ?ast.ProgramUnitKind {
    if (sig) |resolved_sig| return resolved_sig.kind;
    return switch (procedure_decl.interface) {
        .type_spec => .function,
        .none => .subroutine,
        .name => |interface_name| if (symbols_mod.lookupKnownFunctionTypeSpec(ctx, interface_name) != null) .function else .subroutine,
    };
}

fn derivedProcedureComponentHasExplicitInterface(
    procedure_decl: ast.ProcedureDecl,
    sig: ?context.Context.ProcedureSig,
) bool {
    return switch (procedure_decl.interface) {
        .name => sig != null,
        else => false,
    };
}

fn resolveDerivedCharacterComponentLen(ctx: *context.Context, expr: *ast.Expr) !usize {
    if (expr.* == .literal and expr.literal.kind == .assumed_size) {
        return error.InvalidCharLen;
    }
    if (try evalDerivedComponentConst(ctx, expr)) |value| {
        return switch (value) {
            .integer => |int_val| blk: {
                if (int_val < 0) break :blk error.InvalidCharLen;
                break :blk @as(usize, @intCast(int_val));
            },
            else => error.InvalidCharLen,
        };
    }
    emitDerivedComponentSpecExprDiagnostic(ctx);
    return error.InvalidCharLen;
}

fn evalDerivedComponentConst(ctx: *context.Context, expr: *ast.Expr) !?symbols.ConstValue {
    if (try constants.evalConst(ctx, expr)) |value| return value;
    const resolver = evaluator.ConstResolver{
        .ctx = @ptrCast(ctx),
        .resolveFn = resolveDerivedComponentConstValue,
        .allocator = ctx.arena,
        .internStringFn = internDerivedComponentConstString,
        .arrayExtentFn = resolveDerivedComponentArrayExtent,
        .arrayLowerBoundFn = resolveDerivedComponentArrayLowerBound,
    };
    return evaluator.evalConst(expr, resolver);
}

fn resolveDerivedComponentConstValue(raw_ctx: *anyopaque, name: []const u8) ?symbols.ConstValue {
    const ctx: *context.Context = @ptrCast(@alignCast(raw_ctx));
    if (symbols_mod.findSymbolIndex(ctx, name)) |idx| {
        if (ctx.symbols.items[idx].const_value) |value| return value;
    }
    if (lookupUnitParameterInitializer(ctx, name)) |init_expr| {
        return evalDerivedComponentConst(ctx, init_expr) catch null;
    }
    if (symbols_mod.findBuiltinConstant(ctx, name)) |builtin| return builtin.value;
    return null;
}

fn internDerivedComponentConstString(raw_ctx: *anyopaque, text: []const u8) anyerror![]const u8 {
    const ctx: *context.Context = @ptrCast(@alignCast(raw_ctx));
    return ctx.internConstString(text);
}

fn resolveDerivedComponentArrayExtent(raw_ctx: *anyopaque, name: []const u8, dim: ?usize) ?i64 {
    const ctx: *context.Context = @ptrCast(@alignCast(raw_ctx));
    const idx = symbols_mod.findSymbolIndex(ctx, name) orelse return null;
    const sym = ctx.symbols.items[idx];
    if (sym.dims.len == 0) return null;
    if (dim) |requested_dim| {
        if (requested_dim == 0 or requested_dim > sym.dims.len) return null;
        return evalDerivedComponentDimExtent(ctx, sym.dims[requested_dim - 1]);
    }
    var total: i64 = 1;
    for (sym.dims) |dim_expr| {
        const extent = evalDerivedComponentDimExtent(ctx, dim_expr) orelse return null;
        total = std.math.mul(i64, total, extent) catch return null;
    }
    return total;
}

fn resolveDerivedComponentArrayLowerBound(raw_ctx: *anyopaque, name: []const u8, dim: usize) ?i64 {
    const ctx: *context.Context = @ptrCast(@alignCast(raw_ctx));
    if (dim == 0) return null;
    const idx = symbols_mod.findSymbolIndex(ctx, name) orelse return null;
    const sym = ctx.symbols.items[idx];
    if (sym.dims.len == 0 or dim > sym.dims.len) return null;
    return evalDerivedComponentDimLower(ctx, sym.dims[dim - 1]);
}

fn evalDerivedComponentDimExtent(ctx: *context.Context, expr: *ast.Expr) ?i64 {
    return switch (expr.*) {
        .dim_range => |range| blk: {
            if (range.stride != null) break :blk null;
            const upper_val = evalDerivedComponentConstInt(ctx, range.upper) orelse break :blk null;
            const lower_val = if (range.lower) |lower_expr| evalDerivedComponentConstInt(ctx, lower_expr) orelse break :blk null else 1;
            if (upper_val < lower_val) break :blk 0;
            const diff = std.math.sub(i64, upper_val, lower_val) catch break :blk null;
            break :blk std.math.add(i64, diff, 1) catch null;
        },
        else => evalDerivedComponentConstInt(ctx, expr),
    };
}

fn evalDerivedComponentDimLower(ctx: *context.Context, expr: *ast.Expr) ?i64 {
    return switch (expr.*) {
        .dim_range => |range| if (range.lower) |lower_expr| evalDerivedComponentConstInt(ctx, lower_expr) else 1,
        else => 1,
    };
}

fn evalDerivedComponentConstInt(ctx: *context.Context, expr: *ast.Expr) ?i64 {
    const value = evalDerivedComponentConst(ctx, expr) catch return null;
    return switch (value orelse return null) {
        .integer => |v| v,
        else => null,
    };
}

fn lookupUnitParameterInitializer(ctx: *context.Context, target_name: []const u8) ?*ast.Expr {
    for (ctx.unit.decls) |decl| {
        switch (decl) {
            .parameter => |param_decl| {
                for (param_decl.assigns) |assign| {
                    if (std.ascii.eqlIgnoreCase(assign.name, target_name)) return assign.value;
                }
            },
            .type_decl => |type_decl| {
                if (!type_decl.parameter) continue;
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, target_name)) continue;
                    return item.init;
                }
            },
            else => {},
        }
    }
    return null;
}

fn emitDerivedComponentSpecExprDiagnostic(ctx: *context.Context) void {
    const decl_source = ctx.current_decl_source orelse return;
    ctx.setDiagnosticDetailed(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.invalid_char_len.code,
        "non-constant object in the expression; a specification expression is required",
        decl_source.text,
        &.{.{ .text = "Derived type component bounds and lengths must be specification expressions." }},
        &.{.{ .text = "Replace the runtime-dependent expression with a constant or specification expression visible at the type definition." }},
    );
}

fn buildDerivedBindingInfo(
    ctx: *context.Context,
    derived: ast.DerivedTypeDef,
    decl_source: ast.DeclSource,
) ![]const context.Context.DerivedTypeInfo.BindingInfo {
    var bindings = std.array_list.Managed(context.Context.DerivedTypeInfo.BindingInfo).init(ctx.arena);
    const owner_name = decl_source.owner_name orelse if (ctx.unit.kind == .module) ctx.unit.name else ctx.unit.owner_name;
    const owner_kind = bindingOwnerKind(ctx, decl_source);
    for (derived.bindings) |binding| {
        try bindings.append(.{
            .name = binding.name,
            .source = binding.source,
            .owner_name = binding.owner_name orelse owner_name,
            .owner_kind = binding.owner_kind orelse owner_kind,
            .is_generic = binding.is_generic,
            .interface_name = binding.interface_name,
            .implementation_name = binding.implementation_name,
            .deferred = binding.deferred,
            .nopass = binding.nopass,
            .pass_name = binding.pass_name,
            .private = binding.private,
            .non_overridable = binding.non_overridable,
        });
    }
    return try bindings.toOwnedSlice();
}

fn bindingOwnerKind(ctx: *context.Context, decl_source: ast.DeclSource) ?ast.LexicalOwnerKind {
    if (decl_source.owner_name != null) return .module;
    if (ctx.unit.kind == .module) return .module;
    if (ctx.unit.owner_name != null) return .procedure;
    return null;
}
