const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common_diag = @import("../../../common/diagnostic.zig");
const catalog = @import("../../../common/error_catalog.zig");
const symbols = @import("../../symbol/mod.zig");
const context = @import("../context.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");
const procedure_interfaces = @import("procedure_interfaces.zig");

pub const CheckError = anyerror;

pub const DiagnosticSource = struct {
    line: usize,
    column: usize,
    text: []const u8,
};

pub const Advice = struct {
    notes: []const common_diag.DiagnosticMessage = &.{},
    helps: []const common_diag.DiagnosticMessage = &.{},
};

pub fn invalidArgumentAdvice() Advice {
    return .{
        .notes = &.{.{ .text = "This diagnostic comes from the semantic procedure-call matcher, not from parser recovery." }},
        .helps = &.{.{ .text = "Compare the visible procedure interface against the actual argument list and procedure kind." }},
    };
}

pub fn emitProcedureActualDiagnostic(
    self: *context.Context,
    expr: *ast.Expr,
    err: anyerror,
    message: []const u8,
) CheckError {
    const source = self.sourceForExpr(expr);
    const advice = invalidArgumentAdvice();
    if (source) |src| {
        const line = if (src.line == 0) 1 else src.line;
        const column = if (src.column == 0) 1 else src.column;
        var related = std.array_list.Managed(common_diag.DiagnosticSpan).init(self.arena);
        appendActualProcedureExprRelatedSpans(self, &related, expr) catch {};
        self.setDiagnosticStructured(
            line,
            column,
            catalog.semantic.invalid_argument_count.code,
            message,
            src.text,
            "actual procedure argument conflicts here",
            advice.notes,
            advice.helps,
            related.items,
        );
        self.setCurrentSource(src);
    }
    return err;
}

pub fn emitProcedureActualCallDiagnostic(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal_name: ?[]const u8,
    expr: *ast.Expr,
    err: anyerror,
    message: []const u8,
) CheckError {
    const source = self.sourceForExpr(expr);
    const advice = invalidArgumentAdvice();
    if (source) |src| {
        const line = if (src.line == 0) 1 else src.line;
        const column = if (src.column == 0) 1 else src.column;
        var related = std.array_list.Managed(common_diag.DiagnosticSpan).init(self.arena);
        if (callee_name) |name| {
            const formal_source = if (formal_name) |dummy_name|
                procedure_interfaces.findVisibleProcedureFormalSource(self, name, dummy_name)
            else
                null;
            const related_source = formal_source orelse procedure_interfaces.findVisibleProcedureSource(self, name);
            if (related_source) |decl_source| {
                appendDiagnosticSpan(
                    &related,
                    decl_source,
                    if (formal_source != null) "visible dummy declaration here" else "visible interface here",
                ) catch {};
            }
        }
        appendActualProcedureExprRelatedSpans(self, &related, expr) catch {};
        if (related.items.len != 0) {
            self.setDiagnosticStructured(
                line,
                column,
                catalog.semantic.invalid_argument_count.code,
                message,
                src.text,
                "actual argument conflicts here",
                advice.notes,
                advice.helps,
                related.items,
            );
        } else {
            self.setDiagnosticDetailed(line, column, catalog.semantic.invalid_argument_count.code, message, src.text, advice.notes, advice.helps);
        }
        self.setCurrentSource(src);
    }
    return err;
}

