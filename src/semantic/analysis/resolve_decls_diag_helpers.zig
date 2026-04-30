const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const context = @import("context.zig");

pub fn emitCurrentDeclSimpleDiagnostic(self: *context.Context, code: []const u8, message: []const u8) void {
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnostic(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        code,
        message,
        decl_source.text,
    );
}

fn emitCurrentDeclNamedDiagnostic(
    self: *context.Context,
    code: []const u8,
    comptime fmt: []const u8,
    name: []const u8,
    fallback: []const u8,
) void {
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    const message = std.fmt.allocPrint(self.arena, fmt, .{name}) catch fallback;
    self.setDiagnostic(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        code,
        message,
        decl_source.text,
    );
}

pub fn emitCharacterLenTypingDiagnostic(self: *context.Context, expr: *ast.Expr) bool {
    if (!exprHasIdentifier(expr)) return false;
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnosticDetailed(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.invalid_char_len.code,
        "used before it is typed",
        decl_source.text,
        &.{.{ .text = "This CHARACTER length expression depends on an identifier whose type/constant value is not ready at this declaration point." }},
        &.{.{ .text = "Declare or type the length parameter before using it in a CHARACTER length expression." }},
    );
    return true;
}

pub fn emitCharacterLenScalarIntegerDiagnostic(self: *context.Context) void {
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnostic(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.invalid_char_len.code,
        "Scalar INTEGER expression",
        decl_source.text,
    );
}

pub fn emitUnitNoImplicitDiagnostic(self: *context.Context) void {
    const source = self.unit.source;
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_char_len.code,
        "has no IMPLICIT type",
        source.text,
    );
}

pub fn emitExternalCharacterLenDiagnostic(self: *context.Context) void {
    emitCurrentDeclSimpleDiagnostic(self, catalog.semantic.invalid_char_len.code, "must be declared with a constant character length");
}

pub fn emitRestrictedSpecExprDiagnostic(self: *context.Context, name: []const u8) void {
    emitCurrentDeclNamedDiagnostic(self, catalog.semantic.unexpected_type_decl.code, "'{s}' cannot appear in the expression", name, "cannot appear in the expression");
}

pub fn emitOptionalSpecExprDiagnostic(self: *context.Context, name: []const u8) void {
    emitCurrentDeclNamedDiagnostic(
        self,
        catalog.semantic.invalid_argument_count.code,
        "OPTIONAL dummy argument '{s}' cannot appear in specification expression",
        name,
        "OPTIONAL dummy argument cannot appear in specification expression",
    );
}

pub fn emitPureSpecExprDiagnostic(self: *context.Context) void {
    emitCurrentDeclSimpleDiagnostic(self, catalog.semantic.invalid_argument_count.code, "must be PURE");
}

pub fn emitUsedBeforeTypedDiagnostic(self: *context.Context) void {
    emitCurrentDeclSimpleDiagnostic(self, catalog.semantic.invalid_char_len.code, "used before it is typed");
}

pub fn emitCurrentFunctionNoImplicitDiagnostic(self: *context.Context) void {
    const source = inferredCurrentFunctionHeaderSource(self) orelse return;
    self.setDiagnostic(source.line, source.column, catalog.semantic.invalid_char_len.code, "has no IMPLICIT type", source.text);
}

fn inferredCurrentFunctionHeaderSource(self: *context.Context) ?struct { line: usize, column: usize, text: []const u8 } {
    if (self.unit.kind != .function) return null;
    var first_decl_line: ?usize = null;
    for (self.unit.decl_sources) |source| {
        if (source.line == 0) continue;
        first_decl_line = source.line;
        break;
    }
    const line = if (first_decl_line) |decl_line| if (decl_line > 1) decl_line - 1 else decl_line else return null;
    return .{ .line = line, .column = 1, .text = "" };
}

fn exprHasIdentifier(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => true,
        .unary => |un| exprHasIdentifier(un.expr),
        .binary => |bin| exprHasIdentifier(bin.left) or exprHasIdentifier(bin.right),
        .call_or_subscript => |call| blk: {
            for (call.args) |arg| if (exprHasIdentifier(arg)) break :blk true;
            break :blk false;
        },
        .component => |comp| exprHasIdentifier(comp.base),
        .substring => |sub| blk: {
            for (sub.args) |arg| if (exprHasIdentifier(arg)) break :blk true;
            if (sub.start != null and exprHasIdentifier(sub.start.?)) break :blk true;
            if (sub.end != null and exprHasIdentifier(sub.end.?)) break :blk true;
            break :blk false;
        },
        .dim_range => |range| blk: {
            if (range.lower != null and exprHasIdentifier(range.lower.?)) break :blk true;
            if (exprHasIdentifier(range.upper)) break :blk true;
            if (range.stride != null and exprHasIdentifier(range.stride.?)) break :blk true;
            break :blk false;
        },
        .array_constructor => |ctor| blk: {
            for (ctor.items) |item| if (exprHasIdentifier(item)) break :blk true;
            break :blk false;
        },
        .complex_literal => |lit| exprHasIdentifier(lit.real) or exprHasIdentifier(lit.imag),
        .implied_do => |ido| blk: {
            for (ido.items) |item| if (exprHasIdentifier(item)) break :blk true;
            if (exprHasIdentifier(ido.start) or exprHasIdentifier(ido.end)) break :blk true;
            if (ido.step != null and exprHasIdentifier(ido.step.?)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}
