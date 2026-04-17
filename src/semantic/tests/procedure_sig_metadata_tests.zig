const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const fixed_form = @import("../../frontend/fixed_form.zig");
const free_form = @import("../../frontend/free_form.zig");
const parser = @import("../../frontend/parser/mod.zig");
const api = @import("../split/api/mod.zig");
const analyze_api = @import("../split/api/analyze.zig");
const analysis_context = @import("../analysis/context.zig");
const diagnostic = @import("../diagnostic.zig");
const symbols = @import("../symbol/mod.zig");
const function_type = @import("../split/function_type.zig");

test "inferProcedureArgSigs captures descriptor-bearing dummy arrays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S(A, B, C)\n" ++
        "      INTEGER A(:), B(*)\n" ++
        "      CHARACTER*(*) C\n" ++
        "      END\n";

    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);

    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[0]);
    try testing.expectEqual(@as(usize, 3), arg_sigs.len);
    try testing.expectEqualStrings("A", arg_sigs[0].name);
    try testing.expect(arg_sigs[0].requires_descriptor);
    try testing.expectEqual(@as(usize, 1), arg_sigs[0].rank);
    try testing.expect(!arg_sigs[1].requires_descriptor);
    try testing.expectEqual(@as(usize, 1), arg_sigs[1].rank);
    try testing.expectEqual(ast.TypeKind.character, arg_sigs[2].type_spec.lowered_kind);
    try testing.expectEqual(@as(?usize, null), arg_sigs[2].type_spec.char_len);
}

test "inferProcedureArgSigs keeps assumed-size lower-bound dummy arrays off descriptor ABI" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S(A)\n" ++
        "      INTEGER A(1:*)\n" ++
        "      END\n";

    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);

    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[0]);
    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expect(!arg_sigs[0].requires_descriptor);
    try testing.expectEqual(@as(usize, 1), arg_sigs[0].rank);
}

test "inferProcedureArgSigs merges DIMENSION declarations for dummy arrays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S(A)\n" ++
        "      INTEGER A\n" ++
        "      DIMENSION A(*)\n" ++
        "      END\n";

    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);

    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[0]);
    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expect(!arg_sigs[0].requires_descriptor);
    try testing.expectEqual(@as(usize, 1), arg_sigs[0].rank);
    try testing.expectEqual(ast.TypeKind.integer, arg_sigs[0].type_spec.lowered_kind);
}

test "inferProcedureArgSigs merges CLASS dummy declaration with separate DIMENSION statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type :: t\n" ++
        "  end type\n" ++
        "contains\n" ++
        "  real function f(x)\n" ++
        "    class(t) :: x\n" ++
        "    dimension :: x(:)\n" ++
        "    f = 1.0\n" ++
        "  end\n" ++
        "end\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 2), program.units.len);

    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);
    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expectEqual(@as(usize, 1), arg_sigs[0].rank);
    try testing.expectEqual(ast.TypeKind.derived, arg_sigs[0].type_spec.lowered_kind);
    try testing.expect(arg_sigs[0].type_spec.polymorphic);
}

test "inferProcedureArgSigs captures OPTIONAL dummy metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S(A, B)\n" ++
        "      INTEGER, OPTIONAL :: A\n" ++
        "      REAL B\n" ++
        "      END\n";

    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[0]);

    try testing.expectEqual(@as(usize, 2), arg_sigs.len);
    try testing.expect(arg_sigs[0].optional);
    try testing.expect(!arg_sigs[1].optional);
}

test "inferProcedureArgSigs captures OPTIONAL procedure dummy metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      SUBROUTINE S(F)\n" ++
        "      PROCEDURE(INTEGER), OPTIONAL :: F\n" ++
        "      END\n";

    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[0]);

    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expect(arg_sigs[0].optional);
    try testing.expectEqual(ast.TypeKind.integer, arg_sigs[0].type_spec.lowered_kind);
}

test "inferProcedureArgSigs captures dummy data attribute metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  subroutine s(a, b, c, d)\n" ++
        "    real, asynchronous :: a\n" ++
        "    real, contiguous :: b(:)\n" ++
        "    real, value :: c\n" ++
        "    real, volatile :: d\n" ++
        "  end subroutine s\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);

    try testing.expectEqual(@as(usize, 4), arg_sigs.len);
    try testing.expect(arg_sigs[0].asynchronous);
    try testing.expect(arg_sigs[1].contiguous);
    try testing.expect(arg_sigs[2].value_attr);
    try testing.expect(arg_sigs[3].volatile_attr);
}

