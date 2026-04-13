const model = @import("../model.zig");

const UsageSpec = struct {
    id: []const u8,
    symbol_name: []const u8,
    import_fragment: ?[]const u8 = null,
    call_path: ?[]const u8 = null,
    alias_path: ?[]const u8 = null,
};

fn buildUsageRules(
    comptime title: []const u8,
    comptime scope: model.Scope,
    comptime specs: []const UsageSpec,
    comptime excluded_exact_paths: []const []const u8,
    comptime excluded_path_prefixes: []const []const u8,
) [specs.len]model.AuditRule {
    var rules: [specs.len]model.AuditRule = undefined;
    inline for (specs, 0..) |spec, idx| {
        rules[idx] = .{
            .id = spec.id,
            .title = title,
            .kind = .owned_symbol_usage,
            .scope = scope,
            .needle = spec.import_fragment,
            .symbol_name = spec.symbol_name,
            .call_path = spec.call_path,
            .alias_path = spec.alias_path,
            .excluded_exact_paths = excluded_exact_paths,
            .excluded_path_prefixes = excluded_path_prefixes,
        };
    }
    return rules;
}

const io_binary_v_prefix = "src/runtime/col6forge_rt/io_binary_v/";
const io_binary_v_shared = "src/runtime/col6forge_rt/io_binary_v/shared.zig";
const io_binary_v_title = "io_binary_v runtime helper use must stay behind the shared facade";

const codegen_io_prefix = "src/codegen/llvm/stmts/io/";
const implied_helpers_owner = "src/codegen/llvm/stmts/io/implied_helpers.zig";
const implied_helpers_title = "implied-do helper use must import the shared helper module";
const implied_helpers_alias_title = "implied-do helper use must import the shared helper module and bind aliases to the owner";

const runtime_prefix = "src/runtime/col6forge_rt/";
const runtime_args_owner = "src/runtime/col6forge_rt/runtime_args.zig";
const runtime_memory_owner = "src/runtime/col6forge_rt/runtime_memory.zig";
const runtime_stride_owner = "src/runtime/col6forge_rt/runtime_stride.zig";
const runtime_text_owner = "src/runtime/col6forge_rt/runtime_text.zig";
const runtime_facade_prefixes = &.{
    "src/runtime/col6forge_rt/io_binary_v/",
    "src/runtime/col6forge_rt/io_list_read/",
};
const runtime_args_title = "runtime argument helper use must import the shared helper module and bind aliases to runtime_args";
const runtime_memory_title = "runtime memory helper use must import the shared helper module and bind aliases to runtime_memory";
const runtime_stride_title = "runtime stride helper use must import the shared helper module and bind aliases to runtime_stride";
const runtime_text_title = "runtime text helper use must import the shared helper module and bind aliases to runtime_text";

const io_list_read_prefix = "src/runtime/col6forge_rt/io_list_read/";
const io_list_read_shared = "src/runtime/col6forge_rt/io_list_read/shared.zig";
const io_list_read_title = "io_list_read shared helper use must import the shared facade module and bind aliases to shared";

const array_actual_validation_prefix = "src/codegen/llvm/codegen/expression/";
const array_actual_validation_owner = "src/codegen/llvm/codegen/expression/call/shared.zig";
const array_actual_validation_title = "array actual validation must stay behind the shared array-actual module";

const character_plan_validation_prefix = "src/codegen/llvm/codegen/expression/dispatch/";
const character_plan_validation_owner = "src/codegen/llvm/codegen/expression/dispatch/shared.zig";
const character_plan_validation_title = "character value plan validation must stay behind the shared character module";

const storage_model_usage_title = "storage model helper use must stay behind the storage_model module";

