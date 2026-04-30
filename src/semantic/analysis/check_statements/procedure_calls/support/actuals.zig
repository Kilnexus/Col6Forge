const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const symbols = @import("../../../../symbol/mod.zig");
const intrinsic_signature = @import("../../../../intrinsic_signature.zig");
const procedure_inference = @import("../../../../split/api/procedure_inference.zig");
const context = @import("../../../context.zig");
const resolve_expr = @import("../../../resolve_expr.zig");
const resolve_symbols = @import("../../../resolve_symbols.zig");
const assumed_size = @import("../../../assumed_size.zig");
const expr_attributes = @import("../../../expr_attributes.zig");
const abstract_expr_use = @import("../../abstract_expr_use.zig");
const leaf_helpers = @import("../../leaf_helpers.zig");
const procedure_call_actual_traits = @import("../../procedure_call_actual_traits.zig");
const procedure_call_diagnostics = @import("../../procedure_call_diagnostics.zig");
const procedure_interfaces = @import("../../procedure_interfaces.zig");
const allocatable_actuals = @import("allocatable_actuals.zig");
const do_actuals = @import("do_actuals.zig");
const intrinsics = @import("intrinsics.zig");
const pointer_dummy = @import("pointer_dummy.zig");
const resolution = @import("resolution.zig");
const sequence_association = @import("sequence_association.zig");

pub const CheckError = anyerror;
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
const lookupProcedureDeclaratorSig = resolution.lookupProcedureDeclaratorSig;
const resolvedProcedureSig = resolution.resolvedProcedureSig;
const typeMismatchArgumentMessage = intrinsics.typeMismatchArgumentMessage;
const componentInfoForExpr = sequence_association.componentInfoForExpr;
const componentActualTypeCompatibleViaMetadata = sequence_association.componentActualTypeCompatibleViaMetadata;
const dimensionLowerBound = sequence_association.dimensionLowerBound;
const constIntValue = sequence_association.constIntValue;
const sectionIsDefinitelyNoncontiguous = sequence_association.sectionIsDefinitelyNoncontiguous;
const rangeExtent = sequence_association.rangeExtent;
const checkExplicitShapeElementSufficiency = sequence_association.checkExplicitShapeElementSufficiency;
const sequenceAssociationAvailableElements = sequence_association.sequenceAssociationAvailableElements;
const formalRequiredElementCount = sequence_association.formalRequiredElementCount;
const emitTooFewActualElementsDiagnostic = sequence_association.emitTooFewActualElementsDiagnostic;
const actualHasVectorSubscript = sequence_association.actualHasVectorSubscript;
const actualIsPointerArray = sequence_association.actualIsPointerArray;
const actualIsArraySection = sequence_association.actualIsArraySection;

pub fn sourceFromDirectUseModule(self: *context.Context, source: ast.DeclSource) bool {
    const owner_name = source.owner_name orelse return false;
    for (self.unit.stmts) |stmt_node| {
        if (stmt_node.node != .use_stmt) continue;
        if (std.ascii.eqlIgnoreCase(stmt_node.node.use_stmt.module_name, owner_name)) return true;
    }
    return false;
}

pub fn checkTypeBoundProcedureActual(
    self: *context.Context,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    if (formal.is_procedure) {
        return checkProcedureActualArg(self, null, formal, actual_expr, deps);
    }
    try abstract_expr_use.rejectNonpolymorphicAbstractExprUse(self, actual_expr, error.InvalidArgumentCount);
    const actual_spec = try resolve_expr.exprTypeSpec(self, actual_expr);
    if (!deps.dummyArgTypeCompatible(self, formal.type_spec, actual_spec)) {
        self.setCurrentSource(self.sourceForExpr(actual_expr));
        return error.ArgumentTypeMismatch;
    }
}

pub fn typeBoundProcedureSig(
    self: *context.Context,
    binding: context.Context.DerivedTypeInfo.BindingInfo,
) ?context.Context.ProcedureSig {
    const impl_name = binding.implementation_name orelse binding.name;
    if (binding.owner_name) |owner_name| {
        const qualified_impl = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, impl_name }) catch null;
        if (qualified_impl) |name| {
            if (resolve_symbols.lookupKnownProcedureSig(self, name)) |sig| return sig;
        }
        if (binding.interface_name) |iface_name| {
            const qualified_iface = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, iface_name }) catch null;
            if (qualified_iface) |name| {
                if (resolve_symbols.lookupKnownProcedureSig(self, name)) |sig| return sig;
            }
        }
    }
    return resolve_symbols.lookupKnownProcedureSig(self, impl_name) orelse
        (if (binding.interface_name) |iface_name| resolve_symbols.lookupKnownProcedureSig(self, iface_name) else null) orelse
        resolve_symbols.lookupKnownProcedureSig(self, binding.name);
}

