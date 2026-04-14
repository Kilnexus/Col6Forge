const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const free_form = @import("../../../frontend/free_form.zig");
const parser = @import("../../../frontend/parser/mod.zig");
const analyzer = @import("../../analysis/mod.zig");
const check_statements = @import("../../analysis/check_statements/mod.zig");
const procedure_calls = @import("../../analysis/check_statements/procedure_calls.zig");
const resolve_expr = @import("../../analysis/resolve_expr.zig");
const resolve_symbols = @import("../../analysis/resolve_symbols.zig");
const resolve_units = @import("../../analysis/resolve_units.zig");
const resolve_units_bind_c = @import("../../analysis/resolve_units_bind_c.zig");
const context = @import("../../context.zig");
const diagnostic = @import("../../diagnostic.zig");
const symbols = @import("../../symbol/mod.zig");
const function_type = @import("../function_type.zig");
const common_validation = @import("../common_validation.zig");
const symbol_lookup = @import("../symbol_lookup.zig");
const host_context = @import("host_context.zig");
const global_identifier_validation = @import("global_identifier_validation.zig");
const interfaces = @import("interfaces.zig");
const procedure_inference = @import("procedure_inference.zig");
const types = @import("types.zig");

const builtin_known_fn_types = [_]types.KnownFunctionType{
    .{ .name = "c_loc", .type_spec = symbols.TypeSpec.fromDerived("c_ptr") },
    .{ .name = "c_funloc", .type_spec = symbols.TypeSpec.fromDerived("c_funptr") },
    .{ .name = "c_associated", .type_spec = symbols.TypeSpec.fromResolvedKind(.logical, .logical, null) },
};

pub fn analyzeProgram(arena: std.mem.Allocator, program: ast.Program) !types.SemanticProgram {
    return analyzeProgramWithOptions(arena, program, .{});
}

pub fn analyzeProgramWithKnown(
    arena: std.mem.Allocator,
    program: ast.Program,
    known_fn_types: []const types.KnownFunctionType,
    known_proc_sigs: []const types.KnownProcedureSig,
) !types.SemanticProgram {
    return analyzeProgramWithKnownAndOptions(arena, program, known_fn_types, known_proc_sigs, .{});
}

pub fn analyzeProgramWithOptions(
    arena: std.mem.Allocator,
    program: ast.Program,
    options: types.AnalyzeOptions,
) !types.SemanticProgram {
    return analyzeProgramWithKnownAndOptions(arena, program, &.{}, &.{}, options);
}

pub fn analyzeProgramWithKnownAndOptions(
    arena: std.mem.Allocator,
    program: ast.Program,
    known_fn_types: []const types.KnownFunctionType,
    known_proc_sigs: []const types.KnownProcedureSig,
    options: types.AnalyzeOptions,
) !types.SemanticProgram {
    var diag_bag = diagnostic.Bag.init(arena);
    defer diag_bag.deinit();
    return analyzeProgramWithKnownAndOptionsAndDiagnostics(arena, program, known_fn_types, known_proc_sigs, options, &diag_bag);
}

