const std = @import("std");
const builtin = @import("builtin");

const has_legacy_fs = @hasDecl(std.fs, "cwd");

threadlocal var threaded_io_ready: bool = false;
threadlocal var threaded_io: if (has_legacy_fs) void else std.Io.Threaded = if (has_legacy_fs) {} else undefined;

fn optionFieldOr(options: anytype, comptime field_name: []const u8, default_value: anytype) @TypeOf(default_value) {
    const T = @TypeOf(options);
    return if (@hasField(T, field_name)) @field(options, field_name) else default_value;
}

fn mapCreateFileOptions(flags: anytype) std.Io.Dir.CreateFileOptions {
    return .{
        .read = optionFieldOr(flags, "read", false),
        .truncate = optionFieldOr(flags, "truncate", true),
        .exclusive = optionFieldOr(flags, "exclusive", false),
    };
}

fn mapOpenFileOptions(flags: anytype) std.Io.Dir.OpenFileOptions {
    return .{
        .mode = optionFieldOr(flags, "mode", .read_only),
    };
}

fn mapOpenDirOptions(options: anytype) std.Io.Dir.OpenOptions {
    return .{
        .access_sub_paths = optionFieldOr(options, "access_sub_paths", true),
        .iterate = optionFieldOr(options, "iterate", false),
        .follow_symlinks = optionFieldOr(options, "follow_symlinks", true),
    };
}

fn mapAccessOptions(options: anytype) std.Io.Dir.AccessOptions {
    return .{
        .follow_symlinks = optionFieldOr(options, "follow_symlinks", true),
        .read = optionFieldOr(options, "read", false),
        .write = optionFieldOr(options, "write", false),
        .execute = optionFieldOr(options, "execute", false),
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

    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        return self.raw.readToEndAlloc(allocator, max_bytes);
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.raw.writeAll(bytes);
    }

    pub fn setExecutable(self: File) !void {
        if (builtin.os.tag == .windows) return;
        try self.raw.chmod(0o777);
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
        return self.raw.readStreaming(io(), &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
    }

    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);

        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&buffer);
            if (n == 0) break;
            if (bytes.items.len + n > max_bytes) return error.StreamTooLong;
            try bytes.appendSlice(allocator, buffer[0..n]);
        }

        return bytes.toOwnedSlice(allocator);
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.raw.writeStreamingAll(io(), bytes);
    }

    pub fn setExecutable(self: File) !void {
        if (builtin.os.tag == .windows) return;
        try self.raw.setPermissions(io(), .executable_file);
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

    pub fn deleteTree(self: Dir, path: []const u8) !void {
        try self.raw.deleteTree(path);
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

    pub fn deleteTree(self: Dir, path: []const u8) !void {
        try self.raw.deleteTree(io(), path);
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

pub fn createFileAbsolute(path: []const u8, flags: anytype) !File {
    if (comptime has_legacy_fs) {
        return .{ .raw = try std.fs.createFileAbsolute(path, flags) };
    }
    return .{ .raw = try std.Io.Dir.createFileAbsolute(io(), path, mapCreateFileOptions(flags)) };
}

pub fn deleteFileAbsolute(path: []const u8) !void {
    if (comptime has_legacy_fs) {
        try std.fs.deleteFileAbsolute(path);
        return;
    }
    try std.Io.Dir.deleteFileAbsolute(io(), path);
}

pub fn deleteTreePath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        try cwd().deleteTree(path);
        return;
    }
    const parent_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
    const base_name = std.fs.path.basename(path);
    var parent = try openDirAbsolute(parent_path, .{});
    defer parent.close();
    try parent.deleteTree(base_name);
}

pub fn accessAbsolute(path: []const u8, options: anytype) !void {
    if (comptime has_legacy_fs) {
        try std.fs.accessAbsolute(path, options);
        return;
    }
    try std.Io.Dir.accessAbsolute(io(), path, mapAccessOptions(options));
}

pub fn nowNs() i128 {
    if (@hasDecl(std.time, "nanoTimestamp")) {
        return std.time.nanoTimestamp();
    }
    return @as(i128, @intCast(std.Io.Clock.awake.now(io()).nanoseconds));
}

pub fn unixMs() i64 {
    if (@hasDecl(std.time, "milliTimestamp")) {
        return std.time.milliTimestamp();
    }
    return @intCast(@divTrunc(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms));
}

pub fn createProcessEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    const Block = std.process.Environ.Block;
    if (comptime @hasDecl(Block, "global")) {
        return std.process.Environ.createMap(.{ .block = Block.global }, allocator);
    }

    if (comptime builtin.os.tag == .linux) {
        return createLinuxProcessEnvMap(allocator);
    }

    // Zig 0.16 removed the synthetic POSIX global environment block. Keep
    // unsupported targets buildable with an empty replacement environment.
    return std.process.Environ.createMap(std.process.Environ.empty, allocator);
}

