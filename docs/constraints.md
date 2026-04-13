# Compiler Constraints

This document is generated from the code-native constraint registry in `devtools/constraints/mapping.zig`.

The registry is the executable source of truth for constraint metadata and enforcement wiring.
This document is a public English reference for the currently registered constraints.

## Registered Constraints

### DC-A-001: Single code files must not exceed the hard line budget.

- Class: A: Static Forbidden Pattern
- Blocking: blocking
- Primary Enforcers: architecture-audit
- Secondary Enforcers: review checklist
- Rationale: Large files stop being reviewable and invite unrelated work to accumulate in the same hotspot. The limit must fail mechanically instead of relying on grandfather lists or reviewer memory.

### DC-A-002: New duplicate function-body clusters must not enter the mainline.

- Class: A: Static Forbidden Pattern
- Blocking: blocking
- Primary Enforcers: architecture-audit
- Secondary Enforcers: review checklist, path-based CI
- Rationale: Known legacy duplication may temporarily exist behind a code-native baseline, but new clusters or cluster growth must fail mechanically so convergence does not rely on reviewer memory.

### DC-B-001: Do not reuse assignment, actual-argument, and ABI rules across semantic layers.

- Class: B: Unified Model Entry
- Blocking: blocking
- Primary Enforcers: semantic tests
- Secondary Enforcers: architecture-audit, review checklist
- Rationale: These checks may all look like compatibility decisions, but they protect different invariants. Reusing a neighboring rule across layers silently weakens the compiler model and creates broad regressions.

### DC-F-001: Convergence work must remove old paths instead of preserving dual-track behavior.

- Class: F: Review Constraint
- Blocking: non-automatic
- Primary Enforcers: review checklist
- Secondary Enforcers: architecture-audit
- Rationale: A new shared path is not enough if the old path remains writable or decision-making. True convergence requires reducing the number of behavior sources in the tree.

### DC-E-001: External baseline failures must be fed back into first-class compiler constraints and regressions.

- Class: E: Process Constraint
- Blocking: blocking
- Primary Enforcers: path-based CI
- Secondary Enforcers: PR checklist, verify
- Rationale: BLAS, LAPACK, mixed-language projects, and similar baselines must expose missing invariants in the main compiler model. They must not stay as runner folklore or case-local exceptions.

### DC-B-002: New pipeline behavior must enter the PipelineOptions / PipelineResult mainline.

- Class: B: Unified Model Entry
- Blocking: blocking
- Primary Enforcers: integration tests
- Secondary Enforcers: architecture-audit, review checklist
- Rationale: Pipeline-wide behavior belongs in the shared pipeline contract. Hidden local toggles create undocumented forks between parser, semantic, codegen, and driver entry points.

### DC-B-003: TypeSpec is the single source of truth for type semantics.

- Class: B: Unified Model Entry
- Blocking: blocking
- Primary Enforcers: unit tests, integration tests
- Secondary Enforcers: architecture-audit
- Rationale: Type semantics must not be rebuilt from ad hoc symbol fields or compatibility views once TypeSpec already carries the structured information.

### DC-B-004: Descriptor-bearing actual arguments must flow through ArrayActualPlan first.

- Class: B: Unified Model Entry
- Blocking: blocking
- Primary Enforcers: codegen tests
- Secondary Enforcers: golden, architecture-audit
- Rationale: Shape, rank, extent, and multiplier logic must be centralized before lowering. Recomputing them inside local codegen branches recreates drift and duplication.

### DC-B-005: Character-valued paths must flow through CharacterValuePlan.

- Class: B: Unified Model Entry
- Blocking: blocking
- Primary Enforcers: codegen tests
- Secondary Enforcers: golden, architecture-audit
- Rationale: Character data, logical length, storage length, and hidden ABI length handling must stay aligned through one shared value plan.

### DC-B-006: Formatted I/O execution must flow through PreparedExecutionFormatPlan.

- Class: B: Unified Model Entry
- Blocking: blocking
- Primary Enforcers: codegen tests
- Secondary Enforcers: golden, architecture-audit
- Rationale: Formatted I/O lowering must not rebuild dynamic-label, runtime-character, and static-op execution state in scattered local branches once the shared execution plan exists.

### DC-B-007: COMMON and EQUIVALENCE layout decisions must flow through storage_model.

- Class: B: Unified Model Entry
- Blocking: blocking
- Primary Enforcers: semantic tests
- Secondary Enforcers: verify, architecture-audit
- Rationale: Storage overlays, common blocks, and equivalence groups must be derived from one shared storage model instead of being recomputed ad hoc in semantic and codegen paths.

### DC-C-001: Diagnostic Bag is the single source of truth for diagnostics.

- Class: C: Structured Diagnostic
- Blocking: blocking
- Primary Enforcers: diagnostic golden
- Secondary Enforcers: semantic tests, integration tests
- Rationale: Structured notes, helps, spans, and stage-owned diagnostics must travel through one model instead of being reconstructed by runners or fallback caches.

### DC-C-002: The error catalog is the source of truth for stable error identifiers.

- Class: C: Structured Diagnostic
- Blocking: blocking
- Primary Enforcers: architecture-audit
- Secondary Enforcers: integration tests
- Rationale: Generated public references must be derived from the catalog. Hand-maintained mirrors drift and eventually stop matching emitted diagnostics.

### DC-C-003: Compat diagnostic storage must not re-enter parser, driver, or tools paths.

- Class: C: Structured Diagnostic
- Blocking: blocking
- Primary Enforcers: architecture-audit
- Secondary Enforcers: diagnostic golden, review checklist
- Rationale: Once diagnostics are carried through explicit Bag and Diagnostic models, parser, driver, and tooling paths must not regain hidden compat-storage dependencies or publish-side shims.

### DC-D-001: ABI and object-construction decisions must be target-driven, not host-driven.

- Class: D: Behavior Boundary
- Blocking: blocking
- Primary Enforcers: ABI regression
- Secondary Enforcers: verify, architecture-audit
- Rationale: Cross-compilation behavior must not depend on the developer machine. ABI and path decisions must follow explicit target data.

