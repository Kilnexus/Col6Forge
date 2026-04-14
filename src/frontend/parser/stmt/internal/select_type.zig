const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const logical_line = @import("../../../logical_line.zig");
const lexer = @import("../../../lexer.zig");
const context = @import("../../token_stream.zig");
const decl = @import("../../decl/mod.zig");
const type_specs = @import("../../decl/type_specs.zig");
const expr = @import("../../expr.zig");
const parse_diag = @import("../../diagnostic.zig");
const array_info = @import("../../array_info.zig");
const stmt_queries = @import("../../../../common/stmt_queries.zig");
const helpers = @import("../helpers.zig");
const select_case = @import("select_case.zig");
const block_body = @import("block_body.zig");
const stmt_shared = @import("shared.zig");

const LineParser = context.LineParser;
const Stmt = ast.Stmt;
const DoContext = @import("../control_flow.zig").DoContext;
const defaultSourceColumn = stmt_shared.defaultSourceColumn;
const setStmtSourceIfMissing = stmt_shared.setStmtSourceIfMissing;
const lexLine = stmt_shared.lexLine;

pub const ParseStatementFn = block_body.ParseStatementFn;

const ParsedSelector = struct {
    selector: *ast.Expr,
    associate_name: ?[]const u8 = null,
};

pub fn isSelectTypeStart(lp: LineParser) bool {
    var scan = lp;
    consumeOptionalBlockName(&scan);
    if (!scan.isKeywordSplit("SELECT")) return false;
    _ = scan.consumeKeyword("SELECT");
    return scan.isKeywordSplit("TYPE");
}

pub fn isSelectRankStart(lp: LineParser) bool {
    var scan = lp;
    consumeOptionalBlockName(&scan);
    if (!scan.isKeywordSplit("SELECT")) return false;
    _ = scan.consumeKeyword("SELECT");
    return scan.isKeywordSplit("RANK");
}

fn isSelectStart(lp: LineParser) bool {
    return isSelectTypeStart(lp) or select_case.isSelectCaseStart(lp);
}

fn consumeOptionalBlockName(lp: *LineParser) void {
    if (lp.peek()) |tok| {
        if (tok.kind == .identifier and lp.index + 1 < lp.tokens.len and lp.tokens[lp.index + 1].kind == .colon) {
            _ = lp.next();
            _ = lp.next();
        }
    }
}

fn parseOptionalBlockName(lp: *LineParser, arena: std.mem.Allocator) ?[]const u8 {
    if (lp.peek()) |tok| {
        if (tok.kind == .identifier and lp.index + 1 < lp.tokens.len and lp.tokens[lp.index + 1].kind == .colon) {
            const name = lp.readName(arena) orelse return null;
            _ = lp.next();
            return name;
        }
    }
    return null;
}

fn isEndSelectLine(lp: LineParser) bool {
    return helpers.isEndKeywordLine(lp, "ENDSELECT", "SELECT");
}

fn isUnitTerminatorLine(lp: LineParser) bool {
    const end_span = lp.keywordSpan("END") orelse return false;
    const next_idx = lp.index + end_span;
    if (next_idx >= lp.tokens.len) return true;
    const next_tok = lp.tokens[next_idx];
    if (next_tok.kind != .identifier) return true;
    return !context.eqNoCase(lp.tokenText(next_tok), "SELECT");
}

fn isTypeIsLine(lp: LineParser) bool {
    if (!lp.isKeywordSplit("TYPE")) return false;
    var scan = lp;
    _ = scan.consumeKeyword("TYPE");
    return scan.isKeywordSplit("IS");
}

fn isClassIsLine(lp: LineParser) bool {
    if (!lp.isKeywordSplit("CLASS")) return false;
    var scan = lp;
    _ = scan.consumeKeyword("CLASS");
    return scan.isKeywordSplit("IS");
}

