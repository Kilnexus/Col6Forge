const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../token_stream.zig");
const expr = @import("../expr.zig");
const format = @import("format.zig");
const helpers = @import("helpers.zig");
const lexer = @import("../../lexer.zig");

const LineParser = context.LineParser;
const StmtNode = ast.StmtNode;
const Expr = ast.Expr;

const ParseStmtError = anyerror;

fn currentSource(lp: LineParser) ast.SourceRef {
    if (lp.index < lp.tokens.len) {
        const tok = lp.tokens[lp.index];
        return .{
            .line = tok.line,
            .column = tok.column,
            .text = lp.line.text,
        };
    }
    return .{
        .line = lp.line.span.start_line,
        .column = if (lp.line.segments.len > 0) lp.line.segments[0].column else 1,
        .text = lp.line.text,
    };
}

pub fn parseWriteStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("WRITE");
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var unit_expr: ?*Expr = null;
    var format_spec: ast.FormatSpec = .{ .none = {} };
    var rec_expr: ?*Expr = null;
    var err_label: ?[]const u8 = null;
    var iostat_expr: ?*Expr = null;
    var controls = std.array_list.Managed(ast.ControlItem).init(arena);
    var saw_format = false;
    var first = true;
    while (!lp.peekIs(.r_paren)) {
        if (!first) {
            _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        }
        first = false;
        const tok = lp.peek() orelse return error.UnexpectedToken;
        // Positional UNIT expression when the control list does not start with
        // keyword assignments.
        if (unit_expr == null and !(tok.kind == .identifier and helpers.nextTokenIs(lp.*, .equals))) {
            if (tok.kind == .star) {
                _ = lp.next();
                // WRITE(*,...) means default output unit.
                unit_expr = try makeIntegerLiteral(arena, 6);
                continue;
            }
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (!saw_format and !(tok.kind == .identifier and helpers.nextTokenIs(lp.*, .equals))) {
            format_spec = try parseFormatValue(arena, lp);
            saw_format = true;
            continue;
        }
        const name_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
        _ = lp.expect(.equals) orelse return error.UnexpectedToken;
        const name = lp.tokenText(name_tok);
        const value_source = currentSource(lp.*);
        if (context.eqNoCase(name, "UNIT")) {
            const unit_tok = lp.peek() orelse return error.UnexpectedToken;
            if (unit_tok.kind == .star) {
                _ = lp.next();
                unit_expr = try makeIntegerLiteral(arena, 6);
                continue;
            }
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "FMT")) {
            format_spec = try parseFormatValue(arena, lp);
            saw_format = true;
            continue;
        }
        if (context.eqNoCase(name, "ERR")) {
            const err_tok = lp.peek() orelse return error.UnexpectedToken;
            if (err_tok.kind == .integer or err_tok.kind == .identifier) {
                _ = lp.next();
                err_label = normalizeLabelText(lp.tokenText(err_tok));
                continue;
            }
            _ = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "IOSTAT")) {
            iostat_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        const value = try expr.parseExpr(lp, arena, 0);
        if (context.eqNoCase(name, "REC")) {
            rec_expr = value;
        } else {
            try appendControlItem(&controls, name, value, value_source);
        }
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    const unit_final = unit_expr orelse return error.UnexpectedToken;

    const args = try parseIoList(arena, lp);
    return .{ .write = .{ .unit = unit_final, .format = format_spec, .rec = rec_expr, .args = args, .err_label = err_label, .iostat = iostat_expr, .controls = try controls.toOwnedSlice() } };
}

