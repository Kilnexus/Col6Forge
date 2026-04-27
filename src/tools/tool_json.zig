const std = @import("std");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

pub fn readReport(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(T) {
    const data = try zig_api.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(data);
    return std.json.parseFromSlice(T, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
