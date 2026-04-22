const std = @import("std");
const input = @import("../../../input.zig");
const codegen_diag = @import("../../../diagnostic.zig");
const context = @import("../context/mod.zig");
const builder_mod = @import("../builder.zig");
const stmts = @import("../../stmts/function.zig");
const breakdown_mod = @import("breakdown.zig");
const common_blocks = @import("common_blocks.zig");
const format_maps_mod = @import("format_maps.zig");
const fallbacks = @import("fallbacks.zig");
const intrinsic_wrappers = @import("intrinsic_wrappers.zig");
const unit_prep = @import("unit_prep.zig");

const Program = input.Program;
pub const CodegenOptions = context.CodegenOptions;

fn isWasmTarget(target: ?[]const u8) bool {
    const t = target orelse return false;
    return std.mem.startsWith(u8, t, "wasm32") or std.mem.startsWith(u8, t, "wasm64");
}

fn fallbackUnitForSourceName(program: Program, source_name: []const u8) input.ProgramUnit {
    return if (program.units.len == 0) .{
        .kind = .program,
        .name = source_name,
        .bind_name = null,
        .result_name = null,
        .args = &.{},
        .decls = &.{},
        .decl_sources = &.{},
        .stmts = &.{},
        .expr_sources = &.{},
    } else program.units[0];
}

pub fn emitModule(
    allocator: std.mem.Allocator,
    program: Program,
    sem: input.sema.SemanticProgram,
    source_name: []const u8,
    options: CodegenOptions,
) ![]const u8 {
    var diag_bag = codegen_diag.Bag.init(allocator);
    defer diag_bag.deinit();
    return emitModuleWithDiagnostics(allocator, program, sem, source_name, options, &diag_bag);
}

pub fn emitModuleWithDiagnostics(
    allocator: std.mem.Allocator,
    program: Program,
    sem: input.sema.SemanticProgram,
    source_name: []const u8,
    options: CodegenOptions,
    diag_bag: *codegen_diag.Bag,
) ![]const u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    var unmanaged = buffer.moveToUnmanaged();
    var writer_alloc: std.Io.Writer.Allocating = .fromArrayList(allocator, &unmanaged);
    defer buffer = unmanaged.toManaged(allocator);
    try emitModuleToWriterWithDiagnostics(&writer_alloc.writer, allocator, program, sem, source_name, options, diag_bag);
    unmanaged = writer_alloc.toArrayList();
    return buffer.toOwnedSlice();
}

pub fn emitModuleToWriter(
    writer: anytype,
    allocator: std.mem.Allocator,
    program: Program,
    sem: input.sema.SemanticProgram,
    source_name: []const u8,
    options: CodegenOptions,
) !void {
    var diag_bag = codegen_diag.Bag.init(allocator);
    defer diag_bag.deinit();
    return emitModuleToWriterWithDiagnostics(writer, allocator, program, sem, source_name, options, &diag_bag);
}

