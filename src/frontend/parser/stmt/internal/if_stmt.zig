const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const logical_line = @import("../../../logical_line.zig");
const lexer = @import("../../../lexer.zig");
const context = @import("../../token_stream.zig");
const decl = @import("../../decl/mod.zig");
const expr = @import("../../expr.zig");
const parse_diag = @import("../../diagnostic.zig");
const array_info = @import("../../array_info.zig");
const helpers = @import("../helpers.zig");
const action_stmt = @import("action_stmt.zig");
const control_flow = @import("../control_flow.zig");
const stmt_shared = @import("shared.zig");

const LineParser = context.LineParser;
const Stmt = ast.Stmt;
const StmtNode = ast.StmtNode;
const Expr = ast.Expr;
const DoContext = control_flow.DoContext;
const defaultSourceColumn = stmt_shared.defaultSourceColumn;
const setStmtSourceIfMissing = stmt_shared.setStmtSourceIfMissing;
const lexLine = stmt_shared.lexLine;

const ElseIfBlock = struct {
    cond: *Expr,
    stmts: []Stmt,
    label: ?[]const u8,
    source_line: usize,
    source_column: usize,
    source_text: []const u8,
};

pub const ParseStatementFn = *const fn (
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,
) anyerror!Stmt;

fn prependLabeledContinue(
    arena: std.mem.Allocator,
    line: logical_line.LogicalLine,
    stmts: []Stmt,
) std.mem.Allocator.Error![]Stmt {
    const line_label = line.label orelse return stmts;
    const out = try arena.alloc(Stmt, stmts.len + 1);
    out[0] = .{
        .label = line_label,
        .node = .{ .cont = {} },
        .source_line = line.span.start_line,
        .source_column = defaultSourceColumn(line),
        .source_text = line.text,
    };
    if (stmts.len > 0) {
        @memcpy(out[1 .. 1 + stmts.len], stmts);
    }
    return out;
}

pub fn parseIfStatement(
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
    action_callbacks: action_stmt.ActionCallbacks,
) anyerror!Stmt {
    if (!lp.consumeKeyword("IF")) return error.UnexpectedToken;
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const cond = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;

    if (helpers.isArithmeticIf(lp.*)) {
        const neg_label = try helpers.parseLabelToken(lp);
        _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        const zero_label = try helpers.parseLabelToken(lp);
        _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        const pos_label = try helpers.parseLabelToken(lp);
        index.* += 1;
        return .{
            .label = label,
            .node = .{ .arith_if = .{
                .condition = cond,
                .neg_label = neg_label,
                .zero_label = zero_label,
                .pos_label = pos_label,
            } },
        };
    }

    if (lp.isKeywordSplit("THEN")) {
        _ = lp.consumeKeyword("THEN");
        index.* += 1;
        const then_stmts = try parseIfBlock(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parse_statement_fn);
        var else_stmts: []Stmt = &.{};
        var else_if_blocks = std.array_list.Managed(ElseIfBlock).init(arena);
        var else_block: ?[]Stmt = null;

        while (index.* < lines.len) {
            const next_line = lines[index.*];
            const next_tokens = try lexLine(arena, next_line, diag_bag, lex_diag_bag);
            defer arena.free(next_tokens);
            var next_lp = LineParser.init(next_line, next_tokens);
            if (next_lp.isKeywordSplit("ELSEIF")) {
                const else_if_block = try parseElseIfBlock(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parse_statement_fn);
                try else_if_blocks.append(else_if_block);
                continue;
            }
            if (!next_lp.isKeywordSplit("ELSE")) break;
            _ = next_lp.consumeKeyword("ELSE");
            if (next_lp.isKeywordSplit("IF")) {
                const else_if_block = try parseElseIfBlock(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parse_statement_fn);
                try else_if_blocks.append(else_if_block);
                continue;
            }
            index.* += 1;
            const parsed_else = try parseIfBlock(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parse_statement_fn);
            else_block = try prependLabeledContinue(arena, next_line, parsed_else);
            break;
        }

        if (else_block) |block| {
            else_stmts = block;
        }
        if (else_if_blocks.items.len != 0) {
            var tail = else_stmts;
            var i: usize = else_if_blocks.items.len;
            while (i > 0) {
                i -= 1;
                const block = else_if_blocks.items[i];
                const stmt = Stmt{
                    .label = block.label,
                    .node = .{ .if_block = .{ .condition = block.cond, .then_stmts = block.stmts, .else_stmts = tail } },
                    .source_line = block.source_line,
                    .source_column = block.source_column,
                    .source_text = block.source_text,
                };
                const slice = try arena.alloc(Stmt, 1);
                slice[0] = stmt;
                tail = slice;
            }
            else_stmts = tail;
        }
        if (index.* >= lines.len) return error.UnexpectedEOF;
        const end_line = lines[index.*];
        const end_tokens = try lexLine(arena, end_line, diag_bag, lex_diag_bag);
        defer arena.free(end_tokens);
        var end_lp = LineParser.init(end_line, end_tokens);
        if (!end_lp.isKeywordSplit("ENDIF") and !helpers.isEndIfLine(end_lp)) return error.ExpectedEndIf;
        if (end_line.label) |end_label| {
            try do_ctx.pushPending(.{ .label = end_label, .node = .{ .cont = {} } });
        }
        index.* += 1;
        return .{
            .label = label,
            .node = .{ .if_block = .{ .condition = cond, .then_stmts = then_stmts, .else_stmts = else_stmts } },
        };
    }

    const stmt_node = try action_stmt.parseInlineStmtNode(lp, arena, do_ctx, action_callbacks);
    if (lp.peek()) |tok| {
        if (stmt_node.* == .stop) {
            diag_bag.set(
                tok.line,
                tok.column,
                catalog.parser.unexpected_token.code,
                "Syntax error in STOP",
                lp.line.text,
            );
            return error.UnexpectedToken;
        }
    }
    // Logical IF bodies are parsed from the current logical line only.
    // This parser owns advancing the line cursor by exactly one line.
    index.* += 1;
    return .{ .label = label, .node = .{ .if_single = .{ .condition = cond, .stmt = stmt_node } } };
}

