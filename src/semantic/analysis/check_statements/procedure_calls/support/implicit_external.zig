const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const common_diag = @import("../../../../../common/diagnostic.zig");
const catalog = @import("../../../../../common/error_catalog.zig");
const procedure_pass = @import("../../../../../common/procedure_pass.zig");
const free_form = @import("../../../../../frontend/free_form.zig");
const parser = @import("../../../../../frontend/parser/mod.zig");
const symbols = @import("../../../../symbol/mod.zig");
const procedure_inference = @import("../../../../split/api/procedure_inference.zig");
const context = @import("../../../context.zig");
const constants = @import("../../../resolve_const.zig");
const resolve_expr = @import("../../../resolve_expr.zig");
const resolve_symbols = @import("../../../resolve_symbols.zig");
const abstract_expr_use = @import("../../abstract_expr_use.zig");
const leaf_helpers = @import("../../leaf_helpers.zig");
const procedure_call_actual_traits = @import("../../procedure_call_actual_traits.zig");
const procedure_call_diagnostics = @import("../../procedure_call_diagnostics.zig");
const procedure_interfaces = @import("../../procedure_interfaces.zig");
const resolution = @import("resolution.zig");
const sequence_association = @import("sequence_association.zig");

pub const CheckError = anyerror;
const DiagnosticSource = procedure_call_diagnostics.DiagnosticSource;
const Advice = procedure_call_diagnostics.Advice;
const invalidArgumentAdvice = procedure_call_diagnostics.invalidArgumentAdvice;
const appendUniqueDeclSource = procedure_call_diagnostics.appendUniqueDeclSource;
const emitStructuredProcedureDiagnostic = procedure_call_diagnostics.emitStructuredProcedureDiagnostic;
const emitProcedureActualDiagnostic = procedure_call_diagnostics.emitProcedureActualDiagnostic;
const emitProcedureActualCallDiagnostic = procedure_call_diagnostics.emitProcedureActualCallDiagnostic;
const emitProcedureActualCallWarning = procedure_call_diagnostics.emitProcedureActualCallWarning;
const emitVariableDefinitionContextDiagnostic = procedure_call_diagnostics.emitVariableDefinitionContextDiagnostic;
const exprIsVariableDefinitionActual = procedure_call_diagnostics.exprIsVariableDefinitionActual;
const abstractPassedObjectTypeName = procedure_call_actual_traits.abstractPassedObjectTypeName;
const emitAbstractPassedObjectDiagnostic = procedure_call_actual_traits.emitAbstractPassedObjectDiagnostic;
const hasProcedureActualCallArg = procedure_call_actual_traits.hasProcedureActualCallArg;
const hasProcedureActualExprArg = procedure_call_actual_traits.hasProcedureActualExprArg;
const hasExplicitInterfaceSensitiveCallArg = procedure_call_actual_traits.hasExplicitInterfaceSensitiveCallArg;
const hasExplicitInterfaceSensitiveExprArg = procedure_call_actual_traits.hasExplicitInterfaceSensitiveExprArg;
const hasKeywordActualCallArg = procedure_call_actual_traits.hasKeywordActualCallArg;
const resolvedProcedureSig = resolution.resolvedProcedureSig;
const getLowercaseMapPtr = sequence_association.getLowercaseMapPtr;

fn countCallExprArgs(args: []const ast.CallArg) usize {
    var count: usize = 0;
    for (args) |arg| {
        if (arg == .expr) count += 1;
    }
    return count;
}

fn currentProcedureSourceRef(self: *context.Context) ast.SourceRef {
    if (self.current_source) |src| return src;
    if (self.current_stmt) |stmt| {
        return .{
            .line = stmt.source_line,
            .column = stmt.source_column,
            .text = stmt.source_text,
        };
    }
    return .{};
}

fn hasVisibleGenericInterface(self: *context.Context, name: []const u8) bool {
    var idx: usize = 0;
    while (idx < self.unit.decls.len) : (idx += 1) {
        const decl = self.unit.decls[idx];
        if (decl != .interface_block) continue;
        if (decl.interface_block.name) |interface_name| {
            if (std.ascii.eqlIgnoreCase(interface_name, name)) return true;
        }
    }
    return false;
}