test "inferProcedureArgSigs keeps contained dummy declaration type/rank for component-array call sites" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "  type t\n" ++
        "    integer :: i\n" ++
        "    integer :: j\n" ++
        "  end type\n" ++
        "  type (t) :: a(5)\n" ++
        "  call sub('one',a%j)\n" ++
        "contains\n" ++
        "  subroutine sub(key,a)\n" ++
        "    integer, intent(out)    :: a(:)\n" ++
        "    character(*),intent(in) :: key\n" ++
        "    a = 1\n" ++
        "  end subroutine\n" ++
        "end program\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 2), program.units.len);

    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);
    try testing.expectEqual(@as(usize, 2), arg_sigs.len);
    try testing.expectEqualStrings("key", arg_sigs[0].name);
    try testing.expectEqual(ast.TypeKind.character, arg_sigs[0].type_spec.lowered_kind);
    try testing.expectEqual(@as(usize, 0), arg_sigs[0].rank);
    try testing.expectEqualStrings("a", arg_sigs[1].name);
    try testing.expectEqual(ast.TypeKind.integer, arg_sigs[1].type_spec.lowered_kind);
    try testing.expectEqual(@as(usize, 1), arg_sigs[1].rank);
}

test "inferProcedureArgSigs normalizes dummy array shape signature" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "contains\n" ++
        "  subroutine t(a, b)\n" ++
        "    integer :: b\n" ++
        "    integer :: a(2:b+1,1:b)\n" ++
        "  end subroutine t\n" ++
        "end module m\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);

    try testing.expectEqual(@as(usize, 2), arg_sigs[0].shape_signature.len);
    try testing.expectEqualStrings("b", arg_sigs[0].shape_signature[0]);
    try testing.expectEqualStrings("b", arg_sigs[0].shape_signature[1]);
}

test "inferProcedureArgSigs captures procedure dummy function result metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  subroutine s(f)\n" ++
        "    interface\n" ++
        "      function f() result(r)\n" ++
        "        integer, dimension(:), pointer, contiguous :: r\n" ++
        "      end function f\n" ++
        "    end interface\n" ++
        "  end subroutine s\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);

    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expect(arg_sigs[0].procedure_result_pointer);
    try testing.expect(arg_sigs[0].procedure_result_contiguous);
    try testing.expectEqual(@as(usize, 1), arg_sigs[0].procedure_result_shape_signature.len);
    try testing.expectEqualStrings(":", arg_sigs[0].procedure_result_shape_signature[0]);
}

test "inferProcedureArgSigs preserves derived dummy type names" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type :: varying_string\n" ++
        "  end type varying_string\n" ++
        "contains\n" ++
        "  subroutine s(var)\n" ++
        "    type(varying_string) :: var\n" ++
        "  end subroutine s\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 2), program.units.len);

    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);
    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expectEqual(ast.TypeKind.derived, arg_sigs[0].type_spec.lowered_kind);
    try testing.expectEqualStrings("varying_string", arg_sigs[0].type_spec.derived_type_name.?);
}

test "inferFunctionResultShapeSignature preserves component-based specification expressions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module elements\n" ++
        "  implicit none\n" ++
        "  type element_type\n" ++
        "     type(ele_numbering_type), pointer :: numbering\n" ++
        "  end type element_type\n" ++
        "  type ele_numbering_type\n" ++
        "     integer, dimension(:,:), pointer :: number2count\n" ++
        "  end type ele_numbering_type\n" ++
        "end module elements\n" ++
        "module global_numbering\n" ++
        "  use elements\n" ++
        "  implicit none\n" ++
        "contains\n" ++
        "  function element_local_coords(element) result(coords)\n" ++
        "    type(element_type), intent(in) :: element\n" ++
        "    real, dimension(size(element%numbering%number2count, 1)) :: coords\n" ++
        "    coords = 0.0\n" ++
        "  end function element_local_coords\n" ++
        "end module global_numbering\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 2), program.units.len);

    const shape = try function_type.inferFunctionResultShapeSignature(arena.allocator(), program.units[1].contains[0]);
    try testing.expectEqual(@as(usize, 1), shape.len);
    try testing.expectEqualStrings("size(element%numbering%number2count,1)", shape[0]);
}

