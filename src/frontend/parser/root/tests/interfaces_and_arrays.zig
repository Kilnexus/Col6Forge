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
test "parseProgram captures generic type-bound bindings in derived types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure :: allocate_mnnz\n" ++
        "    generic, public :: allocate => allocate_mnnz\n" ++
        "  end type t\n" ++
        "end module m\n" ++
        "subroutine s(x)\n" ++
        "  use m\n" ++
        "  type(t), intent(inout) :: x\n" ++
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
    const derived = unit.decls[0].derived_type_def;
    try testing.expectEqualStrings("t", derived.name);
    try testing.expectEqual(@as(usize, 2), derived.bindings.len);
    try testing.expect(!derived.bindings[0].is_generic);
    try testing.expectEqualStrings("allocate_mnnz", derived.bindings[0].name);
    try testing.expect(derived.bindings[1].is_generic);
    try testing.expectEqualStrings("allocate", derived.bindings[1].name);
    try testing.expectEqualStrings("allocate_mnnz", derived.bindings[1].implementation_name.?);
    try testing.expect(unit.decls[1] == .type_decl);
}

test "parseProgram captures multi-target operator type-bound generics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure, nopass :: p1\n" ++
        "    procedure, nopass :: p2\n" ++
        "    generic :: operator(==) => p1, p2\n" ++
        "  end type t\n" ++
        "end module m\n" ++
        "subroutine s(x)\n" ++
        "  use m\n" ++
        "  type(t), intent(inout) :: x\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const derived = program.units[0].decls[0].derived_type_def;
    try testing.expectEqual(@as(usize, 4), derived.bindings.len);
    try testing.expectEqualStrings("operator(==)", derived.bindings[2].name);
    try testing.expectEqualStrings("p1", derived.bindings[2].implementation_name.?);
    try testing.expect(derived.bindings[2].is_generic);
    try testing.expectEqualStrings("operator(==)", derived.bindings[3].name);
    try testing.expectEqualStrings("p2", derived.bindings[3].implementation_name.?);
    try testing.expect(derived.bindings[3].is_generic);
}

test "parseProgramWithDiagnostics reports type-bound generic attribute and target syntax errors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure, nopass :: p1\n" ++
        "    generic, pass :: gen1 => p1\n" ++
        "    generic :: gen2 => p1 x\n" ++
        "  end type t\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    _ = try parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag);

    var saw_access_spec = false;
    var saw_junk_after = false;
    while (diag_bag.take()) |diag| {
        defer diag_bag.release(diag);
        if (std.mem.indexOf(u8, diag.message, "Expected access-specifier") != null) saw_access_spec = true;
        if (std.mem.indexOf(u8, diag.message, "Junk after binding target") != null) saw_junk_after = true;
    }
    try testing.expect(saw_access_spec);
    try testing.expect(saw_junk_after);
}

test "parseProgramWithDiagnostics captures parse errors in explicit bag" {
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
    try testing.expectEqualStrings("  )", diag.line_text);
}

test "parseProgramWithDiagnostics reports missing operator generic import from module prelude" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m_eq\n" ++
        "  interface operator (==)\n" ++
        "     module procedure :: my_cmp\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  elemental function my_cmp(a, b) result(c)\n" ++
        "    integer, intent(in) :: a, b\n" ++
        "    logical :: c\n" ++
        "    c = a == b\n" ++
        "  end function my_cmp\n" ++
        "end module m_eq\n" ++
        "\n" ++
        "module m8\n" ++
        "  use m_eq, only: operator(==), operator(.eq.)\n" ++
        "  use m_eq, only: operator(/=)\n" ++
        "  use m_eq, only: operator(.ne.)\n" ++
        "end module m8\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    try testing.expectError(error.UnexpectedToken, parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag));
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    try testing.expectEqual(@as(usize, 15), first.line);
    try testing.expect(std.mem.indexOf(u8, first.message, "operator /=") != null);

    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);
    try testing.expectEqual(@as(usize, 16), second.line);
    try testing.expect(std.mem.indexOf(u8, second.message, "operator .ne.") != null);
}

test "parseProgramWithDiagnostics reports malformed operator interface end" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  interface operator ( .gt. )\n" ++
        "  end interface operator (.lt.)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    try testing.expectError(error.UnexpectedEOF, parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag));

    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    try testing.expectEqual(@as(usize, 3), first.line);
    try testing.expectEqualStrings("Expecting END INTERFACE OPERATOR", first.message);

    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);
    try testing.expectEqual(@as(usize, 4), second.line);
    try testing.expectEqualStrings("Expecting END INTERFACE", second.message);

    const third = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(third);
    try testing.expectEqualStrings("Unexpected end of file", third.message);
}

