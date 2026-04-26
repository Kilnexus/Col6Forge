const common = @import("common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const fallback_policy = common.fallback_policy;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const zig_api = common.zig_api;
const logged_pipeline_error = @import("../logged_pipeline_error.zig");

fn openDirPath(path: []const u8, options: anytype) !zig_api.Dir {
    if (std.fs.path.isAbsolute(path)) return zig_api.openDirAbsolute(path, options);
    return zig_api.cwd().openDir(path, options);
}

fn openFilePath(path: []const u8, options: anytype) !zig_api.File {
    if (std.fs.path.isAbsolute(path)) return zig_api.openFileAbsolute(path, options);
    return zig_api.cwd().openFile(path, options);
}

fn createFilePath(path: []const u8, options: anytype) !zig_api.File {
    if (std.fs.path.isAbsolute(path)) return zig_api.createFileAbsolute(path, options);
    return zig_api.cwd().createFile(path, options);
}

fn accessPath(path: []const u8, options: anytype) !void {
    if (std.fs.path.isAbsolute(path)) return zig_api.accessAbsolute(path, options);
    return zig_api.cwd().access(path, options);
}

fn deleteFilePath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) return zig_api.deleteFileAbsolute(path);
    return zig_api.cwd().deleteFile(path);
}

pub fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try createFilePath(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

pub fn emitPipelineToFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    emit: Col6Forge.EmitKind,
    output_path: []const u8,
    dialect: Col6Forge.Dialect,
    capture_profile: bool,
    diag_bag: *Col6Forge.diag.Bag,
) !void {
    var out_file = try createFilePath(output_path, .{ .truncate = true });
    defer out_file.close();
    var out_buf: [32 * 1024]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);
    try Col6Forge.runPipelineToWriterWithOptionsAndDiagnostics(
        allocator,
        input_path,
        emit,
        &out_writer.interface,
        .{
            .coarse_source_map = false,
            .capture_profile = capture_profile,
            .dialect = dialect,
        },
        diag_bag,
    );
    try out_writer.interface.flush();
}

pub fn parseDialect(text: []const u8) !Col6Forge.Dialect {
    if (std.ascii.eqlIgnoreCase(text, "default")) return .default;
    if (std.ascii.eqlIgnoreCase(text, "f95")) return .default;
    if (std.ascii.eqlIgnoreCase(text, "f77")) return .f77_legacy;
    if (std.ascii.eqlIgnoreCase(text, "legacy")) return .f77_legacy;
    return error.InvalidDialect;
}

fn emitCacheTag(_: Col6Forge.EmitKind) []const u8 {
    return "llvm";
}

fn runtimeBackendTag(backend: RuntimeBackend) []const u8 {
    return switch (backend) {
        .c => "c",
        .zig => "zig",
    };
}

pub fn hashFileXx64(path: []const u8) !u64 {
    var file = try openFilePath(path, .{});
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

pub fn fileExistsAbsolute(path: []const u8) bool {
    accessPath(path, .{}) catch return false;
    return true;
}

pub fn copyFileAbsolute(src_path: []const u8, dst_path: []const u8) !void {
    var src = try openFilePath(src_path, .{});
    defer src.close();
    var dst = try createFilePath(dst_path, .{ .truncate = true });
    defer dst.close();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
}

pub fn deleteFileAbsoluteIfExists(path: []const u8) void {
    deleteFilePath(path) catch {};
}

pub fn deleteWindowsLinkSidecarsIfExists(allocator: std.mem.Allocator, exe_path: []const u8) void {
    if (builtin.os.tag != .windows) return;
    const ext = std.fs.path.extension(exe_path);
    const stem = if (ext.len != 0) exe_path[0 .. exe_path.len - ext.len] else exe_path;
    const suffixes = [_][]const u8{ ".pdb", ".lib", ".exp" };
    for (suffixes) |suffix| {
        const sidecar = std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, suffix }) catch continue;
        defer allocator.free(sidecar);
        deleteFileAbsoluteIfExists(sidecar);
    }
}

fn isWindowsLinkAccessDenied(stderr: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    return std.mem.indexOf(u8, stderr, "failed to link with LLD: AccessDenied") != null or
        std.mem.indexOf(u8, stderr, "AccessDenied") != null;
}

