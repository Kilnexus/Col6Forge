const std = @import("std");

const has_legacy_fs = @hasDecl(std.fs, "cwd");

threadlocal var threaded_io_ready: bool = false;
threadlocal var threaded_io: if (has_legacy_fs) void else std.Io.Threaded = if (has_legacy_fs) {} else undefined;

fn mapCreateFileOptions(flags: anytype) std.Io.Dir.CreateFileOptions {
    const T = @TypeOf(flags);
    return .{
        .read = if (@hasField(T, "read")) flags.read else false,
        .truncate = if (@hasField(T, "truncate")) flags.truncate else true,
        .exclusive = if (@hasField(T, "exclusive")) flags.exclusive else false,
    };
}

fn mapOpenFileOptions(flags: anytype) std.Io.Dir.OpenFileOptions {
    const T = @TypeOf(flags);
    return .{
        .mode = if (@hasField(T, "mode")) flags.mode else .read_only,
    };
}

fn mapOpenDirOptions(options: anytype) std.Io.Dir.OpenOptions {
    const T = @TypeOf(options);
    return .{
        .access_sub_paths = if (@hasField(T, "access_sub_paths")) options.access_sub_paths else true,
        .iterate = if (@hasField(T, "iterate")) options.iterate else false,
        .follow_symlinks = if (@hasField(T, "follow_symlinks")) options.follow_symlinks else true,
    };
}

fn mapAccessOptions(options: anytype) std.Io.Dir.AccessOptions {
    const T = @TypeOf(options);
    return .{
        .follow_symlinks = if (@hasField(T, "follow_symlinks")) options.follow_symlinks else true,
        .read = if (@hasField(T, "read")) options.read else false,
        .write = if (@hasField(T, "write")) options.write else false,
        .execute = if (@hasField(T, "execute")) options.execute else false,
    };
}

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

    pub fn read(self: File, buffer: []u8) !usize {
        return self.raw.read(buffer);
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

    pub fn read(self: File, buffer: []u8) !usize {
        return self.raw.readStreaming(io(), &.{buffer});
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

    pub fn rename(self: Dir, old_path: []const u8, new_path: []const u8) !void {
        try self.raw.rename(old_path, new_path);
    }

    pub fn deleteFile(self: Dir, path: []const u8) !void {
        try self.raw.deleteFile(path);
    }

    pub fn access(self: Dir, path: []const u8, options: anytype) !void {
        try self.raw.access(path, options);
    }

    pub fn openFile(self: Dir, path: []const u8, options: anytype) !File {
        return .{ .raw = try self.raw.openFile(path, options) };
    }

    pub fn openDir(self: Dir, path: []const u8, options: anytype) !Dir {
        return .{ .raw = try self.raw.openDir(path, options) };
    }

    pub fn close(self: Dir) void {
        self.raw.close();
    }

    pub fn walk(self: Dir, allocator: std.mem.Allocator) @TypeOf(self.raw.walk(allocator)) {
        return self.raw.walk(allocator);
    }
} else struct {
    raw: std.Io.Dir,

    pub fn cwd() Dir {
        return .{ .raw = std.Io.Dir.cwd() };
    }

    pub fn createFile(self: Dir, path: []const u8, flags: anytype) !File {
        return .{ .raw = try self.raw.createFile(io(), path, mapCreateFileOptions(flags)) };
    }

    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
        return self.raw.readFileAlloc(io(), path, allocator, .limited(max_size));
    }

    pub fn makePath(self: Dir, path: []const u8) !void {
        try self.raw.createDirPath(io(), path);
    }

    pub fn rename(self: Dir, old_path: []const u8, new_path: []const u8) !void {
        try std.Io.Dir.rename(self.raw, old_path, self.raw, new_path, io());
    }

    pub fn deleteFile(self: Dir, path: []const u8) !void {
        try self.raw.deleteFile(io(), path);
    }

    pub fn access(self: Dir, path: []const u8, options: anytype) !void {
        try self.raw.access(io(), path, mapAccessOptions(options));
    }

    pub fn openFile(self: Dir, path: []const u8, options: anytype) !File {
        return .{ .raw = try self.raw.openFile(io(), path, mapOpenFileOptions(options)) };
    }

    pub fn openDir(self: Dir, path: []const u8, options: anytype) !Dir {
        return .{ .raw = try self.raw.openDir(io(), path, mapOpenDirOptions(options)) };
    }

    pub fn close(self: Dir) void {
        self.raw.close(io());
    }

    pub fn walk(self: Dir, allocator: std.mem.Allocator) @TypeOf(self.raw.walk(allocator)) {
        return self.raw.walk(allocator);
    }
};

pub fn cwd() Dir {
    return Dir.cwd();
}

pub fn openFileAbsolute(path: []const u8, options: anytype) !File {
    if (comptime has_legacy_fs) {
        return .{ .raw = try std.fs.openFileAbsolute(path, options) };
    }
    return .{ .raw = try std.Io.Dir.openFileAbsolute(io(), path, mapOpenFileOptions(options)) };
}

pub fn openDirAbsolute(path: []const u8, options: anytype) !Dir {
    if (comptime has_legacy_fs) {
        return .{ .raw = try std.fs.openDirAbsolute(path, options) };
    }
    return .{ .raw = try std.Io.Dir.openDirAbsolute(io(), path, mapOpenDirOptions(options)) };
}

pub fn nowNs() i128 {
    if (@hasDecl(std.time, "nanoTimestamp")) {
        return std.time.nanoTimestamp();
    }
    return @as(i128, @intCast(std.Io.Clock.awake.now(io()).nanoseconds));
}
