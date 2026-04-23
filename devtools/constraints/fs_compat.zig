const std = @import("std");

threadlocal var threaded_io_ready: bool = false;
threadlocal var threaded_io: std.Io.Threaded = undefined;

pub fn defaultIo() std.Io {
    if (!threaded_io_ready) {
        threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
        threaded_io_ready = true;
    }
    return threaded_io.io();
}

fn mapOpenDirOptions(options: anytype) std.Io.Dir.OpenOptions {
    const T = @TypeOf(options);
    return .{
        .access_sub_paths = if (@hasField(T, "access_sub_paths")) options.access_sub_paths else true,
        .iterate = if (@hasField(T, "iterate")) options.iterate else false,
        .follow_symlinks = if (@hasField(T, "follow_symlinks")) options.follow_symlinks else true,
    };
}

pub const Dir = struct {
    raw: std.Io.Dir,

    pub fn close(self: Dir) void {
        self.raw.close(defaultIo());
    }

    pub fn openDir(self: Dir, path: []const u8, options: anytype) !Dir {
        return .{ .raw = try self.raw.openDir(defaultIo(), path, mapOpenDirOptions(options)) };
    }

    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
        return self.raw.readFileAlloc(defaultIo(), path, allocator, .limited(max_size));
    }

    pub fn writeFile(self: Dir, options: std.Io.Dir.WriteFileOptions) !void {
        try self.raw.writeFile(defaultIo(), options);
    }

    pub fn walk(self: Dir, allocator: std.mem.Allocator) !Walker {
        return .{ .raw = try self.raw.walk(allocator) };
    }
};

pub const Walker = struct {
    raw: std.Io.Dir.Walker,

    pub fn deinit(self: *Walker) void {
        self.raw.deinit();
    }

    pub fn next(self: *Walker) !?std.Io.Dir.Walker.Entry {
        return self.raw.next(defaultIo());
    }
};

pub fn cwd() Dir {
    return .{ .raw = std.Io.Dir.cwd() };
}

pub fn openDirAbsolute(path: []const u8, options: anytype) !Dir {
    return .{ .raw = try std.Io.Dir.openDirAbsolute(defaultIo(), path, mapOpenDirOptions(options)) };
}
