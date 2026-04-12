const std = @import("std");
const ast = @import("../../../../../input.zig");
const common = @import("../../../common.zig");
const utils = @import("../../../utils.zig");

const int_eval = @import("../int_eval.zig");
const shared = @import("../shared.zig");

const Context = shared.Context;
const EmitError = shared.EmitError;
const Expr = shared.Expr;
const ValueRef = shared.ValueRef;

pub fn isInternalLiteralSubstringName(name: []const u8) bool {
    return std.mem.eql(u8, name, "__col6forge_substring");
}

pub fn isRepeatIntrinsicName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "repeat");
}

pub fn internalLiteralSubstringArgOmitted(expr_node: *Expr) bool {
    return int_eval.intLiteralValue(expr_node) == 0;
}

pub fn validateConstantSubstringBounds(ctx: *Context, sub: ast.SubstringExpr) EmitError!void {
    if (ctx.options.bounds_check) return;
    const sym = ctx.findSymbol(sub.name) orelse return;
    if (!sym.isCharacter()) return;
    const base_len_usize = common.constantCharacterLen(sym) orelse return;
    const base_len = std.math.cast(i64, base_len_usize) orelse return;

    if (sub.start) |start_expr| {
        if (try int_eval.integerExprExceedsBound(start_expr, base_len)) {
            return error.SubstringExceedsStringLength;
        }
    }
    if (sub.end) |end_expr| {
        if (try int_eval.integerExprExceedsBound(end_expr, base_len)) {
            return error.SubstringExceedsStringLength;
        }
    }
}

pub fn copyCharacterBytesConst(
    ctx: *Context,
    builder: anytype,
    dst_ptr: ValueRef,
    bytes: []const u8,
    dst_offset: usize,
) EmitError!void {
    var idx: usize = 0;
    while (idx < bytes.len) : (idx += 1) {
        const dst_idx = dst_offset + idx;
        const dst_off = try ctx.constI32(@intCast(dst_idx));
        const dst_gep = try ctx.nextTemp();
        try builder.gep(dst_gep, .i8, dst_ptr, dst_off);
        try builder.store(.{ .name = try ctx.intLiteral(bytes[idx]), .ty = .i8, .is_ptr = false }, .{ .name = dst_gep, .ty = .ptr, .is_ptr = true });
    }
}

pub fn literalBytes(allocator: std.mem.Allocator, lit: ast.Literal) ![]const u8 {
    return switch (lit.kind) {
        .string => try utils.decodeStringLiteral(allocator, lit.text),
        .hollerith => utils.hollerithBytes(lit.text) orelse return error.InvalidHollerith,
        else => return error.UnsupportedLiteral,
    };
}

pub fn isTrimIntrinsicName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "trim");
}