const verify_runner_entry = "src/tools/verify_runner.zig";
const blas_runner_entry = "src/tools/blas_runner.zig";
const gcc_dg_runner_entry = "src/tools/gcc_dg_runner.zig";
const verify_runner_title = "verify runner root entry must stay wired through dedicated submodules";
const blas_runner_title = "blas runner root entry must stay wired through dedicated submodules";
const gcc_dg_runner_title = "gcc dg runner root entry must stay wired through dedicated submodules";
const codegen_prelude_title = "codegen module pipeline must consume shared prelude metadata entrypoints";

const io_binary_v_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-001", .symbol_name = "runtimeArgCount", .import_fragment = "shared.zig", .call_path = "shared.runtimeArgCount" },
    .{ .id = "AR-CALL-002", .symbol_name = "runtimeArgPtrAt", .import_fragment = "shared.zig", .call_path = "shared.runtimeArgPtrAt" },
    .{ .id = "AR-CALL-003", .symbol_name = "runtimeArgKindAt", .import_fragment = "shared.zig", .call_path = "shared.runtimeArgKindAt" },
    .{ .id = "AR-CALL-004", .symbol_name = "runtimeArgLenAt", .import_fragment = "shared.zig", .call_path = "shared.runtimeArgLenAt" },
    .{ .id = "AR-CALL-005", .symbol_name = "checkedAdd", .import_fragment = "shared.zig", .call_path = "shared.checkedAdd" },
    .{ .id = "AR-CALL-006", .symbol_name = "checkedMul", .import_fragment = "shared.zig", .call_path = "shared.checkedMul" },
    .{ .id = "AR-CALL-007", .symbol_name = "checkedMulI64", .import_fragment = "shared.zig", .call_path = "shared.checkedMulI64" },
    .{ .id = "AR-CALL-008", .symbol_name = "offsetBytes", .import_fragment = "shared.zig", .call_path = "shared.offsetBytes" },
    .{ .id = "AR-CALL-009", .symbol_name = "offsetConstBytes", .import_fragment = "shared.zig", .call_path = "shared.offsetConstBytes" },
    .{ .id = "AR-CALL-010", .symbol_name = "offsetIndex", .import_fragment = "shared.zig", .call_path = "shared.offsetIndex" },
    .{ .id = "AR-CALL-011", .symbol_name = "complexOffsetIndex", .import_fragment = "shared.zig", .call_path = "shared.complexOffsetIndex" },
};

const implied_helper_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-012", .symbol_name = "impliedLoopDim", .import_fragment = "implied_helpers.zig", .alias_path = "implied_helpers.impliedLoopDim" },
    .{ .id = "AR-CALL-013", .symbol_name = "impliedStrideForDim", .import_fragment = "implied_helpers.zig" },
    .{ .id = "AR-CALL-014", .symbol_name = "impliedStrideForSymbolDim", .import_fragment = "implied_helpers.zig" },
};

const runtime_args_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-015", .symbol_name = "runtimeArgCount", .import_fragment = "runtime_args.zig", .alias_path = "runtime_args.runtimeArgCount" },
    .{ .id = "AR-CALL-016", .symbol_name = "runtimeArgPtrAt", .import_fragment = "runtime_args.zig", .alias_path = "runtime_args.runtimeArgPtrAt" },
    .{ .id = "AR-CALL-017", .symbol_name = "runtimeArgKindAt", .import_fragment = "runtime_args.zig", .alias_path = "runtime_args.runtimeArgKindAt" },
    .{ .id = "AR-CALL-018", .symbol_name = "runtimeArgLenAt", .import_fragment = "runtime_args.zig", .alias_path = "runtime_args.runtimeArgLenAt" },
};