pub fn checkImplicitExternalCallConsistencyForCall(
    self: *context.Context,
    name: []const u8,
    args: []const ast.CallArg,
) CheckError!void {
    if (!shouldTrackImplicitExternalCall(self, name)) return;
    const expr_count = countCallExprArgs(args);
    const actuals = self.arena.alloc(context.Context.ImplicitCallArgSig, expr_count) catch return;
    var idx: usize = 0;
    for (args) |arg| {
        if (arg != .expr) continue;
        actuals[idx] = try implicitActualArgSig(self, arg.expr.value);
        idx += 1;
    }
    try checkImplicitExternalCallConsistency(self, name, actuals, currentProcedureSourceRef(self));
}

pub fn checkImplicitExternalCallConsistencyForExpr(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    if (!shouldTrackImplicitExternalCall(self, name)) return;
    const actuals = self.arena.alloc(context.Context.ImplicitCallArgSig, args.len) catch return;
    for (args, 0..) |arg, idx| {
        actuals[idx] = try implicitActualArgSig(self, arg);
    }
    try checkImplicitExternalCallConsistency(self, name, actuals, currentProcedureSourceRef(self));
}

fn shouldTrackImplicitExternalCall(self: *context.Context, name: []const u8) bool {
    if (resolve_symbols.hasDerivedType(self, name)) return false;
    if (resolve_symbols.lookupKnownProcedureSig(self, name) != null) return false;
    if (resolvedProcedureSig(self, name) != null) return false;
    if (procedure_interfaces.calleeHasVisibleExplicitInterface(self, name)) return false;
    if (hasVisibleGenericInterface(self, name)) return false;
    if (leaf_helpers.lookupIntrinsicArity(self, name) != null) return false;
    if (resolve_symbols.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if ((sym.kind == .function or sym.kind == .subroutine) and !sym.is_external) return false;
        if (sym.is_intrinsic) return false;
    }
    return true;
}

fn checkImplicitExternalCallConsistency(
    self: *context.Context,
    name: []const u8,
    actuals: []const context.Context.ImplicitCallArgSig,
    call_source: ast.SourceRef,
) CheckError!void {
    const observed = findImplicitCallSigPtr(self, name);
    if (observed == null) {
        try recordImplicitCallSig(self, name, actuals, call_source);
        return;
    }
    const existing = observed.?;
    if (existing.args.len != actuals.len) {
        if (self.allow_argument_mismatch) return;
        emitImplicitObservedCallMismatch(self, call_source, existing.call_source, "wrong number of arguments");
        return error.InvalidArgumentCount;
    }
    const count = @min(existing.args.len, actuals.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const previous = &existing.args[idx];
        const current = actuals[idx];
        if (previous.actual_class != current.actual_class) {
            if (self.allow_argument_mismatch) return;
            emitImplicitObservedArgumentMismatch(self, current.source, previous.source, "Rank mismatch in argument");
            previous.mismatch_reported = true;
            return error.InvalidArgumentCount;
        }
        if (!implicitActualTypesCompatible(previous.type_spec, current.type_spec)) {
            if (self.allow_argument_mismatch) return;
            emitImplicitObservedArgumentMismatch(self, current.source, previous.source, "Type mismatch in argument");
            previous.mismatch_reported = true;
            return error.InvalidArgumentCount;
        }
    }
}

fn implicitActualArgSig(
    self: *context.Context,
    expr: *ast.Expr,
) CheckError!context.Context.ImplicitCallArgSig {
    return .{
        .type_spec = try resolve_expr.exprTypeSpec(self, expr),
        .actual_class = if (resolve_expr.exprRank(self, expr) == 0) .scalar else .sequence,
        .source = self.sourceForExpr(expr) orelse ast.SourceRef{},
    };
}

