const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common = @import("common.zig");
const expr = @import("../expr.zig");
const declarators = @import("declarators.zig");
const type_specs = @import("type_specs.zig");

const LineParser = common.LineParser;
const Decl = common.Decl;
const ParamAssign = common.ParamAssign;
const CommonBlock = common.CommonBlock;
const EquivalenceGroup = common.EquivalenceGroup;
const ImplicitRule = common.ImplicitRule;

pub const ParsedCharacterLen = common.ParsedCharacterLen;

pub fn isDeclarationStart(lp: LineParser) bool {
    if (lp.isKeywordSplit("TYPE")) {
        var scan = lp;
        _ = scan.consumeKeyword("TYPE");
        if (scan.isKeywordSplit("IS")) return false;
    }
    if (lp.isKeywordSplit("CLASS")) {
        var scan = lp;
        _ = scan.consumeKeyword("CLASS");
        if (scan.isKeywordSplit("IS") or scan.isKeywordSplit("DEFAULT")) return false;
        return true;
    }
    if (lp.isKeywordSplit("INTEGER") or lp.isKeywordSplit("REAL") or lp.isKeywordSplit("COMPLEX") or lp.isKeywordSplit("LOGICAL") or lp.isKeywordSplit("CHARACTER") or lp.isKeywordSplit("BYTE")) return true;
    if (type_specs.isDoubleComplexTypeStart(lp)) return true;
    if (type_specs.isDoublePrecisionTypeStart(lp)) return true;
    if (type_specs.isDerivedTypeDeclStart(lp)) return true;
    return lp.isKeywordSplit("DIMENSION") or lp.isKeywordSplit("ALLOCATABLE") or lp.isKeywordSplit("POINTER") or lp.isKeywordSplit("PARAMETER") or lp.isKeywordSplit("COMMON") or lp.isKeywordSplit("EQUIVALENCE") or lp.isKeywordSplit("IMPLICIT") or lp.isKeywordSplit("EXTERNAL") or lp.isKeywordSplit("INTRINSIC") or lp.isKeywordSplit("SAVE") or lp.isKeywordSplit("PROCEDURE") or lp.isKeywordSplit("IMPORT") or lp.isKeywordSplit("INTENT") or lp.isKeywordSplit("OPTIONAL") or lp.isKeywordSplit("BIND");
}