const runtime_memory_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-019", .symbol_name = "checkedAdd", .import_fragment = "runtime_memory.zig", .alias_path = "runtime_memory.checkedAdd" },
    .{ .id = "AR-CALL-020", .symbol_name = "checkedMul", .import_fragment = "runtime_memory.zig", .alias_path = "runtime_memory.checkedMul" },
    .{ .id = "AR-CALL-021", .symbol_name = "checkedMulI64", .import_fragment = "runtime_memory.zig", .alias_path = "runtime_memory.checkedMulI64" },
    .{ .id = "AR-CALL-022", .symbol_name = "offsetBytes", .import_fragment = "runtime_memory.zig", .alias_path = "runtime_memory.offsetBytes" },
    .{ .id = "AR-CALL-023", .symbol_name = "offsetConstBytes", .import_fragment = "runtime_memory.zig", .alias_path = "runtime_memory.offsetConstBytes" },
};

const runtime_stride_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-024", .symbol_name = "offsetIndex", .import_fragment = "runtime_stride.zig", .alias_path = "runtime_stride.offsetIndex" },
    .{ .id = "AR-CALL-025", .symbol_name = "complexOffsetIndex", .import_fragment = "runtime_stride.zig", .alias_path = "runtime_stride.complexOffsetIndex" },
};

const runtime_text_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-026", .symbol_name = "cstrlen", .import_fragment = "runtime_text.zig", .alias_path = "runtime_text.cstrlen" },
    .{ .id = "AR-CALL-027", .symbol_name = "cstrnlen", .import_fragment = "runtime_text.zig", .alias_path = "runtime_text.cstrnlen" },
    .{ .id = "AR-CALL-028", .symbol_name = "cstrlenRaw", .import_fragment = "runtime_text.zig", .alias_path = "runtime_text.cstrlenRaw" },
    .{ .id = "AR-CALL-029", .symbol_name = "asCStr", .import_fragment = "runtime_text.zig", .alias_path = "runtime_text.asCStr" },
    .{ .id = "AR-CALL-030", .symbol_name = "asConstCStr", .import_fragment = "runtime_text.zig", .alias_path = "runtime_text.asConstCStr" },
};

const io_list_read_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-031", .symbol_name = "runtimeArgCount", .import_fragment = "shared.zig", .alias_path = "shared.runtimeArgCount" },
    .{ .id = "AR-CALL-032", .symbol_name = "runtimeArgPtrAt", .import_fragment = "shared.zig", .alias_path = "shared.runtimeArgPtrAt" },
    .{ .id = "AR-CALL-033", .symbol_name = "runtimeArgKindAt", .import_fragment = "shared.zig", .alias_path = "shared.runtimeArgKindAt" },
    .{ .id = "AR-CALL-034", .symbol_name = "runtimeArgLenAt", .import_fragment = "shared.zig", .alias_path = "shared.runtimeArgLenAt" },
    .{ .id = "AR-CALL-035", .symbol_name = "checkedAdd", .import_fragment = "shared.zig", .alias_path = "shared.checkedAdd" },
    .{ .id = "AR-CALL-036", .symbol_name = "checkedMul", .import_fragment = "shared.zig", .alias_path = "shared.checkedMul" },
    .{ .id = "AR-CALL-037", .symbol_name = "checkedMulI64", .import_fragment = "shared.zig", .alias_path = "shared.checkedMulI64" },
    .{ .id = "AR-CALL-038", .symbol_name = "offsetBytes", .import_fragment = "shared.zig", .alias_path = "shared.offsetBytes" },
    .{ .id = "AR-CALL-039", .symbol_name = "offsetIndex", .import_fragment = "shared.zig", .alias_path = "shared.offsetIndex" },
    .{ .id = "AR-CALL-040", .symbol_name = "complexOffsetIndex", .import_fragment = "shared.zig", .alias_path = "shared.complexOffsetIndex" },
};

const verify_runner_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-072", .symbol_name = "parseArgs", .import_fragment = "verify_runner/cli.zig", .alias_path = "cli.parseArgs" },
    .{ .id = "AR-CALL-073", .symbol_name = "processCase", .import_fragment = "verify_runner/process.zig", .alias_path = "process_mod.processCase" },
};