pub fn checkProcedureActualArg(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    try abstract_expr_use.rejectNonpolymorphicAbstractExprUse(self, actual_expr, error.InvalidArgumentCount);
    if (!formal.is_procedure) {
        return checkDataActualArgCompatibility(self, callee_name, formal, actual_expr, deps);
    }
    switch (actual_expr.*) {
        .component => |comp| {
            if (comp.has_parens) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Expected a procedure for argument");
            }
            const actual_sig = procedurePointerExprSig(self, actual_expr) orelse {
                if (formal.procedure_kind == .function) {
                    return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "actual argument is not a function");
                }
                return;
            };
            return checkProcedureActualSigCompatibility(self, callee_name, formal, actual_sig, actual_expr, deps);
        },
        .identifier => |name| {
            const actual_sig = resolve_symbols.lookupKnownProcedureSig(self, name) orelse lookupProcedureDeclaratorSig(self, name);
            if (actual_sig) |sig| {
                if (sig.elemental and !resolve_symbols.isIntrinsicName(name)) {
                    return emitProcedureActualCallDiagnostic(
                        self,
                        callee_name,
                        formal.name,
                        actual_expr,
                        error.InvalidArgumentCount,
                        "not allowed as an actual argument",
                    );
                }
                return checkProcedureActualSigCompatibility(self, callee_name, formal, sig, actual_expr, deps);
            }

            if (leaf_helpers.lookupIntrinsicArity(self, name)) |arity| {
                if (formal.procedure_kind != null and formal.procedure_kind.? != .function) {
                    return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, procedureKindMismatchMessage(formal.procedure_kind.?));
                }
                if (!formal.procedure_has_explicit_interface) return;
                if (formal.procedure_arg_count < arity.min) {
                    return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "wrong number of arguments");
                }
                if (arity.max) |max| {
                    if (formal.procedure_arg_count > max) {
                        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "wrong number of arguments");
                    }
                }
                return;
            }

            if (resolve_symbols.findSymbolIndex(self, name)) |idx| {
                var sym = &self.symbols.items[idx];
                if (formal.procedure_kind) |expected_kind| {
                    switch (expected_kind) {
                        .function => {
                            if (sym.kind == .subroutine) {
                                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Passing global subroutine");
                            }
                            if (formal.procedure_arg_count != 0 or formal.procedure_alt_return_count != 0) {
                                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "actual argument is not a function");
                            }
                            if (formal.procedure_result_type_spec) |expected_result| {
                                if (functionResultTypeMismatchMessage(self, expected_result, sym.type_spec, deps)) |message| {
                                    return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, message);
                                }
                            }
                            if (formal.procedure_result_rank != sym.dims.len) {
                                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Rank mismatch in function result");
                            }
                            if (sym.kind == .variable) sym.kind = .function;
                            return;
                        },
                        .subroutine => {
                            if (sym.kind == .function or sym.type_explicit) {
                                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Passing global function");
                            }
                            if (sym.kind == .variable) sym.kind = .subroutine;
                            return;
                        },
                        else => {},
                    }
                }
            }

            if (formal.procedure_kind == .function) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "actual argument is not a function");
            }
        },
        .call_or_subscript => return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Expected a procedure for argument"),
        else => {
            if (formal.procedure_kind) |expected_kind| {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, procedureKindMismatchMessage(expected_kind));
            }
        },
    }
}

pub fn checkProcedureActualSigCompatibility(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    sig: context.Context.ProcedureSig,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    if (formal.procedure_kind) |expected_kind| {
        if (sig.kind != expected_kind) {
            return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, passingGlobalProcedureMessage(sig.kind));
        }
    }
    if (formal.procedure_pure and !sig.pure) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Mismatch in PURE attribute");
    }
    if (formal.procedure_result_type_spec) |expected_result| {
        if (sig.kind == .function) {
            const actual_result = actualSigResultType(sig);
            if (actual_result) |actual_result_spec| {
                if (functionResultTypeMismatchMessage(self, expected_result, actual_result_spec, deps)) |message| {
                    return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, message);
                }
            }
        }
    }
    if (formal.procedure_result_rank != sig.result_rank) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Rank mismatch in function result");
    }
    if (shapeSignatureMismatch(formal.procedure_result_shape_signature, sig.result_shape_signature)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Shape mismatch in function result");
    }
    if (formal.procedure_result_procedure_pointer != sig.result_procedure_pointer) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "PROCEDURE POINTER mismatch in function result");
    }
    if (formal.procedure_result_pointer != sig.is_pointer) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "POINTER attribute mismatch in function result");
    }
    if (formal.procedure_result_allocatable != sig.result_allocatable) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "ALLOCATABLE attribute mismatch in function result");
    }
    if (formal.procedure_result_contiguous != sig.result_contiguous) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "CONTIGUOUS attribute mismatch in function result");
    }
    if (formal.procedure_has_explicit_interface and
        (formal.procedure_arg_count != sig.arg_count or formal.procedure_alt_return_count != sig.alt_return_count))
    {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "wrong number of arguments");
    }
    if (formal.procedure_has_explicit_interface) {
        try checkProcedureDummyCompatibility(self, callee_name, formal, sig, actual_expr, deps);
    }
}

