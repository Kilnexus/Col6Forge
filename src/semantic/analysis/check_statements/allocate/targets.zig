const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const symbols = @import("../../../symbol/mod.zig");
const context = @import("../../context.zig");
const resolve_expr = @import("../../resolve_expr.zig");
const resolve_symbols = @import("../../resolve_symbols.zig");

pub const CheckError = anyerror;

pub const AllocateTargetInfo = struct {
    rank: usize,
    allocatable: bool = false,
    pointer: bool = false,
    procedure: bool = false,
};

pub fn resolveAllocateTargetInfo(self: *context.Context, expr: *ast.Expr) CheckError!AllocateTargetInfo {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse return error.UnknownSymbol;
            const sym = self.symbols.items[idx];
            break :blk .{
                .rank = sym.dims.len,
                .allocatable = sym.is_allocatable,
                .pointer = sym.is_pointer,
                .procedure = !currentFunctionResultDesignatorIsDataEntity(self, name) and (sym.kind == .function or sym.kind == .subroutine),
            };
        },
        .call_or_subscript => |call| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse return error.UnknownSymbol;
            const sym = self.symbols.items[idx];
            const kind = self.ref_kind_index.get(@intFromPtr(expr)) orelse
                (if (sym.dims.len > 0) symbols.ResolvedRefKind.subscript else symbols.ResolvedRefKind.call);
            if (kind != .subscript) return error.UnsupportedAllocateSyntax;
            break :blk .{
                .rank = sym.dims.len,
                .allocatable = sym.is_allocatable,
                .pointer = sym.is_pointer,
                .procedure = !currentFunctionResultDesignatorIsDataEntity(self, call.name) and (sym.kind == .function or sym.kind == .subroutine),
            };
        },
        .component => |comp| blk: {
            const base_spec = try resolve_expr.exprTypeSpec(self, comp.base);
            if (base_spec.lowered_kind != .derived) return error.InvalidSubscript;
            const derived_name = base_spec.derived_type_name orelse return error.InvalidSubscript;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse return error.InvalidSubscript;
            break :blk .{
                .rank = component.dims.len,
                .allocatable = component.allocatable,
                .pointer = component.pointer,
                .procedure = component.procedure,
            };
        },
        else => error.UnsupportedAllocateSyntax,
    };
}

pub fn allocateTargetTypeSpec(self: *context.Context, expr: *ast.Expr) CheckError!symbols.TypeSpec {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse return error.UnknownSymbol;
            break :blk self.symbols.items[idx].type_spec;
        },
        .call_or_subscript => |call| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse return error.UnknownSymbol;
            const sym = self.symbols.items[idx];
            const kind = self.ref_kind_index.get(@intFromPtr(expr)) orelse
                (if (sym.dims.len > 0) symbols.ResolvedRefKind.subscript else symbols.ResolvedRefKind.call);
            if (kind != .subscript) return error.UnsupportedAllocateSyntax;
            break :blk sym.type_spec;
        },
        .component => |comp| blk: {
            const base_spec = try resolve_expr.exprTypeSpec(self, comp.base);
            if (base_spec.lowered_kind != .derived) return error.InvalidSubscript;
            const derived_name = base_spec.derived_type_name orelse return error.InvalidSubscript;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse return error.InvalidSubscript;
            break :blk component.type_spec;
        },
        else => error.UnsupportedAllocateSyntax,
    };
}

pub fn checkDuplicateAllocateItems(self: *context.Context, items: []const ast.AllocateItem) CheckError!void {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < items.len) : (j += 1) {
            if (sameAllocateObjectExpr(items[i].target, items[j].target)) {
                return emitAllocateObjectConflictDiagnostic(self, items[j].source, items[j].target, false);
            }
            if (allocateObjectSubobjectConflict(items[i].target, items[j].target)) {
                return emitAllocateObjectConflictDiagnostic(self, items[j].source, items[j].target, true);
            }
        }
    }
}

