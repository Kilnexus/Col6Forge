const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../token_stream.zig");
const shared = @import("shared.zig");
const arrays = @import("arrays.zig");
const suffixes = @import("suffixes.zig");

const LineParser = shared.LineParser;
const Expr = shared.Expr;
const SourceRef = shared.SourceRef;
const ParseExprError = shared.ParseExprError;

const internal_literal_substring_name = "__col6forge_substring";

pub const min_prec_power = shared.min_prec_power;
pub const SourceCapture = shared.SourceCapture;
pub const pushSourceCapture = shared.pushSourceCapture;
pub const restoreSourceCapture = shared.restoreSourceCapture;

pub fn parseExpr(lp: *LineParser, arena: std.mem.Allocator, min_prec: u8) ParseExprError!*Expr {
    return parseExprDepth(lp, arena, min_prec, 0);
}

fn parseExprDepth(lp: *LineParser, arena: std.mem.Allocator, min_prec: u8, depth: usize) ParseExprError!*Expr {
    if (depth >= shared.max_expression_depth) return error.ExpressionDepthExceeded;
    var left = try parsePrimary(lp, arena, depth + 1);
    while (true) {
        if (arrays.isSlashArrayConstructorEnd(lp.*)) break;
        const op_info = shared.peekBinaryOp(lp.*) orelse break;
        if (op_info.prec < min_prec) break;
        const source = shared.sourceForExpr(left) orelse shared.currentSource(lp.*);
        var consumed: usize = 0;
        while (consumed < op_info.token_count) : (consumed += 1) {
            _ = lp.next();
        }
        const next_min = if (op_info.right_assoc) op_info.prec else op_info.prec + 1;
        const right = try parseExprDepth(lp, arena, next_min, depth + 1);
        left = try shared.makeExprNode(
            arena,
            .{ .binary = .{ .op = op_info.op, .left = left, .right = right } },
            source,
        );
    }
    return left;
}

pub fn parseDimExpr(lp: *LineParser, arena: std.mem.Allocator) ParseExprError!*Expr {
    return parseDimExprDepth(lp, arena, 0);
}

fn parseDimExprDepth(lp: *LineParser, arena: std.mem.Allocator, depth: usize) ParseExprError!*Expr {
    if (depth >= shared.max_expression_depth) return error.ExpressionDepthExceeded;
    const start_source = shared.currentSource(lp.*);
    if (lp.peekIs(.dotdot)) {
        _ = lp.next();
        const upper = try shared.makeExprNode(
            arena,
            .{ .literal = .{ .kind = .assumed_size, .text = "*" } },
            start_source,
        );
        return shared.makeExprNode(
            arena,
            .{ .dim_range = .{
                .lower = null,
                .upper = upper,
                .stride = null,
                .assumed_shape = true,
                .from_dotdot = true,
            } },
            start_source,
        );
    }
    if (lp.peekIs(.star)) {
        const tok = lp.next();
        return shared.makeExprNode(arena, .{ .literal = .{ .kind = .assumed_size, .text = lp.tokenText(tok) } }, start_source);
    }

    var lower: ?*Expr = null;
    if (!lp.peekIs(.colon)) {
        lower = try parseExprDepth(lp, arena, 0, depth + 1);
    }
    if (lp.consume(.colon)) {
        var upper: *Expr = undefined;
        var assumed_shape = false;
        if (lp.peekIs(.star)) {
            const tok = lp.next();
            upper = try shared.makeExprNode(
                arena,
                .{ .literal = .{ .kind = .assumed_size, .text = lp.tokenText(tok) } },
                shared.currentSourceForFallback(lp.*, start_source),
            );
        } else if (lp.peekIs(.colon) or isDimRangeTerminator(lp.*)) {
            upper = try shared.makeExprNode(
                arena,
                .{ .literal = .{ .kind = .assumed_size, .text = "*" } },
                shared.currentSourceForFallback(lp.*, start_source),
            );
            assumed_shape = true;
        } else {
            upper = try parseExprDepth(lp, arena, 0, depth + 1);
        }

        var stride: ?*Expr = null;
        if (lp.consume(.colon) and !isDimRangeTerminator(lp.*)) {
            stride = try parseExprDepth(lp, arena, 0, depth + 1);
        }

        return shared.makeExprNode(
            arena,
            .{ .dim_range = .{ .lower = lower, .upper = upper, .stride = stride, .assumed_shape = assumed_shape } },
            start_source,
        );
    }
    return lower orelse error.UnexpectedToken;
}

