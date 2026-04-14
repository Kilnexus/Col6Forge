const common = @import("common.zig");
const std = common.std;
const ast = common.ast;
const catalog = common.catalog;
const fixed_form = common.fixed_form;
const free_form = common.free_form;
const parse_diag = common.parse_diag;
const parser = common.parser;
const parseProgram = common.parseProgram;
const parseProgramWithDiagnostics = common.parseProgramWithDiagnostics;
test "parseProgram parses a basic subroutine" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE FOO(A)\n" ++
        "      INTEGER A\n" ++
        "      A=1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("FOO", unit.name);
    try testing.expectEqual(@as(usize, 1), unit.args.len);
    try testing.expectEqualStrings("A", unit.args[0]);
    try testing.expectEqual(@as(usize, 1), unit.decls.len);
    try testing.expectEqual(@as(usize, 1), unit.stmts.len);
}

test "parseProgram accepts alternate return dummies in subroutine header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE FOO(A,*,*)\n" ++
        "      INTEGER A\n" ++
        "      RETURN 1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("FOO", unit.name);
    try testing.expectEqual(@as(usize, 1), unit.args.len);
    try testing.expectEqualStrings("A", unit.args[0]);
    try testing.expectEqual(@as(usize, 2), unit.alt_return_dummy_count);
}

test "parseProgram preserves NO_ARG_CHECK on declarator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s(a)\n" ++
        "!GCC$ ATTRIBUTES NO_ARG_CHECK :: a\n" ++
        "integer :: a\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqual(@as(usize, 1), program.units[0].decls.len);
    try testing.expect(program.units[0].decls[0] == .type_decl);
    try testing.expect(program.units[0].decls[0].type_decl.items[0].no_arg_check);
}

test "parseProgram preserves NO_ARG_CHECK in assumed_type_5 actual file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/assumed_type_5.f90", 1024 * 1024);
    defer allocator.free(source);
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 3), program.units.len);
    try testing.expect(program.units[2].decls[1] == .type_decl);
    try testing.expect(program.units[2].decls[1].type_decl.items[0].no_arg_check);
}

test "parseProgram expands fixed-form ENTRY RESULT into sibling function units" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      RECURSIVE FUNCTION FAC(I) RESULT (RES)\n" ++
        "      INTEGER :: I, J, K, RES\n" ++
        "      K = 1\n" ++
        "      GOTO 100\n" ++
        "      ENTRY BIFAC(I,J) RESULT (RES)\n" ++
        "      K = J\n" ++
        " 100  CONTINUE\n" ++
        "      RES = 1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expectEqualStrings("FAC", program.units[0].name);
    try testing.expectEqualStrings("RES", program.units[0].result_name.?);
    try testing.expectEqualStrings("BIFAC", program.units[1].name);
    try testing.expectEqualStrings("RES", program.units[1].result_name.?);
    try testing.expectEqual(@as(usize, 2), program.units[1].args.len);
    try testing.expectEqualStrings("I", program.units[1].args[0]);
    try testing.expectEqualStrings("J", program.units[1].args[1]);
    try testing.expectEqual(@as(usize, 4), program.units[0].stmts.len);
    try testing.expect(program.units[0].stmts[0].node == .assignment);
    try testing.expect(program.units[0].stmts[1].node == .goto);
    try testing.expect(program.units[0].stmts[2].node == .cont);
    try testing.expectEqualStrings("100", program.units[0].stmts[2].label.?);
    try testing.expect(program.units[0].stmts[3].node == .assignment);
    try testing.expectEqual(@as(usize, 3), program.units[1].stmts.len);
    try testing.expect(program.units[1].stmts[0].node == .assignment);
    try testing.expect(program.units[1].stmts[1].node == .cont);
    try testing.expectEqualStrings("100", program.units[1].stmts[1].label.?);
    try testing.expect(program.units[1].stmts[2].node == .assignment);
}

test "parseProgram handles CONTAINS internal function blocks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE OUTER(X)\n" ++
        "      REAL X\n" ++
        "      X = SXVALS(X)\n" ++
        "      RETURN\n" ++
        "      CONTAINS\n" ++
        "      REAL FUNCTION SXVALS(XX)\n" ++
        "      REAL XX\n" ++
        "      SXVALS = XX\n" ++
        "      RETURN\n" ++
        "      END\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expectEqualStrings("OUTER", program.units[0].name);
    try testing.expectEqualStrings("SXVALS", program.units[1].name);
    try testing.expect(program.units[0].stmts[2].node == .cont);
    try testing.expectEqualStrings("OUTER", program.units[1].owner_name.?);
    try testing.expectEqual(ast.LexicalOwnerKind.procedure, program.units[1].owner_kind.?);
}

