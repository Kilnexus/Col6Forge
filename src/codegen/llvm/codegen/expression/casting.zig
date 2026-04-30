const std = @import("std");
const ast = @import("../../../input.zig");
const sema = @import("../../../../semantic/mod.zig");
const ir = @import("../../../ir.zig");
const llvm_types = @import("../../types.zig");
const context = @import("../context/mod.zig");
const utils = @import("../utils.zig");
const literal_utils = @import("../../../../semantic/evaluator/literals.zig");

const complex = @import("complex.zig");

const Expr = ast.Expr;
const Literal = ast.Literal;
const TypeKind = ast.TypeKind;
const IRType = ir.IRType;
const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

fn intrinsicCallType(ctx: *Context, name: []const u8) ?IRType {
    if (std.ascii.eqlIgnoreCase(name, "size")) return ctx.defaultIntegerIRType();
    if (std.ascii.eqlIgnoreCase(name, "logical")) return .i1;
    if (std.ascii.eqlIgnoreCase(name, "c_associated")) return .i1;
    if (std.ascii.eqlIgnoreCase(name, "c_loc")) return .ptr;
    if (std.ascii.eqlIgnoreCase(name, "c_funloc")) return .ptr;
    return null;
}

pub fn emitLiteral(ctx: *Context, builder: anytype, lit: Literal) !ValueRef {
    switch (lit.kind) {
        .integer => {
            const normalized = try utils.normalizeIntLiteral(ctx.allocator, lit.text);
            return .{ .name = normalized, .ty = ctx.defaultIntegerIRType(), .is_ptr = false };
        },
        .real => {
            const ty: IRType = utils.realLiteralType(lit.text);
            const normalized = try utils.formatFloatLiteral(ctx.allocator, lit.text, ty);
            return .{ .name = normalized, .ty = ty, .is_ptr = false };
        },
        .logical => return .{ .name = try normalizeLogicalLiteral(lit.text), .ty = .i1, .is_ptr = false },
        .string => {
            const bytes = try utils.decodeStringLiteral(ctx.allocator, lit.text);
            return emitStringLiteral(ctx, builder, bytes);
        },
        .hollerith => {
            const bytes = utils.hollerithBytes(lit.text) orelse return error.UnsupportedLiteral;
            return emitStringLiteral(ctx, builder, bytes);
        },
        .assumed_size => return error.UnsupportedLiteral,
    }
}

fn normalizeLogicalLiteral(text: []const u8) ![]const u8 {
    return if (try literal_utils.parseLogical(text)) "1" else "0";
}

fn emitStringLiteral(ctx: *Context, builder: anytype, bytes: []const u8) !ValueRef {
    // String globals are stored as C-style bytes with a trailing NUL.
    // Fortran CHARACTER semantics are preserved by explicit length arguments at call sites.
    const name = try ctx.string_pool.intern(bytes);
    const ptr_name = try ctx.nextTemp();
    try builder.gepConstString(ptr_name, name, bytes.len + 1);
    return .{ .name = ptr_name, .ty = .ptr, .is_ptr = false };
}