fn isDimRangeTerminator(lp: LineParser) bool {
    return lp.peek() == null or lp.peekIs(.r_paren) or lp.peekIs(.comma);
}

fn parsePrimary(lp: *LineParser, arena: std.mem.Allocator, depth: usize) ParseExprError!*Expr {
    const tok = lp.peek() orelse return error.UnexpectedEOF;
    const start_source = shared.currentSource(lp.*);
    switch (tok.kind) {
        .identifier => {
            if (arrays.adjacentKindPrefixedString(lp.*)) |string_tok| {
                const prefix_tok = tok;
                _ = lp.next();
                _ = lp.next();
                const prefix_text = lp.tokenText(prefix_tok);
                const literal_text = if (std.mem.endsWith(u8, prefix_text, "_") or isBozPrefix(prefix_text))
                    lp.line.text[prefix_tok.start..string_tok.end]
                else
                    lp.tokenText(string_tok);
                const lit_node = try shared.makeExprNode(
                    arena,
                    .{ .literal = .{ .kind = .string, .text = literal_text } },
                    start_source,
                );
                return suffixes.parseLiteralSubstringSuffix(
                    lp,
                    arena,
                    lit_node,
                    depth + 1,
                    start_source,
                    internal_literal_substring_name,
                    shared.hasSubstringRange,
                    parseExprDepth,
                    shared.makeExprNode,
                );
            }
            const name = lp.readName(arena) orelse return error.UnexpectedToken;
            if (lp.consume(.l_paren)) {
                if (shared.hasSubstringRange(lp.*) and !shared.hasTrailingSubstringSuffix(lp.*)) {
                    const args = @constCast(@as([]const *Expr, &[_]*Expr{}));
                    var start_expr: ?*Expr = null;
                    if (!lp.peekIs(.colon)) {
                        start_expr = try parseExprDepth(lp, arena, 0, depth + 1);
                    }
                    _ = lp.expect(.colon) orelse return error.UnexpectedToken;
                    var end_expr: ?*Expr = null;
                    if (!lp.peekIs(.r_paren)) {
                        end_expr = try parseExprDepth(lp, arena, 0, depth + 1);
                    }
                    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
                    const node = try shared.makeExprNode(
                        arena,
                        .{ .substring = .{ .name = name, .args = args, .start = start_expr, .end = end_expr } },
                        start_source,
                    );
                    return suffixes.parseComponentSuffixes(
                        lp,
                        arena,
                        node,
                        depth + 1,
                        start_source,
                        parseCallArgExpr,
                        parseExprDepth,
                        shared.makeExprNode,
                    );
                }

                var args = std.array_list.Managed(*Expr).init(arena);
                while (!lp.peekIs(.r_paren)) {
                    try args.append(try parseCallArgExpr(lp, arena, depth + 1));
                    _ = lp.consume(.comma);
                }
                _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
                const call_args = try args.toOwnedSlice();
                if (lp.peekIs(.l_paren)) {
                    var lookahead = lp.*;
                    _ = lookahead.consume(.l_paren);
                    if (!shared.hasSubstringRange(lookahead)) {
                        return shared.makeExprNode(
                            arena,
                            .{ .call_or_subscript = .{ .name = name, .args = call_args } },
                            start_source,
                        );
                    }
                    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
                    var start_expr: ?*Expr = null;
                    if (!lp.peekIs(.colon)) {
                        start_expr = try parseExprDepth(lp, arena, 0, depth + 1);
                    }
                    _ = lp.expect(.colon) orelse return error.UnexpectedToken;
                    var end_expr: ?*Expr = null;
                    if (!lp.peekIs(.r_paren)) {
                        end_expr = try parseExprDepth(lp, arena, 0, depth + 1);
                    }
                    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
                    const node = try shared.makeExprNode(
                        arena,
                        .{ .substring = .{ .name = name, .args = call_args, .start = start_expr, .end = end_expr } },
                        start_source,
                    );
                    return suffixes.parseComponentSuffixes(
                        lp,
                        arena,
                        node,
                        depth + 1,
                        start_source,
                        parseCallArgExpr,
                        parseExprDepth,
                        shared.makeExprNode,
                    );
                }
                const node = try shared.makeExprNode(
                    arena,
                    .{ .call_or_subscript = .{ .name = name, .args = call_args } },
                    start_source,
                );
                return suffixes.parseComponentSuffixes(
                    lp,
                    arena,
                    node,
                    depth + 1,
                    start_source,
                    parseCallArgExpr,
                    parseExprDepth,
                    shared.makeExprNode,
                );
            }
            const node = try shared.makeExprNode(arena, .{ .identifier = name }, start_source);
            return suffixes.parseComponentSuffixes(
                lp,
                arena,
                node,
                depth + 1,
                start_source,
                parseCallArgExpr,
                parseExprDepth,
                shared.makeExprNode,
            );
        },
        .integer => {
            if (arrays.adjacentKindPrefixedString(lp.*)) |string_tok| {
                const prefix_tok = tok;
                _ = lp.next();
                _ = lp.next();
                const prefix_text = lp.tokenText(prefix_tok);
                const literal_text = if (std.mem.endsWith(u8, prefix_text, "_"))
                    lp.line.text[prefix_tok.start..string_tok.end]
                else
                    lp.tokenText(string_tok);
                const lit_node = try shared.makeExprNode(
                    arena,
                    .{ .literal = .{ .kind = .string, .text = literal_text } },
                    start_source,
                );
                return suffixes.parseLiteralSubstringSuffix(
                    lp,
                    arena,
                    lit_node,
                    depth + 1,
                    start_source,
                    internal_literal_substring_name,
                    shared.hasSubstringRange,
                    parseExprDepth,
                    shared.makeExprNode,
                );
            }
            _ = lp.next();
            return shared.makeExprNode(arena, .{ .literal = .{ .kind = .integer, .text = lp.tokenText(tok) } }, start_source);
        },
        .real => {
            _ = lp.next();
            return shared.makeExprNode(arena, .{ .literal = .{ .kind = .real, .text = lp.tokenText(tok) } }, start_source);
        },
        .string => {
            _ = lp.next();
            const lit_node = try shared.makeExprNode(arena, .{ .literal = .{ .kind = .string, .text = lp.tokenText(tok) } }, start_source);
            return suffixes.parseLiteralSubstringSuffix(
                lp,
                arena,
                lit_node,
                depth + 1,
                start_source,
                internal_literal_substring_name,
                shared.hasSubstringRange,
                parseExprDepth,
                shared.makeExprNode,
            );
        },
        .hollerith => {
            _ = lp.next();
            const lit_node = try shared.makeExprNode(arena, .{ .literal = .{ .kind = .hollerith, .text = lp.tokenText(tok) } }, start_source);
            return suffixes.parseLiteralSubstringSuffix(
                lp,
                arena,
                lit_node,
                depth + 1,
                start_source,
                internal_literal_substring_name,
                shared.hasSubstringRange,
                parseExprDepth,
                shared.makeExprNode,
            );
        },
        .l_paren => {
            if (try arrays.tryParseImpliedDo(lp, arena, depth + 1, start_source, parseExprDepth, shared.makeExprNode)) |implied_do| {
                return implied_do;
            }
            if (try arrays.tryParseSlashArrayConstructor(lp, arena, depth + 1, start_source, parseExprDepth, shared.makeExprNode)) |array_ctor| {
                return array_ctor;
            }
            _ = lp.next();
            const real = try parseExprDepth(lp, arena, 0, depth + 1);
            if (lp.consume(.comma)) {
                const imag = try parseExprDepth(lp, arena, 0, depth + 1);
                _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
                return shared.makeExprNode(
                    arena,
                    .{ .complex_literal = .{ .real = real, .imag = imag } },
                    start_source,
                );
            }
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            return real;
        },
        .l_bracket => {
            _ = lp.next();
            const type_spec = try arrays.tryParseArrayConstructorTypeSpec(lp, arena, depth + 1, parseExprDepth);
            var items = std.array_list.Managed(*Expr).init(arena);
            while (!lp.peekIs(.r_bracket)) {
                try items.append(try parseExprDepth(lp, arena, 0, depth + 1));
                if (!lp.consume(.comma)) break;
            }
            _ = lp.expect(.r_bracket) orelse return error.UnexpectedToken;
            if (items.items.len == 0) {
                if (type_spec != null) return error.InvalidArrayConstructorSyntax;
                return error.UnexpectedToken;
            }
            return shared.makeExprNode(
                arena,
                .{ .array_constructor = .{ .type_spec = type_spec, .items = try items.toOwnedSlice() } },
                start_source,
            );
        },
        .plus => {
            _ = lp.next();
            const operand = try parseExprDepth(lp, arena, min_prec_power, depth + 1);
            return shared.makeExprNode(arena, .{ .unary = .{ .op = .plus, .expr = operand } }, start_source);
        },
        .minus => {
            _ = lp.next();
            const operand = try parseExprDepth(lp, arena, min_prec_power, depth + 1);
            return shared.makeExprNode(arena, .{ .unary = .{ .op = .minus, .expr = operand } }, start_source);
        },
        .dot_op => {
            if (shared.dotOpIs(lp.*, "TRUE")) {
                const logical_tok = lp.next();
                const text = try logicalLiteralText(arena, lp.tokenText(logical_tok), "1");
                return shared.makeExprNode(arena, .{ .literal = .{ .kind = .logical, .text = text } }, start_source);
            }
            if (shared.dotOpIs(lp.*, "FALSE")) {
                const logical_tok = lp.next();
                const text = try logicalLiteralText(arena, lp.tokenText(logical_tok), "0");
                return shared.makeExprNode(arena, .{ .literal = .{ .kind = .logical, .text = text } }, start_source);
            }
            if (shared.dotOpIs(lp.*, "NOT")) {
                _ = lp.next();
                const operand = try parseExprDepth(lp, arena, 3, depth + 1);
                return shared.makeExprNode(arena, .{ .unary = .{ .op = .not, .expr = operand } }, start_source);
            }
            const op_tok = lp.next();
            const op_name = parseDefinedDotOperatorName(arena, lp.tokenText(op_tok)) orelse return error.UnexpectedToken;
            const operand = try parseExprDepth(lp, arena, 3, depth + 1);
            const call_args = try arena.alloc(*Expr, 1);
            call_args[0] = operand;
            const call_node = try shared.makeExprNode(
                arena,
                .{ .call_or_subscript = .{ .name = op_name, .args = call_args } },
                start_source,
            );
            return suffixes.parseComponentSuffixes(
                lp,
                arena,
                call_node,
                depth + 1,
                start_source,
                parseCallArgExpr,
                parseExprDepth,
                shared.makeExprNode,
            );
        },
        else => return error.UnexpectedToken,
    }
}

