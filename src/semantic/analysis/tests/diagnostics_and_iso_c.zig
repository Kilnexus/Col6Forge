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

test "anonymous subroutine interface matching function name still conflicts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "function foo(x)\n" ++
        "  real :: x\n" ++
        "  interface\n" ++
        "    subroutine foo(i)\n" ++
        "      integer :: i\n" ++
        "    end subroutine\n" ++
        "  end interface\n" ++
        "end function foo\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "attribute conflicts with") != null);
}

test "procedure pointer assignment with type-spec interface does not overconstrain intrinsic arity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none\n" ++
        "procedure(integer), pointer :: p2\n" ++
        "p2 => iabs\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expect(diag.take() == null);
}

test "procedure pointer assignment rejects function for procedure() target" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none\n" ++
        "procedure(), pointer :: p4\n" ++
        "procedure(integer), pointer :: p2\n" ++
        "p4 => p2\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "is not a subroutine") != null);
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

test "bind(c) interface rejects character array result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program p\n" ++
        "  interface\n" ++
        "    function my() bind(c, name='my') result(r)\n" ++
        "      use iso_c_binding\n" ++
        "      character(kind=c_char) :: r(10)\n" ++
        "    end function\n" ++
        "  end interface\n" ++
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
    );
    try testing.expectError(error.InvalidCharLen, analyzer_instance.analyze());
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "cannot be an array") != null);
}

test "bind(c) procedure rejects non-length-one character value dummy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine s(x) bind(c)\n" ++
        "  character(len=2), value :: x\n" ++
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
    );
    try testing.expectError(error.InvalidCharLen, analyzer_instance.analyze());
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "must be of length 1") != null);
}

test "bind(c) interface in implicit main rejects character array result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "implicit none\n" ++
        "  interface\n" ++
        "    function my() bind(C,name=\"my\") result(r)\n" ++
        "      use iso_c_binding\n" ++
        "      character(kind=C_CHAR) :: r(10)\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end\n";
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
    );
    try testing.expectError(error.InvalidCharLen, analyzer_instance.analyze());
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "cannot be an array") != null);
}

test "bind(c) function rejects non-character array result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module x\n" ++
        "  use iso_c_binding\n" ++
        "contains\n" ++
        "  function bar() bind(c)\n" ++
        "    integer(c_int) :: bar(5)\n" ++
        "  end function bar\n" ++
        "end module x\n";
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
    );
    try testing.expectError(error.InvalidCharLen, analyzer_instance.analyze());
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "cannot be an array") != null);
}

test "bind(c) function accepts character c_char shorthand scalar result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "function return_char2(i) result(output) bind(c,name='return_char2')\n" ++
        "  use iso_c_binding\n" ++
        "  implicit none\n" ++
        "  integer(c_int) :: i\n" ++
        "  character(c_char) :: j\n" ++
        "  character(c_char) :: output\n" ++
        "  j = achar(i)\n" ++
        "  output = j\n" ++
        "end function return_char2\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 1), sem.units.len);
    try testing.expect(diag.take() == null);
}

test "global bind(c) validation ignores prelude-mirrored bind entity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module bind_c_implicit_vars\n" ++
        "bind(c) :: j\n" ++
        "contains\n" ++
        "  subroutine sub0(i) bind(c)\n" ++
        "    i = 0\n" ++
        "  end subroutine sub0\n" ++
        "end module bind_c_implicit_vars\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 2), sem.units.len);
    try testing.expect(diag.take() == null);
}

