const support = @import("support.zig");
const std = support.std;
const ast = support.ast;
const catalog = support.catalog;
const symbols = support.symbols;
const context = support.context;
const procedure_calls = support.procedure_calls;
const diag = support.diag;
const fixed_form = support.fixed_form;
const free_form = support.free_form;
const parser = support.parser;
const split_api = support.split_api;
const UnitAnalyzer = support.UnitAnalyzer;
const recordSemanticError = support.recordSemanticError;

test "array-valued function without visible interface requires explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "function test(n)\n" ++
        "  real, dimension(2) :: test\n" ++
        "  integer :: n\n" ++
        "  test = n\n" ++
        "end function test\n" ++
        "program arr\n" ++
        "  real, dimension(2) :: res\n" ++
        "  res = test(2)\n" ++
        "end program arr\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 2), program.units.len);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_parameters = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());

    diag.clear();
    var unit = program.units[1];
    var analyzer_instance = UnitAnalyzer.init(
        arena.allocator(),
        &unit,
        &.{},
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
        false,
    );
    _ = analyzer_instance.analyze() catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    defer diag.releaseTaken(got);
    try testing.expectEqualStrings(catalog.semantic.explicit_interface_required.code, got.code);
}

test "abstract parent component binding call is rejected" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type, abstract :: abstract_t\n" ++
        "  contains\n" ++
        "    procedure, nopass :: proc\n" ++
        "  end type abstract_t\n" ++
        "  type, extends(abstract_t) :: concrete_t\n" ++
        "  end type concrete_t\n" ++
        "contains\n" ++
        "  subroutine proc()\n" ++
        "  end subroutine proc\n" ++
        "  subroutine test(obj)\n" ++
        "    type(concrete_t) :: obj\n" ++
        "    call obj%abstract_t%proc()\n" ++
        "  end subroutine test\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 3), program.units.len);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_parameters = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());

    diag.clear();
    var unit = program.units[0];
    var analyzer_instance = UnitAnalyzer.init(
        arena.allocator(),
        &unit,
        &.{},
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
        false,
    );
    _ = analyzer_instance.analyze() catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    defer diag.releaseTaken(got);
    try testing.expect(std.mem.indexOf(u8, got.message, "is of the ABSTRACT type") != null);
}

test "nonpolymorphic abstract parent reference is rejected" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none\n" ++
        "type, abstract :: parent\n" ++
        "  integer :: i\n" ++
        "end type\n" ++
        "type, extends(parent) :: child\n" ++
        "  class(parent), pointer :: comp\n" ++
        "end type\n" ++
        "type(child), target :: c1\n" ++
        "class(parent), pointer :: cp\n" ++
        "cp => c1%parent\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_parameters = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());

    diag.clear();
    var unit = program.units[0];
    var analyzer_instance = UnitAnalyzer.init(
        arena.allocator(),
        &unit,
        &.{},
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
        false,
    );
    _ = analyzer_instance.analyze() catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    defer diag.releaseTaken(got);
    try testing.expect(std.mem.indexOf(u8, got.message, "Nonpolymorphic reference to abstract type") != null);
}

test "defined assignment declared with procedure is accepted for incompatible intrinsic types" {
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
    const sem = try @import("../../split/api/mod.zig").analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 4), sem.units.len);
}

test "type-bound generic operator and assignment work for abstract polymorphic base" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module abstract_algebra\n" ++
        "  implicit none\n" ++
        "  private\n" ++
        "  public :: rescale\n" ++
        "  public :: object\n" ++
        "  type, abstract :: object\n" ++
        "  contains\n" ++
        "    procedure(assign_interface), deferred :: assign\n" ++
        "    procedure(product_interface), deferred :: product\n" ++
        "    generic :: assignment(=) => assign\n" ++
        "    generic :: operator(*) => product\n" ++
        "  end type\n" ++
        "  abstract interface\n" ++
        "    function product_interface(lhs, rhs) result(product)\n" ++
        "      import :: object\n" ++
        "      class(object), intent(in) :: lhs\n" ++
        "      class(object), allocatable :: product\n" ++
        "      real, intent(in) :: rhs\n" ++
        "    end function\n" ++
        "    subroutine assign_interface(lhs, rhs)\n" ++
        "      import :: object\n" ++
        "      class(object), intent(inout) :: lhs\n" ++
        "      class(object), intent(in) :: rhs\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine rescale(operand, scale)\n" ++
        "    class(object) :: operand\n" ++
        "    real, intent(in) :: scale\n" ++
        "    operand = operand * scale\n" ++
        "    operand = operand%product(scale)\n" ++
        "  end subroutine\n" ++
        "end module\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 1), sem.units.len);
}

