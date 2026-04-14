const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common = @import("common.zig");
const context = @import("../token_stream.zig");
const expr = @import("../expr.zig");
const lexer = @import("../../lexer.zig");
const logical_line = @import("../../logical_line.zig");

const LineParser = common.LineParser;
const Declarator = common.Declarator;
pub const ParsedCharacterLen = common.ParsedCharacterLen;
pub const DeclAttributes = common.DeclAttributes;
pub const LegacyStarSplit = common.LegacyStarSplit;

pub fn consumeDoubleColon(lp: *LineParser) bool {
    if (lp.index + 1 >= lp.tokens.len) return false;
    const first = lp.tokens[lp.index];
    const second = lp.tokens[lp.index + 1];
    if (first.kind != .colon or second.kind != .colon) return false;
    _ = lp.next();
    _ = lp.next();
    return true;
}

pub fn consumeBalancedParens(lp: *LineParser) !void {
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

pub fn consumeBalancedBrackets(lp: *LineParser) !void {
    var depth: usize = 1;
    while (depth > 0) {
        const tok = lp.peek() orelse return error.UnexpectedToken;
        _ = lp.next();
        switch (tok.kind) {
            .l_bracket => depth += 1,
            .r_bracket => depth -= 1,
            else => {},
        }
    }
}

pub fn parseAttrDimensions(lp: *LineParser, arena: std.mem.Allocator) ![]*ast.Expr {
    var dims = std.array_list.Managed(*ast.Expr).init(arena);
    while (!lp.peekIs(.r_paren)) {
        const dim = try expr.parseDimExpr(lp, arena);
        try validateDeclarationDimExpr(dim);
        try dims.append(dim);
        _ = lp.consume(.comma);
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return dims.toOwnedSlice();
}

pub fn validateDeclarationDimExpr(dim: *ast.Expr) !void {
    switch (dim.*) {
        .dim_range => |range| {
            if (range.stride != null) return error.UnexpectedToken;
        },
        else => {},
    }
}

pub fn parseOptionalKindSelector(lp: *LineParser, arena: std.mem.Allocator) !?*ast.Expr {
    if (lp.consume(.star)) {
        return try parseLegacyStarSelectorExpr(lp, arena);
    }
    if (!lp.peekIs(.l_paren)) return null;
    return parseKindSelectorExprInParens(lp, arena);
}

pub fn parseStarOnlyKindSelector(lp: *LineParser, arena: std.mem.Allocator) !?*ast.Expr {
    if (!lp.consume(.star)) return null;
    return try parseLegacyStarSelectorExpr(lp, arena);
}

pub fn parseKindSelectorExprInParens(lp: *LineParser, arena: std.mem.Allocator) !?*ast.Expr {
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var selector: ?*ast.Expr = null;
    while (!lp.peekIs(.r_paren)) {
        if (lp.peek()) |tok| {
            if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "KIND")) {
                if (lp.index + 1 < lp.tokens.len and lp.tokens[lp.index + 1].kind == .equals) {
                    _ = lp.next();
                    _ = lp.expect(.equals) orelse return error.UnexpectedToken;
                    selector = try expr.parseExpr(lp, arena, 0);
                    _ = lp.consume(.comma);
                    continue;
                }
            }
            if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "LEN")) {
                if (lp.index + 1 < lp.tokens.len and lp.tokens[lp.index + 1].kind == .equals) {
                    _ = lp.next();
                    _ = lp.expect(.equals) orelse return error.UnexpectedToken;
                    _ = try expr.parseExpr(lp, arena, 0);
                    _ = lp.consume(.comma);
                    continue;
                }
            }
        }
        const parsed = try expr.parseExpr(lp, arena, 0);
        if (selector == null) selector = parsed;
        _ = lp.consume(.comma);
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return selector;
}

