const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const common_diag = @import("../../../../common/diagnostic.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const procedure_pass = @import("../../../../common/procedure_pass.zig");
const free_form = @import("../../../../frontend/free_form.zig");
const parser = @import("../../../../frontend/parser/mod.zig");
const symbols = @import("../../../symbol/mod.zig");
const procedure_inference = @import("../../../split/api/procedure_inference.zig");
const context = @import("../../context.zig");
const constants = @import("../../resolve_const.zig");
const resolve_expr = @import("../../resolve_expr.zig");
const resolve_symbols = @import("../../resolve_symbols.zig");
const abstract_expr_use = @import("../abstract_expr_use.zig");
const leaf_helpers = @import("../leaf_helpers.zig");
const procedure_call_actual_traits = @import("../procedure_call_actual_traits.zig");
const procedure_call_diagnostics = @import("../procedure_call_diagnostics.zig");
const procedure_interfaces = @import("../procedure_interfaces.zig");

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

const intrinsics = @import("support/intrinsics.zig");
const actuals = @import("support/actuals.zig");
const implicit_external = @import("support/implicit_external.zig");
const sequence_association = @import("support/sequence_association.zig");
const resolution = @import("support/resolution.zig");

pub const checkIntrinsicCallConstraintsForCallArgs = intrinsics.checkIntrinsicCallConstraintsForCallArgs;
pub const checkIntrinsicCallConstraintsForExprArgs = intrinsics.checkIntrinsicCallConstraintsForExprArgs;
const checkIntrinsicSpecialActualRestrictionsForCallArgs = intrinsics.checkIntrinsicSpecialActualRestrictionsForCallArgs;
const checkIntrinsicSpecialActualRestrictionsForExprArgs = intrinsics.checkIntrinsicSpecialActualRestrictionsForExprArgs;
const checkIntrinsicSpecialActualRestriction = intrinsics.checkIntrinsicSpecialActualRestriction;
const intrinsicAllowsNoArgCheck = intrinsics.intrinsicAllowsNoArgCheck;
const intrinsicAllowsAssumedRank = intrinsics.intrinsicAllowsAssumedRank;
const intrinsicAllowsAssumedType = intrinsics.intrinsicAllowsAssumedType;
const intrinsicAllowsInquiryArrayActual = intrinsics.intrinsicAllowsInquiryArrayActual;
const exprIsAssumedType = intrinsics.exprIsAssumedType;
const exprIsAssumedRank = intrinsics.exprIsAssumedRank;
const exprIsNoArgCheck = intrinsics.exprIsNoArgCheck;
const rootActualSymbolIndex = intrinsics.rootActualSymbolIndex;
const symbolIsAssumedRank = intrinsics.symbolIsAssumedRank;
const IntrinsicCallActual = intrinsics.IntrinsicCallActual;
const duplicateKeywordActual = intrinsics.duplicateKeywordActual;
const nthOrKeywordActual = intrinsics.nthOrKeywordActual;
const emitDuplicateIntrinsicKeywordDiagnostic = intrinsics.emitDuplicateIntrinsicKeywordDiagnostic;
const exprIsScalarIntegerVariableAtLeastKind = intrinsics.exprIsScalarIntegerVariableAtLeastKind;
const exprIsScalarCharacterVariableKindOne = intrinsics.exprIsScalarCharacterVariableKindOne;
const exprIsScalarCharacterKindOne = intrinsics.exprIsScalarCharacterKindOne;
const typeStringForCharacterActual = intrinsics.typeStringForCharacterActual;
const typeStringForProcedureTypeSpec = intrinsics.typeStringForProcedureTypeSpec;
const typeMismatchArgumentMessage = intrinsics.typeMismatchArgumentMessage;
const emitCharacterKindOneIntrinsicDiagnostic = intrinsics.emitCharacterKindOneIntrinsicDiagnostic;
const checkMoveAllocCallConstraints = intrinsics.checkMoveAllocCallConstraints;
const moveAllocViolatesIntentIn = intrinsics.moveAllocViolatesIntentIn;
const moveAllocDesignatorsConflict = intrinsics.moveAllocDesignatorsConflict;
const sameMoveAllocDesignator = intrinsics.sameMoveAllocDesignator;
const moveAllocAncestorOf = intrinsics.moveAllocAncestorOf;
const moveAllocParentDesignator = intrinsics.moveAllocParentDesignator;
const checkDateAndTimeCallConstraints = intrinsics.checkDateAndTimeCallConstraints;
const checkGetCommandCallConstraints = intrinsics.checkGetCommandCallConstraints;
const checkGetCommandArgumentCallConstraints = intrinsics.checkGetCommandArgumentCallConstraints;
const checkGetEnvironmentVariableCallConstraints = intrinsics.checkGetEnvironmentVariableCallConstraints;
const checkLegacyWidecharCallConstraints = intrinsics.checkLegacyWidecharCallConstraints;
const CFPointerActuals = intrinsics.CFPointerActuals;
const collectCFPointerActuals = intrinsics.collectCFPointerActuals;
const checkCFPointerCallConstraints = intrinsics.checkCFPointerCallConstraints;
const checkCFProcPointerCallConstraints = intrinsics.checkCFProcPointerCallConstraints;
const isIsoCBindingDerivedType = intrinsics.isIsoCBindingDerivedType;
const isoCBindingAliasMatches = intrinsics.isoCBindingAliasMatches;
const emitIntrinsicArgDiagnostic = intrinsics.emitIntrinsicArgDiagnostic;
const exprHasPointerAttribute = intrinsics.exprHasPointerAttribute;
const sourceFromDirectUseModule = actuals.sourceFromDirectUseModule;
const checkTypeBoundProcedureActual = actuals.checkTypeBoundProcedureActual;
const typeBoundProcedureSig = actuals.typeBoundProcedureSig;
const checkProcedureActualArg = actuals.checkProcedureActualArg;
const checkProcedureActualSigCompatibility = actuals.checkProcedureActualSigCompatibility;
pub const procedurePointerExprSig = actuals.procedurePointerExprSig;
const procedurePointerAssignmentValueSig = actuals.procedurePointerAssignmentValueSig;
const structureConstructorProcedureFormalArg = actuals.structureConstructorProcedureFormalArg;
const declareVariantAdjustKind = actuals.declareVariantAdjustKind;
const procedureComponentSig = actuals.procedureComponentSig;
const checkDataActualArgCompatibility = actuals.checkDataActualArgCompatibility;
const shouldWarnExternalExplicitInterfaceActualTypeMismatch = actuals.shouldWarnExternalExplicitInterfaceActualTypeMismatch;
const currentUnitDeclaresExternalProcedure = actuals.currentUnitDeclaresExternalProcedure;
const identifierIsProcedureDesignatorForDataActual = actuals.identifierIsProcedureDesignatorForDataActual;
pub const rejectDefinitelyNoncontiguousPointerAssociation = actuals.rejectDefinitelyNoncontiguousPointerAssociation;
const calleeAllowsElementalArrayActuals = actuals.calleeAllowsElementalArrayActuals;
const isNullPointerIntrinsic = actuals.isNullPointerIntrinsic;
const exprIsDeclaredContiguousPointerTarget = actuals.exprIsDeclaredContiguousPointerTarget;
const derivedComponentDeclaredContiguous = actuals.derivedComponentDeclaredContiguous;
const exprIsDefinitelyNoncontiguous = actuals.exprIsDefinitelyNoncontiguous;
const sectionIsDefinitelyNoncontiguous = actuals.sectionIsDefinitelyNoncontiguous;
const classifySectionArg = actuals.classifySectionArg;
const classifyDimRangeSection = actuals.classifyDimRangeSection;
const rangeMatchesWholeDimension = actuals.rangeMatchesWholeDimension;
const rangeExtent = actuals.rangeExtent;
pub const procedureActualExprRank = actuals.procedureActualExprRank;
const checkProcedureDummyCompatibility = actuals.checkProcedureDummyCompatibility;
const checkNestedProcedureDummyCompatibility = actuals.checkNestedProcedureDummyCompatibility;
const procedureDummyDataArgMismatchMessage = actuals.procedureDummyDataArgMismatchMessage;
const checkKnownImplicitProcedureScalarActualArgsForCall = actuals.checkKnownImplicitProcedureScalarActualArgsForCall;
const checkKnownImplicitProcedureScalarActualArgsForExprCall = actuals.checkKnownImplicitProcedureScalarActualArgsForExprCall;
const checkKnownImplicitProcedureScalarActualArg = actuals.checkKnownImplicitProcedureScalarActualArg;
const knownImplicitProcedureScalarTypeCheckEligibleActual = actuals.knownImplicitProcedureScalarTypeCheckEligibleActual;
const shapeSignatureMismatch = actuals.shapeSignatureMismatch;
const actualSigResultType = actuals.actualSigResultType;
const functionResultTypeMismatchMessage = actuals.functionResultTypeMismatchMessage;
const procedureKindMismatchMessage = actuals.procedureKindMismatchMessage;
const passingGlobalProcedureMessage = actuals.passingGlobalProcedureMessage;
const checkImplicitExternalCallConsistencyForCall = implicit_external.checkImplicitExternalCallConsistencyForCall;
const checkImplicitExternalCallConsistencyForExpr = implicit_external.checkImplicitExternalCallConsistencyForExpr;
const shouldTrackImplicitExternalCall = implicit_external.shouldTrackImplicitExternalCall;
const checkImplicitExternalCallConsistency = implicit_external.checkImplicitExternalCallConsistency;
const implicitActualArgSig = implicit_external.implicitActualArgSig;
const findImplicitCallSigPtr = implicit_external.findImplicitCallSigPtr;
const recordImplicitCallSig = implicit_external.recordImplicitCallSig;
const implicitExternalCallAdvice = implicit_external.implicitExternalCallAdvice;
const emitImplicitObservedArgumentMismatch = implicit_external.emitImplicitObservedArgumentMismatch;
const emitImplicitObservedCallMismatch = implicit_external.emitImplicitObservedCallMismatch;
const implicitActualTypesCompatible = implicit_external.implicitActualTypesCompatible;
const checkExplicitShapeElementSufficiency = sequence_association.checkExplicitShapeElementSufficiency;
const formalRequiredElementCount = sequence_association.formalRequiredElementCount;
const actualWholeArrayElementCount = sequence_association.actualWholeArrayElementCount;
pub const sequenceAssociationAvailableElements = sequence_association.sequenceAssociationAvailableElements;
const componentInfoForExpr = sequence_association.componentInfoForExpr;
const componentActualTypeCompatibleViaMetadata = sequence_association.componentActualTypeCompatibleViaMetadata;
const bindCallActualsToFormals = sequence_association.bindCallActualsToFormals;
const arrayElementCountForDims = sequence_association.arrayElementCountForDims;
const dimensionExtent = sequence_association.dimensionExtent;
const dimensionLowerBound = sequence_association.dimensionLowerBound;
const linearSubscriptOffset = sequence_association.linearSubscriptOffset;
const sectionHasArraySelection = sequence_association.sectionHasArraySelection;
const sectionElementCount = sequence_association.sectionElementCount;
const constIntValue = sequence_association.constIntValue;
const tripletExtent = sequence_association.tripletExtent;
const emitTooFewActualElementsDiagnostic = sequence_association.emitTooFewActualElementsDiagnostic;
const getLowercaseMapPtr = sequence_association.getLowercaseMapPtr;
const lookupProcedureDeclaratorSig = resolution.lookupProcedureDeclaratorSig;
const resolvedProcedureSigForExprActuals = resolution.resolvedProcedureSigForExprActuals;
const resolvedProcedureSigForCallActuals = resolution.resolvedProcedureSigForCallActuals;
const resolvedProcedureSig = resolution.resolvedProcedureSig;
const procedureDeclaratorUsesTypeSpecInterface = resolution.procedureDeclaratorUsesTypeSpecInterface;
const shouldFallbackVisibleGenericToIntrinsicForExprActuals = resolution.shouldFallbackVisibleGenericToIntrinsicForExprActuals;
const shouldFallbackVisibleGenericToIntrinsicForCallActuals = resolution.shouldFallbackVisibleGenericToIntrinsicForCallActuals;
const exprActualsCouldMatchProcedureSig = resolution.exprActualsCouldMatchProcedureSig;
const callActualsCouldMatchProcedureSig = resolution.callActualsCouldMatchProcedureSig;
const exprActualCouldMatchFormal = resolution.exprActualCouldMatchFormal;

pub fn identifierRequiresArgumentList(self: *context.Context, expr: *ast.Expr) bool {
    if (expr.* != .identifier) return false;
    const name = expr.identifier;
    if (resolvedProcedureSig(self, name)) |sig| {
        return sig.kind == .function;
    }
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    const sym = self.symbols.items[idx];
    return sym.kind == .function;
}

pub fn isNumeric(kind: ast.TypeKind) bool {
    return switch (kind) {
        .integer, .real, .double_precision, .complex, .complex_double => true,
        else => false,
    };
}

pub fn isIntegerLike(kind: ast.TypeKind) bool {
    return kind == .integer;
}

pub fn countCallExprArgs(args: []const ast.CallArg) usize {
    var count: usize = 0;
    for (args) |arg| {
        if (arg == .expr) count += 1;
    }
    return count;
}

pub fn collectCallExprArgsScratch(self: *context.Context, args: []const ast.CallArg) []*ast.Expr {
    const expr_count = countCallExprArgs(args);
    const exprs = self.arena.alloc(*ast.Expr, expr_count) catch return &.{};
    var out_idx: usize = 0;
    for (args) |arg| {
        switch (arg) {
            .expr => |actual| {
                exprs[out_idx] = actual.value;
                out_idx += 1;
            },
            .alt_return => {},
        }
    }
    return exprs;
}

fn rejectUndeclaredSelfProcedureActualForCall(
    self: *context.Context,
    callee_name: []const u8,
    args: []const ast.CallArg,
) CheckError!void {
    for (args) |arg| {
        if (arg != .expr) continue;
        try rejectUndeclaredSelfProcedureActual(self, callee_name, arg.expr.value);
    }
}

fn rejectUndeclaredSelfProcedureActualForExpr(
    self: *context.Context,
    callee_name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    for (args) |arg| {
        try rejectUndeclaredSelfProcedureActual(self, callee_name, arg);
    }
}

fn rejectUndeclaredSelfProcedureActual(
    self: *context.Context,
    callee_name: []const u8,
    actual: *ast.Expr,
) CheckError!void {
    if (actual.* != .identifier) return;
    const actual_name = actual.identifier;
    if (!std.ascii.eqlIgnoreCase(actual_name, callee_name)) return;
    if (currentUnitDeclaresExternalProcedure(self, actual_name)) return;
    if (!knownProcedureRequiresExternalActualDeclaration(self, actual_name)) return;

    const message = std.fmt.allocPrint(
        self.arena,
        "Procedure '{s}' used as actual argument must be explicitly declared EXTERNAL",
        .{actual_name},
    ) catch "procedure used as actual argument must be explicitly declared EXTERNAL";
    return emitProcedureActualDiagnostic(self, actual, error.InvalidArgumentCount, message);
}

fn knownProcedureRequiresExternalActualDeclaration(self: *context.Context, name: []const u8) bool {
    if (procedure_interfaces.findVisibleProcedureSource(self, name) != null) return false;
    if (resolve_symbols.lookupKnownProcedureSig(self, name) != null) return true;
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    const sym = self.symbols.items[idx];
    if (sym.storage == .dummy or sym.is_host_associated or sym.is_intrinsic) return false;
    return sym.kind == .function or sym.kind == .subroutine;
}

pub fn checkProcedureActualArgsForCall(
    self: *context.Context,
    callee_name: []const u8,
    args: []const ast.CallArg,
    comptime deps: anytype,
) CheckError!void {
    try rejectUndeclaredSelfProcedureActualForCall(self, callee_name, args);
    try checkImplicitExternalCallConsistencyForCall(self, callee_name, args);
    const sig = try resolvedProcedureSigForCallActuals(self, callee_name, args, deps) orelse return;
    if (resolve_symbols.isIntrinsicName(callee_name) and !(try callActualsCouldMatchProcedureSig(self, sig, args, deps))) return;
    if (!procedure_interfaces.calleeHasVisibleExplicitInterface(self, callee_name)) {
        try checkKnownImplicitProcedureScalarActualArgsForCall(self, sig, args, deps);
        return;
    }
    if (sig.args.len == 0) return;
    const bound_actuals = try bindCallActualsToFormals(self, sig, args);
    for (sig.args, 0..) |formal, formal_idx| {
        const actual = bound_actuals[formal_idx] orelse continue;
        if (declareVariantAdjustKind(self, callee_name, formal.name)) |kind| {
            if (kind != .nothing) {
                try resolve_expr.resolveExpr(self, actual.value);
                continue;
            }
        }
        try checkProcedureActualArg(self, callee_name, formal, actual.value, deps);
    }
}

pub fn checkProcedureActualArgsForExprCall(
    self: *context.Context,
    callee_name: []const u8,
    args: []*ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    try rejectUndeclaredSelfProcedureActualForExpr(self, callee_name, args);
    try checkImplicitExternalCallConsistencyForExpr(self, callee_name, args);
    const sig = try resolvedProcedureSigForExprActuals(self, callee_name, args, deps) orelse return;
    if (resolve_symbols.isIntrinsicName(callee_name) and !(try exprActualsCouldMatchProcedureSig(self, sig, args, deps))) return;
    if (!procedure_interfaces.calleeHasVisibleExplicitInterface(self, callee_name)) {
        try checkKnownImplicitProcedureScalarActualArgsForExprCall(self, sig, args, deps);
        return;
    }
    if (sig.args.len == 0) return;
    const count = @min(sig.args.len, args.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        if (declareVariantAdjustKind(self, callee_name, sig.args[idx].name)) |kind| {
            if (kind != .nothing) {
                try resolve_expr.resolveExpr(self, args[idx]);
                continue;
            }
        }
        try checkProcedureActualArg(self, callee_name, sig.args[idx], args[idx], deps);
    }
}

pub fn checkTypeBoundProcedureComponent(
    self: *context.Context,
    passed_object: *ast.Expr,
    binding: context.Context.DerivedTypeInfo.BindingInfo,
    args: []*ast.Expr,
    is_call_stmt: bool,
    comptime deps: anytype,
) CheckError!void {
    if (abstractPassedObjectTypeName(self, passed_object)) |derived_name| {
        return emitAbstractPassedObjectDiagnostic(
            self,
            passed_object,
            derived_name,
            if (is_call_stmt) error.InvalidArgumentCount else error.InvalidSubscript,
        );
    }
    const sig = typeBoundProcedureSig(self, binding) orelse {
        return if (is_call_stmt)
            emitProcedureActualDiagnostic(self, passed_object, error.InvalidArgumentCount, "should be a SUBROUTINE")
        else
            emitProcedureActualDiagnostic(self, passed_object, error.InvalidSubscript, "should be a FUNCTION");
    };
    if (self.unit.pure and !sig.pure) {
        return if (is_call_stmt)
            emitProcedureActualDiagnostic(self, passed_object, error.InvalidArgumentCount, "is not PURE")
        else
            emitProcedureActualDiagnostic(self, passed_object, error.InvalidSubscript, "Reference to impure function");
    }
    if (is_call_stmt and sig.kind != .subroutine) {
        return emitProcedureActualDiagnostic(self, passed_object, error.InvalidArgumentCount, "should be a SUBROUTINE");
    }
    if (!is_call_stmt and sig.kind != .function) {
        return emitProcedureActualDiagnostic(self, passed_object, error.InvalidSubscript, "should be a FUNCTION");
    }
    if (binding.nopass and resolve_expr.exprRank(self, passed_object) != 0) {
        return emitProcedureActualDiagnostic(self, passed_object, error.InvalidArgumentCount, "must be scalar");
    }

    const actual_count = args.len + @as(usize, if (binding.nopass) 0 else 1);
    const min_count = minimumRequiredProcedureArgs(sig);
    if (actual_count < min_count or actual_count > sig.arg_count) {
        return error.InvalidArgumentCount;
    }

    const pass_idx = if (binding.nopass) null else procedure_pass.procedurePassArgIndex(sig.args, binding.pass_name);
    var actual_idx: usize = 0;
    var formal_idx: usize = 0;
    while (formal_idx < sig.args.len) : (formal_idx += 1) {
        if (pass_idx != null and formal_idx == pass_idx.?) {
            try checkTypeBoundProcedureActual(self, sig.args[formal_idx], passed_object, deps);
            continue;
        }
        if (actual_idx >= args.len) break;
        try checkTypeBoundProcedureActual(self, sig.args[formal_idx], args[actual_idx], deps);
        actual_idx += 1;
    }
}

pub fn checkProcedureComponent(
    self: *context.Context,
    passed_object: *ast.Expr,
    component: context.Context.DerivedTypeInfo.ComponentInfo,
    args: []*ast.Expr,
    is_call_stmt: bool,
    comptime deps: anytype,
) CheckError!void {
    const sig = procedureComponentSig(self, component);
    const procedure_kind = if (sig) |resolved_sig| resolved_sig.kind else component.procedure_kind orelse {
        return if (is_call_stmt)
            emitProcedureActualDiagnostic(self, passed_object, error.InvalidArgumentCount, "should be a SUBROUTINE")
        else
            emitProcedureActualDiagnostic(self, passed_object, error.InvalidSubscript, "should be a FUNCTION");
    };
    if (sig) |resolved_sig| {
        if (self.unit.pure and !resolved_sig.pure) {
            return if (is_call_stmt)
                emitProcedureActualDiagnostic(self, passed_object, error.InvalidArgumentCount, "is not PURE")
            else
                emitProcedureActualDiagnostic(self, passed_object, error.InvalidSubscript, "Reference to impure function");
        }
    }
    if (is_call_stmt and procedure_kind != .subroutine) {
        return emitProcedureActualDiagnostic(self, passed_object, error.InvalidArgumentCount, "should be a SUBROUTINE");
    }
    if (!is_call_stmt and procedure_kind != .function) {
        return emitProcedureActualDiagnostic(self, passed_object, error.InvalidSubscript, "should be a FUNCTION");
    }
    if (component.procedure_nopass and resolve_expr.exprRank(self, passed_object) != 0) {
        return emitProcedureActualDiagnostic(self, passed_object, error.InvalidArgumentCount, "must be scalar");
    }
    if (!component.procedure_has_explicit_interface) return;

    const resolved_sig = sig orelse return;

    const actual_count = args.len + @as(usize, if (component.procedure_nopass) 0 else 1);
    const min_count = minimumRequiredProcedureArgs(resolved_sig);
    if (actual_count < min_count or actual_count > resolved_sig.arg_count) {
        return error.InvalidArgumentCount;
    }

    const pass_idx = if (component.procedure_nopass) null else procedure_pass.procedurePassArgIndex(resolved_sig.args, component.procedure_pass_name);
    var actual_idx: usize = 0;
    var formal_idx: usize = 0;
    while (formal_idx < resolved_sig.args.len) : (formal_idx += 1) {
        if (pass_idx != null and formal_idx == pass_idx.?) {
            try checkTypeBoundProcedureActual(self, resolved_sig.args[formal_idx], passed_object, deps);
            continue;
        }
        if (actual_idx >= args.len) break;
        try checkTypeBoundProcedureActual(self, resolved_sig.args[formal_idx], args[actual_idx], deps);
        actual_idx += 1;
    }
}

pub fn isTypeBoundProcedurePointerResult(self: *context.Context, comp: ast.ComponentExpr) bool {
    const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch return false;
    if (base_spec.lowered_kind != .derived) return false;
    const derived_name = base_spec.derived_type_name orelse return false;
    const binding = resolve_symbols.lookupDerivedBinding(self, derived_name, comp.name) orelse return false;
    const sig = typeBoundProcedureSig(self, binding) orelse return false;
    return sig.kind == .function and sig.is_pointer;
}

pub fn checkProcedurePointerAssignmentCompatibility(
    self: *context.Context,
    target_expr: *ast.Expr,
    value_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    try rejectArrayPassedObjectProcedureComponentPointerAssignment(self, target_expr);
    const target_sig = procedurePointerExprSig(self, target_expr) orelse return;
    const value_sig = procedurePointerAssignmentValueSig(self, value_expr) orelse return;
    if (value_sig.elemental and !procedurePointerAssignmentValueIsIntrinsic(value_expr)) {
        const proc_name = procedurePointerAssignmentValueName(value_expr) orelse "procedure";
        const message = std.fmt.allocPrint(
            self.arena,
            "Nonintrinsic elemental procedure '{s}' is invalid in procedure pointer assignment",
            .{proc_name},
        ) catch "Nonintrinsic elemental procedure is invalid in procedure pointer assignment";
        return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, message);
    }
    if (target_sig.pure and !value_sig.pure and !procedurePointerAssignmentValueIsIntrinsic(value_expr)) {
        return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Mismatch in PURE attribute");
    }
    const target_uses_type_spec_interface = procedurePointerAssignmentUsesTypeSpecInterface(self, target_expr);
    if (target_sig.kind != value_sig.kind) {
        if (target_uses_type_spec_interface) {
            return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "is invalid in procedure pointer assignment");
        }
        return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, procedureKindMismatchMessage(target_sig.kind));
    }
    if (!target_uses_type_spec_interface) {
        if (target_sig.arg_count != value_sig.arg_count or target_sig.alt_return_count != value_sig.alt_return_count) {
            return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "wrong number of arguments");
        }

        const count = @min(target_sig.args.len, value_sig.args.len);
        var idx: usize = 0;
        while (idx < count) : (idx += 1) {
            const expected = target_sig.args[idx];
            const actual = value_sig.args[idx];
            if (expected.is_procedure != actual.is_procedure) {
                return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Interface mismatch in procedure pointer assignment");
            }
            if (expected.optional != actual.optional) {
                return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Interface mismatch in procedure pointer assignment");
            }
            if (expected.intent != null and actual.intent != null and expected.intent.? != actual.intent.?) {
                return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Interface mismatch in procedure pointer assignment");
            }
            if (!expected.is_procedure and procedureDummyDataArgMismatchMessage(self, expected, actual, deps) != null) {
                return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Interface mismatch in procedure pointer assignment");
            }
        }
    }
    if (target_sig.result_rank != value_sig.result_rank) {
        return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Type mismatch in function result");
    }
    if (target_sig.result_type_spec != null and value_sig.result_type_spec != null) {
        if (!deps.dummyArgTypeCompatible(self, target_sig.result_type_spec.?, value_sig.result_type_spec.?)) {
            return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Type mismatch in function result");
        }
    }
}

