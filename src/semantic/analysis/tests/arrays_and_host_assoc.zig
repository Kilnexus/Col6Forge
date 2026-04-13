const support = @import("support.zig");
const std = support.std;
const ast = support.ast;
const catalog = support.catalog;
const symbols = support.symbols;
const context = support.context;
const procedure_calls = support.procedure_calls;
const diag = support.diag;
const fixed_form = support.fixed_form;
const free_form = support.free_form;
const parser = support.parser;
const split_api = support.split_api;
const UnitAnalyzer = support.UnitAnalyzer;
const recordSemanticError = support.recordSemanticError;

test "parity and norm2 DIM arguments must stay scalar" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  logical, parameter :: a(*,*) = reshape([.true.,.false.], shape=[1,2])\n" ++
        "  real,    parameter :: r(*,*) = reshape([1.,2.], shape=[1,2])\n" ++
        "  print *, parity(a, dim=[1])\n" ++
        "  print *, norm2(r, dim=[1])\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag) catch {};
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);

    try testing.expect(std.mem.indexOf(u8, first.message, "must be a scalar") != null);
    try testing.expect(std.mem.indexOf(u8, second.message, "must be a scalar") != null);
}

test "selected_real_kind arguments must stay scalar" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer :: ip(1), ir(1), i, j\n" ++
        "  i = selected_real_kind(ip, i)\n" ++
        "  j = selected_real_kind(i, ir)\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag) catch {};
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);

    try testing.expect(std.mem.indexOf(u8, first.message, "must be a scalar") != null);
    try testing.expect(std.mem.indexOf(u8, second.message, "must be a scalar") != null);
}

test "static conformance check handles 1D explicit-shape section parsed as substring compatibility node" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  implicit none\n" ++
        "  integer :: n\n" ++
        "  real :: a(10)\n" ++
        "  n = 0\n" ++
        "  if (any(a(n+1:n+5) > [1.0, 2.0, 3.0])) print *, \"x\"\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag) catch {};
    const got = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(got);
    try testing.expect(std.mem.indexOf(u8, got.message, "not conformable") != null);
}

test "free-form rewritten array PARAMETER keeps array shape on PARAMETER statement lane" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer, parameter :: nx = 2, ny = 3\n" ++
        "  integer, parameter, dimension(nx,ny) :: a = reshape((/(i, i=1,size(a))/), shape(a))\n" ++
        "  print *, a(1,1)\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = try split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag);
    try testing.expect(!diag_bag.has());
}

test "elemental scalar dummy accepts array actual and SUM DIM result keeps reduced rank" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer :: a(2,3,4)\n" ++
        "  integer :: r(2,4)\n" ++
        "  r = sum(eid(a), 2)\n" ++
        "contains\n" ++
        "  elemental integer function eid(x)\n" ++
        "    integer, intent(in) :: x\n" ++
        "    eid = x\n" ++
        "  end function eid\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "SUM DIM result may flow into rank-matching array dummy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer :: a(2,3,4)\n" ++
        "  integer :: y(2,4)\n" ++
        "  y = neid2(sum(a, 2))\n" ++
        "contains\n" ++
        "  function neid2(x)\n" ++
        "    integer, intent(in) :: x(:,:)\n" ++
        "    integer :: neid2(size(x,1), size(x,2))\n" ++
        "    neid2 = x\n" ++
        "  end function neid2\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "combined elemental and non-elemental calls accept SUM DIM array result inside larger expression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer :: a(3,4,5)\n" ++
        "  integer :: ay(3,5)\n" ++
        "  if (any(1 + eid(sum(a,2)) + ay + neid2(sum(a,2)) + 1 /= 3*ay + 2)) stop 1\n" ++
        "contains\n" ++
        "  elemental function eid(x)\n" ++
        "    integer, intent(in) :: x\n" ++
        "    integer :: eid\n" ++
        "    eid = x\n" ++
        "  end function eid\n" ++
        "  function neid2(x)\n" ++
        "    integer, intent(in) :: x(:,:)\n" ++
        "    integer :: neid2(size(x,1), size(x,2))\n" ++
        "    neid2 = x\n" ++
        "  end function neid2\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "array sections remain definable actuals for elemental INTENT OUT dummy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer :: b(3,2)\n" ++
        "  call set(b(2:,1), [1,2])\n" ++
        "  call set(b(:,1), [1,2,3])\n" ++
        "contains\n" ++
        "  elemental subroutine set(o, i)\n" ++
        "    integer, intent(out) :: o\n" ++
        "    integer, intent(in) :: i\n" ++
        "    o = i\n" ++
        "  end subroutine set\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "SELECT TYPE character clause preserves kind selector for alias comparisons" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  type :: any_vector\n" ++
        "    class(*), allocatable :: x(:)\n" ++
        "  end type\n" ++
        "  type(any_vector) :: a\n" ++
        "  character(kind = 4, len = 2) :: chr4(2) = [character(kind=4) :: 4_\"ab\", 4_\"cd\"]\n" ++
        "  allocate (a%x(2), source = chr4)\n" ++
        "  call check\n" ++
        "contains\n" ++
        "  subroutine check\n" ++
        "    select type (z => a%x)\n" ++
        "      type is (character(kind = 4, len = *))\n" ++
        "        if (any(z .ne. chr4)) stop 1\n" ++
        "    end select\n" ++
        "  end subroutine check\n" ++
        "end program\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = try split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag);
    try testing.expect(!diag_bag.has());
}

