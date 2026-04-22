const support = @import("support.zig");
const std = support.std;
const testing = std.testing;
const free_form = support.free_form;
const parser = support.parser;
const diagnostic = support.diag;
const split_api = support.split_api;

test "character array intrinsics preserve element character length" {
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  implicit none\n" ++
        "  character(len=1) :: vect(4)\n" ++
        "  character(len=1) :: matrix(2, 2)\n" ++
        "  matrix(1, 1) = \"\"\n" ++
        "  matrix(2, 1) = \"a\"\n" ++
        "  matrix(1, 2) = \"b\"\n" ++
        "  matrix(2, 2) = \"\"\n" ++
        "  vect = (/ \"w\", \"x\", \"y\", \"z\" /)\n" ++
        "  vect = EOSHIFT(vect, 2)\n" ++
        "  vect = PACK(matrix, matrix /= \"\")\n" ++
        "  matrix = RESHAPE(vect, (/ 2, 2 /))\n" ++
        "end program main\n";

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