pub fn consumeDeclAttributes(lp: *LineParser, arena: std.mem.Allocator) !DeclAttributes {
    var attrs: DeclAttributes = .{};

    if (lp.consume(.comma)) {
        while (true) {
            if (consumeDoubleColon(lp)) return attrs;
            const tok = lp.peek() orelse return attrs;
            if (tok.kind != .identifier) return attrs;

            const attr_tok = lp.next();
            const attr_name = lp.tokenText(attr_tok);
            if (context.eqNoCase(attr_name, "PARAMETER")) attrs.parameter = true;
            if (context.eqNoCase(attr_name, "SAVE")) attrs.save = true;
            if (context.eqNoCase(attr_name, "ALLOCATABLE")) attrs.allocatable = true;
            if (context.eqNoCase(attr_name, "POINTER")) attrs.pointer = true;
            if (context.eqNoCase(attr_name, "OPTIONAL")) attrs.optional = true;
            if (context.eqNoCase(attr_name, "NOPASS")) attrs.nopass = true;
            if (context.eqNoCase(attr_name, "PRIVATE")) attrs.private = true;
            if (context.eqNoCase(attr_name, "PUBLIC")) attrs.private = false;
            if (context.eqNoCase(attr_name, "EXTERNAL")) attrs.external = true;
            if (context.eqNoCase(attr_name, "ASYNCHRONOUS")) attrs.asynchronous = true;
            if (context.eqNoCase(attr_name, "CONTIGUOUS")) attrs.contiguous = true;
            if (context.eqNoCase(attr_name, "VALUE")) attrs.value_attr = true;
            if (context.eqNoCase(attr_name, "VOLATILE")) attrs.volatile_attr = true;
            if (context.eqNoCase(attr_name, "PASS")) {
                if (lp.consume(.l_paren)) {
                    attrs.pass_name = lp.readName(arena) orelse return error.MissingName;
                    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
                }
            }
            if (context.eqNoCase(attr_name, "INTENT")) {
                _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
                attrs.intent = if (lp.consumeKeyword("INOUT"))
                    .inout
                else if (lp.consumeKeyword("OUT"))
                    .out
                else if (lp.consumeKeyword("IN"))
                    .in
                else
                    return error.UnexpectedToken;
                _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            }
            if (context.eqNoCase(attr_name, "BIND")) {
                const bind_info = try parseBindSpec(lp, arena);
                attrs.bind_c = bind_info.bind_c;
                attrs.bind_name_expr = bind_info.bind_name_expr;
            }
            if (context.eqNoCase(attr_name, "DIMENSION")) {
                if (lp.consume(.l_paren)) {
                    attrs.dimension = try parseAttrDimensions(lp, arena);
                }
            } else if (context.eqNoCase(attr_name, "CODIMENSION")) {
                if (lp.consume(.l_bracket)) {
                    try consumeBalancedBrackets(lp);
                }
            } else if (lp.consume(.l_paren)) {
                try consumeBalancedParens(lp);
            }

            if (consumeDoubleColon(lp)) return attrs;
            if (!lp.consume(.comma)) break;
        }
    }

    _ = consumeDoubleColon(lp);
    return attrs;
}

pub const BindSpec = struct {
    bind_c: bool = false,
    bind_name_expr: ?*ast.Expr = null,
};

pub fn parseBindSpec(lp: *LineParser, arena: std.mem.Allocator) !BindSpec {
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var bind_info: BindSpec = .{};
    while (!lp.peekIs(.r_paren)) {
        const tok = lp.peek() orelse return error.UnexpectedToken;
        if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "C")) {
            _ = lp.next();
            bind_info.bind_c = true;
        } else if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "NAME")) {
            _ = lp.next();
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            bind_info.bind_name_expr = try expr.parseExpr(lp, arena, 0);
        } else {
            return error.UnexpectedToken;
        }
        _ = lp.consume(.comma);
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return bind_info;
}

