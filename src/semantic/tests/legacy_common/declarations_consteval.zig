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

test "semantic reports CF3116 for duplicate declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      INTEGER A\n" ++
        "      REAL A\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectEqual(@as(usize, 7), diag.column);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "REAL A"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "redeclared here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans[0].line);
    try testing.expectEqual(@as(usize, 7), diag.secondary_spans[0].column);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "INTEGER A"));
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].label, "first declaration here"));
}

test "semantic reports CF3116 for conflicting DIMENSION redeclaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      INTEGER A(10)\n" ++
        "      DIMENSION A(20)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DuplicateDeclaration, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3116"));
    try testing.expect(std.mem.eql(u8, diag.primary_label, "redeclared here"));
    try testing.expectEqual(@as(usize, 1), diag.notes.len);
    try testing.expectEqual(@as(usize, 1), diag.helps.len);
    try testing.expectEqual(@as(usize, 1), diag.secondary_spans.len);
    try testing.expectEqual(@as(usize, 2), diag.secondary_spans[0].line);
    try testing.expect(std.mem.eql(u8, diag.secondary_spans[0].line_text, "INTEGER A(10)"));
}

test "semantic reuses implicit symbol across repeated references" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      X=1\n" ++
        "      X=X+1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    _ = try analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag);
    try diag_capture.expectNone();
}

test "semantic accepts deferred CHARACTER length for dummy argument" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S(N,STR)\n" ++
        "      INTEGER N\n" ++
        "      CHARACTER*(N) STR\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    var found = false;
    for (sem.units[0].symbols) |sym| {
        if (!std.ascii.eqlIgnoreCase(sym.name, "STR")) continue;
        found = true;
        try testing.expect(sym.isCharacter());
        try testing.expectEqual(symbols.StorageClass.dummy, sym.storage);
        try testing.expectEqual(symbols.CharacterLengthKind.deferred, sym.effectiveCharLenKind());
        try testing.expect(sym.effectiveCharLen() == null);
    }
    try testing.expect(found);
}

test "semantic accepts assumed CHARACTER*(*) for dummy argument" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S(STR)\n" ++
        "      CHARACTER*(*) STR\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    var found = false;
    for (sem.units[0].symbols) |sym| {
        if (!std.ascii.eqlIgnoreCase(sym.name, "STR")) continue;
        found = true;
        try testing.expect(sym.isCharacter());
        try testing.expectEqual(symbols.StorageClass.dummy, sym.storage);
        try testing.expectEqual(symbols.CharacterLengthKind.assumed, sym.effectiveCharLenKind());
        try testing.expect(sym.effectiveCharLen() == null);
    }
    try testing.expect(found);
}

test "semantic accepts deferred CHARACTER length for allocatable arrays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      CHARACTER(LEN=:), ALLOCATABLE :: STR(:)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    var found = false;
    for (sem.units[0].symbols) |sym| {
        if (!std.ascii.eqlIgnoreCase(sym.name, "STR")) continue;
        found = true;
        try testing.expect(sym.isCharacter());
        try testing.expect(sym.is_allocatable);
        try testing.expectEqual(symbols.StorageClass.local, sym.storage);
        try testing.expectEqual(symbols.CharacterLengthKind.deferred, sym.effectiveCharLenKind());
        try testing.expect(sym.effectiveCharLen() == null);
    }
    try testing.expect(found);
}

test "semantic COMMON declaration does not erase explicit CHARACTER length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      CHARACTER*2 D2Z1K(2)\n" ++
        "      COMMON /BLK6/ D2Z1K\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    var found = false;
    for (sem.units[0].symbols) |sym| {
        if (!std.ascii.eqlIgnoreCase(sym.name, "D2Z1K")) continue;
        found = true;
        try testing.expect(sym.isCharacter());
        try testing.expectEqual(symbols.StorageClass.common, sym.storage);
        try testing.expectEqual(symbols.CharacterLengthKind.constant, sym.effectiveCharLenKind());
        try testing.expectEqual(@as(?usize, 2), sym.effectiveCharLen());
    }
    try testing.expect(found);
}

