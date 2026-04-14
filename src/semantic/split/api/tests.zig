const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const fixed_form = @import("../../../frontend/fixed_form.zig");
const free_form = @import("../../../frontend/free_form.zig");
const parser = @import("../../../frontend/parser/mod.zig");
const diagnostic = @import("../../diagnostic.zig");
const symbols = @import("../../symbol/mod.zig");
const api = @import("mod.zig");
const procedure_inference = @import("procedure_inference.zig");
const analyzeProgram = api.analyzeProgram;
const analyzeProgramWithKnownAndOptionsAndDiagnostics = api.analyzeProgramWithKnownAndOptionsAndDiagnostics;

test "analyzeProgramWithKnownAndOptionsAndDiagnostics keeps semantic diagnostics in explicit bag" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\      SUBROUTINE S
        \\      CHARACTER*0 A
        \\      END
        \\
    ;
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    try testing.expectError(
        error.InvalidCharLen,
        analyzeProgramWithKnownAndOptionsAndDiagnostics(
            arena.allocator(),
            program,
            &.{},
            &.{},
            .{},
            &diag_bag,
        ),
    );

    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expectEqualStrings(catalog.semantic.invalid_char_len.code, diag.code);
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expect(diagnostic.take() == null);
}

test "analyzeProgram installs single-target generic interface aliases with pointer metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  type t\n" ++
        "    real, pointer :: x(:)\n" ++
        "  end type t\n" ++
        "  interface x_\n" ++
        "    module procedure get_x\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  function get_x(v)\n" ++
        "    real, pointer :: get_x(:)\n" ++
        "    type(t), intent(in) :: v\n" ++
        "    get_x => v%x\n" ++
        "  end function get_x\n" ++
        "end module m1\n" ++
        "subroutine s(v)\n" ++
        "  use m1\n" ++
        "  type(t), intent(in) :: v\n" ++
        "  real, pointer :: p(:)\n" ++
        "  p => x_(v)\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    try testing.expectEqual(@as(usize, 2), sem.units.len);
    const caller = sem.units[1];
    var found_x = false;
    for (caller.symbols) |sym| {
        if (!std.ascii.eqlIgnoreCase(sym.name, "x_")) continue;
        found_x = true;
        try testing.expect(sym.kind == .function);
        try testing.expect(sym.is_pointer);
        try testing.expect(sym.loweredKind() == .real);
    }
    try testing.expect(found_x);
}

test "analyzeProgram rejects assumed-length result in module procedure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module funcs\n" ++
        "contains\n" ++
        "  function assumed_len(x)\n" ++
        "    character(*) :: assumed_len\n" ++
        "    integer, intent(in) :: x\n" ++
        "  end function assumed_len\n" ++
        "end module funcs\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    try testing.expectError(
        error.InvalidCharLen,
        analyzeProgramWithKnownAndOptionsAndDiagnostics(
            arena.allocator(),
            program,
            &.{},
            &.{},
            .{},
            &diag_bag,
        ),
    );

    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expectEqualStrings(catalog.semantic.invalid_char_len.code, diag.code);
    try testing.expect(std.mem.indexOf(u8, diag.message, "module procedure") != null);
}

test "analyzeProgram rejects assumed-length result in internal function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "contains\n" ++
        "  function assumed_len(x)\n" ++
        "    character(*) :: assumed_len\n" ++
        "    integer, intent(in) :: x\n" ++
        "  end function assumed_len\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    try testing.expectError(
        error.InvalidCharLen,
        analyzeProgramWithKnownAndOptionsAndDiagnostics(
            arena.allocator(),
            program,
            &.{},
            &.{},
            .{},
            &diag_bag,
        ),
    );

    const diag = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag);
    try testing.expectEqualStrings(catalog.semantic.invalid_char_len.code, diag.code);
    try testing.expect(std.mem.indexOf(u8, diag.message, "internal function") != null);
}

