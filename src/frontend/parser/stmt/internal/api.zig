const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const logical_line = @import("../../../logical_line.zig");
const lexer = @import("../../../lexer.zig");
const context = @import("../../token_stream.zig");
const parse_diag = @import("../../diagnostic.zig");
const array_info = @import("../../array_info.zig");
const expr = @import("../../expr.zig");
const action_stmt = @import("action_stmt.zig");
const control_flow = @import("../control_flow.zig");
const control_flow_bridge = @import("control_flow_bridge.zig");
const if_stmt = @import("if_stmt.zig");
const associate_stmt = @import("associate_stmt.zig");
const helpers = @import("../helpers.zig");
const select_case = @import("select_case.zig");
const select_type = @import("select_type.zig");
const stmt_shared = @import("shared.zig");

const LineParser = context.LineParser;
const Stmt = ast.Stmt;
const StmtNode = ast.StmtNode;
const DoContext = control_flow.DoContext;
const defaultSourceColumn = stmt_shared.defaultSourceColumn;
const setStmtSourceIfMissing = stmt_shared.setStmtSourceIfMissing;
const makeStmtWithSource = stmt_shared.makeStmtWithSource;
const lexLine = stmt_shared.lexLine;

fn setParseDiagnosticFromStream(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine, lp: LineParser, err: anyerror) void {
    const info = parse_diag.errorInfo(err);
    var line_no = line.span.start_line;
    var column: usize = 1;
    if (lp.index < lp.tokens.len) {
        line_no = lp.tokens[lp.index].line;
        column = lp.tokens[lp.index].column;
    } else if (lp.tokens.len > 0) {
        line_no = lp.tokens[lp.tokens.len - 1].range.end.line;
        column = lp.tokens[lp.tokens.len - 1].range.end.column;
    }
    diag_bag.set(line_no, column, info.code, info.message, line.text);
}

fn maybeSetBareCallLikeVariableDiagnostic(
    arena: std.mem.Allocator,
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    tokens: []lexer.Token,
) bool {
    if (tokens.len == 0) return false;

    var scan = LineParser.init(line, tokens);
    const target = expr.parseExpr(&scan, arena, 0) catch return false;
    if (scan.peek() != null) return false;

    const proc_name = switch (target.*) {
        .call_or_subscript => |call| call.name,
        .component => |comp| if (comp.has_parens) comp.name else return false,
        else => return false,
    };

    const first_tok = tokens[0];
    const message = std.fmt.allocPrint(arena, "'{s}' at (1) is not a variable", .{proc_name}) catch return false;
    diag_bag.set(first_tok.line, first_tok.column, catalog.parser.unexpected_token.code, message, line.text);
    return true;
}

fn actionCallbacks() action_stmt.ActionCallbacks {
    return .{
        .maybeAttachLoopExitLabelFn = control_flow_bridge.maybeAttachLoopExitLabel,
        .resolveExitLabelFn = control_flow_bridge.resolveExitLabel,
        .resolveCycleLabelFn = control_flow_bridge.resolveCycleLabel,
        .parseWhereAsIfSingleFn = if_stmt.parseWhereAsIfSingle,
    };
}

pub fn parseStatement(
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) anyerror!Stmt {
    var diag_bag = parse_diag.Bag.init(arena);
    defer diag_bag.deinit();
    var lex_diag_bag = lexer.Bag.init(arena);
    defer lex_diag_bag.deinit();
    return parseStatementWithDiagnostics(
        arena,
        lines,
        index,
        do_ctx,
        param_ints,
        param_strings,
        array_names,
        &diag_bag,
        &lex_diag_bag,
    );
}