pub fn parseDecl(lp: *LineParser, arena: std.mem.Allocator) !Decl {
    if (lp.isKeywordSplit("IMPORT")) {
        _ = lp.consumeKeyword("IMPORT");
        _ = declarators.consumeDoubleColon(lp);
        return .{ .import = .{ .names = try declarators.parseNameList(lp, arena) } };
    }
    if (lp.isKeywordSplit("INTENT")) {
        _ = lp.consumeKeyword("INTENT");
        _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
        const kind = if (lp.consumeKeyword("INOUT"))
            ast.IntentKind.inout
        else if (lp.consumeKeyword("OUT"))
            ast.IntentKind.out
        else if (lp.consumeKeyword("IN"))
            ast.IntentKind.in
        else
            return error.UnexpectedToken;
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        _ = declarators.consumeDoubleColon(lp);
        return .{ .intent = .{ .kind = kind, .names = try declarators.parseNameList(lp, arena) } };
    }
    if (lp.isKeywordSplit("OPTIONAL")) {
        _ = lp.consumeKeyword("OPTIONAL");
        _ = declarators.consumeDoubleColon(lp);
        return .{ .optional = .{ .names = try declarators.parseNameList(lp, arena) } };
    }
    if (lp.isKeywordSplit("IMPLICIT")) {
        _ = lp.consumeKeyword("IMPLICIT");
        if (lp.isKeywordSplit("NONE")) {
            _ = lp.consumeKeyword("NONE");
            return .{ .implicit = .{ .rules = try arena.alloc(ImplicitRule, 0) } };
        }
        var rules = std.array_list.Managed(ImplicitRule).init(arena);
        while (lp.peek()) |_| {
            const type_spec = try type_specs.parseImplicitTypeKind(lp, arena);
            _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
            while (!lp.peekIs(.r_paren)) {
                const start_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
                var end_char = std.ascii.toUpper(lp.tokenText(start_tok)[0]);
                if (lp.consume(.minus)) {
                    const end_tok = lp.expectIdentifier() orelse return error.UnexpectedToken;
                    end_char = std.ascii.toUpper(lp.tokenText(end_tok)[0]);
                }
                const start_char = std.ascii.toUpper(lp.tokenText(start_tok)[0]);
                try rules.append(.{
                    .start = start_char,
                    .end = end_char,
                    .type_kind = type_spec.type_kind,
                    .kind_selector = type_spec.kind_selector,
                    .char_len = type_spec.char_len,
                    .derived_type_name = type_spec.derived_type_name,
                    .polymorphic = type_spec.polymorphic,
                });
                _ = lp.consume(.comma);
            }
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            if (!lp.consume(.comma)) break;
        }
        return .{ .implicit = .{ .rules = try rules.toOwnedSlice() } };
    }
    if (lp.isKeywordSplit("DIMENSION")) {
        _ = lp.consumeKeyword("DIMENSION");
        _ = declarators.consumeDoubleColon(lp);
        return .{ .dimension = .{ .items = try declarators.parseDeclarators(lp, arena, .{}, null, false) } };
    }
    if (lp.isKeywordSplit("ALLOCATABLE")) {
        _ = lp.consumeKeyword("ALLOCATABLE");
        _ = declarators.consumeDoubleColon(lp);
        return .{ .dimension = .{ .items = try declarators.parseDeclarators(lp, arena, .{}, null, false), .allocatable = true } };
    }
    if (lp.isKeywordSplit("POINTER")) {
        _ = lp.consumeKeyword("POINTER");
        // Support legacy Cray pointer declaration syntax:
        //   POINTER(ptr, pointee)
        //   POINTER(ptr1, pointee1), (ptr2, pointee2)
        // We materialize pointer variables as INTEGER declarations so they are
        // visible under IMPLICIT NONE and later semantic/type checks.
        if (lp.peekIs(.l_paren)) {
            return .{ .type_decl = .{
                .type_kind = .integer,
                .items = try parseCrayPointerDeclarators(lp, arena),
            } };
        }
        _ = declarators.consumeDoubleColon(lp);
        return .{ .dimension = .{ .items = try declarators.parseDeclarators(lp, arena, .{}, null, true), .pointer = true } };
    }
    if (lp.isKeywordSplit("PARAMETER")) {
        _ = lp.consumeKeyword("PARAMETER");
        _ = lp.consume(.l_paren);
        var assigns = std.array_list.Managed(ParamAssign).init(arena);
        while (lp.peek()) |_| {
            const name = lp.readName(arena) orelse return error.MissingName;
            _ = lp.expect(.equals) orelse return error.UnexpectedToken;
            try assigns.append(.{ .name = name, .value = try expr.parseExpr(lp, arena, 0) });
            if (!lp.consume(.comma)) break;
        }
        _ = lp.consume(.r_paren);
        return .{ .parameter = .{ .assigns = try assigns.toOwnedSlice() } };
    }
    if (lp.isKeywordSplit("COMMON")) {
        _ = lp.consumeKeyword("COMMON");
        var blocks = std.array_list.Managed(CommonBlock).init(arena);
        var parsed_any = false;
        while (lp.peek()) |_| {
            var block_name: ?[]const u8 = null;
            if (lp.consume(.slash)) {
                if (!lp.peekIs(.slash)) block_name = lp.readName(arena) orelse return error.MissingName;
                _ = lp.expect(.slash) orelse return error.UnexpectedToken;
            }
            const items = try declarators.parseCommonDeclarators(lp, arena, null);
            if (items.len == 0) return error.MissingName;
            try blocks.append(.{ .name = block_name, .items = items });
            parsed_any = true;
            if (lp.peekIs(.slash) or lp.consume(.comma)) continue;
            break;
        }
        if (!parsed_any) return error.MissingName;
        return .{ .common = .{ .blocks = try blocks.toOwnedSlice() } };
    }
    if (lp.isKeywordSplit("EQUIVALENCE")) {
        _ = lp.consumeKeyword("EQUIVALENCE");
        var groups = std.array_list.Managed(EquivalenceGroup).init(arena);
        while (lp.consume(.l_paren)) {
            var items = std.array_list.Managed(*ast.Expr).init(arena);
            while (!lp.peekIs(.r_paren)) {
                try items.append(try expr.parseExpr(lp, arena, 0));
                _ = lp.consume(.comma);
            }
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            if (items.items.len < 2) return error.InvalidEquivalenceGroup;
            try groups.append(.{ .items = try items.toOwnedSlice() });
            if (!lp.consume(.comma)) break;
        }
        return .{ .equivalence = .{ .groups = try groups.toOwnedSlice() } };
    }
    if (lp.isKeywordSplit("EXTERNAL")) {
        _ = lp.consumeKeyword("EXTERNAL");
        _ = declarators.consumeDoubleColon(lp);
        return .{ .external = .{ .names = try declarators.parseNameList(lp, arena) } };
    }
    if (lp.isKeywordSplit("INTRINSIC")) {
        _ = lp.consumeKeyword("INTRINSIC");
        _ = declarators.consumeDoubleColon(lp);
        return .{ .intrinsic = .{ .names = try declarators.parseNameList(lp, arena) } };
    }
    if (lp.isKeywordSplit("SAVE")) {
        _ = lp.consumeKeyword("SAVE");
        _ = declarators.consumeDoubleColon(lp);
        var items = std.array_list.Managed(ast.SaveItem).init(arena);
        var save_all = true;
        while (lp.peek()) |_| {
            save_all = false;
            if (lp.consume(.comma)) continue;
            if (lp.consume(.slash)) {
                var block_name: ?[]const u8 = null;
                if (!lp.peekIs(.slash)) block_name = lp.readName(arena) orelse return error.MissingName;
                _ = lp.expect(.slash) orelse return error.UnexpectedToken;
                try items.append(.{ .common = block_name });
            } else {
                try items.append(.{ .name = lp.readName(arena) orelse return error.MissingName });
            }
            _ = lp.consume(.comma);
        }
        return .{ .save = .{ .items = try items.toOwnedSlice(), .save_all = save_all } };
    }
    if (lp.isKeywordSplit("PROCEDURE")) {
        _ = lp.consumeKeyword("PROCEDURE");
        const procedure_interface = try type_specs.parseProcedureInterface(lp, arena);
        const attrs = try declarators.consumeDeclAttributes(lp, arena);
        return .{ .procedure = .{
            .interface = procedure_interface,
            .items = try declarators.parseDeclarators(lp, arena, .{}, null, attrs.pointer),
            .pointer = attrs.pointer,
            .optional = attrs.optional,
            .save = attrs.save,
            .nopass = attrs.nopass,
            .pass_name = attrs.pass_name,
            .private = attrs.private,
        } };
    }
    if (lp.isKeywordSplit("BIND")) {
        _ = lp.consumeKeyword("BIND");
        const bind_info = try declarators.parseBindSpec(lp, arena);
        _ = declarators.consumeDoubleColon(lp);
        return .{ .bind_entity = .{
            .names = try declarators.parseNameList(lp, arena),
            .bind_name_expr = bind_info.bind_name_expr,
        } };
    }

    const type_spec = try type_specs.parseDeclTypeKind(lp, arena);
    var default_char_len: ParsedCharacterLen = .{ .expr = type_spec.char_len, .deferred = type_spec.char_len_deferred };
    if (type_spec.type_kind == .character and (lp.consume(.star) or lp.peekIs(.l_paren))) {
        default_char_len = try declarators.parseCharacterLenSpec(lp, arena);
    }
    const attrs = try declarators.consumeDeclAttributes(lp, arena);
    return .{ .type_decl = .{
        .type_kind = type_spec.type_kind,
        .kind_selector = type_spec.kind_selector,
        .derived_type_name = type_spec.derived_type_name,
        .polymorphic = type_spec.polymorphic,
        .assumed_type = type_spec.assumed_type,
        .items = try declarators.parseDeclarators(lp, arena, default_char_len, attrs.dimension, attrs.pointer),
        .parameter = attrs.parameter,
        .save = attrs.save,
        .allocatable = attrs.allocatable,
        .pointer = attrs.pointer,
        .optional = attrs.optional,
        .intent = attrs.intent,
        .external = attrs.external,
        .asynchronous = attrs.asynchronous,
        .contiguous = attrs.contiguous,
        .value_attr = attrs.value_attr,
        .volatile_attr = attrs.volatile_attr,
        .bind_c = attrs.bind_c,
        .bind_name_expr = attrs.bind_name_expr,
    } };
}

