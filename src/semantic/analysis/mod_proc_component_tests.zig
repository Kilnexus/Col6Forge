const std = @import("std");
const diag = @import("../diagnostic.zig");
const free_form = @import("../../frontend/free_form.zig");
const parser = @import("../../frontend/parser/mod.zig");
const split_api = @import("../split/api/mod.zig");

test "standalone assumed-length character function definition does not conflict with caller declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  implicit none\n" ++
        "  character*2 :: arg, cf\n" ++
        "  arg = 'ab'\n" ++
        "  print *, cf(arg)\n" ++
        "end program p\n" ++
        "character*(*) function cf(arg)\n" ++
        "  character*(*) :: arg\n" ++
        "  cf = arg\n" ++
        "end function cf\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "procedure component CALL uses component path with default PASS" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module moda\n" ++
        "  implicit none\n" ++
        "  type :: a\n" ++
        "    procedure(a_proc), pointer :: proc\n" ++
        "  end type a\n" ++
        "contains\n" ++
        "  subroutine a_proc(this, stat)\n" ++
        "    class(a), intent(inout) :: this\n" ++
        "    integer, intent(out) :: stat\n" ++
        "    stat = 0\n" ++
        "  end subroutine a_proc\n" ++
        "end module moda\n" ++
        "program p\n" ++
        "  use moda\n" ++
        "  implicit none\n" ++
        "  integer :: ierr, i\n" ++
        "  type(a), allocatable :: arr(:)\n" ++
        "  allocate(arr(2))\n" ++
        "  do i = 1, 2\n" ++
        "    arr(i)%proc => a_proc\n" ++
        "    call arr(i)%proc(ierr)\n" ++
        "  end do\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "typed procedure component call accepts actual args without explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  implicit none\n" ++
        "  type coefficients_t\n" ++
        "    procedure(real), pointer, nopass :: vfunc\n" ++
        "  end type coefficients_t\n" ++
        "  type(coefficients_t) :: coeff\n" ++
        "  real, dimension(3) :: x\n" ++
        "  print *, abs(coeff%vfunc(x(:)))\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "derived procedure component rejects generic interface references" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "interface gen\n" ++
        "  procedure foo\n" ++
        "end interface\n" ++
        "type t\n" ++
        "  procedure(gen), pointer, nopass :: p\n" ++
        "end type t\n" ++
        "contains\n" ++
        "  subroutine foo()\n" ++
        "  end subroutine foo\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "may not be generic") != null);
}

test "derived procedure component PASS requires explicit interface and polymorphic passed object" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type :: t\n" ++
        "    procedure(), pass(x), pointer :: f1\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "NOPASS or explicit interface required") != null);
}

test "derived procedure component default PASS uses current module explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module test\n" ++
        "  implicit none\n" ++
        "  type :: output\n" ++
        "    real(8) :: dummy\n" ++
        "  end type output\n" ++
        "  type :: tester\n" ++
        "    procedure(proc1), pointer :: ptr => null()\n" ++
        "  end type tester\n" ++
        "  abstract interface\n" ++
        "    function proc1(self) result(uc)\n" ++
        "      import :: tester, output\n" ++
        "      class(tester), intent(in) :: self\n" ++
        "      class(output), allocatable :: uc\n" ++
        "    end function proc1\n" ++
        "  end interface\n" ++
        "end module test\n" ++
        "module test1\n" ++
        "  type :: output\n" ++
        "  end type\n" ++
        "  abstract interface\n" ++
        "    function proc1() result(uc)\n" ++
        "      import :: output\n" ++
        "      class(output), allocatable :: uc\n" ++
        "    end function proc1\n" ++
        "  end interface\n" ++
        "end module test1\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "write rejects derived type with procedure pointer component" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: rectangle\n" ++
        "    procedure(real), pointer, nopass :: get_special_area\n" ++
        "  end type rectangle\n" ++
        "end module m\n" ++
        "program p\n" ++
        "  use m\n" ++
        "  implicit none\n" ++
        "  type(rectangle) :: rect\n" ++
        "  write(*,*) rect\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "cannot have procedure pointer components") != null);
}

test "write rejects polymorphic data transfer element" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type :: t\n" ++
        "    integer :: i = 5\n" ++
        "  end type\n" ++
        "  class(t), allocatable :: x\n" ++
        "  allocate(t :: x)\n" ++
        "  print *, x\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "cannot be polymorphic") != null);
}

test "write rejects polymorphic data transfer element in implicit main form" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "type t\n" ++
        "  integer :: ii = 5\n" ++
        "end type t\n" ++
        "class(t), allocatable :: x\n" ++
        "allocate (t :: x)\n" ++
        "\n" ++
        "print *,x\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "cannot be polymorphic") != null);
}

test "repository class_24 rejects polymorphic data transfer element" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/class_24.f03", 1024 * 1024);
    defer allocator.free(source);

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "cannot be polymorphic") != null);
}

test "procedure pointer assignment rejects mismatched passed-object dummy interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: rectangle\n" ++
        "    procedure(get_area), pointer :: get_special_area\n" ++
        "  end type rectangle\n" ++
        "  abstract interface\n" ++
        "    real function get_area(this)\n" ++
        "      import :: rectangle\n" ++
        "      class(rectangle), intent(in) :: this\n" ++
        "    end function get_area\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  real function get_my_area(this)\n" ++
        "    type(rectangle), intent(in) :: this\n" ++
        "    get_my_area = 3.0\n" ++
        "  end function get_my_area\n" ++
        "end module m\n" ++
        "use m\n" ++
        "type(rectangle) :: rect\n" ++
        "rect%get_special_area => get_my_area\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "Interface mismatch in procedure pointer assignment") != null);
}

test "procedure pointer assignment rejects array passed-object procedure components" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type t\n" ++
        "    procedure(myproc), pointer, pass :: myproc\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  integer function myproc(me)\n" ++
        "    class(t), intent(in) :: me\n" ++
        "    myproc = 42\n" ++
        "  end function myproc\n" ++
        "end module m\n" ++
        "program main\n" ++
        "  use m\n" ++
        "  implicit none\n" ++
        "  type(t) :: arr(2)\n" ++
        "  arr%myproc => myproc\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "must not have the POINTER attribute") != null);
}