fn procedurePointerAssignmentValueName(expr: *ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .identifier => |name| name,
        .call_or_subscript => |call| call.name,
        else => null,
    };
}

fn procedurePointerAssignmentValueIsIntrinsic(expr: *ast.Expr) bool {
    const name = procedurePointerAssignmentValueName(expr) orelse return false;
    return resolve_symbols.isIntrinsicName(name);
}

fn procedurePointerAssignmentUsesTypeSpecInterface(
    self: *context.Context,
    target_expr: *ast.Expr,
) bool {
    return switch (target_expr.*) {
        .identifier => |name| procedureDeclaratorUsesTypeSpecInterface(self, name),
        else => false,
    };
}

pub fn validateProcedurePointerAssignmentValue(
    self: *context.Context,
    value_expr: *ast.Expr,
) CheckError!void {
    if (isNullPointerIntrinsic(value_expr)) return;
    if (procedurePointerAssignmentValueSig(self, value_expr) != null) return;
    switch (value_expr.*) {
        .identifier => |name| {
            if (resolvedProcedureSig(self, name) != null) return;
            if (procedure_interfaces.hasVisibleProcedureReference(self, name)) return;
            if (resolve_symbols.isIntrinsicName(name)) return;
        },
        .call_or_subscript => |call| {
            if (resolvedProcedureSig(self, call.name)) |sig| {
                if (sig.result_procedure_pointer) return;
                if (sig.kind == .function) {
                    return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Type mismatch in function result");
                }
            }
            if (!resolve_symbols.isIntrinsicName(call.name)) {
                if (procedure_interfaces.hasVisibleProcedureReference(self, call.name)) {
                    return emitProcedureActualDiagnostic(self, value_expr, error.InvalidArgumentCount, "Type mismatch in function result");
                }
            }
        },
        else => {},
    }
    return emitProcedureActualDiagnostic(self, value_expr, error.AssignmentTypeMismatch, "Invalid procedure pointer assignment");
}

