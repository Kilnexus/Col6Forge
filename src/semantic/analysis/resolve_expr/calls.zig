const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const procedure_pass = @import("../../../common/procedure_pass.zig");
const symbols = @import("../../symbol/mod.zig");
const intrinsic_signature = @import("../../intrinsic_signature.zig");
const context = @import("../context.zig");
const bound_helpers = @import("calls/bound_helpers.zig");
const constructors = @import("calls/constructors.zig");
const lookup_helpers = @import("calls/lookup_helpers.zig");
const procedure_interfaces = @import("../check_statements/procedure_interfaces.zig");
const symbols_mod = @import("../resolve_symbols.zig");

const ResolvedRefKind = symbols.ResolvedRefKind;
const ResolveError = anyerror;
const emitInvalidArgumentDiagnostic = bound_helpers.emitInvalidArgumentDiagnostic;
const emitInvalidSubscriptDiagnostic = bound_helpers.emitInvalidSubscriptDiagnostic;
const hasVisibleExplicitInterface = lookup_helpers.hasVisibleExplicitInterface;
const isAbstractDerivedType = lookup_helpers.isAbstractDerivedType;
const isCurrentUnitProcedureReference = lookup_helpers.isCurrentUnitProcedureReference;
const isImplicitExternalFunctionReference = lookup_helpers.isImplicitExternalFunctionReference;
const knownProcedureConflictsWithDummy = lookup_helpers.knownProcedureConflictsWithDummy;
const minimumRequiredProcedureArgs = bound_helpers.minimumRequiredProcedureArgs;
const procedureComponentResultTypeSpec = bound_helpers.procedureComponentResultTypeSpec;
const procedureComponentSig = bound_helpers.procedureComponentSig;
const shouldCheckImplicitFunctionReferenceMismatch = lookup_helpers.shouldCheckImplicitFunctionReferenceMismatch;
const typeBoundProcedureResultTypeSpec = bound_helpers.typeBoundProcedureResultTypeSpec;
const typeBoundProcedureSig = bound_helpers.typeBoundProcedureSig;
const validateProcedureComponentCall = bound_helpers.validateProcedureComponentCall;
const validateTypeBoundProcedureCall = bound_helpers.validateTypeBoundProcedureCall;

