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
test "parseStatement preserves labeled ELSE as in-branch continue target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      IF (A .GT. 0) THEN\n" ++
        "      X=1\n" ++
        " 0010 ELSE\n" ++
        "      X=2\n" ++
        "      END IF\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt.node == .if_block);
    try testing.expectEqual(@as(usize, 5), idx);

    const else_stmts = stmt.node.if_block.else_stmts;
    try testing.expect(else_stmts.len >= 1);
    try testing.expect(else_stmts[0].node == .cont);
    try testing.expectEqualStrings("0010", else_stmts[0].label.?);
}

test "parseStatement preserves labeled ELSE IF as nested branch target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      IF (A .GT. 0) THEN\n" ++
        "      X=1\n" ++
        " 0010 ELSE IF (B .GT. 0) THEN\n" ++
        "      X=2\n" ++
        "      END IF\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt.node == .if_block);
    try testing.expectEqual(@as(usize, 5), idx);

    const else_stmts = stmt.node.if_block.else_stmts;
    try testing.expectEqual(@as(usize, 1), else_stmts.len);
    try testing.expect(else_stmts[0].node == .if_block);
    try testing.expectEqualStrings("0010", else_stmts[0].label.?);
}

test "parseStatement handles SELECT CASE and lowers to if_block chain" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SELECT CASE (MODE)\n" ++
        "      CASE (1, 3:5)\n" ++
        "      A=1\n" ++
        "      CASE DEFAULT\n" ++
        "      A=2\n" ++
        "      END SELECT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const parsed = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(parsed.node == .if_block);
    try testing.expectEqual(@as(usize, 6), idx);

    const root = parsed.node.if_block;
    try testing.expect(root.condition.* == .binary);
    try testing.expectEqual(ast.BinaryOp.or_, root.condition.binary.op);
    try testing.expectEqual(@as(usize, 1), root.then_stmts.len);
    try testing.expect(root.then_stmts[0].node == .assignment);
    try testing.expectEqual(@as(usize, 1), root.else_stmts.len);
    try testing.expect(root.else_stmts[0].node == .assignment);
}

test "parseStatement parses SELECT TYPE with associate-name selector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SELECT TYPE (Z => A%X)\n" ++
        "      TYPE IS (REAL)\n" ++
        "      A=1\n" ++
        "      END SELECT\n" ++
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
    try testing.expect(stmt1.node == .select_type_block);
    try testing.expectEqualStrings("Z", stmt1.node.select_type_block.associate_name.?);
    try testing.expectEqual(@as(usize, 1), stmt1.node.select_type_block.clauses.len);
    try testing.expectEqual(ast.SelectTypeClauseKind.type_is, stmt1.node.select_type_block.clauses[0].kind);
    try testing.expectEqual(ast.TypeKind.real, stmt1.node.select_type_block.clauses[0].type_kind.?);
    try testing.expectEqual(@as(usize, 1), stmt1.node.select_type_block.clauses[0].stmts.len);
    try testing.expect(stmt1.node.select_type_block.clauses[0].stmts[0].node == .assignment);
    try testing.expectEqual(@as(usize, 4), idx);

    const stmt2 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt2.node == .assignment);
    try testing.expectEqual(@as(usize, 5), idx);
}

test "parseStatement preserves SELECT TYPE construct name and clause trailing name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      LABEL: SELECT TYPE (A)\n" ++
        "      TYPE IS (REAL) LABEL\n" ++
        "      END SELECT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt.node == .select_type_block);
    try testing.expectEqualStrings("LABEL", stmt.node.select_type_block.construct_name.?);
    try testing.expectEqual(@as(usize, 1), stmt.node.select_type_block.clauses.len);
    try testing.expect(stmt.node.select_type_block.clauses[0].has_trailing_tokens);
    try testing.expectEqualStrings("LABEL", stmt.node.select_type_block.clauses[0].trailing_name.?);
}

