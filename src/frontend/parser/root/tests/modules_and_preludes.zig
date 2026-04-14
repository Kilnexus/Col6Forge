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
test "parseProgram captures BIND(C) procedure name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE FOO() BIND(C, NAME=\"bar\")\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqualStrings("FOO", program.units[0].name);
    try testing.expectEqualStrings("bar", program.units[0].bind_name.?);
}

test "parseProgram prepends supported module declarations to contained procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      MODULE M\n" ++
        "      REAL, PARAMETER :: EPS = 1.0\n" ++
        "      CONTAINS\n" ++
        "      SUBROUTINE FOO()\n" ++
        "      A = EPS\n" ++
        "      END\n" ++
        "      END MODULE M\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("FOO", unit.name);
    try testing.expectEqual(@as(usize, 1), unit.decls.len);
    try testing.expect(unit.decls[0] == .parameter);
}

test "parseProgram keeps split PROGRAMX assignment in implicit main" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      P R O G R A M X = 1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqual(@as(usize, 1), program.units[0].stmts.len);
    try testing.expect(program.units[0].stmts[0].node == .assignment);
    try testing.expectEqualStrings("PROGRAMX", program.units[0].stmts[0].node.assignment.target.identifier);
}

test "parseProgram keeps declarations after USE in specification part" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      USE ISO_FORTRAN_ENV, ONLY: OUTPUT_UNIT\n" ++
        "      INTEGER X\n" ++
        "      X = 1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqual(@as(usize, 1), program.units[0].decls.len);
    try testing.expect(program.units[0].decls[0] == .type_decl);
    try testing.expectEqual(@as(usize, 2), program.units[0].stmts.len);
    try testing.expect(program.units[0].stmts[0].node == .use_stmt);
    try testing.expect(program.units[0].stmts[1].node == .assignment);
}

test "parseProgram preserves module specification-part USE imports separately" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module a\n" ++
        "end module a\n" ++
        "module b\n" ++
        "  use a\n" ++
        "end module b\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expectEqualStrings("b", program.units[1].name);
    try testing.expectEqual(@as(usize, 1), program.units[1].use_imports.len);
    try testing.expectEqualStrings("a", program.units[1].use_imports[0].module_name);
}

test "parseProgram preserves implicit-main bind(c) interface character result declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none\n" ++
        "  interface\n" ++
        "    function my() bind(C,name=\"my\") result(r)\n" ++
        "      use iso_c_binding\n" ++
        "      character(kind=C_CHAR) :: r(10)\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    const program = try parseProgram(allocator, lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[1] == .interface_block);
    try testing.expectEqual(@as(usize, 1), unit.decls[1].interface_block.procedure_headers.len);

    const proc = unit.decls[1].interface_block.procedure_headers[0];
    try testing.expect(proc.bind_c);
    try testing.expectEqualStrings("my", proc.bind_name.?);
    try testing.expect(proc.result_name != null);
    try testing.expectEqualStrings("r", proc.result_name.?);
    try testing.expectEqual(@as(usize, 1), proc.decls.len);
    try testing.expect(proc.decls[0] == .type_decl);
    try testing.expectEqual(@as(usize, 1), proc.decls[0].type_decl.items.len);
    try testing.expectEqualStrings("r", proc.decls[0].type_decl.items[0].name);
    try testing.expectEqual(@as(usize, 1), proc.decls[0].type_decl.items[0].dims.len);
}

test "parseProgram keeps split TYPEI assignment after execution begins" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      INTEGER X\n" ++
        "      X = 1\n" ++
        "      TYPE I = 63.\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqual(@as(usize, 1), program.units[0].decls.len);
    try testing.expectEqual(@as(usize, 2), program.units[0].stmts.len);
    try testing.expect(program.units[0].stmts[1].node == .assignment);
    try testing.expectEqualStrings("TYPEI", program.units[0].stmts[1].node.assignment.target.identifier);
}

test "parseProgram handles free-form slash array constructor assignment in subroutine body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine foo(x)\n" ++
        "  integer :: x(4)\n" ++
        "  x(:) = (/ 3, 1, 4, 1 /)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqual(@as(usize, 1), program.units[0].stmts.len);
    try testing.expect(program.units[0].stmts[0].node == .assignment);
    try testing.expect(program.units[0].stmts[0].node.assignment.value.* == .array_constructor);
}