test "intrinsic assignment accepts double precision to complex conversion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  implicit none\n" ++
        "  complex*16 :: z\n" ++
        "  double precision :: zero\n" ++
        "  zero = 0.0d0\n" ++
        "  z = zero\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try @import("../../split/api/mod.zig").analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 1), sem.units.len);
}

test "where assignment accepts double precision values for complex array targets" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  implicit none\n" ++
        "  logical :: mask(2)\n" ++
        "  complex*16 :: z(2)\n" ++
        "  double precision :: values(2)\n" ++
        "  mask = .true.\n" ++
        "  values = 1.0d0\n" ++
        "  where (mask) z = values\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try @import("../../split/api/mod.zig").analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 1), sem.units.len);
}

test "where statement rejects non-elemental defined assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m1\n" ++
        "  implicit none\n" ++
        "  type t1\n" ++
        "    integer :: i\n" ++
        "  end type t1\n" ++
        "  interface assignment(=)\n" ++
        "    module procedure s1\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine s1(lhs, rhs)\n" ++
        "    type(t1), intent(out) :: lhs(2)\n" ++
        "    type(t1), intent(in) :: rhs(2)\n" ++
        "    lhs%i = -rhs%i\n" ++
        "  end subroutine s1\n" ++
        "end module m1\n" ++
        "\n" ++
        "program p\n" ++
        "  use m1\n" ++
        "  implicit none\n" ++
        "  type(t1) :: i(2), j(2)\n" ++
        "  i(:)%i = 1\n" ++
        "  where (i(:)%i > 0)\n" ++
        "    j = i\n" ++
        "  end where\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.AssignmentTypeMismatch, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.assignment_type_mismatch.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "Non-ELEMENTAL user-defined assignment in WHERE") != null);
}

test "non-abstract type rejects deferred binding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  abstract interface\n" ++
        "    subroutine intf()\n" ++
        "    end subroutine intf\n" ++
        "  end interface\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure(intf), deferred, nopass :: p\n" ++
        "  end type t\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.DuplicateDeclaration, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.duplicate_declaration.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "is not ABSTRACT") != null);
}

test "type-bound binding target must be a module procedure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure :: p => missing_p\n" ++
        "  end type t\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.UnexpectedTypeDecl, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.duplicate_declaration.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "must be a module procedure") != null);
}

test "type-bound generic binding targets a specific binding without module procedure rejection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure :: p => impl\n" ++
        "    generic :: g => p\n" ++
        "  end type t\n" ++
        "  interface\n" ++
        "    subroutine impl(this)\n" ++
        "      import t\n" ++
        "      class(t), intent(inout) :: this\n" ++
        "    end subroutine impl\n" ++
        "  end interface\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "type-bound generic binding rejects generic targets and missing specifics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    generic :: f => g\n" ++
        "    generic :: g => h\n" ++
        "  end type t\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.UnexpectedTypeDecl, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "must target a specific binding") != null or
        std.mem.indexOf(u8, got.message, "Undefined specific binding") != null);
}

test "type-bound generic family ambiguity follows specific PASS positions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type t\n" ++
        "  contains\n" ++
        "    procedure, pass(this) :: sub1\n" ++
        "    procedure, pass(this) :: sub2\n" ++
        "    generic :: gen => sub1, sub2\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  subroutine sub1(x, this)\n" ++
        "    integer :: x\n" ++
        "    class(t) :: this\n" ++
        "  end subroutine sub1\n" ++
        "  subroutine sub2(this, y)\n" ++
        "    class(t) :: this\n" ++
        "    integer :: y\n" ++
        "  end subroutine sub2\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.DuplicateDeclaration, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.duplicate_declaration.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "are ambiguous") != null);
}

