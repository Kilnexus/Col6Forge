const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const logical_line = @import("../../../logical_line.zig");

pub fn consumeNoArgCheckDirectiveLine(
    arena: std.mem.Allocator,
    line: logical_line.LogicalLine,
    pending: *std.StringHashMap(void),
) !bool {
    const trimmed = std.mem.trim(u8, line.text, " \t");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "!gcc$")) return false;
    if (std.ascii.indexOfIgnoreCase(trimmed, "attributes") == null) return false;
    if (std.ascii.indexOfIgnoreCase(trimmed, "no_arg_check") == null) return false;
    const sep = std.mem.indexOf(u8, trimmed, "::") orelse return false;
    var rest = trimmed[sep + 2 ..];
    while (true) {
        const next_sep = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const raw_name = std.mem.trim(u8, rest[0..next_sep], " \t");
        if (raw_name.len != 0) {
            const lowered = try arena.alloc(u8, raw_name.len);
            for (raw_name, 0..) |ch, idx| lowered[idx] = std.ascii.toLower(ch);
            try pending.put(lowered, {});
        }
        if (next_sep == rest.len) break;
        rest = rest[next_sep + 1 ..];
    }
    return true;
}

pub fn applyPendingNoArgCheck(decl_node: *ast.Decl, pending: *const std.StringHashMap(void)) void {
    switch (decl_node.*) {
        .type_decl => |*type_decl| {
            for (type_decl.items) |*item| {
                if (pendingContainsName(pending, item.name)) item.no_arg_check = true;
            }
        },
        .procedure => |*procedure_decl| {
            for (procedure_decl.items) |*item| {
                if (pendingContainsName(pending, item.name)) item.no_arg_check = true;
            }
        },
        .dimension => |*dimension_decl| {
            for (dimension_decl.items) |*item| {
                if (pendingContainsName(pending, item.name)) item.no_arg_check = true;
            }
        },
        else => {},
    }
}

pub fn applyPendingNoArgCheckToDecls(decls: []ast.Decl, pending: *const std.StringHashMap(void)) void {
    for (decls) |*decl_node| {
        applyPendingNoArgCheck(decl_node, pending);
    }
}

fn pendingContainsName(pending: *const std.StringHashMap(void), name: []const u8) bool {
    var key_buf: [128]u8 = undefined;
    if (name.len <= key_buf.len) {
        for (name, 0..) |ch, idx| key_buf[idx] = std.ascii.toLower(ch);
        return pending.contains(key_buf[0..name.len]);
    }
    var it = pending.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return true;
    }
    return false;
}