pub fn parseStatementWithDiagnostics(
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,
) anyerror!Stmt {
    if (do_ctx.popPending()) |pending| {
        try control_flow_bridge.closeCompletedLabeledDoLoops(do_ctx, pending.label);
        return pending;
    }
    const line = lines[index.*];
    const tokens = try lexLine(arena, line, diag_bag, lex_diag_bag);
    defer arena.free(tokens);
    var lp = LineParser.init(line, tokens);
    const label = line.label;
    try control_flow_bridge.closeCompletedLabeledDoLoops(do_ctx, label);

    if (helpers.isEndDo(lp)) {
        if (!lp.consumeKeyword("ENDDO")) {
            _ = lp.consumeKeyword("END");
            _ = lp.consumeKeyword("DO");
        }
        const loop_frame = try do_ctx.popLoopOrError();
        const end_label = loop_frame.cycle_label;
        if (loop_frame.exit_label) |exit_label| {
            try do_ctx.pushPending(.{ .label = exit_label, .node = .{ .cont = {} } });
        }
        index.* += 1;
        return makeStmtWithSource(line, end_label, .{ .cont = {} });
    }
    if (control_flow_bridge.isEndBlockLine(lp)) {
        const end_block_name = try control_flow_bridge.parseEndBlockName(&lp, arena);
        const frame = do_ctx.popBlock() orelse return error.UnexpectedToken;
        if (end_block_name) |name| {
            if (frame.name == null or !context.eqNoCase(name, frame.name.?)) return error.UnexpectedToken;
        }
        if (label) |line_label| {
            try do_ctx.pushPending(.{ .label = line_label, .node = .{ .cont = {} } });
        }
        index.* += 1;
        return makeStmtWithSource(line, frame.end_label, .{ .cont = {} });
    }
    if (control_flow_bridge.isBlockStartLine(lp)) {
        const block_name = try control_flow_bridge.parseBlockStartName(&lp, arena);
        const end_label = try do_ctx.nextBlockLabel(arena);
        try do_ctx.pushBlock(block_name, end_label);
        index.* += 1;
        return makeStmtWithSource(line, label, .{ .cont = {} });
    }
    if (control_flow_bridge.isNamedDoStart(lp)) {
        var do_lp = lp;
        const construct_name = do_lp.readName(arena) orelse return error.MissingName;
        _ = do_lp.expect(.colon) orelse return error.UnexpectedToken;
        if (!do_lp.consumeKeyword("DO")) return error.UnexpectedToken;
        const stmt_node = control_flow.parseDoStatement(arena, &do_lp, do_ctx) catch |err| {
            setParseDiagnosticFromStream(diag_bag, line, do_lp, err);
            return err;
        };
        if (control_flow_bridge.loopEndLabel(stmt_node)) |cycle_label| {
            const exit_label = try control_flow_bridge.maybeAttachLoopExitLabel(arena, do_ctx, stmt_node);
            try do_ctx.updateTopDoName(construct_name, cycle_label, exit_label);
        }
        index.* += 1;
        return makeStmtWithSource(line, label, stmt_node);
    }
    if (lp.isKeywordSplit("FORALL")) {
        var stmt = parseForallStatement(arena, lines, index, label, &lp, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parseStatementWithDiagnostics) catch |err| {
            if (!diag_bag.has()) setParseDiagnosticFromStream(diag_bag, line, lp, err);
            return err;
        };
        setStmtSourceIfMissing(&stmt, line);
        return stmt;
    }
    if (lp.isKeywordSplit("IF")) {
        if (tryParseAmbiguousAssignment(arena, line, lp, .top_level)) |stmt_node| {
            index.* += 1;
            return makeStmtWithSource(line, label, stmt_node);
        }
        var stmt = if_stmt.parseIfStatement(arena, lines, index, label, &lp, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parseStatementWithDiagnostics, actionCallbacks()) catch |err| {
            if (!diag_bag.has()) setParseDiagnosticFromStream(diag_bag, line, lp, err);
            return err;
        };
        setStmtSourceIfMissing(&stmt, line);
        return stmt;
    }
    if (lp.isKeywordSplit("WHERE")) {
        var stmt = if_stmt.parseWhereStatement(arena, lines, index, label, &lp, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parseStatementWithDiagnostics) catch |err| {
            if (!diag_bag.has()) setParseDiagnosticFromStream(diag_bag, line, lp, err);
            return err;
        };
        setStmtSourceIfMissing(&stmt, line);
        return stmt;
    }
    if (select_case.isSelectCaseStart(lp)) {
        var stmt = select_case.parseSelectCaseStatement(arena, lines, index, label, &lp, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parseStatementWithDiagnostics) catch |err| {
            if (!diag_bag.has()) setParseDiagnosticFromStream(diag_bag, line, lp, err);
            return err;
        };
        setStmtSourceIfMissing(&stmt, line);
        return stmt;
    }
    if (select_type.isSelectRankStart(lp)) {
        var stmt = select_type.parseSelectRankStatement(arena, lines, index, label, &lp, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parseStatementWithDiagnostics) catch |err| {
            if (!diag_bag.has()) setParseDiagnosticFromStream(diag_bag, line, lp, err);
            return err;
        };
        setStmtSourceIfMissing(&stmt, line);
        return stmt;
    }
    if (select_type.isSelectTypeStart(lp)) {
        var stmt = select_type.parseSelectTypeStatement(arena, lines, index, label, &lp, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parseStatementWithDiagnostics) catch |err| {
            if (!diag_bag.has()) setParseDiagnosticFromStream(diag_bag, line, lp, err);
            return err;
        };
        setStmtSourceIfMissing(&stmt, line);
        return stmt;
    }
    if (associate_stmt.isAssociateStart(lp)) {
        var stmt = associate_stmt.parseAssociateStatement(arena, lines, index, label, &lp, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parseStatementWithDiagnostics) catch |err| {
            if (!diag_bag.has()) setParseDiagnosticFromStream(diag_bag, line, lp, err);
            return err;
        };
        setStmtSourceIfMissing(&stmt, line);
        return stmt;
    }
    if (select_type.isSelectTypeClauseLine(lp)) {
        var stmt = select_type.parseOrphanSelectTypeClauseStatement(arena, label, &lp) catch |err| {
            if (!diag_bag.has()) setParseDiagnosticFromStream(diag_bag, line, lp, err);
            return err;
        };
        setStmtSourceIfMissing(&stmt, line);
        index.* += 1;
        return stmt;
    }
    const action_node = action_stmt.parseActionStmtNode(arena, line, &lp, do_ctx, .top_level, actionCallbacks()) catch |err| {
        if (!diag_bag.has()) {
            if (!(err == error.UnexpectedToken and maybeSetBareCallLikeVariableDiagnostic(arena, diag_bag, line, tokens))) {
                setParseDiagnosticFromStream(diag_bag, line, lp, err);
            }
        }
        return err;
    };
    if (lp.peek() != null) {
        const tok = lp.peek().?;
        const message = switch (action_node) {
            .deallocate => "Syntax error in DEALLOCATE",
            .allocate => "Syntax error in ALLOCATE",
            else => catalog.parser.unexpected_token.message,
        };
        diag_bag.set(tok.line, tok.column, catalog.parser.unexpected_token.code, message, line.text);
        return error.UnexpectedToken;
    }
    index.* += 1;
    return makeStmtWithSource(line, label, action_node);
}

