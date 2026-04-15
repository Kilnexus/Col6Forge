const common = @import("common.zig");
const std = common.std;
const ast = common.ast;
const input = common.input;
const catalog = common.catalog;
const codegen_diag = common.codegen_diag;
const fixed_form = common.fixed_form;
const free_form = common.free_form;
const parser = common.parser;
const split_api = common.split_api;
const codegen = common.codegen;
const emitModule = common.emitModule;
const emitModuleToWriter = common.emitModuleToWriter;
const setCodegenDiagForUnit = common.setCodegenDiagForUnit;
const makeIdentExpr = common.makeIdentExpr;
const makeLiteralExpr = common.makeLiteralExpr;
const makeLocalArraySymbol = common.makeLocalArraySymbol;
const makeLocalScalarSymbol = common.makeLocalScalarSymbol;
const makeLocalCharacterSymbol = common.makeLocalCharacterSymbol;
const makeIntrinsicFunctionSymbol = common.makeIntrinsicFunctionSymbol;
const makeSourceRef = common.makeSourceRef;
test "emitModuleToWriter emits module header and empty function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unit = input.ProgramUnit{
        .kind = .subroutine,
        .name = "UNIT",
        .args = &[_][]const u8{},
        .decls = try a.alloc(input.Decl, 0),
        .stmts = try a.alloc(input.Stmt, 0),
    };
    const units = try a.alloc(input.ProgramUnit, 1);
    units[0] = unit;
    const program = input.Program{ .units = units };

    const sem_unit = input.sema.SemanticUnit{
        .name = "UNIT",
        .kind = .subroutine,
        .symbols = try a.alloc(input.sema.Symbol, 0),
        .implicit_rules = try a.alloc(input.sema.ImplicitRule, 0),
        .resolved_refs = try a.alloc(input.sema.ResolvedRef, 0),
    };
    const sem_units = try a.alloc(input.sema.SemanticUnit, 1);
    sem_units[0] = sem_unit;
    const sem_prog = input.sema.SemanticProgram{ .units = sem_units };

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "test.f", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "source_filename = \"test.f\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "define void @unit_") != null);
}

test "emitModuleToWriter adds hidden descriptor args for deferred-shape dummy arrays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lower = try a.create(input.Expr);
    lower.* = .{ .literal = .{ .kind = .integer, .text = "1" } };
    const assumed = try a.create(input.Expr);
    assumed.* = .{ .literal = .{ .kind = .assumed_size, .text = "*" } };
    const deferred_dim = try a.create(input.Expr);
    deferred_dim.* = .{ .dim_range = .{ .lower = lower, .upper = assumed, .stride = null, .assumed_shape = true } };
    const dims = try a.alloc(*input.Expr, 1);
    dims[0] = deferred_dim;

    const unit = input.ProgramUnit{
        .kind = .subroutine,
        .name = "S",
        .args = &[_][]const u8{"A"},
        .decls = try a.alloc(input.Decl, 0),
        .stmts = try a.alloc(input.Stmt, 0),
    };
    const units = try a.alloc(input.ProgramUnit, 1);
    units[0] = unit;
    const program = input.Program{ .units = units };

    const symbols = try a.alloc(input.sema.Symbol, 1);
    symbols[0] = blk: {
        var sym = input.sema.Symbol.init(
            "A",
            input.sema.TypeSpec.fromResolvedKind(.integer, .integer, null),
            dims,
            .variable,
            .dummy,
        );
        sym.type_explicit = true;
        break :blk sym;
    };
    const sem_unit = input.sema.SemanticUnit{
        .name = "S",
        .kind = .subroutine,
        .symbols = symbols,
        .implicit_rules = try a.alloc(input.sema.ImplicitRule, 0),
        .resolved_refs = try a.alloc(input.sema.ResolvedRef, 0),
    };
    const sem_units = try a.alloc(input.sema.SemanticUnit, 1);
    sem_units[0] = sem_unit;
    const sem_prog = input.sema.SemanticProgram{ .units = sem_units };

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "dummy_desc.f", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "define void @s_(ptr %arg0, ptr %arg1, ptr %arg2)") != null);
}

test "emitModuleToWriter supports CHARACTER allocate type-spec for deferred-length allocatable scalar" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "      MODULE X\n" ++
        "      CONTAINS\n" ++
        "      PURE FUNCTION FOO() RESULT(RES)\n" ++
        "      CHARACTER(LEN=:), ALLOCATABLE :: RES\n" ++
        "      INTEGER BAR\n" ++
        "      BAR = 1\n" ++
        "      ALLOCATE(CHARACTER(BAR) :: RES)\n" ++
        "      END FUNCTION FOO\n" ++
        "      END MODULE X\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "char_alloc_typespec.f", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "call ptr @malloc") != null);
}

