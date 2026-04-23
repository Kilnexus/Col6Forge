//! Diagnostic golden file test runner for Col6Forge.
//!
//! This suite exercises failing inputs and compares the full rendered
//! diagnostic text (`file:line:column`, source line, caret) against `.diag`
//! golden files.
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
    const cases = try collectTestCases(arena_allocator, options.tests_dir, options.filter);
    if (cases.len == 0) {
        log_state.stdout("no diagnostic golden tests found\n", .{});
        return;
    }
    var progress = try Progress.init(cases.len);
    defer progress.deinit();

    for (cases) |case| {
        logProgress(&log_state, &progress, case.input_path);
        const result = processCase(allocator, case, options, &log_state) catch {
            _ = progress.completed.fetchAdd(1, .seq_cst);
            return error.DiagnosticGoldenTestsFailed;
        };
        if (!result.ok) {
            _ = progress.completed.fetchAdd(1, .seq_cst);
            return error.DiagnosticGoldenTestsFailed;
        }
        _ = progress.completed.fetchAdd(1, .seq_cst);
    }

    if (options.update) {
        log_state.stdout("updated diagnostic golden files\n", .{});
        return;
    }
    log_state.stdout("diagnostic golden tests passed\n", .{});
}

const Options = struct {
    mode: Mode,
    tests_dir: []const u8,
    filter: ?[]const u8,
    update: bool,
    show_help: bool,
    timeout_ms: u64,
    jobs: usize,
};

const Mode = enum {
    pipeline,
    cc_translate,
};

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_timeout: []const u8,
    invalid_jobs: []const u8,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var mode: Mode = .pipeline;
    var tests_dir: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var update = false;
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
        if (std.mem.eql(u8, arg, "--mode")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            mode = parseMode(args[i]) orelse return .{ .failure = .{ .unknown_flag = args[i] } };
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
        .mode = mode,
        .tests_dir = tests_dir orelse defaultTestsDir(mode),
        .filter = filter,
        .update = update,
        .show_help = show_help,
        .timeout_ms = timeout_ms,
        .jobs = jobs,
    } };
}

fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "pipeline")) return .pipeline;
    if (std.mem.eql(u8, value, "cc-translate")) return .cc_translate;
    return null;
}

fn defaultTestsDir(mode: Mode) []const u8 {
    return switch (mode) {
        .pipeline => "tests/diagnostic_golden",
        .cc_translate => "tests/diagnostic_golden_cc",
    };
}

fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_value => |flag| try writer.interface.print("error: missing value for flag {s}\n", .{flag}),
        .unknown_flag => |flag| try writer.interface.print("error: unknown flag: {s}\n", .{flag}),
        .invalid_timeout => |value| try writer.interface.print("error: invalid timeout value: {s}\n", .{value}),
        .invalid_jobs => |value| try writer.interface.print("error: invalid jobs value: {s} (must be positive integer)\n", .{value}),
    }
    try writer.interface.flush();
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: diagnostic_golden_runner [--mode <pipeline|cc-translate>] [--tests-dir <dir>] [--filter <text>] [--update] [--timeout <ms>] [--jobs <n>]
        \\Options:
        \\  --mode <mode>      Diagnostic path to test (default: pipeline)
        \\  --tests-dir <dir>  Root directory to scan for failing .f/.f90 files
        \\  --filter <text>    Only run tests whose relative path contains this text
        \\  --update           Overwrite golden .diag files with current diagnostics
        \\  --timeout <ms>     Per-test timeout in milliseconds (default: 30000)
        \\  --jobs <n>, -j <n> Parallel job count (default: 1; use explicit override if needed)
        \\  -h, --help         Show this help
        \\
    );
}

const TestCase = struct {
    input_path: []const u8,
    golden_path: []const u8,
};

fn collectTestCases(allocator: std.mem.Allocator, tests_dir: []const u8, filter: ?[]const u8) ![]TestCase {
    var list: std.ArrayList(TestCase) = .empty;
    var dir = try zig_api.cwd().openDir(tests_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!isFortranSource(entry.path)) continue;
        if (filter) |needle| {
            if (!std.mem.containsAtLeast(u8, entry.path, 1, needle)) continue;
        }

        const input_path = try std.fs.path.join(allocator, &.{ tests_dir, entry.path });
        const golden_path = try replaceExtension(allocator, input_path, "diag");
        try list.append(allocator, .{ .input_path = input_path, .golden_path = golden_path });
    }

    std.sort.heap(TestCase, list.items, {}, testCaseLessThan);
    return list.toOwnedSlice(allocator);
}

fn isFortranSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".f") or
        std.mem.endsWith(u8, path, ".f90");
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

            if (exp_opt == null and act_opt == null) break;
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
            if (!equalIgnoringPathSeparators(exp_line, act_line)) {
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

fn equalIgnoringPathSeparators(expected: []const u8, actual: []const u8) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |exp_ch, act_ch| {
        const norm_exp = if (exp_ch == '\\') '/' else exp_ch;
        const norm_act = if (act_ch == '\\') '/' else act_ch;
        if (norm_exp != norm_act) return false;
    }
    return true;
}

