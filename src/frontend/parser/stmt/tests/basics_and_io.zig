const common = @import("common.zig");
const std = common.std;
const ast = common.ast;
const catalog = common.catalog;
const fixed_form = common.fixed_form;
const free_form = common.free_form;
const lexer = common.lexer;
const array_info = common.array_info;
const parse_diag = common.parse_diag;
const control_flow = common.control_flow;
const api = common.api;
const if_stmt = common.if_stmt;
const associate_stmt = common.associate_stmt;
const select_case = common.select_case;
const select_type = common.select_type;
const action_stmt = common.action_stmt;
const control_flow_bridge = common.control_flow_bridge;
const DoContext = common.DoContext;
const parseStatement = common.parseStatement;
const parseIfBlock = common.parseIfBlock;
const parseStatementWithDiagnostics = common.parseStatementWithDiagnostics;
const parseIfBlockWithDiagnostics = common.parseIfBlockWithDiagnostics;
test "parseStatement parses assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A=1\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expect(stmt_node.node == .assignment);
}

test "parseStatement parses slash array constructor assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      X(:) = (/ 3, 1, 4, 1 /)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expect(stmt_node.node == .assignment);
    try testing.expect(stmt_node.node.assignment.value.* == .array_constructor);
    try testing.expectEqual(@as(usize, 4), stmt_node.node.assignment.value.array_constructor.items.len);
}

test "parseStatement parses pointer assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      X => Y\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expect(stmt_node.node == .pointer_assignment);
    try testing.expectEqualStrings("X", stmt_node.node.pointer_assignment.target.identifier);
    try testing.expectEqualStrings("Y", stmt_node.node.pointer_assignment.value.identifier);
}

test "parseStatement parses CALL keyword actual argument" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      CALL FOO(WORK=AUX)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expect(stmt_node.node == .call);
    try testing.expectEqualStrings("FOO", stmt_node.node.call.name);
    try testing.expectEqual(@as(usize, 1), stmt_node.node.call.args.len);
    try testing.expect(stmt_node.node.call.args[0] == .expr);
    try testing.expectEqualStrings("WORK", stmt_node.node.call.args[0].expr.keyword.?);
    try testing.expectEqualStrings("AUX", stmt_node.node.call.args[0].expr.value.identifier);
}

test "parseStatement parses ENTRY RESULT clause" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      ENTRY BIFAC(I,J) RESULT (RES)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expect(stmt_node.node == .entry);
    try testing.expectEqualStrings("BIFAC", stmt_node.node.entry.name);
    try testing.expectEqual(@as(usize, 2), stmt_node.node.entry.args.len);
    try testing.expectEqualStrings("I", stmt_node.node.entry.args[0]);
    try testing.expectEqualStrings("J", stmt_node.node.entry.args[1]);
    try testing.expectEqualStrings("RES", stmt_node.node.entry.result_name.?);
}

test "parseStatement treats split IFX name as assignment target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      I F X = 1\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expect(stmt_node.node == .assignment);
    try testing.expectEqualStrings("IFX", stmt_node.node.assignment.target.identifier);
}

test "parseStatementWithDiagnostics captures lexer errors in explicit bag" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      A=$\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    var lex_diag_bag = lexer.Bag.init(arena.allocator());
    defer lex_diag_bag.deinit();

    try testing.expectError(
        error.UnexpectedCharacter,
        parseStatementWithDiagnostics(
            arena.allocator(),
            lines,
            &idx,
            &do_ctx,
            &param_ints,
            &param_strings,
            &array_names,
            &diag_bag,
            &lex_diag_bag,
        ),
    );

    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expectEqualStrings(catalog.lexer.unexpected_character.code, diag.code);
    try testing.expectEqual(@as(usize, 1), diag.line);
}

test "parseStatement handles READ with UNIT equals star" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      READ (UNIT=*,FMT=1) A\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expect(stmt_node.node == .read);
    const read_stmt = stmt_node.node.read;
    try testing.expect(read_stmt.unit.* == .literal);
    try testing.expectEqual(ast.LiteralKind.integer, read_stmt.unit.literal.kind);
    try testing.expectEqualStrings("5", read_stmt.unit.literal.text);
    try testing.expect(read_stmt.format == .label);
    try testing.expectEqualStrings("1", read_stmt.format.label);
}

test "parseStatement handles WRITE with UNIT equals star" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      WRITE (UNIT=*,FMT=*) A\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expect(stmt_node.node == .write);
    const write_stmt = stmt_node.node.write;
    try testing.expect(write_stmt.unit.* == .literal);
    try testing.expectEqual(ast.LiteralKind.integer, write_stmt.unit.literal.kind);
    try testing.expectEqualStrings("6", write_stmt.unit.literal.text);
    try testing.expect(write_stmt.format == .list_directed);
}

test "parseStatement handles PRINT statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      PRINT 67,DTOT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expect(stmt_node.node == .write);
    const write_stmt = stmt_node.node.write;
    try testing.expect(write_stmt.unit.* == .literal);
    try testing.expectEqual(ast.LiteralKind.integer, write_stmt.unit.literal.kind);
    try testing.expectEqualStrings("6", write_stmt.unit.literal.text);
    try testing.expect(write_stmt.format == .label);
    try testing.expectEqualStrings("67", write_stmt.format.label);
    try testing.expectEqual(@as(usize, 1), write_stmt.args.len);
}