test "array sections preserve rank for assumed-size and contiguous dummy compatibility" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine test1\n" ++
        "  integer, pointer, contiguous :: p(:)\n" ++
        "  integer, target :: a(3)\n" ++
        "  p => a\n" ++
        "  call foo(p(::1))\n" ++
        "contains\n" ++
        "  subroutine foo(x)\n" ++
        "    integer :: x(*)\n" ++
        "  end subroutine foo\n" ++
        "end\n" ++
        "\n" ++
        "subroutine test2\n" ++
        "  integer :: a(8)\n" ++
        "  call bar(a(::1))\n" ++
        "contains\n" ++
        "  subroutine bar(x)\n" ++
        "    integer, contiguous :: x(:)\n" ++
        "  end subroutine bar\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "pointer dummy accepts null intrinsic actual" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer, pointer, contiguous :: x(:) => null()\n" ++
        "  call foo(null())\n" ++
        "  call foo(null(x))\n" ++
        "contains\n" ++
        "  subroutine foo(a)\n" ++
        "    integer, pointer, optional, contiguous :: a(:)\n" ++
        "  end subroutine foo\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "contiguous pointer rejects definitely noncontiguous section target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  real, pointer, contiguous :: r(:)\n" ++
        "  real, target :: x(45)\n" ++
        "  r => x(::3)\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.AssignmentTypeMismatch, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.assignment_type_mismatch.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "non-contiguous target") != null);
}

test "allow argument mismatch suppresses implicit external hard errors across contained procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  real :: a\n" ++
        "  call foo(a)\n" ++
        "contains\n" ++
        "  subroutine bar\n" ++
        "    integer :: b\n" ++
        "    call foo(b)\n" ++
        "  end subroutine bar\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = try split_api.analyzeProgramWithKnownAndOptionsAndDiagnostics(
        arena.allocator(),
        program,
        &.{},
        &.{},
        .{ .allow_argument_mismatch = true },
        &diag_bag,
    );
    try testing.expect(!diag_bag.has());
}

test "known implicit external rejects simple scalar type mismatch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module x\n" ++
        "contains\n" ++
        "  subroutine a\n" ++
        "    call foo(1)\n" ++
        "  end subroutine a\n" ++
        "end module x\n" ++
        "\n" ++
        "subroutine foo(a)\n" ++
        "  real :: a\n" ++
        "end subroutine foo\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.InvalidArgumentCount, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.invalid_argument_count.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "Type mismatch in argument") != null);
}