fn normalizeDisplayPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return out;
}

fn renderDiagnosticText(
    allocator: std.mem.Allocator,
    display_path: []const u8,
    diag_bag: *Col6Forge.diag.Bag,
    err: anyerror,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (diag_bag.has()) {
        while (diag_bag.take()) |diag| {
            errdefer diag_bag.release(diag);
            var display_diag = diag;
            display_diag.file_path = display_path;
            try Col6Forge.writeDiagnostic(&out.writer, display_diag);
            diag_bag.release(diag);
        }
    } else {
        try Col6Forge.writePipelineErrorDiagnostic(&out.writer, diag_bag, display_path, err);
    }
    try out.writer.flush();
    return try allocator.dupe(u8, out.writer.buffered());
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
    const result = switch (options.mode) {
        .pipeline => Col6Forge.runPipelineWithOptionsAndDiagnostics(allocator, case.input_path, .llvm, .{
            .target = "x86_64-linux-gnu",
        }, &diag_bag),
        .cc_translate => runCcTranslateDiagnosticPipeline(allocator, case.input_path, &diag_bag),
    };
    if (result) |success| {
        defer allocator.free(success.output);
        log_state.stderr("expected failure but pipeline succeeded: {s}\n", .{case.input_path});
        return .{ .ok = false, .updated = false };
    } else |err| {
        const display_path = try normalizeDisplayPath(allocator, case.input_path);
        defer allocator.free(display_path);
        const actual = try renderDiagnosticText(allocator, display_path, &diag_bag, err);
        defer allocator.free(actual);

        if (isTimedOut(options.timeout_ms, &timer)) {
            log_state.stderr("timeout: {s}\n", .{case.input_path});
            return .{ .ok = false, .updated = false };
        }

        if (options.update) {
            try writeFile(case.golden_path, actual);
            return .{ .ok = true, .updated = true };
        }

        const expected = zig_api.cwd().readFileAlloc(allocator, case.golden_path, 8 * 1024 * 1024) catch |read_err| {
            if (read_err == error.FileNotFound) {
                log_state.stderr("missing golden file: {s}\n", .{case.golden_path});
            } else {
                log_state.stderr("failed to read golden file {s}: {s}\n", .{ case.golden_path, @errorName(read_err) });
            }
            return .{ .ok = false, .updated = false };
        };
        defer allocator.free(expected);

        if (isTimedOut(options.timeout_ms, &timer)) {
            log_state.stderr("timeout: {s}\n", .{case.input_path});
            return .{ .ok = false, .updated = false };
        }

        const comparison = try Comparator.compareText(allocator, expected, actual);
        if (!comparison.ok) {
            log_state.stderr("mismatch: {s}\n{s}\n", .{ case.input_path, comparison.diff.? });
            allocator.free(comparison.diff.?);
            return .{ .ok = false, .updated = false };
        }
        if (comparison.diff) |diff| allocator.free(diff);
        return .{ .ok = true, .updated = false };
    }
}

fn runCcTranslateDiagnosticPipeline(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    diag_bag: *Col6Forge.diag.Bag,
) !Col6Forge.PipelineResult {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try Col6Forge.runPipelineToWriterWithOptionsAndDiagnostics(
        allocator,
        input_path,
        .llvm,
        &out.writer,
        .{
            .pause_mode = .auto,
            .target = "x86_64-linux-gnu",
            .coarse_source_map = false,
        },
        diag_bag,
    );
    try out.writer.flush();
    return .{ .output = try allocator.dupe(u8, out.writer.buffered()) };
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
    completed: std.atomic.Value(usize),
    last_percent: std.atomic.Value(usize),

    fn init(total: usize) !Progress {
        return .{
            .total = total,
            .completed = std.atomic.Value(usize).init(0),
            .last_percent = std.atomic.Value(usize).init(0),
        };
    }

    fn deinit(_: *Progress) void {}
};

fn logProgress(log_state: *LogState, progress: *Progress, input_path: []const u8) void {
    if (progress.total == 0) return;
    const completed = progress.completed.load(.seq_cst);
    const next = @min(completed + 1, progress.total);
    const percent = (next * 100) / progress.total;
    const prev = progress.last_percent.swap(percent, .seq_cst);
    if (percent == prev and percent != 100) return;
    log_state.stdout("[{d: >3}%] {s}\n", .{ percent, input_path });
}

fn defaultJobs() usize {
    return 1;
}

test "diagnostic comparator ignores path separator differences" {
    const testing = std.testing;
    const expected =
        "error[CF2001]: sample\n" ++
        "  ::: tests/diagnostic_golden\\fixed_parse_continuation.f\n";
    const actual =
        "error[CF2001]: sample\n" ++
        "  ::: tests/diagnostic_golden/fixed_parse_continuation.f\n";

    const result = try Comparator.compareText(testing.allocator, expected, actual);
    defer if (result.diff) |diff| testing.allocator.free(diff);
    try testing.expect(result.ok);
}