pub fn parseReadStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("READ");
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var unit_expr: ?*Expr = null;
    var format_spec: ast.FormatSpec = .{ .none = {} };
    var rec_expr: ?*Expr = null;
    var err_label: ?[]const u8 = null;
    var end_label: ?[]const u8 = null;
    var iostat_expr: ?*Expr = null;
    var controls = std.array_list.Managed(ast.ControlItem).init(arena);
    var saw_format = false;
    var first = true;
    while (!lp.peekIs(.r_paren)) {
        if (!first) {
            _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        }
        first = false;
        const tok = lp.peek() orelse return error.UnexpectedToken;
        if (unit_expr == null and !(tok.kind == .identifier and helpers.nextTokenIs(lp.*, .equals))) {
            if (tok.kind == .star) {
                _ = lp.next();
                // READ(*,...) means default input unit.
                unit_expr = try makeIntegerLiteral(arena, 5);
                continue;
            }
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (!saw_format and !(tok.kind == .identifier and helpers.nextTokenIs(lp.*, .equals))) {
            format_spec = try parseFormatValue(arena, lp);
            saw_format = true;
            continue;
        }
        const name_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
        _ = lp.expect(.equals) orelse return error.UnexpectedToken;
        const name = lp.tokenText(name_tok);
        const value_source = currentSource(lp.*);
        if (context.eqNoCase(name, "UNIT")) {
            const unit_tok = lp.peek() orelse return error.UnexpectedToken;
            if (unit_tok.kind == .star) {
                _ = lp.next();
                unit_expr = try makeIntegerLiteral(arena, 5);
                continue;
            }
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "FMT")) {
            format_spec = try parseFormatValue(arena, lp);
            saw_format = true;
            continue;
        }
        if (context.eqNoCase(name, "ERR")) {
            const err_tok = lp.peek() orelse return error.UnexpectedToken;
            if (err_tok.kind == .integer or err_tok.kind == .identifier) {
                _ = lp.next();
                err_label = normalizeLabelText(lp.tokenText(err_tok));
                continue;
            }
            _ = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "END")) {
            const end_tok = lp.peek() orelse return error.UnexpectedToken;
            if (end_tok.kind == .integer or end_tok.kind == .identifier) {
                _ = lp.next();
                end_label = normalizeLabelText(lp.tokenText(end_tok));
                continue;
            }
            _ = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "IOSTAT")) {
            iostat_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        const value = try expr.parseExpr(lp, arena, 0);
        if (context.eqNoCase(name, "REC")) {
            rec_expr = value;
        } else {
            try appendControlItem(&controls, name, value, value_source);
        }
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    const unit_final = unit_expr orelse return error.UnexpectedToken;

    const args = try parseIoList(arena, lp);
    return .{ .read = .{ .unit = unit_final, .format = format_spec, .rec = rec_expr, .args = args, .err_label = err_label, .end_label = end_label, .iostat = iostat_expr, .controls = try controls.toOwnedSlice() } };
}

pub fn parsePrintStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("PRINT");
    const format_spec = try parseFormatValue(arena, lp);

    var args: []*Expr = &.{};
    if (lp.consume(.comma)) {
        if (lp.peek() == null) return error.UnexpectedToken;
        args = try parseIoList(arena, lp);
    }
    const unit_expr = try makeIntegerLiteral(arena, 6);
    return .{ .write = .{
        .unit = unit_expr,
        .format = format_spec,
        .rec = null,
        .args = args,
        .err_label = null,
        .iostat = null,
    } };
}

pub fn parseOpenStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("OPEN");
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var unit_expr: ?*Expr = null;
    var recl_expr: ?*Expr = null;
    var file_expr: ?*Expr = null;
    var access_expr: ?*Expr = null;
    var form_expr: ?*Expr = null;
    var blank_expr: ?*Expr = null;
    var status_expr: ?*Expr = null;
    var err_label: ?[]const u8 = null;
    var iostat_expr: ?*Expr = null;
    var controls = std.array_list.Managed(ast.ControlItem).init(arena);
    var first = true;
    while (!lp.peekIs(.r_paren)) {
        if (!first) {
            _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        }
        first = false;
        const tok = lp.peek() orelse return error.UnexpectedToken;
        if (unit_expr == null and !(tok.kind == .identifier and helpers.nextTokenIs(lp.*, .equals))) {
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        const name_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
        _ = lp.expect(.equals) orelse return error.UnexpectedToken;
        const name = lp.tokenText(name_tok);
        const value_source = currentSource(lp.*);
        if (context.eqNoCase(name, "UNIT")) {
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "FILE")) {
            file_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "ACCESS")) {
            access_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "FORM")) {
            form_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "BLANK")) {
            blank_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "STATUS")) {
            status_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "ERR")) {
            const err_tok = lp.peek() orelse return error.UnexpectedToken;
            if (err_tok.kind == .integer or err_tok.kind == .identifier) {
                _ = lp.next();
                err_label = normalizeLabelText(lp.tokenText(err_tok));
                continue;
            }
            _ = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "IOSTAT")) {
            iostat_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        if (context.eqNoCase(name, "RECL")) {
            recl_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        try appendControlItem(&controls, name, try expr.parseExpr(lp, arena, 0), value_source);
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    const unit_final = unit_expr orelse return error.UnexpectedToken;
    return .{ .open = .{
        .unit = unit_final,
        .recl = recl_expr,
        .file = file_expr,
        .access = access_expr,
        .form = form_expr,
        .blank = blank_expr,
        .status = status_expr,
        .err_label = err_label,
        .iostat = iostat_expr,
        .controls = try controls.toOwnedSlice(),
    } };
}

pub fn parseInquireStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("INQUIRE");
    const controls = try parseControlList(arena, lp);
    return .{ .inquire = .{ .controls = controls } };
}

