const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const symbols = @import("../symbol/mod.zig");
const literals = @import("literals.zig");
const evaluator = @import("../evaluator.zig");
const eval_mod = @import("mod.zig");

const ConstValue = symbols.ConstValue;
const ExprMeasureKind = evaluator.ExprMeasureKind;

const ConstCallKind = enum {
    len,
    transfer,
    achar,
    acos,
    sqrt,
    log10,
    atan,
    atan2,
    abs,
    epsilon,
    tiny,
    huge,
    dpmpar,
    min,
    max,
    selected_real_kind,
    selected_int_kind,
    selected_char_kind,
    same_type_as,
    kind,
    bit_size,
    storage_size,
    sizeof,
    c_sizeof,
    cmplx,
    real,
    log,
    ceiling,
    int,
    size,
    lbound,
    ubound,
    index,
    extends_type_of,
};

const ConstCallMap = std.StaticStringMap(ConstCallKind).initComptime(.{
    .{ "LEN", .len },
    .{ "TRANSFER", .transfer },
    .{ "ACHAR", .achar },
    .{ "CHAR", .achar },
    .{ "ACOS", .acos },
    .{ "DACOS", .acos },
    .{ "SQRT", .sqrt },
    .{ "LOG10", .log10 },
    .{ "ATAN", .atan },
    .{ "DATAN", .atan },
    .{ "ATAN2", .atan2 },
    .{ "DATAN2", .atan2 },
    .{ "ABS", .abs },
    .{ "EPSILON", .epsilon },
    .{ "TINY", .tiny },
    .{ "HUGE", .huge },
    .{ "DPMPAR", .dpmpar },
    .{ "MIN", .min },
    .{ "MAX", .max },
    .{ "SELECTED_REAL_KIND", .selected_real_kind },
    .{ "SELECTED_INT_KIND", .selected_int_kind },
    .{ "SELECTED_CHAR_KIND", .selected_char_kind },
    .{ "SAME_TYPE_AS", .same_type_as },
    .{ "KIND", .kind },
    .{ "BIT_SIZE", .bit_size },
    .{ "STORAGE_SIZE", .storage_size },
    .{ "SIZEOF", .sizeof },
    .{ "C_SIZEOF", .c_sizeof },
    .{ "CMPLX", .cmplx },
    .{ "DCMPLX", .cmplx },
    .{ "REAL", .real },
    .{ "LOG", .log },
    .{ "DLOG", .log },
    .{ "CEILING", .ceiling },
    .{ "INT", .int },
    .{ "SIZE", .size },
    .{ "LBOUND", .lbound },
    .{ "UBOUND", .ubound },
    .{ "INDEX", .index },
    .{ "EXTENDS_TYPE_OF", .extends_type_of },
});

