const model = @import("../model.zig");

const OwnerSpec = struct {
    id: []const u8,
    title: []const u8,
    symbol_name: []const u8,
    definition_kind: model.DefinitionKind,
    owner_exact_path: []const u8,
};

fn buildOwnerRules(comptime scope: model.Scope, comptime specs: []const OwnerSpec) [specs.len]model.AuditRule {
    var rules: [specs.len]model.AuditRule = undefined;
    inline for (specs, 0..) |spec, idx| {
        rules[idx] = .{
            .id = spec.id,
            .title = spec.title,
            .kind = .owned_symbol_definition,
            .scope = scope,
            .symbol_name = spec.symbol_name,
            .definition_kind = spec.definition_kind,
            .owner_exact_path = spec.owner_exact_path,
        };
    }
    return rules;
}

const common_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-001",
        .title = "StringContext type owner",
        .symbol_name = "StringContext",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/common/case_insensitive.zig",
    },
    .{
        .id = "AR-OWN-027",
        .title = "procedure pass argument index helper owner",
        .symbol_name = "procedurePassArgIndex",
        .definition_kind = .function,
        .owner_exact_path = "src/common/procedure_pass.zig",
    },
    .{
        .id = "AR-OWN-031",
        .title = "type declaration type-spec helper owner",
        .symbol_name = "typeSpecFromTypeDecl",
        .definition_kind = .function,
        .owner_exact_path = "src/common/type_specs.zig",
    },
    .{
        .id = "AR-OWN-032",
        .title = "procedure type-spec helper owner",
        .symbol_name = "typeSpecFromProcedureType",
        .definition_kind = .function,
        .owner_exact_path = "src/common/type_specs.zig",
    },
    .{
        .id = "AR-OWN-041",
        .title = "compiler Diagnostic type owner",
        .symbol_name = "Diagnostic",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/common/diagnostic.zig",
    },
};

const semantic_model_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-051",
        .title = "TypeSpec type owner",
        .symbol_name = "TypeSpec",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/semantic/type_spec.zig",
    },
    .{
        .id = "AR-OWN-052",
        .title = "KnownFunctionType type owner",
        .symbol_name = "KnownFunctionType",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/semantic/split/api/types.zig",
    },
    .{
        .id = "AR-OWN-053",
        .title = "KnownProcedureSig type owner",
        .symbol_name = "KnownProcedureSig",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/semantic/split/api/types.zig",
    },
};

const frontend_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-029",
        .title = "parser end-keyword helper owner",
        .symbol_name = "isEndKeywordLine",
        .definition_kind = .function,
        .owner_exact_path = "src/frontend/parser/stmt/helpers.zig",
    },
};

const codegen_type_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-002",
        .title = "ArrayActualPlan type owner",
        .symbol_name = "ArrayActualPlan",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/codegen/llvm/codegen/expression/call/shared.zig",
    },
    .{
        .id = "AR-OWN-003",
        .title = "CharacterValuePlan type owner",
        .symbol_name = "CharacterValuePlan",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/codegen/llvm/codegen/expression/dispatch/shared.zig",
    },
    .{
        .id = "AR-OWN-004",
        .title = "PreparedExecutionFormatPlan type owner",
        .symbol_name = "PreparedExecutionFormatPlan",
        .definition_kind = .type_union,
        .owner_exact_path = "src/codegen/llvm/stmts/io/formatted/context.zig",
    },
    .{
        .id = "AR-OWN-044",
        .title = "validated array actual helper owner",
        .symbol_name = "validatedArrayActual",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/codegen/expression/call/shared.zig",
    },
    .{
        .id = "AR-OWN-045",
        .title = "validated character value plan helper owner",
        .symbol_name = "validatedCharacterValuePlan",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/codegen/expression/dispatch/shared.zig",
    },
    .{
        .id = "AR-OWN-046",
        .title = "prepared execution format plan helper owner",
        .symbol_name = "prepareExecutionFormatPlan",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/formatted/context.zig",
    },
    .{
        .id = "AR-OWN-054",
        .title = "codegen prelude collection helper owner",
        .symbol_name = "collectPreludeState",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/codegen/module/unit_prep.zig",
    },
    .{
        .id = "AR-OWN-055",
        .title = "codegen owner-decl prelude merge helper owner",
        .symbol_name = "prepareCodegenUnitWithOwnerDecls",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/codegen/module/unit_prep.zig",
    },
    .{
        .id = "AR-OWN-056",
        .title = "codegen explicit interface prelude signature installer owner",
        .symbol_name = "installExplicitInterfaceProcedureSigs",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/codegen/module/unit_prep.zig",
    },
};

