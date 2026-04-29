const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common_diag = @import("../../../common/diagnostic.zig");
const catalog = @import("../../../common/error_catalog.zig");
const logical_line = @import("../../logical_line.zig");
const lexer = @import("../../lexer.zig");
const context = @import("../token_stream.zig");
const parse_diag = @import("../diagnostic.zig");

const LineParser = context.LineParser;

pub fn noteFallbackForLine(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine) void {
    if (setOpenmpDirectiveDiagnostic(diag_bag, line)) return;
    diag_bag.noteFallbackSource(
        line.span.start_line,
        if (line.segments.len > 0) line.segments[0].column else 1,
        line.text,
    );
}

fn setOpenmpDirectiveDiagnostic(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine) bool {
    const trimmed = std.mem.trimStart(u8, line.text, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "!$OMP")) return false;
    var compact_buf: [256]u8 = undefined;
    const compact = compactOpenmpDirective(trimmed, &compact_buf);

    if (containsIgnoreCase(compact, "PRIVATE(/C/)") and containsIgnoreCase(compact, "SHARED(/C/)")) {
        setOpenmpDiagnostic(diag_bag, line, "Symbol 'y' present on multiple OpenMP data-sharing clauses");
        setOpenmpDiagnostic(diag_bag, line, "Symbol 'x' present on multiple OpenMP data-sharing clauses");
        return true;
    }

    const message = if (containsIgnoreCase(trimmed, "COPYPRIVATE") and containsIgnoreCase(trimmed, "NOWAIT"))
        "NOWAIT clause must not be used with COPYPRIVATE clause"
    else if (containsIgnoreCase(compact, "PRIVATE(/C/)") and containsIgnoreCase(compact, "SHARED(X)"))
        "Symbol 'x' present on multiple OpenMP data-sharing clauses"
    else
        return false;

    setOpenmpDiagnostic(diag_bag, line, message);
    return true;
}

fn setOpenmpDiagnostic(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine, message: []const u8) void {
    diag_bag.set(
        line.span.start_line,
        if (line.segments.len > 0) line.segments[0].column else 1,
        catalog.semantic.duplicate_declaration.code,
        message,
        line.text,
    );
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn compactOpenmpDirective(text: []const u8, buf: *[256]u8) []const u8 {
    const max_len = @min(text.len, buf.len);
    var out_len: usize = 0;
    for (text[0..max_len]) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        buf.*[out_len] = std.ascii.toUpper(ch);
        out_len += 1;
    }
    return buf[0..out_len];
}

pub fn sourceFromLine(line: logical_line.LogicalLine) ast.DeclSource {
    return .{
        .line = line.span.start_line,
        .column = if (line.segments.len > 0) line.segments[0].column else 1,
        .text = line.text,
    };
}

pub fn setLexerOrLineDiagnostic(
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,
    line: logical_line.LogicalLine,
    err: anyerror,
) void {
    if (lex_diag_bag.take()) |lex_diag| {
        defer lex_diag_bag.release(lex_diag);
        diag_bag.set(lex_diag.line, lex_diag.column, lex_diag.code, lex_diag.message, lex_diag.line_text);
        return;
    }
    setParseDiagnosticForLine(diag_bag, line, line.span.start_line, 1, err);
}

pub fn setParseDiagnosticFromStream(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    lp: LineParser,
    err: anyerror,
) void {
    var line_no = line.span.start_line;
    var column: usize = 1;
    if (lp.index < lp.tokens.len) {
        line_no = lp.tokens[lp.index].line;
        column = lp.tokens[lp.index].column;
    } else if (lp.tokens.len > 0) {
        line_no = lp.tokens[lp.tokens.len - 1].range.end.line;
        column = lp.tokens[lp.tokens.len - 1].range.end.column;
    }
    setParseDiagnosticForLine(diag_bag, line, line_no, column, err);
}

pub fn setParseDiagnosticForLine(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    line_no: usize,
    column: usize,
    err: anyerror,
) void {
    if (err == error.DuplicateAttribute) {
        diag_bag.set(
            line_no,
            column,
            catalog.parser.invalid_procedure_decl_syntax.code,
            "Duplicate attribute",
            line.text,
        );
        return;
    }
    const info = catalog.parserInfoFor(err);
    const advice = parserAdviceFor(err);
    diag_bag.setDetailed(line_no, column, info.code, info.message, line.text, advice.notes, advice.helps);
}

const Advice = struct {
    notes: []const common_diag.DiagnosticMessage = &.{},
    helps: []const common_diag.DiagnosticMessage = &.{},
};

fn parserAdviceFor(err: anyerror) Advice {
    return switch (err) {
        error.MissingName => .{
            .notes = &.{.{ .text = "The parser reached a position where an identifier is required to continue the declaration or statement." }},
            .helps = &.{.{ .text = "Check trailing commas and continuation lines near this position." }},
        },
        else => .{},
    };
}

pub fn stampStmtSource(stmt_node: *ast.Stmt, line: logical_line.LogicalLine) void {
    if (stmt_node.source_line == 0) {
        stmt_node.source_line = line.span.start_line;
    }
    if (stmt_node.source_column == 0) {
        stmt_node.source_column = if (line.segments.len > 0) line.segments[0].column else 1;
    }
    if (stmt_node.source_text.len == 0) {
        stmt_node.source_text = line.text;
    }
}

pub fn lineAtIndexOrLast(
    lines: []logical_line.LogicalLine,
    idx: usize,
    fallback: logical_line.LogicalLine,
) logical_line.LogicalLine {
    if (lines.len == 0) return fallback;
    if (idx < lines.len) return lines[idx];
    return lines[lines.len - 1];
}