pub fn evalConstCall(
    call: ast.CallOrSubscript,
    resolver: anytype,
    eval_const_fn: anytype,
    to_real_fn: anytype,
) anyerror!?ConstValue {
    const kind = constCallKind(call.name) orelse return null;
    switch (kind) {
        .len => {
            if (call.args.len != 1) return null;
            const len = eval_mod.exprConstantCharacterLen(call.args[0], resolver orelse return null) orelse
                ((try literals.evalConstCharLen(call.args[0], resolver, eval_const_fn)) orelse return null);
            return .{ .integer = std.math.cast(i64, len) orelse return error.NumberTooLong };
        },
        .transfer => return evalConstTransfer(call.args, resolver, eval_const_fn),
        .achar => {
            if (call.args.len == 0 or call.args.len > 2) return null;
            const first = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            const scalar = switch (first) {
                .integer => |value| value,
                else => return null,
            };
            if (call.args.len == 2) {
                const kind_arg = (try eval_const_fn(call.args[1], resolver)) orelse return null;
                if (kind_arg != .integer) return null;
            }
            if (scalar < 0 or scalar > std.math.maxInt(u21)) return null;
            const res = resolver orelse return null;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(scalar), &buf) catch return null;
            return .{ .string = try res.internString(buf[0..len]) };
        },
        .acos => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            const is_double = constValuePrefersDouble(arg);
            return .{ .real = .{
                .value = std.math.acos(to_real_fn(arg)),
                .is_double = is_double,
            } };
        },
        .sqrt => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return .{ .real = .{ .value = std.math.sqrt(to_real_fn(arg)), .is_double = true } };
        },
        .log10 => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return .{ .real = .{ .value = std.math.log10(to_real_fn(arg)), .is_double = true } };
        },
        .atan => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return .{ .real = .{ .value = std.math.atan(to_real_fn(arg)), .is_double = true } };
        },
        .atan2 => {
            if (call.args.len != 2) return null;
            const y = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            const x = (try eval_const_fn(call.args[1], resolver)) orelse return null;
            return .{ .real = .{ .value = std.math.atan2(to_real_fn(y), to_real_fn(x)), .is_double = true } };
        },
        .abs => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return switch (arg) {
                .integer => |v| .{ .integer = if (v < 0) -v else v },
                .real => |v| .{ .real = .{ .value = @abs(v.value), .is_double = v.is_double } },
                else => null,
            };
        },
        .epsilon => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            const is_double = constValuePrefersDouble(arg);
            return .{ .real = .{
                .value = if (is_double) std.math.floatEps(f64) else @as(f64, std.math.floatEps(f32)),
                .is_double = is_double,
            } };
        },
        .tiny => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return switch (arg) {
                .integer, .logical => blk: {
                    const bits = (try evalConstBitSize(call.args[0], resolver, eval_const_fn)) orelse 32;
                    if (bits <= 0 or bits > 64) return null;
                    break :blk .{ .integer = signedIntegerMinForBits(@intCast(bits)) };
                },
                else => .{ .real = .{ .value = std.math.floatMin(f64), .is_double = true } },
            };
        },
        .huge => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return switch (arg) {
                .integer, .logical => blk: {
                    const bits = (try evalConstBitSize(call.args[0], resolver, eval_const_fn)) orelse 32;
                    if (bits <= 0 or bits > 64) return null;
                    break :blk .{ .integer = signedIntegerMaxForBits(@intCast(bits)) };
                },
                else => .{ .real = .{ .value = std.math.floatMax(f64), .is_double = true } },
            };
        },
        .dpmpar => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            if (arg != .integer) return null;
            return switch (arg.integer) {
                1 => .{ .real = .{ .value = std.math.floatEps(f64), .is_double = true } },
                2 => .{ .real = .{ .value = std.math.floatMin(f64), .is_double = true } },
                3 => .{ .real = .{ .value = std.math.floatMax(f64), .is_double = true } },
                else => null,
            };
        },
        .min => return evalConstMinMax(call.args, resolver, eval_const_fn, true),
        .max => return evalConstMinMax(call.args, resolver, eval_const_fn, false),
        .selected_real_kind => {
            if (call.args.len == 0 or call.args.len > 2) return null;
            const precision = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            const p = switch (precision) {
                .integer => |v| v,
                else => return null,
            };
            if (call.args.len == 2) {
                const range = (try eval_const_fn(call.args[1], resolver)) orelse return null;
                if (range != .integer) return null;
            }
            return .{ .integer = selectedRealKindForPrecision(p) };
        },
        .selected_int_kind => {
            if (call.args.len != 1) return null;
            const precision = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            const p = switch (precision) {
                .integer => |v| v,
                else => return null,
            };
            return .{ .integer = selectedIntKindForDigits(p) };
        },
        .selected_char_kind => {
            if (call.args.len != 1) return null;
            const selector = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            const text = switch (selector) {
                .string => |v| v,
                else => return null,
            };
            return .{ .integer = selectedCharKind(text) };
        },
        .same_type_as => {
            if (call.args.len != 2) return null;
            const res = resolver orelse return null;
            const lhs = res.exprTypeSpec(call.args[0]) orelse return null;
            const rhs = res.exprTypeSpec(call.args[1]) orelse return null;
            return .{ .logical = evalConstSameTypeAs(call.args[0], lhs, call.args[1], rhs, res) orelse return null };
        },
        .kind => {
            if (call.args.len != 1) return null;
            return .{ .integer = (try evalConstKind(call.args[0], resolver, eval_const_fn)) orelse return null };
        },
        .bit_size => {
            if (call.args.len != 1) return null;
            const bits = (try evalConstBitSize(call.args[0], resolver, eval_const_fn)) orelse return null;
            return .{ .integer = bits };
        },
        .storage_size => return evalConstExprMeasure(call.args, resolver, eval_const_fn, .storage_size_bits),
        .sizeof => return evalConstExprMeasure(call.args, resolver, eval_const_fn, .sizeof_bytes),
        .c_sizeof => return evalConstExprMeasure(call.args, resolver, eval_const_fn, .c_sizeof_bytes),
        .cmplx => {
            if (call.args.len == 0 or call.args.len > 3) return null;
            const first = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            var result = constValueToComplex(first) orelse return null;
            if (call.args.len >= 2) {
                const second = (try eval_const_fn(call.args[1], resolver)) orelse return null;
                const second_complex = constValueToComplex(second) orelse return null;
                if (result.imag != 0.0 or second_complex.imag != 0.0) return null;
                result.imag = second_complex.real;
            }
            if (call.args.len == 3) {
                const kind_arg = (try eval_const_fn(call.args[2], resolver)) orelse return null;
                result.is_double = switch (kind_arg) {
                    .integer => |v| v >= 8,
                    else => return null,
                };
            }
            if (std.ascii.eqlIgnoreCase(call.name, "dcmplx")) result.is_double = true;
            return .{ .complex = result };
        },
        .real => {
            if (call.args.len == 0 or call.args.len > 2) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return switch (arg) {
                .integer => |v| .{ .real = .{ .value = @floatFromInt(v), .is_double = true } },
                .real => |v| .{ .real = .{ .value = v.value, .is_double = true } },
                else => null,
            };
        },
        .log => {
            if (call.args.len != 1) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return .{ .real = .{ .value = @log(to_real_fn(arg)), .is_double = true } };
        },
        .ceiling => {
            if (call.args.len == 0 or call.args.len > 2) return null;
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return .{ .integer = @intFromFloat(@ceil(to_real_fn(arg))) };
        },
        .int => {
            if (call.args.len == 0 or call.args.len > 2) return null;
            if (call.args[0].* == .literal and call.args[0].literal.kind == .string) {
                if (try literals.parseBozInt(call.args[0].literal.text)) |boz| {
                    return .{ .integer = boz };
                }
            }
            const arg = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            return switch (arg) {
                .integer => arg,
                .real => |v| .{ .integer = @intFromFloat(@trunc(v.value)) },
                else => null,
            };
        },
        .size => {
            if (call.args.len == 0 or call.args.len > 2) return null;
            const res = resolver orelse return null;
            const dim = if (call.args.len == 2) blk: {
                const dim_val = (try eval_const_fn(call.args[1], resolver)) orelse return null;
                break :blk switch (dim_val) {
                    .integer => |v| std.math.cast(usize, v) orelse return null,
                    else => return null,
                };
            } else null;
            const extent = switch (call.args[0].*) {
                .identifier => |ident| res.arrayExtent(ident, dim),
                .array_constructor => |ctor| blk: {
                    if (dim != null and dim.? != 1) break :blk null;
                    break :blk std.math.cast(i64, ctor.items.len);
                },
                .call_or_subscript => |inner| blk: {
                    if (!std.ascii.eqlIgnoreCase(inner.name, "transfer")) break :blk null;
                    if (inner.args.len < 3) break :blk null;
                    const size_value = (try eval_const_fn(inner.args[2], resolver)) orelse break :blk null;
                    const elem_count = switch (size_value) {
                        .integer => |v| v,
                        else => break :blk null,
                    };
                    if (dim != null and dim.? != 1) break :blk null;
                    break :blk elem_count;
                },
                else => null,
            } orelse return null;
            return .{ .integer = extent };
        },
        .lbound, .ubound => {
            if (call.args.len == 0 or call.args.len > 2) return null;
            if (call.args.len != 2) return null;
            const res = resolver orelse return null;
            const dim_value = (try eval_const_fn(call.args[1], resolver)) orelse return null;
            const dim = switch (dim_value) {
                .integer => |v| std.math.cast(usize, v) orelse return null,
                else => return null,
            };
            if (dim == 0) return null;
            const ident = switch (call.args[0].*) {
                .identifier => |name| name,
                else => return null,
            };
            const lower = res.arrayLowerBound(ident, dim) orelse return null;
            if (kind == .lbound) return .{ .integer = lower };
            const extent = res.arrayExtent(ident, dim) orelse return null;
            return .{ .integer = lower + extent - 1 };
        },
        .index => {
            if (call.args.len < 2 or call.args.len > 3) return null;
            const string_value = (try eval_const_fn(call.args[0], resolver)) orelse return null;
            const substring_value = (try eval_const_fn(call.args[1], resolver)) orelse return null;
            const string_bytes = switch (string_value) {
                .string => |bytes| bytes,
                else => return null,
            };
            const substring_bytes = switch (substring_value) {
                .string => |bytes| bytes,
                else => return null,
            };
            const back = if (call.args.len == 3) blk: {
                const back_value = (try eval_const_fn(call.args[2], resolver)) orelse return null;
                break :blk switch (back_value) {
                    .logical => |value| value,
                    else => return null,
                };
            } else false;
            return .{ .integer = evalConstIndex(string_bytes, substring_bytes, back) };
        },
        .extends_type_of => {
            if (call.args.len != 2) return null;
            const res = resolver orelse return null;
            const lhs = res.exprTypeSpec(call.args[0]) orelse return null;
            const rhs = res.exprTypeSpec(call.args[1]) orelse return null;
            return .{ .logical = evalConstExtendsTypeOf(call.args[0], lhs, call.args[1], rhs, res) orelse return null };
        },
    }
}