pub fn buildVerifyCachePath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    compiler_cache_key: []const u8,
    source_hash: u64,
    emit: Col6Forge.EmitKind,
    ext: []const u8,
) ![]const u8 {
    const name = try std.fmt.allocPrint(
        allocator,
        "v{d}_{s}_{s}_{x:0>16}{s}",
        .{ CACHE_SCHEMA_VERSION, emitCacheTag(emit), compiler_cache_key, source_hash, ext },
    );
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache_dir, name });
}

pub fn computeCompilerCacheKey(allocator: std.mem.Allocator, root_path: []const u8) ![]const u8 {
    const src_dir = try std.fs.path.join(allocator, &.{ root_path, "src" });
    defer allocator.free(src_dir);

    var dir = try openDirPath(src_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    while (try walker.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.path, ".zig")) continue;
        if (std.mem.startsWith(u8, entry.path, "runtime/") or std.mem.startsWith(u8, entry.path, "runtime\\")) continue;
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
        const abs_path = try std.fs.path.join(allocator, &.{ src_dir, rel_path });
        defer allocator.free(abs_path);
        var digest = try hashFileXx64(abs_path);
        hasher.update(std.mem.asBytes(&digest));
    }
    const final = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{final});
}

pub fn computeRuntimeCacheKey(allocator: std.mem.Allocator, root_path: []const u8) ![]const u8 {
    const runtime_dir = try std.fs.path.join(allocator, &.{ root_path, "src", "runtime" });
    defer allocator.free(runtime_dir);

    var dir = try openDirPath(runtime_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    while (try walker.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.path, ".zig")) continue;
        if (!(std.mem.eql(u8, entry.path, "col6forge_rt.zig") or
            std.mem.startsWith(u8, entry.path, "col6forge_rt/") or
            std.mem.startsWith(u8, entry.path, "col6forge_rt\\")))
        {
            continue;
        }
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
        const abs_path = try std.fs.path.join(allocator, &.{ runtime_dir, rel_path });
        defer allocator.free(abs_path);
        var digest = try hashFileXx64(abs_path);
        hasher.update(std.mem.asBytes(&digest));
    }
    const final = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{final});
}

pub fn computeRunScopedRuntimeCacheKey(allocator: std.mem.Allocator, root_path: []const u8) ![]const u8 {
    const base_key = try computeRuntimeCacheKey(allocator, root_path);
    defer allocator.free(base_key);

    const nonce: u64 = @intCast(zig_api.nowNs());
    return std.fmt.allocPrint(allocator, "{s}_{x:0>16}", .{ base_key, nonce });
}

pub fn computeReferenceCompilerCacheKey(
    allocator: std.mem.Allocator,
    gfortran_cmd: []const u8,
    timeout_ms: u64,
) ![]const u8 {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(gfortran_cmd);

    const probe_timeout: ?u64 = if (timeout_ms == 0)
        5_000
    else
        @min(timeout_ms, @as(u64, 5_000));

    const probe = runProcessCapture(
        allocator,
        &.{ gfortran_cmd, "--version" },
        null,
        probe_timeout,
    ) catch null;
    if (probe) |result| {
        defer result.deinit(allocator);
        if (!result.timed_out and isZeroExit(result.term)) {
            hasher.update(result.stdout);
            hasher.update(result.stderr);
        }
    }

    const final = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{final});
}

pub fn computeLinkedExeCacheKey(
    allocator: std.mem.Allocator,
    compiler_cache_key: []const u8,
    runtime_cache_key: []const u8,
    runtime_backend: RuntimeBackend,
) ![]const u8 {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(compiler_cache_key);
    hasher.update(runtime_cache_key);
    hasher.update(runtimeBackendTag(runtime_backend));
    const final = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{final});
}

const RefSource = struct {
    path: []const u8,
    owned: bool,
};

pub fn prepareGfortranSource(
    allocator: std.mem.Allocator,
    abs_input_path: []const u8,
    work_dir: []const u8,
) !RefSource {
    const max_size = 64 * 1024 * 1024;
    const contents = try zig_api.cwd().readFileAlloc(allocator, abs_input_path, max_size);
    defer allocator.free(contents);

    const sanitized = try sanitizeDuplicateProgramHeader(allocator, contents);
    defer allocator.free(sanitized);

    const out_path = try std.fs.path.join(allocator, &.{ work_dir, "gfortran_input.for" });
    try writeFile(out_path, sanitized);
    return .{ .path = out_path, .owned = true };
}

