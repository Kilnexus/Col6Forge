const std = @import("std");
const ast = @import("../../../../input.zig");
const common = @import("../../common.zig");
const utils = @import("../../utils.zig");
const casting = @import("../casting.zig");
const call = @import("../call/mod.zig");
const array_actuals = @import("../call/array_actuals.zig");
const dispatch = @import("../dispatch/mod.zig");
const resolution = @import("../dispatch/resolution.zig");
const const_components = @import("../../../shared/const_components.zig");
const memory_intrinsics = @import("../../../shared/memory_intrinsics.zig");
const evaluator = @import("../../../../../semantic/evaluator.zig");
const shared = @import("shared.zig");
const numeric = @import("numeric.zig");
const libm = @import("libm.zig");
const arrays = @import("arrays.zig");
const Expr = shared.Expr;
const Context = shared.Context;
const IRType = shared.IRType;
const ValueRef = shared.ValueRef;
const EmitError = shared.EmitError;
const emitIntrinsicUnaryFloat = shared.emitIntrinsicUnaryFloat;
const emitIntrinsicLen = shared.emitIntrinsicLen;
const emitIntrinsicTrim = shared.emitIntrinsicTrim;
const emitSin = libm.emitSin;
const emitCos = libm.emitCos;
const emitSqrt = libm.emitSqrt;
const emitExp = libm.emitExp;
const emitLog = libm.emitLog;
const emitTan = libm.emitTan;
const emitAsin = libm.emitAsin;
const emitAcos = libm.emitAcos;
const emitSinh = libm.emitSinh;
const emitCosh = libm.emitCosh;
const emitAlog = libm.emitAlog;
const emitAlog10 = libm.emitAlog10;
const emitTanh = libm.emitTanh;
const emitAtan = libm.emitAtan;
const emitAtan2 = libm.emitAtan2;
const emitDoubleUnaryLibm = libm.emitDoubleUnaryLibm;
const emitDoubleBinaryLibm = libm.emitDoubleBinaryLibm;
const emitDoubleTrunc = libm.emitDoubleTrunc;
const emitDoubleRound = libm.emitDoubleRound;
const emitIntrinsicIdnint = libm.emitIntrinsicIdnint;
const emitDoubleMinMax = libm.emitDoubleMinMax;
const emitDoubleSign = libm.emitDoubleSign;
const emitDoubleDim = libm.emitDoubleDim;
const emitDoubleRemainder = libm.emitDoubleRemainder;
const emitIntrinsicDprod = libm.emitIntrinsicDprod;
const emitIntrinsicDble = libm.emitIntrinsicDble;
const emitIntrinsicSngl = libm.emitIntrinsicSngl;
const emitIntrinsicAimag = libm.emitIntrinsicAimag;
const emitIntrinsicDimag = libm.emitIntrinsicDimag;
const emitIntrinsicCabs = libm.emitIntrinsicCabs;
const emitComplexCsin = libm.emitComplexCsin;
const emitComplexCcos = libm.emitComplexCcos;
const emitComplexCexp = libm.emitComplexCexp;
const emitComplexClog = libm.emitComplexClog;
const emitComplexCsqrt = libm.emitComplexCsqrt;
const emitIntrinsicAbs = numeric.emitIntrinsicAbs;
const emitIntrinsicIabs = numeric.emitIntrinsicIabs;
const emitIntrinsicInt = numeric.emitIntrinsicInt;
const emitIntrinsicIdint = numeric.emitIntrinsicIdint;
const emitIntrinsicMinMax = numeric.emitIntrinsicMinMax;
const emitMinMaxNInt = numeric.emitMinMaxNInt;
const emitIntrinsicSign = numeric.emitIntrinsicSign;
const emitIntrinsicDim = numeric.emitIntrinsicDim;
const emitIntrinsicDconjg = numeric.emitIntrinsicDconjg;
const emitIntrinsicCmplx = numeric.emitIntrinsicCmplx;
const emitIntrinsicDcmplx = numeric.emitIntrinsicDcmplx;
const emitIntrinsicFloat = numeric.emitIntrinsicFloat;
const emitIntrinsicLogical = numeric.emitIntrinsicLogical;
const emitIntrinsicIchar = numeric.emitIntrinsicIchar;
const emitIntrinsicAchar = numeric.emitIntrinsicAchar;
const emitIntrinsicRand = numeric.emitIntrinsicRand;
const emitIntrinsicDpmpar = numeric.emitIntrinsicDpmpar;
const emitIntrinsicEpsilon = numeric.emitIntrinsicEpsilon;
const emitIntrinsicHuge = numeric.emitIntrinsicHuge;
const emitIntrinsicAnint = numeric.emitIntrinsicAnint;
const emitIntrinsicNint = numeric.emitIntrinsicNint;
const emitIntrinsicRemainder = numeric.emitIntrinsicRemainder;
const emitIntrinsicConjg = numeric.emitIntrinsicConjg;
const emitIntrinsicAny = arrays.emitIntrinsicAny;
const emitIntrinsicAll = arrays.emitIntrinsicAll;
const emitIntrinsicSum = arrays.emitIntrinsicSum;
const emitIntrinsicCount = arrays.emitIntrinsicCount;
const emitIntrinsicLbound = arrays.emitIntrinsicLbound;
const emitIntrinsicRank = arrays.emitIntrinsicRank;
const emitIntrinsicSize = arrays.emitIntrinsicSize;
const emitIntrinsicUbound = arrays.emitIntrinsicUbound;
const emitIntrinsicAllocated = arrays.emitIntrinsicAllocated;
const emitIntrinsicIsContiguous = arrays.emitIntrinsicIsContiguous;
const emitIntrinsicInternalLiteralSubstring = arrays.emitIntrinsicInternalLiteralSubstring;
const emitIntrinsicIndex = shared.emitIntrinsicIndex;
const IntrinsicTag = enum {
    sin,
    cos,
    sqrt,
    abs,
    iabs,
    aint,
    int_,
    idint,
    dabs,
    dint,
    dnint,
    idnint,
    amod,
    mod_,
    dmod,
    min,
    max,
    dmin1,
    dmax1,
    amin0,
    amax0,
    amin1,
    amax1,
    min0,
    max0,
    min1,
    max1,
    sign,
    dsign,
    isign,
    dim,
    ddim,
    idim,
    dprod,
    dot_product,
    conjg,
    dconjg,
    cmplx,
    dcmplx,
    float_,
    logical_,
    dble,
    sngl,
    aimag,
    dimag,
    cabs,
    anint,
    nint,
    ichar,
    achar,
    rand_,
    dpmpar,
    epsilon,
    huge,
    count,
    index,
    size,
    sizeof_,
    c_sizeof,
    storage_size,
    command_argument_count,
    etime,
    signal,
    fstat,
    stat,
    lstat,
    is_contiguous,
    len_,
    kind_,
    len_trim,
    lbound,
    rank,
    trim_,
    tan,
    dtan,
    asin,
    dasin,
    acos,
    dacos,
    sinh,
    dsinh,
    cosh,
    dcosh,
    dsqrt,
    dsin,
    dcos,
    exp,
    dexp,
    alog,
    log_,
    dlog,
    alog10,
    log10,
    dlog10,
    tanh,
    dtanh,
    atan,
    datan,
    atan2,
    datan2,
    scan,
    any,
    all,
    sum_,
    internal_literal_substring,
    allocated,
    associated,
    extends_type_of,
    present,
    same_type_as,
    transfer,
    pack,
    cshift,
    eoshift,
    ubound,
    verify,
    repeat,
    c_loc,
    c_funloc,
    csin,
    ccos,
    cexp,
    clog,
    csqrt,
};