test "parseProgram skips END PROGRAM after internal procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM MAIN\n" ++
        "      CONTAINS\n" ++
        "      SUBROUTINE FCN()\n" ++
        "      RETURN\n" ++
        "      END SUBROUTINE FCN\n" ++
        "      END PROGRAM MAIN\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expectEqual(ast.ProgramUnitKind.program, program.units[0].kind);
    try testing.expectEqual(ast.ProgramUnitKind.subroutine, program.units[1].kind);
}

test "parseProgram clears pending host owner after bare END before external unit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  integer function ctest(i)\n" ++
        "    integer :: i\n" ++
        "    ctest = i\n" ++
        "  end function ctest\n" ++
        "end\n" ++
        "\n" ++
        "integer function test(i)\n" ++
        "  integer :: i\n" ++
        "  test = i\n" ++
        "end function test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 3), program.units.len);
    try testing.expectEqualStrings("P", program.units[0].name);
    try testing.expectEqualStrings("CTEST", program.units[1].name);
    try testing.expectEqualStrings("P", program.units[1].owner_name.?);
    try testing.expectEqualStrings("TEST", program.units[2].name);
    try testing.expect(program.units[2].owner_name == null);
    try testing.expect(program.units[2].owner_kind == null);
}

test "parseProgram accepts declarations inside BLOCK construct body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer :: i\n" ++
        "  i = 3\n" ++
        "  block\n" ++
        "    character(len=i), allocatable :: str1\n" ++
        "    allocate(character(len=3) :: str1)\n" ++
        "  end block\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expect(program.units[0].decls.len >= 2);
}

test "parseProgram prepends host declarations into implicit main internal procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module defs\n" ++
        "  type seq\n" ++
        "    character(len=9) :: ba(2)\n" ++
        "  end type seq\n" ++
        "end module defs\n" ++
        "use defs\n" ++
        "contains\n" ++
        "  subroutine inner(x)\n" ++
        "    type(seq) :: x\n" ++
        "  end subroutine inner\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 3), program.units.len);
    const inner = program.units[2];
    try testing.expectEqualStrings("INNER", inner.name);
    try testing.expectEqualStrings("__COL6FORGE_PROGRAM0", inner.owner_name.?);
    try testing.expectEqual(ast.LexicalOwnerKind.procedure, inner.owner_kind.?);

    var saw_use_defs = false;
    for (inner.stmts) |stmt_node| {
        if (stmt_node.node != .use_stmt) continue;
        if (!std.ascii.eqlIgnoreCase(stmt_node.node.use_stmt.module_name, "defs")) continue;
        saw_use_defs = true;
        break;
    }
    try testing.expect(saw_use_defs);

    var saw_seq_type = false;
    for (inner.decls) |decl_node| {
        if (decl_node != .derived_type_def) continue;
        if (!std.ascii.eqlIgnoreCase(decl_node.derived_type_def.name, "seq")) continue;
        saw_seq_type = true;
        break;
    }
    try testing.expect(saw_seq_type);
}

test "parseProgram imports visible derived types into fixed-form contained procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      MODULE o_TYPE_DEFS\n" ++
        "        implicit none\n" ++
        "        TYPE SEQ\n" ++
        "          SEQUENCE\n" ++
        "          CHARACTER(len = 9) ::  BA(2)\n" ++
        "        END TYPE SEQ\n" ++
        "      END MODULE o_TYPE_DEFS\n" ++
        "      MODULE TESTS\n" ++
        "        use o_type_defs\n" ++
        "      CONTAINS\n" ++
        "        SUBROUTINE OG0015(UDS0L)\n" ++
        "          TYPE(SEQ)          UDS0L\n" ++
        "        END SUBROUTINE\n" ++
        "      END MODULE TESTS\n" ++
        "      use o_type_defs\n" ++
        "      CONTAINS\n" ++
        "        SUBROUTINE OG0015_MAIN(UDS0L)\n" ++
        "          TYPE(SEQ)          UDS0L\n" ++
        "        END SUBROUTINE\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 5), program.units.len);
    for ([_]usize{ 2, 4 }) |unit_idx| {
        const unit = program.units[unit_idx];
        var saw_seq_type = false;
        for (unit.decls) |decl_node| {
            if (decl_node != .derived_type_def) continue;
            if (!std.ascii.eqlIgnoreCase(decl_node.derived_type_def.name, "seq")) continue;
            saw_seq_type = true;
            break;
        }
        try testing.expect(saw_seq_type);
    }
}

