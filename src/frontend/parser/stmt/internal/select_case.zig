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
const stmt_shared = @import("shared.zig");

const LineParser = context.LineParser;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const DoContext = @import("../control_flow.zig").DoContext;
const defaultSourceColumn = stmt_shared.defaultSourceColumn;
const setStmtSourceIfMissing = stmt_shared.setStmtSourceIfMissing;
const lexLine = stmt_shared.lexLine;

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

pub const IsEndSelectLineFn = *const fn (LineParser) bool;

const CaseClause = struct {
    condition: *Expr,
    stmts: []Stmt,
};

const CaseSelectorRange = struct {
    lower: ?*Expr = null,
    upper: ?*Expr = null,
};

const ParsedCaseHeader = struct {
    condition: ?*Expr = null,
    ranges: []const CaseSelectorRange = &.{},
};

const CharacterCaseRange = struct {
    kind_value: i64,
    lower: ?[]const u8 = null,
    upper: ?[]const u8 = null,
};

const IntegerCaseRange = struct {
    lower: ?i64 = null,
    upper: ?i64 = null,
};

const LogicalCaseValue = enum {
    false_value,
    true_value,
};

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

fn selectorNeedsHoist(selector: *Expr) bool {
    return switch (selector.*) {
        .identifier, .literal => false,
        else => true,
    };
}

