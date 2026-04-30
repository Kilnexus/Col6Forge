const std = @import("std");
const ast = @import("../ast/nodes.zig");
const symbols = @import("symbol/mod.zig");

const IntrinsicReturnTypeMap = std.StaticStringMap(ast.TypeKind).initComptime(.{
    .{ "CMPLX", .complex },
    .{ "COMPLEX", .complex },
    .{ "CONJG", .complex },
    .{ "CSIN", .complex },
    .{ "CCOS", .complex },
    .{ "CEXP", .complex },
    .{ "CLOG", .complex },
    .{ "CSQRT", .complex },
    .{ "DCMPLX", .complex_double },
    .{ "DCONJG", .complex_double },
    .{ "ANY", .logical },
    .{ "ALL", .logical },
    .{ "ALLOCATED", .logical },
    .{ "ASSOCIATED", .logical },
    .{ "EXTENDS_TYPE_OF", .logical },
    .{ "IS_CONTIGUOUS", .logical },
    .{ "LOGICAL", .logical },
    .{ "PRESENT", .logical },
    .{ "SAME_TYPE_AS", .logical },
    .{ "KIND", .integer },
    .{ "INT", .integer },
    .{ "ACCESS", .integer },
    .{ "CHDIR", .integer },
    .{ "CHMOD", .integer },
    .{ "FGET", .integer },
    .{ "FGETC", .integer },
    .{ "FPUT", .integer },
    .{ "FPUTC", .integer },
    .{ "GETCWD", .integer },
    .{ "HOSTNM", .integer },
    .{ "IFIX", .integer },
    .{ "IDINT", .integer },
    .{ "NINT", .integer },
    .{ "IDNINT", .integer },
    .{ "IABS", .integer },
    .{ "MOD", .integer },
    .{ "ISIGN", .integer },
    .{ "IDIM", .integer },
    .{ "MIN0", .integer },
    .{ "MIN1", .integer },
    .{ "MAX0", .integer },
    .{ "MAX1", .integer },
    .{ "ICHAR", .integer },
    .{ "IACHAR", .integer },
    .{ "IBCLR", .integer },
    .{ "IBITS", .integer },
    .{ "IBSET", .integer },
    .{ "IAND", .integer },
    .{ "IEOR", .integer },
    .{ "IOR", .integer },
    .{ "ISHFT", .integer },
    .{ "ISHFTC", .integer },
    .{ "COUNT", .integer },
    .{ "SIGNAL", .integer },
    .{ "INDEX", .integer },
    .{ "LINK", .integer },
    .{ "LEN", .integer },
    .{ "LEN_TRIM", .integer },
    .{ "LBOUND", .integer },
    .{ "RANK", .integer },
    .{ "LSTAT", .integer },
    .{ "FSTAT", .integer },
    .{ "RENAME", .integer },
    .{ "STAT", .integer },
    .{ "SYMLNK", .integer },
    .{ "SYSTEM", .integer },
    .{ "UBOUND", .integer },
    .{ "UNLINK", .integer },
    .{ "SHAPE", .integer },
    .{ "SCAN", .integer },
    .{ "SIZE", .integer },
    .{ "SIZEOF", .integer },
    .{ "C_SIZEOF", .integer },
    .{ "STORAGE_SIZE", .integer },
    .{ "DSHIFTL", .integer },
    .{ "DSHIFTR", .integer },
    .{ "MASKL", .integer },
    .{ "MASKR", .integer },
    .{ "MERGE_BITS", .integer },
    .{ "AND", .integer },
    .{ "OR", .integer },
    .{ "XOR", .integer },
    .{ "COMMAND_ARGUMENT_COUNT", .integer },
    .{ "VERIFY", .integer },
    .{ "ACHAR", .character },
    .{ "CHAR", .character },
    .{ "REPEAT", .character },
    .{ "TRIM", .character },
    .{ "DBLE", .double_precision },
    .{ "DINT", .double_precision },
    .{ "DNINT", .double_precision },
    .{ "DMOD", .double_precision },
    .{ "DSIGN", .double_precision },
    .{ "DDIM", .double_precision },
    .{ "DMIN1", .double_precision },
    .{ "DMAX1", .double_precision },
    .{ "DABS", .double_precision },
    .{ "DSQRT", .double_precision },
    .{ "DEXP", .double_precision },
    .{ "DLOG", .double_precision },
    .{ "DLOG10", .double_precision },
    .{ "ETIME", .real },
    .{ "DSIN", .double_precision },
    .{ "DCOS", .double_precision },
    .{ "DTAN", .double_precision },
    .{ "DASIN", .double_precision },
    .{ "DACOS", .double_precision },
    .{ "DATAN", .double_precision },
    .{ "DATAN2", .double_precision },
    .{ "DSINH", .double_precision },
    .{ "DCOSH", .double_precision },
    .{ "DTANH", .double_precision },
    .{ "DIMAG", .double_precision },
    .{ "DPROD", .double_precision },
    .{ "DOT_PRODUCT", .real },
    .{ "FLOAT", .real },
    .{ "REAL", .real },
    .{ "DPMPAR", .real },
    .{ "SNGL", .real },
    .{ "RAND", .real },
    .{ "AINT", .real },
    .{ "ANINT", .real },
    .{ "AMOD", .real },
    .{ "AMIN0", .real },
    .{ "AMIN1", .real },
    .{ "AMAX0", .real },
    .{ "AMAX1", .real },
    .{ "AIMAG", .real },
    .{ "CABS", .real },
    .{ "EPSILON", .real },
    .{ "HUGE", .real },
    .{ "EXP", .real },
    .{ "ALOG", .real },
    .{ "ALOG10", .real },
    .{ "ATAN2", .real },
});