pub fn emitConstTyped(ctx: *Context, builder: anytype, value: sema.ConstValue, type_kind: TypeKind) ValueRef {
    const ty = ctx.typeFromKind(type_kind);
    return switch (value) {
        .integer => |v| blk: {
            if (complex.isComplexType(ty)) {
                const elem_ty: IRType = if (ty == .complex_f64) .f64 else .f32;
                const real_ref = ValueRef{
                    .name = utils.formatFloatValue(ctx.allocator, @as(f64, @floatFromInt(v)), elem_ty),
                    .ty = elem_ty,
                    .is_ptr = false,
                };
                const imag_ref = utils.zeroValue(elem_ty);
                break :blk complex.buildComplex(ctx, builder, real_ref, imag_ref, ty) catch .{ .name = "undef", .ty = ty, .is_ptr = false };
            }
            break :blk .{
                .name = formatConstIntForType(ctx, ty, v),
                .ty = ty,
                .is_ptr = false,
            };
        },
        .real => |v| blk: {
            if (complex.isComplexType(ty)) {
                const elem_ty: IRType = if (ty == .complex_f64) .f64 else .f32;
                const real_ref = ValueRef{ .name = utils.formatFloatValue(ctx.allocator, v.value, elem_ty), .ty = elem_ty, .is_ptr = false };
                const imag_ref = utils.zeroValue(elem_ty);
                break :blk complex.buildComplex(ctx, builder, real_ref, imag_ref, ty) catch .{ .name = "undef", .ty = ty, .is_ptr = false };
            }
            break :blk .{ .name = utils.formatFloatValue(ctx.allocator, v.value, ty), .ty = ty, .is_ptr = false };
        },
        .complex => |v| blk: {
            if (!complex.isComplexType(ty)) {
                break :blk .{ .name = utils.formatFloatValue(ctx.allocator, v.real, ty), .ty = ty, .is_ptr = false };
            }
            const elem_ty: IRType = if (ty == .complex_f64) .f64 else .f32;
            const real_ref = ValueRef{ .name = utils.formatFloatValue(ctx.allocator, v.real, elem_ty), .ty = elem_ty, .is_ptr = false };
            const imag_ref = ValueRef{ .name = utils.formatFloatValue(ctx.allocator, v.imag, elem_ty), .ty = elem_ty, .is_ptr = false };
            break :blk complex.buildComplex(ctx, builder, real_ref, imag_ref, ty) catch .{ .name = "undef", .ty = ty, .is_ptr = false };
        },
        .logical => |v| blk: {
            const bit = if (v) "1" else "0";
            if (ty == .i1 or ty == .i32 or ty == .i64) {
                break :blk .{ .name = bit, .ty = ty, .is_ptr = false };
            }
            if (ty == .f32 or ty == .f64) {
                break :blk .{ .name = utils.formatFloatValue(ctx.allocator, if (v) 1.0 else 0.0, ty), .ty = ty, .is_ptr = false };
            }
            break :blk .{ .name = bit, .ty = .i1, .is_ptr = false };
        },
        .string => |bytes| {
            // Character parameters should behave like string literals.
            return emitStringLiteral(ctx, builder, bytes) catch .{ .name = "0", .ty = ty, .is_ptr = false };
        },
    };
}

fn formatConstIntForType(ctx: *Context, ty: IRType, value: i64) []const u8 {
    return if (ty == .f32 or ty == .f64)
        utils.formatFloatValue(ctx.allocator, @as(f64, @floatFromInt(value)), ty)
    else
        ctx.intLiteral(value) catch unreachable;
}

pub fn coerce(ctx: *Context, builder: anytype, value: ValueRef, target: IRType) EmitError!ValueRef {
    if (value.ty == target) return value;
    if (value.is_ptr) return error.UnexpectedPointerValue;
    if (complex.isComplexType(target)) return complex.coerceToComplex(ctx, builder, value, target);
    if (complex.isComplexType(value.ty)) {
        const real = try complex.extractComplex(ctx, builder, value, 0);
        switch (target) {
            .f32, .f64, .i32, .i64 => return coerce(ctx, builder, real, target),
            else => return unsupportedCast(value.ty, target),
        }
    }
    const tmp = try ctx.nextTemp();
    const from = value.ty;
    const to = target;
    const instr = switch (from) {
        .i32 => switch (to) {
            .f32 => "sitofp",
            .f64 => "sitofp",
            .i64 => "sext",
            .i1 => "trunc",
            else => return unsupportedCast(from, to),
        },
        .i8 => return unsupportedCast(from, to),
        .v2f32 => return unsupportedCast(from, to),
        .i64 => switch (to) {
            .i32 => "trunc",
            .f32 => "sitofp",
            .f64 => "sitofp",
            else => return unsupportedCast(from, to),
        },
        .f32 => switch (to) {
            .f64 => "fpext",
            .i32 => "fptosi",
            .i64 => "fptosi",
            else => return unsupportedCast(from, to),
        },
        .f64 => switch (to) {
            .f32 => "fptrunc",
            .i32 => "fptosi",
            .i64 => "fptosi",
            else => return unsupportedCast(from, to),
        },
        .i1 => switch (to) {
            .i32 => "zext",
            .i64 => "zext",
            else => return unsupportedCast(from, to),
        },
        .complex_f32 => return unsupportedCast(from, to),
        .complex_f64 => return unsupportedCast(from, to),
        .ptr => return unsupportedCast(from, to),
        .void => return unsupportedCast(from, to),
    };
    try builder.cast(tmp, instr, from, value, to);
    return .{ .name = tmp, .ty = to, .is_ptr = false };
}

