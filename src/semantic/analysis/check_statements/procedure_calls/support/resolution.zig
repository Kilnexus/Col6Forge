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
const sequence_association = @import("sequence_association.zig");
const actuals = @import("actuals.zig");
const type_kind_selector = @import("../../../../type_kind_selector.zig");

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
const bindCallActualsToFormals = sequence_association.bindCallActualsToFormals;
const procedureActualExprRank = actuals.procedureActualExprRank;
const sequenceAssociationAvailableElements = sequence_association.sequenceAssociationAvailableElements;
const formalRequiredElementCount = sequence_association.formalRequiredElementCount;

pub fn countCallExprArgs(args: []const ast.CallArg) usize {
    var count: usize = 0;
    for (args) |arg| {
        if (arg == .expr) count += 1;
    }
    return count;
}

pub fn minimumRequiredProcedureArgs(sig: context.Context.ProcedureSig) usize {
    if (sig.args.len == 0) return sig.arg_count;
    var required: usize = 0;
    for (sig.args) |arg| {
        if (!arg.optional) required += 1;
    }
    return required;
}

fn isNullPointerIntrinsic(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .call_or_subscript => |call| std.ascii.eqlIgnoreCase(call.name, "null"),
        else => false,
    };
}


pub fn lookupProcedureDeclaratorSig(self: *context.Context, name: []const u8) ?context.Context.ProcedureSig {
    for (self.unit.decls) |decl| {
        if (decl != .procedure) continue;
        const procedure_decl = decl.procedure;
        for (procedure_decl.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            return switch (procedure_decl.interface) {
                .name => |iface_name| resolve_symbols.lookupKnownProcedureSig(self, iface_name),
                .type_spec => |proc_type| .{
                    .kind = .function,
                    .arg_count = 0,
                    .result_type_spec = procedureDeclaratorTypeSpec(self, proc_type),
                },
                else => null,
            };
        }
    }
    return null;
}

pub fn procedureDeclaratorUsesTypeSpecInterface(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .procedure) continue;
        const procedure_decl = decl.procedure;
        for (procedure_decl.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            return procedure_decl.interface == .type_spec;
        }
    }
    return false;
}

fn procedureDeclaratorTypeSpec(
    self: *context.Context,
    proc_type: ast.ProcedureTypeSpec,
) symbols.TypeSpec {
    if (proc_type.type_kind == .derived) {
        const base = if (proc_type.derived_type_name) |derived_name|
            symbols.TypeSpec.fromDerived(derived_name)
        else
            symbols.TypeSpec.fromKind(.derived);
        return base.withPolymorphic(proc_type.polymorphic).withAssumedType(proc_type.assumed_type);
    }

    var resolved = if (proc_type.kind_selector) |selector|
        type_kind_selector.resolveSpecWithConst(proc_type.type_kind, selector, constants.evalConst(self, selector) catch null)
    else
        symbols.TypeSpec.fromResolvedKind(proc_type.type_kind, proc_type.type_kind, null);
    resolved = resolved.withPolymorphic(proc_type.polymorphic).withAssumedType(proc_type.assumed_type);
    return resolved;
}

pub fn resolvedProcedureSigForExprActuals(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
    comptime deps: anytype,
) !?context.Context.ProcedureSig {
    return resolvedProcedureSigForActualsGeneric(self, name, args, deps, .expr);
}

pub fn resolvedProcedureSigForCallActuals(
    self: *context.Context,
    name: []const u8,
    args: []const ast.CallArg,
    comptime deps: anytype,
) !?context.Context.ProcedureSig {
    return resolvedProcedureSigForActualsGeneric(self, name, args, deps, .call);
}

pub fn resolvedProcedureSig(self: *context.Context, name: []const u8) ?context.Context.ProcedureSig {
    return resolveProcedureSigWithVisibleGeneric(
        self,
        name,
        procedure_interfaces.visibleSpecificInterfaceSig(self, name) orelse
            procedure_interfaces.visibleSingleTargetGenericSig(self, name),
    );
}

fn resolveProcedureSigWithVisibleGeneric(
    self: *context.Context,
    name: []const u8,
    visible_generic_sig: ?context.Context.ProcedureSig,
) ?context.Context.ProcedureSig {
    return visible_generic_sig orelse
        resolve_symbols.lookupKnownProcedureSig(self, name) orelse
        lookupProcedureDeclaratorSig(self, name);
}

