const std = @import("std");
const ast = @import("../../../../input.zig");
const ir = @import("../../../../ir.zig");
const common = @import("../../common.zig");
const cg_context = @import("../../context/mod.zig");
const utils = @import("../../utils.zig");

const binary = @import("../binary.zig");
const call = @import("../call/mod.zig");
const casting = @import("../casting.zig");
const intrinsics = @import("../intrinsics/mod.zig");
const memory = @import("../memory.zig");

const int_eval = @import("int_eval.zig");
const helpers = @import("character/helpers.zig");
const lengths = @import("character/lengths.zig");
const resolution = @import("resolution.zig");
const shared = @import("shared.zig");

pub const CharacterValueKind = shared.CharacterValueKind;
pub const CharacterValuePlan = shared.CharacterValuePlan;

const Expr = shared.Expr;
const Context = shared.Context;
const ValueRef = shared.ValueRef;
const EmitError = shared.EmitError;
const copyCharacterBytesConst = helpers.copyCharacterBytesConst;
const internalLiteralSubstringArgOmitted = helpers.internalLiteralSubstringArgOmitted;
const isInternalLiteralSubstringName = helpers.isInternalLiteralSubstringName;
const isRepeatIntrinsicName = helpers.isRepeatIntrinsicName;
const isTrimIntrinsicName = helpers.isTrimIntrinsicName;
const literalBytes = helpers.literalBytes;
const validateConstantSubstringBounds = helpers.validateConstantSubstringBounds;

pub fn isCharacterExpr(ctx: *Context, expr: *Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            if (common.isIsoCNullCharName(name)) break :blk true;
            const sym = ctx.findSymbol(name) orelse break :blk false;
            break :blk sym.isCharacter();
        },
        .array_constructor => |ctor| blk: {
            if (ctor.type_spec) |type_spec| {
                if (type_spec.type_kind == .character) break :blk true;
            }
            if (ctor.items.len == 0) break :blk false;
            break :blk isCharacterExpr(ctx, ctor.items[0]);
        },
        .call_or_subscript => |call_or_sub| blk: {
            if (isRepeatIntrinsicName(call_or_sub.name) and call_or_sub.args.len == 2) break :blk true;
            if (intrinsicCharacterResultSourceExpr(call_or_sub)) |source_expr| {
                break :blk isCharacterExpr(ctx, source_expr);
            }
            const sym = ctx.findSymbol(call_or_sub.name) orelse break :blk false;
            break :blk sym.isCharacter();
        },
        .substring => true,
        .literal => |lit| lit.kind == .string or lit.kind == .hollerith,
        .binary => |bin| bin.op == .concat,
        .component => |comp| characterComponentLayout(ctx, comp) != null or
            (comp.has_parens and lengths.typeBoundCharacterResultLen(ctx, comp) != null),
        .implied_do => |implied| implied.items.len != 0 and isCharacterExpr(ctx, implied.items[0]),
        else => false,
    };
}

fn intrinsicCharacterResultSourceExpr(call_or_sub: ast.CallOrSubscript) ?*Expr {
    if (call_or_sub.args.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(call_or_sub.name, "pack") or
        std.ascii.eqlIgnoreCase(call_or_sub.name, "reshape") or
        std.ascii.eqlIgnoreCase(call_or_sub.name, "cshift") or
        std.ascii.eqlIgnoreCase(call_or_sub.name, "eoshift") or
        std.ascii.eqlIgnoreCase(call_or_sub.name, "merge"))
    {
        return call_or_sub.args[0];
    }
    return null;
}

pub fn constantCharacterLenForExpr(ctx: *Context, expr: *Expr) ?usize {
    switch (expr.*) {
        .identifier => |name| {
            if (common.isIsoCNullCharName(name)) return 1;
            const sym = ctx.findSymbol(name) orelse return null;
            if (!sym.isCharacter()) return null;
            return common.constantCharacterLen(sym);
        },
        .array_constructor => |ctor| {
            if (ctor.items.len == 0) return null;
            return constantCharacterLenForExpr(ctx, ctor.items[0]);
        },
        .call_or_subscript => |call_or_sub| {
            if (isInternalLiteralSubstringName(call_or_sub.name)) {
                return internalLiteralSubstringConstLen(ctx, call_or_sub.args, null);
            }
            if (isRepeatIntrinsicName(call_or_sub.name) and call_or_sub.args.len == 2) {
                const base_len = constantCharacterLenForExpr(ctx, call_or_sub.args[0]) orelse return null;
                const repeat_count = int_eval.intLiteralValue(call_or_sub.args[1]) orelse return null;
                if (repeat_count < 0) return null;
                const repeat_usize = std.math.cast(usize, repeat_count) orelse return null;
                return std.math.mul(usize, base_len, repeat_usize) catch null;
            }
            if (intrinsicCharacterResultSourceExpr(call_or_sub)) |source_expr| {
                return constantCharacterLenForExpr(ctx, source_expr);
            }
            var kind = ctx.ref_kinds.get(@as(usize, @intFromPtr(expr))) orelse .unknown;
            const sym = ctx.findSymbol(call_or_sub.name) orelse return null;
            if (!sym.isCharacter()) return null;
            if (kind == .unknown) {
                if (sym.dims.len > 0) {
                    kind = .subscript;
                } else if (sym.is_external or sym.is_intrinsic or sym.kind == .function) {
                    kind = .call;
                }
            }
            if (kind == .subscript or kind == .call) {
                return common.constantCharacterLen(sym);
            }
            return null;
        },
        .substring => |sub| return lengths.substringLen(ctx, sub),
        .literal => |lit| switch (lit.kind) {
            .string => return utils.decodedStringLen(lit.text),
            .hollerith => {
                const bytes = utils.hollerithBytes(lit.text) orelse return null;
                return bytes.len;
            },
            else => return null,
        },
        .binary => |bin| {
            if (bin.op != .concat) return null;
            const left_len = constantCharacterLenForExpr(ctx, bin.left) orelse return null;
            const right_len = constantCharacterLenForExpr(ctx, bin.right) orelse return null;
            return left_len + right_len;
        },
        .component => |comp| {
            if (characterComponentLayout(ctx, comp)) |component| {
                if (isCharacterComponentSubstringRef(component, comp)) return componentSubstringLen(ctx, comp, component);
                return componentCharacterConstLen(component);
            }
            if (!comp.has_parens) return null;
            return lengths.typeBoundCharacterResultLen(ctx, comp);
        },
        .implied_do => |implied| {
            if (implied.items.len == 0) return null;
            return constantCharacterLenForExpr(ctx, implied.items[0]);
        },
        else => return null,
    }
}