pub fn checkDuplicateDeallocateItems(self: *context.Context, items: []const ast.DeallocateItem) CheckError!void {
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < items.len) : (j += 1) {
            if (sameAllocateObjectExpr(items[i].target, items[j].target)) {
                return emitAllocateObjectConflictDiagnostic(self, items[j].source, items[j].target, false);
            }
            if (allocateObjectSubobjectConflict(items[i].target, items[j].target)) {
                return emitAllocateObjectConflictDiagnostic(self, items[j].source, items[j].target, true);
            }
        }
    }
}

pub fn emitAllocateTargetConstraintDiagnostic(
    self: *context.Context,
    target: *ast.Expr,
    source: ast.SourceRef,
    is_allocate: bool,
) CheckError {
    const target_spec = allocateTargetTypeSpec(self, target) catch symbols.TypeSpec.fromResolvedKind(.integer, .integer, null);
    const is_numeric = switch (target_spec.lowered_kind) {
        .integer, .real, .double_precision, .complex, .complex_double, .logical => true,
        else => false,
    };
    const target_info = resolveAllocateTargetInfo(self, target) catch AllocateTargetInfo{ .rank = 0 };
    const message = if (target_info.procedure)
        "must be ALLOCATABLE"
    else if (is_allocate)
        if (is_numeric) "must be ALLOCATABLE or a POINTER" else "neither a data pointer nor an allocatable"
    else if (is_numeric)
        "must be ALLOCATABLE or a POINTER"
    else
        "not a nonprocedure pointer nor an allocatable";
    const final_source: ast.SourceRef = if (source.line != 0) source else self.sourceForExpr(target) orelse .{};
    self.setDiagnostic(
        if (final_source.line == 0) 1 else final_source.line,
        if (final_source.column == 0) 1 else final_source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        final_source.text,
    );
    return error.UnsupportedAllocateSyntax;
}

pub fn emitVariableDefinitionContextDiagnostic(
    self: *context.Context,
    source: ast.SourceRef,
    expr_node: *ast.Expr,
) CheckError {
    const final_source: ast.SourceRef = if (source.line != 0) source else self.sourceForExpr(expr_node) orelse .{};
    self.setDiagnostic(
        if (final_source.line == 0) 1 else final_source.line,
        if (final_source.column == 0) 1 else final_source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "variable definition context",
        final_source.text,
    );
    return error.AssignmentTypeMismatch;
}

pub fn violatesVariableDefinitionContext(self: *context.Context, expr_node: *ast.Expr) bool {
    return dummyIntentForExpr(self, expr_node) == .in;
}

pub fn dummyIntentForExpr(self: *context.Context, expr_node: *ast.Expr) ?ast.IntentKind {
    return switch (expr_node.*) {
        .identifier => |name| dummyIntentForName(self, name),
        .component => |comp| dummyIntentForExpr(self, comp.base),
        else => null,
    };
}

