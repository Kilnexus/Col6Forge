const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const logical_line = @import("../../logical_line.zig");
const lexer = @import("../../lexer.zig");
const context = @import("../token_stream.zig");
const decl = @import("../decl/mod.zig");
const expr = @import("../expr.zig");

const ProgramUnitKind = ast.ProgramUnitKind;
const LineParser = context.LineParser;

fn consumeDoubleColon(lp: *LineParser) bool {
    var scan = lp.*;
    if (!scan.consume(.colon)) return false;
    if (!scan.consume(.colon)) return false;
    lp.* = scan;
    return true;
}

const TypeInfo = struct {
    type_kind: ast.TypeKind,
    kind_selector: ?*ast.Expr = null,
    char_len: ?*ast.Expr,
    derived_type_name: ?[]const u8 = null,
    polymorphic: bool = false,
};

pub const ProgramUnitHeader = struct {
    kind: ProgramUnitKind,
    name: []const u8,
    is_module_procedure: bool,
    pure: bool,
    elemental: bool,
    recursive: bool,
    bind_c: bool,
    bind_name: ?[]const u8,
    result_name: ?[]const u8,
    args: []const []const u8,
    alt_return_dummy_count: usize,
    type_decl: ?ast.Decl,
};

pub const SubmoduleHeader = struct {
    parent_name: []const u8,
    name: []const u8,
};

pub fn parseProgramUnitHeader(arena: std.mem.Allocator, lp: *LineParser, block_data_counter: *usize) !ProgramUnitHeader {
    var kind: ProgramUnitKind = undefined;
    var type_info: ?TypeInfo = null;
    var allow_missing_name = false;
    var saw_module_prefix = false;
    var pure = false;
    var elemental = false;
    var recursive = false;

    try consumeProcedurePrefixes(lp, &pure, &elemental, &recursive);
    saw_module_prefix = lp.consumeKeyword("MODULE");

    if (lp.isKeywordSplit("PROGRAM")) {
        _ = lp.consumeKeyword("PROGRAM");
        kind = .program;
    } else if (lp.isKeywordSplit("SUBROUTINE")) {
        _ = lp.consumeKeyword("SUBROUTINE");
        kind = .subroutine;
    } else if (lp.isKeywordSplit("FUNCTION")) {
        _ = lp.consumeKeyword("FUNCTION");
        kind = .function;
    } else if (lp.isKeywordSplit("BLOCKDATA")) {
        _ = lp.consumeKeyword("BLOCKDATA");
        kind = .block_data;
        allow_missing_name = true;
    } else {
        type_info = try parseTypePrefix(arena, lp) orelse return error.ExpectedProgramUnit;
        try consumeProcedurePrefixes(lp, &pure, &elemental, &recursive);
        saw_module_prefix = lp.consumeKeyword("MODULE");
        if (!lp.isKeywordSplit("FUNCTION")) return error.ExpectedProgramUnit;
        _ = lp.consumeKeyword("FUNCTION");
        kind = .function;
    }

    const name = lp.readName(arena) orelse blk: {
        if (!allow_missing_name) return error.MissingName;
        const synthetic = try std.fmt.allocPrint(arena, "BLOCKDATA{d}", .{block_data_counter.*});
        block_data_counter.* += 1;
        break :blk synthetic;
    };
    var args_list = std.array_list.Managed([]const u8).init(arena);
    var alt_return_dummy_count: usize = 0;
    var saw_arg_parens = false;
    if (lp.consume(.l_paren)) {
        saw_arg_parens = true;
        while (!lp.peekIs(.r_paren)) {
            if (lp.consume(.star)) {
                alt_return_dummy_count += 1;
                _ = lp.consume(.comma);
                continue;
            }
            const arg_name = lp.readName(arena) orelse return error.MissingName;
            try args_list.append(arg_name);
            _ = lp.consume(.comma);
        }
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    }
    var result_name: ?[]const u8 = null;
    var bind_spec: ParsedBindSpec = .{};
    while (true) {
        if (kind == .function and result_name == null and lp.consumeKeyword("RESULT")) {
            _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
            result_name = lp.readName(arena) orelse return error.MissingName;
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            continue;
        }
        if (!bind_spec.bind_c and bind_spec.bind_name == null) {
            const parsed_bind_spec = try parseBindSpec(arena, lp);
            if (parsed_bind_spec.bind_c or parsed_bind_spec.bind_name != null) {
                bind_spec = parsed_bind_spec;
                continue;
            }
        }
        break;
    }
    if ((kind == .subroutine or kind == .function) and bind_spec.bind_c and !saw_arg_parens) {
        return error.UnexpectedToken;
    }

    var type_decl: ?ast.Decl = null;
    if (type_info) |info| {
        const decl_items = try arena.alloc(ast.Declarator, 1);
        decl_items[0] = .{
            .name = name,
            .dims = &.{},
            .char_len = info.char_len,
            .char_len_deferred = false,
        };
        type_decl = .{ .type_decl = .{
            .type_kind = info.type_kind,
            .kind_selector = info.kind_selector,
            .derived_type_name = info.derived_type_name,
            .polymorphic = info.polymorphic,
            .items = decl_items,
            .allocatable = false,
        } };
    }

    return .{
        .kind = kind,
        .name = name,
        .is_module_procedure = saw_module_prefix,
        .pure = pure,
        .elemental = elemental,
        .recursive = recursive,
        .bind_c = bind_spec.bind_c,
        .bind_name = bind_spec.bind_name,
        .result_name = result_name,
        .args = try args_list.toOwnedSlice(),
        .alt_return_dummy_count = alt_return_dummy_count,
        .type_decl = type_decl,
    };
}