pub fn procedurePointerExprSig(
    self: *context.Context,
    expr_node: *ast.Expr,
) ?context.Context.ProcedureSig {
    return switch (expr_node.*) {
        .identifier => |name| blk: {
            if (lookupProcedureDeclaratorSig(self, name)) |sig| break :blk sig;
            if (currentFunctionResultDesignatorIsDataEntity(self, name)) break :blk null;
            break :blk resolve_symbols.lookupKnownProcedureSig(self, name);
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk null;
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk null;
            if (base_spec.lowered_kind != .derived) break :blk null;
            const derived_name = base_spec.derived_type_name orelse break :blk null;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk null;
            if (!component.procedure) break :blk null;
            if (procedureComponentSig(self, component)) |sig| break :blk sig;
            const kind = component.procedure_kind orelse break :blk null;
            break :blk .{
                .kind = kind,
                .arg_count = 0,
                .args = &.{},
                .result_type_spec = if (kind == .function) component.type_spec else null,
            };
        },
        else => null,
    };
}

fn currentFunctionResultDesignatorIsDataEntity(self: *context.Context, name: []const u8) bool {
    if (self.unit.kind != .function) return false;
    const result_name = self.unit.result_name orelse self.unit.name;
    if (!std.ascii.eqlIgnoreCase(name, result_name)) return false;
    if (self.unit.result_name == null and std.ascii.eqlIgnoreCase(name, self.unit.name)) return true;
    if (resolve_symbols.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.kind == .variable) return true;
        if (self.unit.result_name == null and std.ascii.eqlIgnoreCase(name, self.unit.name)) return true;
    }
    return false;
}

pub fn procedurePointerAssignmentValueSig(
    self: *context.Context,
    expr_node: *ast.Expr,
) ?context.Context.ProcedureSig {
    return switch (expr_node.*) {
        .identifier => |name| procedurePointerExprSig(self, expr_node) orelse intrinsicProcedurePointerSig(self, name),
        else => procedurePointerExprSig(self, expr_node),
    };
}

fn intrinsicProcedurePointerSig(
    self: *context.Context,
    name: []const u8,
) ?context.Context.ProcedureSig {
    if (!resolve_symbols.isIntrinsicName(name)) return null;
    const arity = leaf_helpers.lookupIntrinsicArity(self, name) orelse return null;
    const default_result = symbols.TypeSpec.fromResolvedKind(.real, .real, null);
    const result_spec = resolve_symbols.lookupKnownFunctionResolvedSpec(self, name) orelse
        (intrinsic_signature.inferResultType(name, default_result, &.{}) catch return null);
    return .{
        .kind = .function,
        .arg_count = arity.min,
        .alt_return_count = 0,
        .args = &.{},
        .result_type_spec = result_spec,
    };
}

pub fn structureConstructorProcedureFormalArg(
    component: context.Context.DerivedTypeInfo.ComponentInfo,
    sig: context.Context.ProcedureSig,
) context.Context.ProcedureSig.ArgSig {
    return .{
        .name = component.name,
        .type_spec = component.type_spec,
        .is_procedure = true,
        .procedure_kind = sig.kind,
        .procedure_pure = sig.pure,
        .procedure_has_explicit_interface = component.procedure_has_explicit_interface,
        .procedure_arg_count = sig.arg_count,
        .procedure_alt_return_count = sig.alt_return_count,
        .procedure_result_type_spec = sig.result_type_spec,
        .procedure_result_rank = sig.result_rank,
        .procedure_result_shape_signature = sig.result_shape_signature,
        .procedure_result_pointer = sig.is_pointer,
        .procedure_result_allocatable = sig.result_allocatable,
        .procedure_result_contiguous = sig.result_contiguous,
        .procedure_result_procedure_pointer = sig.result_procedure_pointer,
        .procedure_dummy_sigs = sig.args,
    };
}

pub fn declareVariantAdjustKind(
    self: *context.Context,
    callee_name: []const u8,
    formal_name: []const u8,
) ?context.Context.DeclareVariantAdjustArgKind {
    for (self.declare_variant_adjust_args) |adjust| {
        if (!std.ascii.eqlIgnoreCase(adjust.procedure_name, callee_name)) continue;
        if (!std.ascii.eqlIgnoreCase(adjust.arg_name, formal_name)) continue;
        return adjust.kind;
    }
    return null;
}

pub fn procedureComponentSig(
    self: *context.Context,
    component: context.Context.DerivedTypeInfo.ComponentInfo,
) ?context.Context.ProcedureSig {
    return component.procedure_sig orelse
        (if (component.interface_name) |iface_name| resolve_symbols.lookupKnownProcedureSig(self, iface_name) else null);
}

