const std = @import("std");
const input = @import("../../../input.zig");
const context = @import("../context/mod.zig");
const utils = @import("../utils.zig");
const format_items = @import("../../../../format/items.zig");
const codegen_diag = @import("../../../diagnostic.zig");

const FormatInfo = context.FormatInfo;

pub const FormatMaps = struct {
    labels: std.StringHashMap(FormatInfo),
    inline_items: std.AutoHashMap(usize, FormatInfo),
};

const AssignedFormatAlias = struct {
    target_name: []const u8,
    source_label: []const u8,
};

pub fn buildFormatMaps(
    allocator: std.mem.Allocator,
    builder: anytype,
    unit: input.ProgramUnit,
    diag_bag: *codegen_diag.Bag,
) !FormatMaps {
    var label_map = std.StringHashMap(FormatInfo).init(allocator);
    var inline_map = std.AutoHashMap(usize, FormatInfo).init(allocator);
    var assigned_aliases = std.array_list.Managed(AssignedFormatAlias).init(allocator);
    defer assigned_aliases.deinit();
    const unit_mangled = try utils.mangleProcedureUnitName(allocator, unit);
    var inline_index: usize = 0;
    try collectFormatsAndInlineFromStmts(
        allocator,
        builder,
        unit_mangled,
        unit.stmts,
        &label_map,
        &inline_map,
        &inline_index,
        &assigned_aliases,
        diag_bag,
    );
    try applyAssignedFormatAliases(&label_map, assigned_aliases.items);
    return .{ .labels = label_map, .inline_items = inline_map };
}

fn collectFormatsAndInlineFromStmts(
    allocator: std.mem.Allocator,
    builder: anytype,
    unit_mangled: []const u8,
    stmt_list: []const input.Stmt,
    label_map: *std.StringHashMap(FormatInfo),
    inline_map: *std.AutoHashMap(usize, FormatInfo),
    inline_index: *usize,
    assigned_aliases: *std.array_list.Managed(AssignedFormatAlias),
    diag_bag: *codegen_diag.Bag,
) anyerror!void {
    for (stmt_list) |stmt_item| {
        collectFormatsAndInlineFromNode(
            allocator,
            builder,
            unit_mangled,
            stmt_item.node,
            stmt_item.label,
            label_map,
            inline_map,
            inline_index,
            assigned_aliases,
            diag_bag,
        ) catch |err| {
            const info = codegen_diag.codegenErrorInfo(err);
            const line = if (stmt_item.source_line == 0) 1 else stmt_item.source_line;
            const column = if (stmt_item.source_column == 0) 1 else stmt_item.source_column;
            diag_bag.set(line, column, info.code, info.message, stmt_item.source_text);
            return err;
        };
    }
}

