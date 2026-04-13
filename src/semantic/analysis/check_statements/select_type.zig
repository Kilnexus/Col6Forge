const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const symbols = @import("../../symbol/mod.zig");
const context = @import("../context.zig");
const constants = @import("../resolve_const.zig");
const decls = @import("../resolve_decls.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");
const stmt_queries = @import("../../../common/stmt_queries.zig");
const select_type_char_clause = @import("../select_type_char_clause.zig");
const expr_semantics = @import("expr_semantics.zig");

pub const CheckError = anyerror;

pub fn checkAssociateBlock(self: *context.Context, associate: ast.AssociateBlock, comptime deps: anytype) CheckError!void {
    if (associate.select_rank) |select_rank| {
        try checkSelectRankAssociateBlock(self, associate, select_rank, deps);
    }
    var first_err: ?anyerror = null;
    const binding_ok = try self.arena.alloc(bool, associate.bindings.len);
    for (associate.bindings, 0..) |binding, idx| {
        var ok = true;
        _ = deps.checkExprType(self, binding.selector, .{
            .dummyArgTypeCompatible = deps.dummyArgTypeCompatible,
        }) catch |err| blk: {
            ok = false;
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            self.recordSemanticError(err);
            break :blk .integer;
        };
        if (ok) {
            validateAssociateSelectorTarget(self, binding) catch |err| {
                ok = false;
                if (!self.usesExplicitDiagnosticBag()) return err;
                if (first_err == null) first_err = err;
                self.recordSemanticError(err);
            };
        }
        binding_ok[idx] = ok;
    }
    _ = try self.pushScope(.block);
    defer self.popScope();
    for (associate.bindings, 0..) |binding, idx| {
        const spec = resolve_expr.exprTypeSpec(self, binding.selector) catch |err| blk: {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            self.recordSemanticError(err);
            break :blk symbols.TypeSpec.fromResolvedKind(.integer, .integer, null);
        };
        _ = try resolve_symbols.installAliasSymbol(
            self,
            binding.name,
            spec,
            selectorRankForAssociateAlias(self, binding.selector),
            binding_ok[idx] and associateSelectorMayBeVariable(binding.selector) and expr_semantics.selectorIsDefinableAlias(self, binding.selector),
        );
    }
    for (associate.stmts) |inner| {
        deps.checkStmt(self, inner) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            self.recordSemanticError(err);
        };
    }
    if (first_err) |err| return err;
}

