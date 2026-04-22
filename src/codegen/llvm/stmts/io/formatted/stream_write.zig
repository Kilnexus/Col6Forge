const std = @import("std");
const ast = @import("../../../../input.zig");
const llvm_types = @import("../../../types.zig");
const context = @import("../../../codegen/context/mod.zig");
const expr = @import("../../../codegen/expression/mod.zig");
const complex = @import("../../../codegen/expression/complex.zig");
const format_ir = @import("../../../../../format/stream_ir.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

const io_utils = @import("../utils.zig");
const expansion = @import("../expansion.zig");
const formatted_context = @import("context.zig");
const stream_common = @import("stream_common.zig");
const stream_runtime = @import("stream_runtime.zig");
const array_actuals = @import("../../../codegen/expression/call/array_actuals.zig");

const expandWriteArgs = expansion.expandWriteArgs;
const coerceRuntimeI32 = io_utils.coerceRuntimeI32;
const emitRuntimeFormatValue = formatted_context.emitRuntimeFormatValue;
const StreamFormatSource = formatted_context.StreamFormatSource;
const emitSharedRuntimeImpliedDo = stream_common.emitRuntimeImpliedDo;
const emitSharedStreamArgs = stream_common.emitStreamArgs;
const BeginDeclNames = stream_runtime.BeginDeclNames;
const BeginOptions = stream_runtime.BeginOptions;
const emitSharedStreamBegin = stream_runtime.emitStreamBegin;
const emitSharedStreamFinishStatus = stream_runtime.emitStreamFinishStatus;
const emitArrayActualElement = array_actuals.emitArrayActualElement;
const emitArrayActualElementPtr = array_actuals.emitArrayActualElementPtr;
const emitExtentProductI64 = array_actuals.emitExtentProductI64;
const emitOwnedHeapActualFree = array_actuals.emitOwnedHeapActualFree;
const resolveArrayActual = array_actuals.resolveArrayActual;

fn appendEscapedLiteral(buf: *std.array_list.Managed(u8), text: []const u8) !void {
    for (text) |ch| {
        if (ch == '%') {
            try buf.appendSlice("%%");
        } else {
            try buf.append(ch);
        }
    }
}

fn appendIntDescriptor(
    buf: *std.array_list.Managed(u8),
    width: usize,
    min_digits: usize,
    explicit_min_digits: bool,
    sign_plus: bool,
) !void {
    const sign: u8 = if (sign_plus) 1 else 0;
    try buf.writer().print(
        "%I{d},{d},{d};",
        .{ width, if (explicit_min_digits and min_digits == 0) @as(i32, -1) else @as(i32, @intCast(min_digits)), sign },
    );
}

fn appendFixedDescriptor(buf: *std.array_list.Managed(u8), width: usize, precision: usize, sign_plus: bool) !void {
    const sign: u8 = if (sign_plus) 1 else 0;
    try buf.writer().print("%F{d},{d},{d};", .{ width, precision, sign });
}

fn appendRealDescriptor(buf: *std.array_list.Managed(u8), kind: u8, width: usize, precision: usize, exp_width: usize, scale: i32, sign_plus: bool) !void {
    const sign: u8 = if (sign_plus) 1 else 0;
    try buf.writer().print("%R{c},{d},{d},{d},{d},{d};", .{ kind, width, precision, exp_width, scale, sign });
}

fn lowerStaticWriteStreamFormatWithBuilder(
    ctx: *Context,
    builder: anytype,
    fmt_ops: []const format_ir.StreamOp,
    is_internal: bool,
) EmitError!ValueRef {
    _ = is_internal;
    var fmt_buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer fmt_buf.deinit();

    var sign_plus = false;
    var scale_factor: i32 = 0;
    for (fmt_ops) |item| {
        switch (item) {
            .literal => |text| try appendEscapedLiteral(&fmt_buf, text),
            .spaces => |count| {
                var i: usize = 0;
                while (i < count) : (i += 1) try fmt_buf.append(' ');
            },
            .tab => |tab| {
                try fmt_buf.append(0x01);
                try fmt_buf.append(switch (tab.kind) {
                    .absolute => 'T',
                    .relative_right => 'R',
                    .relative_left => 'L',
                });
                try fmt_buf.print("{d}", .{tab.count});
                try fmt_buf.append(0x02);
            },
            .descriptor => |descriptor| switch (descriptor) {
                .int => |spec| try appendIntDescriptor(&fmt_buf, spec.width, spec.min_digits, spec.explicit_min_digits, sign_plus),
                .real_fixed => |spec| try appendFixedDescriptor(&fmt_buf, spec.width, spec.precision, sign_plus),
                .real => |spec| try appendRealDescriptor(
                    &fmt_buf,
                    switch (spec.kind) {
                        .e => 'E',
                        .d => 'D',
                        .g => 'G',
                    },
                    spec.width,
                    spec.precision,
                    spec.exp_width,
                    scale_factor,
                    sign_plus,
                ),
                .char => |spec| try fmt_buf.print("%S{d};", .{spec.width}),
                .logical => |spec| try fmt_buf.print("%L{d};", .{spec.width}),
            },
            .sign_control => |ctrl| sign_plus = (ctrl == .plus),
            .scale => |value| scale_factor = value,
            .blank_control => {},
            .colon => {},
            .reversion_anchor => try fmt_buf.append(0x03),
        }
    }

    const fmt_global = try ctx.string_pool.intern(fmt_buf.items);
    const fmt_ptr_name = try ctx.nextTemp();
    try builder.gepConstString(fmt_ptr_name, fmt_global, fmt_buf.items.len + 1);
    return .{ .name = fmt_ptr_name, .ty = .ptr, .is_ptr = true };
}

const StreamArg = struct {
    ptr: ValueRef,
    kind: u8,
    len: usize,
};

fn emitStreamArg(
    ctx: *Context,
    builder: anytype,
    value: ValueRef,
    char_len: usize,
) EmitError!StreamArg {
    return switch (value.ty) {
        .ptr => .{
            .ptr = .{ .name = value.name, .ty = .ptr, .is_ptr = true },
            .kind = 's',
            .len = char_len,
        },
        .i1 => blk: {
            const int_ty = ctx.defaultIntegerIRType();
            const one = try expr.coerce(ctx, builder, try ctx.constI32(1), int_ty);
            const zero = try expr.coerce(ctx, builder, try ctx.constI32(0), int_ty);
            const select_tmp = try ctx.nextTemp();
            try builder.select(select_tmp, int_ty, value, one, zero);
            const slot_name = try ctx.nextTemp();
            try builder.alloca(slot_name, int_ty);
            const slot = ValueRef{ .name = slot_name, .ty = .ptr, .is_ptr = true };
            try builder.store(.{ .name = select_tmp, .ty = int_ty, .is_ptr = false }, slot);
            break :blk .{
                .ptr = slot,
                .kind = 'L',
                .len = 0,
            };
        },
        .f32, .f64 => blk: {
            const coerced = try expr.coerce(ctx, builder, value, .f64);
            const slot_name = try ctx.nextTemp();
            try builder.alloca(slot_name, .f64);
            const slot = ValueRef{ .name = slot_name, .ty = .ptr, .is_ptr = true };
            try builder.store(coerced, slot);
            break :blk .{
                .ptr = slot,
                .kind = 'D',
                .len = 0,
            };
        },
        .i32, .i64 => blk: {
            const int_ty = ctx.defaultIntegerIRType();
            const coerced = try expr.coerce(ctx, builder, value, int_ty);
            const slot_name = try ctx.nextTemp();
            try builder.alloca(slot_name, int_ty);
            const slot = ValueRef{ .name = slot_name, .ty = .ptr, .is_ptr = true };
            try builder.store(coerced, slot);
            break :blk .{
                .ptr = slot,
                .kind = if (int_ty == .i64) 'j' else 'i',
                .len = 0,
            };
        },
        else => error.UnsupportedIntrinsicType,
    };
}

fn emitStreamNextValue(ctx: *Context, builder: anytype, state: ValueRef, arg: StreamArg) EmitError!void {
    return emitStreamNextPointer(ctx, builder, state, arg.ptr, arg.kind, try ctx.constI32(@intCast(arg.len)));
}

fn emitStreamNextPointer(
    ctx: *Context,
    builder: anytype,
    state: ValueRef,
    ptr: ValueRef,
    kind: u8,
    len: ValueRef,
) EmitError!void {
    const decl = try ctx.ensureDeclRaw("col6forge_formatted_write_stream_next", .i32, &[_]llvm_types.IRType{ .ptr, .ptr, .i32, .i32 }, false);
    const len_i32 = if (len.ty == .i32) len else try coerceRuntimeI32(ctx, builder, len);
    try builder.callTyped(
        null,
        .i32,
        decl,
        &.{
            state,
            ptr,
            try ctx.constI32(@intCast(kind)),
            len_i32,
        },
    );
}

fn emitScalarStreamSlice(ctx: *Context, builder: anytype, state: ValueRef, args: []*ast.Expr) EmitError!void {
    if (args.len == 0) return;
    var expanded = try expandWriteArgs(ctx, builder, args);
    defer expanded.deinit();
    for (expanded.values.items, 0..) |value, idx| {
        const arg = try emitStreamArg(ctx, builder, value, expanded.char_lens.items[idx]);
        try emitStreamNextValue(ctx, builder, state, arg);
    }
}

fn emitResolvedArrayActualStream(ctx: *Context, builder: anytype, state: ValueRef, actual: anytype) EmitError!void {
    errdefer emitOwnedHeapActualFree(ctx, builder, actual.owned_heap_ptr) catch {};

    const idx_ptr_name = try ctx.nextTemp();
    try builder.alloca(idx_ptr_name, .i64);
    const idx_ptr = ValueRef{ .name = idx_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(try ctx.constI64(0), idx_ptr);

    const count = try emitExtentProductI64(ctx, builder, actual.extents);
    const loop_head = try ctx.nextLabel("fmt_write_arr_head");
    const loop_body = try ctx.nextLabel("fmt_write_arr_body");
    const loop_exit = try ctx.nextLabel("fmt_write_arr_exit");
    try builder.br(loop_head);

    try builder.label(loop_head);
    const idx_tmp = try ctx.nextTemp();
    try builder.load(idx_tmp, .i64, idx_ptr);
    const idx_val = ValueRef{ .name = idx_tmp, .ty = .i64, .is_ptr = false };
    const cond_tmp = try ctx.nextTemp();
    try builder.compare(cond_tmp, "icmp", "slt", .i64, idx_val, count);
    try builder.brCond(.{ .name = cond_tmp, .ty = .i1, .is_ptr = false }, loop_body, loop_exit);

    try builder.label(loop_body);
    if (actual.elem_ty == .i8) {
        const elem_ptr = try emitArrayActualElementPtr(
            ctx,
            builder,
            actual.base_ptr,
            actual.elem_ty,
            actual.extents,
            actual.multipliers,
            actual.address_scale,
            actual.contiguous,
            idx_val,
        );
        try emitStreamNextPointer(ctx, builder, state, elem_ptr, 's', actual.address_scale);
    } else {
        const value = try emitArrayActualElement(ctx, builder, idx_val, actual);
        if (complex.isComplexType(value.ty)) {
            const real = try complex.extractComplex(ctx, builder, value, 0);
            const imag = try complex.extractComplex(ctx, builder, value, 1);
            const real_arg = try emitStreamArg(ctx, builder, real, 0);
            const imag_arg = try emitStreamArg(ctx, builder, imag, 0);
            try emitStreamNextValue(ctx, builder, state, real_arg);
            try emitStreamNextValue(ctx, builder, state, imag_arg);
        } else {
            const arg = try emitStreamArg(ctx, builder, value, 0);
            try emitStreamNextValue(ctx, builder, state, arg);
        }
    }

    const next_tmp = try ctx.nextTemp();
    try builder.binary(next_tmp, "add", .i64, idx_val, try ctx.constI64(1));
    try builder.store(.{ .name = next_tmp, .ty = .i64, .is_ptr = false }, idx_ptr);
    try builder.br(loop_head);

    try builder.label(loop_exit);
    try emitOwnedHeapActualFree(ctx, builder, actual.owned_heap_ptr);
}

fn emitStreamSlice(ctx: *Context, builder: anytype, state: ValueRef, args: []*ast.Expr) EmitError!void {
    if (args.len == 0) return;

    var chunk_start: usize = 0;
    for (args, 0..) |arg, idx| {
        const actual = (try resolveArrayActual(ctx, builder, arg)) orelse continue;
        try emitScalarStreamSlice(ctx, builder, state, args[chunk_start..idx]);
        try emitResolvedArrayActualStream(ctx, builder, state, actual);
        chunk_start = idx + 1;
    }
    try emitScalarStreamSlice(ctx, builder, state, args[chunk_start..]);
}

fn emitRuntimeImpliedDo(
    ctx: *Context,
    builder: anytype,
    state: ValueRef,
    implied: ast.ImpliedDo,
) EmitError!void {
    return emitSharedRuntimeImpliedDo(ctx, builder, state, implied, "fmt_write_implied", emitStreamArgs);
}

fn emitStreamArgs(ctx: *Context, builder: anytype, state: ValueRef, args: []*ast.Expr) EmitError!void {
    return emitSharedStreamArgs(ctx, builder, state, args, emitStreamSlice, emitRuntimeImpliedDo);
}

fn emitStreamBegin(
    ctx: *Context,
    builder: anytype,
    unit_value: ValueRef,
    unit_char_len: ?usize,
    unit_record_count: ?usize,
    is_internal: bool,
    unit_i32: ValueRef,
    format_source: StreamFormatSource,
) EmitError!ValueRef {
    return emitSharedStreamBegin(
        ctx,
        builder,
        .{
            .external_static = "col6forge_formatted_write_stream_begin",
            .external_dynamic = "col6forge_formatted_write_stream_begin_dynamic",
            .internal_static = "col6forge_write_internal_stream_begin",
            .internal_dynamic = "col6forge_write_internal_stream_begin_dynamic",
        },
        .{
            .unit_value = unit_value,
            .unit_char_len = unit_char_len,
            .unit_record_count = unit_record_count,
            .is_internal = is_internal,
            .unit_i32 = unit_i32,
            .format_source = format_source,
            .mode_i32 = .{ .name = "0", .ty = .i32, .is_ptr = false },
        },
        lowerStaticWriteStreamFormatWithBuilder,
        emitRuntimeFormatValue,
    );
}

fn emitStreamFinish(ctx: *Context, builder: anytype, state: ValueRef) EmitError!void {
    _ = try emitSharedStreamFinishStatus(ctx, builder, "col6forge_formatted_write_stream_finish", state);
}

pub fn emitWriteFormattedStream(
    ctx: *Context,
    builder: anytype,
    write: ast.WriteStmt,
    unit_value: ValueRef,
    unit_char_len: ?usize,
    unit_record_count: ?usize,
    is_internal: bool,
    unit_i32: ValueRef,
    format_source: StreamFormatSource,
) EmitError!void {
    const state = try emitStreamBegin(
        ctx,
        builder,
        unit_value,
        unit_char_len,
        unit_record_count,
        is_internal,
        unit_i32,
        format_source,
    );
    try emitStreamArgs(ctx, builder, state, write.args);
    try emitStreamFinish(ctx, builder, state);
}