pub fn emitCharacterLenValue(ctx: *Context, builder: anytype, expr: *Expr) EmitError!?ValueRef {
    return emitCharacterLenValueImpl(ctx, builder, expr, ctx.stmt_func_stack.items.len);
}

pub fn emitCharacterLenValueOrOne(ctx: *Context, builder: anytype, expr: *Expr) EmitError!ValueRef {
    return (try emitCharacterLenValue(ctx, builder, expr)) orelse try ctx.constI32(1);
}

pub fn emitAbiCharacterLenValue(ctx: *Context, builder: anytype, expr: *Expr) EmitError!?ValueRef {
    const len_val = (try emitCharacterLenValue(ctx, builder, expr)) orelse return null;
    const abi_len_ty = ctx.abiCharacterLenType();
    if (len_val.ty == abi_len_ty) return len_val;
    return try casting.coerce(ctx, builder, len_val, abi_len_ty);
}

pub fn emitInternalLiteralSubstringPlan(ctx: *Context, builder: anytype, args: []*Expr) EmitError!?CharacterValuePlan {
    if (args.len != 3) return error.InvalidIntrinsicCall;
    const base_plan = (try emitCharacterValuePlanImpl(ctx, builder, args[0], ctx.stmt_func_stack.items.len)) orelse return null;

    var start_val = utils.oneValue();
    if (!internalLiteralSubstringArgOmitted(args[1])) {
        start_val = try memory.emitIndex(ctx, builder, args[1]);
    }
    var end_val = base_plan.logical_len;
    if (end_val.ty != .i64) {
        end_val = try casting.coerce(ctx, builder, end_val, .i64);
    }
    if (!internalLiteralSubstringArgOmitted(args[2])) {
        end_val = try memory.emitIndex(ctx, builder, args[2]);
    }

    const offset = try binary.emitSub(ctx, builder, start_val, utils.oneValue());
    const gep = try ctx.nextTemp();
    try builder.gep(gep, .i8, base_plan.ptr, offset);
    const diff = try binary.emitSub(ctx, builder, end_val, start_val);
    const len_val = try binary.emitAdd(ctx, builder, diff, utils.oneValue());
    const const_len = internalLiteralSubstringConstLen(ctx, args, base_plan.logical_len_const);
    return try shared.validatedCharacterValuePlan(.{
        .ptr = .{ .name = gep, .ty = .ptr, .is_ptr = true },
        .logical_len = len_val,
        .storage_len = len_val,
        .logical_len_const = const_len,
        .storage_len_const = const_len,
        .kind = .substring_view,
    });
}

pub fn emitCharacterValuePlan(ctx: *Context, builder: anytype, expr: *Expr) EmitError!?CharacterValuePlan {
    if (try emitCharacterValuePlanImpl(ctx, builder, expr, ctx.stmt_func_stack.items.len)) |plan| {
        return try shared.validatedCharacterValuePlan(plan);
    }
    return null;
}

pub fn emitCharacterSymbolLenValue(ctx: *Context, name: []const u8, sym: ast.sema.Symbol) !ValueRef {
    if (sym.effectiveCharLenKind() == .constant or sym.effectiveCharLenKind() == .none) {
        if (common.constantCharacterLen(sym)) |char_len| {
            return try ctx.constI32(@intCast(char_len));
        }
    }
    if (sym.effectiveCharLen()) |char_len| {
        return try ctx.constI32(@intCast(char_len));
    }
    if (ctx.char_arg_lens.get(name)) |len_val| return len_val;
    return try ctx.constI32(1);
}

pub fn emitCharacterSymbolLenValueI64(ctx: *Context, builder: anytype, name: []const u8, sym: ast.sema.Symbol) !ValueRef {
    const len_val = try emitCharacterSymbolLenValue(ctx, name, sym);
    if (len_val.ty == .i64) return len_val;
    if (!len_val.is_ptr and len_val.ty == .i32) {
        if (std.fmt.parseInt(i64, len_val.name, 10) catch null) |const_len| {
            return .{ .name = try ctx.intLiteral(const_len), .ty = .i64, .is_ptr = false };
        }
    }
    return casting.coerce(ctx, builder, len_val, .i64);
}