pub fn resolveCallOrSubscriptExpr(
    self: *context.Context,
    expr_node: *ast.Expr,
    call: ast.CallOrSubscript,
    comptime deps: anytype,
) ResolveError!void {
    for (call.args) |arg| {
        try deps.resolveExpr(self, arg);
    }

    const idx = try symbols_mod.ensureSymbol(self, call.name);
    var sym = self.symbols.items[idx];
    if (shouldRejectNonRecursiveCurrentProcedureReference(self, call.name)) {
        return emitNonRecursiveProcedureReferenceDiagnostic(self, expr_node);
    }
    if (shouldRejectImplicitRecursiveFunctionResultReference(self, call.name, sym, call.args.len)) {
        return emitInvalidArgumentDiagnostic(
            self,
            expr_node,
            catalog.semantic.invalid_argument_count.code,
            "Function name is the name of a recursive function result; use RESULT for recursive calls",
        );
    }
    var kind: ResolvedRefKind = .unknown;
    var resolved_spec = sym.type_spec;
    const visible_generic_sig = try effectiveVisibleGenericSig(self, call.name, call.args, deps);
        if (constructors.structureConstructorTypeSpec(self, call.name, sym)) |ctor_spec| {
        const type_name = ctor_spec.derived_type_name orelse call.name;
        if (isAbstractDerivedType(self, type_name)) {
            const source = self.sourceForExpr(expr_node) orelse ast.SourceRef{};
            const message = std.fmt.allocPrint(self.arena, "Cannot construct ABSTRACT type '{s}'", .{type_name}) catch "Cannot construct ABSTRACT type";
            self.setDiagnostic(
                if (source.line == 0) 1 else source.line,
                if (source.column == 0) 1 else source.column,
                catalog.semantic.invalid_argument_count.code,
                message,
                source.text,
            );
            return error.InvalidArgumentCount;
        }
        try constructors.validateStructureConstructorActuals(self, call.name, call.args, ctor_spec, deps);
        kind = .call;
        resolved_spec = ctor_spec;
        if (sym.kind == .variable) sym.kind = .function;
        sym.applyTypeSpec(ctor_spec);
        sym.type_explicit = true;
        sym.is_external = false;
        sym.is_intrinsic = false;
        self.symbols.items[idx] = sym;
    } else if (sym.storage == .dummy) {
        if (sym.dims.len > 0) {
            kind = .subscript;
        } else {
            if (knownProcedureConflictsWithDummy(self, call.name)) {
                const message = std.fmt.allocPrint(self.arena, "'{s}' conflicts with DUMMY argument", .{call.name}) catch "conflicts with DUMMY argument";
                return emitInvalidArgumentDiagnostic(self, expr_node, catalog.semantic.duplicate_declaration.code, message);
            }
            kind = .call;
            if (sym.kind == .variable) sym.kind = .function;
            self.symbols.items[idx] = sym;
        }
    } else {
        if (!sym.is_intrinsic and
            !sym.is_external and
            sym.kind == .variable and
            sym.dims.len == 0 and
            call.args.len > 0 and
            symbols_mod.isIntrinsicName(call.name) and
            visible_generic_sig == null)
        {
            sym.is_intrinsic = true;
            self.symbols.items[idx] = sym;
        }
        if (sym.is_intrinsic) {
            resolved_spec = try intrinsicReturnType(self, call.name, sym.type_spec, call.args, deps);
            if (!intrinsic_signature.resultDependsOnArgs(call.name)) {
                sym.applyTypeSpec(resolved_spec);
                self.symbols.items[idx] = sym;
            }
        }
        if (sym.dims.len > 0) {
            kind = .subscript;
        } else if (resolvedProcedureSig(self, call.name, sym.is_intrinsic, visible_generic_sig)) |sig| {
            if (shouldPreferIntrinsicOverResolvedSig(self, call.name, sig, call.args, deps)) {
                kind = .call;
                sym.is_intrinsic = true;
                resolved_spec = try intrinsicReturnType(self, call.name, sym.type_spec, call.args, deps);
                if (!intrinsic_signature.resultDependsOnArgs(call.name)) {
                    sym.applyTypeSpec(resolved_spec);
                }
                self.symbols.items[idx] = sym;
            } else
        if (sig.kind == .function) {
                const was_variable = sym.kind == .variable;
                const known_result_spec = sig.result_type_spec orelse symbols_mod.lookupKnownFunctionResolvedSpec(self, call.name);
                if (shouldCheckImplicitFunctionReferenceMismatch(self, call.name, sym, visible_generic_sig) and
                    !sym.type_explicit and
                    known_result_spec != null)
                {
                    if (functionReferenceMismatchMessage(sym.type_spec, known_result_spec.?)) |message| {
                        const source = self.sourceForExpr(expr_node) orelse ast.SourceRef{};
                        self.setDiagnostic(
                            if (source.line == 0) 1 else source.line,
                            if (source.column == 0) 1 else source.column,
                            catalog.semantic.invalid_argument_count.code,
                            message,
                            source.text,
                        );
                        return error.InvalidArgumentCount;
                    }
                }
                kind = .call;
                if (sym.kind == .variable) sym.kind = .function;
                if (!sym.is_intrinsic and sym.storage != .dummy and was_variable) sym.is_external = true;
                if (!sym.type_explicit) {
                    if (known_result_spec) |fn_spec| {
                        sym.applyTypeSpec(fn_spec);
                        sym.type_explicit = true;
                    } else if (symbols_mod.lookupKnownFunctionResolvedSpec(self, call.name)) |fn_spec| {
                        sym.applyTypeSpec(fn_spec);
                        sym.type_explicit = true;
                    }
                }
                self.symbols.items[idx] = sym;
                resolved_spec = sym.type_spec;
            } else {
                return emitInvalidArgumentDiagnostic(self, expr_node, catalog.semantic.actual_argument_not_function.code, "Unexpected use of subroutine name");
            }
        } else if (symbols_mod.lookupKnownFunctionResolvedSpec(self, call.name)) |fn_spec| {
            const was_variable = sym.kind == .variable;
            kind = .call;
            if (sym.kind == .variable) sym.kind = .function;
            if (!sym.is_intrinsic and sym.storage != .dummy and was_variable) sym.is_external = true;
            if (!sym.type_explicit) {
                sym.applyTypeSpec(fn_spec);
                sym.type_explicit = true;
            }
            self.symbols.items[idx] = sym;
            resolved_spec = sym.type_spec;
        } else if (sym.is_external or sym.is_intrinsic or sym.kind == .function) {
            if (sym.is_external and !sym.type_explicit and implicitNoneActive(self)) {
                return emitInvalidArgumentDiagnostic(self, expr_node, catalog.semantic.unexpected_type_decl.code, "has no IMPLICIT type");
            }
            kind = .call;
        } else if (self.unit.owner_name != null and sym.type_explicit and sym.kind == .variable and sym.dims.len == 0 and call.args.len == 0) {
            return emitInvalidArgumentDiagnostic(self, expr_node, catalog.semantic.actual_argument_not_function.code, "is not a function");
        } else if (sym.type_explicit and call.args.len > 0) {
            if (isStatementFunctionDefinitionTarget(self, expr_node, call.args)) {
                kind = .call;
                if (sym.kind == .variable) sym.kind = .function;
                self.symbols.items[idx] = sym;
            } else if (hasProcedureActualExprArgs(self, call.args)) {
                kind = .call;
                if (sym.kind == .variable) sym.kind = .function;
                sym.is_external = true;
                self.symbols.items[idx] = sym;
            } else if (canTreatTypedScalarReferenceAsFunction(sym, call.args)) {
                kind = .call;
                if (sym.kind == .variable) sym.kind = .function;
                sym.is_external = true;
                self.symbols.items[idx] = sym;
            } else {
                return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
            }
        } else {
            kind = .call;
            if (sym.kind == .variable) sym.kind = .function;
            self.symbols.items[idx] = sym;
        }
    }
    if (kind == .call and requiresExplicitInterfaceForActuals(self, call.name, call.args, sym, deps)) {
        return error.ExplicitInterfaceRequired;
    }
    if (kind == .subscript) {
        if (sym.dims.len == 0) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
        if (call.args.len != sym.dims.len) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_count.code, "Subscript count mismatch");
        for (call.args) |arg| {
            const arg_ty = try deps.resolvedExprType(self, arg);
            if (arg_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
        }
        resolved_spec = sym.type_spec;
    }
    try deps.recordResolvedRef(self, expr_node, call.name, kind, idx);
    try deps.cacheExprType(self, expr_node, resolved_spec);
}