const blas_runner_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-074", .symbol_name = "compileReference", .import_fragment = "blas_runner/build_helpers.zig", .alias_path = "build_helpers.compileReference" },
    .{ .id = "AR-CALL-075", .symbol_name = "Comparator", .import_fragment = "blas_runner/io_compare.zig", .alias_path = "io_compare.Comparator" },
};

const gcc_dg_runner_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-076", .symbol_name = "parseArgs", .import_fragment = "gcc_dg_runner/cli.zig", .alias_path = "cli.parseArgs" },
    .{ .id = "AR-CALL-077", .symbol_name = "collectRunnableCases", .import_fragment = "gcc_dg_runner/directives.zig", .alias_path = "directives.collectRunnableCases" },
    .{ .id = "AR-CALL-078", .symbol_name = "processCase", .import_fragment = "gcc_dg_runner/process.zig", .alias_path = "process_mod.processCase" },
};

const codegen_prelude_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-085", .symbol_name = "collectPreludeState", .import_fragment = "unit_prep.zig", .call_path = "unit_prep.collectPreludeState" },
    .{ .id = "AR-CALL-086", .symbol_name = "prepareCodegenUnitWithOwnerDecls", .import_fragment = "unit_prep.zig", .call_path = "unit_prep.prepareCodegenUnitWithOwnerDecls" },
};

const array_actual_validation_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-079", .symbol_name = "validatedArrayActual", .import_fragment = "shared.zig", .alias_path = "shared.validatedArrayActual" },
};

const character_plan_validation_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-080", .symbol_name = "validatedCharacterValuePlan", .import_fragment = "shared.zig", .call_path = "shared.validatedCharacterValuePlan" },
};

const storage_model_common_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-081", .symbol_name = "buildUnitCommonBlocks", .call_path = "storage_model.buildUnitCommonBlocks" },
    .{ .id = "AR-CALL-082", .symbol_name = "deinitCommonBlocks", .call_path = "storage_model.deinitCommonBlocks" },
};

const storage_model_equivalence_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-083", .symbol_name = "buildUnitEquivalenceGroups", .call_path = "storage_model.buildUnitEquivalenceGroups" },
    .{ .id = "AR-CALL-084", .symbol_name = "deinitEquivalenceGroups", .call_path = "storage_model.deinitEquivalenceGroups" },
};

const list_directed_stride_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-068", .symbol_name = "impliedStrideForDim", .alias_path = "implied_helpers.impliedStrideForSymbolDim" },
};

const streaming_stride_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-069", .symbol_name = "impliedStrideForDim", .alias_path = "implied_helpers.impliedStrideForSymbolDim" },
};

const special_write_stride_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-070", .symbol_name = "impliedStrideForDim", .alias_path = "implied_helpers.impliedStrideForSymbolDim" },
};

const unformatted_stride_specs = [_]UsageSpec{
    .{ .id = "AR-CALL-071", .symbol_name = "impliedStrideForDim", .alias_path = "implied_helpers.impliedStrideForDims" },
};