test "parseStatement preserves SELECT TYPE CHARACTER clause kind and length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SELECT TYPE (Z => A%X)\n" ++
        "      TYPE IS (CHARACTER(KIND = 4, LEN = *))\n" ++
        "      A=1\n" ++
        "      END SELECT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt.node == .select_type_block);
    try testing.expectEqual(@as(usize, 1), stmt.node.select_type_block.clauses.len);
    const clause = stmt.node.select_type_block.clauses[0];
    try testing.expectEqual(ast.TypeKind.character, clause.type_kind.?);
    try testing.expect(clause.kind_selector != null);
    try testing.expect(clause.char_len != null);
    try testing.expect(!clause.char_len_deferred);
    try testing.expect(clause.kind_selector.?.* == .literal);
    try testing.expectEqual(ast.LiteralKind.integer, clause.kind_selector.?.literal.kind);
    try testing.expectEqualStrings("4", clause.kind_selector.?.literal.text);
    try testing.expect(clause.char_len.?.* == .literal);
    try testing.expectEqual(ast.LiteralKind.assumed_size, clause.char_len.?.literal.kind);
}

test "parseStatement preserves labeled END SELECT as pending continue" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SELECT CASE (I)\n" ++
        "      CASE (1)\n" ++
        "      A=1\n" ++
        " 0010 END SELECT\n" ++
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
    try testing.expectEqual(@as(usize, 4), idx);

    const stmt2 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expectEqualStrings("0010", stmt2.label.?);
    try testing.expect(stmt2.node == .cont);
    try testing.expectEqual(@as(usize, 4), idx);

    const stmt3 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt3.node == .assignment);
    try testing.expectEqual(@as(usize, 5), idx);
}

test "parseStatement allows empty SELECT CASE and lowers to cont" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SELECT CASE (I)\n" ++
        "      END SELECT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt.node == .cont);
    try testing.expectEqual(@as(usize, 2), idx);
}

test "parseStatement preserves labeled CASE as in-branch continue target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SELECT CASE (I)\n" ++
        " 0010 CASE (1)\n" ++
        "      A=1\n" ++
        "      END SELECT\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt.node == .if_block);
    try testing.expectEqual(@as(usize, 4), idx);
    const then_stmts = stmt.node.if_block.then_stmts;
    try testing.expectEqual(@as(usize, 2), then_stmts.len);
    try testing.expectEqualStrings("0010", then_stmts[0].label.?);
    try testing.expect(then_stmts[0].node == .cont);
    try testing.expect(then_stmts[1].node == .assignment);
}

test "parseStatement hoists non-trivial SELECT CASE selector into temp assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SELECT CASE (NEXT())\n" ++
        "      CASE (1)\n" ++
        "      A=1\n" ++
        "      CASE DEFAULT\n" ++
        "      A=2\n" ++
        "      END SELECT\n" ++
        "      A=3\n";
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
    try testing.expect(stmt1.node == .assignment);
    try testing.expect(stmt1.node.assignment.target.* == .identifier);
    try testing.expect(std.mem.startsWith(u8, stmt1.node.assignment.target.identifier, "__cf_select_case_sel_"));
    try testing.expect(stmt1.node.assignment.value.* == .call_or_subscript);
    try testing.expectEqual(@as(usize, 6), idx);

    const stmt2 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt2.node == .if_block);
    try testing.expectEqual(@as(usize, 6), idx);

    const stmt3 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt3.node == .assignment);
    try testing.expectEqual(@as(usize, 7), idx);
}

test "parseStatementWithDiagnostics rejects array SELECT CASE selector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "select case(a)\n" ++
        "case (0)\n" ++
        "end select\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    try array_names.put("a", .{ .size = 4, .rank = 1, .lower = 1 });
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    var lex_diag_bag = lexer.Bag.init(arena.allocator());
    defer lex_diag_bag.deinit();

    _ = try parseStatementWithDiagnostics(
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

    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expect(std.mem.indexOf(u8, diag.message, "must be a scalar expression") != null);
}