fn checkSelectRankAssociateBlock(
    self: *context.Context,
    associate: ast.AssociateBlock,
    select_rank: ast.SelectRankInfo,
    comptime deps: anytype,
) CheckError!void {
    _ = deps;
    const selector_expr = if (associate.bindings.len != 0) associate.bindings[0].selector else return;
    const selector_source = self.sourceForExpr(selector_expr) orelse ast.SourceRef{};
    const selector_info = selectRankSelectorInfo(self, selector_expr);

    if (!selector_info.assumed_rank) {
        self.setDiagnostic(
            if (selector_source.line == 0) 1 else selector_source.line,
            if (selector_source.column == 0) 1 else selector_source.column,
            catalog.semantic.assignment_type_mismatch.code,
            "must be an assumed rank variable",
            selector_source.text,
        );
        for (select_rank.clauses) |clause| {
            self.setDiagnostic(
                if (clause.source.line == 0) 1 else clause.source.line,
                if (clause.source.column == 0) 1 else clause.source.column,
                catalog.parser.unexpected_token.code,
                "Unexpected RANK statement",
                clause.source.text,
            );
        }
        if (select_rank.end_source.line != 0) {
            self.setDiagnostic(
                select_rank.end_source.line,
                if (select_rank.end_source.column == 0) 1 else select_rank.end_source.column,
                catalog.parser.unexpected_token.code,
                "Expecting END SUBROUTINE statement",
                select_rank.end_source.text,
            );
        }
        return error.AssignmentTypeMismatch;
    }

    if (selector_info.pointer_or_allocatable) {
        self.setDiagnostic(
            if (selector_source.line == 0) 1 else selector_source.line,
            if (selector_source.column == 0) 1 else selector_source.column,
            catalog.semantic.assignment_type_mismatch.code,
            "cannot be used with the pointer or allocatable selector",
            selector_source.text,
        );
    }

    var seen_default = false;
    var seen_star = false;
    var seen_rank = std.AutoHashMap(i64, void).init(self.arena);
    for (select_rank.clauses) |clause| {
        switch (clause.kind) {
            .rank_default => {
                if (seen_default) {
                    emitSelectRankClauseDiagnostic(self, clause.source, "is repeated");
                }
                seen_default = true;
            },
            .rank_star => {
                if (selector_info.pointer_or_allocatable) {
                    emitSelectRankClauseDiagnostic(self, clause.source, "cannot be used with the pointer or allocatable selector");
                }
                if (seen_star) {
                    emitSelectRankClauseDiagnostic(self, clause.source, "is repeated");
                }
                if (associate.bindings.len != 0) {
                    const selector_name = associate.bindings[0].name;
                    for (clause.stmts) |stmt| {
                        if (stmt_queries.stmtUsesWholeSelectorArray(stmt, selector_name)) {
                            emitSelectRankStmtDiagnostic(self, stmt, "assumed-size array");
                        }
                    }
                }
                seen_star = true;
            },
            .rank_value => {
                const rank_expr = clause.rank_expr orelse continue;
                const rank_spec = try resolve_expr.exprTypeSpec(self, rank_expr);
                if (resolve_expr.exprRank(self, rank_expr) != 0) {
                    emitSelectRankClauseDiagnostic(self, clause.source, "must be a scalar");
                    continue;
                }
                if (rank_spec.lowered_kind != .integer) {
                    emitSelectRankClauseDiagnostic(self, clause.source, "must be a scalar");
                    continue;
                }
                const rank_value = (constants.evalConst(self, rank_expr) catch null) orelse {
                    emitSelectRankClauseDiagnostic(self, clause.source, "must be a scalar");
                    continue;
                };
                const rank_int = switch (rank_value) {
                    .integer => |value| value,
                    else => {
                        emitSelectRankClauseDiagnostic(self, clause.source, "must be a scalar");
                        continue;
                    },
                };
                if (rank_int < 0 or rank_int > 15) {
                    emitSelectRankClauseDiagnostic(self, clause.source, "must not be less than zero or greater than 15");
                    continue;
                }
                const gop = seen_rank.getOrPut(rank_int) catch continue;
                if (gop.found_existing) {
                    emitSelectRankClauseDiagnostic(self, clause.source, "is repeated");
                }
            },
        }
    }
}

const SelectRankSelectorInfo = struct {
    assumed_rank: bool = false,
    pointer_or_allocatable: bool = false,
};

fn selectRankSelectorInfo(self: *context.Context, selector: *ast.Expr) SelectRankSelectorInfo {
    const idx = switch (selector.*) {
        .identifier => |name| resolve_symbols.findSymbolIndex(self, name),
        else => null,
    } orelse return .{};
    const sym = self.symbols.items[idx];
    return .{
        .assumed_rank = dimsRepresentAssumedRank(sym.dims),
        .pointer_or_allocatable = sym.is_pointer or sym.is_allocatable,
    };
}

fn dimsRepresentAssumedRank(dims: []const *ast.Expr) bool {
    if (dims.len != 1) return false;
    return switch (dims[0].*) {
        .dim_range => |range| range.from_dotdot,
        else => false,
    };
}

fn emitSelectRankClauseDiagnostic(self: *context.Context, source: ast.SourceRef, message: []const u8) void {
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
    );
}

