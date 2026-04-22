const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const symbols = @import("../../symbol/mod.zig");
const context = @import("../context.zig");
const symbols_mod = @import("../resolve_symbols.zig");
const type_bound_generics = @import("../type_bound_generics.zig");

const ResolveError = anyerror;

fn defaultCharacterKind(kind_value: ?i64) i64 {
    return kind_value orelse 1;
}

fn emitCharacterKindMismatch(
    self: *context.Context,
    left_spec: symbols.TypeSpec,
    op: ast.BinaryOp,
    left_expr: *ast.Expr,
    right_expr: *ast.Expr,
) void {
    const src = self.current_source orelse self.sourceForExpr(right_expr) orelse self.sourceForExpr(left_expr) orelse return;
    const message = if (std.ascii.indexOfIgnoreCase(src.text, "case") != null)
        std.fmt.allocPrint(self.arena, "must be of kind {d}", .{defaultCharacterKind(left_spec.kind_value)}) catch "must be of kind 1"
    else switch (op) {
        .concat => "Operands of string concatenation operator are of different kind",
        else => "Operands of comparison operator are of different kind",
    };
    self.setDiagnostic(src.line, src.column, @import("../../../common/error_catalog.zig").semantic.invalid_arithmetic_operands.code, message, src.text);
}

pub fn validateBinaryOperandSpecs(
    self: *context.Context,
    op: ast.BinaryOp,
    left_spec: symbols.TypeSpec,
    right_spec: symbols.TypeSpec,
    left_expr: *ast.Expr,
    right_expr: *ast.Expr,
    comptime deps: anytype,
) !symbols.TypeSpec {
    try deps.validateBinaryOperands(op, left_spec.lowered_kind, right_spec.lowered_kind);
    switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => {
            if (left_spec.lowered_kind == .character and right_spec.lowered_kind == .character and
                defaultCharacterKind(left_spec.kind_value) != defaultCharacterKind(right_spec.kind_value))
            {
                emitCharacterKindMismatch(self, left_spec, op, left_expr, right_expr);
                return error.InvalidArithmeticOperands;
            }
            return symbols.TypeSpec.fromResolvedKind(.logical, .logical, null);
        },
        .and_, .or_, .eqv, .neqv => return symbols.TypeSpec.fromResolvedKind(.logical, .logical, null),
        .concat => {
            if (left_spec.lowered_kind == .character and right_spec.lowered_kind == .character and
                defaultCharacterKind(left_spec.kind_value) != defaultCharacterKind(right_spec.kind_value))
            {
                emitCharacterKindMismatch(self, left_spec, op, left_expr, right_expr);
                return error.InvalidArithmeticOperands;
            }
            return concatResultSpec(left_spec, right_spec);
        },
        else => return promoteNumericTypeSpec(self, left_expr, right_expr, deps),
    }
}

pub fn concatResultSpec(left_spec: symbols.TypeSpec, right_spec: symbols.TypeSpec) symbols.TypeSpec {
    const result_kind = left_spec.kind_value orelse right_spec.kind_value;
    return symbols.TypeSpec.fromResolvedKind(.character, .character, result_kind)
        .withCharacterLength(.deferred, null);
}

pub fn resolveDefinedUnaryOperatorResult(
    self: *context.Context,
    op: ast.UnaryOp,
    actual: *ast.Expr,
    comptime deps: anytype,
) ResolveError!?symbols.TypeSpec {
    const op_name = unaryDefinedOperatorName(op) orelse return null;
    var actuals = [_]*ast.Expr{actual};
    return lookupDefinedOperatorResult(self, op_name, &actuals, deps);
}

pub fn resolveDefinedBinaryOperatorResult(
    self: *context.Context,
    op: ast.BinaryOp,
    left: *ast.Expr,
    right: *ast.Expr,
    comptime deps: anytype,
) ResolveError!?symbols.TypeSpec {
    const op_name = binaryDefinedOperatorName(op) orelse return null;
    var actuals = [_]*ast.Expr{ left, right };
    return lookupDefinedOperatorResult(self, op_name, &actuals, deps);
}

pub fn binaryIntrinsicApplicable(
    op: ast.BinaryOp,
    left_spec: symbols.TypeSpec,
    right_spec: symbols.TypeSpec,
    comptime deps: anytype,
) bool {
    deps.validateBinaryOperands(op, left_spec.lowered_kind, right_spec.lowered_kind) catch return false;
    switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge, .concat => {
            if (left_spec.lowered_kind == .character and right_spec.lowered_kind == .character and
                defaultCharacterKind(left_spec.kind_value) != defaultCharacterKind(right_spec.kind_value))
            {
                return false;
            }
        },
        else => {},
    }
    return true;
}

pub fn promoteNumericTypeSpec(
    self: *context.Context,
    left: *ast.Expr,
    right: *ast.Expr,
    comptime deps: anytype,
) ResolveError!symbols.TypeSpec {
    const left_spec = try deps.exprTypeSpecCached(self, left);
    const right_spec = try deps.exprTypeSpecCached(self, right);
    return switch (deps.promoteNumericType(left_spec.lowered_kind, right_spec.lowered_kind)) {
        .complex_double => symbols.TypeSpec.fromResolvedKind(.complex, .complex_double, 16),
        .complex => if (left_spec.lowered_kind == .complex or left_spec.lowered_kind == .complex_double) left_spec else right_spec,
        .double_precision => if (left_spec.lowered_kind == .double_precision) left_spec else right_spec,
        .real => if (left_spec.lowered_kind == .real) left_spec else right_spec,
        .integer => if (left_spec.lowered_kind == .integer) left_spec else right_spec,
        else => return error.InvalidArithmeticOperands,
    };
}