pub fn emitCharacterValuePlanImpl(
    ctx: *Context,
    builder: anytype,
    expr: *Expr,
    subst_depth: usize,
) EmitError!?CharacterValuePlan {
    const prev_source = ctx.current_source;
    ctx.setCurrentSource(ctx.sourceForExpr(expr));
    defer ctx.setCurrentSource(prev_source);
    switch (expr.*) {
        .identifier => |name| {
            if (subst_depth > 0) {
                var depth = subst_depth;
                while (depth > 0) {
                    depth -= 1;
                    const subst = ctx.stmt_func_stack.items[depth];
                    if (shared.findParamIndex(subst.params, name)) |idx| {
                        return emitCharacterValuePlanImpl(ctx, builder, subst.actuals[idx], depth);
                    }
                }
            }
            if (common.isIsoCNullCharName(name)) {
                const buf_name = try ctx.nextTemp();
                try builder.alloca(buf_name, .i8);
                const buf_ptr = ValueRef{ .name = buf_name, .ty = .ptr, .is_ptr = true };
                try builder.store(.{ .name = "0", .ty = .i8, .is_ptr = false }, buf_ptr);
                const len_val = try ctx.constI32(1);
                return try shared.validatedCharacterValuePlan(.{
                    .ptr = buf_ptr,
                    .logical_len = len_val,
                    .storage_len = len_val,
                    .logical_len_const = 1,
                    .storage_len_const = 1,
                    .kind = .literal_temp,
                });
            }
            const sym = ctx.findSymbol(name) orelse return null;
            if (!sym.isCharacter()) return null;
            if (sym.kind == .parameter) {
                if (sym.const_value) |cv| {
                    if (cv == .string) {
                        const bytes = cv.string;
                        const buf_name = try ctx.nextTemp();
                        if (bytes.len <= 1) {
                            try builder.alloca(buf_name, .i8);
                        } else {
                            try builder.allocaArray(buf_name, .i8, bytes.len);
                        }
                        const buf_ptr = ValueRef{ .name = buf_name, .ty = .ptr, .is_ptr = true };
                        try copyCharacterBytesConst(ctx, builder, buf_ptr, bytes, 0);
                        const len_val = try ctx.constI32(@intCast(bytes.len));
                        return try shared.validatedCharacterValuePlan(.{
                            .ptr = buf_ptr,
                            .logical_len = len_val,
                            .storage_len = len_val,
                            .logical_len_const = bytes.len,
                            .storage_len_const = bytes.len,
                            .kind = .literal_temp,
                        });
                    }
                }
            }
            const len_val = try emitCharacterSymbolLenValue(ctx, name, sym);
            return try shared.validatedCharacterValuePlan(.{
                .ptr = try ctx.getPointer(name),
                .logical_len = len_val,
                .storage_len = len_val,
                .logical_len_const = common.constantCharacterLen(sym),
                .storage_len_const = common.constantCharacterLen(sym),
                .kind = .direct_symbol,
            });
        },
        .call_or_subscript => |call_or_sub| {
            if (isInternalLiteralSubstringName(call_or_sub.name)) {
                return emitInternalLiteralSubstringPlan(ctx, builder, call_or_sub.args);
            }
            if (isRepeatIntrinsicName(call_or_sub.name) and call_or_sub.args.len == 2) {
                return emitRepeatCharacterPlan(ctx, builder, call_or_sub.args[0], call_or_sub.args[1], subst_depth);
            }
            if (isTrimIntrinsicName(call_or_sub.name) and call_or_sub.args.len == 1) {
                const base_plan = (try emitCharacterValuePlanImpl(ctx, builder, call_or_sub.args[0], subst_depth)) orelse return null;
                return try emitTrimmedCharacterPlan(ctx, builder, base_plan);
            }
            if (std.ascii.eqlIgnoreCase(call_or_sub.name, "transfer") and
                call_or_sub.args.len == 2 and
                isCharacterExpr(ctx, call_or_sub.args[1]))
            {
                const ptr = try intrinsics.emitIntrinsicCall(ctx, builder, call_or_sub.name, call_or_sub.args);
                const len_val = (try emitCharacterLenValueImpl(ctx, builder, call_or_sub.args[1], subst_depth)) orelse return null;
                const const_len = constantCharacterLenForExpr(ctx, call_or_sub.args[1]);
                return try shared.validatedCharacterValuePlan(.{
                    .ptr = .{ .name = ptr.name, .ty = .ptr, .is_ptr = true },
                    .logical_len = len_val,
                    .storage_len = len_val,
                    .logical_len_const = const_len,
                    .storage_len_const = const_len,
                    .kind = .function_result,
                });
            }
            const sym = ctx.findSymbol(call_or_sub.name) orelse return null;
            if (sym.is_intrinsic) {
                if (intrinsicCharacterResultSourceExpr(call_or_sub)) |source_expr| {
                    if (!isCharacterExpr(ctx, source_expr)) return null;
                    const ptr = try intrinsics.emitIntrinsicCall(ctx, builder, call_or_sub.name, call_or_sub.args);
                    const len_val = (try emitCharacterLenValueImpl(ctx, builder, source_expr, subst_depth)) orelse return null;
                    const const_len = constantCharacterLenForExpr(ctx, source_expr);
                    return try shared.validatedCharacterValuePlan(.{
                        .ptr = .{ .name = ptr.name, .ty = .ptr, .is_ptr = true },
                        .logical_len = len_val,
                        .storage_len = len_val,
                        .logical_len_const = const_len,
                        .storage_len_const = const_len,
                        .kind = .function_result,
                    });
                }
            }
            if (!sym.isCharacter()) return null;
            var kind = ctx.ref_kinds.get(@as(usize, @intFromPtr(expr))) orelse .unknown;
            if (kind == .unknown) {
                if (sym.dims.len > 0) {
                    kind = .subscript;
                } else if (sym.is_external or sym.is_intrinsic or sym.kind == .function) {
                    kind = .call;
                }
            }
            switch (kind) {
                .subscript => {
                    const len_val = try emitCharacterSymbolLenValue(ctx, call_or_sub.name, sym);
                    return try shared.validatedCharacterValuePlan(.{
                        .ptr = try memory.emitSubscriptPtr(ctx, builder, call_or_sub),
                        .logical_len = len_val,
                        .storage_len = len_val,
                        .logical_len_const = common.constantCharacterLen(sym),
                        .storage_len_const = common.constantCharacterLen(sym),
                        .kind = .direct_symbol,
                    });
                },
                .call => {
                    if (sym.is_intrinsic and sym.isCharacter()) {
                        const ptr = try intrinsics.emitIntrinsicCall(ctx, builder, call_or_sub.name, call_or_sub.args);
                        const len_val = try ctx.constI32(1);
                        return try shared.validatedCharacterValuePlan(.{
                            .ptr = .{ .name = ptr.name, .ty = .ptr, .is_ptr = true },
                            .logical_len = len_val,
                            .storage_len = len_val,
                            .logical_len_const = 1,
                            .storage_len_const = 1,
                            .kind = .function_result,
                        });
                    }
                    if (!(sym.kind == .function and sym.isCharacter())) return null;
                    const result_len = common.constantCharacterLen(sym) orelse common.symbolCharacterLenOrOne(sym);
                    const ptr = if (sym.storage == .dummy)
                        try call.emitIndirectCharacterCall(ctx, builder, try ctx.getPointer(call_or_sub.name), result_len, call_or_sub.args)
                    else blk: {
                        const fn_name = try resolution.ensureExternalDeclForCall(ctx, call_or_sub.name, .void, call_or_sub.args, true);
                        break :blk try call.emitCharacterCall(ctx, builder, fn_name, result_len, call_or_sub.args);
                    };
                    const len_val = try ctx.constI32(@intCast(result_len));
                    return try shared.validatedCharacterValuePlan(.{
                        .ptr = .{ .name = ptr.name, .ty = .ptr, .is_ptr = true },
                        .logical_len = len_val,
                        .storage_len = len_val,
                        .logical_len_const = result_len,
                        .storage_len_const = result_len,
                        .kind = .function_result,
                    });
                },
                else => return null,
            }
        },
        .substring => |sub| {
            try validateConstantSubstringBounds(ctx, sub);
            const sym = ctx.findSymbol(sub.name) orelse return null;
            if (!sym.isCharacter()) return null;
            const base_ptr = if (sub.args.len > 0)
                try memory.emitSubscriptPtr(ctx, builder, .{ .name = sub.name, .args = sub.args })
            else
                try ctx.getPointer(sub.name);
            var start_val = utils.oneValue();
            if (sub.start) |start_expr| {
                start_val = try memory.emitIndex(ctx, builder, start_expr);
            }
            var end_val = try emitCharacterSymbolLenValue(ctx, sub.name, sym);
            if (sub.end) |end_expr| {
                end_val = try memory.emitIndex(ctx, builder, end_expr);
            }
            const offset = try binary.emitSub(ctx, builder, start_val, utils.oneValue());
            const gep = try ctx.nextTemp();
            try builder.gep(gep, .i8, base_ptr, offset);
            const diff = try binary.emitSub(ctx, builder, end_val, start_val);
            const len_val = try binary.emitAdd(ctx, builder, diff, utils.oneValue());
            const const_len = lengths.substringLen(ctx, sub);
            return try shared.validatedCharacterValuePlan(.{
                .ptr = .{ .name = gep, .ty = .ptr, .is_ptr = true },
                .logical_len = len_val,
                .storage_len = len_val,
                .logical_len_const = const_len,
                .storage_len_const = const_len,
                .kind = .substring_view,
            });
        },
        .literal => |lit| {
            const bytes = switch (lit.kind) {
                .string, .hollerith => try literalBytes(ctx.allocator, lit),
                else => return null,
            };
            const buf_name = try ctx.nextTemp();
            if (bytes.len <= 1) {
                try builder.alloca(buf_name, .i8);
            } else {
                try builder.allocaArray(buf_name, .i8, bytes.len);
            }
            const buf_ptr = ValueRef{ .name = buf_name, .ty = .ptr, .is_ptr = true };
            try copyCharacterBytesConst(ctx, builder, buf_ptr, bytes, 0);
            const len_val = try ctx.constI32(@intCast(bytes.len));
            return try shared.validatedCharacterValuePlan(.{
                .ptr = buf_ptr,
                .logical_len = len_val,
                .storage_len = len_val,
                .logical_len_const = bytes.len,
                .storage_len_const = bytes.len,
                .kind = .literal_temp,
            });
        },
        .binary => |bin| {
            if (bin.op != .concat) return null;
            const left = (try emitCharacterValuePlanImpl(ctx, builder, bin.left, subst_depth)) orelse return null;
            const right = (try emitCharacterValuePlanImpl(ctx, builder, bin.right, subst_depth)) orelse return null;
            const left_len = try coerceCharacterLenToI32(ctx, builder, left.logical_len);
            const right_len = try coerceCharacterLenToI32(ctx, builder, right.logical_len);
            const total_len = try binary.emitAdd(ctx, builder, left_len, right_len);
            const buf_name = try ctx.nextTemp();
            try builder.allocaArrayValue(buf_name, .i8, total_len);
            const buf_ptr = ValueRef{ .name = buf_name, .ty = .ptr, .is_ptr = true };
            try copyCharacterBytesFromPlanDynamic(ctx, builder, buf_ptr, utils.zeroValue(.i32), left);
            try copyCharacterBytesFromPlanDynamic(ctx, builder, buf_ptr, left_len, right);
            const total_len_const = if (left.logical_len_const != null and right.logical_len_const != null)
                left.logical_len_const.? + right.logical_len_const.?
            else
                null;
            return try shared.validatedCharacterValuePlan(.{
                .ptr = buf_ptr,
                .logical_len = total_len,
                .storage_len = total_len,
                .logical_len_const = total_len_const,
                .storage_len_const = total_len_const,
                .kind = .concat_temp,
            });
        },
        .component => |comp| {
            if (characterComponentLayout(ctx, comp)) |component| {
                return try emitCharacterComponentPlan(ctx, builder, comp, component);
            }
            if (!comp.has_parens) return null;
            const info = lengths.typeBoundCharacterResultInfo(ctx, comp) orelse return null;
            const actuals = try resolution.buildTypeBoundProcedureActuals(ctx, comp, info.binding);
            defer ctx.allocator.free(actuals);
            const fn_name = try resolution.ensureExternalDeclForResolvedCall(ctx, info.lookup_name, info.ir_name, .void, actuals, true);
            const ptr = try call.emitCharacterCall(ctx, builder, fn_name, info.result_len, actuals);
            const len_val = try ctx.constI32(@intCast(info.result_len));
            return try shared.validatedCharacterValuePlan(.{
                .ptr = .{ .name = ptr.name, .ty = .ptr, .is_ptr = true },
                .logical_len = len_val,
                .storage_len = len_val,
                .logical_len_const = info.result_len,
                .storage_len_const = info.result_len,
                .kind = .function_result,
            });
        },
        else => return null,
    }
}