fn evalConstIndex(string_bytes: []const u8, substring_bytes: []const u8, back: bool) i64 {
    if (substring_bytes.len == 0) {
        return if (back)
            @intCast(string_bytes.len + 1)
        else
            1;
    }
    const idx = if (back)
        std.mem.lastIndexOf(u8, string_bytes, substring_bytes)
    else
        std.mem.indexOf(u8, string_bytes, substring_bytes);
    return if (idx) |value|
        @intCast(value + 1)
    else
        0;
}

fn evalConstTransfer(
    args: []const *ast.Expr,
    resolver: anytype,
    eval_const_fn: anytype,
) !?ConstValue {
    if (args.len < 2 or args.len > 3) return null;
    if (args.len == 3) return null;

    const res = resolver orelse return null;
    const source_value = try eval_const_fn(args[0], resolver);
    const source_spec = res.exprTypeSpec(args[0]) orelse return null;
    const mold_spec = res.exprTypeSpec(args[1]) orelse return null;

    const raw = (try encodeCharacterTransferSourceBytes(args[0], source_value, source_spec, resolver, eval_const_fn, res)) orelse return null;
    return (try decodeTransferResult(res, raw, args[1], mold_spec)) orelse return null;
}

fn encodeCharacterTransferSourceBytes(
    source_expr: *const ast.Expr,
    maybe_source_value: ?ConstValue,
    source_spec: symbols.TypeSpec,
    resolver: anytype,
    eval_const_fn: anytype,
    const_resolver: evaluator.ConstResolver,
) !?[]u8 {
    if (maybe_source_value) |source_value| {
        switch (source_value) {
            .string => |bytes| {
                if (source_spec.lowered_kind == .character) {
                    return encodeCharacterTransferBytes(const_resolver, bytes, source_spec);
                }
                return duplicateRawTransferBytes(const_resolver, bytes);
            },
            .integer => |value| return encodeIntegerTransferBytes(const_resolver, value, source_spec),
            .logical => |value| return encodeIntegerTransferBytes(const_resolver, if (value) 1 else 0, source_spec),
            else => {},
        }
    }

    return switch (source_expr.*) {
        .array_constructor => |ctor| blk: {
            const alloc = const_resolver.allocator orelse break :blk null;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(alloc);
            for (ctor.items) |item| {
                const item_value = (try eval_const_fn(item, resolver)) orelse break :blk null;
                const item_text = switch (item_value) {
                    .string => |bytes| bytes,
                    else => break :blk null,
                };
                const item_raw = (try encodeCharacterTransferBytes(const_resolver, item_text, source_spec)) orelse break :blk null;
                try out.appendSlice(alloc, item_raw);
            }
            break :blk try out.toOwnedSlice(alloc);
        },
        else => null,
    };
}