fn sanitizeDuplicateProgramHeader(allocator: std.mem.Allocator, contents: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var it = std.mem.splitScalar(u8, contents, '\n');
    var wrote_any = false;
    var first_header: ?[]const u8 = null;
    var skipped = false;
    defer if (first_header) |hdr| allocator.free(hdr);

    while (it.next()) |line_raw| {
        const line = stripTrailingCarriage(line_raw);
        const normalized = normalizeHeaderLine(allocator, line) catch null;
        defer if (normalized) |value| allocator.free(value);

        var skip_line = false;
        if (!skipped) {
            if (normalized) |value| {
                if (first_header == null) {
                    if (isProgramUnitHeader(value)) {
                        first_header = try allocator.dupe(u8, value);
                    }
                } else if (std.mem.eql(u8, value, first_header.?)) {
                    skip_line = true;
                    skipped = true;
                }
            }
        }

        if (!skip_line) {
            if (wrote_any) try out.append('\n');
            try out.appendSlice(line_raw);
            wrote_any = true;
        }
    }

    return out.toOwnedSlice();
}

fn stripTrailingCarriage(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn normalizeHeaderLine(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    if (line.len == 0) return null;
    if (isCommentLine(line)) return null;

    const limited = line[0..@min(line.len, 72)];
    const trimmed = std.mem.trim(u8, limited, " \t");
    if (trimmed.len == 0) return null;

    var buf = std.array_list.Managed(u8).init(allocator);
    var in_space = false;
    for (trimmed) |ch| {
        if (ch == ' ' or ch == '\t') {
            if (!in_space) {
                try buf.append(' ');
                in_space = true;
            }
            continue;
        }
        try buf.append(std.ascii.toUpper(ch));
        in_space = false;
    }
    return try buf.toOwnedSlice();
}

fn isProgramUnitHeader(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "PROGRAM ") or
        std.mem.startsWith(u8, text, "SUBROUTINE ") or
        std.mem.startsWith(u8, text, "FUNCTION ") or
        std.mem.eql(u8, text, "BLOCKDATA") or
        std.mem.startsWith(u8, text, "BLOCK DATA");
}

fn isCommentLine(line: []const u8) bool {
    if (line.len == 0) return false;
    return line[0] == 'c' or line[0] == 'C' or line[0] == '*' or line[0] == '!';
}

pub fn prepareExePath(allocator: std.mem.Allocator, work_dir: []const u8, base: []const u8) ![]const u8 {
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        const candidate = try buildExePath(allocator, work_dir, base, attempt);
        accessPath(candidate, .{ .read = true }) catch |err| switch (err) {
            error.FileNotFound => return candidate,
            error.AccessDenied, error.PermissionDenied => {
                allocator.free(candidate);
                continue;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        allocator.free(candidate);
    }
    return error.OutOfMemory;
}

fn buildExePath(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    base: []const u8,
    attempt: usize,
) ![]const u8 {
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    const file_name = if (attempt == 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, ext })
    else
        try std.fmt.allocPrint(allocator, "{s}_{d}{s}", .{ base, attempt, ext });
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ work_dir, file_name });
}

pub fn reportPipelineError(log_state: anytype, diag_bag: *const Col6Forge.diag.Bag, input_path: []const u8, err: anyerror) !void {
    return logged_pipeline_error.report(log_state, diag_bag, input_path, err);
}

pub const Stopwatch = struct {
    start_ns: i128,

    pub fn start() Stopwatch {
        return .{ .start_ns = zig_api.nowNs() };
    }

    pub fn read(self: *const Stopwatch) u64 {
        const elapsed = zig_api.nowNs() - self.start_ns;
        return @intCast(if (elapsed > 0) elapsed else 0);
    }
};

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,
    timed_out: bool,

    pub fn deinit(self: ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runProcessCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ms: ?u64,
) !ProcessResult {
    return runProcessCaptureWithInput(allocator, argv, cwd, timeout_ms, null);
}