fn emitSelectRankStmtDiagnostic(self: *context.Context, stmt: ast.Stmt, message: []const u8) void {
    self.setDiagnostic(
        if (stmt.source_line == 0) 1 else stmt.source_line,
        if (stmt.source_column == 0) 1 else stmt.source_column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        stmt.source_text,
    );
}

pub fn checkSelectTypeBlock(self: *context.Context, select_type: ast.SelectTypeBlock, comptime deps: anytype) CheckError!void {
    var first_err: ?anyerror = null;
    const selector_spec = resolve_expr.exprTypeSpec(self, select_type.selector) catch |err| blk: {
        if (!self.usesExplicitDiagnosticBag()) return err;
        first_err = err;
        self.recordSemanticError(err);
        break :blk symbols.TypeSpec.fromResolvedKind(.integer, .integer, null);
    };
    _ = deps.checkExprType(self, select_type.selector, .{
        .dummyArgTypeCompatible = deps.dummyArgTypeCompatible,
    }) catch |err| blk: {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_err == null) first_err = err;
        self.recordSemanticError(err);
        break :blk .integer;
    };
    validateSelectTypeSelector(self, select_type.selector, select_type.associate_name != null, selector_spec) catch |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_err == null) first_err = err;
    };
    const alias_name = selectTypeAliasName(select_type);
    const enforce_alias_definable = shouldEnforceAliasDefinableForSelectType(self, select_type);
    const alias_definable = if (alias_name != null and enforce_alias_definable)
        expr_semantics.selectorIsDefinableAlias(self, select_type.selector)
    else
        true;
    if (alias_name != null and enforce_alias_definable and !alias_definable) {
        emitCurrentStmtVariableDefinitionContext(self);
        if (first_err == null) first_err = error.AssignmentTypeMismatch;
    }
    if (select_type.leading_stmts.len != 0) {
        const stmt = select_type.leading_stmts[0];
        self.setDiagnostic(
            if (stmt.source_line == 0) 1 else stmt.source_line,
            if (stmt.source_column == 0) 1 else stmt.source_column,
            catalog.semantic.assignment_type_mismatch.code,
            "Expected TYPE IS, CLASS IS or END SELECT",
            stmt.source_text,
        );
        if (first_err == null) first_err = error.AssignmentTypeMismatch;
    }
    validateSelectTypeClauses(self, selector_spec, select_type.construct_name, select_type.clauses) catch |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_err == null) first_err = err;
    };
    maybeEmitInvalidSelectTypeRecoveryEndDiagnostic(self, select_type, selector_spec);

    const selector_rank = resolve_expr.exprRank(self, select_type.selector);
    for (select_type.leading_stmts) |inner| {
        deps.checkStmt(self, inner) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            self.recordSemanticError(err);
        };
    }
    for (select_type.clauses) |clause| {
        var alias_spec: ?symbols.TypeSpec = null;
        if (alias_name != null) {
            alias_spec = selectTypeClauseAliasSpec(self, selector_spec, clause) catch |err| blk: {
                if (!self.usesExplicitDiagnosticBag()) return err;
                if (first_err == null) first_err = err;
                break :blk null;
            };
        }
        {
            _ = try self.pushScope(.block);
            defer self.popScope();
            if (alias_name) |name| {
                if (alias_spec) |spec| {
                    _ = try resolve_symbols.installAliasSymbol(self, name, spec, selector_rank, alias_definable);
                }
            }
            for (clause.stmts) |inner| {
                deps.checkStmt(self, inner) catch |err| {
                    if (!self.usesExplicitDiagnosticBag()) return err;
                    if (first_err == null) first_err = err;
                    self.recordSemanticError(err);
                };
            }
        }
    }
    if (first_err) |err| return err;
}