pub fn sameObjectSelectorExpr(a: *ast.Expr, b: *ast.Expr) bool {
    return switch (a.*) {
        .identifier => switch (b.*) {
            .identifier => std.ascii.eqlIgnoreCase(a.identifier, b.identifier),
            else => false,
        },
        .literal => switch (b.*) {
            .literal => a.literal.kind == b.literal.kind and std.mem.eql(u8, a.literal.text, b.literal.text),
            else => false,
        },
        .unary => switch (b.*) {
            .unary => a.unary.op == b.unary.op and sameObjectSelectorExpr(a.unary.expr, b.unary.expr),
            else => false,
        },
        .binary => switch (b.*) {
            .binary => a.binary.op == b.binary.op and
                sameObjectSelectorExpr(a.binary.left, b.binary.left) and
                sameObjectSelectorExpr(a.binary.right, b.binary.right),
            else => false,
        },
        .call_or_subscript => switch (b.*) {
            .call_or_subscript => blk: {
                if (!std.ascii.eqlIgnoreCase(a.call_or_subscript.name, b.call_or_subscript.name)) break :blk false;
                if (a.call_or_subscript.args.len != b.call_or_subscript.args.len) break :blk false;
                for (a.call_or_subscript.args, b.call_or_subscript.args) |lhs, rhs| {
                    if (!sameObjectSelectorExpr(lhs, rhs)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        else => false,
    };
}

fn dummyIntentForName(self: *context.Context, name: []const u8) ?ast.IntentKind {
    const sig = resolve_symbols.lookupKnownProcedureSig(self, self.unit.name) orelse return null;
    for (sig.args) |arg| {
        if (std.ascii.eqlIgnoreCase(arg.name, name)) return arg.intent;
    }
    return null;
}

fn currentFunctionResultDesignatorIsDataEntity(self: *context.Context, name: []const u8) bool {
    if (self.unit.kind != .function) return false;
    const result_name = self.unit.result_name orelse self.unit.name;
    return std.ascii.eqlIgnoreCase(name, result_name);
}

fn emitAllocateObjectConflictDiagnostic(self: *context.Context, source: ast.SourceRef, expr_node: *ast.Expr, is_subobject: bool) CheckError {
    const final_source: ast.SourceRef = if (source.line != 0) source else self.sourceForExpr(expr_node) orelse .{};
    self.setDiagnostic(
        if (final_source.line == 0) 1 else final_source.line,
        if (final_source.column == 0) 1 else final_source.column,
        catalog.semantic.duplicate_declaration.code,
        if (is_subobject) "Allocate-object at (1) is subobject of object at (2)" else "Allocate-object at (1) also appears at (2)",
        final_source.text,
    );
    return error.DuplicateDeclaration;
}

fn sameAllocateObjectExpr(a: *ast.Expr, b: *ast.Expr) bool {
    return switch (a.*) {
        .identifier => switch (b.*) {
            .identifier => std.ascii.eqlIgnoreCase(a.identifier, b.identifier),
            else => false,
        },
        .call_or_subscript => switch (b.*) {
            .call_or_subscript => sameObjectSelectorExpr(a, b),
            else => false,
        },
        .component => switch (b.*) {
            .component => std.ascii.eqlIgnoreCase(a.component.name, b.component.name) and a.component.args.len == 0 and b.component.args.len == 0 and sameAllocateObjectExpr(a.component.base, b.component.base),
            else => false,
        },
        else => false,
    };
}

fn allocateObjectSubobjectConflict(a: *ast.Expr, b: *ast.Expr) bool {
    return isAllocateObjectAncestor(a, b) or isAllocateObjectAncestor(b, a);
}

fn isAllocateObjectAncestor(ancestor: *ast.Expr, expr_node: *ast.Expr) bool {
    if (sameAllocateObjectExpr(ancestor, expr_node)) return false;
    return switch (ancestor.*) {
        .identifier => |name| blk: {
            const root = allocateObjectRootName(expr_node) orelse break :blk false;
            break :blk std.ascii.eqlIgnoreCase(name, root);
        },
        .call_or_subscript => switch (expr_node.*) {
            .component => isAllocateObjectAncestor(ancestor, expr_node.component.base),
            else => false,
        },
        .component => switch (expr_node.*) {
            .component => std.ascii.eqlIgnoreCase(ancestor.component.name, expr_node.component.name) and isAllocateObjectAncestor(ancestor.component.base, expr_node.component.base),
            else => false,
        },
        else => false,
    };
}

fn allocateObjectRootName(expr_node: *ast.Expr) ?[]const u8 {
    return switch (expr_node.*) {
        .identifier => expr_node.identifier,
        .call_or_subscript => expr_node.call_or_subscript.name,
        .component => allocateObjectRootName(expr_node.component.base),
        else => null,
    };
}
