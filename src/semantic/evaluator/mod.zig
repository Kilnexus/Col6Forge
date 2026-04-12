const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const symbols = @import("../symbol/mod.zig");
const intrinsics = @import("intrinsics.zig");
const literals = @import("literals.zig");
const unary_binary = @import("unary_binary.zig");

const ConstValue = symbols.ConstValue;
pub const ExprMeasureKind = enum {
    storage_size_bits,
    sizeof_bytes,
    c_sizeof_bytes,
};

pub const ConstResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, name: []const u8) ?ConstValue,
    allocator: ?std.mem.Allocator = null,
    internStringFn: ?*const fn (ctx: *anyopaque, text: []const u8) anyerror![]const u8 = null,
    arrayExtentFn: ?*const fn (ctx: *anyopaque, name: []const u8, dim: ?usize) ?i64 = null,
    arrayLowerBoundFn: ?*const fn (ctx: *anyopaque, name: []const u8, dim: usize) ?i64 = null,
    exprMeasureFn: ?*const fn (ctx: *anyopaque, expr: *const ast.Expr, measure: ExprMeasureKind) ?i64 = null,
    exprTypeSpecFn: ?*const fn (ctx: *anyopaque, expr: *const ast.Expr) ?symbols.TypeSpec = null,
    derivedExtendsFn: ?*const fn (ctx: *anyopaque, candidate: []const u8, base: []const u8) bool = null,
    componentConstFn: ?*const fn (ctx: *anyopaque, base: *const ast.Expr, name: []const u8) ?ConstValue = null,

    pub fn resolve(self: ConstResolver, name: []const u8) ?ConstValue {
        return self.resolveFn(self.ctx, name);
    }

    pub fn internString(self: ConstResolver, text: []const u8) anyerror![]const u8 {
        if (self.internStringFn) |intern| return intern(self.ctx, text);
        if (self.allocator) |alloc| return alloc.dupe(u8, text);
        return text;
    }

    pub fn arrayExtent(self: ConstResolver, name: []const u8, dim: ?usize) ?i64 {
        if (self.arrayExtentFn) |extent_fn| return extent_fn(self.ctx, name, dim);
        return null;
    }

    pub fn arrayLowerBound(self: ConstResolver, name: []const u8, dim: usize) ?i64 {
        if (self.arrayLowerBoundFn) |lower_fn| return lower_fn(self.ctx, name, dim);
        return null;
    }

    pub fn exprMeasure(self: ConstResolver, expr: *const ast.Expr, measure: ExprMeasureKind) ?i64 {
        if (self.exprMeasureFn) |measure_fn| return measure_fn(self.ctx, expr, measure);
        return null;
    }

    pub fn exprTypeSpec(self: ConstResolver, expr: *const ast.Expr) ?symbols.TypeSpec {
        if (self.exprTypeSpecFn) |type_spec_fn| return type_spec_fn(self.ctx, expr);
        return null;
    }

    pub fn derivedExtends(self: ConstResolver, candidate: []const u8, base: []const u8) bool {
        if (self.derivedExtendsFn) |extends_fn| return extends_fn(self.ctx, candidate, base);
        return false;
    }

    pub fn resolveComponentConst(self: ConstResolver, base: *const ast.Expr, name: []const u8) ?ConstValue {
        if (self.componentConstFn) |component_fn| return component_fn(self.ctx, base, name);
        return null;
    }
};

pub const realLiteralHasDoublePrecisionHint = literals.realLiteralHasDoublePrecisionHint;
pub const parseInt = literals.parseInt;
pub const parseReal = literals.parseReal;