fn maybeEmitInvalidSelectTypeRecoveryEndDiagnostic(
    self: *context.Context,
    select_type: ast.SelectTypeBlock,
    selector_spec: symbols.TypeSpec,
) void {
    if (self.unit.kind != .function) return;
    if (select_type.end_source.line == 0) return;
    if (selector_spec.lowered_kind == .derived and selector_spec.polymorphic) return;
    if (!selectTypeHasInvalidTypedClause(self, select_type.clauses)) return;
    self.setDiagnostic(
        select_type.end_source.line,
        if (select_type.end_source.column == 0) 1 else select_type.end_source.column,
        catalog.parser.unexpected_token.code,
        "Expecting END FUNCTION statement",
        select_type.end_source.text,
    );
}

fn selectTypeHasInvalidTypedClause(
    self: *context.Context,
    clauses: []const ast.SelectTypeClause,
) bool {
    for (clauses) |clause| {
        if (clause.kind == .class_default) continue;
        if (selectTypeClauseIsInvalidForRecovery(self, clause)) return true;
    }
    return false;
}

fn selectTypeClauseIsInvalidForRecovery(
    self: *context.Context,
    clause: ast.SelectTypeClause,
) bool {
    _ = selectTypeClauseResolvedSpec(self, clause, clause.kind == .class_is) catch return true;
    return false;
}

fn associateSelectorMayBeVariable(selector: *ast.Expr) bool {
    return switch (selector.*) {
        .identifier, .component, .substring, .call_or_subscript => true,
        else => false,
    };
}

fn shouldEnforceAliasDefinableForSelectType(
    self: *context.Context,
    select_type: ast.SelectTypeBlock,
) bool {
    if (select_type.associate_name != null) return true;
    return expr_semantics.exprUsesNonDefinableAlias(self, select_type.selector);
}

fn emitCurrentStmtVariableDefinitionContext(self: *context.Context) void {
    const stmt = self.current_stmt orelse return;
    self.setDiagnostic(
        if (stmt.source_line == 0) 1 else stmt.source_line,
        if (stmt.source_column == 0) 1 else stmt.source_column,
        catalog.semantic.assignment_type_mismatch.code,
        "in variable definition context",
        stmt.source_text,
    );
}

fn validateAssociateSelectorTarget(self: *context.Context, binding: ast.AssociateBinding) CheckError!void {
    const selector = binding.selector;
    if (selectorIsNullCall(selector)) {
        return emitAssociateSelectorDiagnostic(self, selector, "cannot be NULL()");
    }
    if (selectorUsesVectorIndex(self, selector)) {
        return emitAssociateSelectorDiagnostic(self, selector, "vector-indexed target");
    }
    if (selectorIsDerivedTypeName(self, selector)) |type_name| {
        const msg = std.fmt.allocPrint(self.arena, "Derived type '{s}' cannot be used as a variable", .{type_name}) catch "Derived type cannot be used as a variable";
        return emitAssociateSelectorDiagnostic(self, selector, msg);
    }
    if (selectorProcedureName(self, selector)) |name| {
        const msg = std.fmt.allocPrint(
            self.arena,
            "Invalid association target; Associating entity '{s}' at (1) is a procedure name; Expected array subscript; Associate-name '{s}' at (1) is used as array; Expecting END FUNCTION statement; Expecting END PROGRAM statement",
            .{ name, binding.name },
        ) catch "Invalid association target";
        return emitAssociateSelectorDiagnostic(self, selector, msg);
    }
}

fn selectorIsNullCall(selector: *ast.Expr) bool {
    return switch (selector.*) {
        .call_or_subscript => |call| call.args.len == 0 and std.ascii.eqlIgnoreCase(call.name, "null"),
        else => false,
    };
}

fn selectorUsesVectorIndex(self: *context.Context, selector: *ast.Expr) bool {
    return switch (selector.*) {
        .component => |comp| blk: {
            if (componentArgsUseVectorIndex(self, comp)) break :blk true;
            break :blk selectorUsesVectorIndex(self, comp.base);
        },
        .call_or_subscript => |call| blk: {
            const idx = expr_semantics.symbolIndexForResolvedCall(self, selector) orelse
                (resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false);
            const sym = self.symbols.items[idx];
            const kind: symbols.ResolvedRefKind = expr_semantics.resolvedKindFor(self, selector) orelse
                (if (sym.dims.len > 0) .subscript else .call);
            if (kind != .subscript) break :blk false;
            break :blk argsUseVectorIndex(self, call.args);
        },
        .substring => |sub| argsUseVectorIndex(self, sub.args),
        else => false,
    };
}

