const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const procedure_pass = @import("../../common/procedure_pass.zig");
const context = @import("context.zig");
const resolve_expr = @import("resolve_expr.zig");
const resolve_symbols = @import("resolve_symbols.zig");
const bound_helpers = @import("resolve_expr/calls/bound_helpers.zig");

const BindingInfo = context.Context.DerivedTypeInfo.BindingInfo;

const GenericSpecific = struct {
    sig: context.Context.ProcedureSig,
    pass_idx: ?usize,
};

pub fn lookupTypeBoundGenericSig(
    self: *context.Context,
    generic_name: []const u8,
    passed_object: *ast.Expr,
    extra_actuals: []const *ast.Expr,
    required_kind: ast.ProgramUnitKind,
    comptime deps: anytype,
) !?context.Context.ProcedureSig {
    const passed_spec = try resolve_expr.exprTypeSpec(self, passed_object);
    if (passed_spec.lowered_kind != .derived) return null;
    const derived_name = passed_spec.derived_type_name orelse return null;

    var current = resolve_symbols.lookupDerivedType(self, derived_name) orelse return null;
    var matched: ?context.Context.ProcedureSig = null;
    while (true) {
        for (current.bindings) |binding| {
            if (!binding.is_generic) continue;
            if (!std.ascii.eqlIgnoreCase(binding.name, generic_name)) continue;
            const target = genericBindingTargetSpecific(self, current, binding) orelse continue;
            if (target.sig.kind != required_kind) continue;
            if (!genericSpecificMatchesActuals(self, target, passed_object, extra_actuals, deps)) continue;
            if (matched != null) return null;
            matched = target.sig;
        }
        const parent_name = current.parent_name orelse break;
        current = resolve_symbols.lookupDerivedType(self, parent_name) orelse break;
    }
    return matched;
}

fn genericBindingTargetSpecific(
    self: *context.Context,
    derived: context.Context.DerivedTypeInfo,
    binding: BindingInfo,
) ?GenericSpecific {
    const target_name = binding.implementation_name orelse return null;
    const target = findSpecificBindingByName(derived.bindings, target_name) orelse
        findAncestorSpecificBindingByName(self, derived.parent_name, target_name) orelse
        return null;
    var sig = bound_helpers.typeBoundProcedureSig(self, target) orelse return null;
    if (sig.kind == .function and sig.result_type_spec == null) {
        sig.result_type_spec = bound_helpers.typeBoundProcedureResultTypeSpec(self, target) catch null;
    }
    return .{
        .sig = sig,
        .pass_idx = if (target.nopass) null else procedure_pass.procedurePassArgIndex(sig.args, target.pass_name),
    };
}

fn findSpecificBindingByName(bindings: []const BindingInfo, name: []const u8) ?BindingInfo {
    for (bindings) |binding| {
        if (binding.is_generic) continue;
        if (std.ascii.eqlIgnoreCase(binding.name, name)) return binding;
    }
    return null;
}

fn findAncestorSpecificBindingByName(
    self: *context.Context,
    parent_name: ?[]const u8,
    name: []const u8,
) ?BindingInfo {
    var current_name = parent_name;
    while (current_name) |parent| {
        const derived = resolve_symbols.lookupDerivedType(self, parent) orelse return null;
        if (findSpecificBindingByName(derived.bindings, name)) |binding| return binding;
        current_name = derived.parent_name;
    }
    return null;
}

fn genericSpecificMatchesActuals(
    self: *context.Context,
    target: GenericSpecific,
    passed_object: *ast.Expr,
    extra_actuals: []const *ast.Expr,
    comptime deps: anytype,
) bool {
    return if (target.pass_idx) |pass_idx|
        genericSpecificMatchesPassedActuals(self, target.sig, pass_idx, passed_object, extra_actuals, deps)
    else
        genericSpecificMatchesPositionalActuals(self, target.sig, passed_object, extra_actuals, deps);
}

fn genericSpecificMatchesPassedActuals(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    pass_idx: usize,
    passed_object: *ast.Expr,
    extra_actuals: []const *ast.Expr,
    comptime deps: anytype,
) bool {
    const actual_count = extra_actuals.len + 1;
    if (actual_count > sig.arg_count) return false;
    if (actual_count < bound_helpers.minimumRequiredProcedureArgs(sig)) return false;

    var extra_idx: usize = 0;
    for (sig.args, 0..) |arg, formal_idx| {
        if (formal_idx == pass_idx) {
            if (!formalMatchesExpr(self, arg, passed_object, deps)) return false;
            continue;
        }
        if (extra_idx >= extra_actuals.len) return arg.optional;
        if (!formalMatchesExpr(self, arg, extra_actuals[extra_idx], deps)) return false;
        extra_idx += 1;
    }
    return extra_idx == extra_actuals.len;
}

fn genericSpecificMatchesPositionalActuals(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    first_actual: *ast.Expr,
    extra_actuals: []const *ast.Expr,
    comptime deps: anytype,
) bool {
    const actual_count = extra_actuals.len + 1;
    if (actual_count > sig.arg_count) return false;
    if (actual_count < bound_helpers.minimumRequiredProcedureArgs(sig)) return false;

    var actual_idx: usize = 0;
    for (sig.args) |arg| {
        if (actual_idx >= actual_count) return arg.optional;
        const actual_expr = if (actual_idx == 0) first_actual else extra_actuals[actual_idx - 1];
        if (!formalMatchesExpr(self, arg, actual_expr, deps)) return false;
        actual_idx += 1;
    }
    return actual_idx == actual_count;
}

fn formalMatchesExpr(
    self: *context.Context,
    formal: context.Context.ProcedureSig.ArgSig,
    actual: *ast.Expr,
    comptime deps: anytype,
) bool {
    const actual_spec = resolve_expr.exprTypeSpec(self, actual) catch return false;
    return deps.dummyArgTypeCompatible(self, formal.type_spec, actual_spec);
}