test "parseProgramWithDiagnostics reports nested interface inside interface body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "interface assignment (=)\n" ++
        "  interface pseudo_scalar\n" ++
        "  pure function double_tensor2odd (x, t2) result (xt2)\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    try testing.expectError(error.UnexpectedEOF, parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag));

    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    try testing.expectEqual(@as(usize, 2), first.line);
    try testing.expectEqualStrings("Unexpected INTERFACE statement", first.message);

    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);
    try testing.expectEqualStrings("Unexpected end of file", second.message);
}

test "parseProgramWithDiagnostics recovers bare call-like statement in implicit program" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none(type,external)\n" ++
        "  integer :: a, b, c\n" ++
        "  g(a,b,c)\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = try parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag);

    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    try testing.expectEqual(@as(usize, 3), first.line);
    try testing.expect(std.mem.indexOf(u8, first.message, "is not a variable") != null);

    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);
    try testing.expectEqual(@as(usize, 4), second.line);
    try testing.expectEqualStrings("Unexpected END statement", second.message);

    const third = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(third);
    try testing.expectEqual(@as(usize, 4), third.line);
    try testing.expectEqualStrings("Unexpected end of file", third.message);
}

test "parseProgramWithDiagnostics reports declarator initializer shape mismatch before later parse errors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  subroutine s(x)\n" ++
        "    integer :: x(..)\n" ++
        "    integer, dimension(10) :: arr = (/1,2,3,4,5/)\n" ++
        "    select rank(arr(1:3))\n" ++
        "    rank(1)\n" ++
        "      print *, 1\n" ++
        "    end select\n" ++
        "  end subroutine s\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag_bag = parse_diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = try parseProgramWithDiagnostics(arena.allocator(), lines, &diag_bag);

    var saw_shape = false;
    var saw_rank_syntax = false;
    while (diag_bag.take()) |diag| {
        defer diag_bag.release(diag);
        if (std.mem.indexOf(u8, diag.message, "Different shape for array assignment") != null) saw_shape = true;
        if (std.mem.indexOf(u8, diag.message, "Syntax error in argument list") != null) saw_rank_syntax = true;
    }
    try testing.expect(saw_shape);
    try testing.expect(saw_rank_syntax);
}

test "parseProgram handles free-form complex parameter slash array constructor declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "  implicit none\n" ++
        "  integer, parameter :: dp = 8\n" ++
        "  complex(dp), parameter :: ri(2) = (/(1,0),(0,1)/)\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 3), unit.decls.len);
    try testing.expect(unit.decls[2] == .type_decl);
    try testing.expect(unit.decls[2].type_decl.items[0].init != null);
    try testing.expect(unit.decls[2].type_decl.items[0].init.?.* == .array_constructor);
}

test "parseProgram handles free-form assignment with slash array constructor keyword call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s\n" ++
        "  implicit none\n" ++
        "  intrinsic :: real\n" ++
        "  real :: vec(1:2)\n" ++
        "  vec = (/ real(a = 1), 1. /)\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    const unit = program.units[0];
    try testing.expectEqual(@as(usize, 1), unit.stmts.len);
    try testing.expect(unit.stmts[0].node == .assignment);
    try testing.expect(unit.stmts[0].node.assignment.value.* == .array_constructor);
}

test "parseProgram preserves free-form statement labels" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "recursive function fac(i) result (res)\n" ++
        "  integer :: i, j, k, res\n" ++
        "  k = 1\n" ++
        "  goto 100\n" ++
        "entry bifac(i,j) result (res)\n" ++
        "  k = j\n" ++
        "100 continue\n" ++
        "  res = 1\n" ++
        "end function\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
    try testing.expect(program.units[1].stmts[1].label != null);
    try testing.expectEqualStrings("100", program.units[1].stmts[1].label.?);
    try testing.expect(program.units[1].stmts[1].node == .cont);
}

test "parseProgram handles full reduced array_constructor_42 structure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s\n" ++
        "  implicit none\n" ++
        "  intrinsic :: real\n" ++
        "  real :: vec(1:2)\n" ++
        "  vec = (/ real(a = 1), 1. /)\n" ++
        "end subroutine s\n" ++
        "\n" ++
        "program main\n" ++
        "  implicit none\n" ++
        "  intrinsic :: real\n" ++
        "  print *,(/ real(a = 1) /)\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 2), program.units.len);
}

test "parseProgram handles reduced array_constructor_34 nested constructor assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "  implicit none\n" ++
        "  integer, parameter :: dp = 8\n" ++
        "  integer, parameter :: n = 8\n" ++
        "  complex(dp) h1(0:n-1)\n" ++
        "  complex(dp) h2(0:n-1)\n" ++
        "  complex(dp), parameter :: ri(2) = (/(1,0),(0,1)/)\n" ++
        "  integer i, j, k, l\n" ++
        "  real(dp) pi\n" ++
        "  h1 = (/(sum((/(exp(-2*pi*(0,1)*mod(k*l,n)/n)*h2(l),l=0,n-1)/)),k=0,n-1)/)\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
}