const ParsedBindSpec = struct {
    bind_c: bool = false,
    bind_name: ?[]const u8 = null,
};

fn parseBindSpec(arena: std.mem.Allocator, lp: *LineParser) !ParsedBindSpec {
    if (!lp.consumeKeyword("BIND")) return .{};
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;

    var bind_spec: ParsedBindSpec = .{};
    while (!lp.peekIs(.r_paren)) {
        if (lp.peek()) |tok| {
            if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "C")) {
                _ = lp.next();
                bind_spec.bind_c = true;
            } else if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "NAME")) {
                _ = lp.next();
                _ = lp.expect(.equals) orelse return error.UnexpectedToken;
                const string_tok = lp.expect(.string) orelse return error.UnexpectedToken;
                bind_spec.bind_name = try decodeHeaderStringLiteral(arena, lp.tokenText(string_tok));
            } else {
                _ = lp.next();
            }
        } else {
            return error.UnexpectedToken;
        }
        _ = lp.consume(.comma);
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return bind_spec;
}

fn decodeHeaderStringLiteral(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len < 2) return error.InvalidStringLiteral;
    const quote = text[0];
    if ((quote != '\'' and quote != '"') or text[text.len - 1] != quote) return error.InvalidStringLiteral;

    var buffer = std.array_list.Managed(u8).init(arena);
    errdefer buffer.deinit();

    var i: usize = 1;
    while (i + 1 < text.len) {
        if (text[i] == quote and i + 2 < text.len and text[i + 1] == quote) {
            try buffer.append(quote);
            i += 2;
            continue;
        }
        try buffer.append(text[i]);
        i += 1;
    }
    return buffer.toOwnedSlice();
}

pub fn isDuplicateProgramUnitLine(arena: std.mem.Allocator, line: logical_line.LogicalLine, header: ProgramUnitHeader) bool {
    const tokens = lexer.lexLogicalLine(arena, line) catch return false;
    defer arena.free(tokens);
    return isDuplicateProgramUnitTokens(arena, line, tokens, header);
}

pub fn isDuplicateProgramUnitTokens(
    arena: std.mem.Allocator,
    line: logical_line.LogicalLine,
    tokens: []lexer.Token,
    header: ProgramUnitHeader,
) bool {
    const probe_tokens = arena.dupe(lexer.Token, tokens) catch return false;
    var lp = LineParser.init(line, probe_tokens);
    var block_data_counter: usize = 0;
    const parsed = parseProgramUnitHeader(arena, &lp, &block_data_counter) catch return false;
    if (lp.peek() != null) return false;
    if (parsed.kind != header.kind) return false;
    return context.eqNoCase(parsed.name, header.name);
}