test "global bind(c) validation allows interface mirror for procedure definition" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module liter_cb_mod\n" ++
        "use iso_c_binding\n" ++
        "contains\n" ++
        "  function liter_cb(link_info) bind(c)\n" ++
        "    use iso_c_binding\n" ++
        "    implicit none\n" ++
        "    integer(c_int) :: liter_cb\n" ++
        "    type, bind(c) :: info_t\n" ++
        "      integer(c_int) :: type\n" ++
        "    end type info_t\n" ++
        "    type(info_t) :: link_info\n" ++
        "    liter_cb = 0\n" ++
        "  end function liter_cb\n" ++
        "end module liter_cb_mod\n" ++
        "program main\n" ++
        "  use iso_c_binding\n" ++
        "  interface\n" ++
        "    function liter_cb(link_info) bind(c)\n" ++
        "      use iso_c_binding\n" ++
        "      implicit none\n" ++
        "      integer(c_int) :: liter_cb\n" ++
        "      type, bind(c) :: info_t\n" ++
        "        integer(c_int) :: type\n" ++
        "      end type info_t\n" ++
        "      type(info_t) :: link_info\n" ++
        "    end function liter_cb\n" ++
        "  end interface\n" ++
        "end program main\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try split_api.analyzeProgram(arena.allocator(), program);
    try testing.expectEqual(@as(usize, 3), sem.units.len);
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

test "bind(c) procedure rejects polymorphic dummy" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "module m\n" ++
        "  use iso_c_binding\n" ++
        "  type :: t\n" ++
        "    integer(c_int) :: i\n" ++
        "  end type\n" ++
        "contains\n" ++
        "  subroutine test(a) bind(c)\n" ++
        "    class(t) :: a\n" ++
        "  end subroutine\n" ++
        "end module m\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "is not C interoperable") != null);
}

test "sequence or bind(c) derived type rejects polymorphic component" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "type :: t\n" ++
        "  integer :: i\n" ++
        "end type\n" ++
        "type t2\n" ++
        "  sequence\n" ++
        "  class(t), pointer :: x\n" ++
        "end type\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    diag.clear();
    _ = split_api.analyzeProgram(arena.allocator(), program) catch {};
    const got = diag.take() orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, got.message, "Polymorphic component x") != null);
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

test "program-level duplicate global binding names are diagnosed before codegen" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine foo() bind(C, name=\"bar\")\n" ++
        "end subroutine foo\n" ++
        "subroutine sub() bind(C, name=\"bar\")\n" ++
        "end subroutine sub\n";
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

    try testing.expect(diag_bag.count() >= 2);
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);
    try testing.expectEqual(@as(usize, 1), first.line);
    try testing.expectEqual(@as(usize, 3), second.line);
    try testing.expect(std.mem.indexOf(u8, first.message, "Global binding name 'bar'") != null);
    try testing.expect(std.mem.indexOf(u8, second.message, "Global binding name 'bar'") != null);
}

test "ENTRY unit inherits entry source for duplicate global name diagnostics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "subroutine foo()\n" ++
        "entry foo()\n" ++
        "end subroutine foo\n";
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

    try testing.expect(diag_bag.count() >= 2);
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);
    try testing.expect(std.mem.indexOf(u8, first.message, "Global name 'foo'") != null);
    try testing.expect(std.mem.indexOf(u8, second.message, "Global name 'foo'") != null);
    try testing.expect(first.line == 1 or first.line == 2);
    try testing.expect(second.line == 1 or second.line == 2);
}

test "procedure declarator reports assignment and call kind diagnostics in bag mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "program bsp\n" ++
        "  implicit none\n" ++
        "  abstract interface\n" ++
        "    subroutine up()\n" ++
        "    end subroutine up\n" ++
        "  end interface\n" ++
        "  procedure(up), pointer :: pptr\n" ++
        "  pptr => add\n" ++
        "  print *, pptr()\n" ++
        "contains\n" ++
        "  pure function add(a, b)\n" ++
        "    integer :: add\n" ++
        "    integer, intent(in) :: a, b\n" ++
        "    add = a + b\n" ++
        "  end function add\n" ++
        "end program bsp\n";
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

    try testing.expect(diag_bag.count() >= 2);
    const first = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(first);
    const second = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(second);

    try testing.expectEqual(@as(usize, 8), first.line);
    try testing.expect(std.mem.indexOf(u8, first.message, "actual argument is not a subroutine") != null);
    try testing.expectEqual(@as(usize, 9), second.line);
    try testing.expect(std.mem.indexOf(u8, second.message, "actual argument is not a function") != null);
}