fn parseCrayPointerDeclarators(lp: *LineParser, arena: std.mem.Allocator) ![]ast.Declarator {
    var out = std.array_list.Managed(ast.Declarator).init(arena);
    while (true) {
        _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
        const pointer_name = lp.readName(arena) orelse return error.MissingName;
        try out.append(.{
            .name = pointer_name,
            .dims = &.{},
            .char_len = null,
        });
        _ = lp.expect(.comma) orelse return error.UnexpectedToken;

        // Pointee name is required, but pointee typing/shape is handled by the
        // regular declaration stream.
        _ = lp.readName(arena) orelse return error.MissingName;
        if (lp.peekIs(.l_paren)) try consumeBalancedParens(lp);

        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        if (!lp.consume(.comma)) break;
    }
    return out.toOwnedSlice();
}

fn consumeBalancedParens(lp: *LineParser) !void {
    _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
    var depth: usize = 1;
    while (depth > 0) {
        if (lp.consume(.l_paren)) {
            depth += 1;
            continue;
        }
        if (lp.consume(.r_paren)) {
            depth -= 1;
            continue;
        }
        _ = lp.peek() orelse return error.UnexpectedToken;
        _ = lp.next();
    }
}

pub fn tryParseAllocateTypeSpec(lp: *LineParser, arena: std.mem.Allocator) !?ast.AllocateTypeSpec {
    var lookahead = lp.*;
    const type_source: ast.SourceRef = .{
        .line = lookahead.line.span.start_line,
        .column = if (lookahead.index < lookahead.tokens.len) lookahead.tokens[lookahead.index].column else 1,
        .text = lookahead.line.text,
    };
    const type_spec = type_specs.parseAllocateTypeSpecHead(&lookahead, arena) catch |err| switch (err) {
        error.UnknownType => return null,
        else => return err,
    };
    var char_len: ParsedCharacterLen = .{ .expr = type_spec.char_len, .deferred = type_spec.char_len_deferred };
    if (type_spec.type_kind == .character and (lookahead.consume(.star) or lookahead.peekIs(.l_paren))) {
        char_len = try declarators.parseCharacterLenSpec(&lookahead, arena);
    }
    if (!declarators.consumeDoubleColon(&lookahead)) return null;
    lp.* = lookahead;
    return .{
        .type_kind = type_spec.type_kind,
        .kind_selector = type_spec.kind_selector,
        .derived_type_name = type_spec.derived_type_name,
        .polymorphic = type_spec.polymorphic,
        .char_len = char_len.expr,
        .char_len_deferred = char_len.deferred,
        .source = type_source,
        .legacy_star_kind = type_spec.legacy_star_kind,
        .invalid_bare_double = type_spec.invalid_bare_double,
    };
}