fn componentArgsUseVectorIndex(self: *context.Context, comp: ast.ComponentExpr) bool {
    if (comp.args.len == 0) return false;
    const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch return false;
    if (base_spec.lowered_kind != .derived) return false;
    const derived_name = base_spec.derived_type_name orelse return false;
    const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse return false;
    if (component.procedure) return false;
    return argsUseVectorIndex(self, comp.args);
}

fn argsUseVectorIndex(self: *context.Context, args: []const *ast.Expr) bool {
    for (args) |arg| {
        if (arg.* == .dim_range) continue;
        if (resolve_expr.exprRank(self, arg) != 0) return true;
    }
    return false;
}

fn selectorRankForAssociateAlias(self: *context.Context, selector: *ast.Expr) usize {
    const resolved_rank = resolve_expr.exprRank(self, selector);
    const fallback_rank = syntacticSectionRank(selector);
    return if (resolved_rank >= fallback_rank) resolved_rank else fallback_rank;
}

fn syntacticSectionRank(expr: *ast.Expr) usize {
    return switch (expr.*) {
        .component => |comp| syntacticSectionRank(comp.base) + sectionRankFromArgs(comp.args),
        .call_or_subscript => |call| sectionRankFromArgs(call.args),
        else => 0,
    };
}

fn sectionRankFromArgs(args: []const *ast.Expr) usize {
    var rank: usize = 0;
    for (args) |arg| {
        if (arg.* == .dim_range) rank += 1;
    }
    return rank;
}

fn selectorIsDerivedTypeName(self: *context.Context, selector: *ast.Expr) ?[]const u8 {
    const name = switch (selector.*) {
        .identifier => |ident| ident,
        else => return null,
    };
    if (!resolve_symbols.hasDerivedType(self, name)) return null;
    if (resolve_symbols.findSymbolIndex(self, name)) |idx| {
        if (self.symbols.items[idx].kind == .variable) return null;
    }
    return name;
}

fn selectorProcedureName(self: *context.Context, selector: *ast.Expr) ?[]const u8 {
    const name = switch (selector.*) {
        .identifier => |ident| ident,
        else => return null,
    };
    if (isFunctionResultDesignatorName(self, name)) return null;
    if (resolve_symbols.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.kind == .function or sym.kind == .subroutine or sym.is_external) return name;
    }
    if (resolve_symbols.lookupKnownProcedureSig(self, name) != null) return name;
    return null;
}

fn isFunctionResultDesignatorName(self: *context.Context, name: []const u8) bool {
    if (self.unit.kind != .function) return false;
    const result_name = self.unit.result_name orelse self.unit.name;
    return std.ascii.eqlIgnoreCase(name, result_name);
}

fn emitAssociateSelectorDiagnostic(
    self: *context.Context,
    selector: *ast.Expr,
    message: []const u8,
) CheckError {
    const source = self.sourceForExpr(selector) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
    );
    return error.AssignmentTypeMismatch;
}