fn collectFormatsAndInlineFromNode(
    allocator: std.mem.Allocator,
    builder: anytype,
    unit_mangled: []const u8,
    node: input.StmtNode,
    label: ?[]const u8,
    label_map: *std.StringHashMap(FormatInfo),
    inline_map: *std.AutoHashMap(usize, FormatInfo),
    inline_index: *usize,
    assigned_aliases: *std.array_list.Managed(AssignedFormatAlias),
    diag_bag: *codegen_diag.Bag,
) anyerror!void {
    switch (node) {
        .format => |fmt| {
            const format_label = label orelse return error.FormatMissingLabel;
            const label_entry = try label_map.getOrPut(format_label);
            if (label_entry.found_existing) return error.DuplicateFormatLabel;
            const flat_items = try format_items.flattenWithReversionAnchor(allocator, fmt.items, format_items.max_flat_items);
            const format_bytes = try buildPrintfFormat(allocator, flat_items);
            const global_name = try std.fmt.allocPrint(allocator, "fmt_{s}{s}", .{ unit_mangled, format_label });
            try builder.globalString(global_name, format_bytes);
            label_entry.value_ptr.* = .{
                .items = flat_items,
                .global_name = global_name,
                .string_len = format_bytes.len + 1,
            };
        },
        .assignment => |assign| {
            if (assign.target.* != .identifier) return;
            if (assign.value.* != .literal) return;
            const lit = assign.value.literal;
            if (lit.kind != .integer) return;
            try assigned_aliases.append(.{
                .target_name = assign.target.identifier,
                .source_label = lit.text,
            });
        },
        .assign_label => |assign| {
            try assigned_aliases.append(.{
                .target_name = assign.target,
                .source_label = assign.label,
            });
        },
        .write => |write| {
            if (write.format != .inline_items) return;
            const items = write.format.inline_items;
            const key = @as(usize, @intFromPtr(items.ptr));
            const inline_entry = try inline_map.getOrPut(key);
            if (inline_entry.found_existing) return;
            const flat_items = try format_items.flattenWithReversionAnchor(allocator, items, format_items.max_flat_items);
            const format_bytes = try buildPrintfFormat(allocator, flat_items);
            const global_name = try std.fmt.allocPrint(allocator, "fmt_{s}inline{d}", .{ unit_mangled, inline_index.* });
            inline_index.* += 1;
            try builder.globalString(global_name, format_bytes);
            inline_entry.value_ptr.* = .{
                .items = flat_items,
                .global_name = global_name,
                .string_len = format_bytes.len + 1,
            };
        },
        .read => |read| {
            if (read.format != .inline_items) return;
            const items = read.format.inline_items;
            const key = @as(usize, @intFromPtr(items.ptr));
            const inline_entry = try inline_map.getOrPut(key);
            if (inline_entry.found_existing) return;
            const flat_items = try format_items.flattenWithReversionAnchor(allocator, items, format_items.max_flat_items);
            const format_bytes = try buildPrintfFormat(allocator, flat_items);
            const global_name = try std.fmt.allocPrint(allocator, "fmt_{s}inline{d}", .{ unit_mangled, inline_index.* });
            inline_index.* += 1;
            try builder.globalString(global_name, format_bytes);
            inline_entry.value_ptr.* = .{
                .items = flat_items,
                .global_name = global_name,
                .string_len = format_bytes.len + 1,
            };
        },
        .if_block => |ifb| {
            try collectFormatsAndInlineFromStmts(
                allocator,
                builder,
                unit_mangled,
                ifb.then_stmts,
                label_map,
                inline_map,
                inline_index,
                assigned_aliases,
                diag_bag,
            );
            try collectFormatsAndInlineFromStmts(
                allocator,
                builder,
                unit_mangled,
                ifb.else_stmts,
                label_map,
                inline_map,
                inline_index,
                assigned_aliases,
                diag_bag,
            );
        },
        .if_single => |ifs| {
            try collectFormatsAndInlineFromNode(
                allocator,
                builder,
                unit_mangled,
                ifs.stmt.*,
                null,
                label_map,
                inline_map,
                inline_index,
                assigned_aliases,
                diag_bag,
            );
        },
        else => {},
    }
}

fn applyAssignedFormatAliases(
    label_map: *std.StringHashMap(FormatInfo),
    aliases: []const AssignedFormatAlias,
) anyerror!void {
    for (aliases) |alias| {
        const fmt_info = label_map.get(alias.source_label) orelse continue;
        const alias_entry = try label_map.getOrPut(alias.target_name);
        if (alias_entry.found_existing) continue;
        alias_entry.value_ptr.* = fmt_info;
    }
}

fn buildPrintfFormat(allocator: std.mem.Allocator, items: []const input.FormatItem) ![]const u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    var last_non_space: ?usize = null;
    for (items, 0..) |item, idx| {
        if (item != .spaces and item != .tab and item != .colon and item != .scale and item != .blank_control and item != .sign_control and item != .reversion_anchor and item != .repeat_group and item != .reversion_offset) {
            last_non_space = idx;
        }
    }
    const cutoff = last_non_space orelse 0;
    const limit = if (last_non_space == null) 0 else cutoff + 1;

    for (items[0..limit]) |item| {
        switch (item) {
            .literal => |text| {
                try buffer.appendSlice(text);
            },
            .spaces => |count| {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    try buffer.append(' ');
                }
            },
            .tab => |tab| {
                var i: usize = 0;
                while (i < tab.count) : (i += 1) {
                    try buffer.append(' ');
                }
            },
            .colon => {},
            .int => |spec| {
                try buffer.print("%{d}d", .{spec.width});
            },
            .real => |spec| {
                try buffer.print("%{d}.{d}E", .{ spec.width, spec.precision });
            },
            .real_fixed => |spec| {
                if (spec.precision == 0) {
                    try buffer.print("%#{d}.0f", .{spec.width});
                } else {
                    try buffer.print("%{d}.{d}f", .{ spec.width, spec.precision });
                }
            },
            .char => |spec| {
                if (spec.width == 0) {
                    try buffer.print("%s", .{});
                } else {
                    try buffer.print("%{d}s", .{spec.width});
                }
            },
            .logical => |spec| {
                if (spec.width == 0) {
                    try buffer.appendSlice("%c");
                } else {
                    try buffer.print("%{d}c", .{spec.width});
                }
            },
            .repeat_group => {},
            .scale => {},
            .blank_control => {},
            .sign_control => {},
            .reversion_offset => {},
            .reversion_anchor => {},
        }
    }
    try buffer.append('\n');
    return buffer.toOwnedSlice();
}