fn parseTypePrefix(arena: std.mem.Allocator, lp: *LineParser) !?TypeInfo {
    if (lp.isKeywordSplit("INTEGER")) {
        _ = lp.consumeKeyword("INTEGER");
        return .{
            .type_kind = .integer,
            .kind_selector = try parseTypePrefixOptionalKindSelector(lp, arena),
            .char_len = null,
        };
    }
    if (lp.isKeywordSplit("REAL")) {
        _ = lp.consumeKeyword("REAL");
        return try parseRealTypePrefixSpec(lp, arena);
    }
    if (lp.isKeywordSplit("COMPLEX")) {
        _ = lp.consumeKeyword("COMPLEX");
        return try parseComplexTypePrefixSpec(lp, arena);
    }
    if (lp.isKeywordSplit("LOGICAL")) {
        _ = lp.consumeKeyword("LOGICAL");
        return .{
            .type_kind = .logical,
            .kind_selector = try parseTypePrefixOptionalKindSelector(lp, arena),
            .char_len = null,
        };
    }
    if (lp.isKeywordSplit("CHARACTER")) {
        _ = lp.consumeKeyword("CHARACTER");
        var parsed_len: decl.ParsedCharacterLen = .{};
        if (lp.consume(.star) or lp.peekIs(.l_paren)) {
            parsed_len = try decl.parseCharacterLenSpec(lp, arena);
        }
        return .{
            .type_kind = .character,
            .kind_selector = parsed_len.kind_selector,
            .char_len = parsed_len.expr,
        };
    }
    if (try decl.consumeDoublePrecisionType(lp)) {
        return .{ .type_kind = .double_precision, .kind_selector = null, .char_len = null };
    }
    if (lp.isKeywordSplit("TYPE")) {
        var lookahead = lp.*;
        _ = lookahead.consumeKeyword("TYPE");
        if (!lookahead.peekIs(.l_paren)) return null;
        lp.* = lookahead;
        _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
        const name = lp.readName(arena) orelse return error.MissingName;
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        return .{ .type_kind = .derived, .kind_selector = null, .char_len = null, .derived_type_name = name };
    }
    if (lp.isKeywordSplit("CLASS")) {
        var lookahead = lp.*;
        _ = lookahead.consumeKeyword("CLASS");
        if (!lookahead.peekIs(.l_paren)) return null;
        lp.* = lookahead;
        _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
        if (lp.consume(.star)) {
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            return .{
                .type_kind = .derived,
                .kind_selector = null,
                .char_len = null,
                .derived_type_name = null,
                .polymorphic = true,
            };
        }
        const name = lp.readName(arena) orelse return error.MissingName;
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        return .{
            .type_kind = .derived,
            .kind_selector = null,
            .char_len = null,
            .derived_type_name = name,
            .polymorphic = true,
        };
    }
    return null;
}

pub const DerivedTypeHeader = struct {
    name: []const u8,
    parent_name: ?[]const u8 = null,
    abstract: bool = false,
    bind_c: bool = false,
};

pub fn parseDerivedTypeHeader(arena: std.mem.Allocator, lp: *LineParser) !DerivedTypeHeader {
    if (!lp.consumeKeyword("TYPE")) return error.UnexpectedToken;
    var header: DerivedTypeHeader = .{ .name = "" };
    while (lp.consume(.comma)) {
        if (lp.consumeKeyword("ABSTRACT")) {
            if (header.abstract) return error.DuplicateAbstractAttribute;
            header.abstract = true;
            continue;
        }
        if (lp.consumeKeyword("PUBLIC")) {
            continue;
        }
        if (lp.consumeKeyword("EXTENDS")) {
            _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
            header.parent_name = lp.readName(arena) orelse return error.MissingName;
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            continue;
        }
        if (lp.consumeKeyword("BIND")) {
            _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
            if (!lp.consumeKeyword("C")) return error.UnexpectedToken;
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            header.bind_c = true;
            continue;
        }
        return error.UnexpectedToken;
    }
    if (lp.peekIs(.colon)) {
        _ = lp.expect(.colon) orelse return error.UnexpectedToken;
        _ = lp.expect(.colon) orelse return error.UnexpectedToken;
    }
    header.name = lp.readName(arena) orelse return error.MissingName;
    return header;
}