fn validateSelectTypeSelector(
    self: *context.Context,
    selector: *ast.Expr,
    has_associate_name: bool,
    selector_spec: symbols.TypeSpec,
) CheckError!void {
    if (has_associate_name and selector.* == .component) {
        const base_rank = resolve_expr.exprRank(self, selector.component.base);
        if (base_rank != 0) {
            const base_spec = resolve_expr.exprTypeSpec(self, selector.component.base) catch selector_spec;
            if (base_spec.lowered_kind == .derived) {
                const derived_name = base_spec.derived_type_name orelse "";
                if (resolve_symbols.lookupDerivedComponent(self, derived_name, selector.component.name)) |component| {
                    if (component.type_spec.polymorphic) {
                        const source = self.sourceForExpr(selector) orelse ast.SourceRef{};
                        self.setDiagnostic(
                            if (source.line == 0) 1 else source.line,
                            if (source.column == 0) 1 else source.column,
                            catalog.semantic.assignment_type_mismatch.code,
                            "part reference with nonzero rank",
                            source.text,
                        );
                        return error.AssignmentTypeMismatch;
                    }
                }
            }
        }
    }
    if (!has_associate_name and selector.* != .identifier) {
        const source = self.sourceForExpr(selector) orelse ast.SourceRef{};
        self.setDiagnostic(
            if (source.line == 0) 1 else source.line,
            if (source.column == 0) 1 else source.column,
            catalog.semantic.assignment_type_mismatch.code,
            "is not a named variable",
            source.text,
        );
        return error.AssignmentTypeMismatch;
    }
    if (selector_spec.lowered_kind != .derived or !selector_spec.polymorphic) {
        const source = self.sourceForExpr(selector) orelse ast.SourceRef{};
        self.setDiagnostic(
            if (source.line == 0) 1 else source.line,
            if (source.column == 0) 1 else source.column,
            catalog.semantic.assignment_type_mismatch.code,
            "Selector shall be polymorphic",
            source.text,
        );
        return error.AssignmentTypeMismatch;
    }
}