pub fn emitProcedureActualCallWarning(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal_name: ?[]const u8,
    expr: *ast.Expr,
    message: []const u8,
) void {
    const source = self.sourceForExpr(expr);
    const advice = invalidArgumentAdvice();
    if (source) |src| {
        const line = if (src.line == 0) 1 else src.line;
        const column = if (src.column == 0) 1 else src.column;
        var related = std.array_list.Managed(common_diag.DiagnosticSpan).init(self.arena);
        if (callee_name) |name| {
            const formal_source = if (formal_name) |dummy_name|
                procedure_interfaces.findVisibleProcedureFormalSource(self, name, dummy_name)
            else
                null;
            const related_source = formal_source orelse procedure_interfaces.findVisibleProcedureSource(self, name);
            if (related_source) |decl_source| {
                appendDiagnosticSpan(
                    &related,
                    decl_source,
                    if (formal_source != null) "visible dummy declaration here" else "visible interface here",
                ) catch {};
            }
        }
        appendActualProcedureExprRelatedSpans(self, &related, expr) catch {};
        if (related.items.len != 0) {
            self.setDiagnosticStructuredWithSeverity(
                line,
                column,
                catalog.semantic.invalid_argument_count.code,
                message,
                src.text,
                .warning,
                "actual argument conflicts here",
                advice.notes,
                advice.helps,
                related.items,
            );
        } else {
            self.setDiagnosticDetailedWithSeverity(
                line,
                column,
                catalog.semantic.invalid_argument_count.code,
                message,
                src.text,
                .warning,
                advice.notes,
                advice.helps,
            );
        }
        self.setCurrentSource(src);
    }
}

pub fn emitStructuredProcedureDiagnostic(
    self: *context.Context,
    primary: DiagnosticSource,
    code: []const u8,
    message: []const u8,
    primary_label: []const u8,
    notes: []const common_diag.DiagnosticMessage,
    helps: []const common_diag.DiagnosticMessage,
    related_sources: []const ast.DeclSource,
    related_label: []const u8,
) void {
    const related = self.arena.alloc(common_diag.DiagnosticSpan, related_sources.len) catch return;
    for (related_sources, 0..) |decl_source, idx| {
        related[idx] = diagnosticSpanFromSource(decl_source, related_label);
    }
    self.setDiagnosticStructured(
        primary.line,
        primary.column,
        code,
        message,
        primary.text,
        primary_label,
        notes,
        helps,
        related,
    );
}

pub fn appendUniqueDeclSource(out: *std.array_list.Managed(ast.DeclSource), source: ast.DeclSource) !void {
    for (out.items) |existing| {
        if (existing.line == source.line and
            existing.column == source.column and
            std.mem.eql(u8, existing.text, source.text))
        {
            return;
        }
    }
    try out.append(source);
}

pub fn emitVariableDefinitionContextDiagnostic(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal_name: ?[]const u8,
    expr: *ast.Expr,
) CheckError {
    const source = self.sourceForExpr(expr) orelse ast.SourceRef{};
    const notes = [_]common_diag.DiagnosticMessage{
        .{ .text = "an actual argument associated with INTENT(OUT) or INTENT(INOUT) must be definable at the call site" },
    };
    const helps = [_]common_diag.DiagnosticMessage{
        .{ .text = "pass a variable, array element, substring, or component that the callee can legally define" },
    };
    if (callee_name) |name| {
        const formal_source = if (formal_name) |dummy_name|
            procedure_interfaces.findVisibleProcedureFormalSource(self, name, dummy_name)
        else
            null;
        const related_source = formal_source orelse procedure_interfaces.findVisibleProcedureSource(self, name);
        if (related_source) |decl_source| {
            const related = [_]ast.DeclSource{decl_source};
            emitStructuredProcedureDiagnostic(
                self,
                .{
                    .line = if (source.line == 0) 1 else source.line,
                    .column = if (source.column == 0) 1 else source.column,
                    .text = source.text,
                },
                catalog.semantic.assignment_type_mismatch.code,
                "in variable definition context",
                "non-definable actual argument here",
                notes[0..],
                helps[0..],
                related[0..],
                if (formal_source != null) "visible dummy declaration here" else "visible interface here",
            );
            return error.AssignmentTypeMismatch;
        }
    }
    self.setDiagnosticStructured(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "in variable definition context",
        source.text,
        "non-definable actual argument here",
        notes[0..],
        helps[0..],
        &.{},
    );
    return error.AssignmentTypeMismatch;
}

