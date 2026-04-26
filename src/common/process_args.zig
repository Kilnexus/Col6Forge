const std = @import("std");

pub fn allocArgs(allocator: std.mem.Allocator, args_src: std.process.Args) ![][]const u8 {
    var it = try std.process.Args.Iterator.initAllocator(args_src, allocator);
    defer it.deinit();

    var args = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }

    while (it.next()) |arg| {
        try args.append(try allocator.dupe(u8, arg));
    }

    return args.toOwnedSlice();
}

pub fn freeArgs(allocator: std.mem.Allocator, args: [][]const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, init: std.process.Init, name: []const u8) !?[]u8 {
    const value = init.environ_map.get(name) orelse return null;
    return try allocator.dupe(u8, value);
}
