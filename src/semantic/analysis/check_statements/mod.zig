const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const symbols = @import("../../symbol/mod.zig");
const context = @import("../context.zig");
const resolve_const = @import("../resolve_const.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");
const literal_utils = @import("../../evaluator/literals.zig");
const leaf_helpers = @import("leaf_helpers.zig");
const procedure_interfaces = @import("procedure_interfaces.zig");
const select_type_checks = @import("select_type.zig");
const allocate_checks = @import("allocate/mod.zig");
const procedure_calls = @import("procedure_calls.zig");
const expr_semantics = @import("expr_semantics.zig");
const abstract_expr_use = @import("abstract_expr_use.zig");
const static_shapes = @import("static_shapes.zig");
const statement_functions = @import("statement_functions.zig");
const data_stmt_checks = @import("data_stmt.zig");
const stmt_diagnostics = @import("diagnostics.zig");
const assumed_size = @import("../assumed_size.zig");
const procedure_context = @import("../procedure_context.zig");

pub const CheckError = anyerror;
const emitCurrentStmtConstraint = stmt_diagnostics.emitCurrentStmtConstraint;
const emitExprConstraint = stmt_diagnostics.emitExprConstraint;

pub fn checkStmt(self: *context.Context, stmt: ast.Stmt) CheckError!void {
    const prev_stmt = self.current_stmt;
    const prev_source = self.current_source;
    self.setCurrentStmt(stmt);
    defer self.current_stmt = prev_stmt;
    defer self.current_source = prev_source;
    return checkStmtNode(self, stmt.node);
}