test "parseStatementWithDiagnostics rejects overlapping SELECT CASE ranges" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "select case(i)\n" ++
        "case (20:30)\n" ++
        "case (25:)\n" ++
        "end select\n";
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

    _ = try parseStatementWithDiagnostics(
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

    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expect(std.mem.indexOf(u8, diag.message, "overlaps with CASE") != null);
}

test "parseStatementWithDiagnostics rejects out-of-range integer CASE selector value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "select case(i)\n" ++
        "case (129)\n" ++
        "end select\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());
    try array_names.put("i", .{ .size = null, .rank = 0, .type_kind = .integer, .kind_value = 1, .lower = null });
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    var lex_diag_bag = lexer.Bag.init(arena.allocator());
    defer lex_diag_bag.deinit();

    _ = try parseStatementWithDiagnostics(
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

    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expect(std.mem.indexOf(u8, diag.message, "Syntax error in CASE specification") != null);
}

test "parseStatement handles block DO with END DO" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      DO I = 1, 3\n" ++
        "      A = A + I\n" ++
        "      END DO\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const do_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(do_stmt.node == .do_loop);
    try testing.expectEqual(@as(usize, 1), idx);

    const body_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(body_stmt.node == .assignment);
    try testing.expectEqual(@as(usize, 2), idx);

    const end_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(end_stmt.node == .cont);
    try testing.expect(end_stmt.label != null);
    try testing.expectEqual(@as(usize, 3), idx);
}

test "parseStatement handles DO WHILE with ENDDO" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      DO WHILE (I .LT. 3)\n" ++
        "      I = I + 1\n" ++
        "      ENDDO\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const do_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(do_stmt.node == .do_while);
    try testing.expectEqual(@as(usize, 1), idx);

    const body_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(body_stmt.node == .assignment);
    try testing.expectEqual(@as(usize, 2), idx);

    const end_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(end_stmt.node == .cont);
    try testing.expect(end_stmt.label != null);
    try testing.expectEqual(@as(usize, 3), idx);
}

test "parseStatement rejects END DO when innermost construct is BLOCK" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      DO\n" ++
        "      BLOCK\n" ++
        "      END DO\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    _ = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    _ = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expectError(
        error.EndDoWithoutDo,
        parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names),
    );
}

test "parseStatement rejects END BLOCK when innermost construct is DO" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      BLOCK\n" ++
        "      DO\n" ++
        "      END BLOCK\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    _ = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    _ = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expectError(
        error.UnexpectedToken,
        parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names),
    );
}

test "parseStatement keeps ambiguous DO assignment as assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      DO 10 I = 1.10\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt.node == .assignment);
    try testing.expect(stmt.node.assignment.target.* == .identifier);
    try testing.expectEqualStrings("DO10I", stmt.node.assignment.target.identifier);
}

test "parseStatement handles named BLOCK construct lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      MAIN : BLOCK\n" ++
        "      A=1\n" ++
        "      END BLOCK MAIN\n";
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
    try testing.expect(stmt1.node == .cont);
    try testing.expectEqual(@as(usize, 1), idx);

    const stmt2 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt2.node == .assignment);
    try testing.expectEqual(@as(usize, 2), idx);

    const stmt3 = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(stmt3.node == .cont);
    try testing.expectEqual(@as(usize, 3), idx);
}

test "parseStatement maps EXIT MAIN to goto end-block label" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      MAIN : BLOCK\n" ++
        "      IF (A .LT. 0) EXIT MAIN\n" ++
        "      END BLOCK MAIN\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    _ = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    const exit_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(exit_stmt.node == .if_single);
    try testing.expect(exit_stmt.node.if_single.stmt.* == .goto);
    try testing.expectEqualStrings("ENDBLOCK0", exit_stmt.node.if_single.stmt.goto.label);

    const end_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(end_stmt.node == .cont);
    try testing.expectEqualStrings("ENDBLOCK0", end_stmt.label.?);
}

