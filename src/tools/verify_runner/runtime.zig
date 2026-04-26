const common = @import("common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const fallback_policy = common.fallback_policy;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const zig_api = common.zig_api;
const runner_io = @import("runner_io.zig");
const log_state_mod = @import("../log_state.zig");

const ProcessResult = runner_io.ProcessResult;
const runProcessCapture = runner_io.runProcessCapture;
const runZigCcLinkWithWindowsRetry = runner_io.runZigCcLinkWithWindowsRetry;
const isZeroExit = runner_io.isZeroExit;
const fileExistsAbsolute = runner_io.fileExistsAbsolute;
const deleteFileAbsoluteIfExists = runner_io.deleteFileAbsoluteIfExists;
const deleteWindowsLinkSidecarsIfExists = runner_io.deleteWindowsLinkSidecarsIfExists;
const runtimeBackendTag = common.runtimeBackendTag;
pub const LogState = log_state_mod.LogState;

const Stopwatch = struct {
    start_ns: i128,

    fn start() Stopwatch {
        return .{ .start_ns = zig_api.nowNs() };
    }

    fn read(self: *const Stopwatch) u64 {
        const elapsed = zig_api.nowNs() - self.start_ns;
        return @intCast(if (elapsed > 0) elapsed else 0);
    }
};

pub const Progress = struct {
    total: usize,
    started: std.atomic.Value(usize),
    completed: std.atomic.Value(usize),
    timer: Stopwatch,

    pub fn init(total: usize) !Progress {
        return .{
            .total = total,
            .started = std.atomic.Value(usize).init(0),
            .completed = std.atomic.Value(usize).init(0),
            .timer = Stopwatch.start(),
        };
    }

    pub fn deinit(_: *Progress) void {}
};

pub const DirLocks = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    map: std.StringHashMapUnmanaged(*std.Io.Mutex) = .{},

    pub fn init(allocator: std.mem.Allocator) DirLocks {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DirLocks) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn get(self: *DirLocks, dir: []const u8) !*std.Io.Mutex {
        self.mutex.lockUncancelable(zig_api.defaultIo());
        defer self.mutex.unlock(zig_api.defaultIo());

        if (self.map.get(dir)) |lock_ptr| return lock_ptr;
        const key = try self.allocator.dupe(u8, dir);
        errdefer self.allocator.free(key);

        const lock_ptr = try self.allocator.create(std.Io.Mutex);
        errdefer self.allocator.destroy(lock_ptr);
        lock_ptr.* = .init;

        try self.map.put(self.allocator, key, lock_ptr);
        return lock_ptr;
    }
};

pub fn logProgress(log_state: *LogState, progress: *Progress, path: []const u8) void {
    const started = progress.started.fetchAdd(1, .seq_cst) + 1;
    const completed = progress.completed.load(.seq_cst);
    const elapsed_ms = progress.timer.read() / std.time.ns_per_ms;
    const eta_ms = estimateEtaMs(elapsed_ms, completed, progress.total);

    var elapsed_buf: [32]u8 = undefined;
    var eta_buf: [32]u8 = undefined;
    const elapsed_str = formatDuration(&elapsed_buf, elapsed_ms);
    const eta_str = formatDuration(&eta_buf, eta_ms);
    const name = std.fs.path.basename(path);

    log_state.stdout("[{d}/{d}] Running {s} | elapsed {s} | eta {s}\n", .{
        started,
        progress.total,
        name,
        elapsed_str,
        eta_str,
    });
}

fn estimateEtaMs(elapsed_ms: u64, completed: usize, total: usize) u64 {
    if (completed == 0 or total <= completed) return 0;
    const avg_ms = elapsed_ms / completed;
    return avg_ms * (total - completed);
}

fn formatDuration(buf: []u8, total_ms: u64) []const u8 {
    const total_seconds = total_ms / 1000;
    const seconds = total_seconds % 60;
    const minutes = (total_seconds / 60) % 60;
    const hours = total_seconds / 3600;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "00:00:00";
}

pub fn parseRuntimeBackend(text: []const u8) !RuntimeBackend {
    if (std.ascii.eqlIgnoreCase(text, "c")) return .c;
    if (std.ascii.eqlIgnoreCase(text, "zig")) return .zig;
    return error.InvalidRuntimeBackend;
}

pub const RuntimeArtifacts = struct {
    zig_object: ?[]const u8 = null,

    pub fn deinit(self: *RuntimeArtifacts, allocator: std.mem.Allocator) void {
        if (self.zig_object) |obj| {
            allocator.free(obj);
            self.zig_object = null;
        }
    }

    pub fn appendToArgs(self: *const RuntimeArtifacts, allocator: std.mem.Allocator, args: *std.ArrayList([]const u8)) !void {
        if (self.zig_object) |obj| {
            try args.append(allocator, obj);
        }
    }
};

