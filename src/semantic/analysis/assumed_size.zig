const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");
const resolve_expr = @import("resolve_expr.zig");
const resolve_symbols = @import("resolve_symbols.zig");
const expr_diagnostics = @import("expr_diagnostics.zig");

pub fn assumedSizeDimIndex(dims: []const *ast.Expr) ?usize {
    var found: ?usize = null;
    for (dims, 0..) |dim, idx| {
        const is_assumed = dimIsAssumedSize(dim);
        if (!is_assumed) continue;
        if (found != null) return null;
        found = idx;
    }
    return found;
}

pub fn hasAssumedSizeDims(dims: []const *ast.Expr) bool {
    return assumedSizeDimIndex(dims) != null;
}

pub fn validateDeclaratorDims(
    self: *context.Context,
    item: ast.Declarator,
    storage: symbols.StorageClass,
    allow_parameter_implied_shape: bool,
) !void {
    if (item.dims.len == 0) return;

    var assumed_idx: ?usize = null;
    for (item.dims, 0..) |dim, idx| {
        const is_assumed = dimIsAssumedSize(dim);
        if (!is_assumed) continue;
        if (assumed_idx != null or idx + 1 != item.dims.len) {
            return emitCurrentDeclDiagnostic(self, "Bad specification for assumed size array");
        }
        assumed_idx = idx;
    }

    if (assumed_idx == null) return;
    if (storage != .dummy) {
        if (allow_parameter_implied_shape) {
            try normalizeParameterImpliedShapeDims(self, item.dims);
            return;
        }
        return emitCurrentDeclDiagnostic(self, "must be a dummy argument");
    }
}

fn normalizeParameterImpliedShapeDims(self: *context.Context, dims: []const *ast.Expr) !void {
    for (dims) |dim| {
        if (!dimIsAssumedSize(dim)) continue;
        const upper = try self.arena.create(ast.Expr);
        upper.* = .{ .literal = .{ .kind = .assumed_size, .text = "*" } };
        dim.* = .{ .dim_range = .{
            .lower = null,
            .upper = upper,
            .stride = null,
            .assumed_shape = true,
        } };
    }
}

fn dimIsAssumedSize(dim: *ast.Expr) bool {
    return switch (dim.*) {
        .literal => |lit| lit.kind == .assumed_size,
        .dim_range => |range| range.upper.* == .literal and
            range.upper.literal.kind == .assumed_size and
            !range.assumed_shape,
        else => false,
    };
}

pub fn validateDerivedIntentOutAssumedSizeDummy(
    self: *context.Context,
    decl: ast.TypeDecl,
    item: ast.Declarator,
    type_spec: symbols.TypeSpec,
) !void {
    if (decl.intent != .out) return;
    if (!hasAssumedSizeDims(item.dims)) return;
    if (type_spec.lowered_kind != .derived) return;
    const derived_name = type_spec.derived_type_name orelse return;
    if (!derivedTypeHasDefaultInitializer(self, derived_name)) return;
    return emitCurrentDeclDiagnostic(self, "cannot have a default initializer");
}

pub fn exprHasAssumedSizeArray(self: *context.Context, expr: *ast.Expr) bool {
    return exprRootDims(self, expr) != null;
}

pub fn exprAssumedSizeRank(self: *context.Context, expr: *ast.Expr) ?usize {
    const dims = exprRootDims(self, expr) orelse return null;
    return dims.len;
}

pub fn exprNeedsExplicitLastUpperBound(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => exprRootDims(self, expr) != null,
        .call_or_subscript => |call| missingLastUpperBoundForArgs(self, expr, call.args),
        .component => |comp| missingLastUpperBoundForArgs(self, expr, comp.args),
        .substring => |sub| missingLastUpperBoundForArgs(self, expr, sub.args),
        else => false,
    };
}

pub fn shapeAssumedSizeMessage(self: *context.Context, expr: *ast.Expr) []const u8 {
    _ = self;
    return switch (expr.*) {
        .identifier => "must not be an assumed size array",
        else => "upper bound of assumed size array",
    };
}

pub fn emitExprDiagnostic(self: *context.Context, expr: *ast.Expr, message: []const u8) anyerror {
    return expr_diagnostics.emitExprAssignmentMismatch(self, expr, message);
}

fn emitCurrentDeclDiagnostic(self: *context.Context, message: []const u8) anyerror {
    const source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_argument_count.code,
        message,
        source.text,
    );
    return error.InvalidArgumentCount;
}

fn exprRootDims(self: *context.Context, expr: *ast.Expr) ?[]const *ast.Expr {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk null;
            const dims = self.symbols.items[idx].dims;
            if (!hasAssumedSizeDims(dims)) break :blk null;
            break :blk dims;
        },
        .call_or_subscript => |call| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk null;
            const kind = self.ref_kind_index.get(@intFromPtr(expr)) orelse
                (if (self.symbols.items[idx].dims.len > 0) symbols.ResolvedRefKind.subscript else .call);
            if (kind != .subscript) break :blk null;
            const dims = self.symbols.items[idx].dims;
            if (!hasAssumedSizeDims(dims)) break :blk null;
            break :blk dims;
        },
        .substring => |sub| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, sub.name) orelse break :blk null;
            const dims = self.symbols.items[idx].dims;
            if (!hasAssumedSizeDims(dims)) break :blk null;
            break :blk dims;
        },
        .component => |comp| blk: {
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk null;
            if (base_spec.lowered_kind != .derived) break :blk null;
            const derived_name = base_spec.derived_type_name orelse break :blk null;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk null;
            if (!hasAssumedSizeDims(component.dims)) break :blk null;
            break :blk component.dims;
        },
        else => null,
    };
}

fn missingLastUpperBoundForArgs(
    self: *context.Context,
    expr: *ast.Expr,
    args: []const *ast.Expr,
) bool {
    const dims = exprRootDims(self, expr) orelse return false;
    const assumed_idx = assumedSizeDimIndex(dims) orelse return false;
    if (assumed_idx + 1 != dims.len) return true;
    if (args.len != dims.len) return true;

    const last_arg = args[args.len - 1];
    return switch (last_arg.*) {
        .dim_range => |range| range.upper.* == .literal and range.upper.literal.kind == .assumed_size,
        else => resolve_expr.exprRank(self, last_arg) != 0,
    };
}

fn derivedTypeHasDefaultInitializer(self: *context.Context, derived_name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .derived_type_def) continue;
        if (!std.ascii.eqlIgnoreCase(decl.derived_type_def.name, derived_name)) continue;
        for (decl.derived_type_def.components) |component_decl| {
            for (component_decl.items) |item| {
                if (item.init != null) return true;
            }
        }
        return false;
    }
    return false;
}