test "emitModuleToWriter supports allocatable unlimited polymorphic components" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  type :: any_vector\n" ++
        "    class(*), allocatable :: x(:)\n" ++
        "  end type any_vector\n" ++
        "  type(any_vector) :: a\n" ++
        "  integer :: values(2) = [1, 2]\n" ++
        "  allocate(a%x(2), source=values)\n" ++
        "  deallocate(a%x)\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "poly_alloc_component.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "call ptr @malloc") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call void @free") != null);
}

test "emitModuleToWriter prefers local RESULT symbol over host-associated duplicate name" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  type, abstract :: foo_t\n" ++
        "  end type foo_t\n" ++
        "  type, extends(foo_t) :: foo_a_t\n" ++
        "    real(8), allocatable :: a(:)\n" ++
        "  end type foo_a_t\n" ++
        "  type, extends(foo_t) :: bar_t\n" ++
        "    class(foo_t), allocatable :: f\n" ++
        "  end type bar_t\n" ++
        "  type(bar_t) :: b(2)\n" ++
        "  integer :: i\n" ++
        "  do i = 1, 2\n" ++
        "    b(i) = func_bar(3)\n" ++
        "  end do\n" ++
        "contains\n" ++
        "  function func_bar(n) result(b)\n" ++
        "    integer :: n\n" ++
        "    type(bar_t) :: b\n" ++
        "    allocate(b%f, source=func_foo(n))\n" ++
        "  end function func_bar\n" ++
        "  function func_foo(n) result(f)\n" ++
        "    integer :: n\n" ++
        "    class(foo_t), allocatable :: f\n" ++
        "    allocate(f, source=func_foo_a(n))\n" ++
        "  end function func_foo\n" ++
        "  function func_foo_a(n) result(f)\n" ++
        "    integer :: n\n" ++
        "    type(foo_a_t) :: f\n" ++
        "    allocate(f%a(n))\n" ++
        "  end function func_foo_a\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "result_shadow_host.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "define ptr @proc_main__func_bar_") != null);
}

test "emitModuleToWriter supports deferred-length allocatable character components in assignment and substring" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  type foo\n" ++
        "    character(len=:), allocatable :: x\n" ++
        "  end type foo\n" ++
        "  type(foo) :: a\n" ++
        "  a%x = 'asdf'\n" ++
        "  a%x = a%x(2:3)\n" ++
        "end program main\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "char_alloc_component_assign.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "load i64") != null);
}

test "emitModuleToWriter resolves derived layout dependencies across imported module preludes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module foo_base_mod\n" ++
        "  type foo_dmt\n" ++
        "    integer :: i\n" ++
        "  end type foo_dmt\n" ++
        "  type foo_cdt\n" ++
        "    integer :: j\n" ++
        "  end type foo_cdt\n" ++
        "end module foo_base_mod\n" ++
        "module bar_prt\n" ++
        "  use foo_base_mod, only : foo_dmt, foo_cdt\n" ++
        "  type bar_dbprt\n" ++
        "    type(foo_dmt), allocatable :: av(:)\n" ++
        "    type(foo_cdt) :: cd\n" ++
        "  end type bar_dbprt\n" ++
        "  type bar_dprt\n" ++
        "    type(bar_dbprt), allocatable :: bpv(:)\n" ++
        "  end type bar_dprt\n" ++
        "end module bar_prt\n" ++
        "module foo_pr_mod\n" ++
        "  use bar_prt, foo_dbprt => bar_dbprt, foo_dprt => bar_dprt\n" ++
        "end module foo_pr_mod\n" ++
        "subroutine foo_sub(pr)\n" ++
        "  use foo_base_mod\n" ++
        "  use foo_pr_mod\n" ++
        "  type(foo_dprt), intent(in) :: pr\n" ++
        "end subroutine foo_sub\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "derived_prelude_layouts.f90", .{});
}

test "emitModuleToWriter supports use-only imported recursive derived pointer layouts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module module_foo\n" ++
        "  type :: foo_node\n" ++
        "    type(foo_node_private), pointer :: p\n" ++
        "  end type\n" ++
        "  type :: foo_node_private\n" ++
        "    type(foo_node), dimension(-1:1) :: link\n" ++
        "  end type\n" ++
        "  type :: foo\n" ++
        "    type(foo_node) :: root\n" ++
        "  end type\n" ++
        "end module module_foo\n" ++
        "function foo_insert()\n" ++
        "  use module_foo, only: foo, foo_node\n" ++
        "  integer :: foo_insert\n" ++
        "  type(foo_node) :: parent, current\n" ++
        "  integer :: cmp\n" ++
        "  parent = current\n" ++
        "  current = current%p%link(cmp)\n" ++
        "end function foo_insert\n" ++
        "function foo_count()\n" ++
        "  use module_foo, only: foo\n" ++
        "  integer :: foo_count\n" ++
        "end function foo_count\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "recursive_use_only_layouts.f90", .{});
}