fn decodeTransferResult(
    resolver: evaluator.ConstResolver,
    raw: []const u8,
    mold_expr: *const ast.Expr,
    mold_spec: symbols.TypeSpec,
) !?ConstValue {
    return switch (mold_spec.lowered_kind) {
        .character => .{ .string = (try decodeCharacterTransferBytes(resolver, raw, mold_spec)) orelse return null },
        .integer, .logical => blk: {
            const bytes = transferStorageBytesForExpr(resolver, mold_expr, mold_spec) orelse return null;
            const int_value = decodeIntegerTransferBytes(raw, bytes);
            break :blk if (mold_spec.lowered_kind == .logical)
                .{ .logical = int_value != 0 }
            else
                .{ .integer = int_value };
        },
        .derived => .{ .string = (try decodeDerivedTransferBytes(resolver, raw, mold_expr, mold_spec)) orelse return null },
        else => null,
    };
}

fn encodeCharacterTransferBytes(
    resolver: evaluator.ConstResolver,
    text: []const u8,
    spec: symbols.TypeSpec,
) !?[]u8 {
    const alloc = resolver.allocator orelse return null;
    const char_len = constantCharacterLen(spec) orelse return null;
    const kind_value = spec.kind_value orelse 1;
    switch (kind_value) {
        1 => {
            const out = try alloc.alloc(u8, char_len);
            @memset(out, ' ');
            const count = @min(out.len, text.len);
            @memcpy(out[0..count], text[0..count]);
            return out;
        },
        4 => {
            const out = try alloc.alloc(u8, char_len * 4);
            var offset: usize = 0;
            var iter = std.unicode.Utf8View.init(text) catch return null;
            var utf8 = iter.iterator();
            var chars_written: usize = 0;
            while (chars_written < char_len) : (chars_written += 1) {
                const codepoint = utf8.nextCodepoint() orelse ' ';
                var buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &buf, codepoint, .little);
                @memcpy(out[offset .. offset + 4], &buf);
                offset += 4;
            }
            return out;
        },
        else => return null,
    }
}