pub fn checkStmtNode(self: *context.Context, node: ast.StmtNode) CheckError!void {
    switch (node) {
        .assignment => |assign| {
            try statement_functions.validateAssignment(self, assign);
            try statement_functions.validateCalls(self, assign.value);
            if (assumed_size.exprNeedsExplicitLastUpperBound(self, assign.target)) {
                return assumed_size.emitExprDiagnostic(self, assign.target, "upper bound in the last dimension");
            }
            if (assumed_size.exprNeedsExplicitLastUpperBound(self, assign.value)) {
                return assumed_size.emitExprDiagnostic(self, assign.value, "upper bound in the last dimension");
            }
            if (procedure_calls.isCurrentUnitAmbiguousResultRef(self, assign.target)) return error.DuplicateDeclaration;
            if (procedure_calls.procedurePointerExprSig(self, assign.target) != null and
                expr_semantics.isPointerTarget(self, assign.target))
            {
                const source = self.sourceForExpr(assign.target) orelse ast.SourceRef{};
                self.setDiagnostic(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "Illegal assignment",
                    source.text,
                );
                return error.AssignmentTypeMismatch;
            }
            const target_ty = try expr_semantics.checkExprType(self, assign.target, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
            const value_ty = try expr_semantics.checkExprType(self, assign.value, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
                .defer_array_constructor_division_by_zero = true,
            });
            const target_spec = try resolve_expr.exprTypeSpec(self, assign.target);
            const value_spec = try resolve_expr.exprTypeSpec(self, assign.value);
            try abstract_expr_use.rejectNonpolymorphicAbstractExprUse(self, assign.target, error.AssignmentTypeMismatch);
            try abstract_expr_use.rejectNonpolymorphicAbstractExprUse(self, assign.value, error.AssignmentTypeMismatch);
            if (!expr_semantics.isAssignmentTarget(self, assign.target)) {
                self.setCurrentSource(self.sourceForExpr(assign.target));
                return error.AssignmentTypeMismatch;
            }
            if (pureProcedureAssignsImpureVariable(self, assign.target)) {
                return emitPureVariableDefinitionDiagnostic(self, assign.target);
            }
            try rejectCharacterLiteralAssignmentConversion(self, assign.value, target_spec, value_spec);
            try rejectMixedCharacterArrayConstructorLengths(self, assign.value, target_spec);
            const defined_assignment_compatible = expr_semantics.isDefinedAssignmentCompatible(self, assign.target, assign.value, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
            if (self.unit.pure and defined_assignment_compatible and pureProcedureUsesImpureDefinedAssignment(self)) {
                return emitExprConstraint(self, assign.target, "is not PURE");
            }
            if (pureProcedureReadsImpurePointerComponentValue(self, assign.value, value_spec)) {
                return emitExprConstraint(self, assign.value, "pure subprogram");
            }
            try rejectInvalidPolymorphicIntrinsicAssignment(self, assign.target, target_spec, defined_assignment_compatible);
            if ((!intrinsicAssignmentTypeCompatible(self, target_ty, value_ty, target_spec, value_spec)) and
                !defined_assignment_compatible)
            {
                self.setCurrentSource(self.sourceForExpr(assign.value) orelse self.sourceForExpr(assign.target));
                return error.AssignmentTypeMismatch;
            }
            try rejectStaticShapeMismatch(self, assign.target, assign.value);
        },
        .pointer_assignment => |assign| {
            if (assumed_size.exprNeedsExplicitLastUpperBound(self, assign.value)) {
                return assumed_size.emitExprDiagnostic(self, assign.value, "upper bound in the last dimension");
            }
            if (pointerAssignmentTargetIsAbstractInterfaceName(self, assign.target)) {
                const source = self.sourceForExpr(assign.target) orelse ast.SourceRef{};
                self.setDiagnostic(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "is not a variable",
                    source.text,
                );
                return error.AssignmentTypeMismatch;
            }
            _ = try expr_semantics.checkExprType(self, assign.target, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
            const procedure_pointer_target = procedure_calls.procedurePointerExprSig(self, assign.target) != null;
            if (procedure_pointer_target and assign.value.* == .call_or_subscript) {
                for (assign.value.call_or_subscript.args) |arg| {
                    _ = expr_semantics.checkExprType(self, arg, .{
                        .dummyArgTypeCompatible = dummyArgTypeCompatible,
                    }) catch |err| {
                        if (!self.usesExplicitDiagnosticBag()) return err;
                        self.recordSemanticError(err);
                        continue;
                    };
                }
            } else {
                _ = try expr_semantics.checkExprType(self, assign.value, .{
                    .dummyArgTypeCompatible = dummyArgTypeCompatible,
                });
            }
            try abstract_expr_use.rejectNonpolymorphicAbstractExprUse(self, assign.target, error.AssignmentTypeMismatch);
            try abstract_expr_use.rejectNonpolymorphicAbstractExprUse(self, assign.value, error.AssignmentTypeMismatch);
            if (expr_semantics.exprUsesNonDefinableAlias(self, assign.target)) {
                const source = self.sourceForExpr(assign.target) orelse ast.SourceRef{};
                self.setDiagnostic(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "in variable definition context",
                    source.text,
                );
                return error.AssignmentTypeMismatch;
            }
            if (expr_semantics.exprRootIsIntentInNonpointerDummy(self, assign.target)) {
                const source = self.sourceForExpr(assign.target) orelse ast.SourceRef{};
                self.setDiagnostic(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "in pointer association context",
                    source.text,
                );
                return error.AssignmentTypeMismatch;
            }
            if (pureProcedureAssignsImpureVariable(self, assign.target)) {
                return emitPureVariableDefinitionDiagnostic(self, assign.target);
            }
            if (!expr_semantics.isPointerTarget(self, assign.target)) {
                const source = self.sourceForExpr(assign.target) orelse ast.SourceRef{};
                self.setDiagnostic(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "Non-POINTER in pointer association context",
                    source.text,
                );
                return error.AssignmentTypeMismatch;
            }
            if (procedure_pointer_target) {
                try procedure_calls.validateProcedurePointerAssignmentValue(self, assign.value);
            } else if (!expr_semantics.isPointerValuedExpr(self, assign.value) and !expr_semantics.isAddressableDataTargetExpr(self, assign.value)) {
                const source = self.sourceForExpr(assign.value) orelse self.sourceForExpr(assign.target) orelse ast.SourceRef{};
                self.setDiagnostic(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "Pointer assignment target is neither TARGET nor POINTER",
                    source.text,
                );
                return error.AssignmentTypeMismatch;
            }
            if (pureProcedureUsesImpurePointerTarget(self, assign.value)) {
                return emitExprConstraint(self, assign.value, "Bad target");
            }
            try rejectCharacterPointerLengthMismatch(self, assign.target, assign.value);
            try procedure_calls.rejectDefinitelyNoncontiguousPointerAssociation(self, assign.target, assign.value);
            try procedure_calls.checkProcedurePointerAssignmentCompatibility(self, assign.target, assign.value, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
        },
        .nullify => |nullify| {
            for (nullify.items) |item| {
                _ = try expr_semantics.checkExprType(self, item, .{
                    .dummyArgTypeCompatible = dummyArgTypeCompatible,
                });
                if (!expr_semantics.isPointerTarget(self, item)) {
                    self.setCurrentSource(self.sourceForExpr(item));
                    return error.AssignmentTypeMismatch;
                }
            }
        },
        .associate_block => |associate| {
            try select_type_checks.checkAssociateBlock(self, associate, .{
                .checkStmt = checkStmt,
                .checkExprType = expr_semantics.checkExprType,
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
        },
        .select_type_block => |select_type| {
            try select_type_checks.checkSelectTypeBlock(self, select_type, .{
                .checkStmt = checkStmt,
                .checkExprType = expr_semantics.checkExprType,
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
        },
        .orphan_select_type_clause => |clause| {
            const message = switch (clause.kind) {
                .type_is => "Unexpected TYPE IS statement",
                .class_is => "Syntax error in CLASS IS",
                .class_default => "Unexpected CLASS DEFAULT statement",
            };
            const stmt = self.current_stmt orelse return error.UnexpectedToken;
            self.setDiagnostic(
                if (stmt.source_line == 0) 1 else stmt.source_line,
                if (stmt.source_column == 0) 1 else stmt.source_column,
                catalog.parser.unexpected_token.code,
                message,
                stmt.source_text,
            );
            return error.UnexpectedToken;
        },
        .assign_label => |assign| {
            _ = std.fmt.parseInt(i64, assign.label, 10) catch return error.InvalidLabelValue;
            const idx = resolve_symbols.findSymbolIndex(self, assign.target) orelse return error.AssignmentTypeMismatch;
            const sym = self.symbols.items[idx];
            if (sym.loweredKind() != .integer or sym.dims.len != 0) return error.AssignmentTypeMismatch;
        },
        .use_stmt => |use_stmt| {
            if (procedure_calls.currentUnitConflictsWithPreludeProcedure(self, self.unit.name)) {
                self.setDiagnostic(
                    if (use_stmt.source.line == 0) 1 else use_stmt.source.line,
                    if (use_stmt.source.column == 0) 1 else use_stmt.source.column,
                    catalog.semantic.duplicate_declaration.code,
                    "is also the name of the current program unit",
                    use_stmt.source.text,
                );
                return error.DuplicateDeclaration;
            }
        },
        .call => |call| {
            const call_idx = resolve_symbols.findSymbolIndex(self, call.name);
            self.setCurrentSource(if (call.source.line != 0) call.source else null);
            if (call.binding_base) |base| {
                try expr_semantics.checkExpr(self, base, .{
                    .dummyArgTypeCompatible = dummyArgTypeCompatible,
                });
                for (call.args) |arg| {
                    switch (arg) {
                        .expr => |actual| try expr_semantics.checkExpr(self, actual.value, .{
                            .dummyArgTypeCompatible = dummyArgTypeCompatible,
                        }),
                        .alt_return => |label| try leaf_helpers.checkCallAltReturnLabel(self, label),
                    }
                }
                const base_spec = try resolve_expr.exprTypeSpec(self, base);
                if (base_spec.lowered_kind != .derived) return error.InvalidArgumentCount;
                const derived_name = base_spec.derived_type_name orelse return error.InvalidArgumentCount;
                if (resolve_symbols.lookupDerivedComponent(self, derived_name, call.name)) |component| {
                    if (!component.procedure) return error.InvalidArgumentCount;
                    return procedure_calls.checkProcedureComponent(self, base, component, procedure_calls.collectCallExprArgsScratch(self, call.args), true, .{
                        .dummyArgTypeCompatible = dummyArgTypeCompatible,
                    });
                }
                const binding = resolve_symbols.lookupDerivedBinding(self, derived_name, call.name) orelse return error.InvalidArgumentCount;
                return procedure_calls.checkTypeBoundProcedureComponent(self, base, binding, procedure_calls.collectCallExprArgsScratch(self, call.args), true, .{
                    .dummyArgTypeCompatible = dummyArgTypeCompatible,
                });
            }
            if (!procedure_interfaces.callHasDerivedActuals(self, call.args) and
                procedure_calls.hasAmbiguousVisibleGenericInterface(self, call.name) and
                procedure_interfaces.matchedVisibleGenericSigForCallArgs(self, call.name, call.args) == null)
            {
                return procedure_calls.emitAmbiguousVisibleGenericDiagnostic(self, call.name, error.DuplicateDeclaration);
            }
            if (std.ascii.eqlIgnoreCase(call.name, self.unit.name) and procedure_calls.currentUnitConflictsWithPreludeProcedure(self, call.name)) {
                procedure_calls.emitAmbiguousReferenceDiagnostic(self, call.name);
                return error.DuplicateDeclaration;
            }
            if (shouldRejectNonRecursiveCurrentProcedureCall(self, call.name)) {
                self.setDiagnostic(
                    if (call.source.line == 0) 1 else call.source.line,
                    if (call.source.column == 0) 1 else call.source.column,
                    catalog.semantic.invalid_argument_count.code,
                    "Procedure is not RECURSIVE",
                    call.source.text,
                );
                return error.InvalidArgumentCount;
            }
            if (procedure_interfaces.isAbstractInterfaceProcedure(self, call.name)) {
                return procedure_calls.emitNamedProcedureDiagnostic(self, call.name, error.InvalidArgumentCount, "must not be referenced");
            }
            try expr_semantics.checkSpecialCallConstraints(self, call.name, procedure_calls.collectCallExprArgsScratch(self, call.args));
            try procedure_calls.checkIntrinsicCallConstraintsForCallArgs(self, call.name, call.args);
            try procedure_calls.checkExplicitInterfaceRequirementForCallArgs(self, call.name, call.args, call_idx);
            try procedure_calls.checkKnownProcedureCallArity(
                self,
                call.name,
                procedure_calls.countCallExprArgs(call.args),
                procedure_calls.countCallAltReturnArgs(call.args),
                true,
                call_idx,
            );
            try procedure_calls.checkProcedureActualArgsForCall(self, call.name, call.args, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
            try rejectElementalCallRankMismatch(self, call.name, call.args);
            for (call.args) |arg| {
                switch (arg) {
                    .expr => |actual| try expr_semantics.checkExpr(self, actual.value, .{
                        .dummyArgTypeCompatible = dummyArgTypeCompatible,
                    }),
                    .alt_return => |label| try leaf_helpers.checkCallAltReturnLabel(self, label),
                }
            }
        },
        .write => |write| {
            try expr_semantics.checkExpr(self, write.unit, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            try leaf_helpers.checkDataTransferUnit(self, write.unit);
            try leaf_helpers.checkFormatSpec(self, write.format);
            if (write.rec) |rec| try expr_semantics.checkExpr(self, rec, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            for (write.args) |arg| {
                try expr_semantics.checkExpr(self, arg, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
                try rejectProcedurePointerComponentIo(self, arg);
                try rejectAllocatableComponentIo(self, arg);
                try rejectPolymorphicDataTransferIo(self, arg);
            }
            if (write.iostat) |io| try expr_semantics.checkExpr(self, io, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            for (write.controls) |ctrl| try expr_semantics.checkExpr(self, ctrl.value, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            try leaf_helpers.rejectNamedIoControl(self, write.controls, "END", "END tag is not allowed in output statement");
            try leaf_helpers.checkAdvanceControls(self, write.controls);
            try leaf_helpers.checkDataTransferAsyncControls(self, write.controls);
            try leaf_helpers.checkNamedDefaultCharacterControls(self, write.controls, &.{ "BLANK", "DELIM", "PAD", "ROUND", "SIGN" });
        },
        .read => |read| {
            try expr_semantics.checkExpr(self, read.unit, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            try leaf_helpers.checkDataTransferUnit(self, read.unit);
            try leaf_helpers.checkFormatSpec(self, read.format);
            try leaf_helpers.checkReadFormatPositiveWidths(self, read.format);
            if (read.rec) |rec| try expr_semantics.checkExpr(self, rec, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            for (read.args) |arg| {
                try expr_semantics.checkExpr(self, arg, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
                try rejectProcedurePointerComponentIo(self, arg);
                try rejectAllocatableComponentIo(self, arg);
                try rejectPolymorphicDataTransferIo(self, arg);
            }
            if (read.iostat) |io| try expr_semantics.checkExpr(self, io, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            for (read.controls) |ctrl| try expr_semantics.checkExpr(self, ctrl.value, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            try leaf_helpers.checkAdvanceControls(self, read.controls);
            try leaf_helpers.checkDataTransferAsyncControls(self, read.controls);
            try leaf_helpers.checkNamedDefaultCharacterControls(self, read.controls, &.{ "BLANK", "DELIM", "PAD", "ROUND", "SIGN" });
        },
        .rewind => |rewind| try expr_semantics.checkExpr(self, rewind.unit, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible }),
        .backspace => |backspace| try expr_semantics.checkExpr(self, backspace.unit, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible }),
        .endfile => |endfile| try expr_semantics.checkExpr(self, endfile.unit, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible }),
        .open => |open_stmt| {
            try expr_semantics.checkExpr(self, open_stmt.unit, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            if (open_stmt.recl) |recl| try expr_semantics.checkExpr(self, recl, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            if (open_stmt.file) |file_expr| try expr_semantics.checkExpr(self, file_expr, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            if (open_stmt.access) |access| try expr_semantics.checkExpr(self, access, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            if (open_stmt.form) |form| try expr_semantics.checkExpr(self, form, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            if (open_stmt.blank) |blank| try expr_semantics.checkExpr(self, blank, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            if (open_stmt.status) |status| try expr_semantics.checkExpr(self, status, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            try leaf_helpers.checkOpenControl(self, open_stmt.access, &.{ "DIRECT", "SEQUENTIAL" });
            try leaf_helpers.checkOpenControl(self, open_stmt.form, &.{ "FORMATTED", "UNFORMATTED" });
            try leaf_helpers.checkOpenControl(self, open_stmt.blank, &.{ "NULL", "ZERO" });
            try leaf_helpers.checkOpenControl(self, open_stmt.status, &.{ "UNKNOWN", "OLD", "NEW", "SCRATCH", "REPLACE" });
            for (open_stmt.controls) |ctrl| try expr_semantics.checkExpr(self, ctrl.value, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            try leaf_helpers.checkNamedDefaultCharacterControls(self, open_stmt.controls, &.{ "DECIMAL", "ENCODING", "ROUND", "SIGN" });
        },
        .inquire => |inq| {
            for (inq.controls) |ctrl| try expr_semantics.checkExpr(self, ctrl.value, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            try leaf_helpers.checkInquireFileUnitControls(self, inq.controls);
        },
        .close => |cls| {
            for (cls.controls) |ctrl| {
                try expr_semantics.checkExpr(self, ctrl.value, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
                if (ctrl.name) |name| {
                    if (std.ascii.eqlIgnoreCase(name, "STATUS")) {
                        self.setCurrentSource(if (ctrl.source.line != 0) ctrl.source else self.sourceForExpr(ctrl.value));
                        try leaf_helpers.checkCharControlExpr(self, ctrl.value);
                        if (leaf_helpers.controlLiteralText(ctrl.value)) |text| {
                            if (!leaf_helpers.textInSet(text, &.{ "KEEP", "DELETE" })) {
                                self.setCurrentSource(if (ctrl.source.line != 0) ctrl.source else self.sourceForExpr(ctrl.value));
                                return error.InvalidIoControlValue;
                            }
                        }
                    }
                }
            }
        },
        .allocate => |allocate| {
            try allocate_checks.checkAllocateStmt(self, allocate, .{
                .checkExprType = expr_semantics.checkExprType,
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
                .resolvedKindFor = expr_semantics.resolvedKindFor,
                .symbolIndexForResolvedCall = expr_semantics.symbolIndexForResolvedCall,
                .identifierRequiresArgumentList = procedure_calls.identifierRequiresArgumentList,
            });
        },
        .deallocate => |deallocate| {
            try allocate_checks.checkDeallocateStmt(self, deallocate, .{
                .checkExprType = expr_semantics.checkExprType,
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
                .resolvedKindFor = expr_semantics.resolvedKindFor,
                .symbolIndexForResolvedCall = expr_semantics.symbolIndexForResolvedCall,
                .identifierRequiresArgumentList = procedure_calls.identifierRequiresArgumentList,
            });
        },
        .data => |data| {
            for (data.inits) |init| {
                try data_stmt_checks.checkDataInit(self, init);
                try expr_semantics.checkExpr(self, init.target, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
                try expr_semantics.checkExpr(self, init.value, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            }
        },
        .format => {
            if (self.current_stmt == null or self.current_stmt.?.label == null) {
                return error.InvalidFormatStatement;
            }
        },
        .arith_if => |arith| try expr_semantics.checkExpr(self, arith.condition, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible }),
        .pause => {},
        .stop => {},
        .do_loop => |loop| {
            const loop_idx = resolve_symbols.findSymbolIndex(self, loop.var_name) orelse return error.UnknownSymbol;
            const loop_sym = self.symbols.items[loop_idx];
            const loop_kind = loop_sym.loweredKind();
            const allow_legacy_numeric_do = self.dialect == .f77_legacy and loop_sym.dims.len == 0 and isLegacyDialectDoControlKind(loop_kind);
            if ((loop_kind != .integer or loop_sym.dims.len != 0) and !allow_legacy_numeric_do) {
                return emitCurrentStmtConstraint(self, "DO variable must be a scalar INTEGER");
            }
            try expr_semantics.checkExpr(self, loop.start, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            try expr_semantics.checkExpr(self, loop.end, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            if (loop.step) |step| {
                const step_ty = try expr_semantics.checkExprType(self, step, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
                if (self.dialect == .f77_legacy) {
                    if (!isLegacyDialectDoControlKind(step_ty)) {
                        return emitExprConstraint(self, step, "DO step must be numeric under -std=f77");
                    }
                } else if (step_ty != .integer) {
                    return emitExprConstraint(self, step, "DO step must be INTEGER");
                }
                if (try resolve_const.evalConst(self, step)) |value| {
                    switch (value) {
                        .integer => |v| if (v == 0) {
                            return emitExprConstraint(self, step, "DO step must not be zero");
                        },
                        .real => |v| if (v.value == 0.0) {
                            return emitExprConstraint(self, step, "DO step must not be zero");
                        },
                        else => {},
                    }
                }
            }
        },
        .do_while => |loop| try expr_semantics.checkLogicalConditionExpr(self, loop.condition, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible }),
        .do_infinite => {},
        .goto => {},
        .computed_goto => |cg| try expr_semantics.checkExpr(self, cg.selector, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible }),
        .assigned_goto => {},
        .if_single => |ifs| {
            try expr_semantics.checkLogicalConditionExpr(self, ifs.condition, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            if (ifs.stmt.* == .if_single or ifs.stmt.* == .if_block) {
                return error.InvalidLogicalIfNesting;
            }
            try checkStmtNode(self, ifs.stmt.*);
        },
        .if_block => |ifb| {
            try expr_semantics.checkLogicalConditionExpr(self, ifb.condition, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            for (ifb.then_stmts) |inner| try checkStmt(self, inner);
            for (ifb.else_stmts) |inner| try checkStmt(self, inner);
        },
        .where_stmt => |where| {
            try expr_semantics.checkLogicalConditionExpr(self, where.mask, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
            const target_ty = try expr_semantics.checkExprType(self, where.target, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
            const value_ty = try expr_semantics.checkExprType(self, where.value, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
            const target_spec = try resolve_expr.exprTypeSpec(self, where.target);
            const value_spec = try resolve_expr.exprTypeSpec(self, where.value);
            if (!expr_semantics.isAssignmentTarget(self, where.target)) {
                self.setCurrentSource(self.sourceForExpr(where.target));
                return error.AssignmentTypeMismatch;
            }
            try rejectCharacterLiteralAssignmentConversion(self, where.value, target_spec, value_spec);
            const defined_assignment_compatible = expr_semantics.isDefinedAssignmentCompatible(self, where.target, where.value, .{
                .dummyArgTypeCompatible = dummyArgTypeCompatible,
            });
            if (defined_assignment_compatible) {
                if (resolve_symbols.lookupKnownProcedureSig(self, "assignment(=)")) |sig| {
                    if (!sig.elemental) {
                        return emitExprConstraint(self, where.value, "Non-ELEMENTAL user-defined assignment in WHERE");
                    }
                }
            }
            if ((!intrinsicAssignmentTypeCompatible(self, target_ty, value_ty, target_spec, value_spec)) and
                !defined_assignment_compatible)
            {
                self.setCurrentSource(self.sourceForExpr(where.value) orelse self.sourceForExpr(where.target));
                return error.AssignmentTypeMismatch;
            }
        },
        .ret => |ret| {
            if (ret.value) |value| try expr_semantics.checkExpr(self, value, .{ .dummyArgTypeCompatible = dummyArgTypeCompatible });
        },
        .cont => {},
        .entry => |entry| {
            if (self.unit.kind != .function and self.unit.kind != .subroutine) {
                return error.InvalidEntryStatement;
            }
            var seen = std.StringHashMap(void).init(self.arena);
            for (entry.args) |arg_name| {
                const key = try leaf_helpers.lowerDup(self.arena, arg_name);
                if (seen.contains(key)) return error.InvalidEntryStatement;
                try seen.put(key, {});
            }
        },
    }
}

fn rejectElementalCallRankMismatch(
    self: *context.Context,
    call_name: []const u8,
    args: []const ast.CallArg,
) CheckError!void {
    const sig = resolve_symbols.lookupKnownProcedureSig(self, call_name) orelse return;
    if (!sig.elemental) return;

    var expected_rank: ?usize = null;
    for (args, 0..) |arg, idx| {
        if (arg != .expr) continue;
        if (idx >= sig.args.len or sig.args[idx].rank != 0) continue;
        const actual_rank = resolve_expr.exprRank(self, arg.expr.value);
        if (actual_rank == 0) continue;
        if (expected_rank == null) {
            expected_rank = actual_rank;
            continue;
        }
        if (expected_rank.? != actual_rank) {
            return emitExprConstraint(self, arg.expr.value, "Incompatible ranks in elemental procedure");
        }
    }
    const array_rank = expected_rank orelse return;
    for (args, 0..) |arg, idx| {
        if (arg != .expr) continue;
        if (idx >= sig.args.len or sig.args[idx].rank != 0) continue;
        const intent = sig.args[idx].intent orelse continue;
        if (intent != .out and intent != .inout) continue;
        if (resolve_expr.exprRank(self, arg.expr.value) == array_rank) continue;
        return emitExprConstraint(self, arg.expr.value, "is a scalar");
    }
}

fn shouldRejectNonRecursiveCurrentProcedureCall(self: *context.Context, name: []const u8) bool {
    return procedure_context.shouldRejectNonRecursiveCurrentProcedureReference(self, name);
}

fn pureProcedureAssignsImpureVariable(self: *context.Context, target: *ast.Expr) bool {
    return pureProcedureUsesImpureStorage(self, target);
}

fn pureProcedureUsesImpurePointerTarget(self: *context.Context, target: *ast.Expr) bool {
    return pureProcedureUsesImpureStorage(self, target);
}

fn pureProcedureUsesImpureStorage(self: *context.Context, target: *ast.Expr) bool {
    if (!self.unit.pure) return false;
    const name = switch (target.*) {
        .identifier => |ident| ident,
        .call_or_subscript => |call| call.name,
        .substring => |sub| sub.name,
        .component => return pureProcedureUsesImpureStorage(self, target.component.base),
        else => return false,
    };
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    const sym = self.symbols.items[idx];
    if (sym.storage == .common or sym.is_host_associated) return true;
    if (self.unit.kind == .function and sym.storage == .dummy) return true;
    return dummyHasIntentIn(self, name);
}

fn pureProcedureReadsImpurePointerComponentValue(self: *context.Context, value: *ast.Expr, value_spec: symbols.TypeSpec) bool {
    if (!self.unit.pure) return false;
    if (value_spec.lowered_kind != .derived) return false;
    const derived_name = value_spec.derived_type_name orelse return false;
    if (!derivedTypeHasPointerComponent(self, derived_name)) return false;
    return pureProcedureUsesImpurePointerTarget(self, value);
}

fn derivedTypeHasPointerComponent(self: *context.Context, type_name: []const u8) bool {
    const derived = resolve_symbols.lookupDerivedType(self, type_name) orelse return false;
    for (derived.components) |component| {
        if (component.pointer) return true;
    }
    return false;
}

fn pureProcedureUsesImpureDefinedAssignment(self: *context.Context) bool {
    const sig = resolve_symbols.lookupKnownProcedureSig(self, "assignment(=)") orelse return false;
    return !sig.pure;
}

fn emitPureVariableDefinitionDiagnostic(self: *context.Context, target: *ast.Expr) CheckError {
    const source = self.sourceForExpr(target) orelse blk: {
        const stmt = self.current_stmt orelse break :blk ast.SourceRef{};
        break :blk ast.SourceRef{
            .line = stmt.source_line,
            .column = stmt.source_column,
            .text = stmt.source_text,
        };
    };
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "cannot be used in a variable definition context",
        source.text,
    );
    return error.AssignmentTypeMismatch;
}

fn dummyHasIntentIn(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                const intent = type_decl.intent orelse continue;
                if (intent != .in) continue;
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .intent => |intent_decl| {
                if (intent_decl.kind != .in) continue;
                for (intent_decl.names) |intent_name| {
                    if (std.ascii.eqlIgnoreCase(intent_name, name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn rejectStaticShapeMismatch(
    self: *context.Context,
    target: *ast.Expr,
    value: *ast.Expr,
) CheckError!void {
    const target_rank = resolve_expr.exprRank(self, target);
    const value_rank = resolve_expr.exprRank(self, value);
    if (value_rank != 0 and target_rank != value_rank) {
        return emitExprConstraint(self, value, "Incompatible ranks");
    }

    const target_shape = static_shapes.staticShapeForExpr(self, target) orelse return;
    const value_shape = static_shapes.staticShapeForExpr(self, value) orelse return;
    if (target_shape.len != value_shape.len) {
        return emitExprConstraint(self, value, "Different shape");
    }
    for (target_shape, value_shape) |expected, actual| {
        if (expected != actual) return emitExprConstraint(self, value, "Different shape");
    }
}

fn pointerAssignmentTargetIsAbstractInterfaceName(self: *context.Context, expr: *ast.Expr) bool {
    const name = switch (expr.*) {
        .identifier => |ident| ident,
        else => return false,
    };
    return procedure_interfaces.abstractInterfaceNameBlocksVariableUse(self, name);
}

fn dummyArgTypeCompatible(
    self: *context.Context,
    expected: symbols.TypeSpec,
    actual: symbols.TypeSpec,
) bool {
    if (expected.assumed_type) return true;
    if (actual.assumed_type) return false;
    if (expected.polymorphic and expected.derived_type_name == null) {
        return true;
    }
    if (expected.lowered_kind != actual.lowered_kind) return false;
    if (expected.lowered_kind != .derived) return true;

    const expected_name = expected.derived_type_name orelse return false;
    const actual_name = actual.derived_type_name orelse return false;
    const expected_iso_family = isoCBindingHandleFamily(expected_name);
    const actual_iso_family = isoCBindingHandleFamily(actual_name);
    if (expected_iso_family != null or actual_iso_family != null) {
        return expected_iso_family != null and actual_iso_family != null and expected_iso_family.? == actual_iso_family.?;
    }
    return if (expected.polymorphic)
        resolve_symbols.isSameOrExtension(self, actual_name, expected_name)
    else
        resolve_symbols.areConcreteDerivedTypesCompatible(self, expected_name, actual_name);
}

fn isoCBindingHandleFamily(name: []const u8) ?enum { c_ptr, c_funptr } {
    var lower_buf: [128]u8 = undefined;
    if (name.len > lower_buf.len) return null;
    for (name, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const lower = lower_buf[0..name.len];
    if (std.mem.indexOf(u8, lower, "c_funptr") != null) return .c_funptr;
    if (std.mem.indexOf(u8, lower, "c_ptr") != null) return .c_ptr;
    return null;
}

fn intrinsicAssignmentTypeCompatible(
    self: *context.Context,
    target_ty: ast.TypeKind,
    value_ty: ast.TypeKind,
    target_spec: symbols.TypeSpec,
    value_spec: symbols.TypeSpec,
) bool {
    const logical_integer_extension =
        (target_ty == .logical and value_ty == .integer) or
        (target_ty == .integer and value_ty == .logical);
    if (!logical_integer_extension and !expr_semantics.isAssignmentCompatible(target_ty, value_ty)) return false;

    if (target_spec.polymorphic or value_spec.polymorphic) {
        return dummyArgTypeCompatible(self, target_spec, value_spec);
    }

    if (target_spec.lowered_kind == .derived or value_spec.lowered_kind == .derived) {
        return dummyArgTypeCompatible(self, target_spec, value_spec);
    }

    return true;
}

fn rejectInvalidPolymorphicIntrinsicAssignment(
    self: *context.Context,
    target: *ast.Expr,
    target_spec: symbols.TypeSpec,
    defined_assignment_compatible: bool,
) CheckError!void {
    if (defined_assignment_compatible) return;
    if (target_spec.lowered_kind != .derived or !target_spec.polymorphic) return;
    if (assignmentTargetAllowsPolymorphicIntrinsicAssignment(self, target)) return;
    return emitExprConstraint(self, target, "Nonallocatable variable must not be polymorphic in intrinsic assignment");
}

fn assignmentTargetAllowsPolymorphicIntrinsicAssignment(
    self: *context.Context,
    target: *ast.Expr,
) bool {
    return switch (target.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.is_allocatable;
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk false;
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk false;
            if (base_spec.lowered_kind != .derived) break :blk false;
            const derived_name = base_spec.derived_type_name orelse break :blk false;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk false;
            break :blk component.allocatable;
        },
        else => false,
    };
}

fn rejectCharacterLiteralAssignmentConversion(
    self: *context.Context,
    value: *ast.Expr,
    target_spec: symbols.TypeSpec,
    value_spec: symbols.TypeSpec,
) CheckError!void {
    if (!self.fbackslash) return;
    if (target_spec.lowered_kind != .character or value_spec.lowered_kind != .character) return;

    const target_kind = target_spec.kind_value orelse 1;
    const value_kind = value_spec.kind_value orelse 1;
    if (target_kind == value_kind) return;
    if (value.* != .literal or value.literal.kind != .string) return;

    const cp = literal_utils.firstBackslashEscapeExceedingCharacterKind(value.literal.text, target_kind) orelse return;
    const source = self.sourceForExpr(value) orelse ast.SourceRef{};
    const message = std.fmt.allocPrint(
        self.arena,
        "Unicode character U+{X} cannot be converted to character kind {d}",
        .{ cp, target_kind },
    ) catch "cannot be converted";
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
    );
    return error.AssignmentTypeMismatch;
}

fn rejectMixedCharacterArrayConstructorLengths(
    self: *context.Context,
    value: *ast.Expr,
    target_spec: symbols.TypeSpec,
) CheckError!void {
    if (target_spec.lowered_kind != .character) return;
    if (resolve_expr.exprRank(self, value) == 0) return;
    const ctor = switch (value.*) {
        .array_constructor => |ctor| ctor,
        else => return,
    };
    var expected_len: ?usize = null;
    for (ctor.items) |item| {
        const item_len = characterExprLogicalLen(self, item) orelse return;
        if (expected_len == null) {
            expected_len = item_len;
            continue;
        }
        if (expected_len.? != item_len) {
            return emitExprConstraint(self, value, "Different CHARACTER lengths");
        }
    }
}

fn characterExprLogicalLen(self: *context.Context, expr_node: *ast.Expr) ?usize {
    return switch (expr_node.*) {
        .literal => |lit| switch (lit.kind) {
            .string, .hollerith => literal_utils.literalByteLen(lit),
            else => null,
        },
        else => blk: {
            const spec = resolve_expr.exprTypeSpec(self, expr_node) catch break :blk null;
            if (spec.lowered_kind != .character) break :blk null;
            break :blk switch (spec.char_len_kind) {
                .constant => spec.char_len,
                .none => spec.char_len orelse 1,
                .assumed, .deferred => null,
            };
        },
    };
}

fn isLegacyDialectDoControlKind(kind: ast.TypeKind) bool {
    return switch (kind) {
        .integer, .real, .double_precision => true,
        else => false,
    };
}

fn rejectProcedurePointerComponentIo(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return;
    if (spec.lowered_kind != .derived) return;
    const derived_name = spec.derived_type_name orelse return;
    const derived = resolve_symbols.lookupDerivedType(self, derived_name) orelse return;
    for (derived.components) |component| {
        if (!component.procedure or !component.pointer) continue;
        return emitExprConstraint(self, expr_node, "cannot have procedure pointer components");
    }
}

fn rejectCharacterPointerLengthMismatch(self: *context.Context, target: *ast.Expr, value: *ast.Expr) CheckError!void {
    const target_spec = resolve_expr.exprTypeSpec(self, target) catch return;
    if (target_spec.lowered_kind != .character or target_spec.char_len_kind == .deferred) return;
    const value_spec = resolve_expr.exprTypeSpec(self, value) catch return;
    if (value_spec.lowered_kind != .character or value_spec.char_len_kind == .deferred) return;
    const target_len = target_spec.char_len orelse return;
    const value_len = value_spec.char_len orelse return;
    if (target_len == value_len) return;
    const message = std.fmt.allocPrint(
        self.arena,
        "Unequal character lengths ({d}/{d})",
        .{ target_len, value_len },
    ) catch "Unequal character lengths";
    return emitExprConstraint(self, value, message);
}

fn rejectAllocatableComponentIo(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return;
    if (spec.lowered_kind != .derived) return;
    const derived_name = spec.derived_type_name orelse return;
    const derived = resolve_symbols.lookupDerivedType(self, derived_name) orelse return;
    for (derived.components) |component| {
        if (!component.allocatable) continue;
        return emitExprConstraint(self, expr_node, "cannot have ALLOCATABLE components");
    }
}

fn rejectPolymorphicDataTransferIo(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return;
    if (spec.lowered_kind != .derived or !spec.polymorphic) return;
    return emitExprConstraint(self, expr_node, "Data transfer element at .1. cannot be polymorphic");
}