test "parseStatement handles free-form assignment with slash array constructor keyword call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "vec = (/ real(a = 1), 1. /)\n";
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
    try testing.expect(stmt_node.node == .assignment);
    try testing.expect(stmt_node.node.assignment.value.* == .array_constructor);
}

test "parseStatementWithDiagnostics clears speculative parse errors for slash array constructor keyword call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "vec = (/ real(a = 1), 1. /)\n";
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
    try testing.expect(stmt_node.node == .assignment);
    try testing.expect(stmt_node.node.assignment.value.* == .array_constructor);
    try testing.expect(!diag_bag.has());
}

test "parseStatement maps EXIT INNER in named DO construct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      INNER : DO\n" ++
        "      IF (A .GT. 0) EXIT INNER\n" ++
        "      END DO INNER\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const do_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(do_stmt.node == .do_infinite);
    try testing.expectEqualStrings("ENDDO0", do_stmt.node.do_infinite.end_label);

    const exit_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(exit_stmt.node == .if_single);
    try testing.expect(exit_stmt.node.if_single.stmt.* == .goto);
    try testing.expectEqualStrings("EXITDO1", exit_stmt.node.if_single.stmt.goto.label);

    const end_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(end_stmt.node == .cont);
    try testing.expectEqualStrings("ENDDO0", end_stmt.label.?);
}

test "parseStatement maps bare EXIT to innermost DO end label" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      DO\n" ++
        "      EXIT\n" ++
        "      END DO\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const do_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(do_stmt.node == .do_infinite);
    const exit_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(exit_stmt.node == .goto);
    try testing.expectEqualStrings("EXITDO1", exit_stmt.node.goto.label);
}

test "parseStatement maps EXIT in labeled DO to loop exit label" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      DO 10 I = 1, 3\n" ++
        "      IF (I .EQ. 2) EXIT\n" ++
        "   10 CONTINUE\n" ++
        "      X = 1\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var do_ctx = DoContext.init(arena.allocator());
    var param_ints = std.StringHashMap(i64).init(arena.allocator());
    var param_strings = std.StringHashMap(ast.Literal).init(arena.allocator());
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(arena.allocator());

    const do_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(do_stmt.node == .do_loop);
    try testing.expectEqualStrings("10", do_stmt.node.do_loop.end_label);

    const exit_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(exit_stmt.node == .if_single);
    try testing.expect(exit_stmt.node.if_single.stmt.* == .goto);
    try testing.expectEqualStrings("EXITDO0", exit_stmt.node.if_single.stmt.goto.label);

    const end_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(end_stmt.node == .cont);
    try testing.expectEqualStrings("10", end_stmt.label.?);

    const exit_join = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(exit_join.node == .cont);
    try testing.expectEqualStrings("EXITDO0", exit_join.label.?);

    const after_stmt = try parseStatement(arena.allocator(), lines, &idx, &do_ctx, &param_ints, &param_strings, &array_names);
    try testing.expect(after_stmt.node == .assignment);
}

test "parseStatement preserves SELECT RANK clause metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SELECT RANK (X)\n" ++
        "      RANK (2)\n" ++
        "      PRINT *, X\n" ++
        "      RANK DEFAULT\n" ++
        "      PRINT *, X\n" ++
        "      END SELECT\n";
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
    try testing.expect(stmt_node.node == .associate_block);
    const select_rank = stmt_node.node.associate_block.select_rank orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 2), select_rank.clauses.len);
    try testing.expect(select_rank.clauses[0].kind == .rank_value);
    try testing.expect(select_rank.clauses[0].rank_expr != null);
    try testing.expect(select_rank.clauses[1].kind == .rank_default);
}

