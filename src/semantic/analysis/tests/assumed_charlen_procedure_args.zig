const support = @import("support.zig");
const std = support.std;
const testing = std.testing;
const free_form = support.free_form;
const parser = support.parser;
const diagnostic = support.diag;
const api = support.split_api;

test "accepts assumed-length function dummy with concrete-length actual external" {
    const allocator = testing.allocator;

    const source =
        "function is_ok(ch)\n" ++
        "  character(*) is_ok, ch\n" ++
        "  is_ok = ch\n" ++
        "end function is_ok\n" ++
        "\n" ++
        "function more_ok(ch, fcn)\n" ++
        "  character(*) more_ok, ch\n" ++
        "  character(*), external :: fcn\n" ++
        "  more_ok = fcn(ch)\n" ++
        "end function more_ok\n" ++
        "\n" ++
        "program p\n" ++
        "  character(4) :: answer\n" ++
        "  character(4), external :: is_ok, more_ok\n" ++
        "  answer = more_ok(\"okay\", is_ok)\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(allocator);
    defer diag_bag.deinit();

    try api.analyzeProgramWithKnownAndOptionsAndDiagnostics(arena.allocator(), program, &.{}, &.{}, .{}, &diag_bag);
    try testing.expect(diag_bag.take() == null);
}

test "accepts assumed-length external function passed to assumed-length dummy" {
    const allocator = testing.allocator;

    const source =
        "character(*) function charrext(n)\n" ++
        "  character(26) :: alpha = \"abcdefghijklmnopqrstuvwxyz\"\n" ++
        "  charrext = alpha(1:n)\n" ++
        "end function charrext\n" ++
        "\n" ++
        "program p\n" ++
        "  interface\n" ++
        "    integer function test(charr, i)\n" ++
        "      character(*), external :: charr\n" ++
        "      integer :: i\n" ++
        "    end function test\n" ++
        "  end interface\n" ++
        "  character(26), external :: charrext\n" ++
        "  integer :: j, m\n" ++
        "  do j = 1, 26\n" ++
        "    m = test(charrext, j)\n" ++
        "  end do\n" ++
        "end program p\n" ++
        "\n" ++
        "integer function test(charr, i)\n" ++
        "  character(*) :: charr\n" ++
        "  integer :: i\n" ++
        "  print *, charr(i)\n" ++
        "  test = 1\n" ++
        "end function test\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(allocator);
    defer diag_bag.deinit();

    try api.analyzeProgramWithKnownAndOptionsAndDiagnostics(arena.allocator(), program, &.{}, &.{}, .{}, &diag_bag);
    try testing.expect(diag_bag.take() == null);
}