pub fn checkStructureConstructorProcedureComponentActual(
    self: *context.Context,
    component: context.Context.DerivedTypeInfo.ComponentInfo,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    if (!component.procedure or !component.procedure_has_explicit_interface) return;
    const target_sig = procedureComponentSig(self, component) orelse return;
    const actual_sig = procedurePointerExprSig(self, actual_expr) orelse
        return emitProcedureActualDiagnostic(self, actual_expr, error.InvalidArgumentCount, "Type mismatch in argument");
    const formal = structureConstructorProcedureFormalArg(component, target_sig);
    try checkProcedureActualSigCompatibility(self, null, formal, actual_sig, actual_expr, deps);
}

fn rejectArrayPassedObjectProcedureComponentPointerAssignment(
    self: *context.Context,
    target_expr: *ast.Expr,
) CheckError!void {
    const comp = switch (target_expr.*) {
        .component => |comp| comp,
        else => return,
    };
    if (comp.has_parens) return;

    const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch return;
    if (base_spec.lowered_kind != .derived) return;
    const derived_name = base_spec.derived_type_name orelse return;
    const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse return;
    if (!component.procedure or component.procedure_nopass) return;
    if (resolve_expr.exprRank(self, comp.base) == 0) return;

    return emitProcedureActualDiagnostic(self, target_expr, error.InvalidArgumentCount, "must not have the POINTER attribute");
}