fn encodeIntegerTransferBytes(
    resolver: evaluator.ConstResolver,
    value: i64,
    spec: symbols.TypeSpec,
) !?[]u8 {
    const alloc = resolver.allocator orelse return null;
    const bytes = transferStorageBytesForType(spec) orelse return null;
    const out = try alloc.alloc(u8, bytes);
    @memset(out, 0);
    var bits: u64 = @bitCast(value);
    var index: usize = 0;
    while (index < bytes) : (index += 1) {
        out[index] = @truncate(bits & 0xff);
        bits >>= 8;
    }
    return out;
}

fn duplicateRawTransferBytes(
    resolver: evaluator.ConstResolver,
    bytes: []const u8,
) !?[]u8 {
    const alloc = resolver.allocator orelse return null;
    return try alloc.dupe(u8, bytes);
}

fn decodeCharacterTransferBytes(
    resolver: evaluator.ConstResolver,
    raw: []const u8,
    spec: symbols.TypeSpec,
) !?[]const u8 {
    const alloc = resolver.allocator orelse return null;
    const char_len = constantCharacterLen(spec) orelse return null;
    const kind_value = spec.kind_value orelse 1;
    switch (kind_value) {
        1 => {
            const out = try alloc.alloc(u8, char_len);
            @memset(out, 0);
            const count = @min(out.len, raw.len);
            @memcpy(out[0..count], raw[0..count]);
            return out;
        },
        4 => {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(alloc);
            var index: usize = 0;
            var chars_read: usize = 0;
            while (chars_read < char_len) : (chars_read += 1) {
                const remaining = raw.len -| index;
                const codepoint = if (remaining >= 4)
                    @as(u32, raw[index]) |
                        (@as(u32, raw[index + 1]) << 8) |
                        (@as(u32, raw[index + 2]) << 16) |
                        (@as(u32, raw[index + 3]) << 24)
                else
                    0;
                if (codepoint > std.math.maxInt(u21)) return null;
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buf) catch return null;
                try out.appendSlice(alloc, utf8_buf[0..utf8_len]);
                index += @min(@as(usize, 4), remaining);
            }
            return try out.toOwnedSlice(alloc);
        },
        else => return null,
    }
}

fn decodeDerivedTransferBytes(
    resolver: evaluator.ConstResolver,
    raw: []const u8,
    mold_expr: *const ast.Expr,
    mold_spec: symbols.TypeSpec,
) !?[]const u8 {
    const alloc = resolver.allocator orelse return null;
    const bytes = transferStorageBytesForExpr(resolver, mold_expr, mold_spec) orelse return null;
    const out = try alloc.alloc(u8, bytes);
    @memset(out, 0);
    const count = @min(out.len, raw.len);
    @memcpy(out[0..count], raw[0..count]);
    return out;
}

fn decodeIntegerTransferBytes(raw: []const u8, bytes: usize) i64 {
    var accum: u64 = 0;
    const count = @min(bytes, @min(raw.len, @sizeOf(u64)));
    var index: usize = 0;
    while (index < count) : (index += 1) {
        accum |= @as(u64, raw[index]) << @intCast(index * 8);
    }
    if (bytes < 8 and bytes != 0) {
        const sign_bit = @as(u64, 1) << @intCast(bytes * 8 - 1);
        if ((accum & sign_bit) != 0) {
            accum |= ~(@as(u64, 0)) << @intCast(bytes * 8);
        }
    }
    return @bitCast(accum);
}

