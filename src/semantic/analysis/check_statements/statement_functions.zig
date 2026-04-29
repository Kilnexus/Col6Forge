const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../context.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");
const stmt_diagnostics = @import("diagnostics.zig");

const CheckError = anyerror;
const emitCurrentStmtConstraint = stmt_diagnostics.emitCurrentStmtConstraint;
const emitExprConstraint = stmt_diagnostics.emitExprConstraint;
const StatementFunctionRef = struct {
    name: []const u8,
    args: []*ast.Expr,
    value: *ast.Expr,
};

pub fn validateAssignment(self: *context.Context, assign: ast.Assignment) CheckError!void {
    const stmt_fn = statementFunctionRef(self, assign) orelse return;
    if (self.unit.kind == .module) {
        return emitCurrentStmtConstraint(self, "Unexpected STATEMENT FUNCTION");
    }
    if (statementFunctionNameIsDummy(self, stmt_fn.name)) {
        return emitCurrentStmtConstraint(self, "Unclassifiable statement");
    }
    for (stmt_fn.args) |arg| {
        if (arg.* != .identifier) continue;
        if (std.ascii.eqlIgnoreCase(stmt_fn.name, arg.identifier)) {
            return emitCurrentStmtConstraint(self, "Self-referential argument");
        }
        if (statementFunctionArgIsArray(self, arg.identifier)) {
            return emitCurrentStmtConstraint(self, "must be scalar");
        }
    }
    if (statementFunctionValueCallsArgument(stmt_fn.value, stmt_fn.args)) {
        return emitCurrentStmtConstraint(self, "Invalid use of statement function argument");
    }
}

pub fn validateCalls(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    switch (expr_node.*) {
        .call_or_subscript => |call| {
            const def = findStatementFunctionDefinition(self, call.name) orelse {
                for (call.args) |arg| try validateCalls(self, arg);
                return;
            };
            if (statementFunctionCallUsesKeywordActual(self, expr_node, call.name)) {
                return emitExprConstraint(self, expr_node, "invalid in a statement function");
            }
            try validateStatementFunctionActualTypes(self, expr_node, def.args, call.args);
            for (call.args) |arg| try validateCalls(self, arg);
        },
        .substring => |sub| {
            for (sub.args) |arg| try validateCalls(self, arg);
            if (sub.start) |start| try validateCalls(self, start);
            if (sub.end) |end| try validateCalls(self, end);
        },
        .component => |comp| {
            try validateCalls(self, comp.base);
            for (comp.args) |arg| try validateCalls(self, arg);
        },
        .unary => |unary| try validateCalls(self, unary.expr),
        .binary => |binary| {
            try validateCalls(self, binary.left);
            try validateCalls(self, binary.right);
        },
        .complex_literal => |complex| {
            try validateCalls(self, complex.real);
            try validateCalls(self, complex.imag);
        },
        .array_constructor => |ctor| for (ctor.items) |item| {
            try validateCalls(self, item);
        },
        .dim_range => |range| {
            if (range.lower) |lower| try validateCalls(self, lower);
            try validateCalls(self, range.upper);
            if (range.stride) |stride| try validateCalls(self, stride);
        },
        .implied_do => |implied_do| {
            for (implied_do.items) |item| try validateCalls(self, item);
            try validateCalls(self, implied_do.start);
            try validateCalls(self, implied_do.end);
            if (implied_do.step) |step| try validateCalls(self, step);
        },
        .identifier, .literal => {},
    }
}

fn statementFunctionRef(self: *context.Context, assign: ast.Assignment) ?StatementFunctionRef {
    if (assign.target.* != .call_or_subscript) return null;
    const call = assign.target.call_or_subscript;
    if (call.args.len == 0) return null;
    for (call.args) |arg| {
        if (arg.* != .identifier) return null;
    }
    if (resolve_symbols.findSymbolIndex(self, call.name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.dims.len != 0) return null;
    }
    return .{ .name = call.name, .args = call.args, .value = assign.value };
}

fn findStatementFunctionDefinition(self: *context.Context, name: []const u8) ?StatementFunctionRef {
    for (self.unit.stmts) |stmt| {
        if (stmt.node != .assignment) continue;
        const stmt_fn = statementFunctionRef(self, stmt.node.assignment) orelse continue;
        if (std.ascii.eqlIgnoreCase(stmt_fn.name, name)) return stmt_fn;
    }
    return null;
}

fn statementFunctionNameIsDummy(self: *context.Context, name: []const u8) bool {
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    return self.symbols.items[idx].storage == .dummy;
}

fn statementFunctionArgIsArray(self: *context.Context, name: []const u8) bool {
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    return self.symbols.items[idx].dims.len != 0;
}