pub fn countCallAltReturnArgs(args: []ast.CallArg) usize {
    var count: usize = 0;
    for (args) |arg| {
        if (arg == .alt_return) count += 1;
    }
    return count;
}

pub fn checkKnownProcedureCallArity(
    self: *context.Context,
    name: []const u8,
    got_expr: usize,
    got_alt_return: usize,
    is_call_stmt: bool,
    symbol_idx: ?usize,
) CheckError!void {
    if (symbol_idx orelse resolve_symbols.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.storage == .dummy) return;
    }

    if (leaf_helpers.lookupIntrinsicArity(self, name)) |arity| {
        if (got_alt_return != 0) {
            return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "wrong number of arguments");
        }
        if (got_expr < arity.min) {
            return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "Missing actual argument");
        }
        if (arity.max) |max| {
            if (got_expr > max) return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "wrong number of arguments");
        }
        return;
    }

    if (!procedure_interfaces.calleeHasVisibleExplicitInterface(self, name)) return;

    if (resolvedProcedureSig(self, name)) |sig| {
        if (is_call_stmt and sig.kind != .subroutine) {
            return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "actual argument is not a subroutine");
        }
        if (!is_call_stmt and sig.kind != .function) {
            return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "actual argument is not a function");
        }
        const min_expr = minimumRequiredProcedureArgs(sig);
        if (got_expr < min_expr) {
            return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "Missing actual argument");
        }
        if (got_expr > sig.arg_count) {
            return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "wrong number of arguments");
        }
        if (is_call_stmt and got_alt_return != sig.alt_return_count) {
            return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "wrong number of arguments");
        }
        if (!is_call_stmt and got_alt_return != 0) {
            return emitNamedProcedureDiagnostic(self, name, error.InvalidArgumentCount, "wrong number of arguments");
        }
        return;
    }
}