pub fn analyzeProgramWithKnownAndOptionsAndDiagnostics(
    arena: std.mem.Allocator,
    program: ast.Program,
    known_fn_types: []const types.KnownFunctionType,
    known_proc_sigs: []const types.KnownProcedureSig,
    options: types.AnalyzeOptions,
    diag_bag: *diagnostic.Bag,
) !types.SemanticProgram {
    diag_bag.clear();

    const mutable_program = program;
    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena);
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena);
    var known_host_symbols = std.StringHashMap(symbols.Symbol).init(arena);
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena);
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena);
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena);
    var known_host_implicit_call_sigs = std.StringHashMap(context.Context.ImplicitCallSig).init(arena);
    var known_program_implicit_call_sigs = std.StringHashMap(context.Context.ImplicitCallSig).init(arena);
    var host_symbols_active = false;
    var active_host_owner: ?[]const u8 = null;

    try seedKnownProcedures(arena, known_fn_types, known_proc_sigs, &known_function_type_specs, &known_procedure_sigs);
    try validateProgramBindCInterfaces(
        arena,
        mutable_program,
        &known_function_type_specs,
        &known_procedure_sigs,
        &known_host_symbols,
        &known_host_derived_types,
        &known_host_interface_sources,
        &known_host_abstract_interfaces,
        options,
        diag_bag,
    );
    try inferProgramProcedures(arena, mutable_program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installExplicitInterfaceProcedures(arena, mutable_program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installSingleTargetGenericInterfaces(arena, mutable_program, &known_function_type_specs, &known_procedure_sigs);
    try global_identifier_validation.validateProgram(arena, mutable_program, diag_bag);

    var units = std.array_list.Managed(types.SemanticUnit).init(arena);
    var first_error: ?anyerror = null;
    for (mutable_program.units) |*unit| {
        clearInactiveHostContext(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            &host_symbols_active,
            &active_host_owner,
            unit.*,
        );

        var unit_analyzer = analyzer.UnitAnalyzer.initWithDiagnostics(
            arena,
            unit,
            &.{},
            &known_function_type_specs,
            &known_procedure_sigs,
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            active_host_owner,
            options.target_layout,
            options.range_check,
            diag_bag,
        );
        unit_analyzer.ctx.fbackslash = options.fbackslash;
        unit_analyzer.ctx.allow_argument_mismatch = options.allow_argument_mismatch;
        unit_analyzer.ctx.dialect = options.dialect;
        unit_analyzer.ctx.declare_variant_adjust_args = options.declare_variant_adjust_args;
        unit_analyzer.ctx.known_host_implicit_call_sigs = &known_host_implicit_call_sigs;
        unit_analyzer.ctx.known_program_implicit_call_sigs = &known_program_implicit_call_sigs;
        const sem_unit = unit_analyzer.analyze() catch |err| {
            if (first_error == null) first_error = err;
            try units.append(.{
                .name = unit.name,
                .kind = unit.kind,
                .symbols = &.{},
                .implicit_rules = &.{},
                .resolved_refs = &.{},
            });
            try refreshHostContextIfNeeded(
                &known_host_symbols,
                &known_host_derived_types,
                &known_host_interface_sources,
                &known_host_abstract_interfaces,
                &known_host_implicit_call_sigs,
                arena,
                unit.*,
                &unit_analyzer.ctx.derived_types,
                &unit_analyzer.ctx.implicit_call_sigs,
                unit_analyzer.ctx.symbols.items,
                &host_symbols_active,
                &active_host_owner,
            );
            try mergeProgramImplicitCallSigs(
                arena,
                &known_program_implicit_call_sigs,
                &unit_analyzer.ctx.implicit_call_sigs,
            );
            continue;
        };
        try units.append(sem_unit);
        try refreshHostContextIfNeeded(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            arena,
            unit.*,
            &unit_analyzer.ctx.derived_types,
            &unit_analyzer.ctx.implicit_call_sigs,
            sem_unit.symbols,
            &host_symbols_active,
            &active_host_owner,
        );
        try mergeProgramImplicitCallSigs(
            arena,
            &known_program_implicit_call_sigs,
            &unit_analyzer.ctx.implicit_call_sigs,
        );
    }
    if (first_error) |err| return err;
    try common_validation.validateCommonBlocksWithDiagnostics(arena, mutable_program, units.items, diag_bag);
    return .{ .units = try units.toOwnedSlice() };
}

fn validateProgramBindCInterfaces(
    arena: std.mem.Allocator,
    program: ast.Program,
    known_function_type_specs: *const std.StringHashMap(symbols.TypeSpec),
    known_procedure_sigs: *const std.StringHashMap(context.Context.ProcedureSig),
    known_host_symbols: *const std.StringHashMap(symbols.Symbol),
    known_host_derived_types: *const std.StringHashMap(context.Context.DerivedTypeInfo),
    known_host_interface_sources: *const std.StringHashMap(ast.DeclSource),
    known_host_abstract_interfaces: *const std.StringHashMap(void),
    options: types.AnalyzeOptions,
    diag_bag: *diagnostic.Bag,
) !void {
    for (program.units) |*unit| {
        var unit_analyzer = analyzer.UnitAnalyzer.initWithDiagnostics(
            arena,
            unit,
            &.{},
            known_function_type_specs,
            known_procedure_sigs,
            known_host_symbols,
            known_host_derived_types,
            known_host_interface_sources,
            known_host_abstract_interfaces,
            null,
            options.target_layout,
            options.range_check,
            diag_bag,
        );
        unit_analyzer.ctx.fbackslash = options.fbackslash;
        unit_analyzer.ctx.allow_argument_mismatch = options.allow_argument_mismatch;
        unit_analyzer.ctx.dialect = options.dialect;
        try resolve_units_bind_c.validateBindCInterfaceBlocks(&unit_analyzer.ctx);
    }
}

fn mergeProgramImplicitCallSigs(
    arena: std.mem.Allocator,
    program_sigs: *std.StringHashMap(context.Context.ImplicitCallSig),
    unit_sigs: *const std.StringHashMap(context.Context.ImplicitCallSig),
) !void {
    var it = unit_sigs.iterator();
    while (it.next()) |entry| {
        if (program_sigs.contains(entry.key_ptr.*)) continue;
        const key = try symbol_lookup.lowerDup(arena, entry.key_ptr.*);
        try program_sigs.put(key, entry.value_ptr.*);
    }
}

fn seedKnownProcedures(
    arena: std.mem.Allocator,
    known_fn_types: []const types.KnownFunctionType,
    known_proc_sigs: []const types.KnownProcedureSig,
    known_function_type_specs: *std.StringHashMap(symbols.TypeSpec),
    known_procedure_sigs: *std.StringHashMap(context.Context.ProcedureSig),
) !void {
    for (builtin_known_fn_types) |known| {
        const key = try symbol_lookup.lowerDup(arena, known.name);
        try known_function_type_specs.put(key, known.resolvedSpec());
    }
    for (known_fn_types) |known| {
        const key = try symbol_lookup.lowerDup(arena, known.name);
        try known_function_type_specs.put(key, known.resolvedSpec());
    }
    for (known_proc_sigs) |known| {
        const key = try symbol_lookup.lowerDup(arena, known.name);
        try known_procedure_sigs.put(key, .{
            .kind = known.kind,
            .arg_count = known.arg_count,
            .alt_return_count = known.alt_return_count,
            .args = known.args,
            .pure = known.pure,
            .elemental = known.elemental,
            .is_pointer = known.is_pointer,
            .result_rank = known.result_rank,
            .result_type_spec = known.result_type_spec,
            .result_shape_signature = known.result_shape_signature,
            .result_allocatable = known.result_allocatable,
            .result_contiguous = known.result_contiguous,
            .result_procedure_pointer = known.result_procedure_pointer,
            .actual_requires_explicit_interface = known.actual_requires_explicit_interface,
            .definition_known_from_current_program = known.definition_known_from_current_program,
        });
    }
}

fn inferProgramProcedures(
    arena: std.mem.Allocator,
    program: ast.Program,
    known_function_type_specs: *std.StringHashMap(symbols.TypeSpec),
    known_procedure_sigs: *std.StringHashMap(context.Context.ProcedureSig),
) !void {
    for (program.units) |unit| {
        if (unit.kind == .function) {
            const inferred = function_type.inferFunctionTypeSpec(unit);
            if (unit.owner_name) |owner_name| {
                const qualified_key = try qualifiedProcedureKey(arena, owner_name, unit.name);
                try known_function_type_specs.put(qualified_key, inferred);
            } else {
                const key = try symbol_lookup.lowerDup(arena, unit.name);
                try known_function_type_specs.put(key, inferred);
            }
        }
        if (unit.kind == .function or unit.kind == .subroutine) {
            const sig: context.Context.ProcedureSig = .{
                .kind = unit.kind,
                .arg_count = unit.args.len,
                .alt_return_count = unit.alt_return_dummy_count,
                .args = try procedure_inference.inferProcedureArgSigsWithKnown(arena, unit, known_procedure_sigs),
                .pure = unit.pure,
                .elemental = unit.elemental,
                .is_pointer = function_type.inferProcedureIsPointer(unit),
                .result_rank = if (unit.kind == .function) function_type.inferFunctionResultRank(unit) else 0,
                .result_type_spec = if (unit.kind == .function) function_type.inferFunctionTypeSpec(unit) else null,
                .result_shape_signature = if (unit.kind == .function) try function_type.inferFunctionResultShapeSignature(arena, unit) else &.{},
                .result_allocatable = if (unit.kind == .function) function_type.inferFunctionResultAllocatable(unit) else false,
                .result_contiguous = if (unit.kind == .function) function_type.inferFunctionResultContiguous(unit) else false,
                .result_procedure_pointer = if (unit.kind == .function) function_type.inferFunctionResultIsProcedurePointer(unit) else false,
                .actual_requires_explicit_interface = unit.owner_name != null,
                .definition_known_from_current_program = true,
            };
            if (unit.owner_name) |owner_name| {
                const qualified_key = try qualifiedProcedureKey(arena, owner_name, unit.name);
                try known_procedure_sigs.put(qualified_key, sig);
            } else {
                const key = try symbol_lookup.lowerDup(arena, unit.name);
                try known_procedure_sigs.put(key, sig);
            }
        }
    }
}

fn clearInactiveHostContext(
    known_host_symbols: *std.StringHashMap(symbols.Symbol),
    known_host_derived_types: *std.StringHashMap(context.Context.DerivedTypeInfo),
    known_host_interface_sources: *std.StringHashMap(ast.DeclSource),
    known_host_abstract_interfaces: *std.StringHashMap(void),
    known_host_implicit_call_sigs: *std.StringHashMap(context.Context.ImplicitCallSig),
    host_symbols_active: *bool,
    active_host_owner: *?[]const u8,
    unit: ast.ProgramUnit,
) void {
    if (!host_symbols_active.* or unit.owner_name != null) return;
    known_host_symbols.clearRetainingCapacity();
    known_host_derived_types.clearRetainingCapacity();
    known_host_interface_sources.clearRetainingCapacity();
    known_host_abstract_interfaces.clearRetainingCapacity();
    known_host_implicit_call_sigs.clearRetainingCapacity();
    host_symbols_active.* = false;
    active_host_owner.* = null;
}

fn refreshHostContextIfNeeded(
    known_host_symbols: *std.StringHashMap(symbols.Symbol),
    known_host_derived_types: *std.StringHashMap(context.Context.DerivedTypeInfo),
    known_host_interface_sources: *std.StringHashMap(ast.DeclSource),
    known_host_abstract_interfaces: *std.StringHashMap(void),
    known_host_implicit_call_sigs: *std.StringHashMap(context.Context.ImplicitCallSig),
    arena: std.mem.Allocator,
    unit: ast.ProgramUnit,
    derived_types: *const std.StringHashMap(context.Context.DerivedTypeInfo),
    implicit_call_sigs: *const std.StringHashMap(context.Context.ImplicitCallSig),
    host_symbols: []const symbols.Symbol,
    host_symbols_active: *bool,
    active_host_owner: *?[]const u8,
) !void {
    if (unit.kind != .module and !unitHasContains(unit)) return;
    try host_context.refreshHostContextFromAnalyzer(
        known_host_symbols,
        known_host_derived_types,
        known_host_interface_sources,
        known_host_abstract_interfaces,
        arena,
        host_symbols,
        derived_types,
        unit,
    );
    known_host_implicit_call_sigs.clearRetainingCapacity();
    var it = implicit_call_sigs.iterator();
    while (it.next()) |entry| {
        const key = try symbol_lookup.lowerDup(arena, entry.key_ptr.*);
        try known_host_implicit_call_sigs.put(key, entry.value_ptr.*);
    }
    host_symbols_active.* = true;
    active_host_owner.* = unit.name;
}

fn qualifiedProcedureKey(arena: std.mem.Allocator, owner_name: []const u8, procedure_name: []const u8) ![]const u8 {
    return symbol_lookup.lowerDup(arena, try std.fmt.allocPrint(arena, "{s}::{s}", .{ owner_name, procedure_name }));
}

fn unitHasContains(unit: ast.ProgramUnit) bool {
    for (unit.stmts) |stmt| {
        if (stmt.node != .cont) continue;
        const text = std.mem.trim(u8, stmt.source_text, " \t");
        if (std.ascii.eqlIgnoreCase(text, "contains")) return true;
    }
    return false;
}

fn testDummyArgTypeCompatible(
    self: *context.Context,
    expected: symbols.TypeSpec,
    actual: symbols.TypeSpec,
) bool {
    if (expected.assumed_type) return true;
    if (actual.assumed_type) return false;
    if (expected.polymorphic and expected.derived_type_name == null) {
        return true;
    }
    if (expected.lowered_kind != actual.lowered_kind) return false;
    if (expected.lowered_kind != .derived) return true;

    const expected_name = expected.derived_type_name orelse return false;
    const actual_name = actual.derived_type_name orelse return false;
    return if (expected.polymorphic)
        resolve_symbols.isSameOrExtension(self, actual_name, expected_name)
    else
        resolve_symbols.areConcreteDerivedTypesCompatible(self, expected_name, actual_name);
}

test "analyze inferred procedure sig keeps assumed-type module dummy ranks" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source =
        "module mod\n" ++
        "contains\n" ++
        "  subroutine sub_array_shape(arg2, ubounds)\n" ++
        "    type(*) :: arg2(:,:)\n" ++
        "    integer :: ubounds(2)\n" ++
        "  end subroutine sub_array_shape\n" ++
        "  subroutine sub_array_assumed(arg3)\n" ++
        "    type(*) :: arg3(*)\n" ++
        "  end subroutine sub_array_assumed\n" ++
        "end module mod\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var known_fn_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_sig = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    try inferProgramProcedures(arena.allocator(), program, &known_fn_specs, &known_sig);

    const shape_sig = known_sig.get("mod::sub_array_shape") orelse known_sig.get("sub_array_shape") orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 2), shape_sig.args[0].rank);
    try testing.expect(shape_sig.args[0].requires_descriptor);
    try testing.expect(shape_sig.args[0].type_spec.assumed_type);
    try testing.expectEqual(@as(usize, 1), shape_sig.args[1].rank);

    const assumed_sig = known_sig.get("mod::sub_array_assumed") orelse known_sig.get("sub_array_assumed") orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 1), assumed_sig.args[0].rank);
    try testing.expect(!assumed_sig.args[0].requires_descriptor);
    try testing.expect(assumed_sig.args[0].type_spec.assumed_type);
}