test "known implicit external still permits sequence association actuals" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  real :: a(3,4)\n" ++
        "  call foo(a(3,3))\n" ++
        "end program main\n" ++
        "\n" ++
        "subroutine foo(x)\n" ++
        "  real :: x(4)\n" ++
        "end subroutine foo\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "seeded known external remains F77-compatible without explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  call foo(1)\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    const known_proc_sigs = [_]split_api.KnownProcedureSig{
        .{
            .name = "foo",
            .kind = .subroutine,
            .arg_count = 1,
            .args = &.{
                .{
                    .name = "a",
                    .type_spec = symbols.TypeSpec.fromResolvedKind(.real, .real, null),
                },
            },
        },
    };

    _ = try split_api.analyzeProgramWithKnown(arena.allocator(), program, &.{}, &known_proc_sigs);
}

test "explicit external suppresses implicit call consistency tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  external foo\n" ++
        "  call foo(1)\n" ++
        "  call foo('ab')\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "mirrored host parameters must not shadow contained procedure host association" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module teststr\n" ++
        "  implicit none\n" ++
        "  integer, parameter :: grh_size = 20, nmax = 64\n" ++
        "  type strtype\n" ++
        "    integer :: size\n" ++
        "    character :: mdr(nmax)\n" ++
        "  end type strtype\n" ++
        "contains\n" ++
        "  subroutine sub2(string, str_size)\n" ++
        "    integer, intent(in) :: str_size\n" ++
        "    character, intent(out) :: string(str_size)\n" ++
        "  end subroutine sub2\n" ++
        "  subroutine sub1(a)\n" ++
        "    type(strtype), intent(inout) :: a\n" ++
        "    call sub2(a%mdr(grh_size + 1), a%size - grh_size)\n" ++
        "  end subroutine sub1\n" ++
        "end module teststr\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "contained procedure local derived type may shadow host-associated derived type with same name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module global\n" ++
        "  implicit none\n" ++
        "  type :: different_type\n" ++
        "    integer :: i\n" ++
        "  end type different_type\n" ++
        "contains\n" ++
        "  subroutine foo()\n" ++
        "    type(different_type) :: host_value\n" ++
        "    call inner(host_value)\n" ++
        "  contains\n" ++
        "    subroutine inner(dt1)\n" ++
        "      type(different_type), intent(in) :: dt1\n" ++
        "      type :: different_type\n" ++
        "        complex :: z\n" ++
        "      end type different_type\n" ++
        "      type(different_type) :: b\n" ++
        "      b%z = (2.0, -1.0)\n" ++
        "    end subroutine inner\n" ++
        "  end subroutine foo\n" ++
        "end module global\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "contained procedure sees host-associated external character function declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "function is_ok(ch)\n" ++
        "  character(*) is_ok, ch\n" ++
        "  is_ok = ch\n" ++
        "end function is_ok\n" ++
        "program main\n" ++
        "  character(4), external :: is_ok\n" ++
        "contains\n" ++
        "  function also_ok(ch)\n" ++
        "    character(4) also_ok\n" ++
        "    character(*) ch\n" ++
        "    also_ok = is_ok(ch)\n" ++
        "  end function also_ok\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "derived assignment accepts renamed host type identity and sequence-equivalent local type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module global\n" ++
        "  implicit none\n" ++
        "  type :: seq_type1\n" ++
        "    sequence\n" ++
        "    integer :: i\n" ++
        "  end type seq_type1\n" ++
        "  type :: nonseq_type1\n" ++
        "    integer :: i\n" ++
        "  end type nonseq_type1\n" ++
        "  type(nonseq_type1) :: ns1\n" ++
        "end module global\n" ++
        "use global, only: seq_type2 => seq_type1, nonseq_type1, ns1\n" ++
        "type(seq_type2) :: t1\n" ++
        "type(nonseq_type1) :: ns2\n" ++
        "t1 = seq_type2(42)\n" ++
        "ns2 = ns1\n" ++
        "call foo(t1)\n" ++
        "contains\n" ++
        "  subroutine foo(x)\n" ++
        "    use global, only: seq_type3 => seq_type1\n" ++
        "    type :: seq_type1\n" ++
        "      sequence\n" ++
        "      integer :: i\n" ++
        "    end type seq_type1\n" ++
        "    type(seq_type2) :: x\n" ++
        "    type(seq_type1) :: y\n" ++
        "    type(seq_type3) :: z\n" ++
        "    y = seq_type2(46)\n" ++
        "    z = seq_type3(47)\n" ++
        "  end subroutine foo\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "local derived constructor shadows host-associated object of the same name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module global\n" ++
        "  type :: seq_type1\n" ++
        "    sequence\n" ++
        "    integer :: i\n" ++
        "  end type seq_type1\n" ++
        "end module global\n" ++
        "use global, only: seq_type2 => seq_type1\n" ++
        "real :: seq_type1\n" ++
        "contains\n" ++
        "  subroutine foo()\n" ++
        "    type :: seq_type1\n" ++
        "      sequence\n" ++
        "      integer :: i\n" ++
        "    end type seq_type1\n" ++
        "    type(seq_type2) :: x\n" ++
        "    x = seq_type1(1)\n" ++
        "  end subroutine foo\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try split_api.analyzeProgram(arena.allocator(), program);
}

