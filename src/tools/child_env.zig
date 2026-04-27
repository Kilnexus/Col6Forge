const std = @import("std");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

fn isZigCommand(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    return std.mem.eql(u8, argv[0], "zig") or std.mem.eql(u8, argv[0], "zig.exe");
}

pub fn build(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    temp_name: []const u8,
) !std.process.Environ.Map {
    const base_dir = cwd orelse ".";
    const temp_dir = try std.fs.path.join(allocator, &.{ base_dir, temp_name });
    defer allocator.free(temp_dir);
    try zig_api.cwd().makePath(temp_dir);

    var env_map = try std.process.Environ.createMap(.{ .block = .global }, allocator);
    errdefer env_map.deinit();

    const temp_env = if (cwd != null) temp_name else temp_dir;
    try env_map.put("TMP", temp_env);
    try env_map.put("TEMP", temp_env);
    try env_map.put("TMPDIR", temp_env);

    if (isZigCommand(argv)) {
        const local_cache_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zig-runner-cache" });
        defer allocator.free(local_cache_dir);
        const global_cache_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zig-runner-global-cache" });
        defer allocator.free(global_cache_dir);
        try zig_api.cwd().makePath(local_cache_dir);
        try zig_api.cwd().makePath(global_cache_dir);
        try env_map.put("ZIG_LOCAL_CACHE_DIR", local_cache_dir);
        try env_map.put("ZIG_GLOBAL_CACHE_DIR", global_cache_dir);
    }

    return env_map;
}