test "analyze semantic units keep assumed-type array symbol ranks" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source =
        "module mod\n" ++
        "contains\n" ++
        "  subroutine sub_array_shape(arg2, ubounds)\n" ++
        "    type(*) :: arg2(:,:)\n" ++
        "    integer :: ubounds(2)\n" ++
        "  end subroutine sub_array_shape\n" ++
        "  subroutine sub_array_assumed(arg3)\n" ++
        "    type(*) :: arg3(*)\n" ++
        "  end subroutine sub_array_assumed\n" ++
        "end module mod\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    const sem = try analyzeProgram(arena.allocator(), program);

    var found_shape = false;
    var found_assumed = false;
    for (sem.units) |unit| {
        if (std.ascii.eqlIgnoreCase(unit.name, "sub_array_shape")) {
            found_shape = true;
            for (unit.symbols) |sym| {
                if (std.ascii.eqlIgnoreCase(sym.name, "arg2")) {
                    try testing.expectEqual(@as(usize, 2), sym.dims.len);
                    try testing.expect(sym.type_spec.assumed_type);
                }
                if (std.ascii.eqlIgnoreCase(sym.name, "ubounds")) {
                    try testing.expectEqual(@as(usize, 1), sym.dims.len);
                }
            }
        }
        if (std.ascii.eqlIgnoreCase(unit.name, "sub_array_assumed")) {
            found_assumed = true;
            for (unit.symbols) |sym| {
                if (std.ascii.eqlIgnoreCase(sym.name, "arg3")) {
                    try testing.expectEqual(@as(usize, 1), sym.dims.len);
                    try testing.expect(sym.type_spec.assumed_type);
                }
            }
        }
    }
    try testing.expect(found_shape);
    try testing.expect(found_assumed);
}