pub fn runProcessCaptureWithInput(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ms: ?u64,
    stdin_path: ?[]const u8,
) !ProcessResult {
    const io = zig_api.defaultIo();
    const base_dir = cwd orelse ".";
    var local_cache_dir: ?[]u8 = null;
    defer if (local_cache_dir) |path| allocator.free(path);
    var global_cache_dir: ?[]u8 = null;
    defer if (global_cache_dir) |path| allocator.free(path);
    var temp_dir: ?[]u8 = null;
    defer if (temp_dir) |path| allocator.free(path);
    var env_map_storage: ?std.process.Environ.Map = null;
    defer if (env_map_storage) |*map| map.deinit();

    env_map_storage = try std.process.Environ.createMap(.{ .block = .global }, allocator);
    temp_dir = try std.fs.path.join(allocator, &.{ base_dir, ".verify-runner-tmp" });
    try zig_api.cwd().makePath(temp_dir.?);
    const temp_env = if (cwd != null) ".verify-runner-tmp" else temp_dir.?;
    try env_map_storage.?.put("TMP", temp_env);
    try env_map_storage.?.put("TEMP", temp_env);
    try env_map_storage.?.put("TMPDIR", temp_env);

    if (argv.len != 0 and std.mem.eql(u8, argv[0], "zig")) {
        local_cache_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zig-runner-cache" });
        global_cache_dir = try std.fs.path.join(allocator, &.{ base_dir, ".zig-runner-global-cache" });
        try zig_api.cwd().makePath(local_cache_dir.?);
        try zig_api.cwd().makePath(global_cache_dir.?);

        try env_map_storage.?.put("ZIG_LOCAL_CACHE_DIR", local_cache_dir.?);
        try env_map_storage.?.put("ZIG_GLOBAL_CACHE_DIR", global_cache_dir.?);
    }

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &env_map_storage.?,
        .stdin = if (stdin_path == null) .ignore else .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = builtin.os.tag == .windows,
    });
    defer child.kill(io);

    if (stdin_path) |path| {
        const stdin_bytes = try zig_api.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
        defer allocator.free(stdin_bytes);

        if (child.stdin) |stdin_file| {
            try stdin_file.writeStreamingAll(io, stdin_bytes);
            stdin_file.close(io);
            child.stdin = null;
        }
    }

    var done = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    var monitor: ?std.Thread = null;
    var monitor_joined = false;
    if (timeout_ms) |limit| {
        if (limit > 0) {
            monitor = try std.Thread.spawn(.{}, timeoutMonitor, .{ &child, &done, &timed_out, limit });
        }
    }
    errdefer {
        done.store(true, .seq_cst);
        if (!monitor_joined) {
            if (monitor) |thread| thread.join();
            monitor_joined = true;
        }
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try multi_reader.checkAnyError();

    done.store(true, .seq_cst);
    if (monitor) |thread| thread.join();
    monitor_joined = true;

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = term,
        .timed_out = timed_out.load(.seq_cst),
    };
}

pub fn runZigCcLinkWithWindowsRetry(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ms: ?u64,
    output_exe_path: []const u8,
) !ProcessResult {
    deleteFileAbsoluteIfExists(output_exe_path);
    deleteWindowsLinkSidecarsIfExists(allocator, output_exe_path);

    var first = try runProcessCapture(allocator, argv, cwd, timeout_ms);
    if (isZeroExit(first.term) or !isWindowsLinkAccessDenied(first.stderr)) return first;

    first.deinit(allocator);
    deleteFileAbsoluteIfExists(output_exe_path);
    deleteWindowsLinkSidecarsIfExists(allocator, output_exe_path);
    std.Io.sleep(zig_api.defaultIo(), .fromMilliseconds(200), .awake) catch {};
    return runProcessCapture(allocator, argv, cwd, timeout_ms);
}

pub fn remainingTimeoutMs(timeout_ms: u64, timer: *const Stopwatch) ?u64 {
    if (timeout_ms == 0) return null;
    const elapsed_ms = timer.read() / std.time.ns_per_ms;
    if (elapsed_ms >= timeout_ms) return 0;
    return timeout_ms - elapsed_ms;
}

