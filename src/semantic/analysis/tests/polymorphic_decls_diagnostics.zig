const support = @import("support.zig");
const std = support.std;
const diag = support.diag;
const free_form = support.free_form;
const parser = support.parser;
const split_api = support.split_api;

fn bagContainsMessageAtLine(diag_bag: *diag.Bag, line: usize, needle: []const u8) bool {
    while (diag_bag.take()) |item| {
        defer diag_bag.release(item);
        if (item.line != line) continue;
        if (std.mem.indexOf(u8, item.message, needle) != null) return true;
    }
    return false;
}

test "rewritten polymorphic parameter declaration still reports parameter attribute" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type t\n" ++
        "    integer :: i\n" ++
        "  end type\n" ++
        "  class(t), parameter :: x = t(1)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    _ = split_api.analyzeProgramWithKnownAndOptionsAndDiagnostics(
        arena.allocator(),
        program,
        &.{},
        &.{},
        .{},
        &diag_bag,
    ) catch {};

    try testing.expect(bagContainsMessageAtLine(&diag_bag, 5, "PARAMETER attribute"));
}

test "assumed type named constant reports assumed type before parameter initializer fallout" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type t\n" ++
        "  end type\n" ++
        "  type(*), parameter :: x = t()\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    _ = split_api.analyzeProgramWithKnownAndOptionsAndDiagnostics(
        arena.allocator(),
        program,
        &.{},
        &.{},
        .{},
        &diag_bag,
    ) catch {};

    try testing.expect(bagContainsMessageAtLine(&diag_bag, 4, "Assumed type of variable"));
}

test "polymorphic function result still rejects non dummy allocatable pointer result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "type :: t\n" ++
        "end type\n" ++
        "function fun()\n" ++
        "  class(t) :: fun\n" ++
        "end function fun\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    _ = split_api.analyzeProgramWithKnownAndOptionsAndDiagnostics(
        arena.allocator(),
        program,
        &.{},
        &.{},
        .{},
        &diag_bag,
    ) catch {};

    try testing.expect(bagContainsMessageAtLine(&diag_bag, 4, "must be dummy, allocatable or pointer"));
}

test "allocatable polymorphic declaration rejects initializer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type :: t\n" ++
        "    integer :: i\n" ++
        "  end type\n" ++
        "  class(t), allocatable :: x = t(1)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();
    _ = split_api.analyzeProgramWithKnownAndOptionsAndDiagnostics(
        arena.allocator(),
        program,
        &.{},
        &.{},
        .{},
        &diag_bag,
    ) catch {};

    try testing.expect(bagContainsMessageAtLine(&diag_bag, 5, "cannot have an initializer"));
}