fn isRuntimeCacheCorruption(stderr: []const u8, runtime_artifacts: *const RuntimeArtifacts) bool {
    const runtime_obj = runtime_artifacts.zig_object orelse return false;
    if (std.mem.indexOf(u8, stderr, runtime_obj) == null) return false;
    return std.mem.indexOf(u8, stderr, "unknown file type") != null or
        std.mem.indexOf(u8, stderr, "unknown directive") != null or
        std.mem.indexOf(u8, stderr, "file format not recognized") != null;
}

pub fn tryRecoverRuntimeCacheAndRelink(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cache_dir: []const u8,
    runtime_cache_key: []const u8,
    runtime_artifacts: *RuntimeArtifacts,
    options: anytype,
    log_state: *LogState,
    dir_locks: *DirLocks,
    abs_input_path: []const u8,
    work_dir: []const u8,
    test_exe: []const u8,
    translated_obj_path: []const u8,
    link_timeout: ?u64,
    link_result: *ProcessResult,
) !bool {
    _ = work_dir;
    if (!isRuntimeCacheCorruption(link_result.stderr, runtime_artifacts)) return false;

    const runtime_obj = runtime_artifacts.zig_object orelse return false;
    const runtime_lock = try dir_locks.get(runtime_obj);
    runtime_lock.lockUncancelable(zig_api.defaultIo());
    defer runtime_lock.unlock(zig_api.defaultIo());

    log_state.stderr("runtime cache object invalid, rebuilding: {s}\n", .{abs_input_path});
    deleteFileAbsoluteIfExists(runtime_obj);
    runtime_artifacts.deinit(allocator);
    runtime_artifacts.* = try prepareRuntimeArtifacts(
        allocator,
        root_path,
        cache_dir,
        options.runtime_backend,
        options.timeout_ms,
        runtime_cache_key,
        true,
    );

    deleteFileAbsoluteIfExists(test_exe);
    deleteWindowsLinkSidecarsIfExists(allocator, test_exe);

    var compile_args: std.ArrayList([]const u8) = .empty;
    defer compile_args.deinit(allocator);
    try compile_args.appendSlice(allocator, &.{ "zig", "cc", "-O0", "-o", test_exe, translated_obj_path });
    try runtime_artifacts.appendToArgs(allocator, &compile_args);

    const rebuilt_result = runZigCcLinkWithWindowsRetry(
        allocator,
        compile_args.items,
        null,
        link_timeout,
        test_exe,
    ) catch |err| {
        log_state.stderr("zig cc link failed while rebuilding runtime cache: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
        return false;
    };
    link_result.deinit(allocator);
    link_result.* = rebuilt_result;
    return isZeroExit(link_result.term);
}

pub fn prepareRuntimeArtifacts(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    output_dir: []const u8,
    backend: RuntimeBackend,
    timeout_ms: u64,
    runtime_cache_key: []const u8,
    incremental: bool,
) !RuntimeArtifacts {
    return switch (backend) {
        .c, .zig => blk: {
            const runtime_src = try std.fs.path.join(allocator, &.{ root_path, "src", "runtime", "col6forge_rt.zig" });
            defer allocator.free(runtime_src);
            const runtime_obj_name = if (incremental)
                try std.fmt.allocPrint(
                    allocator,
                    "col6forge_rt_v{d}_{s}_{s}.o",
                    .{ CACHE_SCHEMA_VERSION, runtimeBackendTag(backend), runtime_cache_key },
                )
            else
                try allocator.dupe(u8, "col6forge_rt.o");
            defer allocator.free(runtime_obj_name);
            const runtime_obj = try std.fs.path.join(allocator, &.{ output_dir, runtime_obj_name });
            errdefer allocator.free(runtime_obj);
            if (incremental and fileExistsAbsolute(runtime_obj)) {
                break :blk .{ .zig_object = runtime_obj };
            }
            const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{runtime_obj});
            defer allocator.free(emit_arg);
            const build = try runProcessCapture(
                allocator,
                &.{ "zig", "build-obj", "-ODebug", "-fPIC", emit_arg, runtime_src },
                null,
                timeout_ms,
            );
            defer build.deinit(allocator);
            if (build.timed_out) return error.RuntimeBackendBuildTimeout;
            if (!isZeroExit(build.term)) {
                std.log.err("zig runtime backend build failed\n{s}\n", .{build.stderr});
                return error.RuntimeBackendBuildFailed;
            }
            break :blk .{
                .zig_object = runtime_obj,
            };
        },
    };
}

pub fn defaultJobs() usize {
    if (builtin.os.tag == .windows) return 1;
    const cpu = std.Thread.getCpuCount() catch 1;
    return if (cpu > 4) 4 else cpu;
}