test "emitModuleToWriter lowers fixed-shape entry-expanded array functions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "interface\n" ++
        "  function bad_stuff(n)\n" ++
        "    integer :: bad_stuff(2)\n" ++
        "    integer :: n(2)\n" ++
        "  end function bad_stuff\n" ++
        "  recursive function rec_stuff(n) result(tmp)\n" ++
        "    integer :: n(2), tmp(2)\n" ++
        "  end function rec_stuff\n" ++
        "end interface\n" ++
        "  integer :: res(2)\n" ++
        "  res = bad_stuff((/-19,-30/))\n" ++
        "end program test\n" ++
        "recursive function bad_stuff(n)\n" ++
        "  integer :: bad_stuff(2)\n" ++
        "  integer :: n(2), tmp(2), ent = 0, sent = 0\n" ++
        "  save ent, sent\n" ++
        "  ent = -1\n" ++
        "  entry rec_stuff(n) result(tmp)\n" ++
        "  if (ent == -1) then\n" ++
        "    sent = ent\n" ++
        "    ent = 0\n" ++
        "  end if\n" ++
        "  ent = ent + 1\n" ++
        "  tmp = 1\n" ++
        "  if (maxval(n) < 5) then\n" ++
        "    tmp = tmp + rec_stuff(n+1)\n" ++
        "    ent = ent - 1\n" ++
        "  endif\n" ++
        "  if (ent == 1) then\n" ++
        "    if (sent == -1) then\n" ++
        "      bad_stuff = tmp + bad_stuff(1)\n" ++
        "    end if\n" ++
        "    ent = 0\n" ++
        "    sent = 0\n" ++
        "  end if\n" ++
        "end function bad_stuff\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "entry_array_function.f90", .{});
}

test "emitModuleToWriter supports declarator initializer with implied-do structure constructor array" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "type dd\n" ++
        "  integer :: i\n" ++
        "end type dd\n" ++
        "type(dd) :: x(2) = (/(dd(i), i = 1, 2)/)\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "decl_init_struct_ctor_implied_do.f90", .{});
}

test "emitModuleToWriter lowers nested implied-do whole-array assignment with loops" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  implicit none\n" ++
        "  integer, parameter :: n = 4\n" ++
        "  integer :: i, j\n" ++
        "  integer :: vect(n * n)\n" ++
        "  vect(:) = (/ (((i + j + 3), i = 1, n), j = 1, n) /)\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "nested_implied_do_whole_array_assign.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "arr_generated_head") != null);
}

test "emitModuleToWriter does not treat type-bound function calls as whole-array component copies" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module class_t\n" ++
        "  type :: tx\n" ++
        "    integer, allocatable :: i(:)\n" ++
        "  end type tx\n" ++
        "  type :: t\n" ++
        "    type(tx), pointer :: x\n" ++
        "  contains\n" ++
        "    procedure :: calc\n" ++
        "    procedure :: find_x\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  subroutine calc(this)\n" ++
        "    class(t), target :: this\n" ++
        "    this%x = this%find_x()\n" ++
        "  end subroutine calc\n" ++
        "  function find_x(this)\n" ++
        "    class(t), intent(in) :: this\n" ++
        "    type(tx), pointer :: find_x\n" ++
        "    find_x => null()\n" ++
        "  end function find_x\n" ++
        "end module class_t\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "typebound_whole_array_call_assign.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "call ptr @class_t__find_x") != null);
    try testing.expect(std.mem.indexOf(u8, output, "llvm.memmove") == null);
}

test "emitModuleToWriter lowers direct array-actual assignment for pointer array target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module mod1\n" ++
        "  type t1\n" ++
        "    real :: f1\n" ++
        "  end type t1\n" ++
        "  type t2\n" ++
        "    type(t1), pointer :: f2(:)\n" ++
        "  end type t2\n" ++
        "end module mod1\n" ++
        "module mod2\n" ++
        "  use mod1\n" ++
        "  type(t1), pointer, save :: v(:)\n" ++
        "contains\n" ++
        "  subroutine foo(x)\n" ++
        "    use mod1\n" ++
        "    implicit none\n" ++
        "    type(t2) :: x\n" ++
        "    v = x%f2(:)\n" ++
        "  end subroutine foo\n" ++
        "end module mod2\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "direct_array_actual_pointer_assign.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "section_array_assign_body") != null);
    try testing.expect(std.mem.indexOf(u8, output, "load ptr, ptr @save_mod_mod2__foo_v") != null);
}