const intrinsic_tag_map = std.StaticStringMap(IntrinsicTag).initComptime(.{
    .{ "sin", .sin },
    .{ "cos", .cos },
    .{ "sqrt", .sqrt },
    .{ "abs", .abs },
    .{ "iabs", .iabs },
    .{ "aint", .aint },
    .{ "int", .int_ },
    .{ "ifix", .int_ },
    .{ "idint", .idint },
    .{ "dabs", .dabs },
    .{ "dint", .dint },
    .{ "dnint", .dnint },
    .{ "idnint", .idnint },
    .{ "amod", .amod },
    .{ "mod", .mod_ },
    .{ "dmod", .dmod },
    .{ "min", .min },
    .{ "max", .max },
    .{ "dmin1", .dmin1 },
    .{ "dmax1", .dmax1 },
    .{ "amin0", .amin0 },
    .{ "amax0", .amax0 },
    .{ "amin1", .amin1 },
    .{ "amax1", .amax1 },
    .{ "min0", .min0 },
    .{ "max0", .max0 },
    .{ "min1", .min1 },
    .{ "max1", .max1 },
    .{ "sign", .sign },
    .{ "dsign", .dsign },
    .{ "isign", .isign },
    .{ "dim", .dim },
    .{ "ddim", .ddim },
    .{ "idim", .idim },
    .{ "dprod", .dprod },
    .{ "dot_product", .dot_product },
    .{ "conjg", .conjg },
    .{ "dconjg", .dconjg },
    .{ "cmplx", .cmplx },
    .{ "dcmplx", .dcmplx },
    .{ "float", .float_ },
    .{ "real", .float_ },
    .{ "logical", .logical_ },
    .{ "dble", .dble },
    .{ "sngl", .sngl },
    .{ "aimag", .aimag },
    .{ "dimag", .dimag },
    .{ "cabs", .cabs },
    .{ "anint", .anint },
    .{ "nint", .nint },
    .{ "ichar", .ichar },
    .{ "iachar", .ichar },
    .{ "achar", .achar },
    .{ "char", .achar },
    .{ "rand", .rand_ },
    .{ "dpmpar", .dpmpar },
    .{ "epsilon", .epsilon },
    .{ "huge", .huge },
    .{ "count", .count },
    .{ "index", .index },
    .{ "size", .size },
    .{ "sizeof", .sizeof_ },
    .{ "c_sizeof", .c_sizeof },
    .{ "storage_size", .storage_size },
    .{ "command_argument_count", .command_argument_count },
    .{ "etime", .etime },
    .{ "signal", .signal },
    .{ "fstat", .fstat },
    .{ "stat", .stat },
    .{ "lstat", .lstat },
    .{ "is_contiguous", .is_contiguous },
    .{ "len", .len_ },
    .{ "kind", .kind_ },
    .{ "len_trim", .len_trim },
    .{ "lbound", .lbound },
    .{ "rank", .rank },
    .{ "trim", .trim_ },
    .{ "tan", .tan },
    .{ "dtan", .dtan },
    .{ "asin", .asin },
    .{ "dasin", .dasin },
    .{ "acos", .acos },
    .{ "dacos", .dacos },
    .{ "sinh", .sinh },
    .{ "dsinh", .dsinh },
    .{ "cosh", .cosh },
    .{ "dcosh", .dcosh },
    .{ "dsqrt", .dsqrt },
    .{ "dsin", .dsin },
    .{ "dcos", .dcos },
    .{ "exp", .exp },
    .{ "dexp", .dexp },
    .{ "alog", .alog },
    .{ "log", .log_ },
    .{ "dlog", .dlog },
    .{ "alog10", .alog10 },
    .{ "log10", .log10 },
    .{ "dlog10", .dlog10 },
    .{ "tanh", .tanh },
    .{ "dtanh", .dtanh },
    .{ "atan", .atan },
    .{ "datan", .datan },
    .{ "atan2", .atan2 },
    .{ "datan2", .datan2 },
    .{ "scan", .scan },
    .{ "any", .any },
    .{ "all", .all },
    .{ "sum", .sum_ },
    .{ "__col6forge_substring", .internal_literal_substring },
    .{ "allocated", .allocated },
    .{ "associated", .associated },
    .{ "extends_type_of", .extends_type_of },
    .{ "present", .present },
    .{ "same_type_as", .same_type_as },
    .{ "transfer", .transfer },
    .{ "pack", .pack },
    .{ "cshift", .cshift },
    .{ "eoshift", .eoshift },
    .{ "ubound", .ubound },
    .{ "verify", .verify },
    .{ "repeat", .repeat },
    .{ "c_loc", .c_loc },
    .{ "c_funloc", .c_funloc },
    .{ "csin", .csin },
    .{ "ccos", .ccos },
    .{ "cexp", .cexp },
    .{ "clog", .clog },
    .{ "csqrt", .csqrt },
});

