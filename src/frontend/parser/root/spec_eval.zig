const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const array_info = @import("../array_info.zig");

const Decl = ast.Decl;

pub fn recordParamInts(param_ints: *std.StringHashMap(i64), assigns: []ast.ParamAssign) !void {
    for (assigns) |assign| {
        if (evalParamInt(assign.value, param_ints)) |value| {
            try param_ints.put(assign.name, value);
        }
    }
}

pub fn recordParamStrings(param_strings: *std.StringHashMap(ast.Literal), assigns: []ast.ParamAssign) !void {
    for (assigns) |assign| {
        if (assign.value.* == .literal) {
            const lit = assign.value.literal;
            if (lit.kind == .string or lit.kind == .hollerith) {
                try param_strings.put(assign.name, lit);
            }
        }
    }
}

pub fn recordArrayNames(
    allocator: std.mem.Allocator,
    array_names: *std.StringHashMap(array_info.ArrayInfo),
    decl_node: Decl,
    param_ints: *const std.StringHashMap(i64),
) !void {
    switch (decl_node) {
        .type_decl => |td| {
            for (td.items) |item| {
                var info = try arrayInfoFromDims(allocator, item.dims, param_ints, td.pointer, td.allocatable);
                info.type_kind = td.type_kind;
                info.kind_value = inferKindValue(td.kind_selector, param_ints);
                try array_names.put(item.name, info);
            }
        },
        .dimension => |dim| {
            for (dim.items) |item| {
                if (item.dims.len > 0) {
                    try array_names.put(item.name, try arrayInfoFromDims(allocator, item.dims, param_ints, dim.pointer, dim.allocatable));
                }
            }
        },
        .common => |com| {
            for (com.blocks) |block| {
                for (block.items) |item| {
                    if (item.dims.len > 0) {
                        try array_names.put(item.name, try arrayInfoFromDims(allocator, item.dims, param_ints, false, false));
                    }
                }
            }
        },
        else => {},
    }
}

fn arraySizeFromDims(dims: []*ast.Expr, param_ints: *const std.StringHashMap(i64)) ?usize {
    if (dims.len == 0) return null;
    var total: u64 = 1;
    const max_u64 = std.math.maxInt(u64);
    const max_usize = std.math.maxInt(usize);
    for (dims) |dim_expr| {
        const dim_val_i = evalDimValue(dim_expr, param_ints) orelse return null;
        if (dim_val_i <= 0) return null;
        const dim_val = @as(u64, @intCast(dim_val_i));
        if (total > max_u64 / dim_val) return null;
        total *= dim_val;
        if (total > max_usize) return null;
    }
    return @intCast(total);
}

pub fn arrayInfoFromDims(
    allocator: std.mem.Allocator,
    dims: []*ast.Expr,
    param_ints: *const std.StringHashMap(i64),
    pointer: bool,
    allocatable: bool,
) !array_info.ArrayInfo {
    const size = arraySizeFromDims(dims, param_ints);
    const rank = dims.len;
    var lower: ?i64 = null;
    if (rank > 0) {
        lower = evalDimLowerValue(dims[0], param_ints);
    }

    var extents_known = true;
    var lowers_known = true;

    const lowers = try allocator.alloc(i64, rank);
    const extents = try allocator.alloc(usize, rank);
    for (dims, 0..) |dim_expr, idx| {
        if (evalDimLowerValue(dim_expr, param_ints)) |lower_val| {
            lowers[idx] = lower_val;
        } else {
            lowers_known = false;
            lowers[idx] = 1;
        }

        if (evalDimValue(dim_expr, param_ints)) |extent_val| {
            if (extent_val <= 0) {
                extents_known = false;
                extents[idx] = 0;
            } else {
                extents[idx] = @intCast(extent_val);
            }
        } else {
            extents_known = false;
            extents[idx] = 0;
        }
    }

    return .{
        .size = size,
        .rank = rank,
        .assumed_rank = dimsRepresentAssumedRank(dims),
        .pointer = pointer,
        .allocatable = allocatable,
        .lower = lower,
        .lower_bounds = if (rank != 0 and lowers_known) lowers else null,
        .extents = if (rank != 0 and extents_known) extents else null,
    };
}

fn inferKindValue(kind_selector: ?*ast.Expr, param_ints: *const std.StringHashMap(i64)) ?i64 {
    const expr_node = kind_selector orelse return null;
    return evalParamInt(expr_node, param_ints);
}

fn dimsRepresentAssumedRank(dims: []*ast.Expr) bool {
    if (dims.len != 1) return false;
    return switch (dims[0].*) {
        .dim_range => |range| range.from_dotdot,
        else => false,
    };
}

fn evalDimValue(expr_node: *ast.Expr, param_ints: *const std.StringHashMap(i64)) ?i64 {
    switch (expr_node.*) {
        .literal => |lit| {
            if (lit.kind == .assumed_size) return null;
            return evalParamInt(expr_node, param_ints);
        },
        .dim_range => |range| {
            if (range.stride != null) return null;
            if (range.upper.* == .literal and range.upper.literal.kind == .assumed_size) return null;
            const upper = evalParamInt(range.upper, param_ints) orelse return null;
            const lower = if (range.lower) |lower_expr|
                evalParamInt(lower_expr, param_ints) orelse return null
            else
                1;
            return upper - lower + 1;
        },
        else => return evalParamInt(expr_node, param_ints),
    }
}

fn evalDimLowerValue(expr_node: *ast.Expr, param_ints: *const std.StringHashMap(i64)) ?i64 {
    switch (expr_node.*) {
        .dim_range => |range| {
            if (range.lower) |lower_expr| {
                return evalParamInt(lower_expr, param_ints);
            }
            return 1;
        },
        else => return 1,
    }
}

pub fn evalParamInt(expr_node: *ast.Expr, param_ints: *const std.StringHashMap(i64)) ?i64 {
    return switch (expr_node.*) {
        .literal => |lit| if (lit.kind == .integer) std.fmt.parseInt(i64, lit.text, 10) catch null else null,
        .identifier => |name| param_ints.get(name),
        .unary => |un| {
            const value = evalParamInt(un.expr, param_ints) orelse return null;
            return switch (un.op) {
                .plus => value,
                .minus => -value,
                else => null,
            };
        },
        .binary => |bin| {
            const left = evalParamInt(bin.left, param_ints) orelse return null;
            const right = evalParamInt(bin.right, param_ints) orelse return null;
            return switch (bin.op) {
                .add => left + right,
                .sub => left - right,
                .mul => left * right,
                .div => if (right == 0) null else @divTrunc(left, right),
                .power => if (right < 0) null else powInt(left, right),
                else => null,
            };
        },
        else => null,
    };
}

fn powInt(base: i64, exp: i64) i64 {
    if (exp <= 0) return 1;
    var result: i64 = 1;
    var i: i64 = 0;
    while (i < exp) : (i += 1) {
        result *= base;
    }
    return result;
}
