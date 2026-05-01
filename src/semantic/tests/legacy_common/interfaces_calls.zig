const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const fixed_form = @import("../../../frontend/fixed_form.zig");
const free_form = @import("../../../frontend/free_form.zig");
const parser = @import("../../../frontend/parser/mod.zig");
const symbols = @import("../../symbol/mod.zig");

const api = @import("../../split/api/mod.zig");
const function_type = @import("../../split/function_type.zig");
const helpers = @import("../helpers.zig");
const analyzeProgram = api.analyzeProgram;
const analyzeProgramWithKnown = api.analyzeProgramWithKnown;
const analyzeProgramWithDiagnostics = helpers.analyzeProgramWithDiagnostics;
const DiagCapture = helpers.DiagCapture;

test "semantic reports CF3110 for function argument count mismatch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      INTEGER X\n" ++
        "      X=F(1)\n" ++
        "      END\n" ++
        "      INTEGER FUNCTION F(A,B)\n" ++
        "      INTEGER A,B\n" ++
        "      F=A+B\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArgumentCount, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectEqual(@as(usize, 9), diag.column);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3110"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "X=F(1)"));
}

test "semantic reports CF3110 with explicit interface related location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      INTERFACE\n" ++
        "      INTEGER FUNCTION F(A,B)\n" ++
        "      INTEGER A,B\n" ++
        "      END FUNCTION\n" ++
        "      END INTERFACE\n" ++
        "      INTEGER X\n" ++
        "      X=F(1)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArgumentCount, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3110"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "X=F(1)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "call site conflicts here"));
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "INTEGER FUNCTION F(A,B)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "visible interface here"));
}

test "semantic reports ambiguous interfaces with related location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  interface iface\n" ++
        "    module procedure sub_a\n" ++
        "    module procedure sub_b\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine sub_a(x)\n" ++
        "    integer, intent(in) :: x\n" ++
        "  end subroutine\n" ++
        "  subroutine sub_b(y)\n" ++
        "    integer, intent(in) :: y\n" ++
        "  end subroutine\n" ++
        "end module\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "Ambiguous interfaces"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    module procedure sub_b"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "ambiguous specific here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "    module procedure sub_a"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "conflicting specific here"));
}

test "semantic reports ambiguous reference with related location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  interface\n" ++
        "    function my_fun(a)\n" ++
        "      real a, my_fun\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end module\n" ++
        "module m2\n" ++
        "  interface\n" ++
        "    function my_fun(a)\n" ++
        "      real a, my_fun\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end module\n" ++
        "subroutine s(a)\n" ++
        "  use m1\n" ++
        "  use m2\n" ++
        "  real a\n" ++
        "  print *, my_fun(a)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "ambiguous reference"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "  print *, my_fun(a)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "ambiguous reference here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 10), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "    function my_fun(a)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "conflicting visible procedure here"));
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[1].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[1].line_text, "    function my_fun(a)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[1].label, "conflicting visible procedure here"));
}

test "semantic reports declaration-side ambiguous interfaces with multiple related locations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  interface iface\n" ++
        "    module procedure sub_a\n" ++
        "    module procedure sub_b\n" ++
        "    module procedure sub_c\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine sub_a(x)\n" ++
        "    integer, intent(in) :: x\n" ++
        "  end subroutine\n" ++
        "  subroutine sub_b(y)\n" ++
        "    integer, intent(in) :: y\n" ++
        "  end subroutine\n" ++
        "  subroutine sub_c(z)\n" ++
        "    integer, intent(in) :: z\n" ++
        "  end subroutine\n" ++
        "end module\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "Ambiguous interfaces"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    module procedure sub_c"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "ambiguous specific here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "    module procedure sub_a"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "conflicting specific here"));
    try testing.expectEqual(@as(usize, 4), diag.secondary_spans[1].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[1].line_text, "    module procedure sub_b"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[1].label, "conflicting specific here"));
}

test "semantic reports visible prelude generic specific reuse with related location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  interface foo\n" ++
        "    module procedure bar\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine bar(x)\n" ++
        "    integer, intent(in) :: x\n" ++
        "  end subroutine\n" ++
        "end module\n" ++
        "subroutine s()\n" ++
        "  use m\n" ++
        "  interface foo\n" ++
        "    subroutine bar(x)\n" ++
        "      integer x\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "is already present in the interface"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    subroutine bar(x)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "duplicate specific here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "    module procedure bar"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "visible prelude specific here"));
}