test "analyzeProgram accepts pointer assignment from single-target generic function result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module class_fld\n" ++
        "  type fld\n" ++
        "    integer :: size(2)\n" ++
        "  end type fld\n" ++
        "end module class_fld\n" ++
        "module class_s_fld\n" ++
        "  use class_fld\n" ++
        "  type s_fld\n" ++
        "    type(fld) :: base\n" ++
        "    real(kind(1.d0)), pointer :: x(:) => null()\n" ++
        "  end type s_fld\n" ++
        "  interface x_\n" ++
        "    module procedure get_s_fld_x\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  function get_s_fld_x(fld)\n" ++
        "    real(kind(1.d0)), pointer :: get_s_fld_x(:)\n" ++
        "    type(s_fld), intent(in) :: fld\n" ++
        "    get_s_fld_x => fld%x\n" ++
        "  end function get_s_fld_x\n" ++
        "end module class_s_fld\n" ++
        "subroutine solve_s_foo(phi)\n" ++
        "  use class_s_fld\n" ++
        "  type(s_fld), intent(inout) :: phi\n" ++
        "  integer :: nsz\n" ++
        "  real(kind(1.d0)), pointer :: x(:)\n" ++
        "  x => x_(phi)\n" ++
        "  nsz = size(x)\n" ++
        "end subroutine solve_s_foo\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try analyzeProgram(arena.allocator(), program);
    try testing.expect(diagnostic.take() == null);
}

test "inferProcedureArgSigs marks implicit dummy procedure arguments from call usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        \\      REAL FUNCTION FF326(RDON02,RDON03)
        \\      CALL RDON02(RDON03)
        \\      FF326 = RDON03 + 1.0
        \\      RETURN
        \\      END
        \\
    ;
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);

    const arg_sigs = try procedure_inference.inferProcedureArgSigs(arena.allocator(), program.units[0]);
    try testing.expectEqual(@as(usize, 2), arg_sigs.len);
    try testing.expect(arg_sigs[0].is_procedure);
    try testing.expectEqual(ast.ProgramUnitKind.subroutine, arg_sigs[0].procedure_kind.?);
    try testing.expect(!arg_sigs[1].is_procedure);
}

test "inferProcedureArgSigs infers typed scalar dummy as function from call syntax usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
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
    try testing.expectEqual(@as(usize, 1), program.units.len);

    const arg_sigs = try procedure_inference.inferProcedureArgSigs(arena.allocator(), program.units[0]);
    try testing.expectEqual(@as(usize, 2), arg_sigs.len);
    try testing.expect(arg_sigs[0].is_procedure);
    try testing.expectEqual(ast.ProgramUnitKind.function, arg_sigs[0].procedure_kind.?);
    try testing.expectEqual(ast.TypeKind.character, arg_sigs[0].procedure_result_type_spec.?.lowered_kind);
    try testing.expectEqual(@as(?usize, null), arg_sigs[0].procedure_result_type_spec.?.char_len);
    try testing.expect(!arg_sigs[1].is_procedure);
}

test "analyzeProgram selects the unique visible generic specific after USE association" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module p_class\n" ++
        "  implicit none\n" ++
        "  private :: init_personnel\n" ++
        "  interface new\n" ++
        "    module procedure init_personnel\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine init_personnel(this)\n" ++
        "    integer, intent(in) :: this\n" ++
        "  end subroutine init_personnel\n" ++
        "end module p_class\n" ++
        "module s_class\n" ++
        "  use p_class\n" ++
        "  implicit none\n" ++
        "  private :: init_student\n" ++
        "  type student\n" ++
        "    integer :: personnel = 1\n" ++
        "  end type student\n" ++
        "  interface new\n" ++
        "    module procedure init_student\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine init_student(this)\n" ++
        "    type(student), intent(in) :: this\n" ++
        "    call new(this%personnel)\n" ++
        "  end subroutine init_student\n" ++
        "end module s_class\n" ++
        "program p\n" ++
        "  use s_class\n" ++
        "  type(student) :: b\n" ++
        "  call new(b)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try analyzeProgram(arena.allocator(), program);
    try testing.expect(diagnostic.take() == null);
}

test "analyzeProgram installs single-target generic assignment aliases declared with procedure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  implicit none\n" ++
        "  type :: varying_string\n" ++
        "  end type varying_string\n" ++
        "  interface assignment(=)\n" ++
        "    procedure op_assign_vs_ch\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine op_assign_vs_ch(var, exp)\n" ++
        "    type(varying_string), intent(out) :: var\n" ++
        "    character(len=*), intent(in) :: exp\n" ++
        "  end subroutine op_assign_vs_ch\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    try testing.expectEqual(@as(usize, 2), sem.units.len);
    const unit = sem.units[1];
    var found_assignment = false;
    for (unit.symbols) |sym| {
        if (!std.ascii.eqlIgnoreCase(sym.name, "assignment(=)")) continue;
        found_assignment = true;
        try testing.expect(sym.kind == .subroutine);
    }
    try testing.expect(found_assignment);
}