test "parseProgramWithDiagnostics handles free-form slash array constructor assignment in subroutine body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine foo(x)\n" ++
        "  integer :: x(4)\n" ++
        "  x(:) = (/ 3, 1, 4, 1 /)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    const program = try parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqual(@as(usize, 1), program.units[0].stmts.len);
    try testing.expect(program.units[0].stmts[0].node == .assignment);
    try testing.expect(program.units[0].stmts[0].node.assignment.value.* == .array_constructor);
    try testing.expect(!diag_bag.has());
}

test "parseProgramWithDiagnostics accepts repository array_constructor_14 file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = try std.fs.cwd().readFileAlloc(
        allocator,
        "tests/gcc-tests/gfortran.dg/array_constructor_14.f90",
        1024 * 1024,
    );
    defer allocator.free(source);

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    const program = try parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expect(program.units[0].stmts[0].node == .assignment);
    try testing.expect(program.units[0].stmts[0].node.assignment.value.* == .array_constructor);
    try testing.expect(program.units[1].stmts[0].node == .assignment);
    try testing.expect(program.units[1].stmts[0].node.assignment.value.* == .array_constructor);
    try testing.expect(!diag_bag.has());
}

test "parseProgram reports continued declaration parse errors on the real source line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      INTEGER A,\n" ++
        "     1 )\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    try testing.expectError(error.UnexpectedToken, parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag));
    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectEqual(@as(usize, 8), diag.column);
    try testing.expectEqualStrings(catalog.parser.unexpected_token.code, diag.code);
}

test "parseProgram reports continued IF parse errors on the real source line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      IF (A .EQ.\n" ++
        "     1 ) THEN\n" ++
        "      END IF\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    try testing.expectError(error.UnexpectedToken, parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag));
    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectEqual(@as(usize, 8), diag.column);
    try testing.expectEqualStrings(catalog.parser.unexpected_token.code, diag.code);
}

test "parseProgram reports free-form continued declaration parse errors on the real source line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "integer :: a, &\n" ++
        "  )\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    try testing.expectError(error.UnexpectedToken, parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag));
    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectEqual(@as(usize, 3), diag.column);
    try testing.expectEqualStrings(catalog.parser.unexpected_token.code, diag.code);
}

test "parseProgram handles free-form implicit main with derived type and class allocate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "type :: real_type\n" ++
        "end type\n" ++
        "class(real_type), allocatable :: obj\n" ++
        "real(8), allocatable :: r8\n" ++
        "allocate(real_type :: obj)\n" ++
        "allocate(real(kind=8) :: r8)\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 3), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("real_type", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .type_decl);
    try testing.expect(unit.decls[1].type_decl.polymorphic);
    try testing.expectEqualStrings("real_type", unit.decls[1].type_decl.derived_type_name.?);
}

test "parseProgram handles interface blocks inside procedure bodies" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "contains\n" ++
        "  subroutine s1(f1)\n" ++
        "    interface\n" ++
        "      function f1(i)\n" ++
        "      end function f1\n" ++
        "    end interface\n" ++
        "  end subroutine s1\n" ++
        "end module m1\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("s1", unit.name);
    try testing.expectEqual(@as(usize, 1), unit.decls.len);
    try testing.expect(unit.decls[0] == .interface_block);
    try testing.expectEqual(@as(usize, 1), unit.decls[0].interface_block.procedures.len);
    try testing.expectEqualStrings("f1", unit.decls[0].interface_block.procedures[0]);
}