fn shouldRejectImplicitRecursiveFunctionResultReference(
    self: *context.Context,
    name: []const u8,
    sym: symbols.Symbol,
    arg_count: usize,
) bool {
    if (arg_count == 0) return false;
    if (self.unit.kind != .function) return false;
    if (!self.unit.recursive) return false;
    if (self.unit.result_name != null) return false;
    if (!std.ascii.eqlIgnoreCase(self.unit.name, name)) return false;
    if (sym.dims.len != 0) return false;
    return true;
}

fn shouldRejectNonRecursiveCurrentProcedureReference(self: *context.Context, name: []const u8) bool {
    if (self.unit.recursive) return false;
    if (self.unit.kind != .subroutine and self.unit.kind != .function) return false;
    if (std.ascii.eqlIgnoreCase(self.unit.name, name)) return true;
    return isSyntheticSiblingEntryProcedure(self, name);
}

fn isSyntheticSiblingEntryProcedure(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        if (decl.interface_block.name != null) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (proc_header.source.line != 0) continue;
            if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return true;
        }
    }
    return false;
}

fn emitNonRecursiveProcedureReferenceDiagnostic(self: *context.Context, expr_node: *ast.Expr) ResolveError {
    const source = self.sourceForExpr(expr_node) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_argument_count.code,
        "Procedure is not RECURSIVE",
        source.text,
    );
    return error.InvalidArgumentCount;
}

fn implicitNoneActive(self: *const context.Context) bool {
    var active = false;
    for (self.unit.decls) |decl| {
        if (decl != .implicit) continue;
        active = decl.implicit.rules.len == 0;
    }
    return active;
}

pub fn resolveSubstringExpr(
    self: *context.Context,
    expr_node: *ast.Expr,
    sub: ast.SubstringExpr,
    comptime deps: anytype,
) ResolveError!void {
    const idx = try symbols_mod.ensureSymbol(self, sub.name);
    try self.ref_symbol_index.put(@intFromPtr(expr_node), idx);
    const sym = self.symbols.items[idx];
    if (isArraySectionSubstring(sym, sub)) {
        if (sym.dims.len == 0) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
        if (sub.start) |start_expr| {
            try deps.resolveExpr(self, start_expr);
            const start_ty = try deps.resolvedExprType(self, start_expr);
            if (start_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
        }
        if (sub.end) |end_expr| {
            try deps.resolveExpr(self, end_expr);
            const end_ty = try deps.resolvedExprType(self, end_expr);
            if (end_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
        }
        try deps.recordResolvedRef(self, expr_node, sub.name, .subscript, idx);
        try deps.cacheExprType(self, expr_node, sym.type_spec);
        return;
    }
    for (sub.args) |arg| try deps.resolveExpr(self, arg);
    if (sub.start) |start| try deps.resolveExpr(self, start);
    if (sub.end) |end| try deps.resolveExpr(self, end);
    try deps.recordResolvedRef(self, expr_node, sub.name, .call, idx);
    try deps.cacheExprType(self, expr_node, symbols.TypeSpec.fromResolvedKind(.character, .character, null).withCharacterLength(.deferred, null));
}

pub fn resolveComponentExpr(
    self: *context.Context,
    expr_node: *ast.Expr,
    comp: ast.ComponentExpr,
    comptime deps: anytype,
) ResolveError!void {
    try deps.resolveExpr(self, comp.base);
    for (comp.args) |arg| try deps.resolveExpr(self, arg);
    if (invalidPolymorphicParameterComponentBase(self, comp.base)) {
        return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "Syntax error");
    }
    const base_spec = try deps.exprTypeSpecCached(self, comp.base);
    if (pseudoComponentInfo(base_spec, comp.name)) |pseudo| {
        if (comp.has_parens or comp.args.len != 0) {
            return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
        }
        try deps.cacheExprType(self, expr_node, pseudo.result_spec);
        return;
    }
    if (base_spec.lowered_kind != .derived) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
    const derived_name = base_spec.derived_type_name orelse
        derivedTypeNameForExprFallback(self, comp.base) orelse
        return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
    try ensureResolvedDerivedTypeForComponentBase(self, derived_name, expr_node);
    if (symbols_mod.lookupDerivedComponent(self, derived_name, comp.name)) |component| {
        if (component.procedure) {
            if (!comp.has_parens) {
                try deps.cacheExprType(self, expr_node, component.type_spec);
                return;
            }
            try validateProcedureComponentCall(self, expr_node, comp.base, component, comp.args, deps);
            try deps.cacheExprType(self, expr_node, try procedureComponentResultTypeSpec(self, component));
            return;
        }
        if (isCharacterComponentSubstringRef(component, comp)) {
            try validateCharacterComponentSubstringArgs(self, expr_node, component.dims, comp.args, deps);
            try deps.cacheExprType(self, expr_node, component.type_spec);
            return;
        }
        try validateComponentArgs(self, expr_node, component.dims, comp.args, deps);
        try deps.cacheExprType(self, expr_node, component.type_spec);
        return;
    }
    const binding = symbols_mod.lookupDerivedBinding(self, derived_name, comp.name) orelse {
        const message = std.fmt.allocPrint(self.arena, "'{s}' is not a member of the '{s}' structure", .{ comp.name, derived_name }) catch "component or binding is not a member of the structure";
        return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_component_reference.code, message);
    };
    if (!comp.has_parens) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
    try validateTypeBoundProcedureCall(self, expr_node, comp.base, binding, comp.args, deps);
    try deps.cacheExprType(self, expr_node, try typeBoundProcedureResultTypeSpec(self, binding));
}