pub fn parseElseIfBlock(
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
) anyerror!ElseIfBlock {
    const line = lines[index.*];
    const tokens = try lexLine(arena, line, diag_bag, lex_diag_bag);
    defer arena.free(tokens);
    var lp = LineParser.init(line, tokens);
    if (lp.isKeywordSplit("ELSEIF")) {
        _ = lp.consumeKeyword("ELSEIF");
    } else {
        if (!lp.consumeKeyword("ELSE")) return error.UnexpectedToken;
        if (!lp.consumeKeyword("IF")) return error.UnexpectedToken;
    }
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const cond = try expr.parseExpr(&lp, arena, 0);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    if (!lp.isKeywordSplit("THEN")) return error.UnexpectedToken;
    _ = lp.consumeKeyword("THEN");
    index.* += 1;
    const stmts = try parseIfBlock(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parse_statement_fn);
    return .{
        .cond = cond,
        .stmts = stmts,
        .label = line.label,
        .source_line = line.span.start_line,
        .source_column = defaultSourceColumn(line),
        .source_text = line.text,
    };
}

pub fn parseIfBlock(
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
    var stmts = std.array_list.Managed(Stmt).init(arena);
    while (index.* < lines.len) {
        const line = lines[index.*];
        const tokens = try lexLine(arena, line, diag_bag, lex_diag_bag);
        defer arena.free(tokens);
        var lp = LineParser.init(line, tokens);
        if (lp.isKeywordSplit("ELSE") or lp.isKeywordSplit("ELSEIF") or lp.isKeywordSplit("ENDIF") or helpers.isEndIfLine(lp)) {
            break;
        }
        if (decl.isDeclarationStart(lp)) return error.DeclarationInIfBlock;
        var node = try parse_statement_fn(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag);
        setStmtSourceIfMissing(&node, line);
        try stmts.append(node);
    }
    return stmts.toOwnedSlice();
}

pub fn parseWhereAsIfSingle(arena: std.mem.Allocator, lp: *LineParser) anyerror!StmtNode {
    if (!lp.consumeKeyword("WHERE")) return error.UnexpectedToken;
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const cond = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;

    const target = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.equals) orelse return error.UnexpectedToken;
    const value = try expr.parseExpr(lp, arena, 0);
    return .{
        .where_stmt = .{
            .mask = cond,
            .target = target,
            .value = value,
        },
    };
}

