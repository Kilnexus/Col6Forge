const std = @import("std");
const Col6Forge = @import("Col6Forge");
const build_options = @import("build_options");
const types = @import("types.zig");
const process = @import("process.zig");
const zig_api = Col6Forge.zig_api;

const RUNTIME_CACHE_SCHEMA_VERSION: u32 = 1;

pub fn prepareRuntimeObjectCached(allocator: std.mem.Allocator, cfg: types.RuntimeBuildConfig) ![]const u8 {
    const cache_dir = cacheDirRel();
    const cwd = zig_api.cwd();
    try cwd.makePath(cache_dir);

    const cache_key = try computeRuntimeCacheKey(allocator, cfg);
    defer allocator.free(cache_key);
    const obj_name = try std.fmt.allocPrint(
        allocator,
        "col6forge_rt_v{d}_{s}.o",
        .{ RUNTIME_CACHE_SCHEMA_VERSION, cache_key },
    );
    defer allocator.free(obj_name);

    const runtime_obj_path = try std.fs.path.join(allocator, &.{ cache_dir, obj_name });
    errdefer allocator.free(runtime_obj_path);
    if (fileExists(runtime_obj_path)) return runtime_obj_path;

    const tmp_name = try std.fmt.allocPrint(
        allocator,
        "col6forge_rt_tmp_{d}_{s}.o",
        .{ zig_api.nowNs(), cache_key },
    );
    defer allocator.free(tmp_name);
    const tmp_path = try std.fs.path.join(allocator, &.{ cache_dir, tmp_name });
    defer allocator.free(tmp_path);

    try buildRuntimeObject(allocator, tmp_path, cfg);
    try cwd.rename(tmp_path, runtime_obj_path);
    return runtime_obj_path;
}

fn cacheDirRel() []const u8 {
    return "zig-cache/cc-driver/cache";
}

fn fileExists(path: []const u8) bool {
    zig_api.cwd().access(path, .{}) catch return false;
    return true;
}

fn hashFileXx64(path: []const u8) !u64 {
    var file = if (std.fs.path.isAbsolute(path))
        try zig_api.openFileAbsolute(path, .{})
    else
        try zig_api.cwd().openFile(path, .{});
    defer file.close();
    var hasher = std.hash.XxHash64.init(0);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.final();
}

fn runtimeSourceDirPath(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ build_options.project_root, "src", "runtime" });
}

fn runtimeRootSourcePath(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ build_options.project_root, "src", "runtime", "col6forge_rt.zig" });
}

fn computeRuntimeSourceKey(allocator: std.mem.Allocator) ![]const u8 {
    const runtime_source_dir = try runtimeSourceDirPath(allocator);
    defer allocator.free(runtime_source_dir);
    var dir = if (std.fs.path.isAbsolute(runtime_source_dir))
        try zig_api.openDirAbsolute(runtime_source_dir, .{ .iterate = true })
    else
        try zig_api.cwd().openDir(runtime_source_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    while (if (@hasDecl(std.fs, "cwd")) try walker.next() else try walker.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.path, ".zig")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.sort.heap([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var hasher = std.hash.XxHash64.init(0);
    for (files.items) |rel_path| {
        hasher.update(rel_path);
        const abs_rel = try std.fs.path.join(allocator, &.{ runtime_source_dir, rel_path });
        defer allocator.free(abs_rel);
        var digest = try hashFileXx64(abs_rel);
        hasher.update(std.mem.asBytes(&digest));
    }
    const final = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{final});
}

fn computeRuntimeCacheKey(allocator: std.mem.Allocator, cfg: types.RuntimeBuildConfig) ![]const u8 {
    const source_key = try computeRuntimeSourceKey(allocator);
    defer allocator.free(source_key);

    var hasher = std.hash.XxHash64.init(0);
    hasher.update(source_key);
    hasher.update(std.mem.asBytes(&RUNTIME_CACHE_SCHEMA_VERSION));
    if (cfg.target) |target| hasher.update(target);
    if (cfg.cpu) |cpu| hasher.update(cpu);
    if (cfg.ofmt) |ofmt| hasher.update(ofmt);
    const final = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{final});
}

fn buildRuntimeObject(allocator: std.mem.Allocator, runtime_obj_path: []const u8, cfg: types.RuntimeBuildConfig) !void {
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{runtime_obj_path});
    defer allocator.free(emit_arg);
    const runtime_source_path = try runtimeRootSourcePath(allocator);
    defer allocator.free(runtime_source_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "zig", "build-obj", "-ODebug", "-fPIC", emit_arg });
    if (cfg.target) |target| {
        try argv.appendSlice(allocator, &.{ "-target", target });
    }
    if (cfg.cpu) |cpu| {
        try argv.appendSlice(allocator, &.{ "-mcpu", cpu });
    }
    if (cfg.ofmt) |ofmt| {
        try argv.appendSlice(allocator, &.{ "-ofmt", ofmt });
    }
    try argv.append(allocator, runtime_source_path);
    try process.runCheckedCommand(allocator, argv.items, "zig build-obj runtime");
}