fn validateSelectTypeClauses(
    self: *context.Context,
    selector_spec: symbols.TypeSpec,
    construct_name: ?[]const u8,
    clauses: []const ast.SelectTypeClause,
) CheckError!void {
    var default_clause_count: usize = 0;
    var type_clause_counts = std.StringHashMap(usize).init(self.arena);
    var seen_class_names = std.StringHashMap(void).init(self.arena);
    for (clauses) |clause| {
        switch (clause.kind) {
            .class_default => default_clause_count += 1,
            .type_is => {
                if (clause.derived_type_name) |type_name| {
                    const lowered = std.ascii.allocLowerString(self.arena, type_name) catch type_name;
                    const count = type_clause_counts.get(lowered) orelse 0;
                    try type_clause_counts.put(lowered, count + 1);
                }
            },
            .class_is => {},
        }
    }
    var first_err: ?CheckError = null;
    for (clauses) |clause| {
        switch (clause.kind) {
            .class_default => {
                if (default_clause_count > 1) {
                    self.setDiagnostic(
                        if (clause.source.line == 0) 1 else clause.source.line,
                        if (clause.source.column == 0) 1 else clause.source.column,
                        catalog.semantic.duplicate_declaration.code,
                        "cannot be followed by a second DEFAULT CASE",
                        clause.source.text,
                    );
                    if (first_err == null) first_err = error.DuplicateDeclaration;
                }
            },
            .type_is, .class_is => {
                if (clauseHeaderRequiresDiagnostic(self, construct_name, clause)) |err| {
                    if (first_err == null) first_err = err;
                }
                const clause_spec = selectTypeClauseAliasSpec(self, selector_spec, clause) catch |err| {
                    if (first_err == null) first_err = err;
                    continue;
                };
                if (clause.kind == .type_is and
                    selector_spec.lowered_kind == .derived and
                    selector_spec.derived_type_name != null and
                    clause_spec.lowered_kind != .derived)
                {
                    self.setDiagnostic(
                        if (clause.source.line == 0) 1 else clause.source.line,
                        if (clause.source.column == 0) 1 else clause.source.column,
                        catalog.semantic.assignment_type_mismatch.code,
                        try std.fmt.allocPrint(self.arena, "Unexpected intrinsic type '{s}'", .{selectTypeIntrinsicName(clause.type_kind orelse .integer)}),
                        clause.source.text,
                    );
                    if (first_err == null) first_err = error.AssignmentTypeMismatch;
                    continue;
                }
                if (clause.kind == .class_is and !isExtensibleSelectTypeSpec(self, clause_spec)) {
                    self.setDiagnostic(
                        if (clause.source.line == 0) 1 else clause.source.line,
                        if (clause.source.column == 0) 1 else clause.source.column,
                        catalog.semantic.assignment_type_mismatch.code,
                        "must be extensible",
                        clause.source.text,
                    );
                    if (first_err == null) first_err = error.AssignmentTypeMismatch;
                    continue;
                }
                if (selector_spec.derived_type_name) |selector_name| {
                    if (clause_spec.lowered_kind != .derived or clause_spec.derived_type_name == null) {
                        self.setDiagnostic(
                            if (clause.source.line == 0) 1 else clause.source.line,
                            if (clause.source.column == 0) 1 else clause.source.column,
                            catalog.semantic.assignment_type_mismatch.code,
                            "must be an extension of",
                            clause.source.text,
                        );
                        if (first_err == null) first_err = error.AssignmentTypeMismatch;
                        continue;
                    }
                    if (!resolve_symbols.isSameOrExtension(self, clause_spec.derived_type_name.?, selector_name)) {
                        self.setDiagnostic(
                            if (clause.source.line == 0) 1 else clause.source.line,
                            if (clause.source.column == 0) 1 else clause.source.column,
                            catalog.semantic.assignment_type_mismatch.code,
                            "must be an extension of",
                            clause.source.text,
                        );
                        if (first_err == null) first_err = error.AssignmentTypeMismatch;
                        continue;
                    }
                }
                if (clause.kind == .class_is and clause_spec.derived_type_name != null) {
                    const lowered = std.ascii.allocLowerString(self.arena, clause_spec.derived_type_name.?) catch clause_spec.derived_type_name.?;
                    if (seen_class_names.contains(lowered)) {
                        self.setDiagnostic(
                            if (clause.source.line == 0) 1 else clause.source.line,
                            if (clause.source.column == 0) 1 else clause.source.column,
                            catalog.semantic.duplicate_declaration.code,
                            "Double CLASS IS block",
                            clause.source.text,
                        );
                        if (first_err == null) first_err = error.DuplicateDeclaration;
                        continue;
                    }
                    try seen_class_names.put(lowered, {});
                }
                if (clause.kind == .type_is and clause_spec.derived_type_name != null) {
                    const lowered = std.ascii.allocLowerString(self.arena, clause_spec.derived_type_name.?) catch clause_spec.derived_type_name.?;
                    if ((type_clause_counts.get(lowered) orelse 0) > 1) {
                        self.setDiagnostic(
                            if (clause.source.line == 0) 1 else clause.source.line,
                            if (clause.source.column == 0) 1 else clause.source.column,
                            catalog.semantic.duplicate_declaration.code,
                            "overlaps with TYPE IS",
                            clause.source.text,
                        );
                        if (first_err == null) first_err = error.DuplicateDeclaration;
                        continue;
                    }
                }
            },
        }
    }
    if (first_err) |err| return err;
}

fn selectTypeAliasName(select_type: ast.SelectTypeBlock) ?[]const u8 {
    if (select_type.associate_name) |name| return name;
    return switch (select_type.selector.*) {
        .identifier => |name| name,
        else => null,
    };
}

fn selectTypeClauseAliasSpec(
    self: *context.Context,
    selector_spec: symbols.TypeSpec,
    clause: ast.SelectTypeClause,
) CheckError!symbols.TypeSpec {
    switch (clause.kind) {
        .class_default => return selector_spec,
        .type_is => return try selectTypeClauseResolvedSpec(self, clause, false),
        .class_is => return (try selectTypeClauseResolvedSpec(self, clause, true)).withPolymorphic(true),
    }
}