fn makeIdentifierExpr(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!*Expr {
    const node = try arena.create(Expr);
    node.* = .{ .identifier = name };
    return node;
}

pub fn isSelectCaseStart(lp: LineParser) bool {
    if (lp.isKeywordSplit("SELECTCASE")) return true;
    if (!lp.isKeywordSplit("SELECT")) return false;
    var scan = lp;
    _ = scan.consumeKeyword("SELECT");
    return scan.isKeywordSplit("CASE");
}

pub fn isCaseLine(lp: LineParser) bool {
    return lp.isKeywordSplit("CASE") or lp.isKeywordSplit("CASEDEFAULT");
}

pub fn isEndSelectLine(lp: LineParser) bool {
    return helpers.isEndKeywordLine(lp, "ENDSELECT", "SELECT");
}

pub fn parseSelectCaseStatement(
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
    if (!lp.consumeKeyword("SELECTCASE")) {
        if (!lp.consumeKeyword("SELECT")) return error.UnexpectedToken;
        if (!lp.consumeKeyword("CASE")) return error.UnexpectedToken;
    }
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const selector = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;

    const hoist_selector = selectorNeedsHoist(selector);
    const selector_tmp_name: ?[]const u8 = if (hoist_selector)
        try std.fmt.allocPrint(arena, "__cf_select_case_sel_{d}", .{index.*})
    else
        null;
    const selector_for_clauses = if (selector_tmp_name) |tmp_name|
        try makeIdentifierExpr(arena, tmp_name)
    else
        selector;
    const selector_integer_kind = selectorIntegerKindValue(selector, array_names);
    if (selectorIsDefinitelyArray(selector, array_names)) {
        diag_bag.set(
            lp.line.span.start_line,
            defaultSourceColumn(lp.line),
            catalog.semantic.assignment_type_mismatch.code,
            "must be a scalar expression",
            lp.line.text,
        );
    }

    index.* += 1;

    var clauses = std.array_list.Managed(CaseClause).init(arena);
    var seen_character_ranges = std.array_list.Managed(CharacterCaseRange).init(arena);
    var seen_integer_ranges = std.array_list.Managed(IntegerCaseRange).init(arena);
    var seen_logical_values = std.EnumSet(LogicalCaseValue).initEmpty();
    var default_stmts: ?[]Stmt = null;
    var saw_end_select = false;

    while (index.* < lines.len) {
        const line = lines[index.*];
        const tokens = try lexLine(arena, line, diag_bag, lex_diag_bag);
        defer arena.free(tokens);
        var case_lp = LineParser.init(line, tokens);
        if (isEndSelectLine(case_lp)) {
            if (line.label) |end_label| {
                try do_ctx.pushPending(.{ .label = end_label, .node = .{ .cont = {} } });
            }
            index.* += 1;
            saw_end_select = true;
            break;
        }
        if (!isCaseLine(case_lp)) return error.UnexpectedToken;

        const case_header = try parseCaseHeader(arena, &case_lp, selector_for_clauses);
        diagnoseInvalidIntegerCaseSpecification(diag_bag, line, case_header.ranges, selector_integer_kind);
        diagnoseCharacterCaseOverlap(arena, diag_bag, line, case_header.ranges, seen_character_ranges.items);
        try appendCharacterCaseRanges(arena, &seen_character_ranges, case_header.ranges);
        diagnoseIntegerCaseOverlap(diag_bag, line, case_header.ranges, seen_integer_ranges.items);
        try appendIntegerCaseRanges(&seen_integer_ranges, case_header.ranges);
        diagnoseRepeatedLogicalCase(diag_bag, line, case_header.ranges, &seen_logical_values);
        index.* += 1;
        const parsed_block_stmts = try parseSelectCaseBlock(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag, parse_statement_fn);
        const block_stmts = try prependLabeledContinue(arena, line, parsed_block_stmts);
        if (case_header.condition) |condition| {
            try clauses.append(.{ .condition = condition, .stmts = block_stmts });
        } else {
            if (default_stmts != null) return error.UnexpectedToken;
            default_stmts = block_stmts;
        }
    }

    if (!saw_end_select) return error.UnexpectedEOF;

    var tail: []Stmt = default_stmts orelse &.{};
    var i: usize = clauses.items.len;
    while (i > 0) {
        i -= 1;
        const clause = clauses.items[i];
        const nested = Stmt{
            .label = null,
            .node = .{ .if_block = .{
                .condition = clause.condition,
                .then_stmts = clause.stmts,
                .else_stmts = tail,
            } },
        };
        const slice = try arena.alloc(Stmt, 1);
        slice[0] = nested;
        tail = slice;
    }

    if (tail.len == 0) {
        return .{ .label = label, .node = .{ .cont = {} } };
    }

    if (!hoist_selector) {
        return .{ .label = label, .node = tail[0].node };
    }

    const lowered_stmt = Stmt{
        .label = null,
        .node = tail[0].node,
        .source_line = lp.line.span.start_line,
        .source_column = defaultSourceColumn(lp.line),
        .source_text = lp.line.text,
    };
    try do_ctx.pushPending(lowered_stmt);

    const tmp_target = try makeIdentifierExpr(arena, selector_tmp_name.?);
    return .{
        .label = label,
        .node = .{ .assignment = .{
            .target = tmp_target,
            .value = selector,
        } },
    };
}

pub fn parseCaseHeader(arena: std.mem.Allocator, lp: *LineParser, selector: *Expr) anyerror!ParsedCaseHeader {
    if (lp.consumeKeyword("CASEDEFAULT")) return .{};
    if (!lp.consumeKeyword("CASE")) return error.UnexpectedToken;
    if (lp.consumeKeyword("DEFAULT")) return .{};
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    const parsed = try parseCaseSelectorListCondition(arena, lp, selector);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return parsed;
}

pub fn parseCaseSelectorListCondition(arena: std.mem.Allocator, lp: *LineParser, selector: *Expr) anyerror!ParsedCaseHeader {
    var condition: ?*Expr = null;
    var ranges = std.array_list.Managed(CaseSelectorRange).init(arena);
    while (!lp.peekIs(.r_paren)) {
        const item = try parseCaseSelectorCondition(arena, lp, selector);
        condition = if (condition) |existing|
            try makeBinaryExpr(arena, .or_, existing, item.condition)
        else
            item.condition;
        try ranges.append(item.range);
        if (!lp.consume(.comma)) break;
    }
    return .{
        .condition = condition orelse return error.UnexpectedToken,
        .ranges = try ranges.toOwnedSlice(),
    };
}

pub fn parseCaseSelectorCondition(
    arena: std.mem.Allocator,
    lp: *LineParser,
    selector: *Expr,
) anyerror!struct { condition: *Expr, range: CaseSelectorRange } {
    if (lp.consume(.colon)) {
        const high = try expr.parseExpr(lp, arena, 0);
        return .{
            .condition = try makeBinaryExpr(arena, .le, selector, high),
            .range = .{ .upper = high },
        };
    }

    const first = try expr.parseExpr(lp, arena, 0);
    if (!lp.consume(.colon)) {
        return .{
            .condition = try makeBinaryExpr(arena, .eq, selector, first),
            .range = .{ .lower = first, .upper = first },
        };
    }

    if (lp.peekIs(.comma) or lp.peekIs(.r_paren)) {
        return .{
            .condition = try makeBinaryExpr(arena, .ge, selector, first),
            .range = .{ .lower = first },
        };
    }

    const high = try expr.parseExpr(lp, arena, 0);
    const ge = try makeBinaryExpr(arena, .ge, selector, first);
    const le = try makeBinaryExpr(arena, .le, selector, high);
    return .{
        .condition = try makeBinaryExpr(arena, .and_, ge, le),
        .range = .{ .lower = first, .upper = high },
    };
}

fn makeBinaryExpr(arena: std.mem.Allocator, op: ast.BinaryOp, left: *Expr, right: *Expr) std.mem.Allocator.Error!*Expr {
    const node = try arena.create(Expr);
    node.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
    return node;
}

fn parseSelectCaseBlock(
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
        const lp = LineParser.init(line, tokens);
        if (isCaseLine(lp) or isEndSelectLine(lp)) {
            break;
        }
        if (decl.isDeclarationStart(lp)) return error.DeclarationInIfBlock;
        var node = try parse_statement_fn(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag);
        setStmtSourceIfMissing(&node, line);
        try stmts.append(node);
    }
    return stmts.toOwnedSlice();
}