test "analyze accepts assumed-type sequence association with module dummy" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source =
        "module mod\n" ++
        "contains\n" ++
        "  subroutine sub_array_shape(arg2, ubounds)\n" ++
        "    type(*) :: arg2(:,:)\n" ++
        "    integer :: ubounds(2)\n" ++
        "    call sub_array_assumed(arg2)\n" ++
        "  end subroutine sub_array_shape\n" ++
        "  subroutine sub_array_assumed(arg3)\n" ++
        "    type(*) :: arg3(*)\n" ++
        "  end subroutine sub_array_assumed\n" ++
        "end module mod\n" ++
        "program p\n" ++
        "  use mod\n" ++
        "  real, allocatable :: array_real_alloc(:,:)\n" ++
        "  allocate(array_real_alloc(3:5,2:4))\n" ++
        "  call sub_array_assumed(array_real_alloc)\n" ++
        "  call sub_array_shape(array_real_alloc, shape(array_real_alloc))\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try analyzeProgram(arena.allocator(), program);
}

test "analyze accepts assumed-type array section actual" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source =
        "program p\n" ++
        "  real :: a(3)\n" ++
        "  call foo(a(1:2))\n" ++
        "contains\n" ++
        "  subroutine foo(x)\n" ++
        "    type(*) :: x(*)\n" ++
        "  end subroutine foo\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try analyzeProgram(arena.allocator(), program);
}