test "parseStatement handles PRINT with inline string format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      PRINT '(Z8)', A\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expect(stmt_node.node == .write);
    const write_stmt = stmt_node.node.write;
    try testing.expect(write_stmt.format == .inline_items);
    try testing.expect(write_stmt.format.inline_items.len > 0);
    try testing.expectEqual(@as(usize, 1), write_stmt.args.len);
}

test "parseStatement handles free-form lowercase PRINT with inline string format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "print '(z8)', a\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expect(stmt_node.node == .write);
    const write_stmt = stmt_node.node.write;
    try testing.expect(write_stmt.format == .inline_items);
    try testing.expect(write_stmt.format.inline_items.len > 0);
    try testing.expectEqual(@as(usize, 1), write_stmt.args.len);
}

test "parseStatement handles free-form PRINT list-directed without spaces" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "print *,x\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expect(stmt_node.node == .write);
    const write_stmt = stmt_node.node.write;
    try testing.expect(write_stmt.format == .list_directed);
    try testing.expectEqual(@as(usize, 1), write_stmt.args.len);
    try testing.expect(write_stmt.args[0].* == .identifier);
    try testing.expectEqualStrings("x", write_stmt.args[0].identifier);
}

test "lexer preserves free-form PRINT inline format and trailing comma as separate tokens" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "print '(z8)', a\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var diag_bag = parse_diag.Bag.init(allocator);
    defer diag_bag.deinit();
    var lex_diag_bag = lexer.Bag.init(allocator);
    defer lex_diag_bag.deinit();

    const tokens = try lexer.lexLogicalLineWithDiagnostics(allocator, lines[0], &lex_diag_bag);
    defer allocator.free(tokens);
    try testing.expect(tokens.len >= 4);
    try testing.expectEqual(lexer.TokenKind.identifier, tokens[0].kind);
    try testing.expectEqual(lexer.TokenKind.string, tokens[1].kind);
    try testing.expectEqual(lexer.TokenKind.comma, tokens[2].kind);
    try testing.expectEqual(lexer.TokenKind.identifier, tokens[3].kind);
}

test "parseStatementWithDiagnostics accepts free-form lowercase PRINT with radix inline format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "print '(z8)', a\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    var lex_diag_bag = lexer.Bag.init(arena.allocator());
    defer lex_diag_bag.deinit();

    const stmt_node = try parseStatementWithDiagnostics(
        arena.allocator(),
        lines,
        &idx,
        &do_ctx,
        &param_ints,
        &param_strings,
        &array_names,
        &diag_bag,
        &lex_diag_bag,
    );

    try testing.expect(stmt_node.node == .write);
    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expect(!diag_bag.has());
}

test "parseStatement handles labeled FORMAT statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "90007 FORMAT (\" \",20X,\"END OF PROGRAM FM045\" )\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expect(stmt_node.node == .format);
    try testing.expectEqualStrings("90007", stmt_node.label.?);
    try testing.expect(stmt_node.node.format.items.len > 0);
}

test "parseStatement parses USE ONLY statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      USE MINPACK_MODULE, ONLY: WP\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt_node.node == .use_stmt);
    try testing.expectEqualStrings("MINPACK_MODULE", stmt_node.node.use_stmt.module_name);
    try testing.expectEqual(@as(usize, 1), stmt_node.node.use_stmt.only_items.len);
    try testing.expectEqualStrings("WP", stmt_node.node.use_stmt.only_items[0].local_name);
    try testing.expectEqualStrings("WP", stmt_node.node.use_stmt.only_items[0].remote_name);
    try testing.expectEqual(@as(usize, 1), idx);
}

test "parseStatement rejects legacy USE rename marker" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      USE ISO_FORTRAN_ENV, ONLY: NWRITE =.GT. OUTPUT_UNIT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    try testing.expectError(error.UnexpectedToken, parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names));
}

test "parseStatement parses USE ONLY rename arrow token" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      USE ISO_FORTRAN_ENV, ONLY: NWRITE => OUTPUT_UNIT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt_node.node == .use_stmt);
    try testing.expectEqualStrings("ISO_FORTRAN_ENV", stmt_node.node.use_stmt.module_name);
    try testing.expect(stmt_node.node.use_stmt.has_only);
    try testing.expectEqual(@as(usize, 1), stmt_node.node.use_stmt.only_items.len);
    try testing.expectEqualStrings("NWRITE", stmt_node.node.use_stmt.only_items[0].local_name);
    try testing.expectEqualStrings("OUTPUT_UNIT", stmt_node.node.use_stmt.only_items[0].remote_name);
    try testing.expectEqual(@as(usize, 1), idx);
}

