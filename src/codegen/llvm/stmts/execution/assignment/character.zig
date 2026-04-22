const std = @import("std");
const ast = @import("../../../../input.zig");
const context = @import("../../../codegen/context/mod.zig");
const expr = @import("../../../codegen/expression/mod.zig");
const expr_dispatch = @import("../../../codegen/expression/dispatch/mod.zig");
const utils = @import("../../../codegen/utils.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

pub fn evalCharConst(ctx: *Context, value: *ast.Expr, target_len: usize) !?[]const u8 {
    const raw = try evalCharExprRaw(ctx, value) orelse return null;
    var padded = try ctx.allocator.alloc(u8, target_len);
    @memset(padded, ' ');
    const copy_len = @min(raw.len, target_len);
    @memcpy(padded[0..copy_len], raw[0..copy_len]);
    return padded;
}

fn evalCharExprRaw(ctx: *Context, value: *ast.Expr) !?[]const u8 {
    switch (value.*) {
        .literal => |lit| {
            return switch (lit.kind) {
                .string => utils.decodeStringLiteral(ctx.allocator, lit.text) catch null,
                .hollerith => utils.hollerithBytes(lit.text),
                else => null,
            };
        },
        .identifier => |name| {
            if (ctx.char_values.get(name)) |val| return val;
            return null;
        },
        .binary => |bin| {
            if (bin.op != .concat) return null;
            const left = try evalCharExprRaw(ctx, bin.left) orelse return null;
            const right = try evalCharExprRaw(ctx, bin.right) orelse return null;
            const joined = try std.mem.concat(ctx.allocator, u8, &.{ left, right });
            return joined;
        },
        .call_or_subscript => |call| {
            if (call.args.len != 1) return null;
            const idx_val = intLiteralValue(call.args[0]) orelse return null;
            var key_buf = std.array_list.Managed(u8).init(ctx.allocator);
            defer key_buf.deinit();
            const key = try formatCharArrayKey(&key_buf, call.name, idx_val);
            if (ctx.char_array_values.get(key)) |val| return val;
            return null;
        },
        else => return null,
    }
}

fn formatCharArrayKey(buffer: *std.array_list.Managed(u8), name: []const u8, idx: i64) ![]const u8 {
    buffer.clearRetainingCapacity();
    try buffer.print("{s}[{d}]", .{ name, idx });
    return buffer.items;
}

pub fn trackCharAssignment(ctx: *Context, target: *ast.Expr, value: ?[]const u8) void {
    switch (target.*) {
        .identifier => |name| {
            const sym = ctx.findSymbol(name);
            if (sym) |s| {
                if (s.isCharacter() and s.dims.len > 0) {
                    invalidateCharArrayEntries(ctx, name);
                    return;
                }
            }
            updateCharMap(&ctx.char_values, ctx, name, value);
        },
        .call_or_subscript => |call| {
            if (call.args.len != 1) {
                invalidateCharArrayEntries(ctx, call.name);
                return;
            }
            const idx_val = intLiteralValue(call.args[0]) orelse {
                invalidateCharArrayEntries(ctx, call.name);
                return;
            };
            var key_buf = std.array_list.Managed(u8).init(ctx.allocator);
            defer key_buf.deinit();
            const key = formatCharArrayKey(&key_buf, call.name, idx_val) catch return;
            updateCharMap(&ctx.char_array_values, ctx, key, value);
        },
        .substring => |sub| {
            const sym = ctx.findSymbol(sub.name) orelse return;
            if (sym.isCharacter() and sym.dims.len > 0 and sub.args.len == 0) {
                invalidateCharArrayEntries(ctx, sub.name);
            }
        },
        else => {},
    }
}

fn invalidateCharArrayEntries(ctx: *Context, name: []const u8) void {
    var keys = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer keys.deinit();

    var it = ctx.char_array_values.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (isCharArrayEntryKeyForName(key, name)) {
            keys.append(key) catch return;
        }
    }

    for (keys.items) |key| {
        if (ctx.char_array_values.fetchRemove(key)) |kv| {
            ctx.allocator.free(kv.key);
            ctx.allocator.free(kv.value);
        }
    }
}