const pipeline_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-042",
        .title = "PipelineOptions type owner",
        .symbol_name = "PipelineOptions",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/driver/pipeline/types.zig",
    },
    .{
        .id = "AR-OWN-043",
        .title = "PipelineResult type owner",
        .symbol_name = "PipelineResult",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/driver/pipeline/types.zig",
    },
};

const semantic_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-005",
        .title = "semantic test DiagCapture owner",
        .symbol_name = "DiagCapture",
        .definition_kind = .type_struct,
        .owner_exact_path = "src/semantic/tests/helpers.zig",
    },
    .{
        .id = "AR-OWN-006",
        .title = "intrinsic assignment compatibility helper owner",
        .symbol_name = "intrinsicAssignmentTypeCompatible",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/analysis/check_statements/mod.zig",
    },
    .{
        .id = "AR-OWN-028",
        .title = "single-note source diagnostic helper owner",
        .symbol_name = "setSingleNoteHelpSourceDiagnostic",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/analysis/resolve_specs/interfaces/diagnostics.zig",
    },
    .{
        .id = "AR-OWN-033",
        .title = "procedure shape-signature helper owner",
        .symbol_name = "shapeSignatureForDims",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/api/procedure_inference/shape_signatures.zig",
    },
    .{
        .id = "AR-OWN-057",
        .title = "known procedure seed helper owner",
        .symbol_name = "seedKnownProcedures",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/api/analyze.zig",
    },
    .{
        .id = "AR-OWN-058",
        .title = "program procedure inference helper owner",
        .symbol_name = "inferProgramProcedures",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/api/analyze.zig",
    },
    .{
        .id = "AR-OWN-059",
        .title = "explicit interface installation helper owner",
        .symbol_name = "installExplicitInterfaceProcedures",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/api/interfaces.zig",
    },
    .{
        .id = "AR-OWN-060",
        .title = "single-target generic interface installation helper owner",
        .symbol_name = "installSingleTargetGenericInterfaces",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/api/interfaces.zig",
    },
};

const storage_model_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-047",
        .title = "storage model common block builder owner",
        .symbol_name = "buildUnitCommonBlocks",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/storage_model.zig",
    },
    .{
        .id = "AR-OWN-048",
        .title = "storage model common block deinit owner",
        .symbol_name = "deinitCommonBlocks",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/storage_model.zig",
    },
    .{
        .id = "AR-OWN-049",
        .title = "storage model equivalence group builder owner",
        .symbol_name = "buildUnitEquivalenceGroups",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/storage_model.zig",
    },
    .{
        .id = "AR-OWN-050",
        .title = "storage model equivalence group deinit owner",
        .symbol_name = "deinitEquivalenceGroups",
        .definition_kind = .function,
        .owner_exact_path = "src/semantic/split/storage_model.zig",
    },
};

const implied_helper_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-007",
        .title = "implied-do identifier scan helper owner",
        .symbol_name = "exprContainsIdentifier",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/implied_helpers.zig",
    },
    .{
        .id = "AR-OWN-008",
        .title = "implied-do dimension helper owner",
        .symbol_name = "impliedLoopDim",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/implied_helpers.zig",
    },
    .{
        .id = "AR-OWN-009",
        .title = "implied-do symbol stride helper owner",
        .symbol_name = "impliedStrideForSymbolDim",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/implied_helpers.zig",
    },
    .{
        .id = "AR-OWN-010",
        .title = "implied-do extent stride helper owner",
        .symbol_name = "impliedStrideForDims",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/implied_helpers.zig",
    },
    .{
        .id = "AR-OWN-030",
        .title = "stream chunk loop helper owner",
        .symbol_name = "emitChunkedStream",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/stream_chunks.zig",
    },
    .{
        .id = "AR-OWN-034",
        .title = "collapsed range subscript helper owner",
        .symbol_name = "emitCollapsedRangeSubscriptValue",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/expansion/collapsed_sections.zig",
    },
    .{
        .id = "AR-OWN-035",
        .title = "collapsed substring section helper owner",
        .symbol_name = "emitCollapsedSubstringSectionValue",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/expansion/collapsed_sections.zig",
    },
    .{
        .id = "AR-OWN-036",
        .title = "collapsed whole-array fallback helper owner",
        .symbol_name = "emitCollapsedUnknownCountWholeArrayValue",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/expansion/collapsed_sections.zig",
    },
    .{
        .id = "AR-OWN-037",
        .title = "io array element count helper owner",
        .symbol_name = "emitArrayElemCountI32",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/stmts/io/array_helpers.zig",
    },
    .{
        .id = "AR-OWN-038",
        .title = "llvm memset helper owner",
        .symbol_name = "emitMemsetByte",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/shared/memory_intrinsics.zig",
    },
    .{
        .id = "AR-OWN-039",
        .title = "llvm memcpy helper owner",
        .symbol_name = "emitMemcpyBytes",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/shared/memory_intrinsics.zig",
    },
    .{
        .id = "AR-OWN-040",
        .title = "array shape equality check helper owner",
        .symbol_name = "emitRequireEqualExtents",
        .definition_kind = .function,
        .owner_exact_path = "src/codegen/llvm/shared/array_shape_checks.zig",
    },
};

