const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../context.zig");
const resolve_expr = @import("../resolve_expr.zig");
const expr_diagnostics = @import("../expr_diagnostics.zig");
const literal_utils = @import("../../evaluator/literals.zig");

pub fn checkExprCall(self: *context.Context, name: []const u8, args: []*ast.Expr) anyerror!void {
    if (isBitwiseBinaryIntrinsic(name)) {
        try checkBitwiseBinary(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "merge_bits")) {
        try checkMergeBits(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "dshiftl") or std.ascii.eqlIgnoreCase(name, "dshiftr")) {
        try checkDshift(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "complex")) {
        try checkComplex(self, args);
    }
}

fn checkBitwiseBinary(self: *context.Context, args: []*ast.Expr) anyerror!void {
    if (args.len < 2) return;
    if (exprIsBozLiteral(args[0]) and exprIsBozLiteral(args[1])) {
        return emit(self, args[1], "cannot both be BOZ literal");
    }
    try checkIntegerOrBoz(self, args[0]);
    try checkIntegerOrBoz(self, args[1]);
    if (!exprIsBozLiteral(args[0]) and !exprIsBozLiteral(args[1])) {
        const lhs = try resolve_expr.exprTypeSpec(self, args[0]);
        const rhs = try resolve_expr.exprTypeSpec(self, args[1]);
        if (lhs.kind_value != rhs.kind_value) return emit(self, args[1], "must be the same type");
    }
}

fn checkMergeBits(self: *context.Context, args: []*ast.Expr) anyerror!void {
    if (args.len < 3) return;
    if (exprIsBozLiteral(args[0]) and exprIsBozLiteral(args[1])) {
        return emit(self, args[1], "cannot both be BOZ literal");
    }
    try checkIntegerOrBoz(self, args[0]);
    try checkIntegerOrBoz(self, args[1]);
    try checkIntegerOrBoz(self, args[2]);
}

fn checkDshift(self: *context.Context, args: []*ast.Expr) anyerror!void {
    if (args.len < 2) return;
    if (exprIsBozLiteral(args[0]) and exprIsBozLiteral(args[1])) {
        return emit(self, args[1], "cannot both be BOZ");
    }
    try checkIntegerOrBoz(self, args[0]);
    try checkIntegerOrBoz(self, args[1]);
}

fn checkComplex(self: *context.Context, args: []*ast.Expr) anyerror!void {
    if (args.len < 1) return;
    const first_boz = exprIsBozLiteral(args[0]);
    const second_boz = args.len >= 2 and exprIsBozLiteral(args[1]);
    if (first_boz and second_boz) return emit(self, args[1], "cannot both be BOZ");
    if (first_boz) return emit(self, args[0], "cannot appear in the COMPLEX intrinsic");
    if (second_boz) return emit(self, args[1], "cannot appear in the COMPLEX intrinsic");
}

fn checkIntegerOrBoz(self: *context.Context, expr_node: *ast.Expr) anyerror!void {
    if (exprIsBozLiteral(expr_node)) return;
    const spec = try resolve_expr.exprTypeSpec(self, expr_node);
    if (spec.lowered_kind != .integer) return emit(self, expr_node, "must be INTEGER");
}

fn isBitwiseBinaryIntrinsic(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "iand") or
        std.ascii.eqlIgnoreCase(name, "and") or
        std.ascii.eqlIgnoreCase(name, "ieor") or
        std.ascii.eqlIgnoreCase(name, "xor") or
        std.ascii.eqlIgnoreCase(name, "ior") or
        std.ascii.eqlIgnoreCase(name, "or");
}

fn exprIsBozLiteral(expr_node: *ast.Expr) bool {
    if (expr_node.* != .literal or expr_node.literal.kind != .string) return false;
    return literal_utils.parseBozInt(expr_node.literal.text) catch null != null;
}

fn emit(self: *context.Context, expr_node: *ast.Expr, message: []const u8) anyerror {
    return expr_diagnostics.emitExprAssignmentMismatch(self, expr_node, message);
}
