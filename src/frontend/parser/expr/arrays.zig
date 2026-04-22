const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../token_stream.zig");
const lexer = @import("../../lexer.zig");
const shared = @import("shared.zig");

const LineParser = context.LineParser;
const Expr = ast.Expr;
const SourceRef = ast.SourceRef;
const ParseExprError = shared.ParseExprError;

pub fn tryParseArrayConstructorTypeSpec(
    lp: *LineParser,
    arena: std.mem.Allocator,
    depth: usize,
    comptime parseExprDepthFn: anytype,
) ParseExprError!?ast.ArrayConstructorTypeSpec {
    if (!hasTopLevelDoubleColonBeforeArrayItemEnd(lp.*)) return null;
    var lookahead = lp.*;
    const parsed = parseArrayConstructorTypeSpec(&lookahead, arena, depth, parseExprDepthFn) catch |err| {
        return switch (err) {
            error.UnknownType => null,
            error.UnexpectedEOF => error.UnexpectedEOF,
            error.UnexpectedToken => error.UnexpectedToken,
            error.ExpressionDepthExceeded => error.ExpressionDepthExceeded,
            error.InvalidArrayConstructorSyntax => error.InvalidArrayConstructorSyntax,
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    if (!consumeDoubleColon(&lookahead)) return null;
    lp.* = lookahead;
    return parsed;
}

fn hasTopLevelDoubleColonBeforeArrayItemEnd(lp: LineParser) bool {
    var depth: usize = 0;
    var i = lp.index;
    while (i < lp.tokens.len) : (i += 1) {
        const tok = lp.tokens[i];
        if (depth == 0) {
            if (tok.kind == .comma) return false;
            if (tok.kind == .slash and i + 1 < lp.tokens.len and lp.tokens[i + 1].kind == .r_paren) {
                return false;
            }
            if (tok.kind == .colon and i + 1 < lp.tokens.len and lp.tokens[i + 1].kind == .colon) {
                return true;
            }
        }
        switch (tok.kind) {
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

const ParseArrayTypeError = ParseExprError || error{UnknownType};

fn parseArrayConstructorTypeSpec(
    lp: *LineParser,
    arena: std.mem.Allocator,
    depth: usize,
    comptime parseExprDepthFn: anytype,
) ParseArrayTypeError!ast.ArrayConstructorTypeSpec {
    if (lp.isKeywordSplit("INTEGER")) {
        _ = lp.consumeKeyword("INTEGER");
        return .{ .type_kind = .integer, .kind_selector = try parseOptionalKindSelector(lp, arena, depth + 1, parseExprDepthFn) };
    }
    if (lp.isKeywordSplit("REAL")) {
        _ = lp.consumeKeyword("REAL");
        return .{ .type_kind = .real, .kind_selector = try parseOptionalKindSelector(lp, arena, depth + 1, parseExprDepthFn) };
    }
    if (lp.isKeywordSplit("COMPLEX")) {
        _ = lp.consumeKeyword("COMPLEX");
        return .{ .type_kind = .complex, .kind_selector = try parseOptionalKindSelector(lp, arena, depth + 1, parseExprDepthFn) };
    }
    if (lp.isKeywordSplit("LOGICAL")) {
        _ = lp.consumeKeyword("LOGICAL");
        return .{ .type_kind = .logical, .kind_selector = try parseOptionalKindSelector(lp, arena, depth + 1, parseExprDepthFn) };
    }
    if (lp.isKeywordSplit("CHARACTER")) {
        _ = lp.consumeKeyword("CHARACTER");
        return .{ .type_kind = .character, .kind_selector = try parseCharacterArrayKindSelector(lp, arena, depth + 1, parseExprDepthFn) };
    }
    if (lp.isKeywordSplit("DOUBLEPRECISION")) {
        _ = lp.consumeKeyword("DOUBLEPRECISION");
        return .{ .type_kind = .double_precision };
    }
    if (lp.isKeywordSplit("DOUBLE")) {
        _ = lp.consumeKeyword("DOUBLE");
        if (!lp.consumeKeyword("PRECISION")) return error.UnexpectedToken;
        return .{ .type_kind = .double_precision };
    }
    if (lp.consumeKeyword("TYPE")) {
        _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
        const name = lp.readName(arena) orelse return error.UnexpectedToken;
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        return .{ .type_kind = .derived, .derived_type_name = name };
    }
    if (lp.consumeKeyword("CLASS")) {
        _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
        if (lp.consume(.star)) {
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            return .{ .type_kind = .derived, .polymorphic = true };
        }
        const name = lp.readName(arena) orelse return error.UnexpectedToken;
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        return .{ .type_kind = .derived, .derived_type_name = name, .polymorphic = true };
    }
    if (lp.peekIs(.identifier)) {
        const name = lp.readName(arena) orelse return error.UnexpectedToken;
        return .{ .type_kind = .derived, .derived_type_name = name };
    }
    return error.UnknownType;
}

fn parseOptionalKindSelector(
    lp: *LineParser,
    arena: std.mem.Allocator,
    depth: usize,
    comptime parseExprDepthFn: anytype,
) ParseExprError!?*Expr {
    if (!lp.consume(.l_paren)) return null;
    if (lp.consumeKeyword("KIND")) {
        _ = lp.expect(.equals) orelse return error.UnexpectedToken;
    }
    const selector = try parseExprDepthFn(lp, arena, 0, depth + 1);
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return selector;
}

fn parseCharacterArrayKindSelector(
    lp: *LineParser,
    arena: std.mem.Allocator,
    depth: usize,
    comptime parseExprDepthFn: anytype,
) ParseExprError!?*Expr {
    if (!lp.consume(.l_paren)) return null;
    var kind_selector: ?*Expr = null;
    var fallback_selector: ?*Expr = null;
    while (!lp.peekIs(.r_paren)) {
        if (lp.consumeKeyword("KIND")) {
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            kind_selector = try parseExprDepthFn(lp, arena, 0, depth + 1);
        } else if (lp.consumeKeyword("LEN")) {
            const len_expr = if (lp.consume(.l_paren)) blk: {
                const parsed = try parseExprDepthFn(lp, arena, 0, depth + 1);
                _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
                break :blk parsed;
            } else blk: {
                _ = lp.expect(.equals) orelse return error.UnexpectedToken;
                break :blk try parseExprDepthFn(lp, arena, 0, depth + 1);
            };
            if (fallback_selector == null) fallback_selector = len_expr;
        } else {
            const bare_expr = try parseExprDepthFn(lp, arena, 0, depth + 1);
            if (fallback_selector == null) fallback_selector = bare_expr;
        }
        if (!lp.consume(.comma)) break;
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return kind_selector orelse fallback_selector;
}

fn consumeDoubleColon(lp: *LineParser) bool {
    if (!lp.peekIs(.colon)) return false;
    if (lp.index + 1 >= lp.tokens.len or lp.tokens[lp.index + 1].kind != .colon) return false;
    _ = lp.next();
    _ = lp.next();
    return true;
}

pub fn tryParseImpliedDo(
    lp: *LineParser,
    arena: std.mem.Allocator,
    depth: usize,
    start_source: SourceRef,
    comptime parseExprDepthFn: anytype,
    comptime makeExprNodeFn: anytype,
) ParseExprError!?*Expr {
    var lookahead = lp.*;
    if (!lookahead.consume(.l_paren)) return null;
    if (!hasTopLevelCommaBeforeParenEnd(lookahead)) return null;

    var items = std.array_list.Managed(*Expr).init(arena);
    const first_item = parseExprDepthFn(&lookahead, arena, 0, depth + 1) catch return null;
    try items.append(first_item);
    if (!lookahead.consume(.comma)) return null;

    while (true) {
        if (lookahead.peek()) |tok| {
            if (tok.kind == .identifier and lookahead.index + 1 < lookahead.tokens.len and lookahead.tokens[lookahead.index + 1].kind == .equals) {
                const var_name = lookahead.readName(arena) orelse return error.UnexpectedToken;
                _ = lookahead.expect(.equals) orelse return error.UnexpectedToken;
                const start_expr = try parseExprDepthFn(&lookahead, arena, 0, depth + 1);
                _ = lookahead.expect(.comma) orelse return error.UnexpectedToken;
                const end_expr = try parseExprDepthFn(&lookahead, arena, 0, depth + 1);
                var step_expr: ?*Expr = null;
                if (lookahead.consume(.comma)) {
                    step_expr = try parseExprDepthFn(&lookahead, arena, 0, depth + 1);
                }
                _ = lookahead.expect(.r_paren) orelse return error.UnexpectedToken;
                lp.* = lookahead;
                return makeExprNodeFn(
                    arena,
                    .{ .implied_do = .{
                        .items = try items.toOwnedSlice(),
                        .var_name = var_name,
                        .start = start_expr,
                        .end = end_expr,
                        .step = step_expr,
                    } },
                    start_source,
                );
            }
        }

        const next_item = parseExprDepthFn(&lookahead, arena, 0, depth + 1) catch return null;
        try items.append(next_item);
        if (!lookahead.consume(.comma)) return null;
    }
}

fn hasTopLevelCommaBeforeParenEnd(lp: LineParser) bool {
    var depth: usize = 0;
    var idx = lp.index;
    while (idx < lp.tokens.len) : (idx += 1) {
        const tok = lp.tokens[idx];
        switch (tok.kind) {
            .l_paren, .l_bracket => depth += 1,
            .r_paren, .r_bracket => {
                if (depth == 0) return false;
                depth -= 1;
            },
            .comma => {
                if (depth == 0) return true;
            },
            else => {},
        }
    }
    return false;
}

pub fn tryParseSlashArrayConstructor(
    lp: *LineParser,
    arena: std.mem.Allocator,
    depth: usize,
    start_source: SourceRef,
    comptime parseExprDepthFn: anytype,
    comptime makeExprNodeFn: anytype,
) ParseExprError!?*Expr {
    var lookahead = lp.*;
    if (!lookahead.consume(.l_paren)) return null;
    if (!lookahead.consume(.slash)) return null;

    const type_spec = try tryParseArrayConstructorTypeSpec(&lookahead, arena, depth + 1, parseExprDepthFn);
    var items = std.array_list.Managed(*Expr).init(arena);
    while (!isSlashArrayConstructorEnd(lookahead)) {
        const item = try parseExprDepthFn(&lookahead, arena, 0, depth + 1);
        try items.append(item);
        if (isSlashArrayConstructorEnd(lookahead)) break;
        if (!lookahead.consume(.comma)) return null;
    }
    if (!isSlashArrayConstructorEnd(lookahead)) return null;
    _ = lookahead.expect(.slash) orelse return error.UnexpectedToken;
    _ = lookahead.expect(.r_paren) orelse return error.UnexpectedToken;
    if (items.items.len == 0) return error.UnexpectedToken;
    lp.* = lookahead;
    return makeExprNodeFn(
        arena,
        .{ .array_constructor = .{ .type_spec = type_spec, .items = try items.toOwnedSlice() } },
        start_source,
    );
}

pub fn isSlashArrayConstructorEnd(lp: LineParser) bool {
    return lp.peekIs(.slash) and lp.index + 1 < lp.tokens.len and lp.tokens[lp.index + 1].kind == .r_paren;
}

pub fn adjacentKindPrefixedString(lp: LineParser) ?lexer.Token {
    const first = lp.peek() orelse return null;
    if (first.kind != .identifier and first.kind != .integer) return null;
    if (lp.index + 1 >= lp.tokens.len) return null;
    const next = lp.tokens[lp.index + 1];
    if (next.kind != .string) return null;
    if (next.start != first.end) return null;
    return next;
}