fn constantCharacterLen(spec: symbols.TypeSpec) ?usize {
    if (spec.lowered_kind != .character) return null;
    return switch (spec.char_len_kind) {
        .constant => spec.char_len,
        .none => spec.char_len orelse 1,
        .assumed, .deferred => null,
    };
}

fn transferStorageBytesForExpr(
    resolver: evaluator.ConstResolver,
    expr: *const ast.Expr,
    spec: symbols.TypeSpec,
) ?usize {
    if (transferStorageBytesForType(spec)) |bytes| return bytes;
    const measured = resolver.exprMeasure(expr, .sizeof_bytes);
    return std.math.cast(usize, measured orelse return null);
}

fn transferStorageBytesForType(spec: symbols.TypeSpec) ?usize {
    return switch (spec.lowered_kind) {
        .integer, .logical => blk: {
            const kind_value = spec.kind_value orelse 4;
            if (kind_value <= 0) break :blk 4;
            if (kind_value <= 16) break :blk std.math.cast(usize, kind_value) orelse null;
            break :blk std.math.cast(usize, @divExact(kind_value, 8)) orelse null;
        },
        .derived => blk: {
            const name = spec.derived_type_name orelse break :blk null;
            if (std.ascii.eqlIgnoreCase(name, "c_ptr") or std.ascii.eqlIgnoreCase(name, "c_funptr")) {
                break :blk @sizeOf(usize);
            }
            break :blk null;
        },
        else => null,
    };
}

fn constValuePrefersDouble(value: ConstValue) bool {
    return switch (value) {
        .real => |v| v.is_double,
        .complex => |v| v.is_double,
        else => false,
    };
}

fn constValueToComplex(value: ConstValue) ?symbols.ComplexConst {
    return switch (value) {
        .integer => |v| .{ .real = @floatFromInt(v), .imag = 0.0, .is_double = false },
        .real => |v| .{ .real = v.value, .imag = 0.0, .is_double = v.is_double },
        .complex => |v| v,
        else => null,
    };
}

