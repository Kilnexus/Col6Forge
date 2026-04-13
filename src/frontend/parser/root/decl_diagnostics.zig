const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const logical_line = @import("../../logical_line.zig");
const parse_diag = @import("../diagnostic.zig");
const array_info = @import("../array_info.zig");
const root_spec_eval = @import("spec_eval.zig");

pub fn noteDeclaratorInitializerShapeDiagnostics(
    arena: std.mem.Allocator,
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    decl_node: ast.Decl,
    param_ints: *const std.StringHashMap(i64),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) !void {
    switch (decl_node) {
        .type_decl => |type_decl| {
            for (type_decl.items) |item| {
                const init_expr = item.init orelse continue;
                const expected_shape = try staticShapeForDims(arena, item.dims, param_ints) orelse continue;
                const actual_shape = try staticShapeForExpr(arena, init_expr, param_ints, array_names) orelse continue;
                if (expected_shape.len != actual_shape.len) {
                    try emitShapeMismatch(
                        diag_bag,
                        line,
                        1,
                        @intCast(expected_shape.len),
                        @intCast(actual_shape.len),
                    );
                    continue;
                }
                for (expected_shape, actual_shape, 0..) |expected, actual, dim_idx| {
                    if (expected != actual) {
                        try emitShapeMismatch(diag_bag, line, dim_idx + 1, expected, actual);
                        break;
                    }
                }
            }
        },
        else => {},
    }
}

fn emitShapeMismatch(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    dim: usize,
    expected: i64,
    actual: i64,
) !void {
    const message = try std.fmt.allocPrint(
        diag_bag.allocator,
        "Different shape for array assignment at (1) on dimension {d} ({d} and {d}).",
        .{ dim, expected, actual },
    );
    diag_bag.set(
        line.span.start_line,
        if (line.segments.len > 0) line.segments[0].column else 1,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        line.text,
    );
}

fn staticShapeForDims(
    arena: std.mem.Allocator,
    dims: []*ast.Expr,
    param_ints: *const std.StringHashMap(i64),
) !?[]const i64 {
    if (dims.len == 0) return null;
    const out = try arena.alloc(i64, dims.len);
    for (dims, 0..) |dim_expr, idx| {
        out[idx] = staticDimExtent(dim_expr, param_ints) orelse return null;
    }
    return out;
}

fn staticShapeForExpr(
    arena: std.mem.Allocator,
    expr_node: *ast.Expr,
    param_ints: *const std.StringHashMap(i64),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) !?[]const i64 {
    return switch (expr_node.*) {
        .array_constructor => |ctor| blk: {
            const out = try arena.alloc(i64, 1);
            out[0] = @intCast(ctor.items.len);
            break :blk out;
        },
        .identifier => |name| shapeFromArrayInfo(arena, array_names.get(name)),
        .call_or_subscript => |call| try staticShapeForSubscript(arena, call, param_ints, array_names),
        else => null,
    };
}

fn shapeFromArrayInfo(
    arena: std.mem.Allocator,
    info: ?array_info.ArrayInfo,
) ?[]const i64 {
    const array = info orelse return null;
    const extents = array.extents orelse return null;
    const out = arena.alloc(i64, extents.len) catch return null;
    for (extents, 0..) |extent, idx| out[idx] = @intCast(extent);
    return out;
}

fn staticShapeForSubscript(
    arena: std.mem.Allocator,
    call: ast.CallOrSubscript,
    param_ints: *const std.StringHashMap(i64),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
) !?[]const i64 {
    const info = array_names.get(call.name) orelse return null;
    const lower_bounds = info.lower_bounds orelse return null;
    const extents = info.extents orelse return null;
    if (call.args.len != extents.len or lower_bounds.len != extents.len) return null;

    var rank: usize = 0;
    for (call.args) |arg| {
        if (arg.* == .dim_range) rank += 1;
    }
    if (rank == 0) return null;

    const out = try arena.alloc(i64, rank);
    var out_idx: usize = 0;
    for (call.args, 0..) |arg, dim_idx| {
        if (arg.* != .dim_range) continue;
        out[out_idx] = staticSectionExtent(arg.dim_range, lower_bounds[dim_idx], @intCast(extents[dim_idx]), param_ints) orelse return null;
        out_idx += 1;
    }
    return out;
}

fn staticSectionExtent(
    range: ast.DimRange,
    declared_lower: i64,
    declared_extent: i64,
    param_ints: *const std.StringHashMap(i64),
) ?i64 {
    const stride = if (range.stride) |stride_expr| root_spec_eval.evalParamInt(stride_expr, param_ints) orelse return null else 1;
    if (stride == 0) return null;
    const declared_upper = declared_lower + declared_extent - 1;
    const lower = if (range.lower) |lower_expr|
        root_spec_eval.evalParamInt(lower_expr, param_ints) orelse return null
    else if (stride > 0)
        declared_lower
    else
        declared_upper;
    const upper = root_spec_eval.evalParamInt(range.upper, param_ints) orelse return null;

    if (stride > 0) {
        if (upper < lower) return 0;
        return @divFloor(upper - lower, stride) + 1;
    }
    if (lower < upper) return 0;
    return @divFloor(lower - upper, -stride) + 1;
}

fn staticDimExtent(
    expr_node: *ast.Expr,
    param_ints: *const std.StringHashMap(i64),
) ?i64 {
    return switch (expr_node.*) {
        .dim_range => |range| blk: {
            if (range.stride != null) break :blk null;
            const upper = root_spec_eval.evalParamInt(range.upper, param_ints) orelse break :blk null;
            const lower = if (range.lower) |lower_expr|
                root_spec_eval.evalParamInt(lower_expr, param_ints) orelse break :blk null
            else
                1;
            if (upper < lower) break :blk 0;
            break :blk upper - lower + 1;
        },
        else => root_spec_eval.evalParamInt(expr_node, param_ints),
    };
}