test "semantic reports CF3117 for divide-by-zero in const expression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      CHARACTER*(1/0) A\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.DivisionByZero, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3117"));
}

test "semantic reports CF3118 for negative integer exponent in const expression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      CHARACTER*(2**(-1)) A\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.NegativeIntegerExponent, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3118"));
}

test "semantic reports CF3119 for CHARACTER arithmetic operand" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      INTEGER I\n" ++
        "      I='A'+1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArithmeticOperands, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectEqual(@as(usize, 9), diag.column);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3119"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "I='A'+1"));
}

test "semantic reports CF3119 for LOGICAL and REAL logical operator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      LOGICAL L\n" ++
        "      REAL R\n" ++
        "      L=.TRUE..AND.R\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArithmeticOperands, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3119"));
}

test "semantic reports CF3119 for REAL EQV REAL" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      LOGICAL L\n" ++
        "      REAL A,B\n" ++
        "      L=A.EQV.B\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArithmeticOperands, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3119"));
}

test "semantic reports CF3119 for CHARACTER compared with INTEGER" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      LOGICAL L\n" ++
        "      L='A'.EQ.1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArithmeticOperands, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3119"));
}

test "semantic reports CF3119 for CONCAT with non-character operand" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      CHARACTER*2 C\n" ++
        "      C='A'//1\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidArithmeticOperands, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3119"));
}

test "semantic reports CF3120 for ENTRY in PROGRAM" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      PROGRAM P\n" ++
        "      ENTRY E(X)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidEntryStatement, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3120"));
}

test "semantic reports CF3120 for duplicate ENTRY arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      ENTRY E(X,X)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidEntryStatement, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3120"));
}

test "semantic reports CF3121 for unlabeled FORMAT" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      FORMAT(I5)\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidFormatStatement, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3121"));
}

test "semantic reports CF3122 for SAVE unknown COMMON block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      SAVE /BLK/\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.UnknownCommonBlock, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3122"));
}

test "semantic rejects CHARACTER*(*) for non-dummy declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S\n" ++
        "      CHARACTER*(*) A\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidCharLen, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expectEqual(@as(usize, 7), diag.column);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3103"));
    try testing.expect(std.mem.eql(u8, diag.line_text, "CHARACTER*(*) A"));
}

test "semantic rejects external character declarator with non-constant length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "character(len=10) function a()\n" ++
        "  a = ''\n" ++
        "end function a\n" ++
        "subroutine s(n)\n" ++
        "  integer :: n\n" ++
        "  character(len=n), external :: a\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.InvalidCharLen, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.eql(u8, diag.code, "CF3103"));
    try testing.expect(std.mem.indexOf(u8, diag.message, "constant character length") != null);
}

test "semantic rejects unsupported CHARACTER kind selected by SELECTED_CHAR_KIND" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  character(kind=selected_char_kind(\"\")) :: s\n" ++
        "end program p\n";
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
    try testing.expect(std.mem.indexOf(u8, diag.message, "is not supported for CHARACTER") != null);
}

test "semantic rejects allocatable array with explicit shape" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer, allocatable :: a(1:1)\n" ++
        "end program p\n";
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
    try testing.expect(std.mem.indexOf(u8, diag.message, "deferred shape or assumed rank") != null);
}

test "semantic rejects allocatable bounds inquiry in initialization expression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer, allocatable :: a(:)\n" ++
        "  integer :: b(1) = lbound(a)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_capture = DiagCapture.init(allocator);
    defer diag_capture.deinit();
    try testing.expectError(error.ParameterNotConstant, analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_capture.bag));
    const diag = try diag_capture.take();
    defer diag_capture.release(diag);
    try testing.expect(std.mem.indexOf(u8, diag.message, "does not reduce to a constant expression") != null);
}
