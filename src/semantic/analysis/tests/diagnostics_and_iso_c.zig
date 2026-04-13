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

test "semantic UnexpectedTypeDecl maps to the unexpected_type_decl diagnostic with declaration source" {
    const testing = std.testing;

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

    const unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "S",
        .args = &.{},
        .decls = &.{},
        .decl_sources = &.{},
        .stmts = &.{},
    };
    var ctx = context.Context.init(
        testing.allocator,
        unit,
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
    );
    ctx.setCurrentDeclSource(.{
        .line = 3,
        .column = 7,
        .text = "INTEGER X",
    });

    diag.clear();
    recordSemanticError(&ctx, error.UnexpectedTypeDecl);
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 3), got.line);
    try testing.expectEqual(@as(usize, 7), got.column);
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.unexpected_type_decl.code));
    try testing.expect(std.mem.eql(u8, got.line_text, "INTEGER X"));
}

test "semantic fallback uses last noted statement when active context is cleared" {
    const testing = std.testing;

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

    const stmt = ast.Stmt{
        .label = null,
        .node = .{ .stop = {} },
        .source_line = 5,
        .source_column = 11,
        .source_text = "      STOP",
    };
    const unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "S",
        .args = &.{},
        .decls = &.{},
        .decl_sources = &.{},
        .stmts = &.{stmt},
    };
    var ctx = context.Context.init(
        testing.allocator,
        unit,
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
    );

    diag.clear();
    ctx.setCurrentStmt(stmt);
    ctx.clearCurrentStmt();
    recordSemanticError(&ctx, error.MissingScope);
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 5), got.line);
    try testing.expectEqual(@as(usize, 11), got.column);
    try testing.expect(std.mem.eql(u8, got.code, catalog.semantic.missing_scope.code));
    try testing.expect(std.mem.eql(u8, got.line_text, "      STOP"));
}

test "module procedure explicit interface body does not conflict with module contained definition" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  interface assign\n" ++
        "    module subroutine s()\n" ++
        "    end subroutine s\n" ++
        "  end interface assign\n" ++
        "contains\n" ++
        "  module subroutine s()\n" ++
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
    );
    _ = try analyzer_instance.analyze();
    try testing.expect(diag.take() == null);
}

test "explicit interface import can reference host derived type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  use, intrinsic :: iso_c_binding\n" ++
        "  type, bind(c) :: cstruct\n" ++
        "    integer(c_int) :: i\n" ++
        "  end type cstruct\n" ++
        "  interface\n" ++
        "    subroutine psub(that) bind(c)\n" ++
        "      import :: cstruct\n" ++
        "      type(cstruct) :: that(:)\n" ++
        "    end subroutine psub\n" ++
        "  end interface\n" ++
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
    );
    _ = try analyzer_instance.analyze();
    try testing.expect(diag.take() == null);
}


test "use iso_c_binding full import provides builtin derived types and constants to declarations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  use iso_c_binding\n" ++
        "  implicit none\n" ++
        "  type(c_ptr) :: p0 = c_null_ptr\n" ++
        "  type(c_funptr) :: fp = c_null_funptr\n" ++
        "  character(kind=c_char), dimension(1) :: s = c_null_char\n" ++
        "  integer(c_int) :: i\n" ++
        "  real(c_double) :: x\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 1), sem.units.len);
}

test "use iso_c_binding only rename provides builtin derived types and kind constants" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  use iso_c_binding, only: cptr_t => c_ptr, cint_t => c_int, cchar_t => c_char\n" ++
        "  implicit none\n" ++
        "  type(cptr_t) :: p0\n" ++
        "  integer(cint_t) :: i\n" ++
        "  character(kind=cchar_t,len=1) :: ch\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 1), sem.units.len);
}

test "character c_char shorthand and c_loc intrinsic resolve through iso_c_binding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  use iso_c_binding\n" ++
        "  implicit none\n" ++
        "  type(c_ptr), target :: argv\n" ++
        "  character(c_char), dimension(1) :: s = c_null_char\n" ++
        "  interface\n" ++
        "    subroutine sub1(x)\n" ++
        "      import :: c_ptr\n" ++
        "      type(c_ptr), intent(in) :: x\n" ++
        "    end subroutine sub1\n" ++
        "  end interface\n" ++
        "  call sub1(c_loc(argv))\n" ++
        "end program p\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 1), sem.units.len);
}

test "contained procedure can use host-associated iso_c_binding c_char in character shorthand" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  use iso_c_binding\n" ++
        "  implicit none\n" ++
        "contains\n" ++
        "  subroutine s()\n" ++
        "    character(c_char), dimension(1) :: text = c_null_char\n" ++
        "  end subroutine s\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 2), sem.units.len);
}

test "unnamed explicit interface body in module prelude is callable from contained procedure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module gfbug\n" ++
        "  implicit none\n" ++
        "  interface\n" ++
        "    function uppercase(string) result(upper)\n" ++
        "      character(*), intent(in) :: string\n" ++
        "      character(len(string)) :: upper\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "contains\n" ++
        "  subroutine s1\n" ++
        "    character(5) :: c\n" ++
        "    character(5), dimension(1) :: ca\n" ++
        "    ca = (/ uppercase(c) /)\n" ++
        "  end subroutine s1\n" ++
        "end module gfbug\n";
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
        &program.units,
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
    );
    _ = try analyzer_instance.analyze();
    try testing.expect(diag.take() == null);
}

test "contained procedure does not revalidate imported derived binding prelude" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  type, abstract :: top\n" ++
        "  contains\n" ++
        "    procedure(xxx), deferred :: proc_a\n" ++
        "  end type top\n" ++
        "contains\n" ++
        "  subroutine s\n" ++
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
    var diag_bag = diag.Bag.init(arena.allocator());
    defer diag_bag.deinit();

    var unit = program.units[1];
    var analyzer_instance = UnitAnalyzer.initWithDiagnostics(
        arena.allocator(),
        &unit,
        &program.units,
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
    try testing.expectEqual(@as(usize, 0), diag_bag.count());
}

test "recursive function name without RESULT is rejected as recursive call target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program test\n" ++
        "contains\n" ++
        "  recursive function f(n)\n" ++
        "    integer :: f\n" ++
        "    integer :: n\n" ++
        "    f = 1\n" ++
        "    if (n < 5) f = f + f(n + 1)\n" ++
        "  end function f\n" ++
        "end program test\n";
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
        &program.units,
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_parameters,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        null,
        .{},
    );
    _ = analyzer_instance.analyze() catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    defer diag.releaseTaken(got);
    try testing.expectEqualStrings(catalog.semantic.invalid_argument_count.code, got.code);
    try testing.expect(std.mem.indexOf(u8, got.message, "name of a recursive function") != null);
}