fn isCharArrayEntryKeyForName(key: []const u8, name: []const u8) bool {
    if (key.len <= name.len + 1) return false;
    if (!std.mem.eql(u8, key[0..name.len], name)) return false;
    return key[name.len] == '[';
}

fn updateCharMap(map: *std.StringHashMap([]const u8), ctx: *Context, key: []const u8, value: ?[]const u8) void {
    if (map.get(key)) |existing| {
        ctx.allocator.free(existing);
        _ = map.remove(key);
    }
    if (value) |val| {
        const key_dup = ctx.allocator.dupe(u8, key) catch return;
        const val_dup = ctx.allocator.dupe(u8, val) catch {
            ctx.allocator.free(key_dup);
            return;
        };
        map.put(key_dup, val_dup) catch {
            ctx.allocator.free(key_dup);
            ctx.allocator.free(val_dup);
        };
    }
}

pub fn storeCharacterValue(ctx: *Context, builder: anytype, target_ptr: ValueRef, char_len: usize, value_expr: *ast.Expr) EmitError!void {
    const target_len = constI32(ctx, @intCast(char_len));
    try storeCharacterValueDynamic(ctx, builder, target_ptr, target_len, value_expr);
}

fn emitCharacterBytesStore(
    ctx: *Context,
    builder: anytype,
    target_ptr: ValueRef,
    char_len: usize,
    bytes: []const u8,
) EmitError!void {
    var i: usize = 0;
    while (i < char_len) : (i += 1) {
        const byte: u8 = if (i < bytes.len) bytes[i] else ' ';
        const offset = ValueRef{ .name = try ctx.intLiteral(@intCast(i)), .ty = .i32, .is_ptr = false };
        const gep = try ctx.nextTemp();
        try builder.gep(gep, .i8, target_ptr, offset);
        const val = ValueRef{ .name = try ctx.intLiteral(byte), .ty = .i8, .is_ptr = false };
        try builder.store(val, .{ .name = gep, .ty = .ptr, .is_ptr = true });
    }
}