const io_binary_v_rules = buildUsageRules(io_binary_v_title, .{ .prefix = io_binary_v_prefix }, io_binary_v_specs[0..], &.{io_binary_v_shared}, &.{});
const implied_helper_rules = buildUsageRules(implied_helpers_alias_title, .{ .prefix = codegen_io_prefix }, implied_helper_specs[0..1], &.{implied_helpers_owner}, &.{});
const implied_helper_import_rules = buildUsageRules(implied_helpers_title, .{ .prefix = codegen_io_prefix }, implied_helper_specs[1..], &.{implied_helpers_owner}, &.{});
const runtime_arg_rules = buildUsageRules(runtime_args_title, .{ .prefix = runtime_prefix }, runtime_args_specs[0..], &.{runtime_args_owner}, runtime_facade_prefixes);
const runtime_memory_rules = buildUsageRules(runtime_memory_title, .{ .prefix = runtime_prefix }, runtime_memory_specs[0..], &.{runtime_memory_owner}, runtime_facade_prefixes);
const runtime_stride_rules = buildUsageRules(runtime_stride_title, .{ .prefix = runtime_prefix }, runtime_stride_specs[0..], &.{runtime_stride_owner}, runtime_facade_prefixes);
const runtime_text_rules = buildUsageRules(runtime_text_title, .{ .prefix = runtime_prefix }, runtime_text_specs[0..], &.{runtime_text_owner}, runtime_facade_prefixes);
const io_list_read_rules = buildUsageRules(io_list_read_title, .{ .prefix = io_list_read_prefix }, io_list_read_specs[0..], &.{io_list_read_shared}, &.{});
const verify_runner_rules = buildUsageRules(verify_runner_title, .{ .prefix = verify_runner_entry }, verify_runner_specs[0..], &.{}, &.{});
const blas_runner_rules = buildUsageRules(blas_runner_title, .{ .prefix = blas_runner_entry }, blas_runner_specs[0..], &.{}, &.{});
const gcc_dg_runner_rules = buildUsageRules(gcc_dg_runner_title, .{ .prefix = gcc_dg_runner_entry }, gcc_dg_runner_specs[0..], &.{}, &.{});
const codegen_prelude_rules = buildUsageRules(codegen_prelude_title, .{ .prefix = "src/codegen/llvm/codegen/module/pipeline.zig" }, codegen_prelude_specs[0..], &.{}, &.{});
const array_actual_validation_rules = buildUsageRules(array_actual_validation_title, .{ .prefix = array_actual_validation_prefix }, array_actual_validation_specs[0..], &.{array_actual_validation_owner}, &.{});
const character_plan_validation_rules = buildUsageRules(character_plan_validation_title, .{ .prefix = character_plan_validation_prefix }, character_plan_validation_specs[0..], &.{character_plan_validation_owner}, &.{});
const storage_model_common_rules = buildUsageRules(storage_model_usage_title, .any, storage_model_common_specs[0..], &.{"src/semantic/split/storage_model.zig"}, &.{});
const storage_model_equivalence_rules = buildUsageRules(storage_model_usage_title, .any, storage_model_equivalence_specs[0..], &.{"src/semantic/split/storage_model.zig"}, &.{});
const list_directed_stride_rules = buildUsageRules("list-directed implied stride alias must bind to implied_helpers", .{ .prefix = "src/codegen/llvm/stmts/io/list_directed.zig" }, list_directed_stride_specs[0..], &.{}, &.{});
const streaming_stride_rules = buildUsageRules("streaming implied stride alias must bind to implied_helpers", .{ .prefix = "src/codegen/llvm/stmts/io/direct/streaming.zig" }, streaming_stride_specs[0..], &.{}, &.{});
const special_write_stride_rules = buildUsageRules("special write implied stride alias must bind to implied_helpers", .{ .prefix = "src/codegen/llvm/stmts/io/formatted/special_write.zig" }, special_write_stride_specs[0..], &.{}, &.{});
const unformatted_stride_rules = buildUsageRules("unformatted implied stride alias must bind to implied_helpers", .{ .prefix = "src/codegen/llvm/stmts/io/unformatted.zig" }, unformatted_stride_specs[0..], &.{}, &.{});

pub const file_rules =
    io_binary_v_rules ++
    implied_helper_rules ++
    implied_helper_import_rules ++
    runtime_arg_rules ++
    runtime_memory_rules ++
    runtime_stride_rules ++
    runtime_text_rules ++
    io_list_read_rules ++
    verify_runner_rules ++
    blas_runner_rules ++
    gcc_dg_runner_rules ++
    codegen_prelude_rules ++
    array_actual_validation_rules ++
    character_plan_validation_rules ++
    storage_model_common_rules ++
    storage_model_equivalence_rules ++
    list_directed_stride_rules ++
    streaming_stride_rules ++
    special_write_stride_rules ++
    unformatted_stride_rules;