test "parseStatement parses USE rename list without ONLY" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      USE BAR_PRT, FOO_DPRT => BAR_DPRT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt_node.node == .use_stmt);
    try testing.expectEqualStrings("BAR_PRT", stmt_node.node.use_stmt.module_name);
    try testing.expect(!stmt_node.node.use_stmt.has_only);
    try testing.expectEqual(@as(usize, 1), stmt_node.node.use_stmt.only_items.len);
    try testing.expectEqualStrings("FOO_DPRT", stmt_node.node.use_stmt.only_items[0].local_name);
    try testing.expectEqualStrings("BAR_DPRT", stmt_node.node.use_stmt.only_items[0].remote_name);
}

test "parseStatement parses USE ONLY assignment generic spec" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      USE MOD1, ONLY: T_M, ASSIGNMENT(=)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt_node.node == .use_stmt);
    try testing.expectEqual(@as(usize, 2), stmt_node.node.use_stmt.only_items.len);
    try testing.expectEqualStrings("assignment(=)", stmt_node.node.use_stmt.only_items[1].local_name);
    try testing.expectEqualStrings("assignment(=)", stmt_node.node.use_stmt.only_items[1].remote_name);
    try testing.expect(stmt_node.node.use_stmt.only_items[1].generic_spec);
    try testing.expectEqualStrings("=", stmt_node.node.use_stmt.only_items[1].generic_display_name);
}

test "parseStatement parses USE ONLY operator generic spec" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      USE M_OS, ONLY: OPERATOR(.EQ.), OPERATOR(/=)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt_node.node == .use_stmt);
    try testing.expectEqual(@as(usize, 2), stmt_node.node.use_stmt.only_items.len);
    try testing.expectEqualStrings("operator(==)", stmt_node.node.use_stmt.only_items[0].remote_name);
    try testing.expectEqualStrings("operator(/=)", stmt_node.node.use_stmt.only_items[1].remote_name);
    try testing.expect(stmt_node.node.use_stmt.only_items[0].generic_spec);
    try testing.expectEqualStrings(".eq.", stmt_node.node.use_stmt.only_items[0].generic_display_name);
    try testing.expectEqualStrings("/=", stmt_node.node.use_stmt.only_items[1].generic_display_name);
}

test "parseStatement parses USE double-colon form" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      USE :: ISO_FORTRAN_ENV, ONLY: OUTPUT_UNIT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt_node = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt_node.node == .use_stmt);
    try testing.expectEqualStrings("ISO_FORTRAN_ENV", stmt_node.node.use_stmt.module_name);
    try testing.expectEqual(@as(usize, 1), stmt_node.node.use_stmt.only_items.len);
    try testing.expectEqualStrings("OUTPUT_UNIT", stmt_node.node.use_stmt.only_items[0].local_name);
    try testing.expectEqualStrings("OUTPUT_UNIT", stmt_node.node.use_stmt.only_items[0].remote_name);
    try testing.expectEqual(@as(usize, 1), idx);
}

test "parseIfBlock stops at ENDIF" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      A=1\n" ++
        "      ENDIF\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    const stmts = try parseIfBlock(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);

    try testing.expectEqual(@as(usize, 1), stmts.len);
    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expect(stmts[0].node == .assignment);
}

test "parseStatement preserves labeled END IF as pending continue" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      IF (A) THEN\n" ++
        "      A=1\n" ++
        " 0010 END IF\n" ++
        "      A=2\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt1 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt1.node == .if_block);
    try testing.expectEqual(@as(usize, 3), idx);

    const stmt2 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expectEqualStrings("0010", stmt2.label.?);
    try testing.expect(stmt2.node == .cont);
    try testing.expectEqual(@as(usize, 3), idx);

    const stmt3 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt3.node == .assignment);
    try testing.expectEqual(@as(usize, 4), idx);
}

test "parseStatement closes labeled DO when pending END IF continue shares terminator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      DO 10 I = 1, 5\n" ++
        "      IF (A .GT. 0) THEN\n" ++
        "      X = 1\n" ++
        " 0010 END IF\n" ++
        "      Y = 2\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt1 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt1.node == .do_loop);
    try testing.expectEqualStrings("10", stmt1.node.do_loop.end_label);
    try testing.expectEqual(@as(usize, 1), idx);

    const stmt2 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt2.node == .if_block);
    try testing.expectEqual(@as(usize, 4), idx);

    const stmt3 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt3.node == .cont);
    try testing.expectEqualStrings("0010", stmt3.label.?);
    try testing.expectEqual(@as(usize, 4), idx);
    try testing.expect(do_ctx.peekTopLoop() == null);

    const stmt4 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt4.node == .assignment);
    try testing.expectEqual(@as(usize, 5), idx);
}

test "parseStatement logical IF advances by one line and does not skip follower" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      IF (A .GT. 0) GOTO 10\n" ++
        "      X=1\n" ++
        " 0010 CONTINUE\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt1 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt1.node == .if_single);
    try testing.expectEqual(@as(usize, 1), idx);

    const stmt2 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt2.node == .assignment);
    try testing.expectEqual(@as(usize, 2), idx);

    const stmt3 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt3.node == .cont);
    try testing.expectEqualStrings("0010", stmt3.label.?);
    try testing.expectEqual(@as(usize, 3), idx);
}