pub fn exprRankForCallOrSubscript(
    self: *context.Context,
    expr_node: *ast.Expr,
    call: ast.CallOrSubscript,
    comptime deps: anytype,
) usize {
    const idx = self.ref_symbol_index.get(@intFromPtr(expr_node)) orelse
        (symbols_mod.findSymbolIndex(self, call.name) orelse return 0);
    const sym = self.symbols.items[idx];
    const kind: ResolvedRefKind = deps.refKindIndex(self, @intFromPtr(expr_node)) orelse
        (if (sym.dims.len > 0) .subscript else .call);
    if (kind == .subscript) return sectionResultRank(self, call.args, deps);
    if (sym.is_intrinsic or symbols_mod.isIntrinsicName(call.name)) {
        if (intrinsicResultRank(self, call.name, call.args, deps)) |rank| return rank;
        return 0;
    }
    if (resolvedProcedureSig(self, call.name, false, visibleSingleTargetGenericSig(self, call.name))) |sig| {
        if (sig.elemental and sig.result_rank == 0) {
            return elementalActualRank(self, call.args, deps);
        }
        return sig.result_rank;
    }
    return sym.dims.len;
}

pub fn exprRankForSubstring(
    self: *context.Context,
    expr_node: *ast.Expr,
    sub: ast.SubstringExpr,
    comptime deps: anytype,
) usize {
    const idx = self.ref_symbol_index.get(@intFromPtr(expr_node)) orelse
        (symbols_mod.findSymbolIndex(self, sub.name) orelse return 0);
    const sym = self.symbols.items[idx];
    if (isArraySectionSubstring(sym, sub)) return 1;
    if (sub.args.len != 0) return sectionResultRank(self, sub.args, deps);
    return 0;
}