pub fn evalConst(expr: *const ast.Expr, resolver: ?ConstResolver) !?ConstValue {
    return switch (expr.*) {
        .literal => |lit| {
            return switch (lit.kind) {
                .integer => .{ .integer = try literals.parseInt(lit.text) },
                .real => .{ .real = try literals.parseReal(lit.text) },
                .logical => .{ .logical = try literals.parseLogical(lit.text) },
                .string, .hollerith => blk: {
                    // String constants are decoded from source text directly when possible.
                    // Allocator is only required for escaped-quote normalization and concat.
                    const maybe_allocator = if (resolver) |res| res.allocator else null;
                    const bytes = (try literals.decodeLiteralBytes(lit, maybe_allocator)) orelse break :blk null;
                    if (resolver) |res| {
                        break :blk .{ .string = try res.internString(bytes) };
                    }
                    break :blk .{ .string = bytes };
                },
                .assumed_size => null,
            };
        },
        .array_constructor => return null,
        .identifier => |name| {
            if (resolver) |res| return res.resolve(name);
            return null;
        },
        .unary => |un| {
            const inner = (try evalConst(un.expr, resolver)) orelse return null;
            return unary_binary.evalUnary(un.op, inner);
        },
        .binary => |bin| {
            const left = (try evalConst(bin.left, resolver)) orelse return null;
            const right = (try evalConst(bin.right, resolver)) orelse return null;
            return try unary_binary.evalBinary(bin.op, left, right, resolver);
        },
        .complex_literal => |lit| {
            const real_val = (try evalConst(lit.real, resolver)) orelse return null;
            const imag_val = (try evalConst(lit.imag, resolver)) orelse return null;
            const real = unary_binary.toComplex(real_val) orelse return null;
            const imag = unary_binary.toComplex(imag_val) orelse return null;
            if (real.imag != 0.0 or imag.imag != 0.0) return null;
            return .{ .complex = .{
                .real = real.real,
                .imag = imag.real,
                .is_double = real.is_double or imag.is_double,
            } };
        },
        .substring => return null,
        .component => |comp| {
            if (resolver) |res| {
                if (std.ascii.eqlIgnoreCase(comp.name, "len")) {
                    const len = exprConstantCharacterLen(comp.base, res) orelse return null;
                    return .{ .integer = std.math.cast(i64, len) orelse return error.NumberTooLong };
                }
                if (std.ascii.eqlIgnoreCase(comp.name, "kind")) {
                    const base_spec = res.exprTypeSpec(comp.base) orelse return null;
                    return .{ .integer = typeSpecKindValue(base_spec) orelse return null };
                }
                if (res.resolveComponentConst(comp.base, comp.name)) |value| return value;
            }
            return null;
        },
        .call_or_subscript => |call| blk: {
            if (try intrinsics.evalConstCall(call, resolver, evalConst, unary_binary.toReal)) |value| break :blk value;
            const res = resolver orelse return null;
            const spec = res.exprTypeSpec(expr) orelse return null;
            if (spec.lowered_kind != .derived or call.args.len != 0) return null;
            const derived_name = spec.derived_type_name orelse return null;
            if (!std.ascii.eqlIgnoreCase(call.name, derived_name)) return null;
            const bytes = res.exprMeasure(expr, .sizeof_bytes) orelse return null;
            const alloc = res.allocator orelse return null;
            const len = std.math.cast(usize, bytes) orelse return null;
            const out = try alloc.alloc(u8, len);
            @memset(out, 0);
            break :blk ConstValue{ .string = out };
        },
        .dim_range => return null,
        .implied_do => return null,
    };
}

fn typeSpecKindValue(spec: symbols.TypeSpec) ?i64 {
    return switch (spec.lowered_kind) {
        .integer, .logical => spec.kind_value orelse 4,
        .real => spec.kind_value orelse 4,
        .double_precision => spec.kind_value orelse 8,
        .complex => spec.kind_value orelse 4,
        .complex_double => spec.kind_value orelse 8,
        .character => spec.kind_value orelse 1,
        .derived => null,
    };
}