test "analyze accepts assumed-type sequence association with c_loc context" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source =
        "module mod\n" ++
        "  use iso_c_binding, only: c_loc, c_ptr\n" ++
        "contains\n" ++
        "  subroutine sub_array_shape(arg2, ubounds)\n" ++
        "    type(*), target :: arg2(:,:)\n" ++
        "    integer :: ubounds(2)\n" ++
        "    call sub_array_assumed(arg2)\n" ++
        "  end subroutine sub_array_shape\n" ++
        "  subroutine sub_array_assumed(arg3)\n" ++
        "    type(*), target :: arg3(*)\n" ++
        "    type(c_ptr) :: cpt\n" ++
        "    cpt = c_loc(arg3)\n" ++
        "  end subroutine sub_array_assumed\n" ++
        "end module mod\n" ++
        "program p\n" ++
        "  use mod\n" ++
        "  real, allocatable :: array_real_alloc(:,:)\n" ++
        "  allocate(array_real_alloc(3:5,2:4))\n" ++
        "  call sub_array_assumed(array_real_alloc)\n" ++
        "  call sub_array_shape(array_real_alloc, shape(array_real_alloc))\n" ++
        "end program p\n";

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);
    _ = try analyzeProgram(arena.allocator(), program);
}

test "analyze actual assumed_type_2 file preserves ranks at failing call sites" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/assumed_type_2.f90", 1024 * 1024);
    defer allocator.free(source);

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_symbols = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());
    var known_host_implicit_call_sigs = std.StringHashMap(context.Context.ImplicitCallSig).init(arena.allocator());
    var host_symbols_active = false;
    var active_host_owner: ?[]const u8 = null;

    try seedKnownProcedures(arena.allocator(), &.{}, &.{}, &known_function_type_specs, &known_procedure_sigs);
    try inferProgramProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installExplicitInterfaceProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installSingleTargetGenericInterfaces(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);

    var saw_line_44 = false;
    var saw_line_130 = false;
    for (program.units) |*unit| {
        clearInactiveHostContext(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            &host_symbols_active,
            &active_host_owner,
            unit.*,
        );

        var unit_analyzer = analyzer.UnitAnalyzer.init(
            arena.allocator(),
            unit,
            &.{},
            &known_function_type_specs,
            &known_procedure_sigs,
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            active_host_owner,
            .{},
            false,
        );
        unit_analyzer.ctx.known_host_implicit_call_sigs = &known_host_implicit_call_sigs;
        _ = unit_analyzer.analyze() catch {};

        for (unit.stmts) |stmt| {
            if (stmt.node != .call) continue;
            if (stmt.source_line == 44) {
                saw_line_44 = true;
                const sig = resolve_symbols.lookupKnownProcedureSig(&unit_analyzer.ctx, "sub_array_assumed") orelse return error.TestExpectedEqual;
                try testing.expectEqual(@as(usize, 1), sig.args[0].rank);
                try testing.expect(!sig.args[0].requires_descriptor);
                const actual = stmt.node.call.args[0].expr.value;
                try resolve_expr.resolveExpr(&unit_analyzer.ctx, actual);
                try testing.expectEqual(@as(usize, 2), resolve_expr.exprRank(&unit_analyzer.ctx, actual));
                try testing.expectEqual(@as(usize, 2), procedure_calls.procedureActualExprRank(&unit_analyzer.ctx, actual));
                try testing.expect((try procedure_calls.sequenceAssociationAvailableElements(&unit_analyzer.ctx, actual)) != null);
                try procedure_calls.checkProcedureActualArgsForCall(&unit_analyzer.ctx, stmt.node.call.name, stmt.node.call.args, .{
                    .dummyArgTypeCompatible = testDummyArgTypeCompatible,
                });
            }
            if (stmt.source_line == 130) {
                saw_line_130 = true;
                const sig = resolve_symbols.lookupKnownProcedureSig(&unit_analyzer.ctx, "sub_array_shape") orelse return error.TestExpectedEqual;
                try testing.expectEqual(@as(usize, 1), sig.args[2].rank);
                const actual = stmt.node.call.args[2].expr.value;
                try resolve_expr.resolveExpr(&unit_analyzer.ctx, actual);
                try testing.expectEqual(@as(usize, 1), resolve_expr.exprRank(&unit_analyzer.ctx, actual));
                try testing.expectEqual(@as(usize, 1), procedure_calls.procedureActualExprRank(&unit_analyzer.ctx, actual));
                try procedure_calls.checkProcedureActualArgsForCall(&unit_analyzer.ctx, stmt.node.call.name, stmt.node.call.args, .{
                    .dummyArgTypeCompatible = testDummyArgTypeCompatible,
                });
            }
        }

        try refreshHostContextIfNeeded(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            arena.allocator(),
            unit.*,
            &unit_analyzer.ctx.derived_types,
            &unit_analyzer.ctx.implicit_call_sigs,
            unit_analyzer.ctx.symbols.items,
            &host_symbols_active,
            &active_host_owner,
        );
    }

    try testing.expect(saw_line_44);
    try testing.expect(saw_line_130);
}