pub fn parseIfBlock(
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) anyerror![]Stmt {
    var diag_bag = parse_diag.Bag.init(arena);
    defer diag_bag.deinit();
    var lex_diag_bag = lexer.Bag.init(arena);
    defer lex_diag_bag.deinit();
    return parseIfBlockWithDiagnostics(
        arena,
        lines,
        index,
        do_ctx,
        param_ints,
        param_strings,
        array_names,
        &diag_bag,
        &lex_diag_bag,
    );
}

pub fn parseIfBlockWithDiagnostics(
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,
) anyerror![]Stmt {
    return if_stmt.parseIfBlock(
        arena,
        lines,
        index,
        do_ctx,
        param_ints,
        param_strings,
        array_names,
        diag_bag,
        lex_diag_bag,
        parseStatementWithDiagnostics,
    );
}

fn tryParseAmbiguousAssignment(
    arena: std.mem.Allocator,
    line: logical_line.LogicalLine,
    lp: LineParser,
    mode: action_stmt.ActionParseMode,
) ?StmtNode {
    _ = mode;
    if (!helpers.looksLikeBlankInsensitiveAssignment(lp)) return null;
    return helpers.tryParseBlankInsensitiveAssignment(arena, line, lp);
}

fn shouldTreatDoAsAssignment(lp: LineParser) bool {
    var do_scan = lp;
    _ = do_scan.consumeKeyword("DO");
    const is_block_do = do_scan.peekIs(.identifier) and helpers.nextTokenIsEquals(do_scan);
    const looks_like_assignment = !helpers.hasCommaAfterEquals(do_scan);
    return !is_block_do and (helpers.labelFollowedByEquals(lp) or looks_like_assignment);
}