pub fn checkDataActualArgCompatibility(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    if (isNullPointerIntrinsic(actual_expr)) {
        if (nullPointerIntrinsicHasNoMold(actual_expr)) {
            if (formal.assumed_rank) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "NULL() without MOLD cannot be passed to assumed-rank dummy");
            }
            if (formal.type_spec.lowered_kind == .character and formal.type_spec.char_len_kind == .assumed) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "NULL() without MOLD cannot be passed to assumed-length dummy");
            }
        }
        if (formal.pointer or formal.optional) return;
    }
    if (actual_expr.* == .identifier and identifierIsProcedureDesignatorForDataActual(self, actual_expr.identifier)) {
        return emitProcedureActualCallDiagnostic(
            self,
            callee_name,
            formal.name,
            actual_expr,
            error.InvalidArgumentCount,
            "not allowed as an actual argument",
        );
    }
    try resolve_expr.resolveExpr(self, actual_expr);
    try do_actuals.rejectActiveDoControlForIntent(self, formal, actual_expr);
    if ((formal.intent == .out or formal.intent == .inout) and !exprIsVariableDefinitionActual(self, actual_expr)) {
        return emitVariableDefinitionContextDiagnostic(self, callee_name, formal.name, actual_expr);
    }
    const skip_no_arg_check_compat = formal.no_arg_check;
    const actual_rank = procedureActualExprRank(self, actual_expr);
    const actual_spec = try resolve_expr.exprTypeSpec(self, actual_expr);
    try allocatable_actuals.check(self, callee_name, formal, actual_expr, skip_no_arg_check_compat);
    if (!skip_no_arg_check_compat) {
        try checkAllocatablePolymorphicActualConstraint(self, callee_name, formal, actual_expr, actual_spec);
    }
    if (!skip_no_arg_check_compat and actual_spec.assumed_type and !formal.type_spec.assumed_type) {
        const message = std.fmt.allocPrint(
            self.arena,
            "Assumed-type actual argument at (1) requires that dummy argument '{s}' is of assumed type",
            .{formal.name},
        ) catch "Assumed-type actual argument requires assumed-type dummy";
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, message);
    }
    if (!skip_no_arg_check_compat and !deps.dummyArgTypeCompatible(self, formal.type_spec, actual_spec)) {
        if (!componentActualTypeCompatibleViaMetadata(self, formal.type_spec, actual_expr, deps)) {
            if (shouldWarnExternalExplicitInterfaceActualTypeMismatch(self, callee_name)) {
                emitProcedureActualCallWarning(
                    self,
                    callee_name,
                    formal.name,
                    actual_expr,
                    typeMismatchArgumentMessage(self, actual_spec, formal.type_spec),
                );
                return;
            }
            return emitProcedureActualCallDiagnostic(
                self,
                callee_name,
                formal.name,
                actual_expr,
                error.InvalidArgumentCount,
                typeMismatchArgumentMessage(self, actual_spec, formal.type_spec),
            );
        }
    }
    if (!skip_no_arg_check_compat and formal.pointer and formal.contiguous and exprIsDefinitelyNoncontiguous(self, actual_expr)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "must be simply contiguous");
    }
    try pointer_dummy.checkActual(self, callee_name, formal, actual_expr);
    try checkVolatileAndAsynchronousActualRestrictions(self, callee_name, formal, actual_expr);
    if (skip_no_arg_check_compat) return;
    if (formal.requires_descriptor and assumed_size.exprNeedsExplicitLastUpperBound(self, actual_expr)) return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "cannot be an assumed-size array");
    if (formal.assumed_rank) {
        try checkAssumedRankDummyActualConstraints(self, callee_name, formal, actual_expr, actual_spec);
        return;
    }
    if (formal.rank == 0 and actual_rank > 0 and calleeAllowsElementalArrayActuals(self, callee_name)) {
        if (assumed_size.exprNeedsExplicitLastUpperBound(self, actual_expr)) {
            return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "upper bound in the last dimension");
        }
        return;
    }
    if (formal.rank == actual_rank) {
        try checkExplicitShapeElementSufficiency(self, formal, actual_expr);
        return;
    }
    if (formal.rank == 1 and !formal.requires_descriptor) {
        if (try sequenceAssociationAvailableElements(self, actual_expr)) |available_elements| {
            if (formalRequiredElementCount(formal)) |required_elements| {
                if (available_elements < required_elements) {
                    return emitTooFewActualElementsDiagnostic(self, actual_expr, formal.name);
                }
            }
            return;
        }
    }
    return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Rank mismatch in argument");
}

fn checkVolatileAndAsynchronousActualRestrictions(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
) CheckError!void {
    if (formal.asynchronous and actualHasVectorSubscript(self, actual_expr)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "incompatible asynchronous actual argument");
    }
    if (!formal.volatile_attr or formal.requires_descriptor) return;
    if (actualIsPointerArray(self, actual_expr)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Pointer-array actual argument");
    }
    if (actualIsAssumedShapeOrRank(self, actual_expr)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Assumed-shape actual argument");
    }
    if (actualIsArraySection(actual_expr)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Array-section actual argument");
    }
}