pub fn parseTypeBoundProcedureBindings(
    arena: std.mem.Allocator,
    lp: *LineParser,
) ![]const ast.TypeBoundProcedureBinding {
    if (!lp.consumeKeyword("PROCEDURE")) return error.UnexpectedToken;

    var interface_name: ?[]const u8 = null;
    var syntax_error_message: ?[]const u8 = null;
    var saw_binding_attr = false;
    if (lp.consume(.l_paren)) {
        if (lp.peekIs(.r_paren)) {
            syntax_error_message = "Interface-name expected";
        } else {
            interface_name = lp.readName(arena) orelse blk: {
                if (syntax_error_message == null) syntax_error_message = "Interface-name expected";
                break :blk null;
            };
            if (!lp.peekIs(.r_paren)) {
                if (syntax_error_message == null) syntax_error_message = "')' expected";
                while (lp.peek()) |tok| {
                    if (tok.kind == .r_paren) break;
                    _ = lp.next();
                }
            }
        }
        _ = lp.consume(.r_paren);
    }

    var deferred = false;
    var nopass = false;
    var pass_name: ?[]const u8 = null;
    var private = false;
    var non_overridable = false;

    while (lp.consume(.comma)) {
        if (consumeDoubleColon(lp)) break;
        const attr_name = lp.readName(arena) orelse {
            if (syntax_error_message == null) syntax_error_message = "Expected binding attribute";
            break;
        };
        if (std.ascii.eqlIgnoreCase(attr_name, "DEFERRED")) {
            if (deferred and syntax_error_message == null) syntax_error_message = "Duplicate DEFERRED";
            deferred = true;
            saw_binding_attr = true;
        } else if (std.ascii.eqlIgnoreCase(attr_name, "NOPASS")) {
            nopass = true;
            saw_binding_attr = true;
        } else if (std.ascii.eqlIgnoreCase(attr_name, "NON_OVERRIDABLE")) {
            non_overridable = true;
            saw_binding_attr = true;
        } else if (std.ascii.eqlIgnoreCase(attr_name, "PASS")) {
            saw_binding_attr = true;
            if (lp.consume(.l_paren)) {
                pass_name = lp.readName(arena) orelse blk: {
                    if (syntax_error_message == null) syntax_error_message = "Expected PASS argument";
                    break :blk null;
                };
                if (!lp.peekIs(.r_paren) and syntax_error_message == null) syntax_error_message = "Expected ')'";
                _ = lp.consume(.r_paren);
            }
        } else if (std.ascii.eqlIgnoreCase(attr_name, "PRIVATE")) {
            private = true;
            saw_binding_attr = true;
        } else if (std.ascii.eqlIgnoreCase(attr_name, "PUBLIC")) {
            private = false;
            saw_binding_attr = true;
        } else if (lp.consume(.l_paren)) {
            try consumeBalancedParens(lp);
        }
    }
    const saw_double_colon = consumeDoubleColon(lp);
    if (!saw_double_colon and syntax_error_message == null and (saw_binding_attr or lineParserHasBindingTarget(lp))) {
        syntax_error_message = "Expected '::'";
    }

    var out = std.array_list.Managed(ast.TypeBoundProcedureBinding).init(arena);
    while (true) {
        const binding_name = lp.readName(arena) orelse {
            try out.append(.{
                .name = "__invalid_binding__",
                .interface_name = interface_name,
                .implementation_name = null,
                .deferred = deferred,
                .nopass = nopass,
                .pass_name = pass_name,
                .private = private,
                .non_overridable = non_overridable,
                .syntax_error_message = syntax_error_message orelse "Expected binding name",
            });
            break;
        };
        var implementation_name: ?[]const u8 = null;
        var binding_error_message = syntax_error_message;
        if (lp.consume(.equals)) {
            if (!lp.consume(.greater)) {
                if (binding_error_message == null) binding_error_message = "Expected binding target";
            } else {
                implementation_name = lp.readName(arena) orelse blk: {
                    if (binding_error_message == null) binding_error_message = "Expected binding target";
                    break :blk null;
                };
            }
        }
        try out.append(.{
            .name = binding_name,
            .interface_name = interface_name,
            .implementation_name = implementation_name,
            .deferred = deferred,
            .nopass = nopass,
            .pass_name = pass_name,
            .private = private,
            .non_overridable = non_overridable,
            .syntax_error_message = binding_error_message,
        });
        if (!lp.consume(.comma)) break;
    }
    return out.toOwnedSlice();
}