fn lookupDefinedOperatorResult(
    self: *context.Context,
    op_name: []const u8,
    actuals: []const *ast.Expr,
    comptime deps: anytype,
) ResolveError!?symbols.TypeSpec {
    const sig = try lookupDefinedOperatorSig(self, op_name, actuals, deps) orelse return null;
    if (sig.result_type_spec) |spec| return spec;
    return symbols_mod.lookupKnownFunctionResolvedSpec(self, op_name) orelse null;
}

fn lookupDefinedOperatorSig(
    self: *context.Context,
    op_name: []const u8,
    actuals: []const *ast.Expr,
    comptime deps: anytype,
) ResolveError!?context.Context.ProcedureSig {
    if (symbols_mod.lookupKnownProcedureSig(self, op_name)) |sig| {
        if (sig.kind == .function and procedureSigMatchesActuals(self, sig, actuals, deps)) return sig;
    }
    if (actuals.len != 0) {
        if (try type_bound_generics.lookupTypeBoundGenericSig(
            self,
            op_name,
            actuals[0],
            actuals[1..],
            .function,
            .{ .dummyArgTypeCompatible = deps.dummyArgTypeCompatible },
        )) |sig| return sig;
    }

    var matched: ?context.Context.ProcedureSig = null;
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, op_name)) continue;

        for (decl.interface_block.procedure_headers) |proc_header| {
            const sig = lookupSpecificSig(self, proc_header.name, proc_header.source) orelse continue;
            if (sig.kind != .function) continue;
            if (!procedureSigMatchesActuals(self, sig, actuals, deps)) continue;
            if (matched != null) return null;
            matched = sig;
        }
        for (decl.interface_block.specific_procedures, 0..) |proc_name, idx| {
            if (idx >= decl.interface_block.specific_procedure_sources.len) continue;
            const sig = lookupSpecificSig(self, proc_name, decl.interface_block.specific_procedure_sources[idx]) orelse continue;
            if (sig.kind != .function) continue;
            if (!procedureSigMatchesActuals(self, sig, actuals, deps)) continue;
            if (matched != null) return null;
            matched = sig;
        }
        for (decl.interface_block.module_procedures, 0..) |proc_name, idx| {
            if (idx >= decl.interface_block.module_procedure_sources.len) continue;
            const sig = lookupSpecificSig(self, proc_name, decl.interface_block.module_procedure_sources[idx]) orelse continue;
            if (sig.kind != .function) continue;
            if (!procedureSigMatchesActuals(self, sig, actuals, deps)) continue;
            if (matched != null) return null;
            matched = sig;
        }
        for (decl.interface_block.procedures, 0..) |proc_name, idx| {
            var has_header = false;
            for (decl.interface_block.procedure_headers) |proc_header| {
                if (std.ascii.eqlIgnoreCase(proc_header.name, proc_name)) {
                    has_header = true;
                    break;
                }
            }
            if (has_header) continue;
            if (idx >= decl.interface_block.procedure_sources.len) continue;
            const sig = lookupSpecificSig(self, proc_name, decl.interface_block.procedure_sources[idx]) orelse continue;
            if (sig.kind != .function) continue;
            if (!procedureSigMatchesActuals(self, sig, actuals, deps)) continue;
            if (matched != null) return null;
            matched = sig;
        }
    }
    return matched;
}

fn lookupSpecificSig(
    self: *context.Context,
    proc_name: []const u8,
    source: ast.DeclSource,
) ?context.Context.ProcedureSig {
    if (symbols_mod.lookupKnownProcedureSig(self, proc_name)) |sig| return sig;
    if (source.owner_name) |owner_name| {
        const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, proc_name }) catch return null;
        if (symbols_mod.lookupKnownProcedureSig(self, qualified)) |sig| return sig;
    }
    const suffix = std.fmt.allocPrint(self.arena, "::{s}", .{proc_name}) catch return null;
    var matched: ?context.Context.ProcedureSig = null;
    var it = self.known_procedure_sigs.iterator();
    while (it.next()) |entry| {
        if (!std.ascii.endsWithIgnoreCase(entry.key_ptr.*, suffix)) continue;
        if (matched != null) return null;
        matched = entry.value_ptr.*;
    }
    return matched;
}

fn procedureSigMatchesActuals(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    actuals: []const *ast.Expr,
    comptime deps: anytype,
) bool {
    if (sig.args.len == 0) return sig.arg_count == actuals.len;
    if (actuals.len > sig.arg_count) return false;

    var actual_index: usize = 0;
    for (sig.args) |arg| {
        if (actual_index >= actuals.len) return arg.optional;
        const actual_spec = deps.exprTypeSpecCached(self, actuals[actual_index]) catch return false;
        if (!deps.dummyArgTypeCompatible(self, arg.type_spec, actual_spec)) return false;
        actual_index += 1;
    }
    return actual_index == actuals.len;
}

fn unaryDefinedOperatorName(op: ast.UnaryOp) ?[]const u8 {
    return switch (op) {
        .plus => "operator(+)",
        .minus => "operator(-)",
        .not => "operator(.not.)",
    };
}

fn binaryDefinedOperatorName(op: ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .add => "operator(+)",
        .sub => "operator(-)",
        .mul => "operator(*)",
        .div => "operator(/)",
        .concat => "operator(//)",
        .power => "operator(**)",
        .eq => "operator(==)",
        .ne => "operator(/=)",
        .lt => "operator(<)",
        .le => "operator(<=)",
        .gt => "operator(>)",
        .ge => "operator(>=)",
        .and_ => "operator(.and.)",
        .or_ => "operator(.or.)",
        .eqv => "operator(.eqv.)",
        .neqv => "operator(.neqv.)",
    };
}