fn selectTypeClauseResolvedSpec(
    self: *context.Context,
    clause: ast.SelectTypeClause,
    polymorphic: bool,
) CheckError!symbols.TypeSpec {
    const invalid_spec_message = selectTypeClauseInvalidSpecMessage(clause.kind);
    const kind = clause.type_kind orelse {
        self.setDiagnostic(
            if (clause.source.line == 0) 1 else clause.source.line,
            if (clause.source.column == 0) 1 else clause.source.column,
            catalog.semantic.assignment_type_mismatch.code,
            invalid_spec_message,
            clause.source.text,
        );
        return error.AssignmentTypeMismatch;
    };
    if (kind == .derived) {
        const name = clause.derived_type_name orelse {
            self.setDiagnostic(
                if (clause.source.line == 0) 1 else clause.source.line,
                if (clause.source.column == 0) 1 else clause.source.column,
                catalog.semantic.assignment_type_mismatch.code,
                invalid_spec_message,
                clause.source.text,
            );
            return error.AssignmentTypeMismatch;
        };
        if (!resolve_symbols.hasDerivedType(self, name)) {
            self.setDiagnostic(
                if (clause.source.line == 0) 1 else clause.source.line,
                if (clause.source.column == 0) 1 else clause.source.column,
                catalog.semantic.assignment_type_mismatch.code,
                invalid_spec_message,
                clause.source.text,
            );
            return error.AssignmentTypeMismatch;
        }
        return symbols.TypeSpec.fromDerived(name).withPolymorphic(polymorphic);
    }
    const spec = try decls.resolvedDeclTypeSpec(
        self,
        kind,
        clause.derived_type_name,
        clause.kind_selector,
        polymorphic,
        false,
    );
    if (kind != .character) return spec;
    return try select_type_char_clause.applySelectTypeCharacterClauseLength(self, spec, clause);
}

fn clauseHeaderRequiresDiagnostic(
    self: *context.Context,
    construct_name: ?[]const u8,
    clause: ast.SelectTypeClause,
) ?CheckError {
    if (!clause.has_trailing_tokens) return null;
    if (construct_name) |expected_name| {
        if (clause.trailing_name) |actual_name| {
            if (std.ascii.eqlIgnoreCase(actual_name, expected_name)) return null;
        }
        self.setDiagnostic(
            if (clause.source.line == 0) 1 else clause.source.line,
            if (clause.source.column == 0) 1 else clause.source.column,
            catalog.semantic.assignment_type_mismatch.code,
            "Expected block name",
            clause.source.text,
        );
        return error.AssignmentTypeMismatch;
    }
    self.setDiagnostic(
        if (clause.source.line == 0) 1 else clause.source.line,
        if (clause.source.column == 0) 1 else clause.source.column,
        catalog.parser.unexpected_token.code,
        "Syntax error",
        clause.source.text,
    );
    return error.UnexpectedToken;
}

fn selectTypeClauseInvalidSpecMessage(kind: ast.SelectTypeClauseKind) []const u8 {
    return switch (kind) {
        .type_is => "error in TYPE IS specification",
        .class_is => "error in CLASS IS specification",
        .class_default => "error in TYPE IS specification",
    };
}

fn selectTypeIntrinsicName(kind: ast.TypeKind) []const u8 {
    return switch (kind) {
        .integer => "INTEGER",
        .real => "REAL",
        .double_precision => "DOUBLE PRECISION",
        .complex => "COMPLEX",
        .complex_double => "DOUBLE COMPLEX",
        .logical => "LOGICAL",
        .character => "CHARACTER",
        .derived => "DERIVED",
    };
}

fn isExtensibleSelectTypeSpec(self: *context.Context, spec: symbols.TypeSpec) bool {
    if (spec.lowered_kind != .derived) return false;
    const derived_name = spec.derived_type_name orelse return false;
    const derived = resolve_symbols.lookupDerivedType(self, derived_name) orelse return false;
    return !derived.sequence and !derived.bind_c;
}
