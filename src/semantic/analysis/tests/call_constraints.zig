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

test "type-bound function called by CALL reports should be a SUBROUTINE" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: t\n" ++
        "  contains\n" ++
        "    procedure :: f\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  integer function f(this)\n" ++
        "    class(t) :: this\n" ++
        "    f = 1\n" ++
        "  end function f\n" ++
        "  subroutine s(obj)\n" ++
        "    class(t) :: obj\n" ++
        "    call obj%f\n" ++
        "  end subroutine s\n" ++
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
    try testing.expectEqualStrings("should be a SUBROUTINE", got.message);
}

test "parent component selector supports type-bound CALL" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: middle\n" ++
        "  contains\n" ++
        "    procedure :: p\n" ++
        "  end type middle\n" ++
        "  type, extends(middle) :: bottom\n" ++
        "  end type bottom\n" ++
        "contains\n" ++
        "  subroutine p(this)\n" ++
        "    class(middle) :: this\n" ++
        "  end subroutine p\n" ++
        "  subroutine s(obj)\n" ++
        "    class(bottom) :: obj\n" ++
        "    call obj%middle%p\n" ++
        "  end subroutine s\n" ++
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
    _ = try analyzer_instance.analyze();
    try testing.expect(diag.take() == null);
}

test "polymorphic actual requires explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type :: t\n" ++
        "  end type t\n" ++
        "contains\n" ++
        "  subroutine s(obj)\n" ++
        "    class(t) :: obj\n" ++
        "    call missing_proc(obj)\n" ++
        "  end subroutine s\n" ++
        "end module m\n";
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
    try testing.expectEqualStrings(catalog.semantic.explicit_interface_required.code, got.code);
}

test "assumed-shape dummy without visible interface requires explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  real, dimension(2) :: a\n" ++
        "  call foo(a)\n" ++
        "end program main\n" ++
        "subroutine foo(a)\n" ++
        "  real, dimension(:) :: a\n" ++
        "end subroutine foo\n";
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
    try testing.expectEqualStrings(catalog.semantic.explicit_interface_required.code, got.code);
}

test "optional dummy without visible interface requires explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program main\n" ++
        "  real :: a\n" ++
        "  call sub(a)\n" ++
        "end program main\n" ++
        "subroutine sub(a, i)\n" ++
        "  real :: a\n" ++
        "  integer, optional :: i\n" ++
        "end subroutine sub\n";
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
    try testing.expectEqualStrings(catalog.semantic.explicit_interface_required.code, got.code);
}

test "intrinsic call with keyword actuals does not require explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "function c_f_string(cptr) result(fptr)\n" ++
        "  use iso_c_binding\n" ++
        "  implicit none\n" ++
        "  type(c_ptr), intent(in) :: cptr\n" ++
        "  character(kind=c_char), dimension(:), pointer :: fptr\n" ++
        "  interface\n" ++
        "     function strlen(string) result(len) bind(c,name=\"strlen\")\n" ++
        "       import\n" ++
        "       type(c_ptr), value :: string\n" ++
        "       integer(c_int) :: len\n" ++
        "     end function strlen\n" ++
        "  end interface\n" ++
        "  call c_f_pointer(fptr=fptr, cptr=cptr, shape=[strlen(cptr)])\n" ++
        "end function c_f_string\n";
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
    try analyzer_instance.analyze();
    try testing.expect(diag.take() == null);
}

test "move_alloc intrinsic call diagnoses duplicate stat keyword instead of explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  integer, allocatable :: i, o\n" ++
        "  integer :: st, s2\n" ++
        "  call move_alloc(i, o, stat=st, stat=s2)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

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
    try testing.expectEqualStrings(catalog.semantic.invalid_intrinsic_keyword_argument.code, got.code);
    try testing.expect(std.mem.indexOf(u8, got.message, "Keyword 'stat'") != null);
}