fn lookupIntrinsicTag(ctx: *Context, name: []const u8) EmitError!?IntrinsicTag {
    var stack_buf: [32]u8 = undefined;
    var heap_buf: ?[]u8 = null;
    const key: []u8 = if (name.len <= stack_buf.len)
        stack_buf[0..name.len]
    else blk: {
        const buf = try ctx.allocator.alloc(u8, name.len);
        heap_buf = buf;
        break :blk buf;
    };
    defer if (heap_buf) |buf| ctx.allocator.free(buf);
    for (name, 0..) |ch, idx| key[idx] = std.ascii.toLower(ch);
    return intrinsic_tag_map.get(key);
}

pub fn emitIntrinsicCall(ctx: *Context, builder: anytype, name: []const u8, args: []*Expr) EmitError!ValueRef {
    const tag = try lookupIntrinsicTag(ctx, name) orelse return error.UnknownIntrinsic;
    switch (tag) {
        .sin => return emitSin(ctx, builder, args),
        .cos => return emitCos(ctx, builder, args),
        .sqrt => return emitSqrt(ctx, builder, args),
        .abs => return emitIntrinsicAbs(ctx, builder, args),
        .iabs => return emitIntrinsicIabs(ctx, builder, args),
        .aint => return emitIntrinsicUnaryFloat(ctx, builder, "trunc", args),
        .int_ => return emitIntrinsicInt(ctx, builder, args),
        .idint => return emitIntrinsicIdint(ctx, builder, args),
        .dabs => return emitDoubleUnaryLibm(ctx, builder, "fabs", args),
        .dint => return emitDoubleTrunc(ctx, builder, args),
        .dnint => return emitDoubleRound(ctx, builder, args),
        .idnint => return emitIntrinsicIdnint(ctx, builder, args),
        .amod => return emitIntrinsicRemainder(ctx, builder, args, false, true),
        .mod_ => return emitIntrinsicRemainder(ctx, builder, args, true, true),
        .dmod => return emitDoubleRemainder(ctx, builder, args),
        .min => return emitIntrinsicMinMax(ctx, builder, args, false),
        .max => return emitIntrinsicMinMax(ctx, builder, args, true),
        .dmin1 => return emitDoubleMinMax(ctx, builder, args, false),
        .dmax1 => return emitDoubleMinMax(ctx, builder, args, true),
        .amin0 => {
            const int_min = try emitMinMaxNInt(ctx, builder, args, false);
            return casting.coerce(ctx, builder, int_min, .f32);
        },
        .amax0 => {
            const int_max = try emitMinMaxNInt(ctx, builder, args, true);
            return casting.coerce(ctx, builder, int_max, .f32);
        },
        .amin1 => return emitIntrinsicMinMax(ctx, builder, args, false),
        .amax1 => return emitIntrinsicMinMax(ctx, builder, args, true),
        .min0 => return emitMinMaxNInt(ctx, builder, args, false),
        .max0 => return emitMinMaxNInt(ctx, builder, args, true),
        .min1 => {
            const real_min = try emitIntrinsicMinMax(ctx, builder, args, false);
            return casting.coerce(ctx, builder, real_min, ctx.defaultIntegerIRType());
        },
        .max1 => {
            const real_max = try emitIntrinsicMinMax(ctx, builder, args, true);
            return casting.coerce(ctx, builder, real_max, ctx.defaultIntegerIRType());
        },
        .sign => return emitIntrinsicSign(ctx, builder, args),
        .dsign => return emitDoubleSign(ctx, builder, args),
        .isign => {
            const value = try emitIntrinsicSign(ctx, builder, args);
            return casting.coerce(ctx, builder, value, ctx.defaultIntegerIRType());
        },
        .dim => return emitIntrinsicDim(ctx, builder, args),
        .ddim => return emitDoubleDim(ctx, builder, args),
        .idim => {
            const value = try emitIntrinsicDim(ctx, builder, args);
            return casting.coerce(ctx, builder, value, ctx.defaultIntegerIRType());
        },
        .dprod => return emitIntrinsicDprod(ctx, builder, args),
        .dot_product => return emitIntrinsicDotProduct(ctx, args),
        .conjg => return emitIntrinsicConjg(ctx, builder, args),
        .dconjg => return emitIntrinsicDconjg(ctx, builder, args),
        .cmplx => return emitIntrinsicCmplx(ctx, builder, args),
        .dcmplx => return emitIntrinsicDcmplx(ctx, builder, args),
        .float_ => return emitIntrinsicFloat(ctx, builder, args),
        .logical_ => return emitIntrinsicLogical(ctx, builder, args),
        .dble => return emitIntrinsicDble(ctx, builder, args),
        .sngl => return emitIntrinsicSngl(ctx, builder, args),
        .aimag => return emitIntrinsicAimag(ctx, builder, args),
        .dimag => return emitIntrinsicDimag(ctx, builder, args),
        .cabs => return emitIntrinsicCabs(ctx, builder, args),
        .anint => return emitIntrinsicAnint(ctx, builder, args),
        .nint => return emitIntrinsicNint(ctx, builder, args),
        .ichar => return emitIntrinsicIchar(ctx, builder, args),
        .achar => return emitIntrinsicAchar(ctx, builder, args),
        .rand_ => return emitIntrinsicRand(ctx, builder, args),
        .dpmpar => return emitIntrinsicDpmpar(ctx, args),
        .epsilon => return emitIntrinsicEpsilon(ctx, args),
        .huge => return emitIntrinsicHuge(ctx, args),
        .count => return emitIntrinsicCount(ctx, builder, args),
        .index => return emitIntrinsicIndex(ctx, builder, args, .index),
        .size => return emitIntrinsicSize(ctx, builder, args),
        .sizeof_, .c_sizeof => return emitIntrinsicSizeof(ctx, args),
        .storage_size => return emitIntrinsicStorageSize(ctx, args),
        .command_argument_count => return emitIntrinsicCommandArgumentCount(ctx, args),
        .etime => return emitIntrinsicEtime(ctx, args),
        .signal => return emitIntrinsicSignal(ctx, args),
        .fstat, .stat, .lstat => return emitIntrinsicStatLike(ctx, args),
        .is_contiguous => return emitIntrinsicIsContiguous(ctx, builder, args),
        .len_ => return emitIntrinsicLen(ctx, builder, args),
        .kind_ => return emitIntrinsicKind(ctx, args),
        .len_trim => return shared.emitIntrinsicLenTrim(ctx, builder, args),
        .lbound => return emitIntrinsicLbound(ctx, builder, args),
        .rank => return emitIntrinsicRank(ctx, builder, args),
        .trim_ => return emitIntrinsicTrim(ctx, builder, args),
        .tan => return emitTan(ctx, builder, args),
        .dtan => return emitDoubleUnaryLibm(ctx, builder, "tan", args),
        .asin => return emitAsin(ctx, builder, args),
        .dasin => return emitDoubleUnaryLibm(ctx, builder, "asin", args),
        .acos => return emitAcos(ctx, builder, args),
        .dacos => return emitDoubleUnaryLibm(ctx, builder, "acos", args),
        .sinh => return emitSinh(ctx, builder, args),
        .dsinh => return emitDoubleUnaryLibm(ctx, builder, "sinh", args),
        .cosh => return emitCosh(ctx, builder, args),
        .dcosh => return emitDoubleUnaryLibm(ctx, builder, "cosh", args),
        .dsqrt => return emitDoubleUnaryLibm(ctx, builder, "sqrt", args),
        .dsin => return emitDoubleUnaryLibm(ctx, builder, "sin", args),
        .dcos => return emitDoubleUnaryLibm(ctx, builder, "cos", args),
        .exp => return emitExp(ctx, builder, args),
        .dexp => return emitDoubleUnaryLibm(ctx, builder, "exp", args),
        .alog => return emitAlog(ctx, builder, args),
        .log_ => return emitLog(ctx, builder, args),
        .dlog => return emitDoubleUnaryLibm(ctx, builder, "log", args),
        .alog10 => return emitAlog10(ctx, builder, args),
        .log10 => return emitDoubleUnaryLibm(ctx, builder, "log10", args),
        .dlog10 => return emitDoubleUnaryLibm(ctx, builder, "log10", args),
        .tanh => return emitTanh(ctx, builder, args),
        .dtanh => return emitDoubleUnaryLibm(ctx, builder, "tanh", args),
        .atan => return emitAtan(ctx, builder, args),
        .datan => return emitDoubleUnaryLibm(ctx, builder, "atan", args),
        .atan2 => return emitAtan2(ctx, builder, args),
        .datan2 => return emitDoubleBinaryLibm(ctx, builder, "atan2", args),
        .scan => return emitIntrinsicIndex(ctx, builder, args, .scan),
        .any => return emitIntrinsicAny(ctx, builder, args),
        .all => return emitIntrinsicAll(ctx, builder, args),
        .sum_ => return emitIntrinsicSum(ctx, builder, args),
        .internal_literal_substring => return emitIntrinsicInternalLiteralSubstring(ctx, builder, args),
        .allocated => return emitIntrinsicAllocated(args),
        .associated => return emitIntrinsicAllocated(args),
        .extends_type_of => return emitDeclaredLogicalIntrinsicCall(ctx, builder, name, args),
        .present => return emitIntrinsicAllocated(args),
        .same_type_as => return emitDeclaredLogicalIntrinsicCall(ctx, builder, name, args),
        .transfer => return emitIntrinsicTransfer(ctx, builder, args),
        .pack, .cshift, .eoshift => return emitIntrinsicArraySourcePtr(ctx, builder, args),
        .ubound => return emitIntrinsicUbound(ctx, builder, args),
        .verify => return emitIntrinsicIndex(ctx, builder, args, .verify),
        .repeat => return emitIntrinsicRepeat(ctx, builder, args),
        .c_loc => return emitIntrinsicCLoc(ctx, builder, args),
        .c_funloc => return emitIntrinsicCFunloc(ctx, args),
        .csin => return emitComplexCsin(ctx, builder, args),
        .ccos => return emitComplexCcos(ctx, builder, args),
        .cexp => return emitComplexCexp(ctx, builder, args),
        .clog => return emitComplexClog(ctx, builder, args),
        .csqrt => return emitComplexCsqrt(ctx, builder, args),
    }
}

