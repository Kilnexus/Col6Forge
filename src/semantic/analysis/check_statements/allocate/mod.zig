const ast = @import("../../../../ast/nodes.zig");
const context = @import("../../context.zig");
const options = @import("options.zig");
const targets = @import("targets.zig");
const type_spec = @import("type_spec.zig");

pub const CheckError = anyerror;

pub fn checkAllocateStmt(self: *context.Context, allocate: ast.AllocateStmt, comptime deps: anytype) CheckError!void {
    if (allocate.type_spec) |spec| {
        try type_spec.checkAllocateTypeSpecCompatibility(self, allocate, spec, deps);
    }
    try type_spec.checkAllocateRequiresTypeSpecOrSource(self, allocate);
    for (allocate.items) |item| {
        const target_info = try targets.resolveAllocateTargetInfo(self, item.target);
        if (target_info.procedure) {
            return targets.emitAllocateTargetConstraintDiagnostic(self, item.target, item.source, true);
        }
        if (!target_info.allocatable and !target_info.pointer) {
            return targets.emitAllocateTargetConstraintDiagnostic(self, item.target, item.source, true);
        }
        if (targets.violatesVariableDefinitionContext(self, item.target)) {
            return targets.emitVariableDefinitionContextDiagnostic(self, item.source, item.target);
        }
        if (target_info.rank == 0 and item.dims.len == 0) continue;
        if (target_info.rank == 0) {
            self.setCurrentSource(if (item.source.line != 0) item.source else self.sourceForExpr(item.target));
            return error.UnsupportedAllocateSyntax;
        }
        if (item.dims.len == 0) {
            const inferred_rank = options.allocateSourceOrMoldRank(self, allocate.options, deps);
            if (inferred_rank == target_info.rank) continue;
        }
        if (target_info.rank != item.dims.len) {
            self.setCurrentSource(if (item.source.line != 0) item.source else null);
            return error.InvalidSubscript;
        }
        for (item.dims) |dim| try options.checkAllocateDim(self, dim, deps);
    }
    try targets.checkDuplicateAllocateItems(self, allocate.items);
    try options.checkAllocationOptions(self, allocate.items, allocate.options, true, allocate.type_spec != null, deps);
}

pub fn checkDeallocateStmt(self: *context.Context, deallocate: ast.DeallocateStmt, comptime deps: anytype) CheckError!void {
    for (deallocate.items) |item| {
        const target_info = try targets.resolveAllocateTargetInfo(self, item.target);
        if (!(target_info.allocatable or target_info.pointer)) {
            return targets.emitAllocateTargetConstraintDiagnostic(self, item.target, item.source, false);
        }
        if (targets.violatesVariableDefinitionContext(self, item.target)) {
            return targets.emitVariableDefinitionContextDiagnostic(self, item.source, item.target);
        }
    }
    try targets.checkDuplicateDeallocateItems(self, deallocate.items);
    try options.checkDeallocateOptions(self, deallocate.items, deallocate.options, deps);
}