pub fn emitNamedProcedureDiagnostic(
    self: *context.Context,
    name: []const u8,
    err: anyerror,
    message: []const u8,
) CheckError {
    const advice = invalidArgumentAdvice();
    const primary = currentProcedureDiagnosticSource(self) orelse return err;
    const related_source = procedure_interfaces.findVisibleProcedureSource(self, name);
    if (related_source) |decl_source| {
        const related = [_]ast.DeclSource{decl_source};
        emitStructuredProcedureDiagnostic(
            self,
            primary,
            catalog.semantic.invalid_argument_count.code,
            message,
            "call site conflicts here",
            advice.notes,
            advice.helps,
            related[0..],
            "visible interface here",
        );
        return err;
    }
    self.setDiagnosticDetailed(
        primary.line,
        primary.column,
        catalog.semantic.invalid_argument_count.code,
        message,
        primary.text,
        advice.notes,
        advice.helps,
    );
    return err;
}

pub fn emitAmbiguousReferenceDiagnostic(self: *context.Context, name: []const u8) void {
    const primary = currentProcedureDiagnosticSource(self) orelse return;
    const advice = ambiguousReferenceAdvice();
    var sources = std.array_list.Managed(ast.DeclSource).init(self.arena);
    appendPreludeSpecificInterfaceSources(self, &sources, name) catch {};
    if (sources.items.len != 0) {
        emitStructuredProcedureDiagnostic(
            self,
            primary,
            catalog.semantic.duplicate_declaration.code,
            "ambiguous reference",
            "ambiguous reference here",
            advice.notes,
            advice.helps,
            sources.items,
            "conflicting visible procedure here",
        );
        return;
    }
    self.setDiagnosticDetailed(
        primary.line,
        primary.column,
        catalog.semantic.duplicate_declaration.code,
        "ambiguous reference",
        primary.text,
        advice.notes,
        advice.helps,
    );
}

