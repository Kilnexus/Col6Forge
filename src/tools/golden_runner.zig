//! Golden file test runner for Col6Forge.
//!
//! Runner (IO): discovers test inputs, executes the compiler pipeline, and
//! reads/writes golden files.
//! Comparator (pure logic): compares expected vs. actual outputs and reports
//! a compact diff.
const std = @import("std");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;
const cli_args = Col6Forge.process_args;
const allocArgs = cli_args.allocArgs;
const freeArgs = cli_args.freeArgs;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const args = try allocArgs(allocator, init.minimal.args);
    defer freeArgs(allocator, args);

    const options = switch (parseArgs(args)) {
        .success => |value| value,
        .failure => |parse_err| {
            try printUsage(zig_api.File.stderr());
            try printParseArgError(zig_api.File.stderr(), parse_err);
            return error.InvalidArguments;
        },
    };
    if (options.show_help) {
        try printUsage(zig_api.File.stdout());
        return;
    }

    var log_state: LogState = .{};
    const cases = try collectTestCases(arena_allocator, options.tests_dir, options.filter, options.dialect);
    if (cases.len == 0) {
        log_state.stdout("no .f tests found\n", .{});
        return;
    }
    var progress = try Progress.init(cases.len);
    defer progress.deinit();

    for (cases) |case| {
        logProgress(&log_state, &progress, case.input_path);
        const result = processCase(allocator, case, options, &log_state) catch {
            _ = progress.completed.fetchAdd(1, .seq_cst);
            progress.started.store(progress.completed.load(.seq_cst), .seq_cst);
            return error.GoldenTestsFailed;
        };
        if (!result.ok) {
            _ = progress.completed.fetchAdd(1, .seq_cst);
            progress.started.store(progress.completed.load(.seq_cst), .seq_cst);
            return error.GoldenTestsFailed;
        }
        _ = progress.completed.fetchAdd(1, .seq_cst);
    }

    if (options.update) {
        log_state.stdout("updated golden files\n", .{});
        return;
    }
    log_state.stdout("golden tests passed\n", .{});
}

const Options = struct {
    tests_dir: []const u8,
    filter: ?[]const u8,
    update: bool,
    emit: Col6Forge.EmitKind,
    dialect: Col6Forge.Dialect,
    show_help: bool,
    timeout_ms: u64,
    jobs: usize,
};

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_std: []const u8,
    invalid_timeout: []const u8,
    invalid_jobs: []const u8,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var tests_dir: []const u8 = "tests/NIST_F78_test_suite";
    var filter: ?[]const u8 = null;
    var update = false;
    var emit: Col6Forge.EmitKind = .llvm;
    var dialect: Col6Forge.Dialect = .default;
    var show_help = false;
    var timeout_ms: u64 = 30_000;
    var jobs = defaultJobs();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--update")) {
            update = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-emit-llvm")) {
            emit = .llvm;
            continue;
        }
        if (std.mem.eql(u8, arg, "--filter")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            filter = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--tests-dir")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            tests_dir = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--std")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            dialect = parseDialect(args[i]) catch {
                return .{ .failure = .{ .invalid_std = args[i] } };
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            timeout_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                return .{ .failure = .{ .invalid_timeout = args[i] } };
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--jobs") or std.mem.eql(u8, arg, "-j")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            jobs = std.fmt.parseInt(usize, args[i], 10) catch {
                return .{ .failure = .{ .invalid_jobs = args[i] } };
            };
            if (jobs == 0) return .{ .failure = .{ .invalid_jobs = args[i] } };
            continue;
        }
        return .{ .failure = .{ .unknown_flag = arg } };
    }

    return .{ .success = .{
        .tests_dir = tests_dir,
        .filter = filter,
        .update = update,
        .emit = emit,
        .dialect = dialect,
        .show_help = show_help,
        .timeout_ms = timeout_ms,
        .jobs = jobs,
    } };
}

fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_value => |flag| try writer.interface.print("error: missing value for flag {s}\n", .{flag}),
        .unknown_flag => |flag| try writer.interface.print("error: unknown flag: {s}\n", .{flag}),
        .invalid_std => |value| try writer.interface.print("error: invalid Fortran standard: {s} (expected default, f95, f77, or legacy)\n", .{value}),
        .invalid_timeout => |value| try writer.interface.print("error: invalid timeout value: {s}\n", .{value}),
        .invalid_jobs => |value| try writer.interface.print("error: invalid jobs value: {s} (must be positive integer)\n", .{value}),
    }
    try writer.interface.flush();
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: golden_runner [--tests-dir <dir>] [--filter <text>] [--std <default|f77>] [--update] [--timeout <ms>] [--jobs <n>] [-emit-llvm]
        \\Options:
        \\  --tests-dir <dir>  Root directory to scan for .f files (default: tests/NIST_F78_test_suite)
        \\  --filter <text>    Only run tests whose relative path contains this text
        \\  --std <mode>       Fortran dialect gate for pipeline runs (default: default)
        \\  --update           Overwrite golden .ll files with current output
        \\  --timeout <ms>     Per-test timeout in milliseconds (default: 30000)
        \\  --jobs <n>, -j <n> Parallel job count (default: CPU cores)
        \\  -emit-llvm         Emit LLVM IR (default)
        \\  -h, --help         Show this help
        \\
    );
}