fn intrinsicResultRank(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
    comptime deps: anytype,
) ?usize {
    var upper_buf: [64]u8 = undefined;
    if (name.len > upper_buf.len) return null;
    for (name, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    const upper = upper_buf[0..name.len];

    if (std.mem.eql(u8, upper, "SUM")) {
        if (args.len == 0) return 0;
        const array_rank = deps.exprRank(self, args[0]);
        if (args.len >= 2) return array_rank -| 1;
        return 0;
    }
    if (std.mem.eql(u8, upper, "COUNT")) {
        if (args.len == 0) return 0;
        const array_rank = deps.exprRank(self, args[0]);
        if (args.len >= 3 and constIntLiteralValue(args[2]) != null) return array_rank -| 1;
        if (args.len >= 2 and constIntLiteralValue(args[1]) != null) return array_rank -| 1;
        return 0;
    }
    if (std.mem.eql(u8, upper, "SHAPE") or
        std.mem.eql(u8, upper, "LBOUND") or
        std.mem.eql(u8, upper, "UBOUND"))
    {
        if (args.len >= 2) return 0;
        return 1;
    }
    if (std.mem.eql(u8, upper, "RESHAPE")) {
        if (args.len < 2) return null;
        if (reshapeResultRank(self, args[1], deps)) |rank| return rank;
        return 1;
    }
    if (std.mem.eql(u8, upper, "PACK")) {
        if (args.len == 0) return null;
        return 1;
    }
    if (std.mem.eql(u8, upper, "CSHIFT") or std.mem.eql(u8, upper, "EOSHIFT")) {
        if (args.len == 0) return null;
        return deps.exprRank(self, args[0]);
    }
    if (std.mem.eql(u8, upper, "MERGE")) {
        return elementalActualRank(self, args, deps);
    }
    return null;
}

fn reshapeResultRank(
    self: *context.Context,
    shape_expr: *ast.Expr,
    comptime deps: anytype,
) ?usize {
    return switch (shape_expr.*) {
        .array_constructor => |ctor| ctor.items.len,
        .call_or_subscript => |call| blk: {
            if (std.ascii.eqlIgnoreCase(call.name, "shape") or
                std.ascii.eqlIgnoreCase(call.name, "lbound") or
                std.ascii.eqlIgnoreCase(call.name, "ubound"))
            {
                if (call.args.len == 0) break :blk 1;
                break :blk deps.exprRank(self, call.args[0]);
            }
            break :blk null;
        },
        .identifier => |name| blk: {
            const idx = symbols_mod.findSymbolIndex(self, name) orelse break :blk null;
            if (self.symbols.items[idx].dims.len == 1) {
                const extent = constantShapeVectorLength(self.symbols.items[idx].dims[0]) orelse break :blk null;
                break :blk extent;
            }
            break :blk null;
        },
        else => null,
    };
}

fn constantShapeVectorLength(dim: *ast.Expr) ?usize {
    return switch (dim.*) {
        .dim_range => |range| blk: {
            const lower = if (range.lower) |expr| constIntLiteralValue(expr) orelse break :blk null else 1;
            if (range.upper.* == .literal and range.upper.literal.kind == .assumed_size) break :blk null;
            const upper = constIntLiteralValue(range.upper) orelse break :blk null;
            const stride = if (range.stride) |expr| constIntLiteralValue(expr) orelse break :blk null else 1;
            if (stride == 0) break :blk null;
            if (stride > 0 and upper < lower) break :blk 0;
            if (stride < 0 and upper > lower) break :blk 0;
            const count = if (stride > 0)
                @divTrunc(upper - lower, stride) + 1
            else
                @divTrunc(lower - upper, -stride) + 1;
            if (count < 0) break :blk null;
            break :blk @intCast(count);
        },
        .literal => |lit| blk: {
            if (lit.kind != .integer) break :blk null;
            const value = std.fmt.parseInt(i64, lit.text, 10) catch break :blk null;
            if (value < 0) break :blk null;
            break :blk @intCast(value);
        },
        else => null,
    };
}

fn constIntLiteralValue(expr: *ast.Expr) ?i64 {
    return switch (expr.*) {
        .literal => |lit| if (lit.kind == .integer) std.fmt.parseInt(i64, lit.text, 10) catch null else null,
        .unary => |un| blk: {
            const inner = constIntLiteralValue(un.expr) orelse break :blk null;
            break :blk switch (un.op) {
                .plus => inner,
                .minus => -inner,
                else => null,
            };
        },
        else => null,
    };
}

fn elementalActualRank(
    self: *context.Context,
    args: []*ast.Expr,
    comptime deps: anytype,
) usize {
    var rank: usize = 0;
    for (args) |arg| rank = @max(rank, deps.exprRank(self, arg));
    return rank;
}

pub fn exprRankForComponent(
    self: *context.Context,
    comp: ast.ComponentExpr,
    comptime deps: anytype,
) usize {
    const base_rank = deps.exprRank(self, comp.base);
    const base_spec = deps.exprTypeSpec(self, comp.base) catch return 0;
    if (pseudoComponentInfo(base_spec, comp.name)) |pseudo| {
        if (comp.has_parens or comp.args.len != 0) return 0;
        return switch (pseudo.rank_mode) {
            .preserve_base => base_rank,
            .scalar => 0,
        };
    }
    if (base_spec.lowered_kind != .derived) return 0;
    const derived_name = base_spec.derived_type_name orelse derivedTypeNameForExprFallback(self, comp.base) orelse return 0;
    const component = symbols_mod.lookupDerivedComponent(self, derived_name, comp.name) orelse return 0;
    if (component.procedure and comp.has_parens) {
        const sig = procedureComponentSig(self, component) orelse return 0;
        return sig.result_rank;
    }
    if (comp.args.len == 0) return base_rank + component.dims.len;
    return base_rank + sectionResultRank(self, comp.args, deps);
}

pub fn exprTypeSpecForCallOrSubscript(
    self: *context.Context,
    expr_node: *ast.Expr,
    call: ast.CallOrSubscript,
    comptime deps: anytype,
) ResolveError!symbols.TypeSpec {
    if (self.ref_symbol_index.get(@intFromPtr(expr_node))) |idx| {
        const sym = self.symbols.items[idx];
        const kind = deps.refKindIndex(self, @intFromPtr(expr_node)) orelse if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call;
        if (kind == .call and sym.is_intrinsic) {
            return intrinsicReturnType(self, call.name, sym.type_spec, call.args, deps);
        }
        return sym.type_spec;
    }
    const idx = try symbols_mod.ensureSymbol(self, call.name);
    const sym = self.symbols.items[idx];
    if (sym.is_intrinsic) return intrinsicReturnType(self, call.name, sym.type_spec, call.args, deps);
    if (visibleSingleTargetGenericSig(self, call.name)) |sig| {
        if (sig.result_type_spec) |spec| return spec;
    }
    return sym.type_spec;
}

pub fn exprTypeSpecForSubstring(
    self: *context.Context,
    expr_node: *ast.Expr,
    sub: ast.SubstringExpr,
) ResolveError!symbols.TypeSpec {
    if (self.ref_symbol_index.get(@intFromPtr(expr_node))) |idx| {
        const sym = self.symbols.items[idx];
        if (isArraySectionSubstring(sym, sub)) return sym.type_spec;
    }
    const idx = try symbols_mod.ensureSymbol(self, sub.name);
    const sym = self.symbols.items[idx];
    if (isArraySectionSubstring(sym, sub)) return sym.type_spec;
    return symbols.TypeSpec.fromResolvedKind(.character, .character, null).withCharacterLength(.deferred, null);
}

pub fn exprTypeSpecForComponent(
    self: *context.Context,
    comp: ast.ComponentExpr,
    comptime deps: anytype,
) ResolveError!symbols.TypeSpec {
    const base_spec = try deps.exprTypeSpecCached(self, comp.base);
    if (pseudoComponentInfo(base_spec, comp.name)) |pseudo| {
        if (comp.has_parens or comp.args.len != 0) return error.InvalidSubscript;
        return pseudo.result_spec;
    }
    if (base_spec.lowered_kind != .derived) return error.InvalidSubscript;
    const derived_name = base_spec.derived_type_name orelse derivedTypeNameForExprFallback(self, comp.base) orelse return error.InvalidSubscript;
    try ensureResolvedDerivedTypeForComponentBase(self, derived_name, comp.base);
    if (symbols_mod.lookupDerivedComponent(self, derived_name, comp.name)) |component| {
        if (component.procedure and comp.has_parens) return procedureComponentResultTypeSpec(self, component);
        return component.type_spec;
    }
    const binding = symbols_mod.lookupDerivedBinding(self, derived_name, comp.name) orelse return error.InvalidSubscript;
    if (!comp.has_parens) return error.InvalidSubscript;
    return typeBoundProcedureResultTypeSpec(self, binding);
}

pub fn intrinsicReturnType(
    self: *context.Context,
    name: []const u8,
    current: symbols.TypeSpec,
    args: []*ast.Expr,
    comptime deps: anytype,
) ResolveError!symbols.TypeSpec {
    var arg_types_buf: [8]symbols.TypeSpec = undefined;
    if (args.len <= arg_types_buf.len) {
        var arg_types = arg_types_buf[0..args.len];
        for (args, 0..) |arg, idx| {
            arg_types[idx] = try deps.exprTypeSpecCached(self, arg);
        }
        return intrinsic_signature.inferResultType(name, current, arg_types);
    }
    var dynamic_args = try self.arena.alloc(symbols.TypeSpec, args.len);
    for (args, 0..) |arg, idx| {
        dynamic_args[idx] = try deps.exprTypeSpecCached(self, arg);
    }
    return intrinsic_signature.inferResultType(name, current, dynamic_args);
}

fn isStatementFunctionDefinitionTarget(
    self: *context.Context,
    expr_node: *ast.Expr,
    args: []*ast.Expr,
) bool {
    const stmt = self.current_stmt orelse return false;
    if (stmt.node != .assignment) return false;
    if (stmt.node.assignment.target != expr_node) return false;
    if (args.len == 0) return false;
    for (args) |arg| if (arg.* != .identifier) return false;
    return true;
}

fn hasDimRangeActual(args: []*ast.Expr) bool {
    for (args) |arg| if (arg.* == .dim_range) return true;
    return false;
}

fn sectionResultRank(
    self: *context.Context,
    args: []*ast.Expr,
    comptime deps: anytype,
) usize {
    var rank: usize = 0;
    var saw_section = false;
    for (args) |arg| {
        switch (arg.*) {
            .dim_range => {
                saw_section = true;
                rank += 1;
            },
            else => {
                const arg_rank = deps.exprRank(self, arg);
                if (arg_rank != 0) {
                    saw_section = true;
                    rank += 1;
                }
            },
        }
    }
    return if (saw_section) rank else 0;
}

fn canTreatTypedScalarReferenceAsFunction(sym: symbols.Symbol, args: []*ast.Expr) bool {
    if (!sym.type_explicit) return false;
    if (sym.dims.len != 0) return false;
    if (args.len == 0) return false;
    if (hasDimRangeActual(args)) return false;
    return sym.kind == .variable or sym.kind == .function;
}

pub const PseudoComponentRankMode = enum {
    preserve_base,
    scalar,
};

pub const PseudoComponentInfo = struct {
    result_spec: symbols.TypeSpec,
    rank_mode: PseudoComponentRankMode,
};

pub fn pseudoComponentInfo(base_spec: symbols.TypeSpec, name: []const u8) ?PseudoComponentInfo {
    if (std.ascii.eqlIgnoreCase(name, "re") or std.ascii.eqlIgnoreCase(name, "im")) {
        return switch (base_spec.lowered_kind) {
            .complex => .{
                .result_spec = symbols.TypeSpec.fromResolvedKind(.real, .real, base_spec.kind_value),
                .rank_mode = .preserve_base,
            },
            .complex_double => .{
                .result_spec = symbols.TypeSpec.fromResolvedKind(.real, .double_precision, complexToRealKindValue(base_spec.kind_value)),
                .rank_mode = .preserve_base,
            },
            else => null,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "len")) {
        if (base_spec.lowered_kind != .character) return null;
        return .{
            .result_spec = symbols.TypeSpec.fromResolvedKind(.integer, .integer, null),
            .rank_mode = .scalar,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "kind")) {
        if (base_spec.lowered_kind == .derived) return null;
        return .{
            .result_spec = symbols.TypeSpec.fromResolvedKind(.integer, .integer, null),
            .rank_mode = .scalar,
        };
    }
    return null;
}

fn complexToRealKindValue(kind_value: ?i64) ?i64 {
    const value = kind_value orelse return null;
    if (value >= 16) return @divTrunc(value, 2);
    return value;
}

fn derivedTypeNameForExprFallback(self: *context.Context, expr_node: *ast.Expr) ?[]const u8 {
    return switch (expr_node.*) {
        .identifier => |name| blk: {
            const idx = symbols_mod.findSymbolIndex(self, name) orelse break :blk null;
            const sym = self.symbols.items[idx];
            if (sym.type_spec.lowered_kind != .derived) break :blk null;
            break :blk sym.type_spec.derived_type_name;
        },
        .call_or_subscript => |call| blk: {
            const idx = symbols_mod.findSymbolIndex(self, call.name) orelse break :blk null;
            const sym = self.symbols.items[idx];
            if (sym.type_spec.lowered_kind != .derived) break :blk null;
            break :blk sym.type_spec.derived_type_name;
        },
        .component => |comp| blk: {
            const base_name = derivedTypeNameForExprFallback(self, comp.base) orelse break :blk null;
            const component = symbols_mod.lookupDerivedComponent(self, base_name, comp.name) orelse break :blk null;
            if (component.type_spec.lowered_kind != .derived) break :blk null;
            break :blk component.type_spec.derived_type_name;
        },
        else => null,
    };
}

fn hasProcedureActualExprArgs(self: *context.Context, args: []*ast.Expr) bool {
    for (args) |arg| {
        switch (arg.*) {
            .identifier => |name| {
                if (symbols_mod.lookupKnownProcedureSig(self, name) != null) return true;
                const idx = symbols_mod.findSymbolIndex(self, name) orelse continue;
                const sym = self.symbols.items[idx];
                if ((sym.kind == .function or sym.kind == .subroutine) and !sym.is_external) return true;
            },
            else => {},
        }
    }
    return false;
}

fn visibleSingleTargetGenericSig(self: *context.Context, name: []const u8) ?context.Context.ProcedureSig {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, name)) continue;
        return singleTargetGenericInterfaceSig(self, decl.interface_block);
    }
    return null;
}