fn statementFunctionValueCallsArgument(expr_node: *ast.Expr, args: []*ast.Expr) bool {
    switch (expr_node.*) {
        .call_or_subscript => |call| {
            for (args) |arg| {
                if (arg.* == .identifier and std.ascii.eqlIgnoreCase(arg.identifier, call.name) and call.args.len != 0) return true;
            }
            for (call.args) |actual| {
                if (statementFunctionValueCallsArgument(actual, args)) return true;
            }
            return false;
        },
        .substring => |sub| {
            for (sub.args) |arg| {
                if (statementFunctionValueCallsArgument(arg, args)) return true;
            }
            if (sub.start) |start| if (statementFunctionValueCallsArgument(start, args)) return true;
            if (sub.end) |end| if (statementFunctionValueCallsArgument(end, args)) return true;
            return false;
        },
        .component => |comp| {
            if (statementFunctionValueCallsArgument(comp.base, args)) return true;
            for (comp.args) |arg| {
                if (statementFunctionValueCallsArgument(arg, args)) return true;
            }
            return false;
        },
        .unary => |unary| return statementFunctionValueCallsArgument(unary.expr, args),
        .binary => |binary| return statementFunctionValueCallsArgument(binary.left, args) or statementFunctionValueCallsArgument(binary.right, args),
        .complex_literal => |complex| return statementFunctionValueCallsArgument(complex.real, args) or statementFunctionValueCallsArgument(complex.imag, args),
        .array_constructor => |ctor| {
            for (ctor.items) |item| {
                if (statementFunctionValueCallsArgument(item, args)) return true;
            }
            return false;
        },
        .dim_range => |range| {
            if (range.lower) |lower| if (statementFunctionValueCallsArgument(lower, args)) return true;
            if (statementFunctionValueCallsArgument(range.upper, args)) return true;
            if (range.stride) |stride| if (statementFunctionValueCallsArgument(stride, args)) return true;
            return false;
        },
        .implied_do => |implied_do| {
            for (implied_do.items) |item| {
                if (statementFunctionValueCallsArgument(item, args)) return true;
            }
            if (statementFunctionValueCallsArgument(implied_do.start, args)) return true;
            if (statementFunctionValueCallsArgument(implied_do.end, args)) return true;
            if (implied_do.step) |step| if (statementFunctionValueCallsArgument(step, args)) return true;
            return false;
        },
        .identifier, .literal => return false,
    }
}

fn statementFunctionCallUsesKeywordActual(self: *context.Context, expr_node: *ast.Expr, call_name: []const u8) bool {
    const source = self.sourceForExpr(expr_node) orelse return false;
    const args_text = statementFunctionCallArgumentText(source, call_name) orelse return false;
    var depth: usize = 0;
    for (args_text) |ch| {
        switch (ch) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) break;
                depth -= 1;
            },
            '=' => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn statementFunctionCallArgumentText(source: ast.SourceRef, call_name: []const u8) ?[]const u8 {
    const text = source.text;
    const hinted_idx = if (source.column > 0 and source.column - 1 < text.len) source.column - 1 else 0;
    if (callNameAt(text, hinted_idx, call_name)) {
        return argumentTextAfterName(text, hinted_idx + call_name.len);
    }
    var found_idx: ?usize = null;
    var idx: usize = 0;
    while (idx + call_name.len <= text.len) : (idx += 1) {
        if (!callNameAt(text, idx, call_name)) continue;
        if (argumentTextAfterName(text, idx + call_name.len) == null) continue;
        if (found_idx != null) return null;
        found_idx = idx;
    }
    return if (found_idx) |pos| argumentTextAfterName(text, pos + call_name.len) else null;
}

fn callNameAt(text: []const u8, idx: usize, call_name: []const u8) bool {
    if (idx + call_name.len > text.len) return false;
    if (idx > 0 and isFortranNameChar(text[idx - 1])) return false;
    if (idx + call_name.len < text.len and isFortranNameChar(text[idx + call_name.len])) return false;
    return std.ascii.eqlIgnoreCase(text[idx .. idx + call_name.len], call_name);
}

fn isFortranNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn argumentTextAfterName(text: []const u8, after_name: usize) ?[]const u8 {
    var open_idx = after_name;
    while (open_idx < text.len and (text[open_idx] == ' ' or text[open_idx] == '\t')) : (open_idx += 1) {}
    if (open_idx >= text.len or text[open_idx] != '(') return null;
    return text[open_idx + 1 ..];
}

fn validateStatementFunctionActualTypes(
    self: *context.Context,
    call_expr: *ast.Expr,
    formals: []*ast.Expr,
    actuals: []*ast.Expr,
) CheckError!void {
    const count = @min(formals.len, actuals.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        if (formals[idx].* != .identifier) continue;
        const formal_idx = resolve_symbols.findSymbolIndex(self, formals[idx].identifier) orelse continue;
        const formal_spec = self.symbols.items[formal_idx].type_spec;
        const actual_spec = resolve_expr.exprTypeSpec(self, actuals[idx]) catch continue;
        if (formal_spec.lowered_kind == actual_spec.lowered_kind) continue;
        return emitExprConstraint(self, call_expr, "Type mismatch in argument");
    }
}