test "parseProgram handles interface CHARACTER(*,kind) declarations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine h4\n" ++
        "  interface\n" ++
        "    subroutine f4(a, b)\n" ++
        "      integer :: a\n" ++
        "      character(*,4) :: b\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "end subroutine h4\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const interface_block = program.units[0].decls[0].interface_block;
    try testing.expectEqual(@as(usize, 1), interface_block.procedure_headers.len);
    const proc_header = interface_block.procedure_headers[0];
    try testing.expectEqual(@as(usize, 2), proc_header.decls.len);
    try testing.expectEqual(ast.Decl, @TypeOf(proc_header.decls[1]));
    try testing.expect(proc_header.decls[1] == .type_decl);
    try testing.expectEqual(ast.TypeKind.character, proc_header.decls[1].type_decl.type_kind);
    try testing.expect(proc_header.decls[1].type_decl.kind_selector != null);
    switch (proc_header.decls[1].type_decl.kind_selector.?.*) {
        .literal => |lit| try testing.expectEqualStrings("4", lit.text),
        else => return error.UnexpectedToken,
    }
    switch (proc_header.decls[1].type_decl.items[0].char_len.?.*) {
        .literal => |lit| try testing.expectEqual(ast.LiteralKind.assumed_size, lit.kind),
        else => return error.UnexpectedToken,
    }
}

test "parseProgram preserves module interface blocks in contained procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  interface\n" ++
        "    subroutine foo(x)\n" ++
        "    end subroutine foo\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine bar()\n" ++
        "  end subroutine bar\n" ++
        "end module m1\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("bar", unit.name);
    try testing.expectEqual(@as(usize, 1), unit.decls.len);
    try testing.expect(unit.decls[0] == .interface_block);
}

test "parseProgram imports used module preludes into later module preludes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  type t1\n" ++
        "    integer :: value\n" ++
        "  end type t1\n" ++
        "end module m1\n" ++
        "module m2\n" ++
        "  use m1\n" ++
        "  type t2\n" ++
        "    type(t1) :: base\n" ++
        "  end type t2\n" ++
        "contains\n" ++
        "  subroutine s(x)\n" ++
        "    type(t2), intent(in) :: x\n" ++
        "  end subroutine s\n" ++
        "end module m2\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("s", unit.name);
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("t1", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .derived_type_def);
    try testing.expectEqualStrings("t2", unit.decls[1].derived_type_def.name);
}

test "parseProgram captures generic interface module procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  interface x_\n" ++
        "    module procedure get_x\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  function get_x()\n" ++
        "    integer :: get_x\n" ++
        "    get_x = 1\n" ++
        "  end function get_x\n" ++
        "end module m1\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 1), unit.decls.len);
    const interface_block = unit.decls[0].interface_block;
    try testing.expectEqualStrings("x_", interface_block.name.?);
    try testing.expectEqual(@as(usize, 1), interface_block.module_procedures.len);
    try testing.expectEqualStrings("get_x", interface_block.module_procedures[0]);
}

test "parseProgram captures assignment interface generic name and module procedure double-colon" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  interface assignment (=)\n" ++
        "    module procedure :: assign_m\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine assign_m()\n" ++
        "  end subroutine assign_m\n" ++
        "end module m1\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const interface_block = program.units[0].decls[0].interface_block;
    try testing.expectEqualStrings("assignment(=)", interface_block.name.?);
    try testing.expectEqual(@as(usize, 1), interface_block.module_procedures.len);
    try testing.expectEqualStrings("assign_m", interface_block.module_procedures[0]);
}

test "parseProgram recognizes pure module subroutine headers in interface bodies" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  interface assign\n" ++
        "    pure module subroutine assign_m(x)\n" ++
        "    end subroutine assign_m\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  pure module subroutine assign_m(x)\n" ++
        "    integer :: x\n" ++
        "  end subroutine assign_m\n" ++
        "end module m1\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const interface_block = program.units[0].decls[0].interface_block;
    try testing.expectEqual(@as(usize, 1), interface_block.procedures.len);
    try testing.expectEqualStrings("assign_m", interface_block.procedures[0]);
    try testing.expectEqual(@as(usize, 1), interface_block.procedure_headers.len);
    try testing.expectEqual(ast.ProgramUnitKind.subroutine, interface_block.procedure_headers[0].kind);
    try testing.expectEqualStrings("assign_m", interface_block.procedure_headers[0].name);
    try testing.expect(program.units[0].is_module_procedure);
}

