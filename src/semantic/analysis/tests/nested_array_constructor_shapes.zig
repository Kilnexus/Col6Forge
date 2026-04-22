const support = @import("support.zig");
const std = support.std;
const testing = std.testing;
const free_form = support.free_form;
const parser = support.parser;
const diagnostic = support.diag;
const split_api = support.split_api;

fn expectSemanticOk(source: []const u8) !void {
    const allocator = testing.allocator;
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(allocator);
    defer diag_bag.deinit();

    try split_api.analyzeProgramWithKnownAndOptionsAndDiagnostics(arena.allocator(), program, &.{}, &.{}, .{}, &diag_bag);
    try testing.expect(diag_bag.take() == null);
}

test "nested array constructor flattens elemental concat result and scalar" {
    try expectSemanticOk(
        "implicit none\n" ++
        "character(len=2) :: c(3)\n" ++
        "c = 'a'\n" ++
        "c = (/ (/ trim(c(1)), 'a' /)//'c', 'cd' /)\n" ++
        "end\n",
    );
}

test "nested array constructor flattens concat between two array constructors" {
    try expectSemanticOk(
        "implicit none\n" ++
        "character(len=2) :: c(2)\n" ++
        "c = 'a'\n" ++
        "c = (/ (/ trim(c(1)), 'a' /) // (/ trim(c(1)), 'a' /) /)\n" ++
        "end\n",
    );
}

test "nested array constructor handles three-level flattening" {
    try expectSemanticOk(
        "implicit none\n" ++
        "character(len=3) :: c(3)\n" ++
        "c = 'a'\n" ++
        "c = (/ (/ 'A'//(/ trim(c(1)), 'a' /)/)//'c', 'dcd' /)\n" ++
        "end\n",
    );
}
