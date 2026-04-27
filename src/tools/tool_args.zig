const std = @import("std");

pub fn allocArgs(allocator: std.mem.Allocator, args_src: std.process.Args) ![][]const u8 {
    var it = try std.process.Args.Iterator.initAllocator(args_src, allocator);
    defer it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    while (it.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    return args.toOwnedSlice(allocator);
}

pub fn freeArgs(allocator: std.mem.Allocator, args: [][]const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}