pub fn coerceCheckedI32(ctx: *Context, builder: anytype, value: ValueRef) EmitError!ValueRef {
    switch (value.ty) {
        .i32 => return value,
        .i64 => {
            const min_i32 = ValueRef{ .name = try ctx.intLiteral(std.math.minInt(i32)), .ty = .i64, .is_ptr = false };
            const max_i32 = ValueRef{ .name = try ctx.intLiteral(std.math.maxInt(i32)), .ty = .i64, .is_ptr = false };

            const below_name = try ctx.nextTemp();
            try builder.compare(below_name, "icmp", "slt", .i64, value, min_i32);
            const below = ValueRef{ .name = below_name, .ty = .i1, .is_ptr = false };

            const above_name = try ctx.nextTemp();
            try builder.compare(above_name, "icmp", "sgt", .i64, value, max_i32);
            const above = ValueRef{ .name = above_name, .ty = .i1, .is_ptr = false };

            const overflow_name = try ctx.nextTemp();
            try builder.binary(overflow_name, "or", .i1, below, above);
            const overflow = ValueRef{ .name = overflow_name, .ty = .i1, .is_ptr = false };

            const fail_label = try ctx.nextLabel("i32_narrow_fail");
            const ok_label = try ctx.nextLabel("i32_narrow_ok");
            try builder.brCond(overflow, fail_label, ok_label);

            try builder.label(fail_label);
            const trap_name = try ctx.ensureDeclRaw("llvm.trap", .void, &.{}, false);
            try builder.callTyped(null, .void, trap_name, &.{});
            try builder.emitUnreachable();

            try builder.label(ok_label);
            return coerce(ctx, builder, value, .i32);
        },
        else => return coerce(ctx, builder, value, .i32),
    }
}

fn unsupportedCast(from: IRType, to: IRType) EmitError!ValueRef {
    _ = from;
    _ = to;
    return error.UnsupportedCast;
}

pub fn exprType(ctx: *Context, expr: *Expr) !IRType {
    switch (expr.*) {
        .identifier => |name| {
            const sym = ctx.findSymbol(name) orelse return error.UnknownSymbol;
            return ctx.typeFromKind(sym.loweredKind());
        },
        .array_constructor => |ctor| {
            if (ctor.items.len == 0) return error.UnsupportedArrayConstructor;
            return exprType(ctx, ctor.items[0]);
        },
        .literal => |lit| return switch (lit.kind) {
            .integer => ctx.defaultIntegerIRType(),
            .real => utils.realLiteralType(lit.text),
            .logical => .i1,
            .string, .hollerith => .ptr,
            else => return error.UnsupportedLiteral,
        },
        .complex_literal => |lit| {
            const real_ty = try exprType(ctx, lit.real);
            const imag_ty = try exprType(ctx, lit.imag);
            const elem_ty: IRType = if (real_ty == .f64 or imag_ty == .f64) .f64 else .f32;
            return if (elem_ty == .f64) .complex_f64 else .complex_f32;
        },
        .unary => |un| return exprType(ctx, un.expr),
        .binary => |bin| {
            if (bin.op == .concat) return .ptr;
            const left = try exprType(ctx, bin.left);
            const right = try exprType(ctx, bin.right);
            return ir.commonType(left, right);
        },
        .dim_range => return .i32,
        .substring => return .ptr,
        .component => |comp| return ctx.componentIRType(comp),
        .call_or_subscript => |call| {
            var kind = ctx.ref_kinds.get(@as(usize, @intFromPtr(expr))) orelse .unknown;
            if (kind == .unknown) {
                if (ctx.findSymbol(call.name)) |sym| {
                    if (sym.dims.len > 0) {
                        kind = .subscript;
                    } else if (sym.is_external or sym.is_intrinsic or sym.kind == .function) {
                        kind = .call;
                    }
                } else if (intrinsicCallType(ctx, call.name) != null) {
                    kind = .call;
                }
            }
            if (kind == .subscript) {
                const sym = ctx.findSymbol(call.name) orelse return error.UnknownSymbol;
                return ctx.typeFromKind(sym.loweredKind());
            }
            if (kind != .call) return error.AmbiguousCallOrSubscript;
            if (ctx.findSymbol(call.name)) |sym| {
                return ctx.typeFromKind(sym.loweredKind());
            }
            return intrinsicCallType(ctx, call.name) orelse error.UnknownSymbol;
        },
        .implied_do => return error.UnsupportedImpliedDo,
    }
}