test "emitModuleToWriter preserves pointer declarator initializer semantics for null()" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module factory_pattern\n" ++
        "  type, abstract :: connection\n" ++
        "  end type connection\n" ++
        "end module factory_pattern\n" ++
        "program main\n" ++
        "  use factory_pattern\n" ++
        "  implicit none\n" ++
        "  class(connection), pointer :: db_connect => null()\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "pointer_decl_null_init.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "store ptr null") != null);
}

test "emitModuleToWriter supports SIZE over whole-array class component in specification expressions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module array\n" ++
        "  type :: t_array\n" ++
        "    real, dimension(10) :: coeff\n" ++
        "  contains\n" ++
        "    procedure :: get_coeff\n" ++
        "  end type t_array\n" ++
        "contains\n" ++
        "  function get_coeff(self) result(coeff)\n" ++
        "    class(t_array), intent(in) :: self\n" ++
        "    real, dimension(size(self%coeff)) :: coeff\n" ++
        "  end function get_coeff\n" ++
        "end module array\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "size_component_spec_expr.f03", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "alloca [10 x float]") != null);
}

test "emitModuleToWriter supports SIZE with KIND parameter on array expressions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test_64\n" ++
        "  implicit none\n" ++
        "  integer, parameter :: long = selected_int_kind(18)\n" ++
        "  integer, dimension(:), allocatable :: array\n" ++
        "  print *, size(array, kind=long)\n" ++
        "end program test_64\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "size_kind_arg.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "i64") != null);
}

test "emitModuleToWriter lowers intrinsic procedure actuals through wrappers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine test_d(fn, val, res)\n" ++
        "  double precision fn\n" ++
        "  double precision val, res\n" ++
        "  print *, fn(val), res\n" ++
        "end subroutine\n" ++
        "subroutine test_c(fn, val, res)\n" ++
        "  complex fn\n" ++
        "  complex val, res\n" ++
        "  print *, fn(val), res\n" ++
        "end subroutine\n" ++
        "program specifics\n" ++
        "  intrinsic dcos\n" ++
        "  intrinsic conjg\n" ++
        "  call test_d(dcos, 1d0, dcos(1d0))\n" ++
        "  call test_c(conjg, (1.0,1.0), conjg((1.0,1.0)))\n" ++
        "end program\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "intrinsic_proc_actuals.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "define double @__cf_intrinsic_dcos") != null);
    try testing.expect(std.mem.indexOf(u8, output, "define { float, float } @__cf_intrinsic_conjg") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ptr @__cf_intrinsic_dcos") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ptr @__cf_intrinsic_conjg") != null);
}

test "emitModuleToWriter lowers intrinsic SIN procedure pointer targets through wrappers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "contains\n" ++
        "  function f()\n" ++
        "    intrinsic :: sin\n" ++
        "    abstract interface\n" ++
        "      pure real function sin_interf(x)\n" ++
        "        real, intent(in) :: x\n" ++
        "      end function sin_interf\n" ++
        "    end interface\n" ++
        "    procedure(sin_interf), pointer :: f\n" ++
        "    f => sin\n" ++
        "  end function f\n" ++
        "end\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_sin_wrapper.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "define float @__cf_intrinsic_sin") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ptr @__cf_intrinsic_sin") != null);
}

test "emitModuleToWriter lowers module and contained procedure pointer targets" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module myfortran_binding\n" ++
        "  implicit none\n" ++
        "  procedure(error_stop), pointer :: error_handler\n" ++
        "contains\n" ++
        "  logical function myfortran_shutdown()\n" ++
        "    call error_handler()\n" ++
        "  end function myfortran_shutdown\n" ++
        "  subroutine error_stop()\n" ++
        "  end subroutine error_stop\n" ++
        "end module myfortran_binding\n" ++
        "program test\n" ++
        "  use myfortran_binding\n" ++
        "  procedure(f), pointer :: pf\n" ++
        "  pf => f\n" ++
        "  error_handler => error_stop\n" ++
        "contains\n" ++
        "  pure subroutine f(x, y)\n" ++
        "    real, intent(in) :: x\n" ++
        "    real, intent(out) :: y\n" ++
        "    y = sin(x)\n" ++
        "  end subroutine f\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_targets.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "ptr @mod_myfortran_binding__error_stop_") != null);
    try testing.expect(std.mem.indexOf(u8, output, "ptr @proc_test__f_") != null);
}