fn isClassDefaultLine(lp: LineParser) bool {
    if (lp.isKeywordSplit("CLASSDEFAULT")) return true;
    if (!lp.isKeywordSplit("CLASS")) return false;
    var scan = lp;
    _ = scan.consumeKeyword("CLASS");
    return scan.isKeywordSplit("DEFAULT");
}

pub fn isSelectTypeClauseLine(lp: LineParser) bool {
    return isTypeIsLine(lp) or isClassIsLine(lp) or isClassDefaultLine(lp);
}

fn isRankClauseLine(lp: LineParser) bool {
    if (lp.isKeywordSplit("RANKDEFAULT")) return true;
    if (!lp.isKeywordSplit("RANK")) return false;
    var scan = lp;
    _ = scan.consumeKeyword("RANK");
    return scan.peekIs(.l_paren) or scan.isKeywordSplit("DEFAULT");
}

fn isSyntacticallyInvalidSelectRankSelector(selector: *ast.Expr, associate_name: ?[]const u8) bool {
    if (associate_name != null) return false;
    return switch (selector.*) {
        .identifier => false,
        .component => |comp| comp.has_parens or comp.args.len != 0,
        .call_or_subscript, .substring => true,
        else => false,
    };
}

const SelectRankSelectorState = enum {
    ok,
    invalid_syntax,
    non_assumed_rank,
    pointer_or_allocatable,
};

fn selectRankSelectorState(
    selector: *ast.Expr,
    associate_name: ?[]const u8,
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) SelectRankSelectorState {
    if (isSyntacticallyInvalidSelectRankSelector(selector, associate_name)) return .invalid_syntax;
    const name = switch (selector.*) {
        .identifier => |ident| ident,
        else => return .non_assumed_rank,
    };
    const info = array_names.get(name) orelse return .non_assumed_rank;
    if (info.pointer or info.allocatable) return .pointer_or_allocatable;
    if (!info.assumed_rank) return .non_assumed_rank;
    return .ok;
}

fn selectRankWrappedAssumedRankName(
    selector: *ast.Expr,
    associate_name: ?[]const u8,
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) ?[]const u8 {
    if (associate_name != null) return null;
    const name = switch (selector.*) {
        .unary => |un| switch (un.expr.*) {
            .identifier => |ident| ident,
            else => return null,
        },
        else => return null,
    };
    const info = array_names.get(name) orelse return null;
    if (!info.assumed_rank) return null;
    return name;
}

fn parseSelectRankClauseHeader(
    lp: *LineParser,
    arena: std.mem.Allocator,
) anyerror!ast.SelectRankClause {
    if (lp.isKeywordSplit("RANKDEFAULT")) {
        _ = lp.consumeKeyword("RANKDEFAULT");
        return .{ .kind = .rank_default };
    }
    if (!lp.consumeKeyword("RANK")) return error.UnexpectedToken;
    if (lp.consumeKeyword("DEFAULT")) {
        return .{ .kind = .rank_default };
    }
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    if (lp.peekIs(.star)) {
        _ = lp.next();
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        return .{ .kind = .rank_star };
    }
    const rank_expr = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return .{
        .kind = .rank_value,
        .rank_expr = rank_expr,
    };
}

fn evalSelectRankConstExpr(
    expr_node: *ast.Expr,
    param_ints: *const std.StringHashMap(i64),
) ?i64 {
    return switch (expr_node.*) {
        .literal => |lit| switch (lit.kind) {
            .integer => std.fmt.parseInt(i64, lit.text, 10) catch null,
            else => null,
        },
        .identifier => |name| param_ints.get(name),
        .unary => |un| blk: {
            const inner = evalSelectRankConstExpr(un.expr, param_ints) orelse break :blk null;
            break :blk switch (un.op) {
                .plus => inner,
                .minus => -inner,
                else => null,
            };
        },
        else => null,
    };
}

