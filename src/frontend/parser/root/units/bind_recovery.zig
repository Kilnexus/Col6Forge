const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const logical_line = @import("../../../logical_line.zig");
const lexer = @import("../../../lexer.zig");
const context = @import("../../token_stream.zig");
const root_diagnostics = @import("../diagnostics.zig");
const root_predicates = @import("../predicates.zig");

const LineParser = context.LineParser;

pub fn recoverMalformedBindProcedureHeader(
    self: anytype,
    header_line: logical_line.LogicalLine,
    err: anyerror,
) !?ast.ProgramUnit {
    if (err != error.UnexpectedToken and err != error.MissingName and err != error.InvalidStringLiteral) return null;
    const message = malformedBindHeaderMessage(header_line.text) orelse return null;
    const recovered_info = recoverProcedureHeaderInfo(self.arena, header_line.text) orelse return null;

    self.diag_bag.set(
        header_line.span.start_line,
        if (header_line.segments.len > 0) header_line.segments[0].column else 1,
        catalog.parser.unexpected_token.code,
        message,
        header_line.text,
    );

    var scan_index = self.index + 1;
    while (scan_index < self.lines.len) : (scan_index += 1) {
        const line = self.lines[scan_index];
        const tokens = self.tokensForIndex(scan_index) catch continue;
        if (!root_predicates.isProgramUnitEndTokens(line, tokens) and !root_predicates.isStandaloneEndTokens(line, tokens)) continue;
        self.diag_bag.set(
            line.span.start_line,
            if (line.segments.len > 0) line.segments[0].column else 1,
            catalog.parser.unexpected_token.code,
            "Expecting END MODULE statement",
            line.text,
        );
        self.index = scan_index + 1;
        return ast.ProgramUnit{
            .kind = recovered_info.kind,
            .name = recovered_info.name,
            .source = root_diagnostics.sourceFromLine(header_line),
            .args = &.{},
            .decls = &.{},
            .stmts = &.{},
            .expr_sources = &.{},
        };
    }
    return null;
}

pub fn isBindCProcedureHeaderMissingParens(
    line: logical_line.LogicalLine,
    tokens: []lexer.Token,
) bool {
    var lp = LineParser.init(line, tokens);
    while (true) {
        if (lp.consumeKeyword("PURE") or lp.consumeKeyword("ELEMENTAL") or lp.consumeKeyword("RECURSIVE")) continue;
        if (lp.consumeKeyword("IMPURE")) continue;
        break;
    }
    _ = lp.consumeKeyword("MODULE");
    if (!lp.consumeKeyword("SUBROUTINE") and !lp.consumeKeyword("FUNCTION")) return false;
    _ = lp.expectIdentifier() orelse return false;
    if (lp.peekIs(.l_paren)) return false;

    while (lp.peek()) |tok| {
        if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "BIND")) {
            _ = lp.next();
            if (!lp.consume(.l_paren)) return false;
            const c_tok = lp.peek() orelse return false;
            if (c_tok.kind != .identifier or !context.eqNoCase(lp.tokenText(c_tok), "C")) return false;
            _ = lp.next();
            return lp.consume(.r_paren);
        }
        _ = lp.next();
    }
    return false;
}

const RecoveredProcedureHeader = struct {
    kind: ast.ProgramUnitKind,
    name: []const u8,
};

fn recoverProcedureHeaderInfo(arena: std.mem.Allocator, line_text: []const u8) ?RecoveredProcedureHeader {
    const comment_start = std.mem.indexOfScalar(u8, line_text, '!') orelse line_text.len;
    const prefix = line_text[0..comment_start];
    var it = std.mem.tokenizeAny(u8, prefix, " \t(),");
    while (it.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "pure") or
            std.ascii.eqlIgnoreCase(word, "elemental") or
            std.ascii.eqlIgnoreCase(word, "recursive") or
            std.ascii.eqlIgnoreCase(word, "module"))
        {
            continue;
        }
        if (std.ascii.eqlIgnoreCase(word, "subroutine")) {
            const name = it.next() orelse return null;
            return .{ .kind = .subroutine, .name = arena.dupe(u8, name) catch return null };
        }
        if (std.ascii.eqlIgnoreCase(word, "function")) {
            const name = it.next() orelse return null;
            return .{ .kind = .function, .name = arena.dupe(u8, name) catch return null };
        }
    }
    return null;
}

fn malformedBindHeaderMessage(line_text: []const u8) ?[]const u8 {
    const comment_start = std.mem.indexOfScalar(u8, line_text, '!') orelse line_text.len;
    const prefix = std.mem.trimEnd(u8, line_text[0..comment_start], " \t");
    if (std.ascii.indexOfIgnoreCase(prefix, "bind(") == null) return null;
    const name_idx = std.ascii.indexOfIgnoreCase(prefix, "name") orelse return null;
    var tail = prefix[name_idx + 4 ..];
    tail = std.mem.trimStart(u8, tail, " \t");
    if (tail.len == 0) return "Syntax error";
    if (tail[0] == ')') return "Syntax error";
    if (tail[0] != '=') return null;
    tail = std.mem.trimStart(u8, tail[1..], " \t");
    if (tail.len == 0 or tail[0] == ')') return "Invalid character";
    if (tail[0] == '"' or tail[0] == '\'') {
        const quote = tail[0];
        var idx: usize = 1;
        while (idx < tail.len) : (idx += 1) {
            if (tail[idx] != quote) continue;
            if (idx + 1 < tail.len and tail[idx + 1] == quote) {
                idx += 1;
                continue;
            }
            return null;
        }
        return "Invalid C identifier";
    }
    return "Syntax error";
}