fn shouldTreatSplitDoAsAssignment(lp: LineParser) bool {
    var do_lp = lp;
    _ = do_lp.next();
    _ = do_lp.next();
    return helpers.labelFollowedByEquals(do_lp) or !helpers.hasCommaAfterEquals(do_lp);
}

fn parseForallStatement(
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
    parse_statement_fn: if_stmt.ParseStatementFn,
) anyerror!Stmt {
    if (!lp.consumeKeyword("FORALL")) return error.UnexpectedToken;
    if (!lp.consume(.l_paren)) return error.UnexpectedToken;
    const header_start = lp.index;
    var depth: usize = 1;
    while (depth > 0) {
        const tok = lp.peek() orelse return error.UnexpectedToken;
        _ = lp.next();
        switch (tok.kind) {
            .l_paren => depth += 1,
            .r_paren => depth -= 1,
            else => {},
        }
    }
    const header_end = lp.index - 1;
    const header_errors = validateForallHeader(lines[index.*], lp.tokens[header_start..header_end], array_names, diag_bag);
    if (header_errors != 0) {
        const header_line = lines[index.*];
        index.* += 1;
        return .{
            .label = label,
            .node = .{ .cont = {} },
            .source_line = header_line.span.start_line,
            .source_column = defaultSourceColumn(header_line),
            .source_text = header_line.text,
        };
    }

    // Block FORALL: FORALL (...) <newline> ... END FORALL
    if (lp.peek() == null) {
        const header_line = lines[index.*];
        index.* += 1;
        var block_stmts = std.array_list.Managed(Stmt).init(arena);
        var end_seen = false;
        while (index.* < lines.len) {
            const body_line = lines[index.*];
            const body_tokens = try lexLine(arena, body_line, diag_bag, lex_diag_bag);
            defer arena.free(body_tokens);
            const body_lp = LineParser.init(body_line, body_tokens);
            if (isEndForallLine(body_lp)) {
                end_seen = true;
                index.* += 1;
                break;
            }
            const parsed = try parse_statement_fn(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag);
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

    // Single-line FORALL is parsed as one action statement body.
    const body = action_stmt.parseActionStmtNode(arena, lines[index.*], lp, do_ctx, .top_level, actionCallbacks()) catch return error.UnexpectedToken;
    if (lp.peek() != null) return error.UnexpectedToken;
    index.* += 1;
    return makeStmtWithSource(lines[index.* - 1], label, body);
}

fn isEndForallLine(lp: LineParser) bool {
    return helpers.isEndKeywordLine(lp, "ENDFORALL", "FORALL");
}

fn validateForallHeader(
    line: logical_line.LogicalLine,
    tokens: []const lexer.Token,
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
) usize {
    var errors: usize = 0;
    var indices_buf: [32][]const u8 = undefined;
    var indices_len: usize = 0;
    var pos: usize = 0;
    while (pos < tokens.len) {
        const clause_start = pos;
        const clause_end = findForallClauseEnd(tokens, clause_start);
        const eq_pos = findTopLevelToken(tokens, clause_start, clause_end, .equals);
        if (eq_pos == null) {
            errors += validateForallMask(line, tokens[clause_start..clause_end], array_names, diag_bag);
        } else {
            const target_name = validateForallIndexTarget(line, tokens[clause_start..eq_pos.?], diag_bag);
            if (target_name) |name| {
                errors += validateForallTriplet(line, tokens[eq_pos.? + 1 .. clause_end], name, indices_buf[0..indices_len], diag_bag);
                if (indices_len < indices_buf.len) {
                    indices_buf[indices_len] = name;
                    indices_len += 1;
                }
            } else {
                errors += 1;
            }
        }
        pos = clause_end;
        if (pos < tokens.len and tokens[pos].kind == .comma) pos += 1;
    }
    return errors;
}

fn validateForallIndexTarget(
    line: logical_line.LogicalLine,
    tokens: []const lexer.Token,
    diag_bag: *parse_diag.Bag,
) ?[]const u8 {
    if (tokens.len == 1 and tokens[0].kind == .identifier) return tokenText(line, tokens[0]);
    if (tokens.len >= 1) {
        const tok = tokens[0];
        diag_bag.set(tok.line, tok.column, catalog.parser.invalid_forall_syntax.code, "FORALL index must be a scalar variable of type integer", line.text);
    }
    return null;
}

fn validateForallTriplet(
    line: logical_line.LogicalLine,
    tokens: []const lexer.Token,
    current_index: []const u8,
    prior_indices: []const []const u8,
    diag_bag: *parse_diag.Bag,
) usize {
    var errors: usize = 0;
    for (tokens) |tok| {
        if (tok.kind != .identifier) continue;
        const name = tokenText(line, tok);
        if (!std.ascii.eqlIgnoreCase(name, current_index) and !nameInSetIgnoreCase(name, prior_indices)) continue;
        diag_bag.set(tok.line, tok.column, catalog.parser.invalid_forall_syntax.code, "FORALL index may not appear in triplet specification", line.text);
        errors += 1;
        break;
    }
    const second_colon = secondTopLevelColon(tokens);
    if (second_colon) |colon_pos| {
        const stride = tokens[colon_pos + 1 ..];
        if (tokensRepresentIntegerZero(line, stride)) {
            const tok = if (stride.len != 0) stride[0] else tokens[colon_pos];
            diag_bag.set(tok.line, tok.column, catalog.parser.invalid_forall_syntax.code, "FORALL stride expression at (1) must not be zero", line.text);
            errors += 1;
        }
    }
    return errors;
}

fn validateForallMask(
    line: logical_line.LogicalLine,
    tokens: []const lexer.Token,
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
) usize {
    if (tokens.len == 1 and tokens[0].kind == .identifier) {
        const name = tokenText(line, tokens[0]);
        if (arrayInfoForName(array_names, name)) |info| {
            if (info.rank != 0) {
                diag_bag.set(tokens[0].line, tokens[0].column, catalog.parser.invalid_forall_syntax.code, "FORALL mask requires a scalar LOGICAL expression", line.text);
                return 1;
            }
        }
    }
    return 0;
}

fn findForallClauseEnd(tokens: []const lexer.Token, start: usize) usize {
    var depth: usize = 0;
    var pos = start;
    while (pos < tokens.len) : (pos += 1) {
        switch (tokens[pos].kind) {
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => {
                if (depth > 0) depth -= 1;
            },
            .comma => if (depth == 0) return pos,
            else => {},
        }
    }
    return tokens.len;
}

fn findTopLevelToken(tokens: []const lexer.Token, start: usize, end: usize, kind: lexer.TokenKind) ?usize {
    var depth: usize = 0;
    var pos = start;
    while (pos < end) : (pos += 1) {
        switch (tokens[pos].kind) {
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => {
                if (depth > 0) depth -= 1;
            },
            else => if (depth == 0 and tokens[pos].kind == kind) return pos,
        }
    }
    return null;
}

fn secondTopLevelColon(tokens: []const lexer.Token) ?usize {
    var depth: usize = 0;
    var seen_first = false;
    for (tokens, 0..) |tok, idx| {
        switch (tok.kind) {
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => {
                if (depth > 0) depth -= 1;
            },
            .colon => if (depth == 0) {
                if (seen_first) return idx;
                seen_first = true;
            },
            else => {},
        }
    }
    return null;
}

fn tokensRepresentIntegerZero(line: logical_line.LogicalLine, tokens: []const lexer.Token) bool {
    if (tokens.len == 1 and tokens[0].kind == .integer) {
        return std.mem.eql(u8, tokenText(line, tokens[0]), "0");
    }
    if (tokens.len == 2 and (tokens[0].kind == .plus or tokens[0].kind == .minus) and tokens[1].kind == .integer) {
        return std.mem.eql(u8, tokenText(line, tokens[1]), "0");
    }
    return false;
}

fn tokenText(line: logical_line.LogicalLine, tok: lexer.Token) []const u8 {
    if (tok.end <= line.text.len and tok.start <= tok.end) return line.text[tok.start..tok.end];
    return "";
}

fn nameInSetIgnoreCase(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn arrayInfoForName(array_names: *const std.StringHashMap(array_info.ArrayInfo), name: []const u8) ?array_info.ArrayInfo {
    if (array_names.get(name)) |info| return info;
    var it = array_names.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}