test "parseProgram continues after module ended by bare END in free form" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module my_module\n" ++
        "  implicit none\n" ++
        "  type, abstract, public :: a\n" ++
        "  end type\n" ++
        "end\n" ++
        "\n" ++
        "program main\n" ++
        "  use my_module\n" ++
        "  implicit none\n" ++
        "end program\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expectEqual(ast.ProgramUnitKind.module, program.units[0].kind);
    try testing.expectEqual(ast.ProgramUnitKind.program, program.units[1].kind);
    try testing.expectEqualStrings("my_module", program.units[0].name);
    try testing.expectEqualStrings("main", program.units[1].name);
}

test "parseProgram handles PURE REAL(kind) function header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PURE REAL(WP) FUNCTION ENORM(N, X)\n" ++
        "      INTEGER N\n" ++
        "      REAL X(N)\n" ++
        "      ENORM = 0.0\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("ENORM", unit.name);
    try testing.expect(unit.kind == .function);
    try testing.expectEqual(@as(usize, 2), unit.args.len);
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .type_decl);
    try testing.expectEqual(ast.TypeKind.real, unit.decls[0].type_decl.type_kind);
    try testing.expect(unit.decls[0].type_decl.kind_selector != null);
    switch (unit.decls[0].type_decl.kind_selector.?.*) {
        .identifier => |name| try testing.expectEqualStrings("WP", name),
        else => return error.UnexpectedToken,
    }
}

test "parseProgram handles COMPLEX(KIND=16) function header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      COMPLEX(KIND=16) FUNCTION ZF(X)\n" ++
        "      COMPLEX*16 X\n" ++
        "      ZF = X\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("ZF", unit.name);
    try testing.expect(unit.kind == .function);
    try testing.expect(unit.decls[0] == .type_decl);
    try testing.expectEqual(ast.TypeKind.complex, unit.decls[0].type_decl.type_kind);
    try testing.expect(unit.decls[0].type_decl.kind_selector != null);
    switch (unit.decls[0].type_decl.kind_selector.?.*) {
        .literal => |lit| try testing.expectEqualStrings("16", lit.text),
        else => return error.UnexpectedToken,
    }
}

test "parseProgram handles DOUBLEPRECISION function header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      DOUBLEPRECISION FUNCTION DF(X)\n" ++
        "      DOUBLEPRECISION X\n" ++
        "      DF = X\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("DF", unit.name);
    try testing.expect(unit.kind == .function);
    try testing.expect(unit.decls[0] == .type_decl);
    try testing.expectEqual(ast.TypeKind.double_precision, unit.decls[0].type_decl.type_kind);
    try testing.expectEqual(ast.TypeKind.double_precision, unit.decls[1].type_decl.type_kind);
}

test "parseProgram captures derived type definition and declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S()\n" ++
        "      TYPE A\n" ++
        "        INTEGER X\n" ++
        "      END TYPE A\n" ++
        "      TYPE(A), ALLOCATABLE :: B(:)\n" ++
        "      ALLOCATE(A :: B(1))\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("A", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .type_decl);
    try testing.expectEqual(ast.TypeKind.derived, unit.decls[1].type_decl.type_kind);
    try testing.expectEqualStrings("A", unit.decls[1].type_decl.derived_type_name.?);
}

test "parseProgram handles implicit main with TYPE double-colon and CLASS declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      TYPE :: REAL_TYPE\n" ++
        "      END TYPE\n" ++
        "      CLASS(REAL_TYPE), ALLOCATABLE :: OBJ\n" ++
        "      ALLOCATE(REAL_TYPE :: OBJ)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("REAL_TYPE", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .type_decl);
    try testing.expectEqual(ast.TypeKind.derived, unit.decls[1].type_decl.type_kind);
    try testing.expect(unit.decls[1].type_decl.polymorphic);
    try testing.expectEqualStrings("REAL_TYPE", unit.decls[1].type_decl.derived_type_name.?);
}

test "parseProgram handles derived type EXTENDS and ABSTRACT attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S()\n" ++
        "      TYPE :: T1\n" ++
        "      END TYPE\n" ++
        "      TYPE, EXTENDS(T1) :: T2\n" ++
        "      END TYPE\n" ++
        "      TYPE, ABSTRACT :: U0\n" ++
        "      END TYPE\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 3), unit.decls.len);
    try testing.expectEqualStrings("T1", unit.decls[0].derived_type_def.name);
    try testing.expectEqualStrings("T2", unit.decls[1].derived_type_def.name);
    try testing.expectEqualStrings("T1", unit.decls[1].derived_type_def.parent_name.?);
    try testing.expect(unit.decls[2].derived_type_def.abstract);
}

test "parseProgramWithDiagnostics reports duplicate ABSTRACT attribute in derived type header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type, abstract, extends(t), abstract :: err_t\n" ++
        "    integer :: x\n" ++
        "  end type err_t\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    try testing.expectError(error.DuplicateAbstractAttribute, parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag));
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    try testing.expect(std.mem.indexOf(u8, first.message, "Duplicate ABSTRACT attribute") != null);
}