fn appendCharacterCaseRanges(
    arena: std.mem.Allocator,
    seen: *std.array_list.Managed(CharacterCaseRange),
    ranges: []const CaseSelectorRange,
) !void {
    for (ranges) |range| {
        const converted = characterCaseRangeFromSelector(range) orelse continue;
        const own_lower = if (converted.lower) |lower| try arena.dupe(u8, lower) else null;
        const own_upper = if (converted.upper) |upper| try arena.dupe(u8, upper) else null;
        try seen.append(.{
            .kind_value = converted.kind_value,
            .lower = own_lower,
            .upper = own_upper,
        });
    }
}

fn appendIntegerCaseRanges(
    seen: *std.array_list.Managed(IntegerCaseRange),
    ranges: []const CaseSelectorRange,
) !void {
    for (ranges) |range| {
        const converted = integerCaseRangeFromSelector(range) orelse continue;
        try seen.append(converted);
    }
}

fn diagnoseCharacterCaseOverlap(
    arena: std.mem.Allocator,
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    ranges: []const CaseSelectorRange,
    seen: []const CharacterCaseRange,
) void {
    _ = arena;
    for (ranges) |range| {
        const current = characterCaseRangeFromSelector(range) orelse continue;
        for (seen) |prior| {
            if (prior.kind_value != current.kind_value) continue;
            if (!characterCaseRangesOverlap(prior, current)) continue;
            diag_bag.set(
                line.span.start_line,
                defaultSourceColumn(line),
                catalog.parser.unexpected_token.code,
                "CASE label overlaps with CASE label",
                line.text,
            );
            return;
        }
    }
}

fn diagnoseIntegerCaseOverlap(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    ranges: []const CaseSelectorRange,
    seen: []const IntegerCaseRange,
) void {
    for (ranges) |range| {
        const current = integerCaseRangeFromSelector(range) orelse continue;
        for (seen) |prior| {
            if (!integerCaseRangesOverlap(prior, current)) continue;
            diag_bag.set(
                line.span.start_line,
                defaultSourceColumn(line),
                catalog.parser.unexpected_token.code,
                "CASE label overlaps with CASE label",
                line.text,
            );
            return;
        }
    }
}