fn effectiveVisibleGenericSig(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
    comptime deps: anytype,
) !?context.Context.ProcedureSig {
    const sig = procedure_interfaces.visibleSpecificInterfaceSig(self, name) orelse
        visibleSingleTargetGenericSig(self, name) orelse return null;
    if (!symbols_mod.isIntrinsicName(name)) return sig;
    if (symbols_mod.lookupKnownProcedureSig(self, name) == null) return sig;
    if (try exprActualsCouldMatchProcedureSig(self, sig, args, deps)) return sig;
    return null;
}

fn exprActualsCouldMatchProcedureSig(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    args: []*ast.Expr,
    comptime deps: anytype,
) !bool {
    const min_count = minimumRequiredProcedureArgs(sig);
    if (args.len < min_count or args.len > sig.arg_count) return false;
    const count = @min(sig.args.len, args.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        if (!(try exprActualCouldMatchFormal(self, sig, sig.args[idx], args[idx], deps))) return false;
    }
    return true;
}

fn exprActualCouldMatchFormal(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) !bool {
    if (formal.is_procedure) return true;
    try deps.resolveExpr(self, actual_expr);
    const actual_spec = try deps.exprTypeSpecCached(self, actual_expr);
    if (!deps.dummyArgTypeCompatible(self, formal.type_spec, actual_spec)) return false;
    _ = sig;
    return true;
}