test "semantic reports mixed generic specific kinds with related location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  interface foo\n" ++
        "    subroutine sub_a(x)\n" ++
        "      integer x\n" ++
        "    end subroutine\n" ++
        "    function fun_b(y)\n" ++
        "      integer y\n" ++
        "      integer fun_b\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end module\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "all SUBROUTINEs or all FUNCTIONs"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    function fun_b(y)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "conflicting specific kind here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "    subroutine sub_a(x)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "generic interface first established here"));
}

test "semantic reports non-procedure generic specific with related declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer :: x\n" ++
        "  interface assignment(=)\n" ++
        "    procedure x\n" ++
        "  end interface\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.UnknownSymbol, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "neither function nor subroutine"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    procedure x"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "referenced non-procedure here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "  integer :: x"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "non-procedure declaration here"));
}

test "semantic reports unknown generic specific procedure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  interface assignment(=)\n" ++
        "    procedure missing_proc\n" ++
        "  end interface\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.UnknownSymbol, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "neither function nor subroutine"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    procedure missing_proc"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "unknown procedure entry here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 0), diag.secondary_spans.len);
}

test "semantic reports ABSTRACT INTERFACE bind-name misuse with related end location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  abstract interface\n" ++
        "    subroutine foo() bind(c, name=\"bar\")\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "NAME not allowed on BIND.C. for ABSTRACT INTERFACE"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    subroutine foo() bind(c, name=\"bar\")"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "invalid BIND(C) NAME here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 4), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "    end subroutine"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "END INTERFACE expected here"));
}

test "semantic reports ABSTRACT INTERFACE module procedure misuse" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  abstract interface\n" ++
        "    module procedure foo\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine foo()\n" ++
        "  end subroutine\n" ++
        "end module\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "must be in a generic module interface"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    module procedure foo"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "invalid MODULE PROCEDURE here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 0), diag.secondary_spans.len);
}

test "semantic reports deferred-shape interface function result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  interface\n" ++
        "    function foo() result(r)\n" ++
        "      integer :: r(:)\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "function result cannot have a deferred shape"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    function foo() result(r)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "invalid deferred-shape result here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 0), diag.secondary_spans.len);
}

test "semantic reports known procedure result type mismatch with related visible source" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  interface\n" ++
        "    integer function f(x)\n" ++
        "      integer x\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end module\n" ++
        "subroutine s()\n" ++
        "  use m\n" ++
        "  interface\n" ++
        "    real function f(x)\n" ++
        "      integer x\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArgumentCount, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3110"));
    try testing.expect(std.mem.eql(u8, diag.message, "Type mismatch in function result"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    real function f(x)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "function result type conflicts here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "    integer function f(x)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "visible known procedure here"));
}

test "semantic reports interface derived type use before later host definition" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  interface\n" ++
        "    subroutine foo(x)\n" ++
        "      import :: t\n" ++
        "      type(t) :: x\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "  type :: t\n" ++
        "    integer :: i\n" ++
        "  end type t\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.UnexpectedTypeDecl, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "is being used before it is defined"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "    subroutine foo(x)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "uses derived type before definition here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 8), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "  type :: t"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "derived type declared later here"));
}

test "semantic reports call-site ambiguous interfaces with related location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  interface foo\n" ++
        "    subroutine ext1(x)\n" ++
        "      integer x\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "  interface foo\n" ++
        "    subroutine ext2(y)\n" ++
        "      integer y\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "  call foo(1)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.message, "Ambiguous interfaces"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "  call foo(1)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "call site conflicts here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "    subroutine ext1(x)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "conflicting visible generic specific here"));
    try testing.expectEqual(@as(usize, 8), diag.secondary_spans[1].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[1].line_text, "    subroutine ext2(y)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[1].label, "conflicting visible generic specific here"));
}

test "semantic reports procedure actual mismatch with related interface location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  interface\n" ++
        "    subroutine foo(x)\n" ++
        "      integer x\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "  call foo(1.0)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArgumentCount, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3110"));
    try testing.expect(std.mem.eql(u8, diag.message, "Type mismatch in argument"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "  call foo(1.0)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "actual argument conflicts here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 4), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "      integer x"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "visible dummy declaration here"));
}

test "semantic reports implicit external type mismatch with related previous call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  real :: x\n" ++
        "  x = foo(1)\n" ++
        "  x = foo(1.0)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArgumentCount, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3110"));
    try testing.expect(std.mem.eql(u8, diag.message, "Type mismatch in argument"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "  x = foo(1.0)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "implicit external actual conflicts here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "  x = foo(1)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "previous implicit external actual here"));
}

test "semantic allows implicit external character actuals with different lengths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  real :: x\n" ++
        "  x = foo('A')\n" ++
        "  x = foo('Safe minimum')\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    try analyzeProgram(arena.allocator(), program);
}