pub fn copyCharacterBytesFromPlan(
    ctx: *Context,
    builder: anytype,
    dst_ptr: ValueRef,
    src: CharacterValuePlan,
    dst_offset: usize,
) EmitError!void {
    try src.validate();
    const len = src.logical_len_const orelse return error.UnsupportedConcat;
    var idx: usize = 0;
    while (idx < len) : (idx += 1) {
        const src_off = try ctx.constI32(@intCast(idx));
        const src_gep = try ctx.nextTemp();
        try builder.gep(src_gep, .i8, src.ptr, src_off);
        const tmp = try ctx.nextTemp();
        try builder.load(tmp, .i8, .{ .name = src_gep, .ty = .ptr, .is_ptr = true });

        const dst_idx = dst_offset + idx;
        const dst_off = try ctx.constI32(@intCast(dst_idx));
        const dst_gep = try ctx.nextTemp();
        try builder.gep(dst_gep, .i8, dst_ptr, dst_off);
        try builder.store(.{ .name = tmp, .ty = .i8, .is_ptr = false }, .{ .name = dst_gep, .ty = .ptr, .is_ptr = true });
    }
}

fn copyCharacterBytesFromPlanDynamic(
    ctx: *Context,
    builder: anytype,
    dst_ptr: ValueRef,
    dst_offset: ValueRef,
    src: CharacterValuePlan,
) EmitError!void {
    try src.validate();
    const offset_i32 = try coerceCharacterLenToI32(ctx, builder, dst_offset);
    const src_len_i32 = try coerceCharacterLenToI32(ctx, builder, src.logical_len);

    const idx_ptr = try ctx.nextTemp();
    try builder.alloca(idx_ptr, .i32);
    try builder.store(utils.zeroValue(.i32), .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });

    const loop_cond = try ctx.nextLabel("char_copy_cond");
    const loop_body = try ctx.nextLabel("char_copy_body");
    const loop_inc = try ctx.nextLabel("char_copy_inc");
    const loop_end = try ctx.nextLabel("char_copy_end");

    try builder.br(loop_cond);

    try builder.label(loop_cond);
    const idx_val_tmp = try ctx.nextTemp();
    try builder.load(idx_val_tmp, .i32, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    const idx_val = ValueRef{ .name = idx_val_tmp, .ty = .i32, .is_ptr = false };
    const cmp_tmp = try ctx.nextTemp();
    try builder.compare(cmp_tmp, "icmp", "slt", .i32, idx_val, src_len_i32);
    try builder.brCond(.{ .name = cmp_tmp, .ty = .i1, .is_ptr = false }, loop_body, loop_end);

    try builder.label(loop_body);
    const src_gep = try ctx.nextTemp();
    try builder.gep(src_gep, .i8, src.ptr, idx_val);
    const src_tmp = try ctx.nextTemp();
    try builder.load(src_tmp, .i8, .{ .name = src_gep, .ty = .ptr, .is_ptr = true });
    const dst_idx = try binary.emitAdd(ctx, builder, offset_i32, idx_val);
    const dst_gep = try ctx.nextTemp();
    try builder.gep(dst_gep, .i8, dst_ptr, dst_idx);
    try builder.store(.{ .name = src_tmp, .ty = .i8, .is_ptr = false }, .{ .name = dst_gep, .ty = .ptr, .is_ptr = true });
    try builder.br(loop_inc);

    try builder.label(loop_inc);
    const next_tmp = try ctx.nextTemp();
    try builder.binary(next_tmp, "add", .i32, idx_val, utils.oneValue());
    try builder.store(.{ .name = next_tmp, .ty = .i32, .is_ptr = false }, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    try builder.br(loop_cond);

    try builder.label(loop_end);
}

pub fn emitCharCompare(
    ctx: *Context,
    builder: anytype,
    op: ast.BinaryOp,
    lhs: CharacterValuePlan,
    rhs: CharacterValuePlan,
) EmitError!ValueRef {
    try lhs.validate();
    try rhs.validate();
    const compare_name = try ctx.ensureDeclRaw("col6forge_char_compare", .i32, &[_]ir.IRType{ .ptr, .i32, .ptr, .i32 }, false);
    const lhs_len = try coerceCharacterLenToI32(ctx, builder, lhs.logical_len);
    const rhs_len = try coerceCharacterLenToI32(ctx, builder, rhs.logical_len);
    const cmp_tmp = try ctx.nextTemp();
    try builder.callTyped(cmp_tmp, .i32, compare_name, &.{ lhs.ptr, lhs_len, rhs.ptr, rhs_len });
    const cmp_val = ValueRef{ .name = cmp_tmp, .ty = .i32, .is_ptr = false };
    const zero = ValueRef{ .name = "0", .ty = .i32, .is_ptr = false };

    const pred: []const u8 = switch (op) {
        .eq => "eq",
        .ne => "ne",
        .lt => "slt",
        .le => "sle",
        .gt => "sgt",
        .ge => "sge",
        else => return error.UnsupportedLogicalOp,
    };
    const result_tmp = try ctx.nextTemp();
    try builder.compare(result_tmp, "icmp", pred, .i32, cmp_val, zero);
    return .{ .name = result_tmp, .ty = .i1, .is_ptr = false };
}

fn emitCharacterLenValueImpl(ctx: *Context, builder: anytype, expr: *Expr, subst_depth: usize) EmitError!?ValueRef {
    switch (expr.*) {
        .identifier => |name| {
            if (subst_depth > 0) {
                var depth = subst_depth;
                while (depth > 0) {
                    depth -= 1;
                    const subst = ctx.stmt_func_stack.items[depth];
                    if (shared.findParamIndex(subst.params, name)) |idx| {
                        return emitCharacterLenValueImpl(ctx, builder, subst.actuals[idx], depth);
                    }
                }
            }
            const sym = ctx.findSymbol(name) orelse return null;
            if (!sym.isCharacter()) return null;
            return try emitCharacterSymbolLenValue(ctx, name, sym);
        },
        .array_constructor => |ctor| {
            if (ctor.items.len == 0) return null;
            return emitCharacterLenValueImpl(ctx, builder, ctor.items[0], subst_depth);
        },
        .call_or_subscript => |call_or_sub| {
            if (isInternalLiteralSubstringName(call_or_sub.name)) {
                const plan = (try emitInternalLiteralSubstringPlan(ctx, builder, call_or_sub.args)) orelse return null;
                return plan.logical_len;
            }
            if (isRepeatIntrinsicName(call_or_sub.name) and call_or_sub.args.len == 2) {
                const plan = (try emitRepeatCharacterPlan(ctx, builder, call_or_sub.args[0], call_or_sub.args[1], subst_depth)) orelse return null;
                return plan.logical_len;
            }
            if (isTrimIntrinsicName(call_or_sub.name) and call_or_sub.args.len == 1) {
                const base_plan = (try emitCharacterValuePlanImpl(ctx, builder, call_or_sub.args[0], subst_depth)) orelse return null;
                const trimmed = try emitTrimmedCharacterPlan(ctx, builder, base_plan);
                return trimmed.logical_len;
            }
            if (std.ascii.eqlIgnoreCase(call_or_sub.name, "transfer") and
                call_or_sub.args.len == 2 and
                isCharacterExpr(ctx, call_or_sub.args[1]))
            {
                return emitCharacterLenValueImpl(ctx, builder, call_or_sub.args[1], subst_depth);
            }
            if (intrinsicCharacterResultSourceExpr(call_or_sub)) |source_expr| {
                return emitCharacterLenValueImpl(ctx, builder, source_expr, subst_depth);
            }
            const sym = ctx.findSymbol(call_or_sub.name) orelse return null;
            if (!sym.isCharacter()) return null;
            var kind = ctx.ref_kinds.get(@as(usize, @intFromPtr(expr))) orelse .unknown;
            if (kind == .unknown) {
                if (sym.dims.len > 0) {
                    kind = .subscript;
                } else if (sym.is_external or sym.is_intrinsic or sym.kind == .function) {
                    kind = .call;
                }
            }
            return switch (kind) {
                .subscript, .call => try emitCharacterSymbolLenValue(ctx, call_or_sub.name, sym),
                else => null,
            };
        },
        .substring => |sub| {
            try validateConstantSubstringBounds(ctx, sub);
            const sym = ctx.findSymbol(sub.name) orelse return null;
            if (!sym.isCharacter()) return null;
            var end_val = try emitCharacterSymbolLenValue(ctx, sub.name, sym);
            if (sub.end) |end_expr| {
                end_val = try memory.emitIndex(ctx, builder, end_expr);
            }
            var start_val = utils.oneValue();
            if (sub.start) |start_expr| {
                start_val = try memory.emitIndex(ctx, builder, start_expr);
            }
            const diff = try binary.emitSub(ctx, builder, end_val, start_val);
            return try binary.emitAdd(ctx, builder, diff, utils.oneValue());
        },
        .literal => |lit| switch (lit.kind) {
            .string => return try ctx.constI32(@intCast(utils.decodedStringLen(lit.text))),
            .hollerith => {
                const bytes = utils.hollerithBytes(lit.text) orelse return null;
                return try ctx.constI32(@intCast(bytes.len));
            },
            else => return null,
        },
        .binary => |bin| {
            if (bin.op != .concat) return null;
            const left_len = try emitCharacterLenValueImpl(ctx, builder, bin.left, subst_depth) orelse return null;
            const right_len = try emitCharacterLenValueImpl(ctx, builder, bin.right, subst_depth) orelse return null;
            return try binary.emitAdd(ctx, builder, left_len, right_len);
        },
        .component => |comp| {
            if (characterComponentLayout(ctx, comp)) |component| {
                return emitCharacterComponentLenValue(ctx, builder, comp, component);
            }
            if (!comp.has_parens) return null;
            const result_len = lengths.typeBoundCharacterResultLen(ctx, comp) orelse return null;
            return try ctx.constI32(@intCast(result_len));
        },
        .implied_do => |implied| {
            if (implied.items.len == 0) return null;
            return emitCharacterLenValueImpl(ctx, builder, implied.items[0], subst_depth);
        },
        else => return null,
    }
}

fn coerceCharacterLenToI32(ctx: *Context, builder: anytype, len_val: ValueRef) EmitError!ValueRef {
    if (len_val.ty == .i32) return len_val;
    return casting.coerceCheckedI32(ctx, builder, len_val);
}

fn characterComponentLayout(ctx: *Context, comp: ast.ComponentExpr) ?cg_context.DerivedComponentLayout {
    const base_type_name = ctx.derivedTypeNameForExpr(comp.base) orelse return null;
    const component = ctx.lookupDerivedComponentLayout(base_type_name, comp.name) orelse return null;
    if (component.procedure) return null;
    if (component.type_spec.lowered_kind != .character) return null;
    return component;
}

fn componentCharacterConstLen(component: cg_context.DerivedComponentLayout) ?usize {
    return component.type_spec.char_len;
}

fn isCharacterComponentSubstringRef(component: cg_context.DerivedComponentLayout, comp: ast.ComponentExpr) bool {
    if (!comp.has_parens) return false;
    if (comp.args.len != component.dims.len + 1) return false;
    return comp.args[comp.args.len - 1].* == .dim_range;
}

fn emitCharacterComponentPlan(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    component: cg_context.DerivedComponentLayout,
) EmitError!CharacterValuePlan {
    const ptr = try memory.emitComponentPtr(ctx, builder, comp);
    const len_val = try emitCharacterComponentLenValue(ctx, builder, comp, component) orelse return error.NonConstantCharacterLength;
    const const_len = if (isCharacterComponentSubstringRef(component, comp))
        componentSubstringLen(ctx, comp, component)
    else
        componentCharacterConstLen(component);
    return try shared.validatedCharacterValuePlan(.{
        .ptr = ptr,
        .logical_len = len_val,
        .storage_len = len_val,
        .logical_len_const = const_len,
        .storage_len_const = const_len,
        .kind = if (isCharacterComponentSubstringRef(component, comp)) .substring_view else .direct_symbol,
    });
}

fn emitCharacterComponentLenValue(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    component: cg_context.DerivedComponentLayout,
) EmitError!?ValueRef {
    const base_len_val = if (componentCharacterConstLen(component)) |const_len|
        try ctx.constI32(@intCast(const_len))
    else if (component.pointer or component.allocatable) blk: {
        const len_slot = try memory.emitComponentCharacterLenPtr(ctx, builder, comp);
        const len_name = try ctx.nextTemp();
        try builder.load(len_name, .i64, len_slot);
        var len_val = ValueRef{ .name = len_name, .ty = .i64, .is_ptr = false };
        if (len_val.ty != .i32) len_val = try coerceCharacterLenToI32(ctx, builder, len_val);
        break :blk len_val;
    } else null;

    if (!isCharacterComponentSubstringRef(component, comp)) {
        return base_len_val;
    }
    const range = comp.args[comp.args.len - 1].dim_range;
    var end_val = base_len_val orelse return null;
    if (!(range.upper.* == .literal and range.upper.literal.kind == .assumed_size)) {
        end_val = try coerceCharacterLenToI32(ctx, builder, try memory.emitIndex(ctx, builder, range.upper));
    }
    var start_val = try ctx.constI32(1);
    if (range.lower) |lower| {
        start_val = try coerceCharacterLenToI32(ctx, builder, try memory.emitIndex(ctx, builder, lower));
    }
    const diff = try binary.emitSub(ctx, builder, end_val, start_val);
    return try binary.emitAdd(ctx, builder, diff, utils.oneValue());
}

fn componentSubstringLen(
    ctx: *Context,
    comp: ast.ComponentExpr,
    component: cg_context.DerivedComponentLayout,
) ?usize {
    _ = ctx;
    if (!isCharacterComponentSubstringRef(component, comp)) return componentCharacterConstLen(component);
    const base_len_usize = componentCharacterConstLen(component) orelse return null;
    const base_len = std.math.cast(i64, base_len_usize) orelse return null;
    const range = comp.args[comp.args.len - 1].dim_range;
    const start_val = if (range.lower) |start_expr| int_eval.intLiteralValue(start_expr) orelse return null else 1;
    const end_val = if (range.upper.* == .literal and range.upper.literal.kind == .assumed_size)
        base_len
    else
        int_eval.intLiteralValue(range.upper) orelse return null;
    const span = int_eval.checkedSub(end_val, start_val) orelse return null;
    const length = int_eval.checkedAdd(span, 1) orelse return null;
    if (length <= 0) return null;
    return std.math.cast(usize, length);
}

fn emitRepeatCharacterPlan(
    ctx: *Context,
    builder: anytype,
    value_expr: *Expr,
    count_expr: *Expr,
    subst_depth: usize,
) EmitError!?CharacterValuePlan {
    const base_plan = (try emitCharacterValuePlanImpl(ctx, builder, value_expr, subst_depth)) orelse return null;
    const base_len_i32 = try coerceCharacterLenToI32(ctx, builder, base_plan.logical_len);
    var count_i32 = try coerceCharacterLenToI32(ctx, builder, try memory.emitIndex(ctx, builder, count_expr));
    const zero_i32 = utils.zeroValue(.i32);
    const neg_tmp = try ctx.nextTemp();
    try builder.compare(neg_tmp, "icmp", "slt", .i32, count_i32, zero_i32);
    const clamped_tmp = try ctx.nextTemp();
    try builder.select(clamped_tmp, .i32, .{ .name = neg_tmp, .ty = .i1, .is_ptr = false }, zero_i32, count_i32);
    count_i32 = .{ .name = clamped_tmp, .ty = .i32, .is_ptr = false };

    const total_len = try binary.emitMul(ctx, builder, base_len_i32, count_i32);
    const buf_name = try ctx.nextTemp();
    try builder.allocaArrayValue(buf_name, .i8, total_len);
    const buf_ptr = ValueRef{ .name = buf_name, .ty = .ptr, .is_ptr = true };

    const idx_ptr = try ctx.nextTemp();
    try builder.alloca(idx_ptr, .i32);
    try builder.store(zero_i32, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });

    const loop_cond = try ctx.nextLabel("repeat_cond");
    const loop_body = try ctx.nextLabel("repeat_body");
    const loop_inc = try ctx.nextLabel("repeat_inc");
    const loop_end = try ctx.nextLabel("repeat_end");

    try builder.br(loop_cond);

    try builder.label(loop_cond);
    const idx_tmp = try ctx.nextTemp();
    try builder.load(idx_tmp, .i32, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    const idx_val = ValueRef{ .name = idx_tmp, .ty = .i32, .is_ptr = false };
    const cmp_tmp = try ctx.nextTemp();
    try builder.compare(cmp_tmp, "icmp", "slt", .i32, idx_val, total_len);
    try builder.brCond(.{ .name = cmp_tmp, .ty = .i1, .is_ptr = false }, loop_body, loop_end);

    try builder.label(loop_body);
    const src_idx = if (base_plan.logical_len_const == 1)
        zero_i32
    else blk: {
        const rem_tmp = try ctx.nextTemp();
        try builder.binary(rem_tmp, "srem", .i32, idx_val, base_len_i32);
        break :blk ValueRef{ .name = rem_tmp, .ty = .i32, .is_ptr = false };
    };
    const src_gep = try ctx.nextTemp();
    try builder.gep(src_gep, .i8, base_plan.ptr, src_idx);
    const src_tmp = try ctx.nextTemp();
    try builder.load(src_tmp, .i8, .{ .name = src_gep, .ty = .ptr, .is_ptr = true });
    const dst_gep = try ctx.nextTemp();
    try builder.gep(dst_gep, .i8, buf_ptr, idx_val);
    try builder.store(.{ .name = src_tmp, .ty = .i8, .is_ptr = false }, .{ .name = dst_gep, .ty = .ptr, .is_ptr = true });
    try builder.br(loop_inc);

    try builder.label(loop_inc);
    const next_tmp = try ctx.nextTemp();
    try builder.binary(next_tmp, "add", .i32, idx_val, utils.oneValue());
    try builder.store(.{ .name = next_tmp, .ty = .i32, .is_ptr = false }, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    try builder.br(loop_cond);

    try builder.label(loop_end);

    const total_len_const = blk: {
        const base_const = base_plan.logical_len_const orelse break :blk null;
        const repeat_const = int_eval.intLiteralValue(count_expr) orelse break :blk null;
        if (repeat_const < 0) break :blk 0;
        const repeat_usize = std.math.cast(usize, repeat_const) orelse break :blk null;
        break :blk std.math.mul(usize, base_const, repeat_usize) catch null;
    };

    return try shared.validatedCharacterValuePlan(.{
        .ptr = buf_ptr,
        .logical_len = total_len,
        .storage_len = total_len,
        .logical_len_const = total_len_const,
        .storage_len_const = total_len_const,
        .kind = .concat_temp,
    });
}

fn emitTrimmedCharacterPlan(
    ctx: *Context,
    builder: anytype,
    base_plan: CharacterValuePlan,
) EmitError!CharacterValuePlan {
    try base_plan.validate();
    const base_len = try coerceCharacterLenToI32(ctx, builder, base_plan.logical_len);

    const idx_ptr = try ctx.nextTemp();
    try builder.alloca(idx_ptr, .i32);
    try builder.store(base_len, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });

    const loop_cond = try ctx.nextLabel("trim_len_cond");
    const loop_body = try ctx.nextLabel("trim_len_body");
    const char_check = try ctx.nextLabel("trim_len_check");
    const loop_end = try ctx.nextLabel("trim_len_end");

    try builder.br(loop_cond);

    try builder.label(loop_cond);
    const idx_val_tmp = try ctx.nextTemp();
    try builder.load(idx_val_tmp, .i32, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    const idx_val = ValueRef{ .name = idx_val_tmp, .ty = .i32, .is_ptr = false };
    const has_chars_tmp = try ctx.nextTemp();
    try builder.compare(has_chars_tmp, "icmp", "sgt", .i32, idx_val, utils.zeroValue(.i32));
    try builder.brCond(.{ .name = has_chars_tmp, .ty = .i1, .is_ptr = false }, loop_body, loop_end);

    try builder.label(loop_body);
    const prev_idx = try binary.emitSub(ctx, builder, idx_val, utils.oneValue());
    const char_gep = try ctx.nextTemp();
    try builder.gep(char_gep, .i8, base_plan.ptr, prev_idx);
    const char_tmp = try ctx.nextTemp();
    try builder.load(char_tmp, .i8, .{ .name = char_gep, .ty = .ptr, .is_ptr = true });
    const ch = ValueRef{ .name = char_tmp, .ty = .i8, .is_ptr = false };
    const blank = ValueRef{ .name = try ctx.intLiteral(32), .ty = .i8, .is_ptr = false };
    const is_blank_tmp = try ctx.nextTemp();
    try builder.compare(is_blank_tmp, "icmp", "eq", .i8, ch, blank);
    try builder.brCond(.{ .name = is_blank_tmp, .ty = .i1, .is_ptr = false }, char_check, loop_end);

    try builder.label(char_check);
    try builder.store(prev_idx, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    try builder.br(loop_cond);

    try builder.label(loop_end);
    const result_tmp = try ctx.nextTemp();
    try builder.load(result_tmp, .i32, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    const result_len = ValueRef{ .name = result_tmp, .ty = .i32, .is_ptr = false };

    return try shared.validatedCharacterValuePlan(.{
        .ptr = base_plan.ptr,
        .logical_len = result_len,
        .storage_len = base_plan.storage_len,
        .logical_len_const = null,
        .storage_len_const = base_plan.storage_len_const,
        .kind = .substring_view,
    });
}

fn internalLiteralSubstringConstLen(ctx: *Context, args: []*Expr, base_len_override: ?usize) ?usize {
    if (args.len != 3) return null;
    const base_len = if (base_len_override) |len|
        len
    else
        constantCharacterLenForExpr(ctx, args[0]) orelse return null;
    const base_len_i64 = std.math.cast(i64, base_len) orelse return null;
    const start_val = if (internalLiteralSubstringArgOmitted(args[1])) 1 else int_eval.intLiteralValue(args[1]) orelse return null;
    const end_val = if (internalLiteralSubstringArgOmitted(args[2])) base_len_i64 else int_eval.intLiteralValue(args[2]) orelse return null;
    const span = int_eval.checkedSub(end_val, start_val) orelse return null;
    const length = int_eval.checkedAdd(span, 1) orelse return null;
    if (length <= 0) return null;
    return std.math.cast(usize, length);
}
