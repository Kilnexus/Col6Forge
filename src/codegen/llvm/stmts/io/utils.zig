const std = @import("std");
const ast = @import("../../../input.zig");
const llvm_types = @import("../../types.zig");
const common = @import("../../codegen/common.zig");
const context = @import("../../codegen/context/mod.zig");
const expr = @import("../../codegen/expression/mod.zig");
const utils = @import("../../codegen/utils.zig");
const cfg = @import("../cfg.zig");
const evaluator = @import("../../../../semantic/evaluator.zig");
const sema_mod = @import("../../../../semantic/mod.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

pub const RuntimeI32OutArg = struct {
    runtime_ptr: ValueRef,
    target_ptr: ?ValueRef = null,
    scratch_ptr: ?ValueRef = null,
    target_ty: ?llvm_types.IRType = null,
};

pub fn storeRuntimeI32Value(
    ctx: *Context,
    builder: anytype,
    target_expr: *ast.Expr,
    value: ValueRef,
) EmitError!void {
    if (value.ty != .i32) return error.UnsupportedIntrinsicType;
    const target_ptr = try expr.emitLValue(ctx, builder, target_expr);
    const target_ty = if (targetExprSymbol(ctx, target_expr)) |sym|
        common.symbolStorageIRType(sym, ctx.options.target_layout)
    else
        try expr.exprType(ctx, target_expr);
    switch (target_ty) {
        .i32 => try builder.store(value, target_ptr),
        .i64 => {
            const widened = try expr.coerce(ctx, builder, value, .i64);
            try builder.store(widened, target_ptr);
        },
        .i1 => {
            const cmp_tmp = try ctx.nextTemp();
            try builder.compare(
                cmp_tmp,
                "icmp",
                "ne",
                .i32,
                value,
                .{ .name = "0", .ty = .i32, .is_ptr = false },
            );
            try builder.store(.{ .name = cmp_tmp, .ty = .i1, .is_ptr = false }, target_ptr);
        },
        else => return error.UnsupportedIntrinsicType,
    }
}

pub fn prepareRuntimeI32OutArg(
    ctx: *Context,
    builder: anytype,
    target_expr: ?*ast.Expr,
) EmitError!RuntimeI32OutArg {
    const expr_node = target_expr orelse {
        return .{ .runtime_ptr = .{ .name = "null", .ty = .ptr, .is_ptr = false } };
    };

    const target_ptr = try expr.emitLValue(ctx, builder, expr_node);
    const target_ty = if (targetExprSymbol(ctx, expr_node)) |sym|
        common.symbolStorageIRType(sym, ctx.options.target_layout)
    else
        try expr.exprType(ctx, expr_node);
    switch (target_ty) {
        .i32 => return .{
            .runtime_ptr = target_ptr,
            .target_ptr = target_ptr,
            .target_ty = .i32,
        },
        .i64, .i1 => {
            const scratch_name = try ctx.nextTemp();
            try builder.alloca(scratch_name, .i32);
            const scratch_ptr = ValueRef{ .name = scratch_name, .ty = .ptr, .is_ptr = true };
            try builder.store(.{ .name = "0", .ty = .i32, .is_ptr = false }, scratch_ptr);
            return .{
                .runtime_ptr = scratch_ptr,
                .target_ptr = target_ptr,
                .scratch_ptr = scratch_ptr,
                .target_ty = target_ty,
            };
        },
        else => return error.UnsupportedIntrinsicType,
    }
}

fn targetExprSymbol(ctx: *Context, expr_node: *ast.Expr) ?ast.sema.Symbol {
    return switch (expr_node.*) {
        .identifier => |name| ctx.findSymbol(name),
        .call_or_subscript => |call| ctx.findSymbol(call.name),
        else => null,
    };
}

pub fn ioScalarStorageIRType(ctx: *Context, expr_node: *ast.Expr) EmitError!?llvm_types.IRType {
    if (targetExprSymbol(ctx, expr_node)) |sym| {
        if (sym.isCharacter()) return .ptr;
        if (sym.loweredKind() == .logical) {
            return common.symbolStorageIRType(sym, ctx.options.target_layout);
        }
    }

    const ty = try expr.exprType(ctx, expr_node);
    return switch (ty) {
        .ptr => null,
        .i1 => ctx.defaultIntegerIRType(),
        else => ty,
    };
}

pub fn emitStackIoScalarValue(ctx: *Context, builder: anytype, value: ValueRef) EmitError!ValueRef {
    if (value.ty == .ptr) return error.UnsupportedIntrinsicType;
    if (value.ty == .i1) {
        const storage_ty = ctx.defaultIntegerIRType();
        const widened = try expr.coerce(ctx, builder, value, storage_ty);
        return emitStackValue(ctx, builder, widened);
    }
    return emitStackValue(ctx, builder, value);
}

pub fn commitRuntimeI32OutArg(
    ctx: *Context,
    builder: anytype,
    arg: RuntimeI32OutArg,
) EmitError!void {
    const target_ptr = arg.target_ptr orelse return;
    const target_ty = arg.target_ty orelse return;
    const scratch_ptr = arg.scratch_ptr orelse return;

    const loaded_name = try ctx.nextTemp();
    try builder.load(loaded_name, .i32, scratch_ptr);
    const loaded = ValueRef{ .name = loaded_name, .ty = .i32, .is_ptr = false };
    switch (target_ty) {
        .i64 => {
            const widened = try expr.coerce(ctx, builder, loaded, .i64);
            try builder.store(widened, target_ptr);
        },
        .i1 => {
            const cmp_tmp = try ctx.nextTemp();
            try builder.compare(
                cmp_tmp,
                "icmp",
                "ne",
                .i32,
                loaded,
                .{ .name = "0", .ty = .i32, .is_ptr = false },
            );
            try builder.store(.{ .name = cmp_tmp, .ty = .i1, .is_ptr = false }, target_ptr);
        },
        .i32 => {},
        else => return error.UnsupportedIntrinsicType,
    }
}

pub fn emitIoStatusBranches(
    ctx: *Context,
    builder: anytype,
    read: ast.ReadStmt,
    status: ValueRef,
    next_block: []const u8,
    local_label_map: ?*const std.StringHashMap([]const u8),
) EmitError!bool {
    if (read.iostat) |iostat_expr| {
        try storeRuntimeI32Value(ctx, builder, iostat_expr, status);
    }

    const zero = ValueRef{ .name = "0", .ty = .i32, .is_ptr = false };

    if (read.err_label != null or read.end_label != null) {
        var cont_label = next_block;
        if (read.err_label) |err_label| {
            const err_target = cfg.resolveLabel(ctx, local_label_map, err_label) orelse return error.MissingLabel;
            const cmp_tmp = try ctx.nextTemp();
            try builder.compare(cmp_tmp, "icmp", "sgt", .i32, status, zero);
            const cond = ValueRef{ .name = cmp_tmp, .ty = .i1, .is_ptr = false };
            const next = try ctx.nextLabel("iochk");
            try builder.brCond(cond, err_target, next);
            try builder.label(next);
            cont_label = next_block;
        }
        if (read.end_label) |end_label| {
            const end_target = cfg.resolveLabel(ctx, local_label_map, end_label) orelse return error.MissingLabel;
            const cmp_tmp = try ctx.nextTemp();
            try builder.compare(cmp_tmp, "icmp", "slt", .i32, status, zero);
            const cond = ValueRef{ .name = cmp_tmp, .ty = .i1, .is_ptr = false };
            try builder.brCond(cond, end_target, cont_label);
            return true;
        }
        try builder.br(cont_label);
        return true;
    }
    return false;
}

pub const ComplexFixup = struct {
    target_ptr: ValueRef,
    elem_ty: llvm_types.IRType,
    real_ptr: ValueRef,
    imag_ptr: ValueRef,
};
pub fn charLenForExpr(ctx: *Context, expr_node: *ast.Expr) ?usize {
    switch (expr_node.*) {
        .identifier => |name| {
            const sym = ctx.findSymbol(name) orelse return null;
            if (!sym.isCharacter()) return null;
            return common.constantCharacterLen(sym);
        },
        .call_or_subscript => |call| {
            const sym = ctx.findSymbol(call.name) orelse return null;
            if (!sym.isCharacter()) return null;
            return common.constantCharacterLen(sym);
        },
        .substring => |sub| {
            return substringLen(ctx, sub);
        },
        .binary => |bin| {
            if (bin.op != .concat) return null;
            const left_len = charLenForExpr(ctx, bin.left) orelse return null;
            const right_len = charLenForExpr(ctx, bin.right) orelse return null;
            return std.math.add(usize, left_len, right_len) catch null;
        },
        .literal => |lit| switch (lit.kind) {
            .string => return utils.decodedStringLen(lit.text),
            .hollerith => {
                const bytes = utils.hollerithBytes(lit.text) orelse return null;
                return bytes.len;
            },
            else => return null,
        },
        else => return null,
    }
}
pub fn internalUnitRecordCount(ctx: *Context, expr_node: *ast.Expr) ?usize {
    switch (expr_node.*) {
        .identifier => |name| {
            const sym = ctx.findSymbol(name) orelse return null;
            if (!sym.isCharacter()) return null;
            if (sym.dims.len == 0) return 1;
            return common.arrayElementCount(ctx.sem, sym.dims) catch null;
        },
        else => return null,
    }
}
fn substringLen(ctx: *Context, sub: ast.SubstringExpr) ?usize {
    const sym = ctx.findSymbol(sub.name) orelse return null;
    if (!sym.isCharacter()) return null;
    const base_len_usize = common.constantCharacterLen(sym) orelse return null;
    if (base_len_usize > @as(usize, @intCast(std.math.maxInt(i64)))) return null;
    const base_len: i64 = @intCast(base_len_usize);
    const start_val = if (sub.start) |start_expr| intLiteralValue(start_expr) orelse return null else 1;
    const end_val = if (sub.end) |end_expr| intLiteralValue(end_expr) orelse return null else base_len;
    const delta = checkedSubI64(end_val, start_val) orelse return null;
    const length = checkedAddI64(delta, 1) orelse return null;
    if (length <= 0) return null;
    return @intCast(length);
}
pub fn intLiteralValue(expr_node: *ast.Expr) ?i64 {
    // Only try semantic constant evaluation if the expression is purely literal-based
    if (isPurelyLiteral(expr_node)) {
        if (evaluator.evalConst(expr_node, null) catch null) |const_val| {
            return switch (const_val) {
                .integer => |v| v,
                .real => |v| @intFromFloat(v.value),
                else => null,
            };
        }
    }

    // Fallback to AST-level parsing
    return switch (expr_node.*) {
        .literal => |lit| if (lit.kind == .integer) std.fmt.parseInt(i64, lit.text, 10) catch null else null,
        .unary => |un| {
            const value = intLiteralValue(un.expr) orelse return null;
            return switch (un.op) {
                .plus => value,
                .minus => checkedNegI64(value),
                else => null,
            };
        },
        .binary => |bin| {
            const left = intLiteralValue(bin.left) orelse return null;
            const right = intLiteralValue(bin.right) orelse return null;
            return switch (bin.op) {
                .add => checkedAddI64(left, right),
                .sub => checkedSubI64(left, right),
                .mul => checkedMulI64(left, right),
                .div => checkedDivTruncI64(left, right),
                .power => if (right < 0) null else powInt(left, right),
                else => null,
            };
        },
        else => null,
    };
}

fn isPurelyLiteral(expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .literal => true,
        .unary => |un| isPurelyLiteral(un.expr),
        .binary => |bin| isPurelyLiteral(bin.left) and isPurelyLiteral(bin.right),
        .complex_literal => |lit| isPurelyLiteral(lit.real) and isPurelyLiteral(lit.imag),
        else => false,
    };
}
fn checkedAddI64(lhs: i64, rhs: i64) ?i64 {
    const out = @addWithOverflow(lhs, rhs);
    if (out[1] != 0) return null;
    return out[0];
}