pub fn runnerCacheDir(allocator: std.mem.Allocator, base_dir: []const u8, name: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .linux) {
        const hash = std.hash.Wyhash.hash(0, base_dir);
        const cache_name = trimLeadingDots(name);
        const dir_name = try std.fmt.allocPrint(allocator, "col6forge-{x}-{s}", .{ hash, cache_name });
        defer allocator.free(dir_name);
        return std.fs.path.join(allocator, &.{ "/tmp", dir_name });
    }
    return std.fs.path.join(allocator, &.{ base_dir, name });
}

pub fn runnerWorkDir(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    namespace: []const u8,
    name: []const u8,
) ![]u8 {
    if (comptime builtin.os.tag == .linux) {
        const hash = std.hash.Wyhash.hash(0, root_path);
        const dir_name = try std.fmt.allocPrint(allocator, "col6forge-{x}-{s}-{s}", .{ hash, namespace, name });
        defer allocator.free(dir_name);
        return std.fs.path.join(allocator, &.{ "/tmp", dir_name });
    }
    return std.fs.path.join(allocator, &.{ root_path, "zig-cache", namespace, name });
}

pub const ResolvedArgv = struct {
    argv: []const []const u8,
    owned_argv: ?[][]const u8 = null,
    owned_arg0: ?[]u8 = null,

    pub fn deinit(self: ResolvedArgv, allocator: std.mem.Allocator) void {
        if (self.owned_argv) |items| allocator.free(items);
        if (self.owned_arg0) |arg0| allocator.free(arg0);
    }
};

pub fn resolveZigArgv(allocator: std.mem.Allocator, argv: []const []const u8) !ResolvedArgv {
    if (argv.len == 0 or !isBareZigCommand(argv[0])) {
        return .{ .argv = argv };
    }

    const zig_exe = try resolveZigExecutable(allocator);
    errdefer allocator.free(zig_exe);
    const owned_argv = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(owned_argv);
    for (argv, 0..) |arg, idx| owned_argv[idx] = arg;
    owned_argv[0] = zig_exe;
    return .{
        .argv = owned_argv,
        .owned_argv = owned_argv,
        .owned_arg0 = zig_exe,
    };
}

pub fn resolveZigExecutable(allocator: std.mem.Allocator) ![]u8 {
    var env_map = try createProcessEnvMap(allocator);
    defer env_map.deinit();

    if (env_map.get("COL6FORGE_ZIG_EXE")) |value| {
        if (value.len != 0) return allocator.dupe(u8, value);
    }
    if (env_map.get("ZIG_EXE")) |value| {
        if (value.len != 0) return allocator.dupe(u8, value);
    }
    if (env_map.get("PATH")) |value| {
        if (try findZigInPath(allocator, value)) |path| return path;
    }

    return allocator.dupe(u8, if (builtin.os.tag == .windows) "zig.exe" else "zig");
}

fn isBareZigCommand(arg0: []const u8) bool {
    return std.mem.eql(u8, arg0, "zig") or std.mem.eql(u8, arg0, "zig.exe");
}

fn findZigInPath(allocator: std.mem.Allocator, path_value: []const u8) !?[]u8 {
    const delimiter: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_value, delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (try findZigInDir(allocator, dir)) |path| return path;
    }
    return null;
}

fn findZigInDir(allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const names: []const []const u8 = if (builtin.os.tag == .windows) &.{ "zig.exe", "zig" } else &.{"zig"};
    for (names) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        errdefer allocator.free(candidate);
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        accessAbsolute(path, .{}) catch return false;
        return true;
    }
    cwd().access(path, .{}) catch return false;
    return true;
}

fn trimLeadingDots(name: []const u8) []const u8 {
    var start: usize = 0;
    while (start < name.len and name[start] == '.') : (start += 1) {}
    return name[start..];
}

fn createLinuxProcessEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var file = try openFileAbsolute("/proc/self/environ", .{ .mode = .read_only });
    defer file.close();

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&buffer);
        if (n == 0) break;
        try bytes.appendSlice(allocator, buffer[0..n]);
    }

    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();

    var start: usize = 0;
    while (start < bytes.items.len) {
        const rest = bytes.items[start..];
        const rel_end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        const entry = rest[0..rel_end];
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            if (eq != 0) {
                try map.put(entry[0..eq], entry[eq + 1 ..]);
            }
        }
        start += rel_end + 1;
    }

    return map;
}
