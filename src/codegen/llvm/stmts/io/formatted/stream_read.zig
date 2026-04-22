const std = @import("std");
const ast = @import("../../../../input.zig");
const llvm_types = @import("../../../types.zig");
const context = @import("../../../codegen/context/mod.zig");
const expr = @import("../../../codegen/expression/mod.zig");
const format_ir = @import("../../../../../format/stream_ir.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

const io_utils = @import("../utils.zig");
const expansion = @import("../expansion.zig");
const utils = @import("../../../codegen/utils.zig");
const formatted_context = @import("context.zig");
const stream_common = @import("stream_common.zig");
const stream_runtime = @import("stream_runtime.zig");

const applyComplexFixups = expansion.applyComplexFixups;
const expandReadTargets = expansion.expandReadTargets;
const appendScanfLiteral = io_utils.appendScanfLiteral;
const emitRuntimeFormatValue = formatted_context.emitRuntimeFormatValue;
const StreamFormatSource = formatted_context.StreamFormatSource;
const emitSharedRuntimeImpliedDo = stream_common.emitRuntimeImpliedDo;
const emitSharedStreamArgs = stream_common.emitStreamArgs;
const emitSharedStreamBegin = stream_runtime.emitStreamBegin;
const emitSharedStreamFinishStatus = stream_runtime.emitStreamFinishStatus;

fn formattedReadKindForType(ctx: *Context, ty: llvm_types.IRType) EmitError!u8 {
    return switch (ty) {
        .i32 => io_utils.defaultIntegerReadKind(ctx),
        .i64 => 'j',
        .f32 => 'f',
        .f64 => 'D',
        .i1 => 'L',
        .ptr => 'c',
        else => error.UnsupportedIntrinsicType,
    };
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
    return_status: bool,
) EmitError!ValueRef {
    return emitSharedStreamBegin(
        ctx,
        builder,
        .{
            .external_static = "col6forge_formatted_read_stream_begin",
            .external_dynamic = "col6forge_formatted_read_stream_begin_dynamic",
            .internal_static = "col6forge_read_internal_stream_begin",
            .internal_dynamic = "col6forge_read_internal_stream_begin_dynamic",
        },
        .{
            .unit_value = unit_value,
            .unit_char_len = unit_char_len,
            .unit_record_count = unit_record_count,
            .is_internal = is_internal,
            .unit_i32 = unit_i32,
            .format_source = format_source,
            .mode_i32 = .{ .name = if (return_status) "1" else "0", .ty = .i32, .is_ptr = false },
        },
        lowerStaticReadStreamFormatWithBuilder,
        emitRuntimeFormatValue,
    );
}

fn lowerStaticReadStreamFormatWithBuilder(ctx: *Context, builder: anytype, fmt_ops: []const format_ir.StreamOp, is_internal: bool) EmitError!ValueRef {
    _ = is_internal;
    var fmt_buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer fmt_buf.deinit();

    for (fmt_ops) |item| {
        switch (item) {
            .literal => |text| try appendScanfLiteral(&fmt_buf, text),
            .spaces => |count| {
                var i: usize = 0;
                while (i < count) : (i += 1) try fmt_buf.append(' ');
            },
            .tab => |tab| {
                const directive: u8 = switch (tab.kind) {
                    .absolute => 'T',
                    .relative_right => 'R',
                    .relative_left => 'U',
                };
                try fmt_buf.print("%{d}{c}", .{ tab.count, directive });
            },
            .colon => {},
            .blank_control => |ctrl| {
                const directive: u8 = if (ctrl == .nulls) 'N' else 'Z';
                try fmt_buf.print("%{c}", .{directive});
            },
            .scale => |scale| try fmt_buf.print("%{d}P", .{scale}),
            .descriptor => |descriptor| switch (descriptor) {
                .int => |spec| if (spec.width > 0) {
                    try fmt_buf.print("%{d}d", .{spec.width});
                } else {
                    try fmt_buf.appendSlice("%d");
                },
                .real, .real_fixed => |spec| if (spec.width > 0) {
                    try fmt_buf.print("%{d}.{d}f", .{ spec.width, spec.precision });
                } else {
                    try fmt_buf.print("%.{d}f", .{spec.precision});
                },
                .char => |spec| {
                    const width = if (spec.width > 0) spec.width else 1;
                    try fmt_buf.writer().print("%{d}c", .{width});
                },
                .logical => |spec| if (spec.width > 0) {
                    try fmt_buf.writer().print("%{d}L", .{spec.width});
                } else {
                    try fmt_buf.appendSlice("%L");
                },
            },
            .sign_control => {},
            .reversion_anchor => try fmt_buf.append(0x03),
        }
    }

    const fmt_global = try ctx.string_pool.intern(fmt_buf.items);
    const fmt_ptr_name = try ctx.nextTemp();
    try builder.gepConstString(fmt_ptr_name, fmt_global, fmt_buf.items.len + 1);
    return .{ .name = fmt_ptr_name, .ty = .ptr, .is_ptr = true };
}

fn emitStreamNextTarget(
    ctx: *Context,
    builder: anytype,
    state: ValueRef,
    ptr: ValueRef,
    ty: llvm_types.IRType,
    char_len: usize,
) EmitError!void {
    const decl = try ctx.ensureDeclRaw("col6forge_formatted_read_stream_next", .i32, &[_]llvm_types.IRType{ .ptr, .ptr, .i32, .i32 }, false);
    try builder.callTyped(
        null,
        .i32,
        decl,
        &.{
            state,
            ptr,
            try ctx.constI32(@intCast(try formattedReadKindForType(ctx, ty))),
            try ctx.constI32(@intCast(char_len)),
        },
    );
}

fn emitStreamSlice(ctx: *Context, builder: anytype, state: ValueRef, args: []*ast.Expr) EmitError!void {
    if (args.len == 0) return;
    var expanded = try expandReadTargets(ctx, builder, args);
    defer expanded.deinit();
    for (expanded.ptrs.items, 0..) |ptr, idx| {
        try emitStreamNextTarget(ctx, builder, state, ptr, expanded.types.items[idx], expanded.char_lens.items[idx]);
    }
    try applyComplexFixups(ctx, builder, &expanded);
}

fn emitRuntimeImpliedDo(
    ctx: *Context,
    builder: anytype,
    state: ValueRef,
    implied: ast.ImpliedDo,
) EmitError!void {
    return emitSharedRuntimeImpliedDo(ctx, builder, state, implied, "fmt_read_implied", emitStreamArgs);
}

fn emitStreamArgs(ctx: *Context, builder: anytype, state: ValueRef, args: []*ast.Expr) EmitError!void {
    return emitSharedStreamArgs(ctx, builder, state, args, emitStreamSlice, emitRuntimeImpliedDo);
}

fn emitStreamFinish(ctx: *Context, builder: anytype, state: ValueRef) EmitError!ValueRef {
    return emitSharedStreamFinishStatus(ctx, builder, "col6forge_formatted_read_stream_finish", state);
}

pub fn emitReadFormattedStream(
    ctx: *Context,
    builder: anytype,
    read: ast.ReadStmt,
    unit_value: ValueRef,
    unit_char_len: ?usize,
    unit_record_count: ?usize,
    is_internal: bool,
    unit_i32: ValueRef,
    format_source: StreamFormatSource,
    return_status: bool,
) EmitError!ValueRef {
    const state = try emitStreamBegin(
        ctx,
        builder,
        unit_value,
        unit_char_len,
        unit_record_count,
        is_internal,
        unit_i32,
        format_source,
        return_status,
    );
    try emitStreamArgs(ctx, builder, state, read.args);
    return emitStreamFinish(ctx, builder, state);
}