fn resolveProcedureSigForActuals(
    self: *context.Context,
    name: []const u8,
    visible_generic_sig: ?context.Context.ProcedureSig,
    prefer_intrinsic: bool,
) ?context.Context.ProcedureSig {
    if (prefer_intrinsic) return resolve_symbols.lookupKnownProcedureSig(self, name);
    return resolveProcedureSigWithVisibleGeneric(self, name, visible_generic_sig);
}

const ActualKind = enum {
    expr,
    call,
};

fn resolvedProcedureSigForActualsGeneric(
    self: *context.Context,
    name: []const u8,
    args: anytype,
    comptime deps: anytype,
    comptime actual_kind: ActualKind,
) !?context.Context.ProcedureSig {
    const visible_generic_sig = switch (actual_kind) {
        .expr => procedure_interfaces.visibleSpecificInterfaceSig(self, name) orelse
            procedure_interfaces.matchedVisibleGenericSigForExprArgs(self, name, args) orelse
            procedure_interfaces.visibleSingleTargetGenericSig(self, name),
        .call => procedure_interfaces.visibleSpecificInterfaceSig(self, name) orelse
            procedure_interfaces.matchedVisibleGenericSigForCallArgs(self, name, args) orelse
            procedure_interfaces.visibleSingleTargetGenericSig(self, name),
    };
    const prefer_intrinsic = switch (actual_kind) {
        .expr => try shouldFallbackVisibleGenericToIntrinsicForExprActuals(self, name, visible_generic_sig, args, deps),
        .call => try shouldFallbackVisibleGenericToIntrinsicForCallActuals(self, name, visible_generic_sig, args, deps),
    };
    return resolveProcedureSigForActuals(self, name, visible_generic_sig, prefer_intrinsic);
}

fn shouldFallbackVisibleGenericToIntrinsicForExprActuals(
    self: *context.Context,
    name: []const u8,
    visible_generic_sig: ?context.Context.ProcedureSig,
    args: []*ast.Expr,
    comptime deps: anytype,
) !bool {
    const sig = visible_generic_sig orelse return false;
    if (!resolve_symbols.isIntrinsicName(name)) return false;
    if (resolve_symbols.lookupKnownProcedureSig(self, name) == null) return false;
    return !(try exprActualsCouldMatchProcedureSig(self, sig, args, deps));
}

fn shouldFallbackVisibleGenericToIntrinsicForCallActuals(
    self: *context.Context,
    name: []const u8,
    visible_generic_sig: ?context.Context.ProcedureSig,
    args: []const ast.CallArg,
    comptime deps: anytype,
) !bool {
    const sig = visible_generic_sig orelse return false;
    if (!resolve_symbols.isIntrinsicName(name)) return false;
    if (resolve_symbols.lookupKnownProcedureSig(self, name) == null) return false;
    return !(try callActualsCouldMatchProcedureSig(self, sig, args, deps));
}

pub fn exprActualsCouldMatchProcedureSig(
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

pub fn callActualsCouldMatchProcedureSig(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    args: []const ast.CallArg,
    comptime deps: anytype,
) !bool {
    const got_expr = countCallExprArgs(args);
    var got_alt_return: usize = 0;
    for (args) |arg| {
        if (arg == .alt_return) got_alt_return += 1;
    }
    if (got_alt_return != sig.alt_return_count) return false;
    const min_count = minimumRequiredProcedureArgs(sig);
    if (got_expr < min_count or got_expr > sig.arg_count) return false;
    const bound_actuals = try bindCallActualsToFormals(self, sig, args);
    for (sig.args, 0..) |formal, idx| {
        const actual = bound_actuals[idx] orelse continue;
        if (!(try exprActualCouldMatchFormal(self, sig, formal, actual.value, deps))) return false;
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
    if (formal.pointer and isNullPointerIntrinsic(actual_expr)) return true;
    try resolve_expr.resolveExpr(self, actual_expr);
    const actual_rank = procedureActualExprRank(self, actual_expr);
    const actual_spec = try resolve_expr.exprTypeSpec(self, actual_expr);
    if (!deps.dummyArgTypeCompatible(self, formal.type_spec, actual_spec)) return false;
    if (formal.assumed_rank) return true;
    if (formal.rank == 0 and actual_rank > 0 and sig.elemental) return true;
    if (formal.rank == actual_rank) return true;
    if (formal.rank == 1 and !formal.requires_descriptor) {
        if (try sequenceAssociationAvailableElements(self, actual_expr)) |available_elements| {
            if (formalRequiredElementCount(formal)) |required_elements| {
                return available_elements >= required_elements;
            }
            return true;
        }
    }
    return false;
}