fn selectRankClauseErrorMessage(
    clause: ast.SelectRankClause,
    param_ints: *const std.StringHashMap(i64),
) ?[]const u8 {
    if (clause.kind != .rank_value) return null;
    const rank_expr = clause.rank_expr orelse return "must be a scalar";
    const rank_value = evalSelectRankConstExpr(rank_expr, param_ints) orelse return "must be a scalar";
    if (rank_value < 0 or rank_value > 15) return "must not be less than zero or greater than 15";
    return null;
}

fn parseSelectTypeSelector(lp: *LineParser, arena: std.mem.Allocator) anyerror!ParsedSelector {
    if (lp.peek()) |tok| {
        if (tok.kind == .identifier and lp.index + 2 < lp.tokens.len and lp.tokens[lp.index + 1].kind == .equals and lp.tokens[lp.index + 2].kind == .greater) {
            const associate_name = lp.readName(arena) orelse return error.MissingName;
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            _ = lp.expect(.greater) orelse return error.UnexpectedToken;
            return .{
                .associate_name = associate_name,
                .selector = try expr.parseExpr(lp, arena, 0),
            };
        }
    }
    return .{
        .selector = try expr.parseExpr(lp, arena, 0),
    };
}

fn parseSelectTypeClauseSpec(
    lp: *LineParser,
    arena: std.mem.Allocator,
    kind: ast.SelectTypeClauseKind,
) anyerror!ast.SelectTypeClause {
    if (kind == .class_default) {
        return .{ .kind = .class_default, .stmts = &.{} };
    }

    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var clause = ast.SelectTypeClause{
        .kind = kind,
        .stmts = &.{},
    };
    const parsed: ?type_specs.ParsedTypeSpec = type_specs.parseTypeKind(lp, arena) catch |err| switch (err) {
        error.UnknownType => null,
        else => return err,
    };
    if (parsed) |type_spec| {
        clause.type_kind = type_spec.type_kind;
        clause.kind_selector = type_spec.kind_selector;
        clause.char_len = type_spec.char_len;
        clause.char_len_deferred = type_spec.char_len_deferred;
        clause.derived_type_name = type_spec.derived_type_name;
    } else {
        clause.type_kind = .derived;
        clause.derived_type_name = lp.readName(arena) orelse return error.MissingName;
        if (lp.consume(.l_paren)) {
            clause.derived_params = try parseSelectTypeDerivedParams(lp, arena);
        }
    }

    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return clause;
}

fn parseSelectTypeDerivedParams(
    lp: *LineParser,
    arena: std.mem.Allocator,
) anyerror![]const ast.SelectTypeDerivedParam {
    var params = std.array_list.Managed(ast.SelectTypeDerivedParam).init(arena);
    while (!lp.peekIs(.r_paren)) {
        const name = lp.readName(arena) orelse return error.MissingName;
        _ = lp.expect(.equals) orelse return error.UnexpectedToken;
        const value_kind: ast.SelectTypeDerivedParamValueKind = if (lp.consume(.star))
            .star
        else if (lp.consume(.colon))
            .colon
        else blk: {
            _ = try expr.parseExpr(lp, arena, 0);
            break :blk .expr;
        };
        try params.append(.{
            .name = name,
            .value_kind = value_kind,
        });
        if (!lp.consume(.comma)) break;
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return params.toOwnedSlice();
}

fn consumeBalancedParens(lp: *LineParser) anyerror!void {
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
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
}

pub fn parseSelectTypeClauseHeader(
    lp: *LineParser,
    arena: std.mem.Allocator,
) anyerror!ast.SelectTypeClause {
    if (isClassDefaultLine(lp.*)) {
        if (!lp.consumeKeyword("CLASSDEFAULT")) {
            if (!lp.consumeKeyword("CLASS")) return error.UnexpectedToken;
            if (!lp.consumeKeyword("DEFAULT")) return error.UnexpectedToken;
        }
        return .{ .kind = .class_default, .stmts = &.{} };
    }

    const kind: ast.SelectTypeClauseKind = if (isTypeIsLine(lp.*)) .type_is else .class_is;
    if (kind == .type_is) {
        if (!lp.consumeKeyword("TYPE")) return error.UnexpectedToken;
    } else {
        if (!lp.consumeKeyword("CLASS")) return error.UnexpectedToken;
    }
    if (!lp.consumeKeyword("IS")) return error.UnexpectedToken;
    var clause = try parseSelectTypeClauseSpec(lp, arena, kind);
    if (lp.peek()) |_| {
        clause.has_trailing_tokens = true;
        if (lp.peek()) |tok| {
            if (tok.kind == .identifier) {
                clause.trailing_name = lp.readName(arena);
            }
        }
    }
    return clause;
}

pub fn parseOrphanSelectTypeClauseStatement(
    arena: std.mem.Allocator,
    label: ?[]const u8,
    lp: *LineParser,
) anyerror!Stmt {
    const clause = try parseSelectTypeClauseHeader(lp, arena);
    return .{
        .label = label,
        .node = .{ .orphan_select_type_clause = clause },
    };
}

fn parseSelectTypeClauseBody(
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
                return isSelectTypeClauseLine(lp) or isEndSelectLine(lp);
            }
        }.stop,
    );
}