fn emitIntrinsicKind(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    if (args.len != 1) return error.InvalidIntrinsicCall;
    if (dispatch.isCharacterExpr(ctx, args[0])) return ctx.constDefaultInteger(1);

    const arg_ty = try casting.exprType(ctx, args[0]);
    const default_int_kind: i64 = switch (ctx.defaultIntegerIRType()) {
        .i64 => 8,
        else => 4,
    };
    const kind_value: i64 = switch (arg_ty) {
        .i1, .i32 => default_int_kind,
        .i64 => 8,
        .f32 => 4,
        .f64 => 8,
        .complex_f32 => 4,
        .complex_f64 => 8,
        else => return error.UnsupportedIntrinsicType,
    };
    return ctx.constDefaultInteger(kind_value);
}

fn emitIntrinsicSizeof(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    if (args.len != 1) return error.InvalidIntrinsicCall;
    return ctx.constDefaultInteger(0);
}

fn emitIntrinsicStorageSize(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    if (args.len < 1 or args.len > 2) return error.InvalidIntrinsicCall;
    return ctx.constDefaultInteger(0);
}

fn emitIntrinsicCommandArgumentCount(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    if (args.len != 0) return error.InvalidIntrinsicCall;
    return ctx.constDefaultInteger(0);
}

fn emitIntrinsicEtime(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    _ = ctx;
    if (args.len < 1 or args.len > 2) return error.InvalidIntrinsicCall;
    return .{ .name = "0.000000e+00", .ty = .f32, .is_ptr = false };
}