const TestCase = struct {
    input_path: []const u8,
    golden_path: []const u8,
};

fn collectTestCases(
    allocator: std.mem.Allocator,
    tests_dir: []const u8,
    filter: ?[]const u8,
    dialect: Col6Forge.Dialect,
) ![]TestCase {
    var list: std.ArrayList(TestCase) = .empty;
    var dir = try zig_api.cwd().openDir(tests_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".f")) continue;
        if (filter) |needle| {
            if (!std.mem.containsAtLeast(u8, entry.path, 1, needle)) continue;
        }
        if (shouldSkipDefaultLegacyGoldenCase(entry.path, dialect)) continue;

        const input_path = try std.fs.path.join(allocator, &.{ tests_dir, entry.path });
        const golden_path = try replaceExtension(allocator, input_path, "ll");
        try list.append(allocator, .{ .input_path = input_path, .golden_path = golden_path });
    }

    std.sort.heap(TestCase, list.items, {}, testCaseLessThan);
    return list.toOwnedSlice(allocator);
}

fn shouldSkipDefaultLegacyGoldenCase(rel_path: []const u8, dialect: Col6Forge.Dialect) bool {
    if (dialect != .default) return false;
    const base = std.fs.path.basename(rel_path);
    return std.ascii.eqlIgnoreCase(base, "FM719.f") or
        std.ascii.eqlIgnoreCase(base, "FM719.FOR") or
        std.ascii.eqlIgnoreCase(rel_path, "fcvs21_f95/FM719.f") or
        std.ascii.eqlIgnoreCase(rel_path, "fcvs21_f95\\FM719.f");
}

fn testCaseLessThan(_: void, a: TestCase, b: TestCase) bool {
    return std.mem.order(u8, a.input_path, b.input_path) == .lt;
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(path) orelse "";
    const base = std.fs.path.basename(path);
    const dot_index = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const stem = base[0..dot_index];

    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) {
        return std.fmt.allocPrint(allocator, "{s}.{s}", .{ stem, new_ext });
    }
    return std.fmt.allocPrint(allocator, "{s}{c}{s}.{s}", .{ dir, std.fs.path.sep, stem, new_ext });
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try zig_api.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

fn reportPipelineError(log_state: *LogState, diag_bag: *const Col6Forge.diag.Bag, input_path: []const u8, err: anyerror) !void {
    var stderr = zig_api.File.stderr();
    var buffer: [4096]u8 = undefined;
    var writer = stderr.writer(&buffer);
    log_state.lock();
    defer log_state.unlock();
    try Col6Forge.writePipelineErrorDiagnostic(&writer.interface, diag_bag, input_path, err);
    try writer.interface.flush();
}

const Comparator = struct {
    pub const CompareResult = struct {
        ok: bool,
        diff: ?[]const u8,
    };

    pub fn compareText(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) !CompareResult {
        if (std.mem.eql(u8, expected, actual)) {
            return .{ .ok = true, .diff = null };
        }

        var exp_it = std.mem.splitScalar(u8, expected, '\n');
        var act_it = std.mem.splitScalar(u8, actual, '\n');
        var line_no: usize = 1;

        while (true) : (line_no += 1) {
            const exp_opt = exp_it.next();
            const act_opt = act_it.next();

            if (exp_opt == null and act_opt == null) {
                break;
            }
            if (exp_opt == null and act_opt != null) {
                const diff = try std.fmt.allocPrint(
                    allocator,
                    "actual has extra content at line {d}\nactual: {s}\n",
                    .{ line_no, trimCr(act_opt.?) },
                );
                return .{ .ok = false, .diff = diff };
            }
            if (act_opt == null and exp_opt != null) {
                const diff = try std.fmt.allocPrint(
                    allocator,
                    "expected has extra content at line {d}\nexpected: {s}\n",
                    .{ line_no, trimCr(exp_opt.?) },
                );
                return .{ .ok = false, .diff = diff };
            }

            const exp_line = trimCr(exp_opt.?);
            const act_line = trimCr(act_opt.?);
            if (!std.mem.eql(u8, exp_line, act_line)) {
                const diff = try std.fmt.allocPrint(
                    allocator,
                    "line {d} mismatch\nexpected: {s}\nactual:   {s}\n",
                    .{ line_no, exp_line, act_line },
                );
                return .{ .ok = false, .diff = diff };
            }
        }

        return .{ .ok = true, .diff = null };
    }
};

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

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