pub fn emitAmbiguousVisibleGenericDiagnostic(
    self: *context.Context,
    name: []const u8,
    err: anyerror,
) CheckError {
    const primary = currentProcedureDiagnosticSource(self) orelse return err;
    const advice = ambiguousVisibleGenericAdvice();
    var sources = std.array_list.Managed(ast.DeclSource).init(self.arena);
    procedure_interfaces.appendAmbiguousVisibleGenericSpecificSources(self, &sources, name) catch {};
    if (sources.items.len != 0) {
        emitStructuredProcedureDiagnostic(
            self,
            primary,
            catalog.semantic.duplicate_declaration.code,
            "Ambiguous interfaces",
            "call site conflicts here",
            advice.notes,
            advice.helps,
            sources.items,
            "conflicting visible generic specific here",
        );
        return err;
    }
    self.setDiagnosticDetailed(
        primary.line,
        primary.column,
        catalog.semantic.duplicate_declaration.code,
        "Ambiguous interfaces",
        primary.text,
        advice.notes,
        advice.helps,
    );
    return err;
}

fn currentProcedureDiagnosticSource(self: *context.Context) ?DiagnosticSource {
    if (self.current_source) |src| {
        return .{
            .line = if (src.line == 0) 1 else src.line,
            .column = if (src.column == 0) 1 else src.column,
            .text = src.text,
        };
    }
    if (self.current_stmt) |stmt| {
        return .{
            .line = if (stmt.source_line == 0) 1 else stmt.source_line,
            .column = if (stmt.source_column == 0) 1 else stmt.source_column,
            .text = stmt.source_text,
        };
    }
    return null;
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

fn ambiguousReferenceAdvice() struct {
    notes: []const common_diag.DiagnosticMessage,
    helps: []const common_diag.DiagnosticMessage,
} {
    return .{
        .notes = &[_]common_diag.DiagnosticMessage{
            .{ .text = "this reference resolves to more than one visible procedure with the same name" },
        },
        .helps = &[_]common_diag.DiagnosticMessage{
            .{ .text = "rename one declaration or avoid importing conflicting unnamed interfaces into the same scope" },
        },
    };
}

fn ambiguousVisibleGenericAdvice() struct {
    notes: []const common_diag.DiagnosticMessage,
    helps: []const common_diag.DiagnosticMessage,
} {
    return .{
        .notes = &[_]common_diag.DiagnosticMessage{
            .{ .text = "visible generic interface specifics are indistinguishable for this call" },
        },
        .helps = &[_]common_diag.DiagnosticMessage{
            .{ .text = "make one specific distinguishable by required dummy arguments or avoid importing conflicting generic interfaces" },
        },
    };
}

pub fn checkExplicitInterfaceRequirementForCallArgs(
    self: *context.Context,
    name: []const u8,
    args: []const ast.CallArg,
    symbol_idx: ?usize,
) CheckError!void {
    if (leaf_helpers.lookupIntrinsicArity(self, name) != null) return;
    if (procedure_interfaces.calleeHasVisibleExplicitInterface(self, name)) return;
    if (procedure_interfaces.calleeRequiresExplicitInterface(self, name)) {
        return error.ExplicitInterfaceRequired;
    }
    const has_procedure_actual = hasProcedureActualCallArg(self, args);
    const has_interface_sensitive_actual = hasExplicitInterfaceSensitiveCallArg(self, args);
    const has_keyword_actual = hasKeywordActualCallArg(args);
    if (symbol_idx orelse resolve_symbols.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.is_intrinsic or (sym.is_external and !has_procedure_actual and !has_interface_sensitive_actual and !has_keyword_actual)) return;
    }
    if (has_keyword_actual) {
        return error.ExplicitInterfaceRequired;
    }
    for (args) |arg| {
        if (arg != .expr) continue;
        if (procedure_interfaces.isProcedureActualExpr(self, arg.expr.value)) {
            self.setCurrentSource(self.sourceForExpr(arg.expr.value));
            return emitProcedureActualDiagnostic(self, arg.expr.value, error.InvalidArgumentCount, "Interface mismatch in dummy procedure");
        }
        if (procedure_interfaces.requiresExplicitInterfaceForActual(self, arg.expr.value)) {
            self.setCurrentSource(self.sourceForExpr(arg.expr.value));
            if (procedure_interfaces.explicitInterfaceRestrictionMessageForActual(self, arg.expr.value)) |message| {
                return emitProcedureActualDiagnostic(self, arg.expr.value, error.InvalidArgumentCount, message);
            }
            return error.ExplicitInterfaceRequired;
        }
    }
}