fn checkAllocatablePolymorphicActualConstraint(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    actual_spec: symbols.TypeSpec,
) CheckError!void {
    if (!formal.allocatable or !formal.type_spec.polymorphic) return;
    if (formal.type_spec.lowered_kind != .derived or actual_spec.lowered_kind != .derived) return;

    if (!actual_spec.polymorphic) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "must be polymorphic");
    }
    if (!exprIsAllocatableActual(self, actual_expr)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "must be ALLOCATABLE");
    }

    const formal_name = formal.type_spec.derived_type_name orelse return;
    const actual_name = actual_spec.derived_type_name orelse return;
    if (!std.ascii.eqlIgnoreCase(formal_name, actual_name)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "must have the same declared type");
    }
}

fn checkAssumedRankDummyActualConstraints(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    actual_spec: symbols.TypeSpec,
) CheckError!void {
    if (actual_spec.assumed_type and !actualIsAssumedShapeOrRank(self, actual_expr)) {
        const message = std.fmt.allocPrint(
            self.arena,
            "Assumed-type actual argument at (1) corresponding to assumed-rank dummy argument '{s}' must be assumed-shape or assumed-rank",
            .{formal.name},
        ) catch "Assumed-type actual argument corresponding to assumed-rank dummy must be assumed-shape or assumed-rank";
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, message);
    }
    if (formal.intent != .out) return;
    if (!actualIsAssumedSizeOrRestrictedAssumedRank(self, actual_expr)) return;
    if (actual_spec.polymorphic or derivedTypeNeedsIntentOutAssumedRankProtection(self, actual_spec)) {
        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Assumed-rank actual argument is not permitted for this INTENT(OUT) dummy");
    }
}

fn actualIsAssumedShapeOrRank(self: *context.Context, expr_node: *ast.Expr) bool {
    const sym = rootActualSymbol(self, expr_node) orelse return false;
    return dimsRepresentAssumedRank(sym.dims) or dimsRepresentAssumedShape(sym.dims);
}

fn actualIsAssumedSizeOrRestrictedAssumedRank(self: *context.Context, expr_node: *ast.Expr) bool {
    if (assumed_size.exprHasAssumedSizeArray(self, expr_node)) return true;
    const sym = rootActualSymbol(self, expr_node) orelse return false;
    if (!dimsRepresentAssumedRank(sym.dims)) return false;
    return !sym.is_pointer and !sym.is_allocatable;
}

fn rootActualSymbol(self: *context.Context, expr_node: *ast.Expr) ?symbols.Symbol {
    const name = switch (expr_node.*) {
        .identifier => |ident| ident,
        else => return null,
    };
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return null;
    return self.symbols.items[idx];
}

fn dimsRepresentAssumedRank(dims: []const *ast.Expr) bool {
    if (dims.len != 1) return false;
    return switch (dims[0].*) {
        .dim_range => |range| range.from_dotdot,
        else => false,
    };
}

fn dimsRepresentAssumedShape(dims: []const *ast.Expr) bool {
    if (dims.len == 0) return false;
    for (dims) |dim| {
        if (dim.* != .dim_range or !dim.dim_range.assumed_shape) return false;
    }
    return true;
}

fn derivedTypeNeedsIntentOutAssumedRankProtection(self: *context.Context, spec: symbols.TypeSpec) bool {
    if (spec.lowered_kind != .derived) return false;
    const type_name = spec.derived_type_name orelse return false;
    const info = resolve_symbols.lookupDerivedType(self, type_name) orelse return false;
    if (info.final_subroutines.len != 0) return true;
    for (info.components) |component| {
        if (component.allocatable) return true;
    }
    if (assumed_size.derivedTypeHasDefaultInitializer(self, type_name)) return true;
    return false;
}

fn exprIsAllocatableActual(self: *context.Context, expr_node: *ast.Expr) bool {
    return expr_attributes.isAllocatableEntity(self, expr_node);
}

pub fn shouldWarnExternalExplicitInterfaceActualTypeMismatch(
    self: *context.Context,
    callee_name: ?[]const u8,
) bool {
    const name = callee_name orelse return false;
    if (!procedure_interfaces.calleeHasVisibleExplicitInterface(self, name)) return false;
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    const sym = self.symbols.items[idx];
    return sym.is_external and currentUnitDeclaresExternalProcedure(self, name);
}