test "inferFunctionResultShapeSignature derives deferred allocatable result shape from allocate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module x\n" ++
        "contains\n" ++
        "  pure function myfunc(x) result(y)\n" ++
        "    integer, intent(in) :: x\n" ++
        "    integer, dimension(:), allocatable :: y\n" ++
        "    allocate(y(3))\n" ++
        "    y = [x, 2*x, 3*x]\n" ++
        "  end function myfunc\n" ++
        "end module x\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);
    try testing.expectEqual(@as(usize, 1), program.units[0].contains.len);

    const shape = try function_type.inferFunctionResultShapeSignature(arena.allocator(), program.units[0].contains[0]);
    try testing.expectEqual(@as(usize, 1), shape.len);
    try testing.expectEqualStrings("3", shape[0]);
}

test "inferProcedureArgSigs infers subroutine dummy kind from CALL usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  subroutine bar(sub)\n" ++
        "    call sub\n" ++
        "  end subroutine bar\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);

    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expect(arg_sigs[0].is_procedure);
    try testing.expectEqual(ast.ProgramUnitKind.subroutine, arg_sigs[0].procedure_kind.?);
}

test "inferProcedureArgSigs infers function dummy kind from call syntax usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  subroutine foo(f)\n" ++
        "    integer :: y\n" ++
        "    y = f(32)\n" ++
        "  end subroutine foo\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);

    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expect(arg_sigs[0].is_procedure);
    try testing.expectEqual(ast.ProgramUnitKind.function, arg_sigs[0].procedure_kind.?);
}

test "inferProcedureArgSigs captures result type from interface RESULT declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  subroutine t(f)\n" ++
        "    interface\n" ++
        "      function f(x) result(y)\n" ++
        "        integer, intent(in) :: x\n" ++
        "        integer :: y\n" ++
        "      end function f\n" ++
        "    end interface\n" ++
        "  end subroutine t\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);

    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expect(arg_sigs[0].procedure_has_explicit_interface);
    try testing.expectEqual(ast.TypeKind.integer, arg_sigs[0].procedure_result_type_spec.?.lowered_kind);
}

test "inferProcedureArgSigs captures result rank from interface RESULT declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "contains\n" ++
        "  subroutine t(f)\n" ++
        "    interface\n" ++
        "      function f(x) result(y)\n" ++
        "        integer, intent(in) :: x(:)\n" ++
        "        integer :: y(3)\n" ++
        "      end function f\n" ++
        "    end interface\n" ++
        "  end subroutine t\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[1]);

    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expectEqual(@as(usize, 1), arg_sigs[0].procedure_result_rank);
}

test "inferProcedureArgSigs does not treat array dummy as procedure from subscript use" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine t(a)\n" ++
        "  integer :: a(*)\n" ++
        "  a(1) = 0\n" ++
        "end subroutine t\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    const arg_sigs = try api.inferProcedureArgSigs(arena.allocator(), program.units[0]);

    try testing.expectEqual(@as(usize, 1), arg_sigs.len);
    try testing.expect(!arg_sigs[0].is_procedure);
    try testing.expectEqual(@as(usize, 1), arg_sigs[0].rank);
}

test "analyzeProgram accepts procedure pointer actual with matching declarator interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  abstract interface\n" ++
        "    pure function i_f(x) result(d)\n" ++
        "      real, intent(in) :: x(:,:)\n" ++
        "      real :: d(size(x,1),size(x,2))\n" ++
        "    end function i_f\n" ++
        "  end interface\n" ++
        "  procedure(i_f), pointer :: f => null()\n" ++
        "end module m1\n" ++
        "\n" ++
        "module m2\n" ++
        "contains\n" ++
        "  pure subroutine ns_dirdata(fun)\n" ++
        "    interface\n" ++
        "      pure function fun(x) result(d)\n" ++
        "        real, intent(in) :: x(:,:)\n" ++
        "        real :: d(size(x,1),size(x,2))\n" ++
        "      end function fun\n" ++
        "    end interface\n" ++
        "  end subroutine ns_dirdata\n" ++
        "end module m2\n" ++
        "\n" ++
        "program p\n" ++
        "  use m1\n" ++
        "  use m2\n" ++
        "  call ns_dirdata(f)\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try api.analyzeProgram(arena.allocator(), program);
}