pub fn minimumRequiredProcedureArgs(sig: context.Context.ProcedureSig) usize {
    if (sig.args.len == 0) return sig.arg_count;
    var required: usize = 0;
    for (sig.args) |arg| {
        if (!arg.optional) required += 1;
    }
    return required;
}

pub fn checkExplicitInterfaceRequirementForExprArgs(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
    symbol_idx: ?usize,
) CheckError!void {
    if (leaf_helpers.lookupIntrinsicArity(self, name) != null) return;
    if (procedure_interfaces.calleeHasVisibleExplicitInterface(self, name)) return;
    if (procedure_interfaces.calleeRequiresExplicitInterface(self, name)) {
        return error.ExplicitInterfaceRequired;
    }
    const has_procedure_actual = hasProcedureActualExprArg(self, args);
    const has_interface_sensitive_actual = hasExplicitInterfaceSensitiveExprArg(self, args);
    if (symbol_idx orelse resolve_symbols.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.is_intrinsic or (sym.is_external and !has_procedure_actual and !has_interface_sensitive_actual)) return;
    }
    for (args) |arg| {
        if (procedure_interfaces.requiresExplicitInterfaceForActual(self, arg)) {
            self.setCurrentSource(self.sourceForExpr(arg));
            if (procedure_interfaces.isProcedureActualExpr(self, arg)) {
                return emitProcedureActualDiagnostic(self, arg, error.InvalidArgumentCount, "Interface mismatch in dummy procedure");
            }
            if (procedure_interfaces.explicitInterfaceRestrictionMessageForActual(self, arg)) |message| {
                return emitProcedureActualDiagnostic(self, arg, error.InvalidArgumentCount, message);
            }
            return error.ExplicitInterfaceRequired;
        }
    }
}