test "type-bound PASS(name) call uses the declared passed-object position" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure, pass(a) :: allocate_mnnz => impl\n" ++
        "    generic :: allocate => allocate_mnnz\n" ++
        "  end type t\n" ++
        "  interface\n" ++
        "    subroutine impl(m, n, a, nz)\n" ++
        "      import t\n" ++
        "      integer, intent(in) :: m, n\n" ++
        "      class(t), intent(inout) :: a\n" ++
        "      integer, intent(in), optional :: nz\n" ++
        "    end subroutine impl\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine runit()\n" ++
        "    type(t) :: x\n" ++
        "    call x%allocate(1, 2, nz=3)\n" ++
        "  end subroutine runit\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "typed dummy procedure reference resolves as function call in expression context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine test_d(fn, val, res)\n" ++
        "  double precision fn\n" ++
        "  double precision val, res\n" ++
        "  print *, fn(val), res\n" ++
        "end subroutine\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "type-bound override must also be PURE" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: supert\n" ++
        "  contains\n" ++
        "    procedure, nopass :: p => pure_impl\n" ++
        "  end type supert\n" ++
        "  type, extends(supert) :: t\n" ++
        "  contains\n" ++
        "    procedure, nopass :: p => impure_impl\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  pure subroutine pure_impl()\n" ++
        "  end subroutine pure_impl\n" ++
        "  subroutine impure_impl()\n" ++
        "  end subroutine impure_impl\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.DuplicateDeclaration, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "must also be PURE") != null);
}

test "type-bound override must not reduce visibility" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: supert\n" ++
        "  contains\n" ++
        "    procedure, nopass, public :: p => impl\n" ++
        "  end type supert\n" ++
        "  type, extends(supert) :: t\n" ++
        "  contains\n" ++
        "    procedure, nopass, private :: p => impl\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  subroutine impl()\n" ++
        "  end subroutine impl\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.DuplicateDeclaration, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "must not be PRIVATE") != null);
}

test "type-bound override preserves corresponding dummy names" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: supert\n" ++
        "  contains\n" ++
        "    procedure, pass :: p => super_impl\n" ++
        "  end type supert\n" ++
        "  type, extends(supert) :: t\n" ++
        "  contains\n" ++
        "    procedure, pass :: p => sub_impl\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  subroutine super_impl(me, a)\n" ++
        "    class(supert) :: me\n" ++
        "    integer :: a\n" ++
        "  end subroutine super_impl\n" ++
        "  subroutine sub_impl(me, x)\n" ++
        "    class(t) :: me\n" ++
        "    integer :: x\n" ++
        "  end subroutine sub_impl\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.DuplicateDeclaration, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "should be named 'a'") != null);
}

test "explicit scalar dummy with arguments is not treated as a function call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module t\n" ++
        "  type nc\n" ++
        "  contains\n" ++
        "    procedure :: encm => em\n" ++
        "  end type nc\n" ++
        "contains\n" ++
        "  double precision function em(self)\n" ++
        "    type(nc) :: self\n" ++
        "    em = 0.\n" ++
        "  end function em\n" ++
        "  double precision function cem(c)\n" ++
        "    type(nc) :: c\n" ++
        "    cem = c(i)%encm()\n" ++
        "  end function cem\n" ++
        "end module t\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.InvalidSubscript, split_api.analyzeProgram(arena.allocator(), program));
}

test "derived component type must be declared before use" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "type a\n" ++
        "  type(b), pointer :: c\n" ++
        "end type\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.UnexpectedTypeDecl, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    defer diag.releaseTaken(got);
    try testing.expect(std.mem.indexOf(u8, got.message, "has not been declared") != null);
}