pub fn exprConstantCharacterLen(expr: *const ast.Expr, resolver: ConstResolver) ?usize {
    return switch (expr.*) {
        .literal => |lit| switch (lit.kind) {
            .string, .hollerith => literals.literalByteLen(lit),
            else => null,
        },
        .identifier => |name| blk: {
            if (resolver.resolve(name)) |value| {
                break :blk switch (value) {
                    .string => |bytes| bytes.len,
                    else => null,
                };
            }
            const spec = resolver.exprTypeSpec(expr) orelse break :blk null;
            break :blk typeSpecConstantCharacterLen(spec);
        },
        .binary => |bin| blk: {
            if (bin.op != .concat) break :blk null;
            const left_len = exprConstantCharacterLen(bin.left, resolver) orelse break :blk null;
            const right_len = exprConstantCharacterLen(bin.right, resolver) orelse break :blk null;
            break :blk std.math.add(usize, left_len, right_len) catch null;
        },
        .substring => |sub| substringConstantCharacterLen(sub, resolver),
        .call_or_subscript => |call| blk: {
            if (std.ascii.eqlIgnoreCase(call.name, "transfer") and call.args.len >= 2) {
                const mold_spec = resolver.exprTypeSpec(call.args[1]) orelse break :blk null;
                if (typeSpecConstantCharacterLen(mold_spec)) |len| break :blk len;
            }
            const spec = resolver.exprTypeSpec(expr) orelse break :blk null;
            break :blk typeSpecConstantCharacterLen(spec);
        },
        .component => |comp| blk: {
            if (std.ascii.eqlIgnoreCase(comp.name, "len")) {
                break :blk null;
            }
            const spec = resolver.exprTypeSpec(expr) orelse resolver.exprTypeSpec(comp.base) orelse break :blk null;
            if (std.ascii.eqlIgnoreCase(comp.name, "kind")) {
                break :blk null;
            }
            if (comp.has_parens and comp.args.len != 0) {
                const maybe_range = comp.args[comp.args.len - 1];
                if (maybe_range.* == .dim_range) {
                    const range = maybe_range.dim_range;
                    const start_val = if (range.lower) |lower|
                        constIntFromResolver(lower, resolver) orelse break :blk null
                    else
                        1;
                    if (start_val < 1) break :blk 0;
                    const end_val = constIntFromResolver(range.upper, resolver) orelse break :blk null;
                    if (end_val < start_val) break :blk 0;
                    break :blk std.math.cast(usize, end_val - start_val + 1);
                }
            }
            break :blk typeSpecConstantCharacterLen(spec);
        },
        else => blk: {
            const spec = resolver.exprTypeSpec(expr) orelse break :blk null;
            break :blk typeSpecConstantCharacterLen(spec);
        },
    };
}

fn substringConstantCharacterLen(sub: ast.SubstringExpr, resolver: ConstResolver) ?usize {
    const start_val = if (sub.start) |expr|
        constIntFromResolver(expr, resolver) orelse return null
    else
        1;
    if (start_val < 1) return 0;
    const end_val = if (sub.end) |expr|
        constIntFromResolver(expr, resolver) orelse return null
    else blk: {
        const base_spec = resolver.exprTypeSpec(&ast.Expr{ .substring = .{
            .name = sub.name,
            .args = sub.args,
            .start = null,
            .end = null,
        } }) orelse return null;
        break :blk @as(i64, @intCast(typeSpecConstantCharacterLen(base_spec) orelse return null));
    };
    if (end_val < start_val) return 0;
    return std.math.cast(usize, end_val - start_val + 1);
}

fn constIntFromResolver(expr: *const ast.Expr, resolver: ConstResolver) ?i64 {
    const value = evalConst(expr, resolver) catch return null;
    return switch (value orelse return null) {
        .integer => |int_val| int_val,
        else => null,
    };
}

fn typeSpecConstantCharacterLen(spec: symbols.TypeSpec) ?usize {
    if (spec.lowered_kind != .character) return null;
    return switch (spec.char_len_kind) {
        .constant => spec.char_len,
        .none => spec.char_len orelse 1,
        .assumed, .deferred => null,
    };
}

test {
    _ = @import("tests.zig");
}