const IntrinsicSameArgMap = std.StaticStringMap(void).initComptime(.{
    .{ "SQRT", {} },
    .{ "EXP", {} },
    .{ "ALOG", {} },
    .{ "ALOG10", {} },
    .{ "LOG", {} },
    .{ "LOG10", {} },
    .{ "SIN", {} },
    .{ "COS", {} },
    .{ "TAN", {} },
    .{ "ASIN", {} },
    .{ "ACOS", {} },
    .{ "ATAN", {} },
    .{ "SINH", {} },
    .{ "COSH", {} },
    .{ "TANH", {} },
    .{ "AINT", {} },
    .{ "ANINT", {} },
});

const IntrinsicHomogeneousArgsMap = std.StaticStringMap(void).initComptime(.{
    .{ "MAX", {} },
    .{ "MIN", {} },
    .{ "MOD", {} },
    .{ "SIGN", {} },
    .{ "DIM", {} },
});

pub fn resultDependsOnArgs(name: []const u8) bool {
    var upper_buf: [64]u8 = undefined;
    if (name.len > upper_buf.len) return false;
    for (name, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    const upper = upper_buf[0..name.len];
    if (std.mem.eql(u8, upper, "ABS")) return true;
    if (std.mem.eql(u8, upper, "PACK")) return true;
    if (std.mem.eql(u8, upper, "CSHIFT")) return true;
    if (std.mem.eql(u8, upper, "EOSHIFT")) return true;
    if (std.mem.eql(u8, upper, "MERGE")) return true;
    if (std.mem.eql(u8, upper, "REPEAT")) return true;
    if (std.mem.eql(u8, upper, "TRANSFER")) return true;
    if (IntrinsicSameArgMap.has(upper)) return true;
    if (IntrinsicHomogeneousArgsMap.has(upper)) return true;
    return false;
}

pub fn inferResultType(
    name: []const u8,
    current: symbols.TypeSpec,
    args: []const symbols.TypeSpec,
) !symbols.TypeSpec {
    var upper_buf: [64]u8 = undefined;
    if (name.len > upper_buf.len) return current;
    for (name, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    const upper = upper_buf[0..name.len];

    if (std.mem.eql(u8, upper, "__COL6FORGE_SUBSTRING")) {
        return symbols.TypeSpec.fromResolvedKind(.character, .character, null).withCharacterLength(.deferred, null);
    }

    if (std.mem.eql(u8, upper, "RESHAPE")) {
        if (args.len == 0) return current;
        return args[0];
    }

    if (std.mem.eql(u8, upper, "PACK") or
        std.mem.eql(u8, upper, "CSHIFT") or
        std.mem.eql(u8, upper, "EOSHIFT"))
    {
        if (args.len == 0) return current;
        return args[0];
    }

    if (std.mem.eql(u8, upper, "SUM")) {
        if (args.len == 0) return current;
        return args[0];
    }

    if (std.mem.eql(u8, upper, "MERGE")) {
        if (args.len == 0) return current;
        return args[0];
    }

    if (IntrinsicReturnTypeMap.get(upper)) |kind| {
        return fixedTypeSpec(kind);
    }

    if (std.mem.eql(u8, upper, "ABS")) {
        if (args.len == 0) return current;
        return absReturnType(args[0]);
    }

    if (std.mem.eql(u8, upper, "REPEAT")) {
        if (args.len == 0) return current;
        return repeatReturnType(args[0], current);
    }

    if (std.mem.eql(u8, upper, "TRANSFER")) {
        if (args.len < 2) return current;
        return transferReturnType(args[1], current);
    }

    if (IntrinsicSameArgMap.has(upper)) {
        if (args.len == 0) return current;
        return sameArgReturnType(args[0], current);
    }

    if (IntrinsicHomogeneousArgsMap.has(upper)) {
        if (args.len < 2) return error.InvalidArgumentCount;
        return homogeneousArgsReturnType(args);
    }

    return current;
}

fn fixedTypeSpec(kind: ast.TypeKind) symbols.TypeSpec {
    return switch (kind) {
        .character => symbols.TypeSpec.fromResolvedKind(.character, .character, null).withCharacterLength(.constant, 1),
        else => symbols.TypeSpec.fromResolvedKind(symbols.TypeSpec.baseKind(kind), kind, null),
    };
}

fn absReturnType(arg: symbols.TypeSpec) symbols.TypeSpec {
    return switch (arg.lowered_kind) {
        .integer => symbols.TypeSpec.fromResolvedKind(.integer, .integer, arg.kind_value),
        .real => arg,
        .double_precision => arg,
        .complex => symbols.TypeSpec.fromResolvedKind(.real, .real, complexToRealKindValue(arg.kind_value)),
        .complex_double => symbols.TypeSpec.fromResolvedKind(.real, .double_precision, complexToRealKindValue(arg.kind_value)),
        else => fixedTypeSpec(.real),
    };
}

fn sameArgReturnType(arg: symbols.TypeSpec, current: symbols.TypeSpec) symbols.TypeSpec {
    return switch (arg.lowered_kind) {
        .integer => fixedTypeSpec(.real),
        .real => arg,
        .double_precision => arg,
        .complex => arg,
        .complex_double => arg,
        else => current,
    };
}

fn repeatReturnType(arg: symbols.TypeSpec, current: symbols.TypeSpec) symbols.TypeSpec {
    if (arg.lowered_kind != .character) return current;
    return symbols.TypeSpec.fromResolvedKind(.character, .character, arg.kind_value).withCharacterLength(.deferred, null);
}

fn transferReturnType(mold: symbols.TypeSpec, current: symbols.TypeSpec) symbols.TypeSpec {
    _ = current;
    return mold;
}

fn homogeneousArgsReturnType(args: []const symbols.TypeSpec) !symbols.TypeSpec {
    const first = args[0];
    if (!isNumericType(first.lowered_kind) or first.lowered_kind == .complex or first.lowered_kind == .complex_double) {
        return error.InvalidArithmeticOperands;
    }

    for (args[1..]) |next| {
        if (!sameCallSignatureType(first, next)) return error.InvalidArithmeticOperands;
    }
    return first;
}

fn sameCallSignatureType(a: symbols.TypeSpec, b: symbols.TypeSpec) bool {
    if (a.lowered_kind != b.lowered_kind) return false;
    if (!compatibleKindValue(a.kind_value, b.kind_value)) return false;
    if (a.lowered_kind != .character) return true;
    return a.char_len_kind == b.char_len_kind and
        a.char_len == b.char_len;
}

fn compatibleKindValue(a: ?i64, b: ?i64) bool {
    if (a == null or b == null) return true;
    return a == b;
}

fn isNumericType(kind: ast.TypeKind) bool {
    return switch (kind) {
        .integer, .real, .double_precision, .complex, .complex_double => true,
        else => false,
    };
}

fn complexToRealKindValue(kind_value: ?i64) ?i64 {
    const value = kind_value orelse return null;
    if (value >= 16) return @divTrunc(value, 2);
    return value;
}

test "inferResultType keeps generic MAX typed per call signature" {
    const testing = std.testing;

    const real_spec = symbols.TypeSpec.fromResolvedKind(.real, .real, 4);
    const int_spec = symbols.TypeSpec.fromResolvedKind(.integer, .integer, 4);
    try testing.expectEqual(
        int_spec.lowered_kind,
        (try inferResultType("max", fixedTypeSpec(.real), &.{ int_spec, int_spec })).lowered_kind,
    );
    try testing.expectError(
        error.InvalidArithmeticOperands,
        inferResultType("max", fixedTypeSpec(.real), &.{ int_spec, real_spec }),
    );
}

test "inferResultType accepts generic SIGN when default double mixes with DBLE result" {
    const testing = std.testing;

    const default_double = symbols.TypeSpec.fromResolvedKind(.double_precision, .double_precision, null);
    const dble_result = symbols.TypeSpec.fromResolvedKind(.real, .double_precision, 8);

    const inferred = try inferResultType("SIGN", fixedTypeSpec(.real), &.{ default_double, dble_result });
    try testing.expectEqual(ast.TypeKind.double_precision, inferred.lowered_kind);
}

test "inferResultType still rejects conflicting explicit kind values for homogeneous intrinsic" {
    const testing = std.testing;

    const int4 = symbols.TypeSpec.fromResolvedKind(.integer, .integer, 4);
    const int8 = symbols.TypeSpec.fromResolvedKind(.integer, .integer, 8);

    try testing.expectError(
        error.InvalidArithmeticOperands,
        inferResultType("MAX", fixedTypeSpec(.integer), &.{ int4, int8 }),
    );
}

test "inferResultType recognizes ALL and SHAPE intrinsic result kinds" {
    const testing = std.testing;

    const logical_arg = symbols.TypeSpec.fromResolvedKind(.logical, .logical, null);
    const real_arg = symbols.TypeSpec.fromResolvedKind(.real, .real, 4);

    const all_result = try inferResultType("ALL", fixedTypeSpec(.real), &.{logical_arg});
    try testing.expectEqual(ast.TypeKind.logical, all_result.lowered_kind);

    const shape_result = try inferResultType("SHAPE", fixedTypeSpec(.real), &.{real_arg});
    try testing.expectEqual(ast.TypeKind.integer, shape_result.lowered_kind);
}

test "inferResultType uses mold argument type for TRANSFER" {
    const testing = std.testing;

    const int_arg = symbols.TypeSpec.fromResolvedKind(.integer, .integer, 4);
    const c_ptr_mold = symbols.TypeSpec.fromResolvedKind(.derived, .derived, null).withDerivedTypeName("c_ptr");
    const inferred = try inferResultType("TRANSFER", fixedTypeSpec(.integer), &.{ int_arg, c_ptr_mold });

    try testing.expectEqual(ast.TypeKind.derived, inferred.lowered_kind);
    try testing.expectEqualStrings("c_ptr", inferred.derived_type_name.?);
}

test "inferResultType keeps SUM element type and type inquiry intrinsics return LOGICAL" {
    const testing = std.testing;

    const int_arg = symbols.TypeSpec.fromResolvedKind(.integer, .integer, 4);
    const derived_arg = symbols.TypeSpec.fromDerived("t");

    const sum_result = try inferResultType("SUM", fixedTypeSpec(.real), &.{int_arg});
    try testing.expectEqual(ast.TypeKind.integer, sum_result.lowered_kind);
    try testing.expectEqual(@as(?i64, 4), sum_result.kind_value);

    const same_result = try inferResultType("SAME_TYPE_AS", fixedTypeSpec(.real), &.{ derived_arg, derived_arg });
    try testing.expectEqual(ast.TypeKind.logical, same_result.lowered_kind);

    const extends_result = try inferResultType("EXTENDS_TYPE_OF", fixedTypeSpec(.real), &.{ derived_arg, derived_arg });
    try testing.expectEqual(ast.TypeKind.logical, extends_result.lowered_kind);
}

test "inferResultType uses first argument type for MERGE" {
    const testing = std.testing;

    const char_arg = symbols.TypeSpec.fromResolvedKind(.character, .character, null).withCharacterLength(.constant, 2);
    const logical_arg = symbols.TypeSpec.fromResolvedKind(.logical, .logical, null);

    const inferred = try inferResultType("MERGE", fixedTypeSpec(.real), &.{ char_arg, char_arg, logical_arg });
    try testing.expectEqual(ast.TypeKind.character, inferred.lowered_kind);
    try testing.expectEqual(@as(?usize, 2), inferred.char_len);
}

test "inferResultType uses array argument type for PACK and EOSHIFT" {
    const testing = std.testing;

    const char_arg = symbols.TypeSpec.fromResolvedKind(.character, .character, null).withCharacterLength(.constant, 3);

    const pack_inferred = try inferResultType("PACK", fixedTypeSpec(.real), &.{ char_arg, fixedTypeSpec(.logical) });
    try testing.expectEqual(ast.TypeKind.character, pack_inferred.lowered_kind);
    try testing.expectEqual(@as(?usize, 3), pack_inferred.char_len);

    const eoshift_inferred = try inferResultType("EOSHIFT", fixedTypeSpec(.real), &.{ char_arg, fixedTypeSpec(.integer) });
    try testing.expectEqual(ast.TypeKind.character, eoshift_inferred.lowered_kind);
    try testing.expectEqual(@as(?usize, 3), eoshift_inferred.char_len);
}