fn parseCallArgExpr(lp: *LineParser, arena: std.mem.Allocator, depth: usize) ParseExprError!*Expr {
    return suffixes.parseCallArgExpr(
        lp,
        arena,
        depth,
        shared.hasArgumentDimRange,
        parseDimExprDepth,
        parseExprDepth,
    );
}

fn isBozPrefix(text: []const u8) bool {
    if (text.len != 1) return false;
    return switch (std.ascii.toLower(text[0])) {
        'b', 'o', 'z' => true,
        else => false,
    };
}

fn parseDefinedDotOperatorName(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (text.len < 3 or text[0] != '.') return null;
    var i: usize = 1;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    const start = i;
    while (i < text.len and std.ascii.isAlphabetic(text[i])) : (i += 1) {}
    const end = i;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    if (start == end or i >= text.len or text[i] != '.') return null;
    return arena.dupe(u8, text[start..end]) catch null;
}

fn logicalLiteralText(arena: std.mem.Allocator, source_text: []const u8, base: []const u8) ![]const u8 {
    const close_dot = std.mem.lastIndexOfScalar(u8, source_text, '.') orelse return base;
    const suffix = source_text[close_dot + 1 ..];
    if (suffix.len == 0 or suffix[0] != '_') return base;
    return try std.fmt.allocPrint(arena, "{s}{s}", .{ base, suffix });
}