pub fn parseDeclarators(
    lp: *LineParser,
    arena: std.mem.Allocator,
    default_char_len: ParsedCharacterLen,
    default_dims: ?[]*ast.Expr,
    pointer_attr: bool,
) ![]Declarator {
    var items = std.array_list.Managed(Declarator).init(arena);
    while (lp.peek()) |_| {
        const name = lp.readName(arena) orelse return error.MissingName;
        var dims = std.array_list.Managed(*ast.Expr).init(arena);
        var char_len = default_char_len;
        var init_value: ?*ast.Expr = null;
        if (lp.consume(.star)) {
            char_len = try parseCharacterLenSpec(lp, arena);
        }
        if (lp.consume(.l_paren)) {
            while (!lp.peekIs(.r_paren)) {
                const dim = try expr.parseDimExpr(lp, arena);
                try validateDeclarationDimExpr(dim);
                try dims.append(dim);
                _ = lp.consume(.comma);
            }
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        }
        if (lp.consume(.star)) {
            char_len = try parseCharacterLenSpec(lp, arena);
        }
        if (lp.consume(.equals)) {
            _ = if (pointer_attr) lp.consume(.greater) else false;
            init_value = try expr.parseExpr(lp, arena, 0);
        }
        var dim_items = try dims.toOwnedSlice();
        if (dim_items.len == 0 and default_dims != null) dim_items = default_dims.?;
        try items.append(.{
            .name = name,
            .dims = dim_items,
            .char_len = char_len.expr,
            .char_len_deferred = char_len.deferred,
            .init = init_value,
        });
        if (!lp.consume(.comma)) break;
    }
    return items.toOwnedSlice();
}

pub fn parseCommonDeclarators(lp: *LineParser, arena: std.mem.Allocator, default_char_len: ?*ast.Expr) ![]Declarator {
    var items = std.array_list.Managed(Declarator).init(arena);
    while (lp.peek()) |_| {
        if (lp.peekIs(.slash)) break;
        const name = lp.readName(arena) orelse return error.MissingName;
        var dims = std.array_list.Managed(*ast.Expr).init(arena);
        var char_len = ParsedCharacterLen{ .expr = default_char_len };
        if (lp.consume(.star)) {
            char_len = try parseCharacterLenSpec(lp, arena);
        }
        if (lp.consume(.l_paren)) {
            while (!lp.peekIs(.r_paren)) {
                const dim = try expr.parseDimExpr(lp, arena);
                try validateDeclarationDimExpr(dim);
                try dims.append(dim);
                _ = lp.consume(.comma);
            }
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        }
        if (lp.consume(.star)) {
            char_len = try parseCharacterLenSpec(lp, arena);
        }
        try items.append(.{
            .name = name,
            .dims = try dims.toOwnedSlice(),
            .char_len = char_len.expr,
            .char_len_deferred = char_len.deferred,
        });
        if (!lp.consume(.comma)) break;
        if (lp.peekIs(.slash)) break;
    }
    return items.toOwnedSlice();
}

pub fn parseCharacterLenSpec(lp: *LineParser, arena: std.mem.Allocator) !ParsedCharacterLen {
    if (lp.consume(.l_paren)) {
        var parsed: ParsedCharacterLen = .{};
        while (!lp.peekIs(.r_paren)) {
            if (lp.peek()) |tok| {
                if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "LEN")) {
                    _ = lp.next();
                    if (lp.consume(.equals)) {
                        if (lp.consume(.colon)) {
                            parsed.deferred = true;
                        } else if (lp.consume(.star)) {
                            parsed.expr = try makeAssumedCharLenExpr(arena);
                        } else {
                            parsed.expr = try expr.parseExpr(lp, arena, 0);
                        }
                    } else if (lp.consume(.l_paren)) {
                        parsed.expr = try expr.parseExpr(lp, arena, 0);
                        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
                    } else {
                        return error.UnexpectedToken;
                    }
                    _ = lp.consume(.comma);
                    continue;
                }
                if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "KIND")) {
                    _ = lp.next();
                    _ = lp.expect(.equals) orelse return error.UnexpectedToken;
                    parsed.kind_selector = try expr.parseExpr(lp, arena, 0);
                    _ = lp.consume(.comma);
                    continue;
                }
            }
            if (parsed.expr == null and !parsed.deferred and lp.consume(.colon)) {
                parsed.deferred = true;
            } else if (parsed.expr == null and !parsed.deferred and lp.consume(.star)) {
                parsed.expr = try makeAssumedCharLenExpr(arena);
            } else if (parsed.expr == null and !parsed.deferred) {
                parsed.expr = try expr.parseExpr(lp, arena, 0);
            } else if (parsed.kind_selector == null) {
                parsed.kind_selector = try expr.parseExpr(lp, arena, 0);
            } else {
                _ = try expr.parseExpr(lp, arena, 0);
            }
            _ = lp.consume(.comma);
        }
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        if (parsed.deferred) return parsed;
        if (parsed.expr != null) return parsed;
        const default_len = try arena.create(ast.Expr);
        default_len.* = .{ .literal = .{ .kind = .integer, .text = "1" } };
        parsed.expr = default_len;
        return parsed;
    }
    return .{ .expr = try parseLegacyStarSelectorExpr(lp, arena) };
}