test "analyze actual assumed_type_2 file cold call checks pass after resolver" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/assumed_type_2.f90", 1024 * 1024);
    defer allocator.free(source);

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_symbols = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());
    var known_host_implicit_call_sigs = std.StringHashMap(context.Context.ImplicitCallSig).init(arena.allocator());
    var host_symbols_active = false;
    var active_host_owner: ?[]const u8 = null;

    try seedKnownProcedures(arena.allocator(), &.{}, &.{}, &known_function_type_specs, &known_procedure_sigs);
    try inferProgramProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installExplicitInterfaceProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installSingleTargetGenericInterfaces(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);

    var saw_line_44 = false;
    var saw_line_130 = false;
    for (program.units) |*unit| {
        clearInactiveHostContext(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            &host_symbols_active,
            &active_host_owner,
            unit.*,
        );

        var unit_analyzer = analyzer.UnitAnalyzer.init(
            arena.allocator(),
            unit,
            &.{},
            &known_function_type_specs,
            &known_procedure_sigs,
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            active_host_owner,
            .{},
            false,
        );
        unit_analyzer.ctx.known_host_implicit_call_sigs = &known_host_implicit_call_sigs;

        var resolver = resolve_units.Resolver.init(&unit_analyzer.ctx, &.{});
        resolver.run() catch {};

        for (unit.stmts) |stmt| {
            if (stmt.node != .call) continue;
            if (stmt.source_line == 44 or stmt.source_line == 130) {
                try procedure_calls.checkProcedureActualArgsForCall(&unit_analyzer.ctx, stmt.node.call.name, stmt.node.call.args, .{
                    .dummyArgTypeCompatible = testDummyArgTypeCompatible,
                });
                if (stmt.source_line == 44) saw_line_44 = true;
                if (stmt.source_line == 130) saw_line_130 = true;
            }
        }

        try refreshHostContextIfNeeded(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            arena.allocator(),
            unit.*,
            &unit_analyzer.ctx.derived_types,
            &unit_analyzer.ctx.implicit_call_sigs,
            unit_analyzer.ctx.symbols.items,
            &host_symbols_active,
            &active_host_owner,
        );
    }

    try testing.expect(saw_line_44);
    try testing.expect(saw_line_130);
}

