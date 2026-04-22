const std = @import("std");
const ast = @import("../../../../input.zig");
const llvm_types = @import("../../../types.zig");
const context = @import("../../../codegen/context/mod.zig");
const format_ir = @import("../../../../../format/stream_ir.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

const io_utils = @import("../utils.zig");
const expansion = @import("../expansion.zig");
const classic_common = @import("classic_common.zig");

const appendScanfLiteral = io_utils.appendScanfLiteral;
const appendSpaces = io_utils.appendSpaces;
const emitHeapBytes = io_utils.emitHeapBytes;
const emitStackPointerArrayFromNames = io_utils.emitStackPointerArrayFromNames;
const emitFreeAllocs = io_utils.emitFreeAllocs;
const emitKindArray = io_utils.emitKindArray;
const defaultIntegerReadKind = io_utils.defaultIntegerReadKind;
const ExpandedReadTargets = expansion.ExpandedReadTargets;
const applyComplexFixups = expansion.applyComplexFixups;

const DirectIoSpec = struct {
    unit_i32: ValueRef,
    rec_i32: ValueRef,
    recl_i32: ValueRef,
};

const CharFixup = struct {
    target_ptr: ValueRef,
    target_len: usize,
    field_width: usize,
    temp_ptr: ?ValueRef,
};

fn constI32(ctx: *Context, value: usize) EmitError!ValueRef {
    return ctx.constI32(@intCast(value));
}

pub fn emitReadFormattedLowered(
    ctx: *Context,
    builder: anytype,
    read: ast.ReadStmt,
    unit_value: ValueRef,
    unit_char_len: ?usize,
    unit_record_count: ?usize,
    is_internal: bool,
    unit_i32: ValueRef,
    fmt_ops: []const format_ir.StreamOp,
    expanded: *ExpandedReadTargets,
    return_status: bool,
    direct_spec: ?DirectIoSpec,
) EmitError!ValueRef {
    _ = read;

    var fmt_buf = std.array_list.Managed(u8).init(ctx.allocator);
    defer fmt_buf.deinit();

    var arg_ptrs = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer arg_ptrs.deinit();
    var arg_kinds = std.array_list.Managed(u8).init(ctx.allocator);
    defer arg_kinds.deinit();

    var char_fixups = std.array_list.Managed(CharFixup).init(ctx.allocator);
    defer char_fixups.deinit();

    var heap_allocs = std.array_list.Managed(ValueRef).init(ctx.allocator);
    defer heap_allocs.deinit();

    const descriptor_count = format_ir.countDescriptors(fmt_ops);
    if (descriptor_count == 0) {
        for (fmt_ops) |item| {
            switch (item) {
                .literal => |text| {
                    try appendScanfLiteral(&fmt_buf, text);
                },
                .spaces => |count| {
                    if (count > 0) try appendSpaces(&fmt_buf, count);
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
                .sign_control, .scale, .reversion_anchor => {},
                else => {},
            }
        }
    } else {
        try emitReadDescriptorPasses(ctx, builder, fmt_ops, expanded, &fmt_buf, &arg_ptrs, &arg_kinds, &char_fixups, &heap_allocs);
    }

    const fmt_global = try ctx.string_pool.intern(fmt_buf.items);
    const fmt_ptr_name = try ctx.nextTemp();
    try builder.gepConstString(fmt_ptr_name, fmt_global, fmt_buf.items.len + 1);

    const fmt_ptr = ValueRef{ .name = fmt_ptr_name, .ty = .ptr, .is_ptr = true };
    const ptr_array = try emitStackPointerArrayFromNames(ctx, builder, arg_ptrs.items);
    const kinds_ptr = try emitKindArray(ctx, builder, arg_kinds.items);
    const arg_count_val = try constI32(ctx, arg_ptrs.items.len);

    var status_val = ValueRef{ .name = "0", .ty = .i32, .is_ptr = false };

    if (direct_spec) |direct| {
        const mode_val = ValueRef{ .name = if (return_status) "1" else "0", .ty = .i32, .is_ptr = false };
        const read_name = try ctx.ensureDeclRaw("col6forge_read_direct_internal_core", .i32, &[_]llvm_types.IRType{ .i32, .i32, .i32, .ptr, .ptr, .ptr, .i32, .i32 }, false);
        const tmp = try ctx.nextTemp();
        try builder.callTyped(tmp, .i32, read_name, &.{ direct.unit_i32, direct.rec_i32, direct.recl_i32, fmt_ptr, ptr_array, kinds_ptr, arg_count_val, mode_val });
        status_val = .{ .name = tmp, .ty = .i32, .is_ptr = false };
    } else if (is_internal) {
        const len_val = try constI32(ctx, unit_char_len orelse return error.MissingFormatLabel);
        const count_num: usize = if (unit_record_count) |count| if (count > 1) count else 1 else 1;
        const count_val = try constI32(ctx, count_num);
        const read_name = try ctx.ensureDeclRaw("col6forge_read_internal_core", .i32, &[_]llvm_types.IRType{ .ptr, .i32, .i32, .ptr, .ptr, .ptr, .i32 }, false);
        if (return_status) {
            const tmp = try ctx.nextTemp();
            try builder.callTyped(tmp, .i32, read_name, &.{ unit_value, len_val, count_val, fmt_ptr, ptr_array, kinds_ptr, arg_count_val });
            status_val = .{ .name = tmp, .ty = .i32, .is_ptr = false };
        } else {
            try builder.callTyped(null, .i32, read_name, &.{ unit_value, len_val, count_val, fmt_ptr, ptr_array, kinds_ptr, arg_count_val });
        }
    } else {
        const mode_val = ValueRef{ .name = if (return_status) "1" else "0", .ty = .i32, .is_ptr = false };
        const read_name = try ctx.ensureDeclRaw("col6forge_formatted_read_core", .i32, &[_]llvm_types.IRType{ .i32, .ptr, .ptr, .ptr, .i32, .i32 }, false);
        if (return_status) {
            const tmp = try ctx.nextTemp();
            try builder.callTyped(tmp, .i32, read_name, &.{ unit_i32, fmt_ptr, ptr_array, kinds_ptr, arg_count_val, mode_val });
            status_val = .{ .name = tmp, .ty = .i32, .is_ptr = false };
        } else {
            try builder.callTyped(null, .i32, read_name, &.{ unit_i32, fmt_ptr, ptr_array, kinds_ptr, arg_count_val, mode_val });
        }
    }

    try applyComplexFixups(ctx, builder, expanded);

    const false_i1 = ValueRef{ .name = "false", .ty = .i1, .is_ptr = false };
    const space_i8 = ValueRef{ .name = "32", .ty = .i8, .is_ptr = false };

    for (char_fixups.items) |fixup| {
        if (fixup.target_len == 0) continue;

        if (fixup.temp_ptr) |temp_ptr| {
            const start = if (fixup.field_width > fixup.target_len) fixup.field_width - fixup.target_len else 0;
            const src_gep = try ctx.nextTemp();
            try builder.gep(src_gep, .i8, temp_ptr, try constI32(ctx, start));
            const src_ptr = ValueRef{ .name = src_gep, .ty = .ptr, .is_ptr = true };

            const memcpy_name = try ctx.ensureDeclRaw("llvm.memcpy.p0.p0.i32", .void, &[_]llvm_types.IRType{ .ptr, .ptr, .i32, .i1 }, false);
            try builder.callTyped(null, .void, memcpy_name, &.{ fixup.target_ptr, src_ptr, try constI32(ctx, fixup.target_len), false_i1 });
        } else if (fixup.field_width < fixup.target_len) {
            const pad_len = fixup.target_len - fixup.field_width;
            if (pad_len == 0) continue;

            const dst_gep = try ctx.nextTemp();
            try builder.gep(dst_gep, .i8, fixup.target_ptr, try constI32(ctx, fixup.field_width));
            const dst_ptr = ValueRef{ .name = dst_gep, .ty = .ptr, .is_ptr = true };

            const memset_name = try ctx.ensureDeclRaw("llvm.memset.p0.i32", .void, &[_]llvm_types.IRType{ .ptr, .i8, .i32, .i1 }, false);
            try builder.callTyped(null, .void, memset_name, &.{ dst_ptr, space_i8, try constI32(ctx, pad_len), false_i1 });
        }
    }

    try emitFreeAllocs(ctx, builder, heap_allocs.items);

    return status_val;
}

fn emitReadDescriptorPasses(
    ctx: *Context,
    builder: anytype,
    fmt_ops: []const format_ir.StreamOp,
    expanded: *ExpandedReadTargets,
    fmt_buf: *std.array_list.Managed(u8),
    arg_ptrs: *std.array_list.Managed([]const u8),
    arg_kinds: *std.array_list.Managed(u8),
    char_fixups: *std.array_list.Managed(CharFixup),
    heap_allocs: *std.array_list.Managed(ValueRef),
) EmitError!void {
    const State = struct {
        expanded: *ExpandedReadTargets,
        fmt_buf: *std.array_list.Managed(u8),
        arg_ptrs: *std.array_list.Managed([]const u8),
        arg_kinds: *std.array_list.Managed(u8),
        char_fixups: *std.array_list.Managed(CharFixup),
        heap_allocs: *std.array_list.Managed(ValueRef),
        arg_index: usize = 0,

        pub fn hasRemaining(self: *@This()) bool {
            return self.arg_index < self.expanded.ptrs.items.len;
        }

        pub fn beginReversionPass(self: *@This(), _: *Context, _: anytype) EmitError!void {
            try self.fmt_buf.append('\n');
        }

        pub fn beginPass(_: *@This(), _: *Context, _: anytype, _: usize, _: usize) EmitError!void {}

        pub fn handleItem(self: *@This(), ctx_inner: *Context, builder_inner: anytype, item: format_ir.StreamOp) EmitError!bool {
            switch (item) {
                .literal => |text| try appendScanfLiteral(self.fmt_buf, text),
                .spaces => |count| if (count > 0) try appendSpaces(self.fmt_buf, count),
                .tab => |tab| {
                    const directive: u8 = switch (tab.kind) {
                        .absolute => 'T',
                        .relative_right => 'R',
                        .relative_left => 'U',
                    };
                    try self.fmt_buf.print("%{d}{c}", .{ tab.count, directive });
                },
                .colon => {},
                .descriptor => |descriptor| switch (descriptor) {
                    .int => |spec| {
                        if (!self.hasRemaining()) return true;
                        const width = if (spec.width > 0) spec.width else 0;
                        if (width > 0) {
                            try self.fmt_buf.print("%{d}d", .{width});
                        } else {
                            try self.fmt_buf.appendSlice("%d");
                        }
                        try self.arg_ptrs.append(self.expanded.ptrs.items[self.arg_index].name);
                        try self.arg_kinds.append(defaultIntegerReadKind(ctx_inner));
                        self.arg_index += 1;
                    },
                    .real, .real_fixed => |spec| {
                        if (!self.hasRemaining()) return true;
                        const ty = self.expanded.types.items[self.arg_index];
                        const width = if (spec.width > 0) spec.width else 0;
                        const fmt_spec = if (ty == .f64) "lf" else "f";
                        if (width > 0) {
                            try self.fmt_buf.print("%{d}.{d}{s}", .{ width, spec.precision, fmt_spec });
                        } else {
                            try self.fmt_buf.print("%.{d}{s}", .{ spec.precision, fmt_spec });
                        }
                        try self.arg_ptrs.append(self.expanded.ptrs.items[self.arg_index].name);
                        try self.arg_kinds.append(if (ty == .f64) 'D' else 'f');
                        self.arg_index += 1;
                    },
                    .char => |spec| {
                        if (!self.hasRemaining()) return true;
                        const target_ptr = self.expanded.ptrs.items[self.arg_index];
                        const target_len = self.expanded.char_lens.items[self.arg_index];
                        const width = if (spec.width > 0) spec.width else if (target_len > 0) target_len else 1;
                        try self.fmt_buf.print("%{d}c", .{width});
                        if (target_len > 0 and width > target_len) {
                            const tmp_ptr = try emitHeapBytes(ctx_inner, builder_inner, width);
                            try self.heap_allocs.append(tmp_ptr);
                            try self.arg_ptrs.append(tmp_ptr.name);
                            try self.arg_kinds.append('c');
                            try self.char_fixups.append(.{
                                .target_ptr = target_ptr,
                                .target_len = target_len,
                                .field_width = width,
                                .temp_ptr = tmp_ptr,
                            });
                        } else {
                            try self.arg_ptrs.append(target_ptr.name);
                            try self.arg_kinds.append('c');
                            if (target_len > 0 and width < target_len) {
                                try self.char_fixups.append(.{
                                    .target_ptr = target_ptr,
                                    .target_len = target_len,
                                    .field_width = width,
                                    .temp_ptr = null,
                                });
                            }
                        }
                        self.arg_index += 1;
                    },
                    .logical => |spec| {
                        if (!self.hasRemaining()) return true;
                        const width = if (spec.width > 0) spec.width else 0;
                        if (width > 0) {
                            try self.fmt_buf.print("%{d}L", .{width});
                        } else {
                            try self.fmt_buf.appendSlice("%L");
                        }
                        try self.arg_ptrs.append(self.expanded.ptrs.items[self.arg_index].name);
                        try self.arg_kinds.append('L');
                        self.arg_index += 1;
                    },
                },
                .scale => |value| try self.fmt_buf.print("%{d}P", .{value}),
                .blank_control => |ctrl| {
                    const directive: u8 = if (ctrl == .nulls) 'N' else 'Z';
                    try self.fmt_buf.print("%{c}", .{directive});
                },
                .sign_control => {},
                .reversion_anchor => {},
            }
            return false;
        }
    };

    var state: State = .{
        .expanded = expanded,
        .fmt_buf = fmt_buf,
        .arg_ptrs = arg_ptrs,
        .arg_kinds = arg_kinds,
        .char_fixups = char_fixups,
        .heap_allocs = heap_allocs,
    };
    try classic_common.emitDescriptorPasses(ctx, builder, fmt_ops, &state);
}