test "semantic allows implicit external array and array element sequence actuals" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s(n, j)\n" ++
        "  integer :: n, j, ix\n" ++
        "  real :: a(10, 10), work(10)\n" ++
        "  ix = isamax(n, work, 1)\n" ++
        "  ix = isamax(n, a(1, j), 1)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    try analyzeProgram(arena.allocator(), program);
}

test "semantic reports implicit external argument-count mismatch with related previous call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  real :: x\n" ++
        "  x = foo(1)\n" ++
        "  x = foo(1, 2)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArgumentCount, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3110"));
    try testing.expect(std.mem.eql(u8, diag.message, "wrong number of arguments"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "  x = foo(1, 2)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "implicit external call conflicts here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 3), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "  x = foo(1)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "previous implicit external call here"));
}

test "semantic reports procedure actual mismatch with actual procedure declaration source" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine caller()\n" ++
        "  interface\n" ++
        "    subroutine outer(p)\n" ++
        "      interface\n" ++
        "        integer function p(x)\n" ++
        "          integer x\n" ++
        "        end function\n" ++
        "      end interface\n" ++
        "    end subroutine\n" ++
        "    real function actual(x)\n" ++
        "      integer x\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "  call outer(actual)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArgumentCount, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3110"));
    try testing.expect(std.mem.eql(u8, diag.message, "Type mismatch in function result"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "  call outer(actual)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "actual argument conflicts here"));
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 5), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "        integer function p(x)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "visible dummy declaration here"));
    try testing.expectEqual(@as(usize, 10), diag.secondary_spans[1].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[1].line_text, "    real function actual(x)"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[1].label, "actual procedure declared here"));
}

test "semantic reports variable definition context with related interface location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s()\n" ++
        "  interface\n" ++
        "    subroutine foo(x)\n" ++
        "      integer, intent(out) :: x\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "  call foo(1)\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.AssignmentTypeMismatch, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3108"));
    try testing.expect(std.mem.eql(u8, diag.message, "in variable definition context"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "  call foo(1)"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "non-definable actual argument here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 4), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "      integer, intent(out) :: x"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "visible dummy declaration here"));
}

test "semantic allows statement-function calls inside statement-function definitions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      INTEGER K\n" ++
        "      IFON07(I)=I**2\n" ++
        "      IFON08(I,J)=IFON07(I)+IFON07(J)\n" ++
        "      K=IFON08(2,3)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try analyzeProgram(arena.allocator(), program);
}

test "semantic rejects keyword actuals in statement-function calls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      INTEGER K\n" ++
        "      F(I)=I+1\n" ++
        "      K=F(I=1)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.AssignmentTypeMismatch, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3108"));
    try testing.expect(std.mem.eql(u8, diag.message, "invalid in a statement function"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "K=F(I=1)"));
}

test "semantic reports abstract passed-object actual with related type location" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type, abstract :: abstract_t\n" ++
        "  contains\n" ++
        "    procedure :: p => abs_p\n" ++
        "  end type\n" ++
        "  type, extends(abstract_t) :: concrete_t\n" ++
        "  end type\n" ++
        "contains\n" ++
        "  subroutine abs_p(self)\n" ++
        "    class(abstract_t), intent(inout) :: self\n" ++
        "  end subroutine\n" ++
        "  subroutine test()\n" ++
        "    type(concrete_t) :: obj\n" ++
        "    call obj%abstract_t%p()\n" ++
        "  end subroutine\n" ++
        "end module\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArgumentCount, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3110"));
    try testing.expect(std.mem.indexOf(u8, diag.message, "is of the ABSTRACT type") != null);
    try testing.expect(std.mem.eql(u8, diag.line_text, "    call obj%abstract_t%p()"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "abstract passed-object actual here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "  type, abstract :: abstract_t"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "abstract type declared here"));
}

test "semantic reports concrete abstract-type declaration with related type source" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type, abstract :: base_t\n" ++
        "  end type\n" ++
        "contains\n" ++
        "  subroutine s()\n" ++
        "    type(base_t) :: x\n" ++
        "  end subroutine\n" ++
        "end module\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.UnexpectedTypeDecl, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3107"));
    try testing.expect(std.mem.indexOf(u8, diag.message, "is of the ABSTRACT type") != null);
    try testing.expect(std.mem.eql(u8, diag.line_text, "    type(base_t) :: x"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "concrete abstract-type entity here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "  type, abstract :: base_t"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "abstract type declared here"));
}