pub fn parseWhereStatement(
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
    if (!lp.consumeKeyword("WHERE")) return error.UnexpectedToken;
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const mask = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;

    if (lp.peek() != null) {
        const single = try parseWhereTailAsStmtNode(arena, lp, mask);
        index.* += 1;
        return .{
            .label = label,
            .node = single,
        };
    }

    const header_line = lines[index.*];
    index.* += 1;

    var block_stmts = std.array_list.Managed(Stmt).init(arena);
    var in_elsewhere = false;
    var end_seen = false;
    var saw_unmasked_elsewhere = false;
    var else_mask: ?*Expr = null;

    while (index.* < lines.len) {
        const line = lines[index.*];
        const tokens = try lexLine(arena, line, diag_bag, lex_diag_bag);
        defer arena.free(tokens);
        var body_lp = LineParser.init(line, tokens);

        if (isEndWhereLine(body_lp)) {
            end_seen = true;
            index.* += 1;
            break;
        }
        if (body_lp.isKeywordSplit("ELSEWHERE")) {
            _ = body_lp.consumeKeyword("ELSEWHERE");
            var masked_else: ?*Expr = null;
            if (body_lp.consume(.l_paren)) {
                masked_else = try expr.parseExpr(&body_lp, arena, 0);
                _ = body_lp.expect(.r_paren) orelse return error.UnexpectedToken;
            }
            if (body_lp.peek() != null) return error.UnexpectedToken;
            if (masked_else != null and saw_unmasked_elsewhere) {
                diag_bag.set(
                    line.span.start_line,
                    defaultSourceColumn(line),
                    catalog.parser.unexpected_token.code,
                    "follows previous unmasked ELSEWHERE",
                    line.text,
                );
                return error.UnexpectedToken;
            }
            in_elsewhere = true;
            if (masked_else) |masked| {
                else_mask = masked;
            } else {
                saw_unmasked_elsewhere = true;
                else_mask = null;
            }
            index.* += 1;
            continue;
        }

        var parsed = try parse_statement_fn(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag);
        const active_mask = if (!in_elsewhere)
            mask
        else blk: {
            if (else_mask == null) else_mask = mask;
            break :blk else_mask.?;
        };
        parsed = try rewriteWhereBodyStmt(parsed, active_mask);
        try block_stmts.append(parsed);
    }

    if (!end_seen) return error.UnexpectedEOF;
    if (block_stmts.items.len == 0) {
        return .{
            .label = label,
            .node = .{ .cont = {} },
            .source_line = header_line.span.start_line,
            .source_column = defaultSourceColumn(header_line),
            .source_text = header_line.text,
        };
    }

    var tail = block_stmts.items.len;
    while (tail > 1) {
        tail -= 1;
        try do_ctx.pushPending(block_stmts.items[tail]);
    }

    var first = block_stmts.items[0];
    if (first.label == null) first.label = label;
    return first;
}

fn parseWhereTailAsStmtNode(arena: std.mem.Allocator, lp: *LineParser, mask: *Expr) anyerror!StmtNode {
    const target = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.equals) orelse return error.UnexpectedToken;
    const value = try expr.parseExpr(lp, arena, 0);
    return .{
        .where_stmt = .{
            .mask = mask,
            .target = target,
            .value = value,
        },
    };
}

fn rewriteWhereBodyStmt(stmt_node: Stmt, mask: *Expr) anyerror!Stmt {
    return switch (stmt_node.node) {
        .assignment => |assign| .{
            .label = stmt_node.label,
            .node = .{ .where_stmt = .{
                .mask = mask,
                .target = assign.target,
                .value = assign.value,
            } },
            .source_line = stmt_node.source_line,
            .source_column = stmt_node.source_column,
            .source_text = stmt_node.source_text,
        },
        .where_stmt => stmt_node,
        else => error.UnexpectedToken,
    };
}

fn isEndWhereLine(lp: LineParser) bool {
    return helpers.isEndKeywordLine(lp, "ENDWHERE", "WHERE");
}