pub fn isTimedOut(timeout_ms: u64, timer: *const Stopwatch) bool {
    if (timeout_ms == 0) return false;
    const elapsed_ms = timer.read() / std.time.ns_per_ms;
    return elapsed_ms >= timeout_ms;
}

pub fn cleanupWorkDir(path: []const u8) void {
    zig_api.cwd().deleteTree(path) catch {};
}

pub fn resolveVerifyWorkDir(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    work_name: []const u8,
) ![]const u8 {
    if (!shouldRelocateVerifyWorkDir(root_path)) {
        return std.fs.path.join(allocator, &.{ root_path, "zig-cache", "verify", work_name });
    }

    const override_root: ?[]u8 = null;

    const base_root = override_root orelse "/tmp/col6forge-verify";
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(root_path);
    const root_bucket = try std.fmt.allocPrint(allocator, "{x:0>16}", .{hasher.final()});
    defer allocator.free(root_bucket);

    return std.fs.path.join(allocator, &.{ base_root, root_bucket, work_name });
}

fn shouldRelocateVerifyWorkDir(root_path: []const u8) bool {
    if (builtin.os.tag != .linux) return false;
    return std.mem.startsWith(u8, root_path, "/mnt/");
}

pub fn cleanupFortranScratchFiles(case_dir: []const u8) !void {
    var dir = try openDirPath(case_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.raw.iterate();
    while (try it.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!isFortranScratchName(entry.name)) continue;
        dir.deleteFile(entry.name) catch {};
    }
}

pub fn copyCaseSupportFiles(allocator: std.mem.Allocator, case_dir: []const u8, work_dir: []const u8) !void {
    var dir = try openDirPath(case_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.raw.iterate();
    while (try it.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (isFortranSourceArtifact(entry.name)) continue;

        const src_path = try std.fs.path.join(allocator, &.{ case_dir, entry.name });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ work_dir, entry.name });
        defer allocator.free(dst_path);
        try copyFileAbsolute(src_path, dst_path);
    }
}

pub fn findCompanionInputPath(
    allocator: std.mem.Allocator,
    case_dir: []const u8,
    input_path: []const u8,
) !?[]u8 {
    const source_name = std.fs.path.basename(input_path);
    const source_stem = std.fs.path.stem(source_name);
    const dat_name = try std.fmt.allocPrint(allocator, "{s}.DAT", .{source_stem});
    defer allocator.free(dat_name);

    var dir = try openDirPath(case_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.raw.iterate();
    while (try it.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.eqlIgnoreCase(entry.name, dat_name)) continue;
        return try std.fs.path.join(allocator, &.{ case_dir, entry.name });
    }
    return null;
}

fn isFortranSourceArtifact(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".f") or
        std.ascii.endsWithIgnoreCase(name, ".for") or
        std.ascii.endsWithIgnoreCase(name, ".ll");
}

fn isFortranScratchName(name: []const u8) bool {
    if (name.len < 6) return false;
    if (!std.ascii.eqlIgnoreCase(name[0..5], "fort.")) return false;
    var i: usize = 5;
    while (i < name.len) : (i += 1) {
        if (!std.ascii.isDigit(name[i])) return false;
    }
    return true;
}

fn timeoutMonitor(
    child: *std.process.Child,
    done: *std.atomic.Value(bool),
    timed_out: *std.atomic.Value(bool),
    timeout_ms: u64,
) void {
    const deadline_ns = zig_api.nowNs() + @as(i128, timeout_ms) * std.time.ns_per_ms;
    while (true) {
        if (done.load(.seq_cst)) return;
        const now_ns = zig_api.nowNs();
        if (now_ns >= deadline_ns) break;
        const remaining_ms: u64 = @intCast(@divTrunc(deadline_ns - now_ns, std.time.ns_per_ms));
        const sleep_ms = if (remaining_ms > 50) 50 else remaining_ms;
        std.Io.sleep(zig_api.defaultIo(), .fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
    }
    if (done.load(.seq_cst)) return;
    timed_out.store(true, .seq_cst);
    terminateChild(child);
}

fn terminateChild(child: *std.process.Child) void {
    child.kill(zig_api.defaultIo());
}

pub fn isZeroExit(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn exitCode(term: std.process.Child.Term) u32 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| 128 + @intFromEnum(signal),
        else => 255,
    };
}

