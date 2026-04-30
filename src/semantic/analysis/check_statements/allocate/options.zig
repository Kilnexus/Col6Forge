const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const symbols = @import("../../../symbol/mod.zig");
const context = @import("../../context.zig");
const resolve_expr = @import("../../resolve_expr.zig");
const resolve_symbols = @import("../../resolve_symbols.zig");
const targets = @import("targets.zig");

const ResolvedRefKind = symbols.ResolvedRefKind;
pub const CheckError = anyerror;

pub fn checkAllocateDim(self: *context.Context, expr: *ast.Expr, comptime deps: anytype) CheckError!void {
    const ty = try deps.checkExprType(self, expr, .{
        .dummyArgTypeCompatible = deps.dummyArgTypeCompatible,
    });
    if (ty != .integer or exprRank(self, expr, deps) != 0) {
        self.setCurrentSource(self.sourceForExpr(expr));
        return error.InvalidSubscript;
    }
}

pub fn checkAllocateItemDimTargetReferences(
    self: *context.Context,
    items: []const ast.AllocateItem,
    comptime deps: anytype,
) CheckError!void {
    for (items) |item| {
        for (item.dims) |dim| {
            for (items) |target_item| {
                if (!allocationOptionReferencesTarget(self, dim, target_item.target, deps)) continue;
                self.setDiagnostic(
                    if (item.source.line == 0) 1 else item.source.line,
                    if (item.source.column == 0) 1 else item.source.column,
                    catalog.semantic.duplicate_declaration.code,
                    "same ALLOCATE statement",
                    item.source.text,
                );
                return error.DuplicateDeclaration;
            }
        }
    }
}

pub fn allocateSourceOrMoldRank(
    self: *context.Context,
    options: []const ast.AllocationOption,
    comptime deps: anytype,
) usize {
    for (options) |option| {
        switch (option.kind) {
            .source, .mold => return exprRank(self, option.value, deps),
            else => {},
        }
    }
    return 0;
}

pub fn checkAllocationOptions(
    self: *context.Context,
    items: []const ast.AllocateItem,
    options: []const ast.AllocationOption,
    is_allocate: bool,
    has_type_spec: bool,
    comptime deps: anytype,
) CheckError!void {
    var saw_stat = false;
    var saw_errmsg = false;
    var saw_source = false;
    var saw_mold = false;

    for (options) |option| {
        self.setCurrentSource(if (option.source.line != 0) option.source else self.sourceForExpr(option.value));
        const value_ty = try deps.checkExprType(self, option.value, .{
            .dummyArgTypeCompatible = deps.dummyArgTypeCompatible,
        });
        switch (option.kind) {
            .stat => {
                if (saw_stat) return duplicateTag(self, option, "Redundant STAT");
                saw_stat = true;
                if (deps.identifierRequiresArgumentList(self, option.value)) return missingArgList(self, option);
                if (isParameterInquiryExpr(option.value)) {
                    self.setDiagnostic(
                        if (option.source.line == 0) 1 else option.source.line,
                        if (option.source.column == 0) 1 else option.source.column,
                        catalog.semantic.assignment_type_mismatch.code,
                        "parameter inquiry",
                        option.source.text,
                    );
                    return error.AssignmentTypeMismatch;
                }
                if (value_ty != .integer or exprRank(self, option.value, deps) != 0) {
                    self.setDiagnostic(
                        if (option.source.line == 0) 1 else option.source.line,
                        if (option.source.column == 0) 1 else option.source.column,
                        catalog.semantic.assignment_type_mismatch.code,
                        "must be a scalar INTEGER",
                        option.source.text,
                    );
                    return error.AssignmentTypeMismatch;
                }
                if (targets.violatesVariableDefinitionContext(self, option.value)) {
                    return targets.emitVariableDefinitionContextDiagnostic(self, option.source, option.value);
                }
            },
            .errmsg => {
                if (saw_errmsg) return duplicateTag(self, option, "Redundant ERRMSG");
                saw_errmsg = true;
                if (deps.identifierRequiresArgumentList(self, option.value)) return missingArgList(self, option);
                const value_spec = try resolve_expr.exprTypeSpec(self, option.value);
                const is_default_char = (value_spec.kind_value orelse 1) == 1;
                if (value_ty != .character or exprRank(self, option.value, deps) != 0 or !is_default_char) {
                    self.setDiagnostic(
                        if (option.source.line == 0) 1 else option.source.line,
                        if (option.source.column == 0) 1 else option.source.column,
                        catalog.semantic.assignment_type_mismatch.code,
                        "shall be a scalar default CHARACTER",
                        option.source.text,
                    );
                    return error.AssignmentTypeMismatch;
                }
                if (targets.violatesVariableDefinitionContext(self, option.value)) {
                    return targets.emitVariableDefinitionContextDiagnostic(self, option.source, option.value);
                }
            },
            .source => {
                if (saw_mold) return duplicateTag(self, option, "conflicts with MOLD tag");
                if (has_type_spec) return duplicateTag(self, option, "conflicts with the typespec");
                if (saw_source) return duplicateTag(self, option, "Redundant SOURCE");
                saw_source = true;
                try checkAllocateOptionTypeCompatibility(self, items, option, deps);
            },
            .mold => {
                if (saw_source) return duplicateTag(self, option, "conflicts with SOURCE tag");
                if (has_type_spec) return duplicateTag(self, option, "conflicts with the typespec");
                if (saw_mold) return duplicateTag(self, option, "Redundant MOLD");
                saw_mold = true;
                try checkAllocateOptionTypeCompatibility(self, items, option, deps);
            },
        }
    }

    for (options) |option| {
        for (items) |item| {
            if (!allocationOptionReferencesTarget(self, option.value, item.target, deps)) continue;
            self.setDiagnostic(
                if (option.source.line == 0) 1 else option.source.line,
                if (option.source.column == 0) 1 else option.source.column,
                catalog.semantic.duplicate_declaration.code,
                if (is_allocate) "shall not be ALLOCATEd within" else "shall not be DEALLOCATEd within",
                option.source.text,
            );
            return error.DuplicateDeclaration;
        }
    }
}