test "analyze actual assumed_type_2 file line 44 fails only after prior statement checks" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/assumed_type_2.f90", 1024 * 1024);
    defer allocator.free(source);

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_symbols = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());
    var known_host_implicit_call_sigs = std.StringHashMap(context.Context.ImplicitCallSig).init(arena.allocator());
    var host_symbols_active = false;
    var active_host_owner: ?[]const u8 = null;

    try seedKnownProcedures(arena.allocator(), &.{}, &.{}, &known_function_type_specs, &known_procedure_sigs);
    try inferProgramProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installExplicitInterfaceProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installSingleTargetGenericInterfaces(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);

    var reproduced = false;
    for (program.units) |*unit| {
        clearInactiveHostContext(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            &host_symbols_active,
            &active_host_owner,
            unit.*,
        );

        var unit_analyzer = analyzer.UnitAnalyzer.init(
            arena.allocator(),
            unit,
            &.{},
            &known_function_type_specs,
            &known_procedure_sigs,
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            active_host_owner,
            .{},
            false,
        );
        unit_analyzer.ctx.known_host_implicit_call_sigs = &known_host_implicit_call_sigs;

        var resolver = resolve_units.Resolver.init(&unit_analyzer.ctx, &.{});
        resolver.run() catch {};

        for (unit.stmts) |stmt| {
            check_statements.checkStmt(&unit_analyzer.ctx, stmt) catch |err| {
                if (stmt.source_line == 44) {
                    try testing.expectEqual(error.InvalidArgumentCount, err);
                    reproduced = true;
                    break;
                }
                return err;
            };
            if (stmt.source_line == 44) {
                // Cold direct call check was green; reaching here means the full stmt path stayed green too.
                break;
            }
        }
        if (reproduced) break;

        try refreshHostContextIfNeeded(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            arena.allocator(),
            unit.*,
            &unit_analyzer.ctx.derived_types,
            &unit_analyzer.ctx.implicit_call_sigs,
            unit_analyzer.ctx.symbols.items,
            &host_symbols_active,
            &active_host_owner,
        );
    }

    try testing.expect(reproduced);
}