fn emitIntrinsicSignal(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    if (args.len < 2 or args.len > 3) return error.InvalidIntrinsicCall;
    return ctx.constDefaultInteger(0);
}

fn emitIntrinsicStatLike(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    if (args.len < 2 or args.len > 3) return error.InvalidIntrinsicCall;
    return ctx.constDefaultInteger(0);
}

fn emitIntrinsicDotProduct(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    _ = ctx;
    if (args.len != 2) return error.InvalidIntrinsicCall;
    return .{ .name = "0.000000e+00", .ty = .f32, .is_ptr = false };
}

fn emitIntrinsicRepeat(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len != 2) return error.InvalidIntrinsicCall;
    const plan = (try dispatch.emitCharacterValuePlan(ctx, builder, args[0])) orelse return error.UnsupportedIntrinsicType;
    return .{ .name = plan.ptr.name, .ty = .ptr, .is_ptr = true };
}

fn emitIntrinsicArraySourcePtr(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len < 2 or args.len > 3) return error.InvalidIntrinsicCall;
    const actual = (try array_actuals.resolveArrayActual(ctx, builder, args[0])) orelse return error.UnsupportedIntrinsicType;
    return actual.base_ptr;
}

fn emitDeclaredLogicalIntrinsicCall(ctx: *Context, builder: anytype, name: []const u8, args: []*Expr) EmitError!ValueRef {
    const fn_name = try resolution.ensureExternalDeclForCall(ctx, name, .i1, args, false);
    return call.emitCall(ctx, builder, fn_name, .i1, args, false);
}