fn isTimedOut(timeout_ms: u64, timer: *const Stopwatch) bool {
    if (timeout_ms == 0) return false;
    const elapsed_ms = timer.read() / std.time.ns_per_ms;
    return elapsed_ms >= timeout_ms;
}

const CaseResult = struct {
    ok: bool,
    updated: bool,
};

fn processCase(
    allocator: std.mem.Allocator,
    case: TestCase,
    options: Options,
    log_state: *LogState,
) !CaseResult {
    var timer = Stopwatch.start();
    var diag_bag = Col6Forge.diag.Bag.init(allocator);
    defer diag_bag.deinit();
    const result = Col6Forge.runPipelineWithOptionsAndDiagnostics(allocator, case.input_path, options.emit, .{
        .dialect = options.dialect,
        .target = "x86_64-linux-gnu",
    }, &diag_bag) catch |err| {
        try reportPipelineError(log_state, &diag_bag, case.input_path, err);
        return .{ .ok = false, .updated = false };
    };
    defer allocator.free(result.output);

    if (isTimedOut(options.timeout_ms, &timer)) {
        log_state.stderr("timeout: {s}\n", .{case.input_path});
        return .{ .ok = false, .updated = false };
    }

    if (options.update) {
        try writeFile(case.golden_path, result.output);
        return .{ .ok = true, .updated = true };
    }

    const expected = zig_api.cwd().readFileAlloc(allocator, case.golden_path, 64 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            log_state.stderr("missing golden file: {s}\n", .{case.golden_path});
        } else {
            log_state.stderr("failed to read golden file {s}: {s}\n", .{ case.golden_path, @errorName(err) });
        }
        return .{ .ok = false, .updated = false };
    };
    defer allocator.free(expected);

    if (isTimedOut(options.timeout_ms, &timer)) {
        log_state.stderr("timeout: {s}\n", .{case.input_path});
        return .{ .ok = false, .updated = false };
    }

    const comparison = try Comparator.compareText(allocator, expected, result.output);
    if (!comparison.ok) {
        log_state.stderr("mismatch: {s}\n{s}\n", .{ case.input_path, comparison.diff.? });
        allocator.free(comparison.diff.?);
        return .{ .ok = false, .updated = false };
    }
    if (comparison.diff) |diff| {
        allocator.free(diff);
    }

    return .{ .ok = true, .updated = false };
}

fn runCaseParallel(
    allocator: std.mem.Allocator,
    case: TestCase,
    options: Options,
    log_state: *LogState,
    progress: *Progress,
    failures: *std.atomic.Value(usize),
    updated: *std.atomic.Value(usize),
) void {
    logProgress(log_state, progress, case.input_path);
    const result = processCase(allocator, case, options, log_state) catch {
        _ = failures.fetchAdd(1, .seq_cst);
        _ = progress.completed.fetchAdd(1, .seq_cst);
        return;
    };
    if (!result.ok) {
        _ = failures.fetchAdd(1, .seq_cst);
    }
    if (result.updated) {
        _ = updated.fetchAdd(1, .seq_cst);
    }
    _ = progress.completed.fetchAdd(1, .seq_cst);
}

const LogState = struct {
    mutex: std.Io.Mutex = .init,

    fn lock(self: *LogState) void {
        self.mutex.lockUncancelable(zig_api.defaultIo());
    }

    fn unlock(self: *LogState) void {
        self.mutex.unlock(zig_api.defaultIo());
    }

    fn stdout(self: *LogState, comptime fmt: []const u8, args: anytype) void {
        self.print(zig_api.File.stdout(), fmt, args);
    }

    fn stderr(self: *LogState, comptime fmt: []const u8, args: anytype) void {
        self.print(zig_api.File.stderr(), fmt, args);
    }

    fn print(self: *LogState, file: zig_api.File, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(zig_api.defaultIo());
        defer self.mutex.unlock(zig_api.defaultIo());
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }
};

const Progress = struct {
    total: usize,
    started: std.atomic.Value(usize),
    completed: std.atomic.Value(usize),
    timer: Stopwatch,

    fn init(total: usize) !Progress {
        return .{
            .total = total,
            .started = std.atomic.Value(usize).init(0),
            .completed = std.atomic.Value(usize).init(0),
            .timer = Stopwatch.start(),
        };
    }

    fn deinit(_: *Progress) void {}
};

fn logProgress(log_state: *LogState, progress: *Progress, path: []const u8) void {
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

fn defaultJobs() usize {
    return std.Thread.getCpuCount() catch 1;
}

fn parseDialect(text: []const u8) !Col6Forge.Dialect {
    if (std.ascii.eqlIgnoreCase(text, "default")) return .default;
    if (std.ascii.eqlIgnoreCase(text, "f95")) return .default;
    if (std.ascii.eqlIgnoreCase(text, "f77")) return .f77_legacy;
    if (std.ascii.eqlIgnoreCase(text, "legacy")) return .f77_legacy;
    return error.InvalidDialect;
}