test "analyzeProgram rejects procedure actual dummy attribute mismatch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test_attributes\n" ++
        "  call tester1(a1)\n" ++
        "contains\n" ++
        "  subroutine a1(aa)\n" ++
        "    real :: aa\n" ++
        "  end subroutine\n" ++
        "  subroutine tester1(f1)\n" ++
        "    interface\n" ++
        "      subroutine f1(a)\n" ++
        "        real, asynchronous :: a\n" ++
        "      end subroutine\n" ++
        "    end interface\n" ++
        "  end subroutine\n" ++
        "end program test_attributes\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(allocator);
    defer diag_bag.deinit();

    try testing.expectError(
        error.InvalidArgumentCount,
        api.analyzeProgramWithKnownAndOptionsAndDiagnostics(arena.allocator(), program, &.{}, &.{}, .{}, &diag_bag),
    );
    const got = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(got);
    try testing.expectEqualStrings("ASYNCHRONOUS mismatch in argument", got.message);
}

test "analyzeProgram rejects function result character length mismatch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test_lengths\n" ++
        "  call call_a(a1)\n" ++
        "contains\n" ++
        "  character(1) function a1()\n" ++
        "  end function\n" ++
        "  subroutine call_a(a3)\n" ++
        "    interface\n" ++
        "      character(2) function a3()\n" ++
        "      end function\n" ++
        "    end interface\n" ++
        "  end subroutine\n" ++
        "end program test_lengths\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(allocator);
    defer diag_bag.deinit();

    try testing.expectError(
        error.InvalidArgumentCount,
        api.analyzeProgramWithKnownAndOptionsAndDiagnostics(arena.allocator(), program, &.{}, &.{}, .{}, &diag_bag),
    );
    const got = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(got);
    try testing.expectEqualStrings("Character length mismatch in function result", got.message);
}

test "analyzeProgram accepts explicit default kind matching bind(c) result kind" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test_bindc_result\n" ++
        "  use iso_c_binding\n" ++
        "  interface\n" ++
        "    function fun() bind(C)\n" ++
        "      use iso_c_binding\n" ++
        "      implicit none\n" ++
        "      real(C_FLOAT) fun\n" ++
        "    end function fun\n" ++
        "  end interface\n" ++
        "end program test_bindc_result\n" ++
        "\n" ++
        "function fun() bind(C)\n" ++
        "  use iso_c_binding\n" ++
        "  implicit none\n" ++
        "  real(C_FLOAT) fun\n" ++
        "  fun = 1.0\n" ++
        "end function fun\n";

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

test "analyzeProgram accepts module procedure call with named kind parameter alias in dummy declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module fgsl\n" ++
        "  use, intrinsic :: iso_c_binding\n" ++
        "  implicit none\n" ++
        "  integer, parameter :: fgsl_double = c_double\n" ++
        "  type :: fgsl_vector\n" ++
        "    type(c_ptr) :: gsl_vector = c_null_ptr\n" ++
        "  end type fgsl_vector\n" ++
        "contains\n" ++
        "  function fgsl_vector_align(p_x, f_x)\n" ++
        "    real(fgsl_double), pointer :: p_x(:)\n" ++
        "    type(fgsl_vector) :: f_x\n" ++
        "    integer :: fgsl_vector_align\n" ++
        "    fgsl_vector_align = 4\n" ++
        "  end function fgsl_vector_align\n" ++
        "end module fgsl\n" ++
        "module tmod\n" ++
        "  use fgsl\n" ++
        "contains\n" ++
        "  subroutine expb_df()\n" ++
        "    type(fgsl_vector) :: f_x\n" ++
        "    real(fgsl_double), pointer :: p_x(:)\n" ++
        "    integer :: status\n" ++
        "    status = fgsl_vector_align(p_x, f_x)\n" ++
        "  end subroutine expb_df\n" ++
        "end module tmod\n";

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