test "analyzeProgramWithKnownAndOptionsAndDiagnostics accepts defined assignment declared with procedure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none\n" ++
        "\n" ++
        "type :: varying_string\n" ++
        "end type\n" ++
        "\n" ++
        "interface assignment(=)\n" ++
        "   procedure op_assign_VS_CH\n" ++
        "end interface\n" ++
        "\n" ++
        "contains\n" ++
        "\n" ++
        "subroutine op_assign_VS_CH (var, exp)\n" ++
        "  type(varying_string), intent(out) :: var\n" ++
        "  character(LEN=*), intent(in)      :: exp\n" ++
        "end subroutine\n" ++
        "\n" ++
        "subroutine split_VS\n" ++
        "  type(varying_string) :: string\n" ++
        "  call split_CH(string)\n" ++
        "end subroutine\n" ++
        "\n" ++
        "subroutine split_CH (string)\n" ++
        "  type(varying_string) :: string\n" ++
        "  string = \"\"\n" ++
        "end subroutine\n" ++
        "\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    const sem = try analyzeProgramWithKnownAndOptionsAndDiagnostics(
        arena.allocator(),
        program,
        &.{},
        &.{},
        .{},
        &diag_bag,
    );

    try testing.expectEqual(@as(usize, 4), sem.units.len);
    try testing.expect(diag_bag.take() == null);
}

test "analyzeProgram preserves host derived types for contained functions after host failure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type :: t\n" ++
        "  end type t\n" ++
        "  integer :: i\n" ++
        "  allocate(i)\n" ++
        "contains\n" ++
        "  function f()\n" ++
        "    class(t), allocatable :: f\n" ++
        "  end function\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    var diag_bag = diagnostic.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    try testing.expectError(
        error.UnsupportedAllocateSyntax,
        analyzeProgramWithKnownAndOptionsAndDiagnostics(
            arena.allocator(),
            program,
            &.{},
            &.{},
            .{},
            &diag_bag,
        ),
    );

    var saw_allocate_error = false;
    while (diag_bag.take()) |diag| {
        defer diag_bag.release(diag);
        if (std.mem.eql(u8, diag.message, "invalid type for function result")) {
            return error.TestUnexpectedResult;
        }
        if (std.mem.eql(u8, diag.message, "must be ALLOCATABLE or a POINTER")) {
            saw_allocate_error = true;
        }
    }
    try testing.expect(saw_allocate_error);
}

test "analyzeProgram accepts renamed derived types imported through module preludes without contains" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module bar_prt\n" ++
        "  type bar_dprt\n" ++
        "    integer :: i\n" ++
        "  end type bar_dprt\n" ++
        "end module bar_prt\n" ++
        "module bar_pr_mod\n" ++
        "  interface bar_pwrk\n" ++
        "    subroutine bar_dppwrk(pr)\n" ++
        "      use bar_prt\n" ++
        "      type(bar_dprt), intent(in) :: pr\n" ++
        "    end subroutine bar_dppwrk\n" ++
        "  end interface\n" ++
        "end module bar_pr_mod\n" ++
        "module foo_pr_mod\n" ++
        "  use bar_prt, only : foo_dprt => bar_dprt\n" ++
        "  use bar_pr_mod, only : foo_pwrk => bar_pwrk\n" ++
        "end module foo_pr_mod\n" ++
        "subroutine foo_sub(pr)\n" ++
        "  use foo_pr_mod\n" ++
        "  type(foo_dprt), intent(in) :: pr\n" ++
        "end subroutine foo_sub\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    try testing.expectEqual(@as(usize, 1), sem.units.len);
    const unit = sem.units[0];
    var found = false;
    for (unit.symbols) |sym| {
        if (!std.ascii.eqlIgnoreCase(sym.name, "PR")) continue;
        found = true;
        try testing.expectEqual(ast.TypeKind.derived, sym.loweredKind());
        try testing.expectEqualStrings("foo_dprt", sym.type_spec.derived_type_name.?);
    }
    try testing.expect(found);
}

