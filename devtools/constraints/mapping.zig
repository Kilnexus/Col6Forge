const std = @import("std");

pub const ConstraintClass = enum {
    a_static_forbidden,
    b_unified_model,
    c_structured_diagnostic,
    d_behavior_boundary,
    e_process,
    f_review,
};

pub const Executor = enum {
    architecture_audit,
    unit_tests,
    integration_tests,
    semantic_tests,
    codegen_tests,
    golden,
    diagnostic_golden,
    abi_regression,
    verify,
    path_based_ci,
    pr_checklist,
    review_checklist,
};

pub const Blocking = enum {
    blocking,
    non_automatic,
};

pub const Entry = struct {
    id: []const u8,
    summary: []const u8,
    rationale: []const u8,
    class: ConstraintClass,
    primary: []const Executor,
    secondary: []const Executor,
    blocking: Blocking,
};

pub const entries = [_]Entry{
    .{
        .id = "DC-A-001",
        .summary = "Single code files must not exceed the hard line budget.",
        .rationale = "Large files stop being reviewable and invite unrelated work to accumulate in the same hotspot. The limit must fail mechanically instead of relying on grandfather lists or reviewer memory.",
        .class = .a_static_forbidden,
        .primary = &.{.architecture_audit},
        .secondary = &.{.review_checklist},
        .blocking = .blocking,
    },
    .{
        .id = "DC-A-002",
        .summary = "New duplicate function-body clusters must not enter the mainline.",
        .rationale = "Known legacy duplication may temporarily exist behind a code-native baseline, but new clusters or cluster growth must fail mechanically so convergence does not rely on reviewer memory.",
        .class = .a_static_forbidden,
        .primary = &.{.architecture_audit},
        .secondary = &.{ .review_checklist, .path_based_ci },
        .blocking = .blocking,
    },
    .{
        .id = "DC-B-001",
        .summary = "Do not reuse assignment, actual-argument, and ABI rules across semantic layers.",
        .rationale = "These checks may all look like compatibility decisions, but they protect different invariants. Reusing a neighboring rule across layers silently weakens the compiler model and creates broad regressions.",
        .class = .b_unified_model,
        .primary = &.{.semantic_tests},
        .secondary = &.{.architecture_audit, .review_checklist},
        .blocking = .blocking,
    },
    .{
        .id = "DC-F-001",
        .summary = "Convergence work must remove old paths instead of preserving dual-track behavior.",
        .rationale = "A new shared path is not enough if the old path remains writable or decision-making. True convergence requires reducing the number of behavior sources in the tree.",
        .class = .f_review,
        .primary = &.{.review_checklist},
        .secondary = &.{.architecture_audit},
        .blocking = .non_automatic,
    },
    .{
        .id = "DC-E-001",
        .summary = "External baseline failures must be fed back into first-class compiler constraints and regressions.",
        .rationale = "BLAS, LAPACK, mixed-language projects, and similar baselines must expose missing invariants in the main compiler model. They must not stay as runner folklore or case-local exceptions.",
        .class = .e_process,
        .primary = &.{.path_based_ci},
        .secondary = &.{.pr_checklist, .verify},
        .blocking = .blocking,
    },
    .{
        .id = "DC-B-002",
        .summary = "New pipeline behavior must enter the PipelineOptions / PipelineResult mainline.",
        .rationale = "Pipeline-wide behavior belongs in the shared pipeline contract. Hidden local toggles create undocumented forks between parser, semantic, codegen, and driver entry points.",
        .class = .b_unified_model,
        .primary = &.{.integration_tests},
        .secondary = &.{.architecture_audit, .review_checklist},
        .blocking = .blocking,
    },
    .{
        .id = "DC-B-003",
        .summary = "TypeSpec is the single source of truth for type semantics.",
        .rationale = "Type semantics must not be rebuilt from ad hoc symbol fields or compatibility views once TypeSpec already carries the structured information.",
        .class = .b_unified_model,
        .primary = &.{ .unit_tests, .integration_tests },
        .secondary = &.{.architecture_audit},
        .blocking = .blocking,
    },
    .{
        .id = "DC-B-004",
        .summary = "Descriptor-bearing actual arguments must flow through ArrayActualPlan first.",
        .rationale = "Shape, rank, extent, and multiplier logic must be centralized before lowering. Recomputing them inside local codegen branches recreates drift and duplication.",
        .class = .b_unified_model,
        .primary = &.{.codegen_tests},
        .secondary = &.{ .golden, .architecture_audit },
        .blocking = .blocking,
    },
    .{
        .id = "DC-B-010",
        .summary = "Cross-unit known procedure metadata must flow through KnownFunctionType and KnownProcedureSig.",
        .rationale = "Known function return types and known procedure signatures must stay in one shared cross-unit model so semantic and codegen lanes do not drift on purity, elemental state, and result metadata.",
        .class = .b_unified_model,
        .primary = &.{ .semantic_tests, .codegen_tests },
        .secondary = &.{ .verify, .architecture_audit },
        .blocking = .blocking,
    },
    .{
        .id = "DC-B-005",
        .summary = "Character-valued paths must flow through CharacterValuePlan.",
        .rationale = "Character data, logical length, storage length, and hidden ABI length handling must stay aligned through one shared value plan.",
        .class = .b_unified_model,
        .primary = &.{.codegen_tests},
        .secondary = &.{ .golden, .architecture_audit },
        .blocking = .blocking,
    },
    .{
        .id = "DC-B-006",
        .summary = "Formatted I/O execution must flow through PreparedExecutionFormatPlan.",
        .rationale = "Formatted I/O lowering must not rebuild dynamic-label, runtime-character, and static-op execution state in scattered local branches once the shared execution plan exists.",
        .class = .b_unified_model,
        .primary = &.{.codegen_tests},
        .secondary = &.{ .golden, .architecture_audit },
        .blocking = .blocking,
    },
    .{
        .id = "DC-B-007",
        .summary = "COMMON and EQUIVALENCE layout decisions must flow through storage_model.",
        .rationale = "Storage overlays, common blocks, and equivalence groups must be derived from one shared storage model instead of being recomputed ad hoc in semantic and codegen paths.",
        .class = .b_unified_model,
        .primary = &.{.semantic_tests},
        .secondary = &.{ .verify, .architecture_audit },
        .blocking = .blocking,
    },
    .{
        .id = "DC-C-001",
        .summary = "Diagnostic Bag is the single source of truth for diagnostics.",
        .rationale = "Structured notes, helps, spans, and stage-owned diagnostics must travel through one model instead of being reconstructed by runners or fallback caches.",
        .class = .c_structured_diagnostic,
        .primary = &.{.diagnostic_golden},
        .secondary = &.{ .semantic_tests, .integration_tests },
        .blocking = .blocking,
    },
    .{
        .id = "DC-C-002",
        .summary = "The error catalog is the source of truth for stable error identifiers.",
        .rationale = "Generated public references must be derived from the catalog. Hand-maintained mirrors drift and eventually stop matching emitted diagnostics.",
        .class = .c_structured_diagnostic,
        .primary = &.{.architecture_audit},
        .secondary = &.{.integration_tests},
        .blocking = .blocking,
    },
    .{
        .id = "DC-C-003",
        .summary = "Compat diagnostic storage must not re-enter parser, driver, or tools paths.",
        .rationale = "Once diagnostics are carried through explicit Bag and Diagnostic models, parser, driver, and tooling paths must not regain hidden compat-storage dependencies or publish-side shims.",
        .class = .c_structured_diagnostic,
        .primary = &.{.architecture_audit},
        .secondary = &.{ .diagnostic_golden, .review_checklist },
        .blocking = .blocking,
    },
    .{
        .id = "DC-D-001",
        .summary = "ABI and object-construction decisions must be target-driven, not host-driven.",
        .rationale = "Cross-compilation behavior must not depend on the developer machine. ABI and path decisions must follow explicit target data.",
        .class = .d_behavior_boundary,
        .primary = &.{.abi_regression},
        .secondary = &.{ .verify, .architecture_audit },
        .blocking = .blocking,
    },
    .{
        .id = "DC-D-002",
        .summary = "Codegen prelude metadata must be collected through the shared unit_prep path.",
        .rationale = "Procedure prelude metadata such as purity, elemental state, and explicit-interface signatures must be seeded through one codegen prelude lane instead of ad hoc local reconstruction in later lowering stages.",
        .class = .d_behavior_boundary,
        .primary = &.{.codegen_tests},
        .secondary = &.{ .golden, .architecture_audit },
        .blocking = .blocking,
    },
};

