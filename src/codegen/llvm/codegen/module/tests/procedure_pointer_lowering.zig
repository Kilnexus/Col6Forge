const common = @import("common.zig");
const std = common.std;
const free_form = common.free_form;
const parser = common.parser;
const split_api = common.split_api;
const emitModuleToWriter = common.emitModuleToWriter;

test "emitModuleToWriter lowers module and contained procedure pointer targets" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module myfortran_binding\n" ++
        "  implicit none\n" ++
        "  procedure(error_stop), pointer :: error_handler\n" ++
        "contains\n" ++
        "  logical function myfortran_shutdown()\n" ++
        "    call error_handler()\n" ++
        "  end function myfortran_shutdown\n" ++
        "  subroutine error_stop()\n" ++
        "  end subroutine error_stop\n" ++
        "end module myfortran_binding\n" ++
        "program test\n" ++
        "  use myfortran_binding\n" ++
        "  procedure(f), pointer :: pf\n" ++
        "  pf => f\n" ++
        "  error_handler => error_stop\n" ++
        "contains\n" ++
        "  pure subroutine f(x, y)\n" ++
        "    real, intent(in) :: x\n" ++
        "    real, intent(out) :: y\n" ++
        "    y = sin(x)\n" ++
        "  end subroutine f\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_targets.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "ptr @mod_myfortran_binding__error_stop_") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ptr @proc_test__f_") != null);
}

test "emitModuleToWriter lowers procedure pointer assignment followed by procedure pointer call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "  implicit none\n" ++
        "  integer :: i\n" ++
        "  real :: s(4)\n" ++
        "  procedure(f), pointer :: pf\n" ++
        "  pf => f\n" ++
        "  do i = 1, 4\n" ++
        "    call pf(real(i), s(i))\n" ++
        "  end do\n" ++
        "contains\n" ++
        "  pure subroutine f(x, y)\n" ++
        "    real, intent(in) :: x\n" ++
        "    real, intent(out) :: y\n" ++
        "    y = sin(x)\n" ++
        "  end subroutine f\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_call_after_assign.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "store ptr @proc_test__f_") != null);
    try testing.expect(std.mem.indexOf(u8, output, "load ptr, ptr %t0") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call void %t") != null);
}

test "emitModuleToWriter keeps dummy procedure arguments as indirect calls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "integer function apply(fn, i)\n" ++
        "  integer fn, i\n" ++
        "  apply = fn(i) + 1\n" ++
        "end function apply\n" ++
        "integer function inc(i)\n" ++
        "  integer i\n" ++
        "  inc = i + 1\n" ++
        "end function inc\n" ++
        "program test\n" ++
        "  print *, apply(inc, 5)\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "dummy_proc_actual_indirect.f", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "define i32 @apply_(ptr %arg0, ptr %arg1)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call i32 %arg0(") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call i32 @inc_(") == null);
}

test "emitModuleToWriter lowers interface-only external procedure pointer targets as external decls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "  procedure(prc_is_allowed), pointer :: fptr\n" ++
        "  interface\n" ++
        "     function prc_is_allowed(flv, hel, col) result(is_allowed)\n" ++
        "       logical :: is_allowed\n" ++
        "       integer, intent(in) :: flv, hel, col\n" ++
        "     end function prc_is_allowed\n" ++
        "  end interface\n" ++
        "  fptr => prc_is_allowed\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_interface_external.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "store ptr @prc_is_allowed_") != null);
    try testing.expect(std.mem.indexOf(u8, output, "@proc_test__prc_is_allowed_") == null);
}

test "emitModuleToWriter keeps interface-only external procedure targets external in unnamed program" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "  procedure(prc_is_allowed), pointer :: fptr\n" ++
        "  interface\n" ++
        "     function prc_is_allowed(flv, hel, col) result(is_allowed)\n" ++
        "       logical :: is_allowed\n" ++
        "       integer, intent(in) :: flv, hel, col\n" ++
        "     end function prc_is_allowed\n" ++
        "  end interface\n" ++
        "  fptr => prc_is_allowed\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_interface_external_unnamed.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "store ptr @prc_is_allowed_") != null);
    try testing.expect(std.mem.indexOf(u8, output, "@proc___col6forge_program1__prc_is_allowed_") == null);
}

test "emitModuleToWriter calls use-associated module procedures through qualified IR names" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module test\n" ++
        "  interface generic_name_get_proc_ptr\n" ++
        "    module procedure specific_name_get_proc_ptr\n" ++
        "  end interface\n" ++
        "  abstract interface\n" ++
        "    double precision function foo(arg1)\n" ++
        "      real, intent(in) :: arg1\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  function specific_name_get_proc_ptr() result(res)\n" ++
        "    procedure(foo), pointer :: res\n" ++
        "  end function\n" ++
        "end module test\n" ++
        "program crash_test\n" ++
        "  use :: test\n" ++
        "  procedure(foo), pointer :: ptr\n" ++
        "  ptr => specific_name_get_proc_ptr()\n" ++
        "  ptr => generic_name_get_proc_ptr()\n" ++
        "end program crash_test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_module_proc_result.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "define ptr @mod_test__specific_name_get_proc_ptr_()") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call ptr @mod_test__specific_name_get_proc_ptr_()") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call ptr @specific_name_get_proc_ptr_()") == null);
}

test "emitModuleToWriter lowers procedure pointer function calls with scalar returns" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "contains\n" ++
        "  function func(x) result(y)\n" ++
        "    integer :: x, y\n" ++
        "    y = x * 2\n" ++
        "  end function func\n" ++
        "  subroutine use_func()\n" ++
        "    procedure(func), pointer :: f\n" ++
        "    integer :: y\n" ++
        "    f => func\n" ++
        "    y = f(2)\n" ++
        "  end subroutine use_func\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_scalar_result.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "call i32 %t") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call ptr %t") == null);
}