pub fn exprIsVariableDefinitionActual(self: *context.Context, expr: *ast.Expr) bool {
    if (exprIsParenthesizedAtSource(self, expr)) return false;
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            if (sym.is_alias and !sym.alias_definable) break :blk false;
            break :blk true;
        },
        .component => |comp| exprIsVariableDefinitionActual(self, comp.base),
        .call_or_subscript => |call| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            if (sym.dims.len == 0 or call.args.len != sym.dims.len) break :blk false;
            break :blk subscriptActualIsVariableDefinition(self, call.args);
        },
        .substring => |sub| blk: {
            if (sub.args.len != 0) {
                for (sub.args) |arg| {
                    if (arg.* == .dim_range) break :blk false;
                }
            }
            break :blk true;
        },
        else => false,
    };
}

pub fn exprIsParenthesizedAtSource(self: *context.Context, expr: *ast.Expr) bool {
    const source = self.sourceForExpr(expr) orelse return false;
    if (source.column == 0 or source.column > source.text.len) return false;
    const start = source.column - 1;
    var left = start;
    while (left > 0) {
        left -= 1;
        if (source.text[left] == ' ' or source.text[left] == '\t') continue;
        break;
    }
    const expr_len = sourceExprLeadLen(expr);
    var right = start + expr_len;
    while (right < source.text.len and (source.text[right] == ' ' or source.text[right] == '\t')) : (right += 1) {}
    return source.text[left] == '(' and right < source.text.len and source.text[right] == ')';
}

fn sourceExprLeadLen(expr: *ast.Expr) usize {
    return switch (expr.*) {
        .identifier => |name| name.len,
        .literal => |lit| lit.text.len,
        .call_or_subscript => |call| call.name.len,
        .substring => |sub| sub.name.len,
        .component => |comp| sourceExprLeadLen(comp.base),
        else => 1,
    };
}

pub fn diagnosticSpanFromSource(source: ast.DeclSource, label: []const u8) common_diag.DiagnosticSpan {
    const line = if (source.line == 0) 1 else source.line;
    const column = if (source.column == 0) 1 else source.column;
    return .{
        .file_path = "",
        .line = line,
        .column = column,
        .end_column = @max(column + 1, source.text.len + 1),
        .line_text = source.text,
        .label = label,
    };
}

fn diagnosticSpanSame(a: common_diag.DiagnosticSpan, b: common_diag.DiagnosticSpan) bool {
    return a.line == b.line and
        a.column == b.column and
        std.mem.eql(u8, a.line_text, b.line_text) and
        std.mem.eql(u8, a.label, b.label);
}

fn appendDiagnosticSpan(
    out: *std.array_list.Managed(common_diag.DiagnosticSpan),
    source: ast.DeclSource,
    label: []const u8,
) !void {
    const span = diagnosticSpanFromSource(source, label);
    for (out.items) |existing| {
        if (diagnosticSpanSame(existing, span)) return;
    }
    try out.append(span);
}

fn appendActualProcedureExprRelatedSpans(
    self: *context.Context,
    out: *std.array_list.Managed(common_diag.DiagnosticSpan),
    expr: *ast.Expr,
) !void {
    switch (expr.*) {
        .identifier => |name| {
            const source = procedure_interfaces.findVisibleProcedureSource(self, name) orelse return;
            try appendDiagnosticSpan(out, source, "actual procedure declared here");
        },
        else => {},
    }
}

fn subscriptActualIsVariableDefinition(self: *context.Context, args: []const *ast.Expr) bool {
    for (args) |arg| {
        switch (arg.*) {
            .dim_range => |range| {
                if (!tripletIsVariableDefinition(self, range)) return false;
            },
            else => {
                if (resolve_expr.exprRank(self, arg) != 0) return false;
            },
        }
    }
    return true;
}

fn tripletIsVariableDefinition(self: *context.Context, range: ast.DimRange) bool {
    if (range.lower) |lower| {
        if (resolve_expr.exprRank(self, lower) != 0) return false;
    }
    if (!(range.upper.* == .literal and range.upper.literal.kind == .assumed_size)) {
        if (resolve_expr.exprRank(self, range.upper) != 0) return false;
    }
    if (range.stride) |stride| {
        if (resolve_expr.exprRank(self, stride) != 0) return false;
    }
    return true;
}