pub fn parseCloseStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("CLOSE");
    const controls = try parseControlList(arena, lp);
    return .{ .close = .{ .controls = controls } };
}

fn normalizeLabelText(text: []const u8) []const u8 {
    var all_digits = true;
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) {
            all_digits = false;
            break;
        }
    }
    if (!all_digits) {
        return text;
    }
    var start: usize = 0;
    while (start < text.len and text[start] == '0') : (start += 1) {}
    return if (start == text.len) "0" else text[start..];
}

fn parseFormatValue(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!ast.FormatSpec {
    const tok = lp.peek() orelse return error.UnexpectedToken;

    if (tok.kind == .star and !helpers.nextTokenIs(lp.*, .equals)) {
        _ = lp.next();
        return .{ .list_directed = {} };
    }
    if (tok.kind == .integer and !helpers.nextTokenIs(lp.*, .equals)) {
        _ = lp.next();
        return .{ .label = normalizeLabelText(lp.tokenText(tok)) };
    }

    const fmt_expr = try expr.parseExpr(lp, arena, 0);
    if (fmt_expr.* == .literal) {
        const lit = fmt_expr.literal;
        if (lit.kind == .string) {
            const items = try format.parseInlineFormatSpec(arena, lit.text, lexer.TokenKind.string);
            return .{ .inline_items = items };
        }
        if (lit.kind == .hollerith) {
            const items = try format.parseInlineFormatSpec(arena, lit.text, lexer.TokenKind.hollerith);
            return .{ .inline_items = items };
        }
    }
    return .{ .expr = fmt_expr };
}

pub fn parseRewindStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("REWIND");
    if (!lp.peekIs(.l_paren)) {
        const unit_expr = try parseUnitStatementControl(arena, lp);
        return .{ .rewind = .{ .unit = unit_expr, .err_label = null, .iostat = null } };
    }

    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var unit_expr: ?*Expr = null;
    var err_label: ?[]const u8 = null;
    var iostat_expr: ?*Expr = null;
    var first = true;
    while (!lp.peekIs(.r_paren)) {
        if (!first) {
            _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        }
        first = false;
        if (lp.peekIs(.identifier) and helpers.nextTokenIs(lp.*, .equals)) {
            const name_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            const name = lp.tokenText(name_tok);
            if (context.eqNoCase(name, "UNIT")) {
                unit_expr = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            if (context.eqNoCase(name, "ERR")) {
                const err_tok = lp.peek() orelse return error.UnexpectedToken;
                if (err_tok.kind == .integer or err_tok.kind == .identifier) {
                    _ = lp.next();
                    err_label = normalizeLabelText(lp.tokenText(err_tok));
                    continue;
                }
                _ = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            if (context.eqNoCase(name, "IOSTAT")) {
                iostat_expr = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            return error.UnsupportedIoControlClause;
        }
        if (unit_expr == null) {
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        return error.UnsupportedIoControlClause;
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    const unit_final = unit_expr orelse return error.UnexpectedToken;
    return .{ .rewind = .{ .unit = unit_final, .err_label = err_label, .iostat = iostat_expr } };
}

pub fn parseBackspaceStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("BACKSPACE");
    if (!lp.peekIs(.l_paren)) {
        const unit_expr = try parseUnitStatementControl(arena, lp);
        return .{ .backspace = .{ .unit = unit_expr, .err_label = null, .iostat = null } };
    }

    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var unit_expr: ?*Expr = null;
    var err_label: ?[]const u8 = null;
    var iostat_expr: ?*Expr = null;
    var first = true;
    while (!lp.peekIs(.r_paren)) {
        if (!first) {
            _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        }
        first = false;
        if (lp.peekIs(.identifier) and helpers.nextTokenIs(lp.*, .equals)) {
            const name_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            const name = lp.tokenText(name_tok);
            if (context.eqNoCase(name, "UNIT")) {
                unit_expr = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            if (context.eqNoCase(name, "ERR")) {
                const err_tok = lp.peek() orelse return error.UnexpectedToken;
                if (err_tok.kind == .integer or err_tok.kind == .identifier) {
                    _ = lp.next();
                    err_label = normalizeLabelText(lp.tokenText(err_tok));
                    continue;
                }
                _ = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            if (context.eqNoCase(name, "IOSTAT")) {
                iostat_expr = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            return error.UnsupportedIoControlClause;
        }
        if (unit_expr == null) {
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        return error.UnsupportedIoControlClause;
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    const unit_final = unit_expr orelse return error.UnexpectedToken;
    return .{ .backspace = .{ .unit = unit_final, .err_label = err_label, .iostat = iostat_expr } };
}

pub fn parseEndfileStatement(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!StmtNode {
    _ = lp.consumeKeyword("ENDFILE");
    if (!lp.peekIs(.l_paren)) {
        const unit_expr = try parseUnitStatementControl(arena, lp);
        return .{ .endfile = .{ .unit = unit_expr, .err_label = null, .iostat = null } };
    }

    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var unit_expr: ?*Expr = null;
    var err_label: ?[]const u8 = null;
    var iostat_expr: ?*Expr = null;
    var first = true;
    while (!lp.peekIs(.r_paren)) {
        if (!first) {
            _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        }
        first = false;
        if (lp.peekIs(.identifier) and helpers.nextTokenIs(lp.*, .equals)) {
            const name_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            const name = lp.tokenText(name_tok);
            if (context.eqNoCase(name, "UNIT")) {
                unit_expr = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            if (context.eqNoCase(name, "ERR")) {
                const err_tok = lp.peek() orelse return error.UnexpectedToken;
                if (err_tok.kind == .integer or err_tok.kind == .identifier) {
                    _ = lp.next();
                    err_label = normalizeLabelText(lp.tokenText(err_tok));
                    continue;
                }
                _ = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            if (context.eqNoCase(name, "IOSTAT")) {
                iostat_expr = try expr.parseExpr(lp, arena, 0);
                continue;
            }
            return error.UnsupportedIoControlClause;
        }
        if (unit_expr == null) {
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        return error.UnsupportedIoControlClause;
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    const unit_final = unit_expr orelse return error.UnexpectedToken;
    return .{ .endfile = .{ .unit = unit_final, .err_label = err_label, .iostat = iostat_expr } };
}

fn parseUnitStatementControl(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!*Expr {
    // Support both positional UNIT and control-list forms:
    // REWIND 10
    // REWIND(UNIT=10)
    if (!lp.peekIs(.l_paren)) {
        if (lp.peekIs(.identifier) and helpers.nextTokenIs(lp.*, .equals)) {
            return error.UnsupportedIoControlClause;
        }
        return expr.parseExpr(lp, arena, 0);
    }
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var unit_expr: ?*Expr = null;
    var first = true;
    while (!lp.peekIs(.r_paren)) {
        if (!first) {
            _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        }
        first = false;
        if (lp.peekIs(.identifier) and helpers.nextTokenIs(lp.*, .equals)) {
            const name_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            const value = try expr.parseExpr(lp, arena, 0);
            const name = lp.tokenText(name_tok);
            if (context.eqNoCase(name, "UNIT")) {
                unit_expr = value;
            } else {
                // Do not silently drop controls such as IOSTAT= or ERR=.
                return error.UnsupportedIoControlClause;
            }
            continue;
        }
        // Positional unit inside parentheses.
        if (unit_expr == null) {
            unit_expr = try expr.parseExpr(lp, arena, 0);
            continue;
        }
        return error.UnsupportedIoControlClause;
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return unit_expr orelse error.UnexpectedToken;
}

fn parseControlList(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError![]ast.ControlItem {
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var controls = std.array_list.Managed(ast.ControlItem).init(arena);
    var first = true;
    while (!lp.peekIs(.r_paren)) {
        if (!first) {
            _ = lp.expect(.comma) orelse return error.UnexpectedToken;
        }
        first = false;
        var name_opt: ?[]const u8 = null;
        if (lp.peekIs(.identifier) and helpers.nextTokenIs(lp.*, .equals)) {
            const name_tok = lp.next();
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            name_opt = lp.tokenText(name_tok);
        }
        const value_source = currentSource(lp.*);
        const value = try expr.parseExpr(lp, arena, 0);
        try controls.append(.{
            .name = name_opt,
            .value = value,
            .source = value_source,
        });
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return controls.toOwnedSlice();
}

fn appendControlItem(
    controls: *std.array_list.Managed(ast.ControlItem),
    name: []const u8,
    value: *Expr,
    source: ast.SourceRef,
) ParseStmtError!void {
    try controls.append(.{
        .name = name,
        .value = value,
        .source = source,
    });
}

fn parseIoList(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError![]*Expr {
    var args = std.array_list.Managed(*Expr).init(arena);
    if (lp.peek() == null) return args.toOwnedSlice();

    while (lp.peek() != null) {
        const items = try parseIoItem(arena, lp);
        try args.appendSlice(items);
        if (!lp.consume(.comma)) break;
    }
    return args.toOwnedSlice();
}

fn parseIoItem(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError![]*Expr {
    if (lp.peekIs(.l_paren) and isImpliedDoStart(lp.*)) {
        const implied_node = try parseImpliedDoExpr(arena, lp);
        const items = try arena.alloc(*Expr, 1);
        items[0] = implied_node;
        return items;
    }
    const node = try expr.parseExpr(lp, arena, 0);
    const items = try arena.alloc(*Expr, 1);
    items[0] = node;
    return items;
}

fn isImpliedDoStart(lp: LineParser) bool {
    if (!lp.peekIs(.l_paren)) return false;
    var depth: usize = 0;
    var idx = lp.index + 1;
    while (idx < lp.tokens.len) : (idx += 1) {
        const tok = lp.tokens[idx];
        switch (tok.kind) {
            .l_paren => depth += 1,
            .r_paren => {
                if (depth == 0) return false;
                depth -= 1;
            },
            .comma => {
                if (depth == 0) {
                    if (idx + 2 >= lp.tokens.len) return false;
                    const next = lp.tokens[idx + 1];
                    const after = lp.tokens[idx + 2];
                    if (next.kind == .identifier and after.kind == .equals) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn parseImpliedDoExpr(arena: std.mem.Allocator, lp: *LineParser) ParseStmtError!*Expr {
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var items = std.array_list.Managed(*Expr).init(arena);

    while (true) {
        if (lp.peek() == null) return error.UnexpectedEOF;
        if (lp.peekIs(.l_paren) and isImpliedDoStart(lp.*)) {
            const nested = try parseImpliedDoExpr(arena, lp);
            try items.append(nested);
        } else {
            const node = try expr.parseExpr(lp, arena, 0);
            try items.append(node);
        }
        if (!lp.consume(.comma)) return error.UnexpectedToken;
        if (lp.peekIs(.identifier) and helpers.nextTokenIs(lp.*, .equals)) break;
    }

    const var_name = lp.readName(arena) orelse return error.UnexpectedToken;
    _ = lp.expect(.equals) orelse return error.UnexpectedToken;
    const start_expr = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.comma) orelse return error.UnexpectedToken;
    const end_expr = try expr.parseExpr(lp, arena, 0);
    var step_expr: ?*Expr = null;
    if (lp.consume(.comma)) {
        step_expr = try expr.parseExpr(lp, arena, 0);
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;

    const node = try arena.create(Expr);
    node.* = .{
        .implied_do = .{
            .items = try items.toOwnedSlice(),
            .var_name = var_name,
            .start = start_expr,
            .end = end_expr,
            .step = step_expr,
        },
    };
    return node;
}

fn makeIntegerLiteral(arena: std.mem.Allocator, value: i64) !*Expr {
    const text = try std.fmt.allocPrint(arena, "{d}", .{value});
    const node = try arena.create(Expr);
    node.* = .{ .literal = .{ .kind = .integer, .text = text } };
    return node;
}