test "parseProgram records PROCEDURE declarations in generic interface bodies" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  interface assignment(=)\n" ++
        "    procedure op_assign_vs_ch\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine op_assign_vs_ch(var, exp)\n" ++
        "    integer :: var\n" ++
        "    character(len=*), intent(in) :: exp\n" ++
        "  end subroutine op_assign_vs_ch\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    const interface_block = program.units[0].decls[0].interface_block;
    try testing.expectEqualStrings("assignment(=)", interface_block.name.?);
    try testing.expectEqual(@as(usize, 1), interface_block.specific_procedures.len);
    try testing.expectEqualStrings("op_assign_vs_ch", interface_block.specific_procedures[0]);
    try testing.expectEqual(@as(usize, 0), interface_block.procedure_headers.len);
}

test "parseProgram imports module prelude from module without contains" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module kinds\n" ++
        "  type foo\n" ++
        "    integer :: i\n" ++
        "  end type foo\n" ++
        "end module kinds\n" ++
        "type(foo) function ext_fun()\n" ++
        "  use kinds\n" ++
        "end function ext_fun\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("ext_fun", unit.name);
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("foo", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .type_decl);
}

test "parseProgram imports renamed ONLY items into module preludes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  type t1\n" ++
        "    integer :: value\n" ++
        "  end type t1\n" ++
        "  interface g\n" ++
        "    module procedure f\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine f(x)\n" ++
        "    type(t1), intent(in) :: x\n" ++
        "  end subroutine f\n" ++
        "end module m1\n" ++
        "module m2\n" ++
        "  use m1, only : u1 => t1, h => g\n" ++
        "contains\n" ++
        "  subroutine s(x)\n" ++
        "    type(u1), intent(in) :: x\n" ++
        "  end subroutine s\n" ++
        "end module m2\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    const unit = program.units[1];
    try testing.expectEqualStrings("s", unit.name);
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("u1", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .interface_block);
    try testing.expectEqualStrings("h", unit.decls[1].interface_block.name.?);
}

test "parseProgram imports renamed ONLY items through module preludes without contains" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  type t1\n" ++
        "    integer :: value\n" ++
        "  end type t1\n" ++
        "end module m1\n" ++
        "module m2\n" ++
        "  use m1, only : u1 => t1\n" ++
        "end module m2\n" ++
        "subroutine s(x)\n" ++
        "  use m2\n" ++
        "  type(u1), intent(in) :: x\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqualStrings("s", unit.name);
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("u1", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .type_decl);
    try testing.expectEqualStrings("u1", unit.decls[1].type_decl.derived_type_name.?);
}

test "parseProgram imports renamed USE items through module preludes without ONLY" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  type t1\n" ++
        "    integer :: value\n" ++
        "  end type t1\n" ++
        "end module m1\n" ++
        "module m2\n" ++
        "  use m1, u1 => t1\n" ++
        "end module m2\n" ++
        "subroutine s(x)\n" ++
        "  use m2\n" ++
        "  type(u1), intent(in) :: x\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("u1", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .type_decl);
    try testing.expectEqualStrings("u1", unit.decls[1].type_decl.derived_type_name.?);
}

test "parseProgram keeps non-renamed module exports visible for USE rename without ONLY" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  type t1\n" ++
        "    integer :: value\n" ++
        "  end type t1\n" ++
        "  type t2\n" ++
        "    integer :: value\n" ++
        "  end type t2\n" ++
        "end module m1\n" ++
        "subroutine s(x, y)\n" ++
        "  use m1, u1 => t1\n" ++
        "  type(u1), intent(in) :: x\n" ++
        "  type(t2), intent(in) :: y\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 4), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("u1", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .derived_type_def);
    try testing.expectEqualStrings("t2", unit.decls[1].derived_type_def.name);
}

test "parseProgram imports single-item object declarations through USE ONLY module preludes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  type t1\n" ++
        "    integer :: value\n" ++
        "  end type t1\n" ++
        "  type(t1) :: x\n" ++
        "end module m1\n" ++
        "subroutine s()\n" ++
        "  use m1, only : x\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 2), unit.decls.len);
    try testing.expect(unit.decls[0] == .derived_type_def);
    try testing.expectEqualStrings("t1", unit.decls[0].derived_type_def.name);
    try testing.expect(unit.decls[1] == .type_decl);
    try testing.expectEqualStrings("x", unit.decls[1].type_decl.items[0].name);
    try testing.expectEqualStrings("t1", unit.decls[1].type_decl.derived_type_name.?);
}