fn diagnoseRepeatedLogicalCase(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    ranges: []const CaseSelectorRange,
    seen: *std.EnumSet(LogicalCaseValue),
) void {
    for (ranges) |range| {
        const value = logicalCaseValueFromSelector(range) orelse continue;
        if (seen.contains(value)) {
            diag_bag.set(
                line.span.start_line,
                defaultSourceColumn(line),
                catalog.semantic.assignment_type_mismatch.code,
                "value in CASE statement is repeated",
                line.text,
            );
            return;
        }
        seen.insert(value);
    }
}

fn diagnoseInvalidIntegerCaseSpecification(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    ranges: []const CaseSelectorRange,
    selector_kind_value: ?i64,
) void {
    const kind_value = selector_kind_value orelse return;
    const bounds = integerKindBounds(kind_value) orelse return;
    for (ranges) |range| {
        if (range.lower) |lower_expr| {
            const lower = integerCaseBound(lower_expr) orelse continue;
            if (lower < bounds.min or lower > bounds.max) {
                emitInvalidCaseSpecification(diag_bag, line);
                return;
            }
        }
        if (range.upper) |upper_expr| {
            const upper = integerCaseBound(upper_expr) orelse continue;
            if (upper < bounds.min or upper > bounds.max) {
                emitInvalidCaseSpecification(diag_bag, line);
                return;
            }
        }
    }
}

fn emitInvalidCaseSpecification(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
) void {
    diag_bag.set(
        line.span.start_line,
        defaultSourceColumn(line),
        catalog.parser.unexpected_token.code,
        "Syntax error in CASE specification",
        line.text,
    );
}

fn characterCaseRangeFromSelector(range: CaseSelectorRange) ?CharacterCaseRange {
    const lower = if (range.lower) |expr_node| characterCaseBound(expr_node) else null;
    const upper = if (range.upper) |expr_node| characterCaseBound(expr_node) else null;
    const exemplar = lower orelse upper orelse return null;
    if (lower != null and lower.?.kind_value != exemplar.kind_value) return null;
    if (upper != null and upper.?.kind_value != exemplar.kind_value) return null;
    return .{
        .kind_value = exemplar.kind_value,
        .lower = if (lower) |bound| bound.bytes else null,
        .upper = if (upper) |bound| bound.bytes else null,
    };
}

fn integerCaseRangeFromSelector(range: CaseSelectorRange) ?IntegerCaseRange {
    const lower = if (range.lower) |expr_node| integerCaseBound(expr_node) else null;
    const upper = if (range.upper) |expr_node| integerCaseBound(expr_node) else null;
    if (range.lower != null and lower == null) return null;
    if (range.upper != null and upper == null) return null;
    return .{
        .lower = lower,
        .upper = upper,
    };
}

fn integerCaseBound(expr_node: *Expr) ?i64 {
    return switch (expr_node.*) {
        .literal => |lit| switch (lit.kind) {
            .integer => std.fmt.parseInt(i64, lit.text, 10) catch null,
            else => null,
        },
        .unary => |un| blk: {
            const inner = integerCaseBound(un.expr) orelse break :blk null;
            break :blk switch (un.op) {
                .plus => inner,
                .minus => -inner,
                else => null,
            };
        },
        else => null,
    };
}

fn integerCaseRangesOverlap(lhs: IntegerCaseRange, rhs: IntegerCaseRange) bool {
    const lhs_lower = lhs.lower orelse std.math.minInt(i64);
    const lhs_upper = lhs.upper orelse std.math.maxInt(i64);
    const rhs_lower = rhs.lower orelse std.math.minInt(i64);
    const rhs_upper = rhs.upper orelse std.math.maxInt(i64);
    return lhs_lower <= rhs_upper and rhs_lower <= lhs_upper;
}

fn integerKindBounds(kind_value: i64) ?struct { min: i64, max: i64 } {
    return switch (kind_value) {
        1 => .{ .min = -128, .max = 127 },
        2 => .{ .min = -32768, .max = 32767 },
        4 => .{ .min = -2147483648, .max = 2147483647 },
        8 => .{ .min = -9223372036854775808, .max = 9223372036854775807 },
        else => null,
    };
}

