const std = @import("std");
const builtin = @import("builtin");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

pub fn objectExt() []const u8 {
    return if (builtin.os.tag == .windows) ".obj" else ".o";
}

pub fn defaultExeOutputPath(allocator: std.mem.Allocator, input_path: []const u8) ![]const u8 {
    const stem = fileStem(input_path);
    if (builtin.os.tag == .windows) {
        return std.fmt.allocPrint(allocator, "{s}.exe", .{stem});
    }
    return allocator.dupe(u8, stem);
}

pub fn fileStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    return base[0..dot];
}

pub fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    try zig_api.cwd().makePath(dir);
}

pub fn isFortranSource(path: []const u8) bool {
    const exts = [_][]const u8{
        ".f",
        ".for",
        ".f77",
        ".f90",
        ".f95",
        ".f03",
        ".f08",
    };
    for (exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

pub fn isCcCompilableSource(path: []const u8) bool {
    const exts = [_][]const u8{
        ".c",
        ".cc",
        ".cpp",
        ".cxx",
        ".m",
        ".mm",
        ".s",
        ".S",
        ".ll",
    };
    for (exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

pub fn makeWorkDir(allocator: std.mem.Allocator) ![]const u8 {
    const run_id = zig_api.nowNs();
    const work_rel = try std.fmt.allocPrint(
        allocator,
        "zig-cache{c}cc-driver{c}{d}",
        .{ std.fs.path.sep, std.fs.path.sep, run_id },
    );
    try zig_api.cwd().makePath(work_rel);
    return work_rel;
}
