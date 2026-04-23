const std = @import("std");
const fs_compat = @import("../fs_compat.zig");

pub const max_lines: usize = 1000;

const RootSpec = struct {
    path: []const u8,
};

const root_specs = [_]RootSpec{
    .{ .path = "src" },
    .{ .path = "devtools/constraints" },
};

const exact_specs = [_][]const u8{
    "build.zig",
};

pub fn run(allocator: std.mem.Allocator) !usize {
    var failures: usize = 0;
    for (root_specs) |spec| {
        try scanRoot(allocator, spec.path, &failures);
    }
    for (exact_specs) |path| {
        try checkFile(allocator, path, &failures);
    }
    return failures;
}

fn scanRoot(allocator: std.mem.Allocator, root: []const u8, failures: *usize) !void {
    var dir = try fs_compat.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const rel_path_native = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(rel_path_native);
        const rel_path = try normalizePath(allocator, rel_path_native);
        defer allocator.free(rel_path);

        try checkPath(allocator, rel_path, failures);
    }
}

fn checkFile(allocator: std.mem.Allocator, rel_path: []const u8, failures: *usize) !void {
    try checkPath(allocator, rel_path, failures);
}

fn checkPath(allocator: std.mem.Allocator, rel_path: []const u8, failures: *usize) !void {
    const text = try fs_compat.cwd().readFileAlloc(allocator, rel_path, 16 * 1024 * 1024);
    defer allocator.free(text);

    const line_count = countLines(text);
    if (line_count <= max_lines) return;

    std.log.err(
        "{s}: [AR-LINE-001] forbidden file line budget overflow: {d} lines exceeds hard limit {d}",
        .{ rel_path, line_count, max_lines },
    );
    failures.* += 1;
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return out;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    const newline_count = std.mem.count(u8, text, "\n");
    return if (text[text.len - 1] == '\n') newline_count else newline_count + 1;
}

test "countLines matches line-oriented expectations" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("a"));
    try std.testing.expectEqual(@as(usize, 1), countLines("a\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb"));
    try std.testing.expectEqual(@as(usize, 2), countLines("a\nb\n"));
}