pub fn currentUnitDeclaresExternalProcedure(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        switch (decl) {
            .external => |external_decl| {
                for (external_decl.names) |decl_name| {
                    if (std.ascii.eqlIgnoreCase(decl_name, name)) return true;
                }
            },
            .type_decl => |type_decl| {
                if (!type_decl.external) continue;
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

pub fn identifierIsProcedureDesignatorForDataActual(self: *context.Context, name: []const u8) bool {
    if (self.unit.kind == .function) {
        if (std.ascii.eqlIgnoreCase(name, self.unit.name)) return false;
        if (self.unit.result_name) |result_name| {
            if (std.ascii.eqlIgnoreCase(name, result_name)) return false;
        }
    }

    if (resolve_symbols.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.kind == .subroutine) return true;
        if (sym.kind == .function) {
            if (sym.storage == .dummy or sym.is_external or sym.is_host_associated or sym.is_intrinsic) return true;
            if (resolve_symbols.lookupKnownProcedureSig(self, name) != null) return true;
            if (lookupProcedureDeclaratorSig(self, name) != null) return true;
            return false;
        }
    }
    return resolve_symbols.lookupKnownProcedureSig(self, name) != null or
        lookupProcedureDeclaratorSig(self, name) != null;
}

pub fn rejectDefinitelyNoncontiguousPointerAssociation(
    self: *context.Context,
    target_expr: *ast.Expr,
    value_expr: *ast.Expr,
) CheckError!void {
    if (!exprIsDeclaredContiguousPointerTarget(self, target_expr)) return;
    if (!exprIsDefinitelyNoncontiguous(self, value_expr)) return;
    return emitProcedureActualDiagnostic(
        self,
        value_expr,
        error.AssignmentTypeMismatch,
        "Assignment to contiguous pointer from non-contiguous target",
    );
}

pub fn calleeAllowsElementalArrayActuals(self: *context.Context, callee_name: ?[]const u8) bool {
    const name = callee_name orelse return false;
    const sig = resolvedProcedureSig(self, name) orelse return false;
    return sig.elemental;
}

pub fn isNullPointerIntrinsic(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .call_or_subscript => |call| std.ascii.eqlIgnoreCase(call.name, "null"),
        else => false,
    };
}

fn nullPointerIntrinsicHasNoMold(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .call_or_subscript => |call| std.ascii.eqlIgnoreCase(call.name, "null") and call.args.len == 0,
        else => false,
    };
}

pub fn exprIsDeclaredContiguousPointerTarget(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.is_pointer and sym.contiguous;
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk false;
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk false;
            if (base_spec.lowered_kind != .derived) break :blk false;
            const derived_name = base_spec.derived_type_name orelse break :blk false;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk false;
            if (!component.pointer) break :blk false;
            break :blk derivedComponentDeclaredContiguous(self, derived_name, comp.name);
        },
        else => false,
    };
}

pub fn derivedComponentDeclaredContiguous(
    self: *context.Context,
    derived_name: []const u8,
    component_name: []const u8,
) bool {
    for (self.unit.decls) |decl| {
        if (decl != .derived_type_def) continue;
        if (!std.ascii.eqlIgnoreCase(decl.derived_type_def.name, derived_name)) continue;
        for (decl.derived_type_def.components) |component_decl| {
            if (!component_decl.contiguous) continue;
            for (component_decl.items) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, component_name)) return true;
            }
        }
        return false;
    }
    return false;
}

pub fn exprIsDefinitelyNoncontiguous(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .call_or_subscript => |call| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            const kind = self.ref_kind_index.get(@intFromPtr(expr)) orelse
                (if (sym.dims.len > 0) symbols.ResolvedRefKind.subscript else symbols.ResolvedRefKind.call);
            if (kind != .subscript or call.args.len != sym.dims.len) break :blk false;
            break :blk sectionIsDefinitelyNoncontiguous(self, sym.dims, call.args);
        },
        .component => |comp| blk: {
            const component = componentInfoForExpr(self, comp) orelse break :blk false;
            if (comp.args.len != component.dims.len) break :blk false;
            break :blk sectionIsDefinitelyNoncontiguous(self, component.dims, comp.args);
        },
        else => false,
    };
}

const SectionClass = enum {
    scalar,
    full,
    nonfull_unit,
    strided_nonunit,
    unknown,
};

pub fn procedureActualExprRank(self: *context.Context, expr: *ast.Expr) usize {
    return resolve_expr.exprRank(self, expr);
}