fn checkedSubI64(lhs: i64, rhs: i64) ?i64 {
    const out = @subWithOverflow(lhs, rhs);
    if (out[1] != 0) return null;
    return out[0];
}

fn checkedMulI64(lhs: i64, rhs: i64) ?i64 {
    const out = @mulWithOverflow(lhs, rhs);
    if (out[1] != 0) return null;
    return out[0];
}

fn checkedNegI64(value: i64) ?i64 {
    const out = @subWithOverflow(@as(i64, 0), value);
    if (out[1] != 0) return null;
    return out[0];
}

fn checkedDivTruncI64(lhs: i64, rhs: i64) ?i64 {
    if (rhs == 0) return null;
    if (lhs == std.math.minInt(i64) and rhs == -1) return null;
    return @divTrunc(lhs, rhs);
}

fn powInt(base: i64, exp: i64) ?i64 {
    if (exp <= 0) return 1;
    var result: i64 = 1;
    var factor = base;
    var remaining: u64 = @intCast(exp);
    while (remaining != 0) : (remaining >>= 1) {
        if ((remaining & 1) != 0) {
            result = checkedMulI64(result, factor) orelse return null;
        }
        if (remaining > 1) {
            factor = checkedMulI64(factor, factor) orelse return null;
        }
    }
    return result;
}
pub fn appendScanfLiteral(buffer: *std.array_list.Managed(u8), text: []const u8) !void {
    for (text) |ch| {
        if (ch == '%') {
            try buffer.appendSlice("%%");
        } else {
            try buffer.append(ch);
        }
    }
}
pub fn countFormatDescriptors(items: []const ast.FormatItem) usize {
    var count: usize = 0;
    for (items) |item| {
        switch (item) {
            .int, .real, .real_fixed, .char, .logical => count += 1,
            else => {},
        }
    }
    return count;
}
pub fn evalConstIntSem(ctx: *Context, expr_node: *ast.Expr) EmitError!?i64 {
    const resolver = evaluator.ConstResolver{
        .ctx = @ptrCast(ctx),
        .resolveFn = resolveConstValueCtx,
    };
    const value = try evaluator.evalConst(expr_node, resolver);
    return switch (value orelse return null) {
        .integer => |v| v,
        else => null,
    };
}
fn resolveConstValueCtx(ctx_any: *anyopaque, name: []const u8) ?sema_mod.ConstValue {
    const ctx: *Context = @ptrCast(@alignCast(ctx_any));
    const sym = ctx.findSymbol(name) orelse return null;
    return sym.const_value;
}
pub fn findReversionStart(items: []const ast.FormatItem) usize {
    var idx: ?usize = null;
    for (items, 0..) |item, i| {
        if (item == .reversion_anchor) {
            idx = i;
        }
    }
    return idx orelse 0;
}
pub fn appendSpaces(buffer: *std.array_list.Managed(u8), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try buffer.append(' ');
    }
}
pub fn flushPendingSpaces(buffer: *std.array_list.Managed(u8), pending: *usize) !void {
    if (pending.* == 0) return;
    try appendSpaces(buffer, pending.*);
    pending.* = 0;
}
pub fn isAllNewlines(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (ch != '\n') return false;
    }
    return true;
}
pub fn countNewlinesLiteral(text: []const u8) usize {
    if (!isAllNewlines(text)) return 0;
    return text.len;
}