fn emitIntrinsicCLoc(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len != 1) return error.InvalidIntrinsicCall;
    const ptr = try call.emitArgPointer(ctx, builder, args[0]);
    return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
}

fn emitIntrinsicCFunloc(ctx: *Context, args: []*Expr) EmitError!ValueRef {
    if (args.len != 1) return error.InvalidIntrinsicCall;
    const arg = args[0];
    if (arg.* != .identifier) return error.UnsupportedIntrinsicType;
    const ptr = try call.procedureDesignatorPointer(ctx, arg.identifier) orelse return error.UnknownSymbol;
    return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
}

const TransferScalarResultInfo = struct {
    storage_size: usize,
    value_ty: ?IRType,
};

const TransferSourceBytes = struct {
    ptr: ValueRef,
    size: ValueRef,
};

fn emitIntrinsicTransfer(ctx: *Context, builder: anytype, args: []*Expr) EmitError!ValueRef {
    if (args.len < 2 or args.len > 3) return error.InvalidIntrinsicCall;
    if (args.len == 3) return error.UnsupportedIntrinsicType;

    if (try emitIntrinsicTransferCharacterResult(ctx, builder, args[0], args[1])) |char_result| {
        return char_result;
    }

    const result = try transferScalarResultInfo(ctx, args[1]);
    const dst_ptr = try allocaByteBuffer(ctx, builder, result.storage_size);
    try zeroByteBuffer(ctx, builder, dst_ptr, try ctx.constI64(@intCast(result.storage_size)));

    const src = try transferSourceBytes(ctx, builder, args[0]);
    const dst_size = try ctx.constI64(@intCast(result.storage_size));
    const copy_len = try emitTransferMinI64(ctx, builder, src.size, dst_size);
    try emitMemcpyBytes(ctx, builder, dst_ptr, src.ptr, copy_len);

    if (result.value_ty == null) {
        return .{ .name = dst_ptr.name, .ty = .ptr, .is_ptr = false };
    }

    const tmp = try ctx.nextTemp();
    try builder.load(tmp, result.value_ty.?, dst_ptr);
    return .{ .name = tmp, .ty = result.value_ty.?, .is_ptr = false };
}

fn emitIntrinsicTransferCharacterResult(
    ctx: *Context,
    builder: anytype,
    source_expr: *Expr,
    mold_expr: *Expr,
) EmitError!?ValueRef {
    if (!dispatch.isCharacterExpr(ctx, mold_expr)) return null;
    var char_len = (try dispatch.emitCharacterLenValue(ctx, builder, mold_expr)) orelse return error.UnsupportedIntrinsicType;
    if (char_len.ty != .i64) char_len = try casting.coerce(ctx, builder, char_len, .i64);

    const is_zero_name = try ctx.nextTemp();
    try builder.compare(is_zero_name, "icmp", "eq", .i64, char_len, try ctx.constI64(0));
    const storage_len_name = try ctx.nextTemp();
    try builder.select(
        storage_len_name,
        .i64,
        .{ .name = is_zero_name, .ty = .i1, .is_ptr = false },
        try ctx.constI64(1),
        char_len,
    );
    const storage_len = ValueRef{ .name = storage_len_name, .ty = .i64, .is_ptr = false };

    const dst_name = try ctx.nextTemp();
    try builder.allocaArrayValue(dst_name, .i8, storage_len);
    const dst_ptr = ValueRef{ .name = dst_name, .ty = .ptr, .is_ptr = true };
    try zeroByteBuffer(ctx, builder, dst_ptr, char_len);

    const src = try transferSourceBytes(ctx, builder, source_expr);
    const copy_len = try emitTransferMinI64(ctx, builder, src.size, char_len);
    try emitMemcpyBytes(ctx, builder, dst_ptr, src.ptr, copy_len);
    return .{ .name = dst_name, .ty = .ptr, .is_ptr = false };
}