fn parseSelectRankClauseBody(
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
                return isRankClauseLine(lp) or isEndSelectLine(lp);
            }
        }.stop,
    );
}

pub fn parseSelectTypeStatement(
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
    const construct_name = parseOptionalBlockName(lp, arena);
    if (!lp.consumeKeyword("SELECT")) return error.UnexpectedToken;
    if (!lp.consumeKeyword("TYPE")) return error.UnexpectedToken;
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const parsed_selector = try parseSelectTypeSelector(lp, arena);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;

    index.* += 1;
    var leading_stmts = std.array_list.Managed(Stmt).init(arena);
    var clauses = std.array_list.Managed(ast.SelectTypeClause).init(arena);
    var saw_end_select = false;
    var end_source: ast.SourceRef = .{};

    while (index.* < lines.len) {
        const line = lines[index.*];
        const tokens = try lexLine(arena, line, diag_bag, lex_diag_bag);
        defer arena.free(tokens);
        var scan = LineParser.init(line, tokens);
        if (clauses.items.len == 0 and isUnitTerminatorLine(scan)) {
            return .{
                .label = label,
                .node = .{ .select_type_block = .{
                    .selector = parsed_selector.selector,
                    .associate_name = parsed_selector.associate_name,
                    .construct_name = construct_name,
                    .leading_stmts = try leading_stmts.toOwnedSlice(),
                    .clauses = try clauses.toOwnedSlice(),
                    .end_source = end_source,
                } },
            };
        }
        if (clauses.items.len == 0 and isSelectStart(scan)) {
            return .{
                .label = label,
                .node = .{ .select_type_block = .{
                    .selector = parsed_selector.selector,
                    .associate_name = parsed_selector.associate_name,
                    .construct_name = construct_name,
                    .leading_stmts = try leading_stmts.toOwnedSlice(),
                    .clauses = try clauses.toOwnedSlice(),
                    .end_source = end_source,
                } },
            };
        }
        if (isSelectStart(scan)) return error.UnexpectedToken;
        if (isEndSelectLine(scan)) {
            end_source = .{
                .line = line.span.start_line,
                .column = defaultSourceColumn(line),
                .text = line.text,
            };
            index.* += 1;
            saw_end_select = true;
            break;
        }
        if (!isSelectTypeClauseLine(scan)) {
            if (clauses.items.len != 0) return error.UnexpectedToken;
            if (decl.isDeclarationStart(scan)) return error.DeclarationInIfBlock;
            var stmt = try parse_statement_fn(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag);
            setStmtSourceIfMissing(&stmt, line);
            try leading_stmts.append(stmt);
            continue;
        }

        var clause = try parseSelectTypeClauseHeader(&scan, arena);
        clause.source = .{
            .line = line.span.start_line,
            .column = defaultSourceColumn(line),
            .text = line.text,
        };

        index.* += 1;
        clause.stmts = try parseSelectTypeClauseBody(
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
        try clauses.append(clause);
    }

    if (!saw_end_select) {
        if (clauses.items.len == 0) {
            return .{
                .label = label,
                .node = .{ .select_type_block = .{
                    .selector = parsed_selector.selector,
                    .associate_name = parsed_selector.associate_name,
                    .construct_name = construct_name,
                    .leading_stmts = try leading_stmts.toOwnedSlice(),
                    .clauses = try clauses.toOwnedSlice(),
                    .end_source = end_source,
                } },
            };
        }
        return error.UnexpectedEOF;
    }

    return .{
        .label = label,
        .node = .{ .select_type_block = .{
            .selector = parsed_selector.selector,
            .associate_name = parsed_selector.associate_name,
            .construct_name = construct_name,
            .leading_stmts = try leading_stmts.toOwnedSlice(),
            .clauses = try clauses.toOwnedSlice(),
            .end_source = end_source,
        } },
    };
}

pub fn parseSelectRankStatement(
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
    const construct_name = parseOptionalBlockName(lp, arena);
    if (!lp.consumeKeyword("SELECT")) return error.UnexpectedToken;
    if (!lp.consumeKeyword("RANK")) return error.UnexpectedToken;
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const parsed_selector = try parseSelectTypeSelector(lp, arena);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    const selector_state = selectRankSelectorState(parsed_selector.selector, parsed_selector.associate_name, array_names);
    const selector_name = parsed_selector.associate_name orelse switch (parsed_selector.selector.*) {
        .identifier => |name| name,
        else => null,
    };
    const wrapped_assumed_rank_name = selectRankWrappedAssumedRankName(parsed_selector.selector, parsed_selector.associate_name, array_names);
    if (selector_state == .invalid_syntax) {
        diag_bag.set(
            lp.line.span.start_line,
            defaultSourceColumn(lp.line),
            catalog.parser.unexpected_token.code,
            "Syntax error in argument list",
            lp.line.text,
        );
    } else if (selector_state == .non_assumed_rank) {
        diag_bag.set(
            lp.line.span.start_line,
            defaultSourceColumn(lp.line),
            catalog.semantic.assignment_type_mismatch.code,
            "must be an assumed rank variable",
            lp.line.text,
        );
    } else if (selector_state == .pointer_or_allocatable) {
        diag_bag.set(
            lp.line.span.start_line,
            defaultSourceColumn(lp.line),
            catalog.semantic.assignment_type_mismatch.code,
            "cannot be used with the pointer or allocatable selector",
            lp.line.text,
        );
    }

    index.* += 1;
    var body_stmts = std.array_list.Managed(Stmt).init(arena);
    var clauses = std.array_list.Managed(ast.SelectRankClause).init(arena);
    var saw_end_select = false;
    var end_source: ast.SourceRef = .{};

    while (index.* < lines.len) {
        const line = lines[index.*];
        const tokens = try lexLine(arena, line, diag_bag, lex_diag_bag);
        defer arena.free(tokens);
        var scan = LineParser.init(line, tokens);

        if (isEndSelectLine(scan)) {
            end_source = .{
                .line = line.span.start_line,
                .column = defaultSourceColumn(line),
                .text = line.text,
            };
            index.* += 1;
            saw_end_select = true;
            break;
        }
        if (isRankClauseLine(scan)) {
            if (selector_state == .invalid_syntax or selector_state == .non_assumed_rank) {
                diag_bag.set(
                    line.span.start_line,
                    defaultSourceColumn(line),
                    catalog.parser.unexpected_token.code,
                    "Unexpected RANK statement",
                    line.text,
                );
                index.* += 1;
                continue;
            }
            var clause = try parseSelectRankClauseHeader(&scan, arena);
            clause.source = .{
                .line = line.span.start_line,
                .column = defaultSourceColumn(line),
                .text = line.text,
            };
            if (selector_state == .pointer_or_allocatable and clause.kind == .rank_star) {
                diag_bag.set(
                    line.span.start_line,
                    defaultSourceColumn(line),
                    catalog.semantic.assignment_type_mismatch.code,
                    "cannot be used with the pointer or allocatable selector",
                    line.text,
                );
                index.* += 1;
                continue;
            }
            if (selectRankClauseErrorMessage(clause, param_ints)) |message| {
                diag_bag.set(
                    line.span.start_line,
                    defaultSourceColumn(line),
                    catalog.semantic.assignment_type_mismatch.code,
                    message,
                    line.text,
                );
                index.* += 1;
                continue;
            }
            try clauses.append(clause);
            index.* += 1;
            const clause_stmts = try parseSelectRankClauseBody(
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
            clause.stmts = clause_stmts;
            if (selector_state == .ok and clause.kind == .rank_star and selector_name != null) {
                for (clause_stmts) |stmt| {
                    if (stmt_queries.stmtUsesWholeSelectorArray(stmt, selector_name.?)) {
                        diag_bag.set(
                            if (stmt.source_line == 0) line.span.start_line else stmt.source_line,
                            if (stmt.source_column == 0) defaultSourceColumn(line) else stmt.source_column,
                            catalog.semantic.assignment_type_mismatch.code,
                            "assumed-size array",
                            stmt.source_text,
                        );
                    }
                }
            }
            for (clause_stmts) |stmt| try body_stmts.append(stmt);
            continue;
        }
        if (selector_state == .ok and clauses.items.len == 0) {
            diag_bag.set(
                line.span.start_line,
                defaultSourceColumn(line),
                catalog.parser.unexpected_token.code,
                "Expected RANK or RANK DEFAULT",
                line.text,
            );
        }
        if (decl.isDeclarationStart(scan)) return error.DeclarationInIfBlock;
        var stmt = try parse_statement_fn(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag);
        setStmtSourceIfMissing(&stmt, line);
        if (selector_state == .non_assumed_rank and wrapped_assumed_rank_name != null and stmt_queries.stmtUsesWholeSelectorArray(stmt, wrapped_assumed_rank_name.?)) {
            diag_bag.set(
                if (stmt.source_line == 0) line.span.start_line else stmt.source_line,
                if (stmt.source_column == 0) defaultSourceColumn(line) else stmt.source_column,
                catalog.semantic.assignment_type_mismatch.code,
                "may only be used as actual argument",
                stmt.source_text,
            );
        }
        try body_stmts.append(stmt);
    }

    if (!saw_end_select) return error.UnexpectedEOF;
    if (selector_state == .invalid_syntax or selector_state == .non_assumed_rank) {
        diag_bag.set(
            end_source.line,
            if (end_source.column == 0) 1 else end_source.column,
            catalog.parser.unexpected_token.code,
            "Expecting END SUBROUTINE statement",
            end_source.text,
        );
    }

    const binding_name = parsed_selector.associate_name orelse switch (parsed_selector.selector.*) {
        .identifier => |name| name,
        else => null,
    };
    const bindings = if (binding_name) |name| blk: {
        const out = try arena.alloc(ast.AssociateBinding, 1);
        out[0] = .{ .name = name, .selector = parsed_selector.selector };
        break :blk out;
    } else blk: {
        break :blk try arena.alloc(ast.AssociateBinding, 0);
    };

    return .{
        .label = label,
        .node = .{ .associate_block = .{
            .bindings = bindings,
            .stmts = try body_stmts.toOwnedSlice(),
            .select_rank = .{
                .construct_name = construct_name,
                .clauses = try clauses.toOwnedSlice(),
                .end_source = end_source,
            },
        } },
    };
}