fn shouldPreferIntrinsicOverResolvedSig(
    self: *context.Context,
    name: []const u8,
    sig: context.Context.ProcedureSig,
    args: []*ast.Expr,
    comptime deps: anytype,
) bool {
    if (!symbols_mod.isIntrinsicName(name)) return false;
    if (sig.kind != .function) return false;
    return !(exprActualsCouldMatchProcedureSig(self, sig, args, deps) catch false);
}

fn resolvedProcedureSig(
    self: *context.Context,
    name: []const u8,
    intrinsic_override: bool,
    visible_generic_sig: ?context.Context.ProcedureSig,
) ?context.Context.ProcedureSig {
    if (intrinsic_override) return null;
    return visible_generic_sig orelse
        procedure_interfaces.visibleSpecificInterfaceSig(self, name) orelse
        symbols_mod.lookupKnownProcedureSig(self, name);
}

fn singleTargetGenericInterfaceSig(
    self: *context.Context,
    interface_block: ast.InterfaceBlock,
) ?context.Context.ProcedureSig {
    const total = interface_block.module_procedures.len +
        interface_block.specific_procedures.len +
        interface_block.procedures.len +
        interface_block.procedure_headers.len;
    if (total != 1) return null;

    if (interface_block.procedure_headers.len == 1) {
        return symbols_mod.lookupKnownProcedureSig(self, interface_block.procedure_headers[0].name);
    }
    if (interface_block.module_procedures.len == 1) {
        const proc_name = interface_block.module_procedures[0];
        if (symbols_mod.lookupKnownProcedureSig(self, proc_name)) |sig| return sig;
        const source = interface_block.module_procedure_sources[0];
        if (source.owner_name) |owner_name| {
            const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, proc_name }) catch return null;
            return symbols_mod.lookupKnownProcedureSig(self, qualified);
        }
        return null;
    }
    if (interface_block.specific_procedures.len == 1) {
        return symbols_mod.lookupKnownProcedureSig(self, interface_block.specific_procedures[0]);
    }
    if (interface_block.procedures.len == 1) {
        return symbols_mod.lookupKnownProcedureSig(self, interface_block.procedures[0]);
    }
    return null;
}