fn transferScalarResultInfo(ctx: *Context, mold: *Expr) EmitError!TransferScalarResultInfo {
    if (ctx.derivedTypeNameForExpr(mold)) |derived_name| {
        const layout = ctx.findDerivedTypeLayout(derived_name) orelse return error.UnknownSymbol;
        if (isBuiltinIsoCPointerType(derived_name)) {
            return .{
                .storage_size = layout.size,
                .value_ty = .ptr,
            };
        }
        return .{
            .storage_size = layout.size,
            .value_ty = null,
        };
    }

    switch (mold.*) {
        .identifier => |name| {
            const sym = ctx.findSymbol(name) orelse return error.UnknownSymbol;
            if (sym.isCharacter()) return error.UnsupportedIntrinsicType;
            const storage_ty = common.symbolStorageIRType(sym, ctx.options.target_layout);
            const value_ty = switch (sym.loweredKind()) {
                .logical => ctx.typeFromKind(sym.loweredKind()),
                else => if (sym.loweredKind() == .derived) null else ctx.typeFromKind(sym.loweredKind()),
            };
            return .{
                .storage_size = byteSizeForIRType(storage_ty),
                .value_ty = value_ty,
            };
        },
        .literal => |lit| switch (lit.kind) {
            .integer => {
                const ty = integerLiteralIRType(ctx, lit.text);
                return .{ .storage_size = byteSizeForIRType(ty), .value_ty = ty };
            },
            .real => {
                const ty = casting.exprType(ctx, mold) catch return error.UnsupportedIntrinsicType;
                return .{ .storage_size = byteSizeForIRType(ty), .value_ty = ty };
            },
            .logical => {
                const storage_ty = ctx.defaultIntegerIRType();
                return .{ .storage_size = byteSizeForIRType(storage_ty), .value_ty = .i1 };
            },
            else => return error.UnsupportedIntrinsicType,
        },
        else => {
            const ty = casting.exprType(ctx, mold) catch return error.UnsupportedIntrinsicType;
            return .{ .storage_size = byteSizeForIRType(ty), .value_ty = ty };
        },
    }
}

fn transferSourceBytes(ctx: *Context, builder: anytype, expr: *Expr) EmitError!TransferSourceBytes {
    if (evaluator.evalConst(expr, transferConstResolver(ctx)) catch null) |const_value| {
        switch (const_value) {
            .string => |bytes| {
                const ptr = try emitConstTransferByteBuffer(ctx, builder, bytes);
                return .{ .ptr = ptr, .size = try ctx.constI64(@intCast(bytes.len)) };
            },
            else => {},
        }
    }

    if (try array_actuals.resolveArrayActual(ctx, builder, expr)) |actual| {
        const elem_count = try array_actuals.emitExtentProductI64(ctx, builder, actual.extents);
        var total_bytes = try array_actuals.emitMulI64(ctx, builder, elem_count, try ctx.constI64(@intCast(byteSizeForIRType(actual.elem_ty))));
        if (!array_actuals.valueRefEquals(actual.address_scale, try ctx.constI64(1))) {
            total_bytes = try array_actuals.emitMulI64(ctx, builder, total_bytes, actual.address_scale);
        }
        return .{ .ptr = actual.base_ptr, .size = total_bytes };
    }

    if (try dispatch.emitCharacterValuePlan(ctx, builder, expr)) |char_plan| {
        var char_len = char_plan.logical_len;
        if (char_len.ty != .i64) char_len = try casting.coerce(ctx, builder, char_len, .i64);
        return .{ .ptr = char_plan.ptr, .size = char_len };
    }

    switch (expr.*) {
        .literal => |lit| switch (lit.kind) {
            .string => {
                const ptr = try casting.emitLiteral(ctx, builder, lit);
                const len = try ctx.constI64(@intCast(utils.decodedStringLen(lit.text)));
                return .{ .ptr = .{ .name = ptr.name, .ty = .ptr, .is_ptr = true }, .size = len };
            },
            .hollerith => {
                const ptr = try casting.emitLiteral(ctx, builder, lit);
                const bytes = utils.hollerithBytes(lit.text) orelse return error.UnsupportedIntrinsicType;
                return .{ .ptr = .{ .name = ptr.name, .ty = .ptr, .is_ptr = true }, .size = try ctx.constI64(@intCast(bytes.len)) };
            },
            else => {},
        },
        else => {},
    }

    if (ctx.derivedTypeNameForExpr(expr)) |derived_name| {
        if (!isBuiltinIsoCPointerType(derived_name)) {
            const layout = ctx.findDerivedTypeLayout(derived_name) orelse return error.UnknownSymbol;
            const value = try callValue(ctx, builder, expr);
            return .{
                .ptr = .{ .name = value.name, .ty = .ptr, .is_ptr = true },
                .size = try ctx.constI64(@intCast(layout.size)),
            };
        }
    }

    const value = try callValue(ctx, builder, expr);
    const alloc_ty = if (value.ty == .i1) ctx.defaultIntegerIRType() else value.ty;
    const tmp = try ctx.nextTemp();
    try builder.alloca(tmp, alloc_ty);
    const ptr = ValueRef{ .name = tmp, .ty = .ptr, .is_ptr = true };
    const stored = if (alloc_ty == value.ty) value else try casting.coerce(ctx, builder, value, alloc_ty);
    try builder.store(stored, ptr);
    return .{
        .ptr = ptr,
        .size = try ctx.constI64(@intCast(byteSizeForIRType(alloc_ty))),
    };
}

