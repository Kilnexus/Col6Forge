const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../token_stream.zig");
const fixed_form = @import("../../fixed_form.zig");
const free_form = @import("../../free_form.zig");
const lexer = @import("../../lexer.zig");
const expr = @import("mod.zig");
const shared = @import("shared.zig");

const LineParser = context.LineParser;
const BinaryOp = ast.BinaryOp;
const parseExpr = expr.parseExpr;
const parseDimExpr = expr.parseDimExpr;
const max_expression_depth = shared.max_expression_depth;

test "parseExpr respects precedence" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      1+2*3\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .binary => |bin| {
            try testing.expectEqual(BinaryOp.add, bin.op);
            try testing.expect(bin.left.* == .literal);
            try testing.expect(bin.right.* == .binary);
            const right = bin.right.binary;
            try testing.expectEqual(BinaryOp.mul, right.op);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles EQV with lowest logical precedence" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      .TRUE..OR..FALSE..EQV..TRUE.\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .binary => |bin| {
            try testing.expectEqual(BinaryOp.eqv, bin.op);
            try testing.expect(bin.left.* == .binary);
            try testing.expectEqual(BinaryOp.or_, bin.left.binary.op);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles double-equals relational operator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A==B\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .binary => |bin| {
            try testing.expectEqual(BinaryOp.eq, bin.op);
            try testing.expect(bin.left.* == .identifier);
            try testing.expect(bin.right.* == .identifier);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles slash-equals relational operator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A/=B\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .binary => |bin| {
            try testing.expectEqual(BinaryOp.ne, bin.op);
            try testing.expect(bin.left.* == .identifier);
            try testing.expect(bin.right.* == .identifier);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles dim-range arguments in subscripts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A(1:N, 2:M)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .call_or_subscript => |call| {
            try testing.expectEqual(@as(usize, 2), call.args.len);
            try testing.expect(call.args[0].* == .dim_range);
            try testing.expect(call.args[1].* == .dim_range);
            try testing.expect(call.args[0].dim_range.stride == null);
            try testing.expect(call.args[1].dim_range.stride == null);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles dim-range triplet stride in subscripts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A(1:10:2)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .call_or_subscript => |call| {
            try testing.expectEqual(@as(usize, 1), call.args.len);
            try testing.expect(call.args[0].* == .dim_range);
            const range = call.args[0].dim_range;
            try testing.expect(range.lower != null);
            try testing.expect(range.stride != null);
            try testing.expect(range.stride.?.* == .literal);
            try testing.expectEqualStrings("2", range.stride.?.literal.text);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles omitted-lower triplet stride in subscripts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A(::1)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .call_or_subscript => |call| {
            try testing.expectEqual(@as(usize, 1), call.args.len);
            try testing.expect(call.args[0].* == .dim_range);
            const range = call.args[0].dim_range;
            try testing.expect(range.lower == null);
            try testing.expect(range.stride != null);
            try testing.expect(range.stride.?.* == .literal);
            try testing.expectEqualStrings("1", range.stride.?.literal.text);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr accepts keyword actual arguments in calls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      SIZE(A, KIND=BITS_KIND)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .call_or_subscript => |call| {
            try testing.expectEqualStrings("SIZE", call.name);
            try testing.expectEqual(@as(usize, 2), call.args.len);
            try testing.expect(call.args[1].* == .identifier);
            try testing.expectEqualStrings("BITS_KIND", call.args[1].identifier);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles array section followed by substring suffix" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      STR(:)(1:2)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .substring => |sub| {
            try testing.expectEqualStrings("STR", sub.name);
            try testing.expectEqual(@as(usize, 1), sub.args.len);
            try testing.expect(sub.args[0].* == .dim_range);
            try testing.expect(sub.start != null);
            try testing.expect(sub.end != null);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles array constructor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      W//[STR//W]\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .binary => |bin| {
            try testing.expectEqual(BinaryOp.concat, bin.op);
            try testing.expect(bin.right.* == .array_constructor);
            try testing.expectEqual(@as(usize, 1), bin.right.array_constructor.items.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles slash array constructor with complex literals" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      (/(1,0),(0,1)/)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expectEqual(@as(usize, 2), ctor.items.len);
            try testing.expect(ctor.items[0].* == .complex_literal);
            try testing.expect(ctor.items[1].* == .complex_literal);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles free-form slash array constructor with complex literals" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "(/(1,0),(0,1)/)\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expectEqual(@as(usize, 2), ctor.items.len);
            try testing.expect(ctor.items[0].* == .complex_literal);
            try testing.expect(ctor.items[1].* == .complex_literal);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles slash array constructor with keyword actual call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      (/ REAL(A = 1), 1. /)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expectEqual(@as(usize, 2), ctor.items.len);
            try testing.expect(ctor.items[0].* == .call_or_subscript);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles free-form slash array constructor with keyword actual call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "(/ REAL(A = 1), 1. /)\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expectEqual(@as(usize, 2), ctor.items.len);
            try testing.expect(ctor.items[0].* == .call_or_subscript);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles kind-prefixed string literal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      CK_\"123\"\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .literal => |lit| {
            try testing.expectEqual(ast.LiteralKind.string, lit.kind);
            try testing.expectEqualStrings("CK_\"123\"", lit.text);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles numeric kind-prefixed string literal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      4_\"ab\"\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .literal => |lit| {
            try testing.expectEqual(ast.LiteralKind.string, lit.kind);
            try testing.expectEqualStrings("4_\"ab\"", lit.text);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr preserves BOZ literal prefix" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      z'5e74'\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .literal => |lit| {
            try testing.expectEqual(ast.LiteralKind.string, lit.kind);
            try testing.expectEqualStrings("z'5e74'", lit.text);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles typed array constructor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      [CHARACTER(KIND=4) :: 4_\"ab\"]\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expect(ctor.type_spec != null);
            try testing.expectEqual(ast.TypeKind.character, ctor.type_spec.?.type_kind);
            try testing.expect(ctor.type_spec.?.kind_selector != null);
            try testing.expectEqual(@as(usize, 1), ctor.items.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles typed character array constructor len(expr) syntax" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "[character(len(a)) :: a, b]\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expect(ctor.type_spec != null);
            try testing.expectEqual(ast.TypeKind.character, ctor.type_spec.?.type_kind);
            try testing.expect(ctor.type_spec.?.kind_selector != null);
            try testing.expectEqual(@as(usize, 2), ctor.items.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles bare derived-type array constructor type spec" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      [T :: T()]\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expect(ctor.type_spec != null);
            try testing.expectEqual(ast.TypeKind.derived, ctor.type_spec.?.type_kind);
            try testing.expectEqualStrings("T", ctor.type_spec.?.derived_type_name.?);
            try testing.expectEqual(@as(usize, 1), ctor.items.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles slash array constructor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      (/ 3, 1, 4, 1 /)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expect(ctor.type_spec == null);
            try testing.expectEqual(@as(usize, 4), ctor.items.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles typed slash array constructor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      (/ INTEGER(KIND=4) :: HUGE(0_8) /)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expect(ctor.type_spec != null);
            try testing.expectEqual(ast.TypeKind.integer, ctor.type_spec.?.type_kind);
            try testing.expectEqual(@as(usize, 1), ctor.items.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles implied-do in slash array constructor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      (/ (I, I=1,DIM) /)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expectEqual(@as(usize, 1), ctor.items.len);
            try testing.expect(ctor.items[0].* == .implied_do);
            try testing.expectEqualStrings("I", ctor.items[0].implied_do.var_name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles implied-do in array constructor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      [(I,I=1,DIM)]\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .array_constructor => |ctor| {
            try testing.expectEqual(@as(usize, 1), ctor.items.len);
            try testing.expect(ctor.items[0].* == .implied_do);
            try testing.expectEqualStrings("I", ctor.items[0].implied_do.var_name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr handles deeply nested fixed-form grouping without implied-do blowup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var source = std.array_list.Managed(u8).init(allocator);
    defer source.deinit();

    const open_count: usize = 80;
    const chunk_width: usize = 30;
    var remaining_open = open_count;
    var first_line = true;

    while (remaining_open > 0) {
        try source.appendSlice(if (first_line) "      " else "     1");
        first_line = false;

        const chunk = @min(chunk_width, remaining_open);
        try source.appendNTimes('(', chunk);
        remaining_open -= chunk;

        if (remaining_open == 0) {
            try source.appendSlice("IVON01 / IVON02");
        }
        try source.append('\n');
    }

    var remaining_close = open_count;
    while (remaining_close > 0) {
        try source.appendSlice("     1");
        const chunk = @min(chunk_width, remaining_close);
        try source.appendNTimes(')', chunk);
        remaining_close -= chunk;
        try source.append('\n');
    }

    const lines = try fixed_form.normalizeFixedForm(allocator, source.items);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .binary => |bin| {
            try testing.expectEqual(BinaryOp.div, bin.op);
            try testing.expect(bin.left.* == .identifier);
            try testing.expect(bin.right.* == .identifier);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr gives add higher precedence than concat" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A+B//C\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .binary => |bin| {
            try testing.expectEqual(BinaryOp.concat, bin.op);
            try testing.expect(bin.left.* == .binary);
            try testing.expectEqual(BinaryOp.add, bin.left.binary.op);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr keeps concat lower than add on right-hand side" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A//B+C\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseExpr(&lp, arena.allocator(), 0);

    switch (node.*) {
        .binary => |bin| {
            try testing.expectEqual(BinaryOp.concat, bin.op);
            try testing.expect(bin.right.* == .binary);
            try testing.expectEqual(BinaryOp.add, bin.right.binary.op);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDimExpr handles assumed size" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      *\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseDimExpr(&lp, arena.allocator());

    switch (node.*) {
        .literal => |lit| {
            try testing.expectEqual(ast.LiteralKind.assumed_size, lit.kind);
            try testing.expectEqualStrings("*", lit.text);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDimExpr handles deferred shape colon" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      :\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const node = try parseDimExpr(&lp, arena.allocator());

    switch (node.*) {
        .dim_range => |range| {
            try testing.expect(range.lower == null);
            try testing.expect(range.upper.* == .literal);
            try testing.expectEqual(ast.LiteralKind.assumed_size, range.upper.literal.kind);
            try testing.expect(range.assumed_shape);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseExpr enforces recursion depth limit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nesting = max_expression_depth + 32;
    var source_buf = std.array_list.Managed(u8).init(allocator);
    defer source_buf.deinit();

    try source_buf.appendSlice("      ");
    for (0..nesting) |_| try source_buf.append('(');
    try source_buf.append('1');
    for (0..nesting) |_| try source_buf.append(')');
    try source_buf.append('\n');

    const lines = try fixed_form.normalizeFixedForm(allocator, source_buf.items);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expectError(error.ExpressionDepthExceeded, parseExpr(&lp, arena.allocator(), 0));
}

test "parseDimExpr enforces recursion depth limit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nesting = max_expression_depth + 32;
    var source_buf = std.array_list.Managed(u8).init(allocator);
    defer source_buf.deinit();

    try source_buf.appendSlice("      ");
    for (0..nesting) |_| try source_buf.append('(');
    try source_buf.append('1');
    for (0..nesting) |_| try source_buf.append(')');
    try source_buf.append('\n');

    const lines = try fixed_form.normalizeFixedForm(allocator, source_buf.items);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expectError(error.ExpressionDepthExceeded, parseDimExpr(&lp, arena.allocator()));
}