pub fn parseCharacterLenSpec(lp: *LineParser, arena: std.mem.Allocator) !ParsedCharacterLen {
    return declarators.parseCharacterLenSpec(lp, arena);
}

pub fn parseCharacterLen(lp: *LineParser, arena: std.mem.Allocator) !*ast.Expr {
    return declarators.parseCharacterLen(lp, arena);
}

pub fn parseLegacyStarSelectorExpr(lp: *LineParser, arena: std.mem.Allocator) !*ast.Expr {
    return declarators.parseLegacyStarSelectorExpr(lp, arena);
}

pub fn isDoublePrecisionTypeStart(lp: LineParser) bool {
    return type_specs.isDoublePrecisionTypeStart(lp);
}

pub fn isDoubleComplexTypeStart(lp: LineParser) bool {
    return type_specs.isDoubleComplexTypeStart(lp);
}

pub fn consumeDoublePrecisionType(lp: *LineParser) !bool {
    return type_specs.consumeDoublePrecisionType(lp);
}

pub fn consumeDoubleComplexType(lp: *LineParser) !bool {
    return type_specs.consumeDoubleComplexType(lp);
}

pub fn isDerivedTypeDeclStart(lp: LineParser) bool {
    return type_specs.isDerivedTypeDeclStart(lp);
}

test {
    _ = @import("tests.zig");
}
