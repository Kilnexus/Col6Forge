const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const logical_line = @import("../../logical_line.zig");
const context = @import("../token_stream.zig");
const parse_diag = @import("../diagnostic.zig");

const ProgramUnit = ast.ProgramUnit;
const ProgramUnitKind = ast.ProgramUnitKind;
const Stmt = ast.Stmt;
const LineParser = context.LineParser;

pub fn unitHasContains(unit: ProgramUnit) bool {
    for (unit.stmts) |stmt_node| {
        if (stmt_node.node != .cont) continue;
        const text = std.mem.trim(u8, stmt_node.source_text, " \t");
        if (std.ascii.eqlIgnoreCase(text, "contains")) return true;
    }
    return false;
}

pub fn makeContainsStmt(line: logical_line.LogicalLine) Stmt {
    const first_column = if (line.segments.len > 0) line.segments[0].column else 1;
    return .{
        .label = null,
        .node = .{ .cont = {} },
        .source_line = line.span.start_line,
        .source_column = first_column,
        .source_text = line.text,
    };
}

pub fn stmtKeepsSpecificationPartOpen(stmt_node: ast.Stmt) bool {
    return switch (stmt_node.node) {
        .use_stmt, .data => true,
        else => false,
    };
}

pub fn noteUnexpectedProgramUnitEnd(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    kind: ProgramUnitKind,
) void {
    diag_bag.set(line.span.start_line, 1, catalog.parser.unexpected_token.code, expectedProgramUnitEndMessage(kind), line.text);
}

pub fn rejectProgramUnitEndInsideBlock(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine) error{UnexpectedToken} {
    diag_bag.set(
        line.span.start_line,
        if (line.segments.len > 0) line.segments[0].column else 1,
        catalog.parser.unexpected_token.code,
        "Expecting END BLOCK statement",
        line.text,
    );
    return error.UnexpectedToken;
}

pub fn isEndDoLine(lp: LineParser) bool {
    const end_span = lp.keywordSpan("END") orelse return false;
    const next_idx = lp.index + end_span;
    if (next_idx >= lp.tokens.len) return false;
    const next_tok = lp.tokens[next_idx];
    if (next_tok.kind != .identifier) return false;
    return context.eqNoCase(lp.tokenText(next_tok), "DO");
}

pub fn isEndIfLine(lp: LineParser) bool {
    const end_span = lp.keywordSpan("END") orelse return false;
    const next_idx = lp.index + end_span;
    if (next_idx >= lp.tokens.len) return false;
    const next_tok = lp.tokens[next_idx];
    if (next_tok.kind != .identifier) return false;
    return context.eqNoCase(lp.tokenText(next_tok), "IF");
}

pub fn isEndBlockLine(lp: LineParser) bool {
    const end_span = lp.keywordSpan("END") orelse return false;
    const next_idx = lp.index + end_span;
    if (next_idx >= lp.tokens.len) return false;
    const next_tok = lp.tokens[next_idx];
    if (next_tok.kind != .identifier) return false;
    return context.eqNoCase(lp.tokenText(next_tok), "BLOCK");
}

fn expectedProgramUnitEndMessage(kind: ProgramUnitKind) []const u8 {
    return switch (kind) {
        .subroutine => "Expecting END SUBROUTINE",
        .function => "Expecting END FUNCTION",
        .module => "Expecting END MODULE",
        .program => "Expecting END PROGRAM",
        .block_data => "Expecting END BLOCK DATA",
    };
}