pub fn emitHeapBytes(ctx: *Context, builder: anytype, bytes: usize) EmitError!ValueRef {
    const malloc_name = try ctx.ensureDeclRaw("malloc", .ptr, &[_]llvm_types.IRType{.i64}, false);
    const size_val = ValueRef{ .name = try ctx.intLiteral(@intCast(bytes)), .ty = .i64, .is_ptr = false };
    const tmp = try ctx.nextTemp();
    try builder.callTyped(tmp, .ptr, malloc_name, &.{size_val});
    return .{ .name = tmp, .ty = .ptr, .is_ptr = true };
}

pub fn emitStackValue(ctx: *Context, builder: anytype, value: ValueRef) EmitError!ValueRef {
    if (value.ty == .ptr) return error.UnsupportedIntrinsicType;
    const ptr_name = try ctx.nextTemp();
    try builder.alloca(ptr_name, value.ty);
    const ptr = ValueRef{ .name = ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(value, ptr);
    return ptr;
}

pub fn coerceRuntimeI32(ctx: *Context, builder: anytype, value: ValueRef) EmitError!ValueRef {
    return expr.coerceCheckedI32(ctx, builder, value);
}

pub fn emitFreeAllocs(ctx: *Context, builder: anytype, allocs: []const ValueRef) EmitError!void {
    if (allocs.len == 0) return;
    const free_name = try ctx.ensureDeclRaw("free", .void, &[_]llvm_types.IRType{.ptr}, false);
    for (allocs) |ptr| {
        try builder.callTyped(null, .void, free_name, &.{ptr});
    }
}

pub fn defaultIntegerKind(ctx: *Context) u8 {
    return switch (ctx.defaultIntegerIRType()) {
        .i64 => 'j',
        else => 'i',
    };
}

pub fn defaultIntegerReadKind(ctx: *Context) u8 {
    return switch (ctx.defaultIntegerIRType()) {
        .i64 => 'j',
        else => 'd',
    };
}

pub fn defaultIntegerHelperSuffix(ctx: *Context) []const u8 {
    return switch (ctx.defaultIntegerIRType()) {
        .i64 => "i64",
        else => "i32",
    };
}

pub fn scalarRuntimeKind(ctx: *Context, ty: llvm_types.IRType) EmitError!u8 {
    _ = ctx;
    return switch (ty) {
        .i32 => 'i',
        .i64 => 'j',
        .f32 => 'f',
        .f64 => 'd',
        .i1 => 'l',
        .complex_f32 => 'c',
        .complex_f64 => 'z',
        else => error.UnsupportedIntrinsicType,
    };
}

pub fn scalarByteSize(ty: llvm_types.IRType) ?i64 {
    return switch (ty) {
        .i32, .f32 => 4,
        .i64, .f64, .complex_f32 => 8,
        .complex_f64 => 16,
        .i1 => 1,
        else => null,
    };
}

pub fn emitHeapPointerArrayFromValues(ctx: *Context, builder: anytype, ptrs: []const ValueRef) EmitError!ValueRef {
    if (ptrs.len == 0) {
        return .{ .name = "null", .ty = .ptr, .is_ptr = false };
    }
    const bytes = ptrs.len * @sizeOf(usize);
    const arr_ptr = try emitHeapBytes(ctx, builder, bytes);
    for (ptrs, 0..) |ptr, idx| {
        const off = try ctx.constI32(@intCast(idx));
        const gep = try ctx.nextTemp();
        try builder.gep(gep, .ptr, arr_ptr, off);
        const slot_ptr = ValueRef{ .name = gep, .ty = .ptr, .is_ptr = true };
        try builder.store(.{ .name = ptr.name, .ty = .ptr, .is_ptr = false }, slot_ptr);
    }
    return arr_ptr;
}

pub fn emitStackPointerArrayFromValues(ctx: *Context, builder: anytype, ptrs: []const ValueRef) EmitError!ValueRef {
    if (ptrs.len == 0) {
        return .{ .name = "null", .ty = .ptr, .is_ptr = false };
    }
    const arr_name = try ctx.nextTemp();
    try builder.allocaArray(arr_name, .ptr, ptrs.len);
    const arr_ptr = ValueRef{ .name = arr_name, .ty = .ptr, .is_ptr = true };
    for (ptrs, 0..) |ptr, idx| {
        const off = try ctx.constI32(@intCast(idx));
        const gep = try ctx.nextTemp();
        try builder.gep(gep, .ptr, arr_ptr, off);
        const slot_ptr = ValueRef{ .name = gep, .ty = .ptr, .is_ptr = true };
        try builder.store(.{ .name = ptr.name, .ty = .ptr, .is_ptr = false }, slot_ptr);
    }
    return arr_ptr;
}

pub fn emitStackI32Array(ctx: *Context, builder: anytype, values: []const i32) EmitError!ValueRef {
    if (values.len == 0) {
        return .{ .name = "null", .ty = .ptr, .is_ptr = false };
    }
    const arr_name = try ctx.nextTemp();
    try builder.allocaArray(arr_name, .i32, values.len);
    const arr_ptr = ValueRef{ .name = arr_name, .ty = .ptr, .is_ptr = true };
    for (values, 0..) |value, idx| {
        const off = try ctx.constI32(@intCast(idx));
        const gep = try ctx.nextTemp();
        try builder.gep(gep, .i32, arr_ptr, off);
        const slot_ptr = ValueRef{ .name = gep, .ty = .ptr, .is_ptr = true };
        try builder.store(try ctx.constI32(value), slot_ptr);
    }
    return arr_ptr;
}

pub fn emitHeapI32Array(ctx: *Context, builder: anytype, values: []const i32) EmitError!ValueRef {
    if (values.len == 0) {
        return .{ .name = "null", .ty = .ptr, .is_ptr = false };
    }
    const bytes = values.len * @sizeOf(i32);
    const arr_ptr = try emitHeapBytes(ctx, builder, bytes);
    for (values, 0..) |value, idx| {
        const off = try ctx.constI32(@intCast(idx));
        const gep = try ctx.nextTemp();
        try builder.gep(gep, .i32, arr_ptr, off);
        const slot_ptr = ValueRef{ .name = gep, .ty = .ptr, .is_ptr = true };
        try builder.store(try ctx.constI32(value), slot_ptr);
    }
    return arr_ptr;
}

pub fn emitHeapPointerArrayFromNames(ctx: *Context, builder: anytype, names: []const []const u8) EmitError!ValueRef {
    if (names.len == 0) {
        return .{ .name = "null", .ty = .ptr, .is_ptr = false };
    }
    const bytes = names.len * @sizeOf(usize);
    const arr_ptr = try emitHeapBytes(ctx, builder, bytes);
    for (names, 0..) |name, idx| {
        const off = try ctx.constI32(@intCast(idx));
        const gep = try ctx.nextTemp();
        try builder.gep(gep, .ptr, arr_ptr, off);
        const slot_ptr = ValueRef{ .name = gep, .ty = .ptr, .is_ptr = true };
        try builder.store(.{ .name = name, .ty = .ptr, .is_ptr = false }, slot_ptr);
    }
    return arr_ptr;
}

pub fn emitStackPointerArrayFromNames(ctx: *Context, builder: anytype, names: []const []const u8) EmitError!ValueRef {
    if (names.len == 0) {
        return .{ .name = "null", .ty = .ptr, .is_ptr = false };
    }
    const arr_name = try ctx.nextTemp();
    try builder.allocaArray(arr_name, .ptr, names.len);
    const arr_ptr = ValueRef{ .name = arr_name, .ty = .ptr, .is_ptr = true };
    for (names, 0..) |name, idx| {
        const off = try ctx.constI32(@intCast(idx));
        const gep = try ctx.nextTemp();
        try builder.gep(gep, .ptr, arr_ptr, off);
        const slot_ptr = ValueRef{ .name = gep, .ty = .ptr, .is_ptr = true };
        try builder.store(.{ .name = name, .ty = .ptr, .is_ptr = false }, slot_ptr);
    }
    return arr_ptr;
}

pub fn emitKindArray(ctx: *Context, builder: anytype, kinds: []const u8) EmitError!ValueRef {
    if (kinds.len == 0) {
        return .{ .name = "null", .ty = .ptr, .is_ptr = false };
    }
    const kinds_global = try ctx.string_pool.intern(kinds);
    const kinds_ptr = try ctx.nextTemp();
    try builder.gepConstString(kinds_ptr, kinds_global, kinds.len + 1);
    return .{ .name = kinds_ptr, .ty = .ptr, .is_ptr = true };
}

pub fn emitTripletCount(
    ctx: *Context,
    builder: anytype,
    start_expr: *ast.Expr,
    end_expr: *ast.Expr,
    step_expr: ?*ast.Expr,
) EmitError!ValueRef {
    var start_val = try expr.emitExpr(ctx, builder, start_expr);
    start_val = try coerceRuntimeI32(ctx, builder, start_val);
    var end_val = try expr.emitExpr(ctx, builder, end_expr);
    end_val = try coerceRuntimeI32(ctx, builder, end_val);
    if (step_expr == null) return emitUnitStepCountValues(ctx, builder, start_val, end_val);
    const step_node = step_expr.?;
    if ((try evalConstIntSem(ctx, step_node)) orelse intLiteralValue(step_node)) |step_const| {
        if (step_const == 1) return emitUnitStepCountValues(ctx, builder, start_val, end_val);
    }
    var step_val = try expr.emitExpr(ctx, builder, step_node);
    step_val = try coerceRuntimeI32(ctx, builder, step_val);
    return emitTripletCountValues(ctx, builder, start_val, end_val, step_val);
}

pub fn emitImpliedFinalCount(
    ctx: *Context,
    builder: anytype,
    start_expr: *ast.Expr,
    end_expr: *ast.Expr,
    step_expr: ?*ast.Expr,
) EmitError!ValueRef {
    return emitTripletCount(ctx, builder, start_expr, end_expr, step_expr);
}

pub fn emitTripletCountValues(
    ctx: *Context,
    builder: anytype,
    start_val: ValueRef,
    end_val: ValueRef,
    step_val: ValueRef,
) EmitError!ValueRef {
    const zero = ValueRef{ .name = "0", .ty = .i32, .is_ptr = false };
    const one = ValueRef{ .name = "1", .ty = .i32, .is_ptr = false };

    const step_nonzero_tmp = try ctx.nextTemp();
    try builder.compare(step_nonzero_tmp, "icmp", "ne", .i32, step_val, zero);
    const step_nonzero = ValueRef{ .name = step_nonzero_tmp, .ty = .i1, .is_ptr = false };

    const step_pos_tmp = try ctx.nextTemp();
    try builder.compare(step_pos_tmp, "icmp", "sgt", .i32, step_val, zero);
    const step_pos = ValueRef{ .name = step_pos_tmp, .ty = .i1, .is_ptr = false };

    const step_neg_tmp = try ctx.nextTemp();
    try builder.compare(step_neg_tmp, "icmp", "slt", .i32, step_val, zero);
    const step_neg = ValueRef{ .name = step_neg_tmp, .ty = .i1, .is_ptr = false };

    const safe_step_tmp = try ctx.nextTemp();
    try builder.select(safe_step_tmp, .i32, step_nonzero, step_val, one);
    const safe_step = ValueRef{ .name = safe_step_tmp, .ty = .i32, .is_ptr = false };

    const end_ge_start_tmp = try ctx.nextTemp();
    try builder.compare(end_ge_start_tmp, "icmp", "sge", .i32, end_val, start_val);
    const end_ge_start = ValueRef{ .name = end_ge_start_tmp, .ty = .i1, .is_ptr = false };

    const end_le_start_tmp = try ctx.nextTemp();
    try builder.compare(end_le_start_tmp, "icmp", "sle", .i32, end_val, start_val);
    const end_le_start = ValueRef{ .name = end_le_start_tmp, .ty = .i1, .is_ptr = false };

    const pos_range_ok_tmp = try ctx.nextTemp();
    try builder.binary(pos_range_ok_tmp, "and", .i1, step_pos, end_ge_start);
    const pos_range_ok = ValueRef{ .name = pos_range_ok_tmp, .ty = .i1, .is_ptr = false };

    const neg_range_ok_tmp = try ctx.nextTemp();
    try builder.binary(neg_range_ok_tmp, "and", .i1, step_neg, end_le_start);
    const neg_range_ok = ValueRef{ .name = neg_range_ok_tmp, .ty = .i1, .is_ptr = false };

    const has_values_tmp = try ctx.nextTemp();
    try builder.binary(has_values_tmp, "or", .i1, pos_range_ok, neg_range_ok);
    const has_values = ValueRef{ .name = has_values_tmp, .ty = .i1, .is_ptr = false };

    const diff_tmp = try ctx.nextTemp();
    try builder.binary(diff_tmp, "sub", .i32, end_val, start_val);
    const diff = ValueRef{ .name = diff_tmp, .ty = .i32, .is_ptr = false };
    const quot_tmp = try ctx.nextTemp();
    try builder.binary(quot_tmp, "sdiv", .i32, diff, safe_step);
    const quot = ValueRef{ .name = quot_tmp, .ty = .i32, .is_ptr = false };
    const count_raw_tmp = try ctx.nextTemp();
    try builder.binary(count_raw_tmp, "add", .i32, quot, one);
    const count_raw = ValueRef{ .name = count_raw_tmp, .ty = .i32, .is_ptr = false };

    const final_count_tmp = try ctx.nextTemp();
    try builder.select(final_count_tmp, .i32, has_values, count_raw, zero);
    return .{ .name = final_count_tmp, .ty = .i32, .is_ptr = false };
}

fn emitUnitStepCountValues(
    ctx: *Context,
    builder: anytype,
    start_val: ValueRef,
    end_val: ValueRef,
) EmitError!ValueRef {
    const diff_tmp = try ctx.nextTemp();
    try builder.binary(diff_tmp, "sub", .i32, end_val, start_val);
    const diff = ValueRef{ .name = diff_tmp, .ty = .i32, .is_ptr = false };
    const one = ValueRef{ .name = "1", .ty = .i32, .is_ptr = false };
    const count_tmp = try ctx.nextTemp();
    try builder.binary(count_tmp, "add", .i32, diff, one);
    const count_raw = ValueRef{ .name = count_tmp, .ty = .i32, .is_ptr = false };
    const zero = ValueRef{ .name = "0", .ty = .i32, .is_ptr = false };
    const nonpos_tmp = try ctx.nextTemp();
    try builder.compare(nonpos_tmp, "icmp", "sle", .i32, count_raw, zero);
    const nonpos = ValueRef{ .name = nonpos_tmp, .ty = .i1, .is_ptr = false };
    const final_count_tmp = try ctx.nextTemp();
    try builder.select(final_count_tmp, .i32, nonpos, zero, count_raw);
    return .{ .name = final_count_tmp, .ty = .i32, .is_ptr = false };
}

pub fn emitImpliedBasePtr(
    ctx: *Context,
    builder: anytype,
    call: ast.CallOrSubscript,
    loop_dim: usize,
    start_expr: *ast.Expr,
) EmitError!ValueRef {
    const base_args = try ctx.allocator.alloc(*ast.Expr, call.args.len);
    defer ctx.allocator.free(base_args);
    for (call.args, 0..) |arg, idx| {
        base_args[idx] = arg;
    }
    base_args[loop_dim] = start_expr;
    var base_expr = ast.Expr{
        .call_or_subscript = .{
            .name = call.name,
            .args = base_args,
        },
    };
    return expr.emitLValue(ctx, builder, &base_expr);
}

pub fn appendIntFormat(buffer: *std.array_list.Managed(u8), width: usize, sign_plus: bool) !void {
    const sign_flag = if (sign_plus) "+" else "";
    if (width == 0) {
        try buffer.print("%{s}d", .{sign_flag});
    } else {
        try buffer.print("%{s}{d}d", .{ sign_flag, width });
    }
}
