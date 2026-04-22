const support = @import("support.zig");
const std = support.std;
const diag = support.diag;
const free_form = support.free_form;
const parser = support.parser;
const split_api = support.split_api;

test "function result pointer assignment does not treat implicit result name as procedure pointer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module g_nodes\n" ++
        "  type :: t0\n" ++
        "  end type\n" ++
        "  type, extends(t0) :: t1\n" ++
        "  end type\n" ++
        "contains\n" ++
        "  function basicget(self)\n" ++
        "    class(t0), pointer :: basicget\n" ++
        "    class(t0), target, intent(in) :: self\n" ++
        "    select type (self)\n" ++
        "    type is (t1)\n" ++
        "      basicget => self\n" ++
        "    end select\n" ++
        "  end function basicget\n" ++
        "end module g_nodes\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 2), sem.units.len);
    try testing.expect(diag.take() == null);
}

test "function result pointer assignment from allocatable class component stays data pointer assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module test\n" ++
        "  type :: componentb\n" ++
        "  end type componentb\n" ++
        "  type :: treenode\n" ++
        "    class(componentb), allocatable :: componentb(:)\n" ++
        "  end type treenode\n" ++
        "contains\n" ++
        "  function bget(self)\n" ++
        "    class(componentb), pointer :: bget\n" ++
        "    class(treenode), target, intent(in) :: self\n" ++
        "    select type (self)\n" ++
        "    class is (treenode)\n" ++
        "      bget => self%componentb(1)\n" ++
        "    end select\n" ++
        "  end function bget\n" ++
        "end module test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 2), sem.units.len);
    try testing.expect(diag.take() == null);
}

test "pointer assignment rejects identifier without TARGET attribute" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer :: x\n" ++
        "  integer, pointer :: p\n" ++
        "  p => x\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "neither TARGET nor POINTER") != null);
}

test "pointer assignment accepts identifier with TARGET attribute" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer, target :: x\n" ++
        "  integer, pointer :: p\n" ++
        "  p => x\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "pointer assignment rejects non-target component base" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type :: test_case\n" ++
        "  end type\n" ++
        "  type :: test_suite\n" ++
        "    type(test_case) :: list\n" ++
        "  end type\n" ++
        "contains\n" ++
        "  subroutine sub(self)\n" ++
        "    class(test_suite), intent(inout) :: self\n" ++
        "    type(test_case), pointer :: tst_case\n" ++
        "    tst_case => self%list\n" ++
        "  end subroutine\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "neither TARGET nor POINTER") != null);
}

test "allocatable function result can be allocated by result name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  function f()\n" ++
        "    integer, allocatable :: f\n" ++
        "    allocate(f)\n" ++
        "  end function f\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "allocatable array function result can be allocated through subscript form" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  function f()\n" ++
        "    integer, allocatable :: f(:)\n" ++
        "    allocate(f(3))\n" ++
        "  end function f\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}
