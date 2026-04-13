const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const logical_line = @import("../../../logical_line.zig");
const lexer = @import("../../../lexer.zig");
const context = @import("../../token_stream.zig");
const decl = @import("../../decl/mod.zig");
const expr = @import("../../expr.zig");
const parse_diag = @import("../../diagnostic.zig");
const array_info = @import("../../array_info.zig");
const control_flow = @import("../control_flow.zig");
const helpers = @import("../helpers.zig");
const block_body = @import("block_body.zig");
const stmt_shared = @import("shared.zig");

const LineParser = context.LineParser;
const Stmt = ast.Stmt;
const DoContext = control_flow.DoContext;
const defaultSourceColumn = stmt_shared.defaultSourceColumn;
const setStmtSourceIfMissing = stmt_shared.setStmtSourceIfMissing;
const lexLine = stmt_shared.lexLine;

pub const ParseStatementFn = block_body.ParseStatementFn;

pub fn isAssociateStart(lp: LineParser) bool {
    return lp.isKeywordSplit("ASSOCIATE");
}

fn isEndAssociateLine(lp: LineParser) bool {
    return helpers.isEndKeywordLine(lp, "ENDASSOCIATE", "ASSOCIATE");
}

fn isUnitTerminatorLine(lp: LineParser) bool {
    const end_span = lp.keywordSpan("END") orelse return false;
    const next_idx = lp.index + end_span;
    if (next_idx >= lp.tokens.len) return true;
    const next_tok = lp.tokens[next_idx];
    if (next_tok.kind != .identifier) return true;
    const next = lp.tokenText(next_tok);
    return context.eqNoCase(next, "PROGRAM") or
        context.eqNoCase(next, "SUBROUTINE") or
        context.eqNoCase(next, "FUNCTION") or
        context.eqNoCase(next, "MODULE") or
        context.eqNoCase(next, "BLOCKDATA");
}

fn parseAssociateBindings(arena: std.mem.Allocator, lp: *LineParser) ![]ast.AssociateBinding {
    var bindings = std.array_list.Managed(ast.AssociateBinding).init(arena);
    while (!lp.peekIs(.r_paren)) {
        const name = lp.readName(arena) orelse return error.MissingName;
        _ = lp.expect(.equals) orelse return error.UnexpectedToken;
        _ = lp.expect(.greater) orelse return error.UnexpectedToken;
        const selector = try expr.parseExpr(lp, arena, 0);
        try bindings.append(.{
            .name = name,
            .selector = selector,
        });
        if (!lp.consume(.comma)) break;
    }
    return bindings.toOwnedSlice();
}

fn parseAssociateBlock(
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,
    parse_statement_fn: ParseStatementFn,
) anyerror![]Stmt {
    return block_body.parseNestedStmtBlock(
        arena,
        lines,
        index,
        do_ctx,
        param_ints,
        param_strings,
        array_names,
        diag_bag,
        lex_diag_bag,
        parse_statement_fn,
        struct {
            fn stop(lp: LineParser) bool {
                return isEndAssociateLine(lp) or isUnitTerminatorLine(lp);
            }
        }.stop,
    );
}

pub fn parseAssociateStatement(
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    label: ?[]const u8,
    lp: *LineParser,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,
    parse_statement_fn: ParseStatementFn,
) anyerror!Stmt {
    if (!lp.consumeKeyword("ASSOCIATE")) return error.UnexpectedToken;
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const bindings = try parseAssociateBindings(arena, lp);
    if (bindings.len == 0) return error.UnexpectedToken;
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;

    index.* += 1;
    const body = try parseAssociateBlock(
        arena,
        lines,
        index,
        do_ctx,
        param_ints,
        param_strings,
        array_names,
        diag_bag,
        lex_diag_bag,
        parse_statement_fn,
    );
    if (index.* >= lines.len) return error.UnexpectedEOF;

    const end_line = lines[index.*];
    const end_tokens = try lexLine(arena, end_line, diag_bag, lex_diag_bag);
    defer arena.free(end_tokens);
    const end_lp = LineParser.init(end_line, end_tokens);
    if (isEndAssociateLine(end_lp)) {
        index.* += 1;
    } else if (!isUnitTerminatorLine(end_lp)) {
        return error.UnexpectedToken;
    }

    return .{
        .label = label,
        .node = .{ .associate_block = .{
            .bindings = bindings,
            .stmts = body,
        } },
    };
}