pub fn checkProcedureDummyCompatibility(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_sig: context.Context.ProcedureSig,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    const count = @min(formal.procedure_dummy_sigs.len, actual_sig.args.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const formal_arg = formal.procedure_dummy_sigs[idx];
        const actual_arg = actual_sig.args[idx];
        if (formal_arg.is_procedure != actual_arg.is_procedure) {
            return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Type mismatch in argument");
        }
        if (formal_arg.optional != actual_arg.optional) {
            return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "OPTIONAL mismatch in argument");
        }
        if (formal_arg.intent != null and actual_arg.intent != null and formal_arg.intent.? != actual_arg.intent.?) {
            return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "INTENT mismatch in argument");
        }
        if (formal_arg.is_procedure) {
            if (formal_arg.procedure_kind != null and actual_arg.procedure_kind != null and formal_arg.procedure_kind.? != actual_arg.procedure_kind.?) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Type mismatch in argument");
            }
            if (formal_arg.procedure_result_type_spec) |expected_result| {
                if (actual_arg.procedure_result_type_spec) |actual_result| {
                    if (functionResultTypeMismatchMessage(self, expected_result, actual_result, deps)) |message| {
                        return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, message);
                    }
                }
            }
            if (formal_arg.procedure_result_rank != actual_arg.procedure_result_rank) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Rank mismatch in function result");
            }
            if (shapeSignatureMismatch(formal_arg.procedure_result_shape_signature, actual_arg.procedure_result_shape_signature)) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "Shape mismatch in function result");
            }
            if (formal_arg.procedure_result_procedure_pointer != actual_arg.procedure_result_procedure_pointer) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "PROCEDURE POINTER mismatch in function result");
            }
            if (formal_arg.procedure_result_pointer != actual_arg.procedure_result_pointer) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "POINTER attribute mismatch in function result");
            }
            if (formal_arg.procedure_result_allocatable != actual_arg.procedure_result_allocatable) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "ALLOCATABLE attribute mismatch in function result");
            }
            if (formal_arg.procedure_result_contiguous != actual_arg.procedure_result_contiguous) {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "CONTIGUOUS attribute mismatch in function result");
            }
            if (formal_arg.procedure_has_explicit_interface and actual_arg.procedure_has_explicit_interface) {
                if (formal_arg.procedure_arg_count != actual_arg.procedure_arg_count or
                    formal_arg.procedure_alt_return_count != actual_arg.procedure_alt_return_count)
                {
                    return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "wrong number of arguments");
                }
                try checkNestedProcedureDummyCompatibility(self, formal_arg, actual_arg, actual_expr, deps);
            }
        } else {
            if (procedureDummyDataArgMismatchMessage(self, formal_arg, actual_arg, deps)) |message| {
                return emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, message);
            }
        }
    }
}

pub fn checkNestedProcedureDummyCompatibility(
    self: *context.Context,
    formal: context.Context.ProcedureSig.ArgSig,
    actual: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    const nested_count = @min(formal.procedure_dummy_sigs.len, actual.procedure_dummy_sigs.len);
    var nested_idx: usize = 0;
    while (nested_idx < nested_count) : (nested_idx += 1) {
        const formal_nested = formal.procedure_dummy_sigs[nested_idx];
        const actual_nested = actual.procedure_dummy_sigs[nested_idx];
        if (formal_nested.is_procedure != actual_nested.is_procedure) {
            return emitProcedureActualDiagnostic(self, actual_expr, error.InvalidArgumentCount, "Type mismatch in argument");
        }
        if (formal_nested.is_procedure) {
            if (formal_nested.procedure_kind != null and actual_nested.procedure_kind != null and formal_nested.procedure_kind.? != actual_nested.procedure_kind.?) {
                return emitProcedureActualDiagnostic(self, actual_expr, error.InvalidArgumentCount, "Type mismatch in argument");
            }
        } else if (procedureDummyDataArgMismatchMessage(self, formal_nested, actual_nested, deps)) |message| {
            return emitProcedureActualDiagnostic(self, actual_expr, error.InvalidArgumentCount, message);
        }
    }
}

pub fn procedureDummyDataArgMismatchMessage(
    self: *context.Context,
    formal: context.Context.ProcedureSig.ArgSig,
    actual: context.Context.ProcedureSig.ArgSig,
    comptime deps: anytype,
) ?[]const u8 {
    if (formal.no_arg_check) return null;
    if (formal.asynchronous != actual.asynchronous) return "ASYNCHRONOUS mismatch in argument";
    if (formal.contiguous != actual.contiguous) return "CONTIGUOUS mismatch in argument";
    if (formal.value_attr != actual.value_attr) return "VALUE mismatch in argument";
    if (formal.volatile_attr != actual.volatile_attr) return "VOLATILE mismatch in argument";
    if (shapeSignatureMismatch(formal.shape_signature, actual.shape_signature)) return "Shape mismatch in dimension";
    if (formal.rank != actual.rank) return "Rank mismatch in argument";
    if (formal.requires_descriptor != actual.requires_descriptor) return "Descriptor mismatch in argument";
    if (formal.pointer != actual.pointer) return "POINTER attribute mismatch in argument";
    if (formal.allocatable != actual.allocatable) return "ALLOCATABLE attribute mismatch in argument";
    if (formal.type_spec.assumed_type) return null;
    if (actual.type_spec.assumed_type) return typeMismatchArgumentMessage(self, actual.type_spec, formal.type_spec);
    if (formal.type_spec.polymorphic != actual.type_spec.polymorphic) return "Polymorphic mismatch in argument";
    if (formal.type_spec.lowered_kind == .character and actual.type_spec.lowered_kind == .character) {
        if (formal.type_spec.char_len_kind != actual.type_spec.char_len_kind or formal.type_spec.char_len != actual.type_spec.char_len) {
            return "Character length mismatch";
        }
    }
    if (formal.type_spec.lowered_kind == .derived or actual.type_spec.lowered_kind == .derived) {
        if (formal.type_spec.lowered_kind != actual.type_spec.lowered_kind) return typeMismatchArgumentMessage(self, actual.type_spec, formal.type_spec);
        if (formal.type_spec.derived_type_name == null or actual.type_spec.derived_type_name == null) return "Derived type mismatch in argument";
        if (!std.ascii.eqlIgnoreCase(formal.type_spec.derived_type_name.?, actual.type_spec.derived_type_name.?)) return "Derived type mismatch in argument";
    }
    if (!deps.dummyArgTypeCompatible(self, formal.type_spec, actual.type_spec)) return typeMismatchArgumentMessage(self, actual.type_spec, formal.type_spec);
    return null;
}

