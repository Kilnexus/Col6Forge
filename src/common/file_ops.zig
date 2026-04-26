const std = @import("std");
const zig_api = @import("../compat/zig_api.zig");

pub fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        zig_api.accessAbsolute(path, .{}) catch return false;
    } else {
        zig_api.cwd().access(path, .{}) catch return false;
    }
    return true;
}

pub fn hashFileXx64(path: []const u8) !u64 {
    var file = if (std.fs.path.isAbsolute(path))
        try zig_api.openFileAbsolute(path, .{})
    else
        try zig_api.cwd().openFile(path, .{});
    defer file.close();

    var hasher = std.hash.XxHash64.init(0);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.final();
}

pub fn copyFile(src_path: []const u8, dst_path: []const u8) !void {
    var src = if (std.fs.path.isAbsolute(src_path))
        try zig_api.openFileAbsolute(src_path, .{})
    else
        try zig_api.cwd().openFile(src_path, .{});
    defer src.close();

    var dst = if (std.fs.path.isAbsolute(dst_path))
        try zig_api.createFileAbsolute(dst_path, .{ .truncate = true })
    else
        try zig_api.cwd().createFile(dst_path, .{ .truncate = true });
    defer dst.close();

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
}