const runtime_arg_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-011",
        .title = "runtime argument count helper owner",
        .symbol_name = "runtimeArgCount",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_args.zig",
    },
    .{
        .id = "AR-OWN-012",
        .title = "runtime argument pointer helper owner",
        .symbol_name = "runtimeArgPtrAt",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_args.zig",
    },
    .{
        .id = "AR-OWN-013",
        .title = "runtime argument kind helper owner",
        .symbol_name = "runtimeArgKindAt",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_args.zig",
    },
    .{
        .id = "AR-OWN-014",
        .title = "runtime argument length helper owner",
        .symbol_name = "runtimeArgLenAt",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_args.zig",
    },
};

const runtime_memory_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-015",
        .title = "runtime checked add helper owner",
        .symbol_name = "checkedAdd",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_memory.zig",
    },
    .{
        .id = "AR-OWN-016",
        .title = "runtime checked multiply helper owner",
        .symbol_name = "checkedMul",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_memory.zig",
    },
    .{
        .id = "AR-OWN-017",
        .title = "runtime checked i64 multiply helper owner",
        .symbol_name = "checkedMulI64",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_memory.zig",
    },
    .{
        .id = "AR-OWN-018",
        .title = "runtime mutable byte offset helper owner",
        .symbol_name = "offsetBytes",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_memory.zig",
    },
    .{
        .id = "AR-OWN-019",
        .title = "runtime const byte offset helper owner",
        .symbol_name = "offsetConstBytes",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_memory.zig",
    },
};

const runtime_stride_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-020",
        .title = "runtime element offset helper owner",
        .symbol_name = "offsetIndex",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_stride.zig",
    },
    .{
        .id = "AR-OWN-021",
        .title = "runtime complex element offset helper owner",
        .symbol_name = "complexOffsetIndex",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_stride.zig",
    },
};

const runtime_text_specs = [_]OwnerSpec{
    .{
        .id = "AR-OWN-022",
        .title = "runtime c string length helper owner",
        .symbol_name = "cstrlen",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_text.zig",
    },
    .{
        .id = "AR-OWN-023",
        .title = "runtime bounded c string length helper owner",
        .symbol_name = "cstrnlen",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_text.zig",
    },
    .{
        .id = "AR-OWN-024",
        .title = "runtime raw c string length helper owner",
        .symbol_name = "cstrlenRaw",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_text.zig",
    },
    .{
        .id = "AR-OWN-025",
        .title = "runtime mutable c string cast helper owner",
        .symbol_name = "asCStr",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_text.zig",
    },
    .{
        .id = "AR-OWN-026",
        .title = "runtime const c string cast helper owner",
        .symbol_name = "asConstCStr",
        .definition_kind = .function,
        .owner_exact_path = "src/runtime/col6forge_rt/runtime_text.zig",
    },
};

const common_rules = buildOwnerRules(.{ .domain = .common }, common_specs[0..]);
const semantic_model_rules = buildOwnerRules(.any, semantic_model_specs[0..]);
const frontend_rules = buildOwnerRules(.{ .domain = .frontend }, frontend_specs[0..]);
const codegen_type_rules = buildOwnerRules(.{ .domain = .codegen }, codegen_type_specs[0..]);
const pipeline_rules = buildOwnerRules(.any, pipeline_specs[0..]);
const semantic_rules = buildOwnerRules(.{ .domain = .semantic }, semantic_specs[0..]);
const storage_model_rules = buildOwnerRules(.any, storage_model_specs[0..]);
const implied_helper_rules = buildOwnerRules(.{ .domain = .codegen }, implied_helper_specs[0..]);
const runtime_arg_rules = buildOwnerRules(.{ .domain = .runtime }, runtime_arg_specs[0..]);
const runtime_memory_rules = buildOwnerRules(.{ .domain = .runtime }, runtime_memory_specs[0..]);
const runtime_stride_rules = buildOwnerRules(.{ .domain = .runtime }, runtime_stride_specs[0..]);
const runtime_text_rules = buildOwnerRules(.{ .domain = .runtime }, runtime_text_specs[0..]);

pub const file_rules =
    common_rules ++
    semantic_model_rules ++
    frontend_rules ++
    codegen_type_rules ++
    pipeline_rules ++
    semantic_rules ++
    storage_model_rules ++
    implied_helper_rules ++
    runtime_arg_rules ++
    runtime_memory_rules ++
    runtime_stride_rules ++
    runtime_text_rules;