pub fn checkDeallocateOptions(
    self: *context.Context,
    items: []const ast.DeallocateItem,
    options: []const ast.AllocationOption,
    comptime deps: anytype,
) CheckError!void {
    var alloc_items = try self.arena.alloc(ast.AllocateItem, items.len);
    for (items, 0..) |item, idx| {
        alloc_items[idx] = .{ .target = item.target, .dims = &.{}, .source = item.source };
    }
    try checkAllocationOptions(self, alloc_items, options, false, false, deps);
}

pub fn exprRank(self: *context.Context, expr: *ast.Expr, comptime deps: anytype) usize {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk 0;
            break :blk self.symbols.items[idx].dims.len;
        },
        .array_constructor => 1,
        .call_or_subscript => |call| blk: {
            const idx = deps.symbolIndexForResolvedCall(self, expr) orelse
                (resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk 0);
            const sym = self.symbols.items[idx];
            const kind: ResolvedRefKind = deps.resolvedKindFor(self, expr) orelse
                (if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call);
            if (kind == .subscript) break :blk 0;
            if (resolve_symbols.lookupKnownProcedureSig(self, call.name)) |sig| break :blk sig.result_rank;
            break :blk sym.dims.len;
        },
        .component => |comp| blk: {
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk 0;
            if (base_spec.lowered_kind != .derived) break :blk 0;
            const derived_name = base_spec.derived_type_name orelse break :blk 0;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk 0;
            break :blk if (comp.args.len == 0) component.dims.len else 0;
        },
        .unary => |un| exprRank(self, un.expr, deps),
        .binary => |bin| @max(exprRank(self, bin.left, deps), exprRank(self, bin.right, deps)),
        .implied_do => 1,
        else => 0,
    };
}

fn checkAllocateOptionTypeCompatibility(
    self: *context.Context,
    items: []const ast.AllocateItem,
    option: ast.AllocationOption,
    comptime deps: anytype,
) CheckError!void {
    const value_spec = try resolve_expr.exprTypeSpec(self, option.value);
    const value_rank = exprRank(self, option.value, deps);
    for (items) |item| {
        const target_spec = try targets.allocateTargetTypeSpec(self, item.target);
        if (!deps.dummyArgTypeCompatible(self, target_spec, value_spec)) {
            self.setDiagnostic(
                if (option.source.line == 0) 1 else option.source.line,
                if (option.source.column == 0) 1 else option.source.column,
                catalog.semantic.assignment_type_mismatch.code,
                "is type incompatible",
                option.source.text,
            );
            return error.AssignmentTypeMismatch;
        }
        if (item.dims.len == 0) {
            const target_info = try targets.resolveAllocateTargetInfo(self, item.target);
            if (value_rank != 0 and target_info.rank != value_rank) {
                self.setDiagnostic(
                    if (option.source.line == 0) 1 else option.source.line,
                    if (option.source.column == 0) 1 else option.source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "must be scalar or have the same rank",
                    option.source.text,
                );
                return error.AssignmentTypeMismatch;
            }
        }
    }
}