pub fn parseTypeBoundGenericBindings(
    arena: std.mem.Allocator,
    lp: *LineParser,
) ![]const ast.TypeBoundProcedureBinding {
    if (!lp.consumeKeyword("GENERIC")) return error.UnexpectedToken;

    var private = false;
    var syntax_error_message: ?[]const u8 = null;
    while (lp.consume(.comma)) {
        if (consumeDoubleColon(lp)) break;
        const attr_name = lp.readName(arena) orelse {
            syntax_error_message = "Expected access-specifier";
            break;
        };
        if (std.ascii.eqlIgnoreCase(attr_name, "PRIVATE")) {
            private = true;
        } else if (std.ascii.eqlIgnoreCase(attr_name, "PUBLIC")) {
            private = false;
        } else {
            if (syntax_error_message == null) syntax_error_message = "Expected access-specifier";
            if (lp.consume(.l_paren)) {
                try consumeBalancedParens(lp);
            }
        }
    }
    _ = consumeDoubleColon(lp);

    var out = std.array_list.Managed(ast.TypeBoundProcedureBinding).init(arena);
    const binding_name = try parseGenericBindingName(arena, lp) orelse {
        try out.append(.{
            .name = "__invalid_binding__",
            .is_generic = true,
            .private = private,
            .syntax_error_message = syntax_error_message orelse "Expected binding name",
        });
        return out.toOwnedSlice();
    };

    var saw_arrow = false;
    if (lp.consume(.equals)) {
        saw_arrow = true;
        if (!lp.consume(.greater) and syntax_error_message == null) {
            syntax_error_message = "Expected specific binding";
        }
    } else if (syntax_error_message == null) {
        syntax_error_message = "Expected specific binding";
    }

    while (true) {
        var binding_error_message = syntax_error_message;
        const implementation_name = if (!saw_arrow)
            null
        else
            lp.readName(arena) orelse blk: {
                if (binding_error_message == null) binding_error_message = "Expected specific binding";
                break :blk null;
            };

        if (implementation_name != null and lp.peek() != null and !lp.peekIs(.comma) and binding_error_message == null) {
            binding_error_message = "Junk after binding target";
        }

        try out.append(.{
            .name = binding_name,
            .is_generic = true,
            .implementation_name = implementation_name,
            .private = private,
            .syntax_error_message = binding_error_message,
        });

        if (implementation_name == null) break;
        if (!lp.consume(.comma)) break;
        saw_arrow = true;
        if (lp.peek() == null) break;
    }
    return out.toOwnedSlice();
}

pub fn parseTypeBoundFinalBindings(
    arena: std.mem.Allocator,
    lp: *LineParser,
) ![]const []const u8 {
    if (!lp.consumeKeyword("FINAL")) return error.UnexpectedToken;
    _ = consumeDoubleColon(lp);

    var out = std.array_list.Managed([]const u8).init(arena);
    while (true) {
        const name = lp.readName(arena) orelse return error.MissingName;
        try out.append(name);
        if (!lp.consume(.comma)) break;
    }
    return out.toOwnedSlice();
}

fn parseGenericBindingName(arena: std.mem.Allocator, lp: *LineParser) !?[]const u8 {
    const base_name = lp.readName(arena) orelse return null;
    if (!std.ascii.eqlIgnoreCase(base_name, "OPERATOR") and !std.ascii.eqlIgnoreCase(base_name, "ASSIGNMENT")) {
        return base_name;
    }
    if (!lp.consume(.l_paren)) return base_name;

    var buffer = std.array_list.Managed(u8).init(arena);
    errdefer buffer.deinit();
    try buffer.appendSlice(base_name);
    try buffer.append('(');
    while (lp.peek()) |tok| {
        _ = lp.next();
        if (tok.kind == .r_paren) {
            try buffer.append(')');
            return @as([]const u8, try buffer.toOwnedSlice());
        }
        try buffer.appendSlice(lp.tokenText(tok));
    }
    return @as([]const u8, try buffer.toOwnedSlice());
}