test "analyzeProgram keeps non-renamed derived types visible for USE rename without ONLY" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  type t1\n" ++
        "    integer :: i\n" ++
        "  end type t1\n" ++
        "  type t2\n" ++
        "    integer :: j\n" ++
        "  end type t2\n" ++
        "end module m1\n" ++
        "subroutine s(x, y)\n" ++
        "  use m1, u1 => t1\n" ++
        "  type(u1), intent(in) :: x\n" ++
        "  type(t2), intent(in) :: y\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    try testing.expectEqual(@as(usize, 1), sem.units.len);
    const unit = sem.units[0];
    var found_x = false;
    var found_y = false;
    for (unit.symbols) |sym| {
        if (std.ascii.eqlIgnoreCase(sym.name, "x")) {
            found_x = true;
            try testing.expectEqualStrings("u1", sym.type_spec.derived_type_name.?);
        }
        if (std.ascii.eqlIgnoreCase(sym.name, "y")) {
            found_y = true;
            try testing.expectEqualStrings("t2", sym.type_spec.derived_type_name.?);
        }
    }
    try testing.expect(found_x);
    try testing.expect(found_y);
}

test "analyzeProgram resolves module function result type through USE without ONLY" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m_use_fn\n" ++
        "contains\n" ++
        "  integer pure function bar(i, j)\n" ++
        "    integer, intent(in) :: i, j\n" ++
        "    bar = 3 - i + abs(i) + j\n" ++
        "  end function bar\n" ++
        "end module m_use_fn\n" ++
        "program p\n" ++
        "  use m_use_fn\n" ++
        "  implicit none\n" ++
        "  real :: a(10)\n" ++
        "  integer :: i\n" ++
        "  read (*,*) a, i\n" ++
        "  a(bar(i,i+2):2) = a(bar(i,i+2):2)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    try testing.expectEqual(@as(usize, 2), sem.units.len);
}

test "analyzeProgram accepts inherited generic type-bound calls dispatched through overriding specifics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type :: base_t\n" ++
        "  contains\n" ++
        "    procedure, pass(a) :: allocate_mnnz => base_allocate_mnnz\n" ++
        "    generic, public :: allocate => allocate_mnnz\n" ++
        "  end type base_t\n" ++
        "  type, extends(base_t) :: child_t\n" ++
        "  contains\n" ++
        "    procedure, pass(a) :: allocate_mnnz => child_allocate_mnnz\n" ++
        "  end type child_t\n" ++
        "  interface\n" ++
        "    subroutine base_allocate_mnnz(m,n,a,nz)\n" ++
        "      import base_t\n" ++
        "      integer, intent(in) :: m, n\n" ++
        "      class(base_t), intent(inout) :: a\n" ++
        "      integer, intent(in), optional :: nz\n" ++
        "    end subroutine base_allocate_mnnz\n" ++
        "    subroutine child_allocate_mnnz(m,n,a,nz)\n" ++
        "      import child_t\n" ++
        "      integer, intent(in) :: m, n\n" ++
        "      class(child_t), intent(inout) :: a\n" ++
        "      integer, intent(in), optional :: nz\n" ++
        "    end subroutine child_allocate_mnnz\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine runit()\n" ++
        "    type(child_t) :: x\n" ++
        "    call x%allocate(1, 2, nz=3)\n" ++
        "  end subroutine runit\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try analyzeProgram(arena.allocator(), program);
}

test "analyzeProgram preserves used derived types for module and implicit-main contained procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module o_type_defs\n" ++
        "  implicit none\n" ++
        "  type seq\n" ++
        "    sequence\n" ++
        "    character(len=9) :: ba(2)\n" ++
        "  end type seq\n" ++
        "end module o_type_defs\n" ++
        "module tests\n" ++
        "  use o_type_defs\n" ++
        "  implicit none\n" ++
        "contains\n" ++
        "  subroutine og0015(uds0l)\n" ++
        "    type(seq) :: uds0l\n" ++
        "  end subroutine og0015\n" ++
        "end module tests\n" ++
        "use o_type_defs\n" ++
        "contains\n" ++
        "  subroutine og0015_main(uds0l)\n" ++
        "    type(seq) :: uds0l\n" ++
        "  end subroutine og0015_main\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    try testing.expectEqual(@as(usize, 5), sem.units.len);
}