pub fn checkKnownImplicitProcedureScalarActualArgsForCall(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    args: []const ast.CallArg,
    comptime deps: anytype,
) CheckError!void {
    if (!sig.definition_known_from_current_program) return;
    if (sig.args.len == 0) return;
    var formal_idx: usize = 0;
    for (args) |arg| {
        if (arg != .expr) continue;
        if (formal_idx >= sig.args.len) break;
        try checkKnownImplicitProcedureScalarActualArg(self, sig.args[formal_idx], arg.expr.value, deps);
        formal_idx += 1;
    }
}

pub fn checkKnownImplicitProcedureScalarActualArgsForExprCall(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    args: []*ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    if (!sig.definition_known_from_current_program) return;
    if (sig.args.len == 0) return;
    const count = @min(sig.args.len, args.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        try checkKnownImplicitProcedureScalarActualArg(self, sig.args[idx], args[idx], deps);
    }
}

pub fn checkKnownImplicitProcedureScalarActualArg(
    self: *context.Context,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    if (formal.is_procedure) {
        return checkProcedureActualArg(self, null, formal, actual_expr, deps);
    }
    if (formal.no_arg_check) return;
    if (actual_expr.* == .identifier and identifierIsProcedureDesignatorForDataActual(self, actual_expr.identifier)) {
        return emitProcedureActualDiagnostic(self, actual_expr, error.InvalidArgumentCount, "not allowed as an actual argument");
    }
    if (!knownImplicitProcedureScalarTypeCheckEligibleActual(self, actual_expr)) return;
    if (formal.rank != 0) return;
    if (formal.requires_descriptor or formal.pointer or formal.allocatable or formal.type_spec.polymorphic or formal.type_spec.assumed_type) return;

    try resolve_expr.resolveExpr(self, actual_expr);
    if (resolve_expr.exprRank(self, actual_expr) != 0) return;
    const actual_spec = try resolve_expr.exprTypeSpec(self, actual_expr);
    if (!deps.dummyArgTypeCompatible(self, formal.type_spec, actual_spec)) {
        return emitProcedureActualDiagnostic(self, actual_expr, error.InvalidArgumentCount, typeMismatchArgumentMessage(self, actual_spec, formal.type_spec));
    }
}

pub fn knownImplicitProcedureScalarTypeCheckEligibleActual(
    self: *context.Context,
    expr: *ast.Expr,
) bool {
    return switch (expr.*) {
        .literal, .complex_literal => true,
        .unary => |unary| knownImplicitProcedureScalarTypeCheckEligibleActual(self, unary.expr),
        .binary => |binary| knownImplicitProcedureScalarTypeCheckEligibleActual(self, binary.left) and
            knownImplicitProcedureScalarTypeCheckEligibleActual(self, binary.right),
        .identifier => false,
        .call_or_subscript, .substring, .component, .array_constructor, .dim_range, .implied_do => false,
    };
}

pub fn shapeSignatureMismatch(formal: []const []const u8, actual: []const []const u8) bool {
    if (formal.len == 0 or actual.len == 0) return false;
    if (formal.len != actual.len) return true;
    for (formal, actual) |expected, got| {
        if (!std.mem.eql(u8, expected, got)) return true;
    }
    return false;
}

pub fn actualSigResultType(sig: context.Context.ProcedureSig) ?symbols.TypeSpec {
    return sig.result_type_spec;
}

pub fn functionResultTypeMismatchMessage(
    self: *context.Context,
    expected: symbols.TypeSpec,
    actual: symbols.TypeSpec,
    comptime deps: anytype,
) ?[]const u8 {
    if (expected.lowered_kind == .character and actual.lowered_kind == .character) {
        if (expected.char_len_kind == .assumed) return null;
        if (expected.char_len_kind != actual.char_len_kind or expected.char_len != actual.char_len) {
            return "Character length mismatch in function result";
        }
    }
    if (!deps.dummyArgTypeCompatible(self, expected, actual)) return "Type mismatch in function result";
    return null;
}

pub fn procedureKindMismatchMessage(kind: ast.ProgramUnitKind) []const u8 {
    return switch (kind) {
        .subroutine => "actual argument is not a subroutine",
        .function => "actual argument is not a function",
        else => "wrong procedure kind",
    };
}

pub fn passingGlobalProcedureMessage(kind: ast.ProgramUnitKind) []const u8 {
    return switch (kind) {
        .subroutine => "Passing global subroutine",
        .function => "Passing global function",
        else => "wrong procedure kind",
    };
}