fn logicalCaseValueFromSelector(range: CaseSelectorRange) ?LogicalCaseValue {
    const lower = range.lower orelse return null;
    const upper = range.upper orelse return null;
    const lower_value = logicalCaseBound(lower) orelse return null;
    const upper_value = logicalCaseBound(upper) orelse return null;
    if (lower_value != upper_value) return null;
    return lower_value;
}

fn logicalCaseBound(expr_node: *Expr) ?LogicalCaseValue {
    return switch (expr_node.*) {
        .literal => |lit| switch (lit.kind) {
            .logical => if (std.mem.eql(u8, lit.text, "1") or std.ascii.eqlIgnoreCase(lit.text, ".true."))
                .true_value
            else if (std.mem.eql(u8, lit.text, "0") or std.ascii.eqlIgnoreCase(lit.text, ".false."))
                .false_value
            else
                null,
            else => null,
        },
        else => null,
    };
}

fn selectorIsDefinitelyArray(
    selector: *Expr,
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) bool {
    return switch (selector.*) {
        .identifier => |name| blk: {
            const info = array_names.get(name) orelse break :blk false;
            break :blk info.rank > 0;
        },
        .call_or_subscript => |call| blk: {
            const info = array_names.get(call.name) orelse break :blk false;
            if (info.rank == 0) break :blk false;
            for (call.args) |arg| {
                if (arg.* == .dim_range) break :blk true;
            }
            break :blk false;
        },
        .substring => |sub| sub.args.len != 0,
        else => false,
    };
}

fn selectorIntegerKindValue(
    selector: *Expr,
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) ?i64 {
    const name = switch (selector.*) {
        .identifier => |ident| ident,
        else => return null,
    };
    const info = array_names.get(name) orelse return null;
    if (info.rank != 0) return null;
    if (info.type_kind != .integer) return null;
    return info.kind_value;
}

fn characterCaseBound(expr_node: *Expr) ?struct { kind_value: i64, bytes: []const u8 } {
    return switch (expr_node.*) {
        .literal => |lit| switch (lit.kind) {
            .string => .{
                .kind_value = quotedLiteralKindValue(lit.text),
                .bytes = decodeQuotedLiteralBytes(lit.text) orelse return null,
            },
            else => null,
        },
        else => null,
    };
}

fn characterCaseRangesOverlap(prior: CharacterCaseRange, current: CharacterCaseRange) bool {
    if (prior.upper) |prior_upper| {
        if (current.lower) |current_lower| {
            if (std.mem.order(u8, prior_upper, current_lower) == .lt) return false;
        }
    }
    if (current.upper) |current_upper| {
        if (prior.lower) |prior_lower| {
            if (std.mem.order(u8, current_upper, prior_lower) == .lt) return false;
        }
    }
    return true;
}

fn quotedLiteralKindValue(text: []const u8) i64 {
    const prefix = quotedLiteralKindPrefix(text) orelse return 1;
    var all_digits = prefix.len != 0;
    for (prefix) |ch| {
        if (!std.ascii.isDigit(ch)) {
            all_digits = false;
            break;
        }
    }
    if (!all_digits) return 1;
    return std.fmt.parseInt(i64, prefix, 10) catch 1;
}

fn quotedLiteralKindPrefix(text: []const u8) ?[]const u8 {
    const quote_start = quotedLiteralStart(text) orelse return null;
    if (quote_start == 0 or text[quote_start - 1] != '_') return null;
    return text[0 .. quote_start - 1];
}

fn decodeQuotedLiteralBytes(text: []const u8) ?[]const u8 {
    const quote_start = quotedLiteralStart(text) orelse return null;
    const quoted = text[quote_start..];
    if (quoted.len < 2) return null;
    const quote = quoted[0];
    if ((quote != '\'' and quote != '"') or quoted[quoted.len - 1] != quote) return null;
    return quoted[1 .. quoted.len - 1];
}

fn quotedLiteralStart(text: []const u8) ?usize {
    if (text.len == 0) return null;
    if (text[0] == '\'' or text[0] == '"') return 0;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if ((text[i] == '\'' or text[i] == '"') and text[i - 1] == '_') return i;
    }
    return null;
}