pub fn validateEntries() !void {
    for (entries, 0..) |entry, idx| {
        if (entry.id.len == 0 or entry.summary.len == 0 or entry.rationale.len == 0) {
            return error.IncompleteConstraintMapping;
        }
        if (entry.primary.len == 0) return error.ConstraintMappingMissingPrimaryExecutor;
        for (entries[idx + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateConstraintMappingId;
        }
        if (entry.secondary.len != 0) {
            for (entry.primary) |primary| {
                for (entry.secondary) |secondary| {
                    if (primary == secondary) return error.ConstraintMappingDuplicatedExecutorRole;
                }
            }
        }
    }
}

pub fn classLabel(class: ConstraintClass) []const u8 {
    return switch (class) {
        .a_static_forbidden => "A: Static Forbidden Pattern",
        .b_unified_model => "B: Unified Model Entry",
        .c_structured_diagnostic => "C: Structured Diagnostic",
        .d_behavior_boundary => "D: Behavior Boundary",
        .e_process => "E: Process Constraint",
        .f_review => "F: Review Constraint",
    };
}

pub fn executorLabel(executor: Executor) []const u8 {
    return switch (executor) {
        .architecture_audit => "architecture-audit",
        .unit_tests => "unit tests",
        .integration_tests => "integration tests",
        .semantic_tests => "semantic tests",
        .codegen_tests => "codegen tests",
        .golden => "golden",
        .diagnostic_golden => "diagnostic golden",
        .abi_regression => "ABI regression",
        .verify => "verify",
        .path_based_ci => "path-based CI",
        .pr_checklist => "PR checklist",
        .review_checklist => "review checklist",
    };
}

pub fn blockingLabel(blocking: Blocking) []const u8 {
    return switch (blocking) {
        .blocking => "blocking",
        .non_automatic => "non-automatic",
    };
}

pub fn joinExecutors(
    allocator: std.mem.Allocator,
    executors: []const Executor,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (executors, 0..) |executor, idx| {
        if (idx != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, executorLabel(executor));
    }
    return out.toOwnedSlice(allocator);
}

test "constraint mapping registry validates" {
    try validateEntries();
}