pub fn emitModuleToWriterWithDiagnostics(
    writer: anytype,
    allocator: std.mem.Allocator,
    program: Program,
    sem: input.sema.SemanticProgram,
    source_name: []const u8,
    options: CodegenOptions,
    diag_bag: *codegen_diag.Bag,
) !void {
    diag_bag.clear();
    breakdown_mod.clearLastBreakdownSample();
    var timings: breakdown_mod.CodegenBreakdownSample = .{};
    const total_start = breakdown_mod.nowNs();
    defer {
        timings.total_ns = breakdown_mod.elapsedNs(total_start);
        breakdown_mod.storeLastBreakdownSample(timings);
    }

    const prelude_start = breakdown_mod.nowNs();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var builder = builder_mod.Builder(@TypeOf(writer)).initWithOptions(writer, .{
        .lower_common_as_weak = isWasmTarget(options.target),
    });
    try builder.moduleHeader(source_name);

    var decls = std.StringHashMap(context.IRDecl).init(scratch);
    defer decls.deinit();
    var defined = std.StringHashMap(void).init(scratch);
    defer defined.deinit();
    var known_procedure_sigs = context.CaseInsensitiveStringHashMap(input.sema.KnownProcedureSig).initContext(scratch, .{});
    defer known_procedure_sigs.deinit();

    if (sem.units.len != program.units.len) {
        breakdown_mod.markFailure(&timings, .prelude);
        fallbacks.setCodegenDiagForUnit(diag_bag, fallbackUnitForSourceName(program, source_name), error.MissingSemanticUnit);
        return error.MissingSemanticUnit;
    }

    var prelude_state = unit_prep.collectPreludeState(
        scratch,
        program,
        options.known_procedure_sigs,
        &defined,
        &known_procedure_sigs,
    ) catch |err| {
        breakdown_mod.markFailure(&timings, .prelude);
        if (err == error.MultipleProgramUnits) {
            const info = codegen_diag.codegenErrorInfo(err);
            diag_bag.set(1, 1, info.code, info.message, "");
        } else {
            fallbacks.setCodegenDiagForUnit(diag_bag, fallbackUnitForSourceName(program, source_name), err);
        }
        return err;
    };
    defer prelude_state.deinit();
    timings.prelude_ns = breakdown_mod.elapsedNs(prelude_start);

    const common_start = breakdown_mod.nowNs();
    var conflict_unit_idx: ?usize = null;
    var common_map = common_blocks.buildCommonBlocks(scratch, program, sem, options, &conflict_unit_idx) catch |err| {
        breakdown_mod.markFailure(&timings, .common_layouts);
        if (conflict_unit_idx) |unit_idx| {
            fallbacks.setCodegenDiagForUnit(diag_bag, program.units[unit_idx], err);
        } else if (program.units.len > 0) {
            fallbacks.setCodegenDiagForUnit(diag_bag, program.units[0], err);
        }
        return err;
    };
    defer common_map.deinit();
    try common_blocks.emitCommonGlobals(&builder, &common_map);
    timings.common_layouts_ns = breakdown_mod.elapsedNs(common_start);

    var string_pool = context.StringPool.init(scratch);
    defer string_pool.deinit();
    var intrinsic_wrapper_map = std.StringHashMap(context.IntrinsicWrapperKind).init(scratch);
    defer intrinsic_wrapper_map.deinit();

    for (program.units, 0..) |unit, unit_idx| {
        if (unit.kind == .module) continue;
        fallbacks.noteFallbackForUnit(diag_bag, unit);

        const format_start = breakdown_mod.nowNs();
        const sem_unit = &sem.units[unit_idx];
        var unit_formats = format_maps_mod.buildFormatMaps(scratch, &builder, unit, diag_bag) catch |err| {
            breakdown_mod.markFailure(&timings, .format_maps);
            fallbacks.setCodegenDiagForUnit(diag_bag, unit, err);
            return err;
        };
        timings.format_maps_ns += breakdown_mod.elapsedNs(format_start);

        const unit_emit_start = breakdown_mod.nowNs();
        const codegen_unit = try unit_prep.prepareCodegenUnitWithOwnerDecls(scratch, program, unit);
        var ctx = try context.Context.init(
            scratch,
            source_name,
            codegen_unit,
            sem_unit,
            &decls,
            &defined,
            &unit_formats.labels,
            &unit_formats.inline_items,
            &string_pool,
            &intrinsic_wrapper_map,
            &known_procedure_sigs,
            options,
            diag_bag,
        );
        defer ctx.deinit();
        stmts.emitFunction(&ctx, &builder) catch |err| {
            breakdown_mod.markFailure(&timings, .unit_emit);
            if (!ctx.hasDiagnostic()) {
                if (ctx.current_source) |source| {
                    ctx.setDiagnosticFromSource(source, err);
                } else if (ctx.current_stmt) |stmt| {
                    ctx.setDiagnosticFromStmt(stmt, err);
                } else {
                    fallbacks.setCodegenDiagForUnit(diag_bag, unit, err);
                }
            }
            return err;
        };
        timings.unit_emit_ns += breakdown_mod.elapsedNs(unit_emit_start);
    }

    const wrappers_start = breakdown_mod.nowNs();
    try intrinsic_wrappers.emitIntrinsicWrappers(&builder, &intrinsic_wrapper_map, options);
    timings.intrinsic_wrappers_ns = breakdown_mod.elapsedNs(wrappers_start);

    const strings_start = breakdown_mod.nowNs();
    for (string_pool.items.items) |entry| {
        try builder.globalString(entry.name, entry.bytes);
    }
    timings.string_globals_ns = breakdown_mod.elapsedNs(strings_start);

    const main_start = breakdown_mod.nowNs();
    if (prelude_state.program_mangled) |entry_name| {
        try builder.defineStartWithRet(.i32, "main");
        try builder.defineEnd();
        try builder.entryLabel();
        for (prelude_state.block_data_mangled.items) |block_name| {
            try builder.callTyped(null, .void, block_name, &.{});
        }
        try builder.callTyped(null, .void, entry_name, &.{});
        try builder.retValue(.i32, "0");
        try builder.functionEnd();
    }
    timings.entry_main_ns = breakdown_mod.elapsedNs(main_start);

    const decls_start = breakdown_mod.nowNs();
    var decl_it = decls.iterator();
    while (decl_it.next()) |entry| {
        const decl = entry.value_ptr.*;
        const name = entry.key_ptr.*;
        try builder.declare(name, decl.ret_type, decl.sig, decl.varargs);
    }
    timings.decls_ns = breakdown_mod.elapsedNs(decls_start);
}