test "inferProgramProcedures preserves contained procedure actual signatures for proc_ptr_55 style calls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module julienne_test_description_m\n" ++
        "  implicit none\n" ++
        "  abstract interface\n" ++
        "    logical function test_function_i(arg)\n" ++
        "      integer, intent(in) :: arg\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "  type test_description_t\n" ++
        "    procedure(test_function_i), pointer, nopass :: test_function_\n" ++
        "  end type\n" ++
        "contains\n" ++
        "  type(test_description_t) function new_test_description(test_function)\n" ++
        "    procedure(test_function_i), intent(in), pointer :: test_function\n" ++
        "    new_test_description%test_function_ => test_function\n" ++
        "  end function\n" ++
        "end module\n" ++
        "use julienne_test_description_m\n" ++
        "implicit none\n" ++
        "type(test_description_t) test_description\n" ++
        "test_description = new_test_description(test1)\n" ++
        "test_description = new_test_description(test2)\n" ++
        "test_description = new_test_description(test3)\n" ++
        "test_description = new_test_description(test4)\n" ++
        "test_description = new_test_description(test5)\n" ++
        "contains\n" ++
        "  logical function test1(arg)\n" ++
        "    integer, intent(in) :: arg\n" ++
        "  end function\n" ++
        "  real function test2(arg)\n" ++
        "    integer, intent(in) :: arg\n" ++
        "  end function\n" ++
        "  logical function test3()\n" ++
        "  end function\n" ++
        "  logical function test4(arg)\n" ++
        "    integer, intent(in) :: arg(:)\n" ++
        "  end function\n" ++
        "  function test5(arg) result(res)\n" ++
        "    integer, intent(in) :: arg\n" ++
        "    logical :: res(2)\n" ++
        "  end function\n" ++
        "end\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(analysis_context.Context.ProcedureSig).init(arena.allocator());
    try analyze_api.seedKnownProcedures(arena.allocator(), &.{}, &.{}, &known_function_type_specs, &known_procedure_sigs);
    try analyze_api.inferProgramProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);

    const test1 = known_procedure_sigs.get("test1") orelse return error.TestExpectedEqual;
    const test2 = known_procedure_sigs.get("test2") orelse return error.TestExpectedEqual;
    const test3 = known_procedure_sigs.get("test3") orelse return error.TestExpectedEqual;
    const test4 = known_procedure_sigs.get("test4") orelse return error.TestExpectedEqual;
    const test5 = known_procedure_sigs.get("test5") orelse return error.TestExpectedEqual;

    try testing.expectEqual(ast.ProgramUnitKind.function, test1.kind);
    try testing.expectEqual(ast.TypeKind.logical, test1.result_type_spec.?.lowered_kind);
    try testing.expectEqual(@as(usize, 1), test1.arg_count);
    try testing.expectEqual(@as(usize, 1), test1.args.len);
    try testing.expectEqual(@as(usize, 0), test1.args[0].rank);

    try testing.expectEqual(ast.ProgramUnitKind.function, test2.kind);
    try testing.expectEqual(ast.TypeKind.real, test2.result_type_spec.?.lowered_kind);
    try testing.expectEqual(@as(usize, 1), test2.arg_count);
    try testing.expectEqual(@as(usize, 1), test2.args.len);
    try testing.expectEqual(@as(usize, 0), test2.args[0].rank);

    try testing.expectEqual(ast.ProgramUnitKind.function, test3.kind);
    try testing.expectEqual(ast.TypeKind.logical, test3.result_type_spec.?.lowered_kind);
    try testing.expectEqual(@as(usize, 0), test3.arg_count);
    try testing.expectEqual(@as(usize, 0), test3.args.len);

    try testing.expectEqual(ast.ProgramUnitKind.function, test4.kind);
    try testing.expectEqual(ast.TypeKind.logical, test4.result_type_spec.?.lowered_kind);
    try testing.expectEqual(@as(usize, 1), test4.arg_count);
    try testing.expectEqual(@as(usize, 1), test4.args.len);
    try testing.expectEqual(@as(usize, 1), test4.args[0].rank);

    try testing.expectEqual(ast.ProgramUnitKind.function, test5.kind);
    try testing.expectEqual(ast.TypeKind.logical, test5.result_type_spec.?.lowered_kind);
    try testing.expectEqual(@as(usize, 1), test5.arg_count);
    try testing.expectEqual(@as(usize, 1), test5.args.len);
    try testing.expectEqual(@as(usize, 0), test5.args[0].rank);
    try testing.expectEqual(@as(usize, 1), test5.result_rank);
}
