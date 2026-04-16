const support = @import("procedure_calls/support.zig");

pub const CheckError = support.CheckError;
pub const identifierRequiresArgumentList = support.identifierRequiresArgumentList;
pub const isNumeric = support.isNumeric;
pub const isIntegerLike = support.isIntegerLike;
pub const countCallExprArgs = support.countCallExprArgs;
pub const collectCallExprArgsScratch = support.collectCallExprArgsScratch;
pub const checkProcedureActualArgsForCall = support.checkProcedureActualArgsForCall;
pub const checkProcedureActualArgsForExprCall = support.checkProcedureActualArgsForExprCall;
pub const checkTypeBoundProcedureComponent = support.checkTypeBoundProcedureComponent;
pub const checkProcedureComponent = support.checkProcedureComponent;
pub const isTypeBoundProcedurePointerResult = support.isTypeBoundProcedurePointerResult;
pub const checkProcedurePointerAssignmentCompatibility = support.checkProcedurePointerAssignmentCompatibility;
pub const validateProcedurePointerAssignmentValue = support.validateProcedurePointerAssignmentValue;
pub const checkStructureConstructorProcedureComponentActual = support.checkStructureConstructorProcedureComponentActual;
pub const countCallAltReturnArgs = support.countCallAltReturnArgs;
pub const checkKnownProcedureCallArity = support.checkKnownProcedureCallArity;
pub const emitNamedProcedureDiagnostic = support.emitNamedProcedureDiagnostic;
pub const emitAmbiguousReferenceDiagnostic = support.emitAmbiguousReferenceDiagnostic;
pub const emitAmbiguousVisibleGenericDiagnostic = support.emitAmbiguousVisibleGenericDiagnostic;
pub const checkExplicitInterfaceRequirementForCallArgs = support.checkExplicitInterfaceRequirementForCallArgs;
pub const minimumRequiredProcedureArgs = support.minimumRequiredProcedureArgs;
pub const checkExplicitInterfaceRequirementForExprArgs = support.checkExplicitInterfaceRequirementForExprArgs;
pub const checkIntrinsicCallConstraintsForCallArgs = support.checkIntrinsicCallConstraintsForCallArgs;
pub const checkIntrinsicCallConstraintsForExprArgs = support.checkIntrinsicCallConstraintsForExprArgs;
pub const hasVisibleGenericInterface = support.hasVisibleGenericInterface;
pub const preludeSpecificInterfaceProcedureCount = support.preludeSpecificInterfaceProcedureCount;
pub const findPreludeSpecificInterfaceSource = support.findPreludeSpecificInterfaceSource;
pub const appendPreludeSpecificInterfaceSources = support.appendPreludeSpecificInterfaceSources;
pub const currentUnitConflictsWithPreludeProcedure = support.currentUnitConflictsWithPreludeProcedure;
pub const isCurrentUnitAmbiguousResultRef = support.isCurrentUnitAmbiguousResultRef;
pub const hasAmbiguousVisibleGenericInterface = support.hasAmbiguousVisibleGenericInterface;
pub const rejectDefinitelyNoncontiguousPointerAssociation = support.rejectDefinitelyNoncontiguousPointerAssociation;
pub const procedureActualExprRank = support.procedureActualExprRank;
pub const sequenceAssociationAvailableElements = support.sequenceAssociationAvailableElements;
pub const procedurePointerExprSig = support.procedurePointerExprSig;

test {
    _ = @import("procedure_calls/tests.zig");
}