fn findImplicitCallSigPtr(self: *context.Context, name: []const u8) ?*context.Context.ImplicitCallSig {
    if (getLowercaseMapPtr(context.Context.ImplicitCallSig, &self.implicit_call_sigs, name)) |sig| return sig;
    if (self.known_host_implicit_call_sigs) |host| {
        if (getLowercaseMapPtr(context.Context.ImplicitCallSig, host, name)) |sig| return sig;
    }
    const program = self.known_program_implicit_call_sigs orelse return null;
    return getLowercaseMapPtr(context.Context.ImplicitCallSig, program, name);
}

fn recordImplicitCallSig(
    self: *context.Context,
    name: []const u8,
    actuals: []const context.Context.ImplicitCallArgSig,
    call_source: ast.SourceRef,
) !void {
    const key = try leaf_helpers.lowerDup(self.arena, name);
    const owned = try self.arena.dupe(context.Context.ImplicitCallArgSig, actuals);
    try self.implicit_call_sigs.put(key, .{ .args = owned, .call_source = call_source });
}

fn implicitExternalCallAdvice() Advice {
    return .{
        .notes = &.{.{ .text = "calls to the same implicitly resolved external procedure must stay consistent across observed call sites" }},
        .helps = &.{.{ .text = "add an explicit interface or keep the actual argument counts, ranks, and types consistent" }},
    };
}

fn emitImplicitObservedArgumentMismatch(
    self: *context.Context,
    current: ast.SourceRef,
    previous: ast.SourceRef,
    message: []const u8,
) void {
    const advice = implicitExternalCallAdvice();
    if (previous.line != 0 and previous.column != 0) {
        const related = [_]ast.DeclSource{.{
            .line = previous.line,
            .column = previous.column,
            .text = previous.text,
        }};
        emitStructuredProcedureDiagnostic(
            self,
            .{
                .line = if (current.line == 0) 1 else current.line,
                .column = if (current.column == 0) 1 else current.column,
                .text = current.text,
            },
            catalog.semantic.invalid_argument_count.code,
            message,
            "implicit external actual conflicts here",
            advice.notes,
            advice.helps,
            related[0..],
            "previous implicit external actual here",
        );
        return;
    }
    self.setDiagnosticDetailed(
        if (current.line == 0) 1 else current.line,
        if (current.column == 0) 1 else current.column,
        catalog.semantic.invalid_argument_count.code,
        message,
        current.text,
        advice.notes,
        advice.helps,
    );
}

fn emitImplicitObservedCallMismatch(
    self: *context.Context,
    current: ast.SourceRef,
    previous: ast.SourceRef,
    message: []const u8,
) void {
    const advice = implicitExternalCallAdvice();
    if (previous.line != 0 and previous.column != 0) {
        const related = [_]ast.DeclSource{.{
            .line = previous.line,
            .column = previous.column,
            .text = previous.text,
        }};
        emitStructuredProcedureDiagnostic(
            self,
            .{
                .line = if (current.line == 0) 1 else current.line,
                .column = if (current.column == 0) 1 else current.column,
                .text = current.text,
            },
            catalog.semantic.invalid_argument_count.code,
            message,
            "implicit external call conflicts here",
            advice.notes,
            advice.helps,
            related[0..],
            "previous implicit external call here",
        );
        return;
    }
    self.setDiagnosticDetailed(
        if (current.line == 0) 1 else current.line,
        if (current.column == 0) 1 else current.column,
        catalog.semantic.invalid_argument_count.code,
        message,
        current.text,
        advice.notes,
        advice.helps,
    );
}

fn implicitActualTypesCompatible(previous: symbols.TypeSpec, current: symbols.TypeSpec) bool {
    if (previous.lowered_kind != current.lowered_kind) return false;
    if (previous.lowered_kind == .character) {
        return previous.char_len_kind == current.char_len_kind and previous.char_len == current.char_len;
    }
    if (previous.lowered_kind != .derived) return true;
    if (previous.derived_type_name == null or current.derived_type_name == null) return false;
    return std.ascii.eqlIgnoreCase(previous.derived_type_name.?, current.derived_type_name.?);
}