test "no_arg_check dummy is preserved into intrinsic actual restrictions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s(a)\n" ++
        "  !GCC$ ATTRIBUTES NO_ARG_CHECK :: a\n" ++
        "  integer :: a\n" ++
        "  print *, transfer(a, 1)\n" ++
        "end subroutine s\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

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
    try testing.expect(std.mem.indexOf(u8, got.message, "NO_ARG_CHECK") != null);
}

test "allocatable polymorphic dummy enforces polymorphic allocatable same declared type actuals" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none\n" ++
        "type :: base\n" ++
        "end type\n" ++
        "type, extends(base) :: ext\n" ++
        "end type\n" ++
        "type(base), allocatable :: a\n" ++
        "class(base), pointer :: b\n" ++
        "class(ext), allocatable :: c\n" ++
        "call test(a)\n" ++
        "call test(b)\n" ++
        "call test(c)\n" ++
        "contains\n" ++
        "  subroutine test(arg)\n" ++
        "    class(base), allocatable :: arg\n" ++
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

    try testing.expect(diag_bag.count() >= 3);
    try testing.expect(std.mem.indexOf(u8, diag_bag.items[0].message, "must be polymorphic") != null);
    try testing.expect(std.mem.indexOf(u8, diag_bag.items[1].message, "must be ALLOCATABLE") != null);
    try testing.expect(std.mem.indexOf(u8, diag_bag.items[2].message, "same declared type") != null);
}

test "TRANSFER rejects mold with zero storage size" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type t\n" ++
        "  end type\n" ++
        "  type(t) :: x(2)\n" ++
        "  print *, transfer(1, x)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

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
    try testing.expect(std.mem.indexOf(u8, got.message, "shall not have storage size 0") != null);
}

test "assumed_type_5 third unit keeps NO_ARG_CHECK on analyzed symbol" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/assumed_type_5.f90", 1024 * 1024);
    defer allocator.free(source);
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_parameters = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());

    var unit = program.units[2];
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
    const a_idx = analyzer_instance.ctx.findSymbolIndex("a") orelse return error.TestExpectedEqual;
    try testing.expect(analyzer_instance.ctx.symbols.items[a_idx].no_arg_check);
}

test "assumed_type_5 third unit emits NO_ARG_CHECK diagnostic in isolation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/assumed_type_5.f90", 1024 * 1024);
    defer allocator.free(source);
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_parameters = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());
    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    var unit = program.units[2];
    var analyzer_instance = UnitAnalyzer.initWithDiagnostics(
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
        &diag_bag,
    );
    _ = analyzer_instance.analyze() catch {};
    const items = diag_bag.items();
    try testing.expect(items.len != 0);
    var saw_no_arg_check = false;
    for (items) |item| {
        if (std.mem.indexOf(u8, item.message, "NO_ARG_CHECK") != null) saw_no_arg_check = true;
    }
    try testing.expect(saw_no_arg_check);
}

test "assumed_type_5 full program analysis includes NO_ARG_CHECK diagnostics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/assumed_type_5.f90", 1024 * 1024);
    defer allocator.free(source);
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

    const items = diag_bag.items();
    var saw_no_arg_check = false;
    for (items) |item| {
        if (std.mem.indexOf(u8, item.message, "NO_ARG_CHECK") != null) saw_no_arg_check = true;
    }
    try testing.expect(saw_no_arg_check);
}

