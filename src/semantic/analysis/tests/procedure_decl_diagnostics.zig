const support = @import("support.zig");
const std = support.std;
const ast = support.ast;
const symbols = support.symbols;
const context = support.context;
const diag = support.diag;
const free_form = support.free_form;
const parser = support.parser;
const UnitAnalyzer = support.UnitAnalyzer;

test "procedure declaration rejects SAVE without POINTER" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source =
        "procedure(real), save :: noptr\n" ++
        "end\n";
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
    try testing.expect(std.mem.indexOf(u8, got.message, "SAVE attribute conflicts with PROCEDURE attribute") != null);
}