pub fn parseSubmoduleHeader(arena: std.mem.Allocator, lp: *LineParser) !SubmoduleHeader {
    if (!lp.consumeKeyword("SUBMODULE")) return error.UnexpectedToken;
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;

    var parent_name = lp.readName(arena) orelse return error.MissingName;
    if (lp.consume(.colon)) {
        parent_name = lp.readName(arena) orelse return error.MissingName;
        if (lp.consume(.colon)) return error.UnexpectedToken;
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;

    return .{
        .parent_name = parent_name,
        .name = lp.readName(arena) orelse return error.MissingName,
    };
}

fn lineParserHasBindingTarget(lp: *const LineParser) bool {
    var scan = lp.*;
    while (scan.peek()) |tok| {
        _ = scan.next();
        if (tok.kind != .equals) continue;
        if (scan.peek()) |next| {
            if (next.kind == .greater) return true;
        }
    }
    return false;
}

fn consumeBalancedParens(lp: *LineParser) !void {
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

fn consumeProcedurePrefixes(lp: *LineParser, pure: *bool, elemental: *bool, recursive: *bool) !void {
    while (true) {
        if (lp.consumeKeyword("PURE")) {
            if (pure.*) return error.DuplicatePureAttribute;
            pure.* = true;
            continue;
        }
        if (lp.consumeKeyword("ELEMENTAL")) {
            if (elemental.*) return error.DuplicateElementalAttribute;
            elemental.* = true;
            continue;
        }
        if (lp.consumeKeyword("RECURSIVE")) {
            if (recursive.*) return error.DuplicateRecursiveAttribute;
            recursive.* = true;
            continue;
        }
        if (lp.consumeKeyword("IMPURE")) continue;
        break;
    }
}

fn parseComplexTypePrefixSpec(lp: *LineParser, arena: std.mem.Allocator) !TypeInfo {
    if (lp.consume(.star)) {
        const selector = try decl.parseLegacyStarSelectorExpr(lp, arena);
        return .{
            .type_kind = .complex,
            .kind_selector = selector,
            .char_len = null,
        };
    }
    if (!lp.peekIs(.l_paren)) return .{ .type_kind = .complex, .kind_selector = null, .char_len = null };

    const selector = try parseTypePrefixKindSelectorExpr(lp, arena);
    return .{
        .type_kind = .complex,
        .kind_selector = selector,
        .char_len = null,
    };
}

fn parseRealTypePrefixSpec(lp: *LineParser, arena: std.mem.Allocator) !TypeInfo {
    if (lp.consume(.star)) {
        const selector = try decl.parseLegacyStarSelectorExpr(lp, arena);
        return .{
            .type_kind = .real,
            .kind_selector = selector,
            .char_len = null,
        };
    }
    if (!lp.peekIs(.l_paren)) return .{ .type_kind = .real, .kind_selector = null, .char_len = null };

    const selector = try parseTypePrefixKindSelectorExpr(lp, arena);
    return .{
        .type_kind = .real,
        .kind_selector = selector,
        .char_len = null,
    };
}

fn parseTypePrefixOptionalKindSelector(lp: *LineParser, arena: std.mem.Allocator) !?*ast.Expr {
    if (lp.consume(.star)) {
        return try decl.parseLegacyStarSelectorExpr(lp, arena);
    }
    if (!lp.peekIs(.l_paren)) return null;
    return parseTypePrefixKindSelectorExpr(lp, arena);
}

fn parseTypePrefixKindSelectorExpr(lp: *LineParser, arena: std.mem.Allocator) !?*ast.Expr {
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var selector: ?*ast.Expr = null;
    while (!lp.peekIs(.r_paren)) {
        if (lp.peek()) |tok| {
            if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "KIND")) {
                _ = lp.next();
                _ = lp.expect(.equals) orelse return error.UnexpectedToken;
                selector = try expr.parseExpr(lp, arena, 0);
                _ = lp.consume(.comma);
                continue;
            }
            if (tok.kind == .identifier and context.eqNoCase(lp.tokenText(tok), "LEN")) {
                _ = lp.next();
                _ = lp.expect(.equals) orelse return error.UnexpectedToken;
                _ = try expr.parseExpr(lp, arena, 0);
                _ = lp.consume(.comma);
                continue;
            }
        }
        const parsed = try expr.parseExpr(lp, arena, 0);
        if (selector == null) selector = parsed;
        _ = lp.consume(.comma);
    }
    _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
    return selector;
}