test "emitModuleToWriter lowers procedure pointer assignment followed by procedure pointer call" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "  implicit none\n" ++
        "  integer :: i\n" ++
        "  real :: s(4)\n" ++
        "  procedure(f), pointer :: pf\n" ++
        "  pf => f\n" ++
        "  do i = 1, 4\n" ++
        "    call pf(real(i), s(i))\n" ++
        "  end do\n" ++
        "contains\n" ++
        "  pure subroutine f(x, y)\n" ++
        "    real, intent(in) :: x\n" ++
        "    real, intent(out) :: y\n" ++
        "    y = sin(x)\n" ++
        "  end subroutine f\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "proc_ptr_call_after_assign.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "store ptr @proc_test__f_") != null);
    try testing.expect(std.mem.indexOf(u8, output, "load ptr, ptr %t0") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call void %t") != null);
}

test "emitModuleToWriter keeps dummy procedure arguments as indirect calls" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "integer function apply(fn, i)\n" ++
        "  integer fn, i\n" ++
        "  apply = fn(i) + 1\n" ++
        "end function apply\n" ++
        "integer function inc(i)\n" ++
        "  integer i\n" ++
        "  inc = i + 1\n" ++
        "end function inc\n" ++
        "program test\n" ++
        "  print *, apply(inc, 5)\n" ++
        "end program test\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "dummy_proc_actual_indirect.f", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "define i32 @apply_(ptr %arg0, ptr %arg1)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call i32 %arg0(") != null);
    try testing.expect(std.mem.indexOf(u8, output, "call i32 @inc_(") == null);
}

test "emitModuleToWriter lowers zero-argument type-bound function calls from used modules without crashing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module a_mod\n" ++
        "  implicit none\n" ++
        "  type :: a_type\n" ++
        "    integer :: size = 1\n" ++
        "  contains\n" ++
        "    procedure :: sizeReturn\n" ++
        "  end type a_type\n" ++
        "contains\n" ++
        "  function sizeReturn(this)\n" ++
        "    implicit none\n" ++
        "    class(a_type) :: this\n" ++
        "    integer :: sizeReturn\n" ++
        "    sizeReturn = this%size\n" ++
        "  end function sizeReturn\n" ++
        "end module a_mod\n" ++
        "module b_mod\n" ++
        "  implicit none\n" ++
        "  type :: b_type\n" ++
        "    integer :: size = 2\n" ++
        "  contains\n" ++
        "    procedure :: sizeReturn\n" ++
        "  end type b_type\n" ++
        "contains\n" ++
        "  function sizeReturn(this)\n" ++
        "    implicit none\n" ++
        "    class(b_type) :: this\n" ++
        "    integer :: sizeReturn\n" ++
        "    sizeReturn = this%size\n" ++
        "  end function sizeReturn\n" ++
        "end module b_mod\n" ++
        "program main\n" ++
        "contains\n" ++
        "  subroutine test1\n" ++
        "    use a_mod\n" ++
        "    use b_mod\n" ++
        "    implicit none\n" ++
        "    type(a_type) :: a_inst\n" ++
        "    type(b_type) :: b_inst\n" ++
        "    print *, a_inst%sizeReturn()\n" ++
        "    print *, b_inst%sizeReturn()\n" ++
        "  end subroutine test1\n" ++
        "  subroutine test2\n" ++
        "    use b_mod\n" ++
        "    use a_mod\n" ++
        "    implicit none\n" ++
        "    type(a_type) :: a_inst\n" ++
        "    type(b_type) :: b_inst\n" ++
        "    print *, a_inst%sizeReturn()\n" ++
        "    print *, b_inst%sizeReturn()\n" ++
        "  end subroutine test2\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "typebound_zero_arg_used_module_print.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "@a_mod__sizeReturn") != null);
    try testing.expect(std.mem.indexOf(u8, output, "@b_mod__sizeReturn") != null);
}

test "emitModuleToWriter lowers automatic character length from LEN(dummy)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine lecligne(ligne)\n" ++
        "  character(len=*), intent(out) :: ligne\n" ++
        "  character(len=len(ligne)) :: comment\n" ++
        "  comment = ligne\n" ++
        "end subroutine lecligne\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem_prog = try split_api.analyzeProgram(arena.allocator(), program);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = buffer.writer();
    try emitModuleToWriter(&writer, allocator, program, sem_prog, "spec_expr_2.f90", .{});

    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "alloca i8, i64") != null);
}