fn callValue(ctx: *Context, builder: anytype, expr: *Expr) EmitError!ValueRef {
    return dispatch.emitExpr(ctx, builder, expr);
}

fn allocaByteBuffer(ctx: *Context, builder: anytype, size: usize) EmitError!ValueRef {
    const name = try ctx.nextTemp();
    if (size <= 1) {
        try builder.alloca(name, .i8);
    } else {
        try builder.allocaArray(name, .i8, size);
    }
    return .{ .name = name, .ty = .ptr, .is_ptr = true };
}

fn zeroByteBuffer(ctx: *Context, builder: anytype, ptr: ValueRef, size: ValueRef) EmitError!void {
    const memset_name = try ctx.ensureDeclRaw("llvm.memset.p0.i64", .void, &[_]IRType{ .ptr, .i8, .i64, .i1 }, false);
    try builder.callTyped(null, .void, memset_name, &.{ ptr, .{ .name = "0", .ty = .i8, .is_ptr = false }, size, .{ .name = "false", .ty = .i1, .is_ptr = false } });
}

const emitMemcpyBytes = memory_intrinsics.emitMemcpyBytes;

fn emitTransferMinI64(ctx: *Context, builder: anytype, lhs: ValueRef, rhs: ValueRef) EmitError!ValueRef {
    const cmp_name = try ctx.nextTemp();
    try builder.compare(cmp_name, "icmp", "ule", .i64, lhs, rhs);
    const cmp = ValueRef{ .name = cmp_name, .ty = .i1, .is_ptr = false };
    const min_name = try ctx.nextTemp();
    try builder.select(min_name, .i64, cmp, lhs, rhs);
    return .{ .name = min_name, .ty = .i64, .is_ptr = false };
}

fn byteSizeForIRType(ty: IRType) usize {
    return switch (ty) {
        .i1 => 1,
        .i8 => 1,
        .i32 => 4,
        .i64 => 8,
        .f32 => 4,
        .f64 => 8,
        .v2f32 => 8,
        .complex_f32 => 8,
        .complex_f64 => 16,
        .ptr => @sizeOf(usize),
        .void => 0,
    };
}

fn transferConstResolver(ctx: *Context) evaluator.ConstResolver {
    return .{
        .ctx = ctx,
        .resolveFn = resolveTransferConstValue,
        .componentConstFn = resolveTransferComponentConstValue,
    };
}

fn resolveTransferConstValue(raw_ctx: *anyopaque, name: []const u8) ?ast.sema.ConstValue {
    const ctx: *Context = @ptrCast(@alignCast(raw_ctx));
    const sym = ctx.findSymbol(name) orelse return null;
    return sym.const_value;
}

fn resolveTransferComponentConstValue(raw_ctx: *anyopaque, base: *const Expr, name: []const u8) ?ast.sema.ConstValue {
    const ctx: *Context = @ptrCast(@alignCast(raw_ctx));
    return const_components.resolveDerivedComponentConstValue(ctx, transferConstResolver(ctx), base, name);
}

fn emitConstTransferByteBuffer(ctx: *Context, builder: anytype, bytes: []const u8) EmitError!ValueRef {
    const ptr = try allocaByteBuffer(ctx, builder, if (bytes.len == 0) 1 else bytes.len);
    for (bytes, 0..) |byte, idx| {
        const elem_ptr = if (idx == 0) ptr else blk: {
            const elem_ptr_name = try ctx.nextTemp();
            try builder.gep(elem_ptr_name, .i8, ptr, try ctx.constI64(@intCast(idx)));
            break :blk ValueRef{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true };
        };
        try builder.store(.{ .name = std.fmt.allocPrint(ctx.allocator, "{d}", .{byte}) catch "0", .ty = .i8, .is_ptr = false }, elem_ptr);
    }
    return ptr;
}

fn integerLiteralIRType(ctx: *Context, text: []const u8) IRType {
    const suffix = literalKindSuffix(text) orelse return ctx.defaultIntegerIRType();
    if (suffix.len == 0) return ctx.defaultIntegerIRType();

    var all_digits = true;
    for (suffix) |ch| {
        if (!std.ascii.isDigit(ch)) {
            all_digits = false;
            break;
        }
    }
    if (all_digits) {
        const kind_value = std.fmt.parseInt(i64, suffix, 10) catch return ctx.defaultIntegerIRType();
        return if (kind_value >= 8) .i64 else .i32;
    }
    if (containsIgnoreCase(suffix, "intptr") or
        containsIgnoreCase(suffix, "int64") or
        containsIgnoreCase(suffix, "size_t"))
    {
        return .i64;
    }
    return ctx.defaultIntegerIRType();
}

fn literalKindSuffix(text: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, text, '_') orelse return null;
    if (idx + 1 >= text.len) return null;
    return text[idx + 1 ..];
}

fn isBuiltinIsoCPointerType(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "c_ptr") or std.ascii.eqlIgnoreCase(name, "c_funptr");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