test "deferred binding interface name may not be generic or statement function or intrinsic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "interface gen\n" ++
        "  procedure gen\n" ++
        "end interface\n" ++
        "type, abstract :: t1\n" ++
        "contains\n" ++
        "  procedure(gen), deferred, nopass :: p1\n" ++
        "  procedure(gen2), deferred, nopass :: p2\n" ++
        "end type\n" ++
        "type, abstract :: t2\n" ++
        "contains\n" ++
        "  procedure(sf), deferred, nopass :: p3\n" ++
        "end type\n" ++
        "type, abstract :: t3\n" ++
        "contains\n" ++
        "  procedure(char), deferred, nopass :: p4\n" ++
        "end type\n" ++
        "interface gen2\n" ++
        "  procedure gen\n" ++
        "end interface\n" ++
        "sf(x) = x**2\n" ++
        "contains\n" ++
        "  subroutine gen\n" ++
        "  end subroutine gen\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag) catch {};
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);
    const third = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(third);

    try testing.expect(std.mem.indexOf(u8, first.message, "may not be generic") != null);
    try testing.expect(std.mem.indexOf(u8, second.message, "may not be a statement function") != null);
    try testing.expect(std.mem.indexOf(u8, third.message, "Intrinsic procedure") != null);
}

test "type-bound PASS dummy must not be pointer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure, pass :: p\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  subroutine p(me)\n" ++
        "    class(t), pointer, intent(in) :: me\n" ++
        "  end subroutine p\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    try testing.expectError(error.DuplicateDeclaration, split_api.analyzeProgram(arena.allocator(), program));
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.duplicate_declaration.code));
    try testing.expect(std.mem.indexOf(u8, got.message, "must not be POINTER") != null);
}

test "pure procedure rejects polymorphic intent(out) dummy with impure finalizer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type t\n" ++
        "  contains\n" ++
        "    final :: fnl\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  impure subroutine fnl(x)\n" ++
        "    type(t) :: x\n" ++
        "    print *, \"finalized!\"\n" ++
        "  end subroutine\n" ++
        "end\n" ++
        "program test\n" ++
        "  use m\n" ++
        "  type(t) :: x\n" ++
        "  call foo(x)\n" ++
        "contains\n" ++
        "  pure subroutine foo(x)\n" ++
        "    class(t), intent(out) :: x\n" ++
        "  end subroutine\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag) catch {};
    const got = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(got);
    try testing.expect(std.mem.indexOf(u8, got.message, "may not be polymorphic") != null);
}

test "data actual checking preserves later rank mismatch after earlier call arity error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "function a(b)\n" ++
        "  real :: b\n" ++
        "  b = 2.0\n" ++
        "  a = 1.0\n" ++
        "end function\n" ++
        "\n" ++
        "program gg\n" ++
        "  real :: h\n" ++
        "  character (5) :: chr = 'hello'\n" ++
        "  h = a()\n" ++
        "  call test([chr])\n" ++
        "end program gg\n" ++
        "\n" ++
        "subroutine test(a)\n" ++
        "  character (5) :: a\n" ++
        "end subroutine test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag) catch {};
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);

    try testing.expect(std.mem.indexOf(u8, first.message, "Missing actual argument") != null);
    try testing.expect(std.mem.indexOf(u8, second.message, "Rank mismatch in argument") != null);
}

test "keyword actual without visible interface requires explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "external bar\n" ++
        "call bar(a=5)\n" ++
        "call foo(a=5)\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag) catch {};
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);

    try testing.expectEqualStrings(catalog.semantic.explicit_interface_required.code, first.code);
    try testing.expectEqualStrings(catalog.semantic.explicit_interface_required.code, second.code);
}

test "contained procedure lookup does not collide across different owners" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none\n" ++
        "integer :: i(10)\n" ++
        "call foo(i(8))\n" ++
        "contains\n" ++
        "  subroutine foo(a)\n" ++
        "    integer :: a(4)\n" ++
        "  end subroutine foo\n" ++
        "end\n" ++
        "\n" ++
        "subroutine test()\n" ++
        "  implicit none\n" ++
        "  character(len=5), pointer :: c\n" ++
        "  call foo(c)\n" ++
        "contains\n" ++
        "  subroutine foo(a)\n" ++
        "    character(len=3), pointer :: a\n" ++
        "  end subroutine foo\n" ++
        "end subroutine test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    _ = split_api.analyzeProgramWithDiagnostics(arena.allocator(), program, &diag_bag) catch {};
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);

    try testing.expect(std.mem.indexOf(u8, first.message, "Rank mismatch in argument") != null);
    try testing.expect(std.mem.indexOf(u8, second.message, "Character length mismatch") != null);
}