test "analyze actual assumed_type_2 identifies first prior stmt that poisons line 44" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const source = try std.fs.cwd().readFileAlloc(allocator, "tests/gcc-tests/gfortran.dg/assumed_type_2.f90", 1024 * 1024);
    defer allocator.free(source);

    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const program = try parser.parseProgram(arena.allocator(), lines);

    var known_function_type_specs = std.StringHashMap(symbols.TypeSpec).init(arena.allocator());
    var known_procedure_sigs = std.StringHashMap(context.Context.ProcedureSig).init(arena.allocator());
    var known_host_symbols = std.StringHashMap(symbols.Symbol).init(arena.allocator());
    var known_host_derived_types = std.StringHashMap(context.Context.DerivedTypeInfo).init(arena.allocator());
    var known_host_interface_sources = std.StringHashMap(ast.DeclSource).init(arena.allocator());
    var known_host_abstract_interfaces = std.StringHashMap(void).init(arena.allocator());
    var known_host_implicit_call_sigs = std.StringHashMap(context.Context.ImplicitCallSig).init(arena.allocator());
    var host_symbols_active = false;
    var active_host_owner: ?[]const u8 = null;

    try seedKnownProcedures(arena.allocator(), &.{}, &.{}, &known_function_type_specs, &known_procedure_sigs);
    try inferProgramProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installExplicitInterfaceProcedures(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);
    try interfaces.installSingleTargetGenericInterfaces(arena.allocator(), program, &known_function_type_specs, &known_procedure_sigs);

    var found = false;
    for (program.units) |*unit| {
        if (!std.ascii.eqlIgnoreCase(unit.name, "sub_array_shape")) continue;

        clearInactiveHostContext(
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            &known_host_implicit_call_sigs,
            &host_symbols_active,
            &active_host_owner,
            unit.*,
        );

        var unit_analyzer = analyzer.UnitAnalyzer.init(
            arena.allocator(),
            unit,
            &.{},
            &known_function_type_specs,
            &known_procedure_sigs,
            &known_host_symbols,
            &known_host_derived_types,
            &known_host_interface_sources,
            &known_host_abstract_interfaces,
            active_host_owner,
            .{},
            false,
        );
        unit_analyzer.ctx.known_host_implicit_call_sigs = &known_host_implicit_call_sigs;

        var resolver = resolve_units.Resolver.init(&unit_analyzer.ctx, &.{});
        resolver.run() catch {};

        var target_stmt: ?ast.Stmt = null;
        for (unit.stmts) |stmt| {
            if (stmt.source_line == 44) {
                target_stmt = stmt;
                break;
            }
        }
        const target = target_stmt orelse return error.TestExpectedEqual;

        var first_bad_line: usize = 0;
        for (unit.stmts) |stmt| {
            if (stmt.source_line == 44) break;
            check_statements.checkStmt(&unit_analyzer.ctx, stmt) catch |err| return err;
            procedure_calls.checkProcedureActualArgsForCall(&unit_analyzer.ctx, target.node.call.name, target.node.call.args, .{
                .dummyArgTypeCompatible = testDummyArgTypeCompatible,
            }) catch |err| {
                try testing.expectEqual(error.InvalidArgumentCount, err);
                first_bad_line = stmt.source_line;
                break;
            };
        }

        if (first_bad_line == 0) return error.TestExpectedEqual;
        std.debug.panic("assumed_type_2 first bad prior stmt before line 44: {d}", .{first_bad_line});
        found = true;
        break;
    }

    try testing.expect(found);
}