fn allocationOptionReferencesTarget(self: *context.Context, expr: *ast.Expr, target: *ast.Expr, comptime deps: anytype) bool {
    return switch (expr.*) {
        .identifier => targetExprMatchesName(target, expr.identifier),
        .call_or_subscript => |call| blk: {
            if (targetExprMatchesName(target, call.name)) break :blk true;
            for (call.args) |arg| {
                if (allocationOptionReferencesTarget(self, arg, target, deps)) break :blk true;
            }
            break :blk false;
        },
        .component => |comp| blk: {
            if (allocationOptionReferencesTarget(self, comp.base, target, deps)) break :blk true;
            for (comp.args) |arg| {
                if (allocationOptionReferencesTarget(self, arg, target, deps)) break :blk true;
            }
            break :blk false;
        },
        .array_constructor => |ctor| blk: {
            for (ctor.items) |item| {
                if (allocationOptionReferencesTarget(self, item, target, deps)) break :blk true;
            }
            break :blk false;
        },
        .substring => |sub| blk: {
            if (targetExprMatchesName(target, sub.name)) break :blk true;
            for (sub.args) |arg| {
                if (allocationOptionReferencesTarget(self, arg, target, deps)) break :blk true;
            }
            if (sub.start) |start| if (allocationOptionReferencesTarget(self, start, target, deps)) break :blk true;
            if (sub.end) |end_expr| if (allocationOptionReferencesTarget(self, end_expr, target, deps)) break :blk true;
            break :blk false;
        },
        .unary => |un| allocationOptionReferencesTarget(self, un.expr, target, deps),
        .binary => |bin| allocationOptionReferencesTarget(self, bin.left, target, deps) or allocationOptionReferencesTarget(self, bin.right, target, deps),
        .complex_literal => |lit| allocationOptionReferencesTarget(self, lit.real, target, deps) or allocationOptionReferencesTarget(self, lit.imag, target, deps),
        .dim_range => |range| blk: {
            if (range.lower) |lower| if (allocationOptionReferencesTarget(self, lower, target, deps)) break :blk true;
            if (allocationOptionReferencesTarget(self, range.upper, target, deps)) break :blk true;
            if (range.stride) |stride| if (allocationOptionReferencesTarget(self, stride, target, deps)) break :blk true;
            break :blk false;
        },
        .implied_do => |implied| blk: {
            if (allocationOptionReferencesTarget(self, implied.start, target, deps)) break :blk true;
            if (allocationOptionReferencesTarget(self, implied.end, target, deps)) break :blk true;
            if (implied.step) |step| if (allocationOptionReferencesTarget(self, step, target, deps)) break :blk true;
            for (implied.items) |item| {
                if (allocationOptionReferencesTarget(self, item, target, deps)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn targetExprMatchesName(target: *ast.Expr, name: []const u8) bool {
    return switch (target.*) {
        .identifier => std.ascii.eqlIgnoreCase(target.identifier, name),
        .component => targetExprMatchesName(target.component.base, name),
        .call_or_subscript => std.ascii.eqlIgnoreCase(target.call_or_subscript.name, name),
        else => false,
    };
}

fn isParameterInquiryExpr(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .component => |comp| {
            if (comp.args.len != 0) return false;
            if (std.ascii.eqlIgnoreCase(comp.name, "len") or std.ascii.eqlIgnoreCase(comp.name, "kind")) return true;
            return isParameterInquiryExpr(comp.base);
        },
        else => false,
    };
}

fn duplicateTag(self: *context.Context, option: ast.AllocationOption, message: []const u8) CheckError {
    self.setDiagnostic(
        if (option.source.line == 0) 1 else option.source.line,
        if (option.source.column == 0) 1 else option.source.column,
        catalog.semantic.duplicate_declaration.code,
        message,
        option.source.text,
    );
    return error.DuplicateDeclaration;
}

fn missingArgList(self: *context.Context, option: ast.AllocationOption) CheckError {
    self.setDiagnostic(
        if (option.source.line == 0) 1 else option.source.line,
        if (option.source.column == 0) 1 else option.source.column,
        catalog.semantic.invalid_argument_count.code,
        "requires an argument list",
        option.source.text,
    );
    return error.InvalidArgumentCount;
}
