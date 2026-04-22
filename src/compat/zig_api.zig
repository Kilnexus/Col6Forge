const std = @import("std");

const has_legacy_fs = @hasDecl(std.fs, "cwd");

threadlocal var threaded_io_ready: bool = false;
threadlocal var threaded_io: if (has_legacy_fs) void else std.Io.Threaded = if (has_legacy_fs) {} else undefined;

fn io() std.Io {
    if (comptime has_legacy_fs) unreachable;
    if (!threaded_io_ready) {
        threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
        threaded_io_ready = true;
    }
    return threaded_io.io();
}

pub fn defaultIo() std.Io {
    return io();
}

pub const File = if (has_legacy_fs) struct {
    raw: std.fs.File,

    pub fn stdout() File {
        return .{ .raw = std.fs.File.stdout() };
    }

    pub fn stderr() File {
        return .{ .raw = std.fs.File.stderr() };
    }

    pub fn stdin() File {
        return .{ .raw = std.fs.File.stdin() };
    }

    pub fn close(self: File) void {
        self.raw.close();
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.raw.writeAll(bytes);
    }

    pub fn writer(self: File, buffer: []u8) @TypeOf(self.raw.writer(buffer)) {
        return self.raw.writer(buffer);
    }

    pub fn isTty(self: File) bool {
        return self.raw.isTty();
    }
} else struct {
    raw: std.Io.File,

    pub fn stdout() File {
        return .{ .raw = std.Io.File.stdout() };
    }

    pub fn stderr() File {
        return .{ .raw = std.Io.File.stderr() };
    }

    pub fn stdin() File {
        return .{ .raw = std.Io.File.stdin() };
    }

    pub fn close(self: File) void {
        self.raw.close(io());
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.raw.writeStreamingAll(io(), bytes);
    }

    pub fn writer(self: File, buffer: []u8) @TypeOf(self.raw.writer(io(), buffer)) {
        return self.raw.writer(io(), buffer);
    }

    pub fn isTty(self: File) bool {
        return self.raw.isTty(io()) catch false;
    }
};

pub const Dir = if (has_legacy_fs) struct {
    raw: std.fs.Dir,

    pub fn cwd() Dir {
        return .{ .raw = std.fs.cwd() };
    }

    pub fn createFile(self: Dir, path: []const u8, flags: anytype) !File {
        return .{ .raw = try self.raw.createFile(path, flags) };
    }

    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
        return self.raw.readFileAlloc(allocator, path, max_size);
    }

    pub fn makePath(self: Dir, path: []const u8) !void {
        try self.raw.makePath(path);
    }
} else struct {
    raw: std.Io.Dir,

    pub fn cwd() Dir {
        return .{ .raw = std.Io.Dir.cwd() };
    }

    pub fn createFile(self: Dir, path: []const u8, flags: anytype) !File {
        return .{ .raw = try self.raw.createFile(io(), path, flags) };
    }

    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
        return self.raw.readFileAlloc(io(), path, allocator, .limited(max_size));
    }

    pub fn makePath(self: Dir, path: []const u8) !void {
        try self.raw.makePath(io(), path);
    }
};

pub fn cwd() Dir {
    return Dir.cwd();
}

pub fn nowNs() i128 {
    if (@hasDecl(std.time, "nanoTimestamp")) {
        return std.time.nanoTimestamp();
    }
    return @as(i128, @intCast(std.Io.Clock.awake.now(io()).nanoseconds));
}
