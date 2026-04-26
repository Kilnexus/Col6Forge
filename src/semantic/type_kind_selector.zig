const std = @import("std");
const ast = @import("../ast/nodes.zig");
const symbols = @import("symbol/mod.zig");
const literal_expr = @import("literal_expr.zig");

pub fn resolve(base: ast.TypeKind, selector: ?*ast.Expr) ast.TypeKind {
    return resolveSpecWithConst(base, selector, null).lowered_kind;
}

pub fn resolveWithConst(
    base: ast.TypeKind,
    selector: ?*ast.Expr,
    const_value: ?symbols.ConstValue,
) ast.TypeKind {
    return resolveSpecWithConst(base, selector, const_value).lowered_kind;
}

pub fn resolveSpec(base: ast.TypeKind, selector: ?*ast.Expr) symbols.TypeSpec {
    return resolveSpecWithConst(base, selector, null);
}

pub fn resolveSpecWithConst(
    base: ast.TypeKind,
    selector: ?*ast.Expr,
    const_value: ?symbols.ConstValue,
) symbols.TypeSpec {
    if (selector == null) return symbols.TypeSpec.fromResolvedKind(base, base, null);
    const kind_value = selectorValueAsInteger(const_value) orelse selectorExprAsInteger(selector.?);
    return switch (base) {
        .real => .{
            .declared_kind = .real,
            .lowered_kind = resolveReal(selector.?, const_value),
            .kind_value = kind_value,
            .char_len_kind = .none,
            .char_len = null,
        },
        .complex => .{
            .declared_kind = .complex,
            .lowered_kind = resolveComplex(selector.?, const_value),
            .kind_value = kind_value,
            .char_len_kind = .none,
            .char_len = null,
        },
        .integer, .logical => .{
            .declared_kind = base,
            .lowered_kind = base,
            .kind_value = kind_value,
            .char_len_kind = .none,
            .char_len = null,
        },
        .character => symbols.TypeSpec.fromResolvedKind(.character, .character, kind_value),
        else => symbols.TypeSpec.fromResolvedKind(base, base, kind_value),
    };
}

fn resolveReal(selector: *ast.Expr, const_value: ?symbols.ConstValue) ast.TypeKind {
    if (selectorValueAsInteger(const_value)) |kind_value| {
        if (realKindValueIsDouble(kind_value)) return .double_precision;
        return .real;
    }
    if (selectorExprAsInteger(selector)) |kind_value| {
        if (realKindValueIsDouble(kind_value)) return .double_precision;
        return .real;
    }
    if (selectorExprAsIdentifier(selector)) |name| {
        if (realKindNameIsDouble(name)) return .double_precision;
    }
    return .real;
}

fn resolveComplex(selector: *ast.Expr, const_value: ?symbols.ConstValue) ast.TypeKind {
    if (selectorValueAsInteger(const_value)) |kind_value| {
        if (complexKindValueIsDouble(kind_value)) return .complex_double;
        return .complex;
    }
    if (selectorExprAsInteger(selector)) |kind_value| {
        if (complexKindValueIsDouble(kind_value)) return .complex_double;
        return .complex;
    }
    if (selectorExprAsIdentifier(selector)) |name| {
        if (complexKindNameIsDouble(name)) return .complex_double;
    }
    return .complex;
}

fn selectorValueAsInteger(value: ?symbols.ConstValue) ?i64 {
    if (value) |const_value| {
        return switch (const_value) {
            .integer => |v| v,
            else => null,
        };
    }
    return null;
}

fn selectorExprAsInteger(selector: *ast.Expr) ?i64 {
    return literal_expr.integer(i64, selector);
}

fn selectorExprAsIdentifier(selector: *ast.Expr) ?[]const u8 {
    return switch (selector.*) {
        .identifier => |name| name,
        else => null,
    };
}

pub fn realKindValueIsDouble(kind_value: i64) bool {
    return kind_value >= 8;
}

pub fn complexKindValueIsDouble(kind_value: i64) bool {
    return kind_value >= 16;
}

pub fn realKindNameIsDouble(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "WP") or
        std.ascii.eqlIgnoreCase(name, "REAL64") or
        std.ascii.eqlIgnoreCase(name, "FLOAT64") or
        std.ascii.eqlIgnoreCase(name, "C_DOUBLE") or
        std.ascii.eqlIgnoreCase(name, "DP") or
        std.ascii.eqlIgnoreCase(name, "RK8") or
        std.ascii.eqlIgnoreCase(name, "KIND8") or
        std.ascii.eqlIgnoreCase(name, "K8");
}

pub fn complexKindNameIsDouble(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "REAL64") or
        std.ascii.eqlIgnoreCase(name, "C_DOUBLE") or
        std.ascii.eqlIgnoreCase(name, "C_DOUBLE_COMPLEX") or
        std.ascii.eqlIgnoreCase(name, "KIND16");
}

test "resolve maps REAL selector names and literals" {
    const testing = std.testing;

    var lit8 = ast.Expr{ .literal = .{ .kind = .integer, .text = "8" } };
    try testing.expectEqual(ast.TypeKind.double_precision, resolve(.real, &lit8));

    var wp = ast.Expr{ .identifier = "WP" };
    try testing.expectEqual(ast.TypeKind.double_precision, resolve(.real, &wp));

    var lit4 = ast.Expr{ .literal = .{ .kind = .integer, .text = "4" } };
    try testing.expectEqual(ast.TypeKind.real, resolve(.real, &lit4));

    var lit10 = ast.Expr{ .literal = .{ .kind = .integer, .text = "10" } };
    try testing.expectEqual(ast.TypeKind.double_precision, resolve(.real, &lit10));
}

test "resolveWithConst uses evaluated integer selector values" {
    const testing = std.testing;

    var dyn = ast.Expr{ .identifier = "RK" };
    try testing.expectEqual(
        ast.TypeKind.double_precision,
        resolveWithConst(.real, &dyn, .{ .integer = 8 }),
    );
    try testing.expectEqual(
        ast.TypeKind.complex_double,
        resolveWithConst(.complex, &dyn, .{ .integer = 16 }),
    );
}