test "parseProgram handles transfer kind selector followed by print format string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "  use iso_c_binding\n" ++
        "  implicit none\n" ++
        "  type(c_ptr) :: m\n" ++
        "  integer(c_intptr_t) :: a\n" ++
        "  integer(transfer(transfer(4_c_intptr_t, c_null_ptr),1_c_intptr_t)) :: b\n" ++
        "  a = transfer(transfer(\"ABCE\", m), 1_c_intptr_t)\n" ++
        "  print '(z8)', a\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqual(@as(usize, 2), program.units[0].stmts.len);
    try testing.expect(program.units[0].stmts[1].node == .write);
}

test "parseProgram handles c_ptr_tests_16 reduced full file shape" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "  use iso_c_binding\n" ++
        "  implicit none\n" ++
        "  type(c_ptr) :: m\n" ++
        "  integer(c_intptr_t) :: a\n" ++
        "  integer(transfer(transfer(4_c_intptr_t, c_null_ptr),1_c_intptr_t)) :: b\n" ++
        "  a = transfer (transfer(\"ABCE\", m), 1_c_intptr_t)\n" ++
        "  print '(z8)', a\n" ++
        "end program test\n" ++
        "\n" ++
        "subroutine bug1\n" ++
        "   use iso_c_binding\n" ++
        "   implicit none\n" ++
        "   type(c_ptr) :: m, i\n" ++
        "   type mytype\n" ++
        "     integer a, b, c\n" ++
        "   end type mytype\n" ++
        "   type(mytype) x\n" ++
        "   print *, transfer(32512, x)\n" ++
        "   i = transfer(32512, m)\n" ++
        "end subroutine bug1\n" ++
        "\n" ++
        "function fun()\n" ++
        "   use iso_c_binding\n" ++
        "   implicit none\n" ++
        "   type(c_funptr) fun\n" ++
        "   fun = transfer(32512_c_intptr_t,fun)\n" ++
        "end function fun\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 3), program.units.len);
}

test "parseProgram handles c_ptr_tests_16 exact file shape" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "! PR fortran/46974\n" ++
        "\n" ++
        "program test\n" ++
        "  use ISO_C_BINDING\n" ++
        "  implicit none\n" ++
        "  type(c_ptr) :: m\n" ++
        "  integer(c_intptr_t) :: a\n" ++
        "  integer(transfer(transfer(4_c_intptr_t, c_null_ptr),1_c_intptr_t)) :: b\n" ++
        "  a = transfer (transfer(\"ABCE\", m), 1_c_intptr_t)\n" ++
        "  print '(z8)', a\n" ++
        "  if (     int(z'45434241') /= a  &\n" ++
        "     .and. int(z'41424345') /= a  &\n" ++
        "     .and. int(z'4142434500000000',kind=8) /= a) &\n" ++
        "    call i_do_not_exist()\n" ++
        "end program test\n" ++
        "\n" ++
        "! Examples contributed by Steve Kargl and James Van Buskirk\n" ++
        "\n" ++
        "subroutine bug1\n" ++
        "   use ISO_C_BINDING\n" ++
        "   implicit none\n" ++
        "   type(c_ptr) :: m, i\n" ++
        "   type mytype\n" ++
        "     integer a, b, c\n" ++
        "   end type mytype\n" ++
        "   type(mytype) x\n" ++
        "   print *, transfer(32512, x)\n" ++
        "   i = transfer(32512, m)\n" ++
        "end subroutine bug1\n" ++
        "\n" ++
        "subroutine bug6\n" ++
        "   use ISO_C_BINDING\n" ++
        "   implicit none\n" ++
        "   interface\n" ++
        "      function fun()\n" ++
        "         use ISO_C_BINDING\n" ++
        "         implicit none\n" ++
        "         type(C_FUNPTR) fun\n" ++
        "      end function fun\n" ++
        "   end interface\n" ++
        "   type(C_PTR) array(2)\n" ++
        "   type(C_FUNPTR) result\n" ++
        "   integer(C_INTPTR_T), parameter :: const(*) = [32512,32520]\n" ++
        "\n" ++
        "   result = fun()\n" ++
        "   array = transfer([integer(C_INTPTR_T)::32512,32520],array)\n" ++
        "end subroutine bug6\n" ++
        "\n" ++
        "function fun()\n" ++
        "   use ISO_C_BINDING\n" ++
        "   implicit none\n" ++
        "   type(C_FUNPTR) fun\n" ++
        "   fun = transfer(32512_C_INTPTR_T,fun)\n" ++
        "end function fun\n" ++
        "\n" ++
        "! { dg-final { scan-tree-dump-times \"i_do_not_exist\" 0 \"optimized\" } }\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parseProgram(arena.allocator(), lines);

    try testing.expectEqual(@as(usize, 4), program.units.len);
    try testing.expect(program.units[0].stmts.len >= 3);
}