fn constCallKind(name: []const u8) ?ConstCallKind {
    var upper_buf: [64]u8 = undefined;
    if (name.len > upper_buf.len) return null;
    for (name, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    return ConstCallMap.get(upper_buf[0..name.len]);
}

fn evalConstMinMax(args: []const *ast.Expr, resolver: anytype, eval_const_fn: anytype, is_min: bool) !?ConstValue {
    if (args.len < 2) return null;
    var any_real = false;
    var best_real: f64 = 0.0;
    var best_real_is_double = false;
    var best_int: i64 = 0;
    var initialized = false;
    for (args) |arg_expr| {
        const value = (try eval_const_fn(arg_expr, resolver)) orelse return null;
        switch (value) {
            .integer => |v| {
                if (!initialized) {
                    best_int = v;
                    best_real = @floatFromInt(v);
                    initialized = true;
                } else {
                    if (is_min) {
                        if (v < best_int) best_int = v;
                        if (@as(f64, @floatFromInt(v)) < best_real) best_real = @floatFromInt(v);
                    } else {
                        if (v > best_int) best_int = v;
                        if (@as(f64, @floatFromInt(v)) > best_real) best_real = @floatFromInt(v);
                    }
                }
            },
            .real => |v| {
                const rv = v.value;
                if (!initialized) {
                    best_real = rv;
                    best_int = @intFromFloat(rv);
                    best_real_is_double = v.is_double;
                    initialized = true;
                } else if (is_min) {
                    if (rv < best_real) {
                        best_real = rv;
                        best_real_is_double = v.is_double;
                    }
                } else {
                    if (rv > best_real) {
                        best_real = rv;
                        best_real_is_double = v.is_double;
                    }
                }
                any_real = true;
            },
            else => return null,
        }
    }
    if (!initialized) return null;
    return if (any_real)
        .{ .real = .{ .value = best_real, .is_double = best_real_is_double } }
    else
        .{ .integer = best_int };
}

fn selectedRealKindForPrecision(precision: i64) i64 {
    if (precision <= 6) return 4;
    if (precision <= 15) return 8;
    return -1;
}

fn selectedIntKindForDigits(precision: i64) i64 {
    if (precision <= 2) return 1;
    if (precision <= 4) return 2;
    if (precision <= 9) return 4;
    if (precision <= 18) return 8;
    return -1;
}

fn selectedCharKind(selector: []const u8) i64 {
    const trimmed = std.mem.trim(u8, selector, &std.ascii.whitespace);
    if (trimmed.len == 0) return -1;
    if (std.ascii.eqlIgnoreCase(trimmed, "ascii")) return 1;
    if (std.ascii.eqlIgnoreCase(trimmed, "default")) return 1;
    if (std.ascii.eqlIgnoreCase(trimmed, "iso_10646")) return 4;
    return -1;
}

fn evalConstSameTypeAs(
    lhs_expr: *const ast.Expr,
    lhs: symbols.TypeSpec,
    rhs_expr: *const ast.Expr,
    rhs: symbols.TypeSpec,
    resolver: evaluator.ConstResolver,
) ?bool {
    _ = resolver;
    if (@intFromPtr(lhs_expr) == @intFromPtr(rhs_expr)) return true;
    if (lhs.lowered_kind != rhs.lowered_kind) return false;
    if (lhs.polymorphic or rhs.polymorphic) return null;
    return typeSpecsExactlyMatch(lhs, rhs);
}

fn evalConstExtendsTypeOf(
    lhs_expr: *const ast.Expr,
    lhs: symbols.TypeSpec,
    rhs_expr: *const ast.Expr,
    rhs: symbols.TypeSpec,
    resolver: evaluator.ConstResolver,
) ?bool {
    if (@intFromPtr(lhs_expr) == @intFromPtr(rhs_expr)) return true;
    if (lhs.lowered_kind != .derived or rhs.lowered_kind != .derived) {
        if (lhs.polymorphic or rhs.polymorphic) return null;
        return typeSpecsExactlyMatch(lhs, rhs);
    }

    const lhs_name = lhs.derived_type_name orelse return null;
    const rhs_name = rhs.derived_type_name orelse return null;

    if (!lhs.polymorphic and !rhs.polymorphic) {
        return resolver.derivedExtends(lhs_name, rhs_name);
    }

    if (lhs.polymorphic and rhs.polymorphic) {
        if (!resolver.derivedExtends(lhs_name, rhs_name) and !resolver.derivedExtends(rhs_name, lhs_name)) return false;
        return null;
    }

    if (lhs.polymorphic) {
        if (resolver.derivedExtends(lhs_name, rhs_name)) return true;
        if (!resolver.derivedExtends(rhs_name, lhs_name)) return false;
        return null;
    }

    if (!resolver.derivedExtends(lhs_name, rhs_name)) return false;
    return null;
}

fn typeSpecsExactlyMatch(lhs: symbols.TypeSpec, rhs: symbols.TypeSpec) bool {
    if (lhs.lowered_kind != rhs.lowered_kind) return false;
    if (lhs.kind_value != rhs.kind_value) return false;
    if (lhs.char_len_kind != rhs.char_len_kind) return false;
    if (lhs.char_len != rhs.char_len) return false;
    if (lhs.polymorphic != rhs.polymorphic) return false;
    if (lhs.lowered_kind != .derived) return true;
    if (lhs.derived_type_name == null or rhs.derived_type_name == null) {
        return lhs.derived_type_name == null and rhs.derived_type_name == null;
    }
    return std.ascii.eqlIgnoreCase(lhs.derived_type_name.?, rhs.derived_type_name.?);
}

fn evalConstExprMeasure(
    args: []const *ast.Expr,
    resolver: anytype,
    eval_const_fn: anytype,
    measure: ExprMeasureKind,
) !?ConstValue {
    if (args.len == 0 or args.len > 2) return null;
    const res = resolver orelse return null;
    if (args.len == 2) {
        const kind_value = (try eval_const_fn(args[1], resolver)) orelse return null;
        if (kind_value != .integer) return null;
    }
    return .{ .integer = res.exprMeasure(args[0], measure) orelse return null };
}

fn evalConstKind(expr: *const ast.Expr, resolver: anytype, eval_const_fn: anytype) !?i64 {
    return switch (expr.*) {
        .literal => |lit| switch (lit.kind) {
            .integer, .logical => literalKindValueOrDefault(lit.text, resolver, 4),
            .real => literalKindValueOrDefault(lit.text, resolver, if (literals.realLiteralHasDoublePrecisionHint(lit.text)) 8 else 4),
            .string => quotedStringKindValueOrDefault(lit.text, resolver, 1),
            .hollerith => 1,
            else => null,
        },
        .identifier, .unary, .binary, .call_or_subscript, .complex_literal => blk: {
            const value = (try eval_const_fn(expr, resolver)) orelse break :blk null;
            break :blk switch (value) {
                .integer => 4,
                .logical => 4,
                .real => |v| if (v.is_double) 8 else 4,
                .complex => |v| if (v.is_double) 16 else 8,
                .string => 1,
            };
        },
        else => blk: {
            const res = resolver orelse break :blk null;
            const spec = res.exprTypeSpec(expr) orelse break :blk null;
            break :blk switch (spec.lowered_kind) {
                .integer, .logical => spec.kind_value orelse 4,
                .real => spec.kind_value orelse 4,
                .double_precision => spec.kind_value orelse 8,
                .complex => spec.kind_value orelse 4,
                .complex_double => spec.kind_value orelse 8,
                .character => spec.kind_value orelse 1,
                .derived => null,
            };
        },
    };
}

fn literalKindValueOrDefault(text: []const u8, resolver: anytype, default_kind: i64) !?i64 {
    const suffix = literals.literalKindSuffix(text) orelse return default_kind;
    return (try evalKindSelectorValue(suffix, resolver)) orelse default_kind;
}

fn quotedStringKindValueOrDefault(text: []const u8, resolver: anytype, default_kind: i64) !?i64 {
    const prefix = literals.characterLiteralKindPrefix(text) orelse return default_kind;
    return (try evalKindSelectorValue(prefix, resolver)) orelse default_kind;
}

fn evalConstBitSize(expr: *const ast.Expr, resolver: anytype, eval_const_fn: anytype) !?i64 {
    return switch (expr.*) {
        .literal => |lit| switch (lit.kind) {
            .integer, .logical => try literalBitSize(lit.text, resolver, 32),
            .real => try literalBitSize(lit.text, resolver, if (literals.realLiteralHasDoublePrecisionHint(lit.text)) 64 else 32),
            else => null,
        },
        .identifier, .unary, .binary, .call_or_subscript => blk: {
            _ = (try eval_const_fn(expr, resolver)) orelse return null;
            break :blk 32;
        },
        else => null,
    };
}

fn literalBitSize(text: []const u8, resolver: anytype, default_bits: i64) !?i64 {
    const suffix = literals.literalKindSuffix(text) orelse return default_bits;
    const kind_value = (try evalKindSelectorValue(suffix, resolver)) orelse return default_bits;
    return kindValueToBitSize(kind_value);
}

fn signedIntegerMinForBits(bits: u8) i64 {
    const normalized: u8 = if (bits == 0) 32 else @min(bits, 64);
    if (normalized >= 64) return std.math.minInt(i64);
    const shift_amt: u6 = @intCast(normalized - 1);
    const limit: i128 = @as(i128, 1) << shift_amt;
    return @intCast(-limit);
}

fn signedIntegerMaxForBits(bits: u8) i64 {
    const normalized: u8 = if (bits == 0) 32 else @min(bits, 64);
    if (normalized >= 64) return std.math.maxInt(i64);
    const shift_amt: u6 = @intCast(normalized - 1);
    const limit: i128 = @as(i128, 1) << shift_amt;
    return @intCast(limit - 1);
}

fn evalKindSelectorValue(suffix: []const u8, resolver: anytype) !?i64 {
    if (suffix.len == 0) return null;
    if (std.ascii.isDigit(suffix[0])) return try literals.parseInt(suffix);
    if (resolver) |res| {
        if (res.resolve(suffix)) |value| {
            return switch (value) {
                .integer => |v| v,
                else => null,
            };
        }
    }
    if (std.ascii.eqlIgnoreCase(suffix, "int8")) return 1;
    if (std.ascii.eqlIgnoreCase(suffix, "int16")) return 2;
    if (std.ascii.eqlIgnoreCase(suffix, "int32")) return 4;
    if (std.ascii.eqlIgnoreCase(suffix, "int64")) return 8;
    if (std.ascii.eqlIgnoreCase(suffix, "real32")) return 4;
    if (std.ascii.eqlIgnoreCase(suffix, "real64")) return 8;
    return null;
}

fn kindValueToBitSize(kind_value: i64) i64 {
    return if (kind_value > 0 and kind_value <= 16) kind_value * 8 else kind_value;
}