pub fn hasVisibleGenericInterface(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (std.ascii.eqlIgnoreCase(interface_name, name)) return true;
    }
    return false;
}

pub fn preludeSpecificInterfaceProcedureCount(self: *context.Context, name: []const u8) usize {
    var count: usize = 0;
    var decl_idx: usize = 0;
    while (decl_idx < self.unit.prelude_decl_count and decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        const decl = self.unit.decls[decl_idx];
        if (decl != .interface_block) continue;
        if (decl.interface_block.name != null) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (std.ascii.eqlIgnoreCase(proc_header.name, name)) count += 1;
        }
        for (decl.interface_block.procedures) |proc_name| {
            if (procedure_interfaces.interfaceBlockHasProcedureHeader(decl.interface_block, proc_name)) continue;
            if (std.ascii.eqlIgnoreCase(proc_name, name)) count += 1;
        }
        for (decl.interface_block.specific_procedures) |proc_name| {
            if (std.ascii.eqlIgnoreCase(proc_name, name)) count += 1;
        }
    }
    return count;
}

pub fn findPreludeSpecificInterfaceSource(self: *context.Context, name: []const u8) ?ast.DeclSource {
    var sources = std.array_list.Managed(ast.DeclSource).init(self.arena);
    appendPreludeSpecificInterfaceSources(self, &sources, name) catch return null;
    return if (sources.items.len != 0) sources.items[0] else null;
}

pub fn appendPreludeSpecificInterfaceSources(
    self: *context.Context,
    out: *std.array_list.Managed(ast.DeclSource),
    name: []const u8,
) !void {
    if (self.unit.is_module_procedure and std.ascii.eqlIgnoreCase(name, self.unit.name)) return;
    var decl_idx: usize = 0;
    while (decl_idx < self.unit.prelude_decl_count and decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        const decl = self.unit.decls[decl_idx];
        if (decl != .interface_block) continue;
        if (decl.interface_block.name != null) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (!std.ascii.eqlIgnoreCase(proc_header.name, name)) continue;
            try appendUniqueDeclSource(out, proc_header.source);
        }
        for (decl.interface_block.procedures, 0..) |proc_name, idx| {
            if (procedure_interfaces.interfaceBlockHasProcedureHeader(decl.interface_block, proc_name)) continue;
            if (!std.ascii.eqlIgnoreCase(proc_name, name)) continue;
            if (idx < decl.interface_block.procedure_sources.len) {
                try appendUniqueDeclSource(out, decl.interface_block.procedure_sources[idx]);
            }
        }
        for (decl.interface_block.specific_procedures, 0..) |proc_name, idx| {
            if (!std.ascii.eqlIgnoreCase(proc_name, name)) continue;
            if (idx < decl.interface_block.specific_procedure_sources.len) {
                try appendUniqueDeclSource(out, decl.interface_block.specific_procedure_sources[idx]);
            }
        }
    }
}

pub fn currentUnitConflictsWithPreludeProcedure(self: *context.Context, name: []const u8) bool {
    return findPreludeSpecificInterfaceSource(self, name) != null;
}

pub fn isCurrentUnitAmbiguousResultRef(self: *context.Context, expr: *ast.Expr) bool {
    const name = switch (expr.*) {
        .identifier => |ident| ident,
        else => return false,
    };
    if (!std.ascii.eqlIgnoreCase(name, self.unit.name)) return false;
    if (!currentUnitConflictsWithPreludeProcedure(self, name)) return false;
    emitAmbiguousReferenceDiagnostic(self, name);
    return true;
}

pub fn hasAmbiguousVisibleGenericInterface(self: *context.Context, name: []const u8) bool {
    var sources = std.array_list.Managed(ast.DeclSource).init(self.arena);
    procedure_interfaces.appendAmbiguousVisibleGenericSpecificSources(self, &sources, name) catch return false;
    if (sources.items.len == 0) return false;

    var has_direct_use_source = false;
    var has_non_direct_use_source = false;
    for (sources.items) |source| {
        if (sourceFromDirectUseModule(self, source)) {
            has_direct_use_source = true;
        } else {
            has_non_direct_use_source = true;
        }
        if (has_direct_use_source and has_non_direct_use_source) return false;
    }
    return true;
}
