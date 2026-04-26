const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const symbols = @import("../../symbol/mod.zig");
const context = @import("../context.zig");
const constants = @import("../resolve_const.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");

pub const CheckError = anyerror;

pub fn checkTypedItems(
    self: *context.Context,
    expr_node: *ast.Expr,
    ctor: ast.ArrayConstructor,
    comptime deps: anytype,
) CheckError!void {
    if (ctor.type_spec == null) return;
    const target_spec = try resolve_expr.exprTypeSpec(self, expr_node);
    for (ctor.items) |item| {
        const actual_spec = try resolve_expr.exprTypeSpec(self, item);
        try checkAbstractItem(self, item, actual_spec, expr_node);
        if (target_spec.lowered_kind == .derived or actual_spec.lowered_kind == .derived) {
            if (!deps.dummyArgTypeCompatible(self, target_spec, actual_spec)) {
                const source = self.sourceForExpr(item) orelse self.sourceForExpr(expr_node) orelse ast.SourceRef{};
                self.setDiagnostic(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "cannot convert TYPE in array constructor",
                    source.text,
                );
                return error.AssignmentTypeMismatch;
            }
            continue;
        }
        try checkConstConversion(self, target_spec, item);
    }
}

pub fn checkAbstractItems(
    self: *context.Context,
    expr_node: *ast.Expr,
    items: []const *ast.Expr,
) CheckError!void {
    for (items) |item| {
        const actual_spec = try resolve_expr.exprTypeSpec(self, item);
        try checkAbstractItem(self, item, actual_spec, expr_node);
    }
}

fn checkAbstractItem(
    self: *context.Context,
    item: *ast.Expr,
    actual_spec: symbols.TypeSpec,
    fallback_expr: *ast.Expr,
) CheckError!void {
    if (actual_spec.lowered_kind != .derived) return;
    const derived_name = actual_spec.derived_type_name orelse return;
    const derived_info = resolve_symbols.lookupDerivedType(self, derived_name) orelse return;
    if (!derived_info.abstract) return;

    const source = self.sourceForExpr(item) orelse self.sourceForExpr(fallback_expr) orelse ast.SourceRef{};
    const message = std.fmt.allocPrint(self.arena, "is of the ABSTRACT type '{s}'", .{derived_name}) catch "is of the ABSTRACT type";
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
    );
    return error.AssignmentTypeMismatch;
}

fn checkConstConversion(
    self: *context.Context,
    target_spec: symbols.TypeSpec,
    item: *ast.Expr,
) CheckError!void {
    if (!self.range_check) return;
    if (target_spec.lowered_kind != .integer) return;
    const value = (try constants.evalConst(self, item)) orelse return;
    const int_value = switch (value) {
        .integer => |v| v,
        .real => |v| blk: {
            if (!std.math.isFinite(v.value)) return;
            break :blk @as(i64, @intFromFloat(@trunc(v.value)));
        },
        else => return,
    };
    const bounds = integerBoundsForTypeSpec(self, target_spec);
    if (int_value >= bounds.min and int_value <= bounds.max) return;
    const source = self.sourceForExpr(item) orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "overflow converting INTEGER in array constructor",
        source.text,
    );
    return error.AssignmentTypeMismatch;
}

fn integerBoundsForTypeSpec(self: *context.Context, spec: symbols.TypeSpec) context.Context.IntegerBounds {
    const bits: u16 = blk: {
        const kind_value = spec.kind_value orelse break :blk self.target_layout.default_integer_bits;
        if (kind_value <= 0) break :blk self.target_layout.default_integer_bits;
        if (kind_value <= 16) break :blk @intCast(kind_value * 8);
        break :blk @intCast(@min(kind_value, 64));
    };
    const layout: context.Context.TargetLayout = .{ .default_integer_bits = bits };
    return layout.integerBounds(.integer);
}
