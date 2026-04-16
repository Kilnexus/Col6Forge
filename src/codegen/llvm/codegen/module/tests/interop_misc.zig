const common = @import("common.zig");
const std = common.std;
const ast = common.ast;
const input = common.input;
const catalog = common.catalog;
const codegen_diag = common.codegen_diag;
const fixed_form = common.fixed_form;
const free_form = common.free_form;
const parser = common.parser;
const split_api = common.split_api;
const codegen = common.codegen;
const emitModule = common.emitModule;
const emitModuleToWriter = common.emitModuleToWriter;
const setCodegenDiagForUnit = common.setCodegenDiagForUnit;
const makeIdentExpr = common.makeIdentExpr;
const makeLiteralExpr = common.makeLiteralExpr;
const makeLocalArraySymbol = common.makeLocalArraySymbol;
const makeLocalScalarSymbol = common.makeLocalScalarSymbol;
const makeLocalCharacterSymbol = common.makeLocalCharacterSymbol;
const makeIntrinsicFunctionSymbol = common.makeIntrinsicFunctionSymbol;
const makeSourceRef = common.makeSourceRef;
test "emitModuleToWriter lowers legacy typed external function references in expression context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      DOUBLE PRECISION D1MACH, X\n" ++
        "      X = D1MACH(4)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "typed_external_call.f", .{});
}

test "emitModuleToWriter lowers character component substring and repeat assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type :: t\n" ++
        "    character(4) :: name\n" ++
        "  end type\n" ++
        "  type(t) :: a\n" ++
        "  character(2) :: part\n" ++
        "  character(4) :: fill\n" ++
        "  part = a%name(2:3)\n" ++
        "  fill = repeat('x', 4)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "char_component_repeat.f", .{});
}

test "emitModuleToWriter lowers C_LOC for c_ptr assignment and actual arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\program p
        \\  use iso_c_binding
        \\  implicit none
        \\  integer, target :: x
        \\  type(c_ptr) :: p1
        \\  p1 = c_loc(x)
        \\  call take(c_loc(x))
        \\contains
        \\  subroutine take(p)
        \\    use iso_c_binding
        \\    type(c_ptr), value :: p
        \\  end subroutine take
        \\end program p
    ;

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "c_loc_intrinsic.f90", .{});
}

test "emitModuleToWriter lowers GCC c_loc_tests_12 style iso_c_binding calls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\module test1
        \\  use, intrinsic :: iso_c_binding
        \\  implicit none
        \\contains
        \\  subroutine sub1(argv) bind(c,name="sub1")
        \\    type(c_ptr), intent(in) :: argv
        \\  end subroutine
        \\
        \\  subroutine sub2
        \\    type(c_ptr), dimension(1), target :: argv = c_null_ptr
        \\    character(c_char), dimension(1), target :: s = c_null_char
        \\    call sub1(c_loc(argv))
        \\  end subroutine
        \\end module test1
        \\
        \\program test2
        \\  use iso_c_binding
        \\  type(c_ptr), target, save :: argv
        \\  interface
        \\    subroutine sub1(argv) bind(c)
        \\      import
        \\      type(c_ptr), intent(in) :: argv
        \\    end subroutine sub1
        \\  end interface
        \\  call sub1(c_loc(argv))
        \\end program test2
    ;

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "c_loc_gcc_style.f90", .{});
}

test "emitModuleToWriter lowers iso_c_binding null pointer named constants in initializers and actuals" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\program p
        \\  use iso_c_binding
        \\  implicit none
        \\  type(c_ptr), save :: p0 = c_null_ptr
        \\  type(c_funptr), save :: fp0 = c_null_funptr
        \\  call take_ptr(c_null_ptr)
        \\contains
        \\  subroutine take_ptr(x)
        \\    use iso_c_binding
        \\    type(c_ptr), value :: x
        \\  end subroutine take_ptr
        \\end program p
    ;

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "c_null_ptr_named_constants.f90", .{});
}

test "emitModuleToWriter lowers GCC c_ptr_tests_16 style transfer intrinsics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\program test
        \\  use iso_c_binding
        \\  implicit none
        \\  type(c_ptr) :: m
        \\  integer(c_intptr_t) :: a
        \\  a = transfer(transfer("ABCE", m), 1_c_intptr_t)
        \\  if (int(z'45434241') /= a) stop
        \\contains
        \\  subroutine bug6
        \\    use iso_c_binding
        \\    implicit none
        \\    type(c_ptr) array(2)
        \\    array = transfer([integer(C_INTPTR_T)::32512,32520], array)
        \\  end subroutine bug6
        \\end program test
    ;

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "c_ptr_transfer_gcc_style.f90", .{});

    try testing.expect(std.mem.indexOf(u8, buffer.items, "llvm.memcpy.p0.p0.i64") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "llvm.memset.p0.i64") != null);
}

test "emitModuleToWriter lowers INT and REAL intrinsics with KIND actual" {
    const source =
        \\program p
        \\  integer, parameter :: k8 = 8
        \\  integer(kind=8) :: i
        \\  real(kind=8) :: x
        \\  i = int(3.5, kind=k8)
        \\  x = real(2, kind=k8)
        \\end program p
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try emitModuleToWriter(source, arena.allocator(), buf.writer());
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "fptosi") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "sitofp") != null);
}

test "emitModuleToWriter lowers CMPLX intrinsic with KIND actual" {
    const source =
        \\program p
        \\  complex(kind=8) :: z
        \\  z = cmplx(1.0, 2.0, kind=8)
        \\end program p
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try emitModuleToWriter(source, arena.allocator(), buf.writer());
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "{ double, double }") != null);
}

test "emitModuleToWriter lowers scalar assignment through real pointer target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\program p
        \\  implicit none
        \\  real, pointer :: r
        \\  allocate(r)
        \\  r = 12
        \\end program p
    ;

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "real_pointer_scalar_assign.f90", .{});
}

test "emitModuleToWriter lowers pointer array element assignment after c_f_pointer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\program p
        \\  use iso_c_binding, only: c_ptr, c_loc, c_f_pointer
        \\  implicit none
        \\  real, target :: av(4), bv(4)
        \\  type(c_ptr) :: c_av, c_bv
        \\  real, pointer :: f_av(:), f_bv(:)
        \\  integer :: i
        \\  c_av = c_loc(av)
        \\  c_bv = c_loc(bv)
        \\  call c_f_pointer(c_av, f_av, [4])
        \\  call c_f_pointer(c_bv, f_bv, [4])
        \\  do i = 1, 4
        \\    f_bv(i) = f_av(i) * i
        \\  end do
        \\end program p
    ;

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "pointer_array_assign_after_c_f_pointer.f90", .{});
}

test "emitModuleToWriter lowers scalar assignment through pointer component target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\module m
        \\  implicit none
        \\  type :: t
        \\    logical, pointer :: lval
        \\  end type t
        \\contains
        \\  subroutine s(x, v)
        \\    type(t), intent(inout) :: x
        \\    logical, intent(in) :: v
        \\    allocate(x%lval)
        \\    x%lval = v
        \\  end subroutine s
        \\end module m
    ;

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "pointer_component_scalar_assign.f90", .{});
}

test "emitModuleToWriter lowers pointer array element arithmetic without prior association" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\program p
        \\  implicit none
        \\  real, pointer :: f_av(:), f_bv(:)
        \\  integer :: i, n
        \\  n = 4
        \\  do i = 1, n
        \\    f_bv(i) = f_av(i) * i
        \\  end do
        \\end program p
    ;

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "pointer_array_unassociated_assign.f90", .{});
}