test "nopass type-bound call rejects array base object" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure, nopass :: p\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  subroutine p()\n" ++
        "  end subroutine p\n" ++
        "  subroutine test()\n" ++
        "    type(t) :: arr(2)\n" ++
        "    call arr%p()\n" ++
        "  end subroutine test\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.InvalidArgumentCount, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.invalid_argument_count.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "must be scalar") != null);
}

test "non-polymorphic abstract type declaration is rejected" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type, abstract :: abst_t\n" ++
        "  end type abst_t\n" ++
        "  type(abst_t) :: x\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.UnexpectedTypeDecl, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.unexpected_type_decl.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "is of the ABSTRACT type") != null);
}

test "structure constructor rejects abstract type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type, abstract :: abst_t\n" ++
        "    integer :: x\n" ++
        "  end type abst_t\n" ++
        "contains\n" ++
        "  subroutine s()\n" ++
        "    class(abst_t), allocatable :: x\n" ++
        "    x = abst_t(1)\n" ++
        "  end subroutine s\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.InvalidArgumentCount, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "Cannot construct ABSTRACT type") != null);
}

test "implicit TYPE of abstract derived type is rejected" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type, abstract :: abst_t\n" ++
        "  end type abst_t\n" ++
        "contains\n" ++
        "  subroutine s()\n" ++
        "    implicit type(abst_t) (a-z)\n" ++
        "  end subroutine s\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.UnexpectedTypeDecl, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "ABSTRACT type 'abst_t' used") != null);
}

test "array constructor rejects abstract type items" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type, abstract :: a\n" ++
        "  end type a\n" ++
        "  type, extends(a) :: b\n" ++
        "  end type b\n" ++
        "contains\n" ++
        "  subroutine s()\n" ++
        "    type(b) :: b_instance\n" ++
        "    class(a), allocatable :: a_array(:)\n" ++
        "    a_array = [a_array, b_instance]\n" ++
        "  end subroutine s\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.AssignmentTypeMismatch, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "is of the ABSTRACT type") != null);
}

test "array constructor rejects abstract imported module type items" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module my_module\n" ++
        "  implicit none\n" ++
        "  private\n" ++
        "  type, abstract, public :: a\n" ++
        "  end type\n" ++
        "  type, extends(a), public :: b\n" ++
        "  end type\n" ++
        "end\n" ++
        "\n" ++
        "program main\n" ++
        "  use my_module\n" ++
        "  implicit none\n" ++
        "  type(b) :: b_instance\n" ++
        "  class(a), allocatable :: a_array(:)\n" ++
        "  class(b), allocatable :: b_array(:)\n" ++
        "  a_array = [b_instance]\n" ++
        "  b_array = [b_instance]\n" ++
        "  a_array = [a_array]\n" ++
        "end program\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.AssignmentTypeMismatch, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "is of the ABSTRACT type") != null);
}

test "external procedure without visible explicit interface does not enforce dummy rank" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  implicit none\n" ++
        "  real :: a(3,4)\n" ++
        "  real :: r\n" ++
        "  external ff\n" ++
        "  r = ff(a(2,3))\n" ++
        "end program p\n" ++
        "real function ff(x)\n" ++
        "  real :: x(2,2)\n" ++
        "  ff = x(1,1)\n" ++
        "end function ff\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test {
    _ = @import("../mod_proc_component_tests.zig");
    _ = @import("../mod_regression_tests.zig");
    _ = @import("../mod_regression/contained_calls.zig");
}