test "analyzeProgram exports host-associated parameter constants for contained procedures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module teststr\n" ++
        "  implicit none\n" ++
        "  integer, parameter :: grh_size = 20, nmax = 64\n" ++
        "  type strtype\n" ++
        "    integer :: size\n" ++
        "    character :: mdr(nmax)\n" ++
        "  end type strtype\n" ++
        "contains\n" ++
        "  subroutine sub2(string, str_size)\n" ++
        "    integer, intent(in) :: str_size\n" ++
        "    character, intent(out) :: string(str_size)\n" ++
        "    string(:) = 'a'\n" ++
        "  end subroutine sub2\n" ++
        "  subroutine sub1(a)\n" ++
        "    type(strtype), intent(inout) :: a\n" ++
        "    call sub2(a%mdr(grh_size + 1), a%size - grh_size)\n" ++
        "  end subroutine sub1\n" ++
        "end module teststr\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    const sub1 = blk: {
        for (sem.units) |unit| {
            if (std.ascii.eqlIgnoreCase(unit.name, "sub1")) break :blk unit;
        }
        return error.TestExpectedEqual;
    };

    var found_grh_size = false;
    var found_nmax = false;
    for (sub1.symbols) |sym| {
        if (std.ascii.eqlIgnoreCase(sym.name, "grh_size")) {
            found_grh_size = true;
            try testing.expect(sym.is_host_associated);
            try testing.expectEqual(@as(?symbols.ConstValue, .{ .integer = 20 }), sym.const_value);
        }
        if (std.ascii.eqlIgnoreCase(sym.name, "nmax")) {
            found_nmax = true;
            try testing.expect(sym.is_host_associated);
            try testing.expectEqual(@as(?symbols.ConstValue, .{ .integer = 64 }), sym.const_value);
        }
    }

    try testing.expect(found_grh_size);
    try testing.expect(found_nmax);
}

test "analyzeProgram does not export synthetic constructor symbols into contained host context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module global\n" ++
        "  type :: seq_type1\n" ++
        "    sequence\n" ++
        "    integer :: i\n" ++
        "  end type seq_type1\n" ++
        "end module global\n" ++
        "use global, only: seq_type2 => seq_type1\n" ++
        "type(seq_type2) :: t1\n" ++
        "real :: seq_type1\n" ++
        "t1 = seq_type2(42)\n" ++
        "contains\n" ++
        "  subroutine foo()\n" ++
        "    type :: seq_type1\n" ++
        "      sequence\n" ++
        "      integer :: i\n" ++
        "    end type seq_type1\n" ++
        "    type(seq_type2) :: x\n" ++
        "    x = seq_type1(1)\n" ++
        "  end subroutine foo\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    _ = try analyzeProgram(arena.allocator(), program);
}

test "analyzeProgram accepts fixed-form array constructor derived type sample" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      MODULE o_TYPE_DEFS\n" ++
        "        implicit none\n" ++
        "        TYPE SEQ\n" ++
        "          SEQUENCE\n" ++
        "          CHARACTER(len = 9) ::  BA(2)\n" ++
        "        END TYPE SEQ\n" ++
        "        CHARACTER(len = 9)   ::  BA_T(2)\n" ++
        "        CHARACTER(LEN = 9)   ::  CA_T(1,2)\n" ++
        "      END MODULE o_TYPE_DEFS\n" ++
        "      MODULE TESTS\n" ++
        "        use o_type_defs\n" ++
        "        implicit none\n" ++
        "      CONTAINS\n" ++
        "        SUBROUTINE OG0015(UDS0L)\n" ++
        "          TYPE(SEQ)          UDS0L\n" ++
        "          integer :: j1\n" ++
        "          UDS0L = SEQ((/ (BA_T(J1),J1=1,2) /))\n" ++
        "        END SUBROUTINE\n" ++
        "      END MODULE TESTS\n" ++
        "      use o_type_defs\n" ++
        "      CONTAINS\n" ++
        "        SUBROUTINE OG0015(UDS0L)\n" ++
        "          TYPE(SEQ)          UDS0L\n" ++
        "          UDS0L = SEQ(RESHAPE ( (/ ((CA_T(J1,J2), J1 = 1, 1), J2 = 1, 2)/),(/2/)))\n" ++
        "        END SUBROUTINE\n" ++
        "      END\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try analyzeProgram(arena.allocator(), program);
}
