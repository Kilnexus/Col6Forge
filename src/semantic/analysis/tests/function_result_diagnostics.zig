const support = @import("support.zig");
const std = support.std;
const diag = support.diag;
const free_form = support.free_form;
const parser = support.parser;
const split_api = support.split_api;

test "invalid polymorphic function result still reports intrinsic assignment diagnostic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "class(t) function f()\n" ++
        "  f = 1\n" ++
        "end\n";
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

    try testing.expect(diag_bag.count() >= 2);
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);

    try testing.expectEqual(@as(usize, 1), first.line);
    try testing.expect(std.mem.indexOf(u8, first.message, "is not accessible") != null);
    try testing.expectEqual(@as(usize, 2), second.line);
    try testing.expect(std.mem.indexOf(u8, second.message, "must not be polymorphic") != null);
}