fn requiresExplicitInterfaceForActuals(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
    sym: symbols.Symbol,
    comptime deps: anytype,
) bool {
    if (sym.is_intrinsic) return false;
    if (symbols_mod.lookupKnownProcedureSig(self, name) != null) return false;
    for (args) |arg| {
        const spec = deps.exprTypeSpecCached(self, arg) catch continue;
        if (spec.lowered_kind == .derived and spec.polymorphic) return true;
    }
    if (sym.is_external) return false;
    return false;
}

fn functionReferenceMismatchMessage(declared: symbols.TypeSpec, known: symbols.TypeSpec) ?[]const u8 {
    if (declared.lowered_kind == .character and known.lowered_kind == .character) {
        if (declared.char_len_kind != known.char_len_kind or declared.char_len != known.char_len) {
            return "Character length mismatch";
        }
    }
    if (declared.lowered_kind != known.lowered_kind) return "Return type mismatch";
    if (declared.kind_value != known.kind_value) return "Return type mismatch";
    if (declared.polymorphic != known.polymorphic) return "Return type mismatch";
    if (declared.lowered_kind == .derived) {
        const declared_name = declared.derived_type_name orelse return "Return type mismatch";
        const known_name = known.derived_type_name orelse return "Return type mismatch";
        if (!std.ascii.eqlIgnoreCase(declared_name, known_name)) return "Return type mismatch";
    }
    return null;
}

fn ensureResolvedDerivedTypeForComponentBase(
    self: *context.Context,
    derived_name: []const u8,
    expr_node: *ast.Expr,
) ResolveError!void {
    if (symbols_mod.hasDerivedType(self, derived_name)) return;
    const source = self.sourceForExpr(expr_node) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.unexpected_type_decl.code,
        "is being used before it is defined",
        source.text,
    );
    self.setCurrentSource(source);
    return error.UnexpectedTypeDecl;
}

fn invalidPolymorphicParameterComponentBase(self: *context.Context, expr_node: *ast.Expr) bool {
    const name = switch (expr_node.*) {
        .identifier => |ident| ident,
        else => return false,
    };
    const idx = symbols_mod.findSymbolIndex(self, name) orelse return false;
    const sym = self.symbols.items[idx];
    return sym.kind == .parameter and sym.type_spec.lowered_kind == .derived and sym.type_spec.polymorphic;
}


fn isArraySectionSubstring(sym: symbols.Symbol, sub: ast.SubstringExpr) bool {
    return sym.dims.len != 0 and sub.args.len == 0;
}

pub fn isCharacterComponentSubstringRef(
    component: context.Context.DerivedTypeInfo.ComponentInfo,
    comp: ast.ComponentExpr,
) bool {
    if (component.procedure) return false;
    if (component.type_spec.lowered_kind != .character) return false;
    if (!comp.has_parens) return false;
    if (comp.args.len != component.dims.len + 1) return false;
    return comp.args[comp.args.len - 1].* == .dim_range;
}

pub fn validateCharacterComponentSubstringArgs(
    self: *context.Context,
    expr_node: *ast.Expr,
    component_dims: []*ast.Expr,
    args: []*ast.Expr,
    comptime deps: anytype,
) ResolveError!void {
    if (args.len != component_dims.len + 1) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_count.code, "Subscript count mismatch");
    if (component_dims.len != 0) {
        try validateComponentArgs(self, expr_node, component_dims, args[0..component_dims.len], deps);
    }
    const range = switch (args[args.len - 1].*) {
        .dim_range => |range| range,
        else => return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context"),
    };
    if (range.lower) |lower| {
        const lower_ty = try deps.resolvedExprType(self, lower);
        if (lower_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
    }
    if (!(range.upper.* == .literal and range.upper.literal.kind == .assumed_size)) {
        const upper_ty = try deps.resolvedExprType(self, range.upper);
        if (upper_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
    }
    if (range.stride != null) {
        return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
    }
}

fn validateComponentArgs(
    self: *context.Context,
    expr_node: *ast.Expr,
    dims: []*ast.Expr,
    args: []*ast.Expr,
    comptime deps: anytype,
) ResolveError!void {
    if (dims.len == 0) {
        if (args.len != 0) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_target.code, "object is not subscriptable in this context");
        return;
    }
    if (args.len == 0) return;
    if (args.len != dims.len) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_count.code, "Subscript count mismatch");
    for (args) |arg| {
        switch (arg.*) {
            .dim_range => |range| {
                if (range.lower) |lower| {
                    const lower_ty = try deps.resolvedExprType(self, lower);
                    if (lower_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
                }
                if (!(range.upper.* == .literal and range.upper.literal.kind == .assumed_size)) {
                    const upper_ty = try deps.resolvedExprType(self, range.upper);
                    if (upper_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
                }
                if (range.stride) |stride| {
                    const stride_ty = try deps.resolvedExprType(self, stride);
                    if (stride_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
                }
            },
            else => {
                const arg_ty = try deps.resolvedExprType(self, arg);
                if (arg_ty != .integer) return emitInvalidSubscriptDiagnostic(self, expr_node, catalog.semantic.invalid_subscript_type.code, "Subscript must be INTEGER");
            },
        }
    }
}