test "move_alloc intrinsic call rejects INTENT(IN) allocatable from-argument" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s(from, to)\n" ++
        "  integer, allocatable, intent(in) :: from\n" ++
        "  integer, allocatable :: to\n" ++
        "  call move_alloc(from, to)\n" ++
        "end subroutine s\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);

    var diag_bag = diag.Bag.init(testing.allocator);
    defer diag_bag.deinit();

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(testing.allocator);
    defer known_function_type_specs.deinit();
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(testing.allocator);
    defer known_procedure_sigs.deinit();
    var known_host_parameters = std.StringHashMap(symbols.Symbol).init(testing.allocator);
    defer known_host_parameters.deinit();
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(testing.allocator);
    defer known_host_derived_types.deinit();
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(testing.allocator);
    defer known_host_interface_sources.deinit();
    var known_host_abstract_interfaces = std.StringHashMap(void).init(testing.allocator);
    defer known_host_abstract_interfaces.deinit();

    var analyzer = UnitAnalyzer.initWithDiagnostics(
        testing.allocator,
        @constCast(&program.units[0]),
        &.{},
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
        true,
        &diag_bag,
    );
    try testing.expectError(error.InvalidArgumentCount, analyzer.analyze());
    try testing.expect(diag_bag.items.len != 0);
    try testing.expect(std.mem.indexOf(u8, diag_bag.items[0].message, "INTENT(IN)") != null);
}

test "move_alloc intrinsic call rejects aliasing between from and to" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  type :: linked_list\n" ++
        "    type(linked_list), allocatable :: link\n" ++
        "    integer :: value\n" ++
        "  end type linked_list\n" ++
        "  type(linked_list) :: test\n" ++
        "  allocate(test%link)\n" ++
        "  allocate(test%link%link)\n" ++
        "  call move_alloc(test%link, test%link%link)\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    try testing.expectEqual(@as(usize, 1), program.units.len);

    var diag_bag = diag.Bag.init(testing.allocator);
    defer diag_bag.deinit();

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(testing.allocator);
    defer known_function_type_specs.deinit();
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(testing.allocator);
    defer known_procedure_sigs.deinit();
    var known_host_parameters = std.StringHashMap(symbols.Symbol).init(testing.allocator);
    defer known_host_parameters.deinit();
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(testing.allocator);
    defer known_host_derived_types.deinit();
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(testing.allocator);
    defer known_host_interface_sources.deinit();
    var known_host_abstract_interfaces = std.StringHashMap(void).init(testing.allocator);
    defer known_host_abstract_interfaces.deinit();

    var analyzer = UnitAnalyzer.initWithDiagnostics(
        testing.allocator,
        @constCast(&program.units[0]),
        &.{},
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
        true,
        &diag_bag,
    );
    try testing.expectError(error.InvalidArgumentCount, analyzer.analyze());
    try testing.expect(diag_bag.items.len != 0);
    try testing.expect(std.mem.indexOf(u8, diag_bag.items[0].message, "aliasing restrictions") != null);
}

test "date_and_time intrinsic call diagnoses wide character actual instead of explicit interface" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  character(kind=4,len=20) :: s4\n" ++
        "  call date_and_time(date=s4)\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

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
    try testing.expectEqualStrings(catalog.semantic.invalid_argument_count.code, got.code);
    try testing.expect(std.mem.indexOf(u8, got.message, "must be of kind 1") != null);
}

test "c_f_pointer rejects shape actual for scalar fptr" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  use iso_c_binding\n" ++
        "  type(c_ptr) :: cp\n" ++
        "  integer, pointer :: p\n" ++
        "  call c_f_pointer(cp, p, shape=[2])\n" ++
        "end program p\n";
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
    try testing.expectEqualStrings(catalog.semantic.invalid_argument_count.code, got.code);
    try testing.expect(std.mem.indexOf(u8, got.message, "Unexpected SHAPE argument") != null);
}

test "c_f_pointer rejects non-pointer fptr actual" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  use iso_c_binding\n" ++
        "contains\n" ++
        "  subroutine s(cp)\n" ++
        "    type(c_ptr), value :: cp\n" ++
        "    integer :: x\n" ++
        "    call c_f_pointer(cp, x)\n" ++
        "  end subroutine s\n" ++
        "end module m\n";
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
    try testing.expectEqualStrings(catalog.semantic.invalid_argument_count.code, got.code);
    try testing.expect(std.mem.indexOf(u8, got.message, "must be a pointer") != null);
}