fn makeAssumedCharLenExpr(arena: std.mem.Allocator) !*ast.Expr {
    const node = try arena.create(ast.Expr);
    node.* = .{ .literal = .{ .kind = .assumed_size, .text = "*" } };
    return node;
}

pub fn parseCharacterLen(lp: *LineParser, arena: std.mem.Allocator) !*ast.Expr {
    const parsed = try parseCharacterLenSpec(lp, arena);
    if (parsed.deferred) return error.UnexpectedToken;
    return parsed.expr orelse error.UnexpectedToken;
}

pub fn parseLegacyStarSelectorExpr(lp: *LineParser, arena: std.mem.Allocator) !*ast.Expr {
    if (try splitAmbiguousLegacyStarToken(lp, arena)) |split_expr| return split_expr;
    return expr.parseExpr(lp, arena, expr.min_prec_power);
}

fn splitAmbiguousLegacyStarToken(lp: *LineParser, arena: std.mem.Allocator) !?*ast.Expr {
    const tok = lp.peek() orelse return null;
    if (tok.kind != .real) return null;
    const text = lp.tokenText(tok);
    const split = findLegacyStarSelectorSplit(text) orelse return null;
    const selector_text = std.mem.trimRight(u8, text[0..split.selector_end], " \t");
    if (selector_text.len == 0) return null;

    const suffix_start = tok.start + split.suffix_start;
    const suffix_end = tok.end;
    lp.tokens[lp.index] = makeToken(lp.line, .identifier, suffix_start, suffix_end);

    const literal_text = try arena.dupe(u8, selector_text);
    const node = try arena.create(ast.Expr);
    node.* = .{
        .literal = .{
            .kind = if (std.mem.indexOfScalar(u8, literal_text, '.')) |_| ast.LiteralKind.real else ast.LiteralKind.integer,
            .text = literal_text,
        },
    };
    return node;
}

fn findLegacyStarSelectorSplit(text: []const u8) ?LegacyStarSplit {
    var split_at: usize = 0;
    while (split_at < text.len and text[split_at] != ' ' and text[split_at] != '\t') : (split_at += 1) {}
    if (split_at == text.len) return null;
    const selector = text[0..split_at];
    if (!isLegacyStarSelectorPrefix(selector)) return null;

    var suffix_start = split_at;
    while (suffix_start < text.len and (text[suffix_start] == ' ' or text[suffix_start] == '\t')) : (suffix_start += 1) {}
    if (suffix_start == text.len) return null;
    const suffix = text[suffix_start..];
    if (!isIdentifierText(suffix)) return null;

    return .{ .selector_end = split_at, .suffix_start = suffix_start };
}

fn isLegacyStarSelectorPrefix(text: []const u8) bool {
    if (text.len == 0) return false;
    var saw_digit = false;
    for (text, 0..) |ch, idx| {
        switch (ch) {
            '0'...'9' => saw_digit = true,
            '.' => {},
            '+', '-' => if (idx != 0) return false,
            else => return false,
        }
    }
    return saw_digit;
}

fn isIdentifierText(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

fn makeToken(line: logical_line.LogicalLine, kind: lexer.TokenKind, start: usize, end: usize) lexer.Token {
    const start_pos = logical_line.mapIndexToPos(line, start);
    const end_pos = logical_line.mapIndexToPosExclusive(line, end);
    return .{
        .kind = kind,
        .start = start,
        .end = end,
        .line = start_pos.line,
        .column = start_pos.column,
        .range = .{ .start = start_pos, .end = end_pos },
    };
}

pub fn parseNameList(lp: *LineParser, arena: std.mem.Allocator) ![]const []const u8 {
    var names = std.array_list.Managed([]const u8).init(arena);
    while (lp.peek()) |_| {
        const name = lp.readName(arena) orelse return error.MissingName;
        try names.append(name);
        if (!lp.consume(.comma)) break;
    }
    return names.toOwnedSlice();
}