pub fn storeCharacterValueDynamic(
    ctx: *Context,
    builder: anytype,
    target_ptr: ValueRef,
    target_len: ValueRef,
    value_expr: *ast.Expr,
) EmitError!void {
    const plan = (try expr_dispatch.emitCharacterValuePlan(ctx, builder, value_expr)) orelse return error.UnsupportedCharacterArgumentLength;
    var target_len_i32 = target_len;
    if (target_len_i32.ty != .i32) {
        target_len_i32 = try expr.coerceCheckedI32(ctx, builder, target_len_i32);
    }

    const src_ptr = plan.ptr;
    var src_len = plan.logical_len;
    if (src_len.ty != .i32) {
        src_len = try expr.coerceCheckedI32(ctx, builder, src_len);
    }

    const idx_ptr = try ctx.nextTemp();
    try builder.alloca(idx_ptr, .i32);
    try builder.store(utils.zeroValue(.i32), .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });

    const loop_cond = try ctx.nextLabel("str_loop_cond");
    const loop_body = try ctx.nextLabel("str_loop_body");
    const copy_block = try ctx.nextLabel("str_copy");
    const pad_block = try ctx.nextLabel("str_pad");
    const loop_inc = try ctx.nextLabel("str_loop_inc");
    const loop_end = try ctx.nextLabel("str_loop_end");

    try builder.br(loop_cond);

    try builder.label(loop_cond);
    const idx_val_tmp = try ctx.nextTemp();
    try builder.load(idx_val_tmp, .i32, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    const idx_val = ValueRef{ .name = idx_val_tmp, .ty = .i32, .is_ptr = false };
    const cmp_tmp = try ctx.nextTemp();
    try builder.compare(cmp_tmp, "icmp", "slt", .i32, idx_val, target_len_i32);
    const cond = ValueRef{ .name = cmp_tmp, .ty = .i1, .is_ptr = false };
    try builder.brCond(cond, loop_body, loop_end);

    try builder.label(loop_body);
    const src_cmp_tmp = try ctx.nextTemp();
    try builder.compare(src_cmp_tmp, "icmp", "slt", .i32, idx_val, src_len);
    const src_cond = ValueRef{ .name = src_cmp_tmp, .ty = .i1, .is_ptr = false };
    try builder.brCond(src_cond, copy_block, pad_block);

    try builder.label(copy_block);
    const src_gep = try ctx.nextTemp();
    try builder.gep(src_gep, .i8, src_ptr, idx_val);
    const src_tmp = try ctx.nextTemp();
    try builder.load(src_tmp, .i8, .{ .name = src_gep, .ty = .ptr, .is_ptr = true });
    const dst_gep = try ctx.nextTemp();
    try builder.gep(dst_gep, .i8, target_ptr, idx_val);
    try builder.store(.{ .name = src_tmp, .ty = .i8, .is_ptr = false }, .{ .name = dst_gep, .ty = .ptr, .is_ptr = true });
    try builder.br(loop_inc);

    try builder.label(pad_block);
    const pad_gep = try ctx.nextTemp();
    try builder.gep(pad_gep, .i8, target_ptr, idx_val);
    const blank = ValueRef{ .name = try ctx.intLiteral(32), .ty = .i8, .is_ptr = false };
    try builder.store(blank, .{ .name = pad_gep, .ty = .ptr, .is_ptr = true });
    try builder.br(loop_inc);

    try builder.label(loop_inc);
    const next_tmp = try ctx.nextTemp();
    try builder.binary(next_tmp, "add", .i32, idx_val, utils.oneValue());
    const next_val = ValueRef{ .name = next_tmp, .ty = .i32, .is_ptr = false };
    try builder.store(next_val, .{ .name = idx_ptr, .ty = .ptr, .is_ptr = true });
    try builder.br(loop_cond);

    try builder.label(loop_end);
}

pub fn emitSubstringLenValue(ctx: *Context, builder: anytype, sub: ast.SubstringExpr) EmitError!ValueRef {
    const sym = ctx.findSymbol(sub.name) orelse return error.UnknownSymbol;
    const start_val = if (sub.start) |start_expr| try expr.emitIndex(ctx, builder, start_expr) else utils.oneValue();
    const end_val = if (sub.end) |end_expr|
        try expr.emitIndex(ctx, builder, end_expr)
    else
        try emitCharSymbolLenValue(ctx, sub.name, sym);
    const diff = try expr.emitSub(ctx, builder, end_val, start_val);
    return expr.emitAdd(ctx, builder, diff, utils.oneValue());
}

pub fn constI32(ctx: *Context, value: i64) ValueRef {
    return ctx.constI32(value) catch unreachable;
}

pub fn constI64(ctx: *Context, value: i64) ValueRef {
    return .{ .name = ctx.intLiteral(value) catch unreachable, .ty = .i64, .is_ptr = false };
}

fn emitCharSymbolLenValue(ctx: *Context, name: []const u8, sym: ast.sema.Symbol) EmitError!ValueRef {
    const len_val = try expr_dispatch.emitCharacterSymbolLenValue(ctx, name, sym);
    if (len_val.ty != .i32) return error.NonConstantCharacterLength;
    return len_val;
}

pub fn charLenForExpr(ctx: *Context, expr_node: *ast.Expr) ?usize {
    return expr_dispatch.constantCharacterLenForExpr(ctx, expr_node);
}

fn intLiteralValue(expr_node: *ast.Expr) ?i64 {
    return switch (expr_node.*) {
        .literal => |lit| if (lit.kind == .integer) std.fmt.parseInt(i64, lit.text, 10) catch null else null,
        .unary => |un| {
            const value = intLiteralValue(un.expr) orelse return null;
            return switch (un.op) {
                .plus => value,
                .minus => -value,
                else => null,
            };
        },
        .binary => |bin| {
            const left = intLiteralValue(bin.left) orelse return null;
            const right = intLiteralValue(bin.right) orelse return null;
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
