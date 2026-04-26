const std = @import("std");
const ast = @import("../../../../../input.zig");
const common = @import("../../../common.zig");
const cg_context = @import("../../../context/mod.zig");

const int_eval = @import("../int_eval.zig");
const resolution = @import("../resolution.zig");
const shared = @import("../shared.zig");

const Context = shared.Context;
const Expr = shared.Expr;
const DerivedBindingInfo = cg_context.DerivedBindingInfo;

pub const TypeBoundCharacterResultInfo = struct {
    binding: DerivedBindingInfo,
    lookup_name: []const u8,
    ir_name: []const u8,
    result_len: usize,
};

pub fn substringLen(ctx: *Context, sub: ast.SubstringExpr) ?usize {
    const sym = ctx.findSymbol(sub.name) orelse return null;
    if (!sym.isCharacter()) return null;
    const base_len_usize = common.constantCharacterLen(sym) orelse return null;
    const base_len = std.math.cast(i64, base_len_usize) orelse return null;
    const start_val = if (sub.start) |start_expr| int_eval.intLiteralValue(start_expr) orelse return null else 1;
    const end_val = if (sub.end) |end_expr| int_eval.intLiteralValue(end_expr) orelse return null else base_len;
    const span = int_eval.checkedSub(end_val, start_val) orelse return null;
    const length = int_eval.checkedAdd(span, 1) orelse return null;
    if (length <= 0) return null;
    return std.math.cast(usize, length);
}

pub fn typeBoundCharacterResultLen(ctx: *Context, comp: ast.ComponentExpr) ?usize {
    const info = typeBoundCharacterResultInfo(ctx, comp) orelse return null;
    return info.result_len;
}

pub fn typeBoundCharacterResultInfo(ctx: *Context, comp: ast.ComponentExpr) ?TypeBoundCharacterResultInfo {
    const base_type_name = ctx.derivedTypeNameForExpr(comp.base) orelse return null;
    const binding = ctx.lookupDerivedBinding(base_type_name, comp.name) orelse return null;
    const proc_name = binding.implementation_name orelse binding.interface_name orelse binding.name;
    const lookup_name = resolution.boundProcedureLookupName(ctx, binding, proc_name) catch return null;
    const ir_name = resolution.boundProcedureIRName(ctx, binding, proc_name) catch return null;
    const proc_sig = ctx.lookupKnownProcedureSig(lookup_name) orelse ctx.lookupKnownProcedureSig(proc_name) orelse return null;
    const result_spec = resolution.boundProcedureResultSpec(ctx, binding, proc_sig) orelse return null;
    if (result_spec.lowered_kind != .character) return null;
    const result_len = result_spec.char_len orelse return null;
    return .{
        .binding = binding,
        .lookup_name = lookup_name,
        .ir_name = ir_name,
        .result_len = result_len,
    };
}