test "parseProgram handles derived type PUBLIC attribute" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type, abstract, public :: t\n" ++
        "  end type t\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 1), unit.decls.len);
    try testing.expectEqualStrings("t", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[0].derived_type_def.abstract);
}

test "parseProgram handles derived type BIND(C) attribute" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type, bind(c) :: cstruct\n" ++
        "    integer :: i\n" ++
        "  end type cstruct\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 1), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("cstruct", unit.decls[0].derived_type_def.name);
}

test "parseProgram captures explicit RESULT variable name in function header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      FUNCTION DFLOAT(I) RESULT(F)\n" ++
        "      INTEGER I\n" ++
        "      REAL F\n" ++
        "      F = I\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expect(unit.kind == .function);
    try testing.expectEqualStrings("DFLOAT", unit.name);
    try testing.expect(unit.result_name != null);
    try testing.expectEqualStrings("F", unit.result_name.?);
}

test "parseProgram does not treat END BLOCK as unit terminator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE FOO()\n" ++
        "      A = 0\n" ++
        "      MAIN : BLOCK\n" ++
        "      A = 1\n" ++
        "      END BLOCK MAIN\n" ++
        "      A = 2\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("FOO", unit.name);
    try testing.expectEqual(@as(usize, 5), unit.stmts.len);
}

test "parseProgram flushes pending synthesized labels before END" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE FOO()\n" ++
        "      DO\n" ++
        "      EXIT\n" ++
        "      END DO\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 4), unit.stmts.len);
    try testing.expect(unit.stmts[2].node == .cont);
    try testing.expect(unit.stmts[3].node == .cont);
}

test "parseProgram supports implicit main program header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      IMPLICIT INTEGER(A-Z)\n" ++
        "      A=1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(ast.ProgramUnitKind.program, unit.kind);
    try testing.expect(std.mem.startsWith(u8, unit.name, "__COL6FORGE_PROGRAM"));
    try testing.expectEqual(@as(usize, 1), unit.decls.len);
    try testing.expectEqual(@as(usize, 1), unit.stmts.len);
}

test "parseProgram handles MODULE container with contained procedure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      MODULE MINPACK_MODULE\n" ++
        "      CONTAINS\n" ++
        "      SUBROUTINE FOO(X)\n" ++
        "      REAL X\n" ++
        "      X = 1.0\n" ++
        "      END\n" ++
        "      END MODULE MINPACK_MODULE\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expectEqual(ast.ProgramUnitKind.module, program.units[0].kind);
    try testing.expectEqualStrings("MINPACK_MODULE", program.units[0].name);
    try testing.expectEqualStrings("FOO", program.units[1].name);
    try testing.expectEqualStrings("MINPACK_MODULE", program.units[1].owner_name.?);
    try testing.expectEqual(ast.LexicalOwnerKind.module, program.units[1].owner_kind.?);
}

test "parseProgramWithDiagnostics recovers malformed BIND(C) procedure header inside module" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "contains\n" ++
        "  subroutine sub6() bind(c, name=\"         )\n" ++
        "  end subroutine sub6\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    const program = try parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag);
    try testing.expectEqual(@as(usize, 1), program.units.len);

    var saw_invalid = false;
    var saw_end_module = false;
    while (diag_bag.take()) |diag| {
        defer diag_bag.release(diag);
        if (std.mem.indexOf(u8, diag.message, "Invalid C identifier") != null) saw_invalid = true;
        if (std.mem.indexOf(u8, diag.message, "Expecting END MODULE statement") != null) saw_end_module = true;
    }
    try testing.expect(saw_invalid);
    try testing.expect(saw_end_module);
}

test "parseProgramWithDiagnostics accepts select type over parameterized class selector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module c1162a\n" ++
        "  type pdt(kind,len)\n" ++
        "    integer, kind :: kind\n" ++
        "    integer, len :: len\n" ++
        "  end type\n" ++
        " contains\n" ++
        "  subroutine foo(x)\n" ++
        "    class(pdt(kind = 1, len = :)), allocatable :: x\n" ++
        "    select type (x)\n" ++
        "      type is (pdt(kind = *, len = *)) ! { dg-error \"does not have a default value\" }\n" ++
        "      type is (pdt(kind = :, len = *)) ! { dg-error \"does not have a default value\" }\n" ++
        "    end select\n" ++
        "    select type (x)\n" ++
        "      type is (pdt(kind = 1, len = *)) ! This, of course, is OK\n" ++
        "    end select\n" ++
        "  end subroutine\n" ++
        "end module\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    const program = try parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag);
    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expect(diag_bag.take() == null);
}

