//! Unified test harness that orchestrates existing suite runners.
const std = @import("std");
const builtin = @import("builtin");
const tool_args = @import("tool_args.zig");
const child_env = @import("child_env.zig");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

const TimeoutConfig = struct {
    suite_timeout_ms: u64 = 0,
    test_timeout_ms: u64 = 30_000,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try tool_args.allocArgs(allocator, init.minimal.args);
    defer tool_args.freeArgs(allocator, args);

    const parsed = try parseArgs(allocator, args);
    const options = switch (parsed) {
        .success => |value| value,
        .failure => |parse_err| {
            try printUsage(zig_api.File.stderr());
            try printParseArgError(zig_api.File.stderr(), parse_err);
            return error.InvalidArguments;
        },
    };
    defer allocator.free(options.suite_names);

    if (options.show_help) {
        try printUsage(zig_api.File.stdout());
        return;
    }

    const available_suites = getSuites();
    if (options.list_suites) {
        try listSuites(available_suites, zig_api.File.stdout());
        return;
    }

    const exe_dir = try allocator.dupe(u8, ".");
    defer allocator.free(exe_dir);
    const root_dir = try projectRootFromExeDir(allocator, exe_dir);
    defer allocator.free(root_dir);

    var selected_suites: std.ArrayList(Suite) = .empty;
    defer selected_suites.deinit(allocator);

    for (available_suites) |suite| {
        if (!suiteSelected(options.suite_names, suite)) continue;
        try selected_suites.append(allocator, suite);
    }

    if (selected_suites.items.len == 0) {
        try logStderr("no suites selected\n", .{});
        return error.NoSuitesSelected;
    }

    const runner_jobs = @max(1, options.jobs / selected_suites.items.len);

    var output: OutputMux = .{};

    var failures: usize = 0;
    for (selected_suites.items) |suite| {
        const ok = try runSuite(allocator, suite, options, exe_dir, root_dir, runner_jobs, &output);
        if (!ok) {
            failures += 1;
            if (!options.keep_going) break;
        }
    }
    if (failures > 0) {
        try logStderr("test harness failed: {d}\n", .{failures});
        return error.TestHarnessFailed;
    }
}

const SuiteKind = enum {
    golden,
    nist,
    gcc_dg,
};

const Suite = struct {
    name: []const u8,
    build_step: []const u8,
    exe_name: []const u8,
    description: []const u8,
    kind: SuiteKind,
    enabled_by_default: bool,
};

const Options = struct {
    tests_dir: ?[]const u8,
    filter: ?[]const u8,
    gfortran_path: ?[]const u8,
    suite_names: []const []const u8,
    emit_llvm: bool,
    keep_going: bool,
    update_golden: bool,
    list_suites: bool,
    show_help: bool,
    verbose: bool,
    strict_diagnostics: bool,
    strict_level: ?[]const u8,
    timeout: TimeoutConfig,
    jobs: usize,
};

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_jobs: []const u8,
    invalid_timeout: []const u8,
    invalid_suite_timeout: []const u8,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

const suites = [_]Suite{
    .{
        .name = "golden",
        .build_step = "golden",
        .exe_name = exeName("golden_runner"),
        .description = "Golden file tests",
        .kind = .golden,
        .enabled_by_default = true,
    },
    .{
        .name = "diagnostic-golden",
        .build_step = "diagnostic-golden",
        .exe_name = exeName("diagnostic_golden_runner"),
        .description = "Diagnostic golden file tests",
        .kind = .golden,
        .enabled_by_default = true,
    },
    .{
        .name = "cc-diagnostic-golden",
        .build_step = "cc-diagnostic-golden",
        .exe_name = exeName("diagnostic_golden_runner"),
        .description = "CC translation diagnostic golden file tests",
        .kind = .golden,
        .enabled_by_default = true,
    },
    .{
        .name = "nist",
        .build_step = "verify",
        .exe_name = exeName("verify_runner"),
        .description = "NIST F78 verification tests",
        .kind = .nist,
        .enabled_by_default = true,
    },
    .{
        .name = "gcc-dg",
        .build_step = "gcc-dg-verify",
        .exe_name = exeName("gcc_dg_runner"),
        .description = "GCC gfortran.dg compile-only subset",
        .kind = .gcc_dg,
        .enabled_by_default = false,
    },
};

fn getSuites() []const Suite {
    return suites[0..];
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParseArgsOutcome {
    var tests_dir: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var gfortran_path: ?[]const u8 = null;
    var suite_names: std.ArrayList([]const u8) = .empty;
    var parse_ok = false;
    defer if (!parse_ok) suite_names.deinit(allocator);
    var emit_llvm = false;
    var keep_going = false;
    var update_golden = false;
    var list_suites = false;
    var show_help = false;
    var verbose = false;
    var strict_diagnostics = false;
    var strict_level: ?[]const u8 = null;
    var jobs = defaultJobs();
    const default_timeout = TimeoutConfig{};
    var suite_timeout_ms: u64 = default_timeout.suite_timeout_ms;
    var test_timeout_ms: u64 = default_timeout.test_timeout_ms;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--list-suites")) {
            list_suites = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--suite")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            try appendSuites(allocator, &suite_names, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--tests-dir")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            tests_dir = args[i];
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
        if (std.mem.eql(u8, arg, "--filter")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            filter = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--gfortran")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            gfortran_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "-emit-llvm")) {
            emit_llvm = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep-going")) {
            keep_going = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--update-golden")) {
            update_golden = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            test_timeout_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                return .{ .failure = .{ .invalid_timeout = args[i] } };
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--suite-timeout")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            suite_timeout_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                return .{ .failure = .{ .invalid_suite_timeout = args[i] } };
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-diagnostics")) {
            strict_diagnostics = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-strict-diagnostics")) {
            strict_diagnostics = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-level")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            strict_level = args[i];
            continue;
        }
        return .{ .failure = .{ .unknown_flag = arg } };
    }

    const owned_suite_names = try suite_names.toOwnedSlice(allocator);
    parse_ok = true;
    return .{ .success = .{
        .tests_dir = tests_dir,
        .filter = filter,
        .gfortran_path = gfortran_path,
        .suite_names = owned_suite_names,
        .emit_llvm = emit_llvm,
        .keep_going = keep_going,
        .update_golden = update_golden,
        .list_suites = list_suites,
        .show_help = show_help,
        .verbose = verbose,
        .strict_diagnostics = strict_diagnostics,
        .strict_level = strict_level,
        .timeout = .{
            .suite_timeout_ms = suite_timeout_ms,
            .test_timeout_ms = test_timeout_ms,
        },
        .jobs = jobs,
    } };
}

fn appendSuites(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try list.append(allocator, name);
    }
}

fn suiteSelected(requested: []const []const u8, suite: Suite) bool {
    if (requested.len == 0) return suite.enabled_by_default;
    for (requested) |item| {
        if (std.mem.eql(u8, item, suite.name)) return true;
    }
    return false;
}

fn runSuite(
    allocator: std.mem.Allocator,
    suite: Suite,
    options: Options,
    _exe_dir: []const u8,
    root_dir: []const u8,
    runner_jobs: usize,
    output: *OutputMux,
) !bool {
    _ = _exe_dir;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var timeout_arg: ?[]const u8 = null;
    defer if (timeout_arg) |value| allocator.free(value);

    // Always invoke the suite through `zig build <step>` so test-all uses
    // the same freshly-built runner binaries as direct suite execution.
    try argv.appendSlice(allocator, &.{ "zig", "build", suite.build_step, "--" });
    if (options.tests_dir) |dir| {
        try argv.append(allocator, "--tests-dir");
        try argv.append(allocator, dir);
    }
    if (options.filter) |filter| {
        try argv.append(allocator, "--filter");
        try argv.append(allocator, filter);
    }
    try argv.append(allocator, "--jobs");
    const jobs_arg = try std.fmt.allocPrint(allocator, "{d}", .{runner_jobs});
    defer allocator.free(jobs_arg);
    try argv.append(allocator, jobs_arg);
    if (options.gfortran_path) |gfortran| {
        if (suite.kind == .nist) {
            try argv.append(allocator, "--gfortran");
            try argv.append(allocator, gfortran);
        }
    }
    if (options.update_golden and suite.kind == .golden) {
        try argv.append(allocator, "--update");
    }
    if (options.emit_llvm) {
        try argv.append(allocator, "-emit-llvm");
    }
    if (suite.kind == .gcc_dg) {
        if (options.strict_level) |level| {
            try argv.appendSlice(allocator, &.{ "--strict-level", level });
        } else if (options.strict_diagnostics) {
            try argv.append(allocator, "--strict-diagnostics");
        }
    }
    if (options.timeout.test_timeout_ms > 0) {
        timeout_arg = try std.fmt.allocPrint(allocator, "{d}", .{options.timeout.test_timeout_ms});
        try argv.append(allocator, "--timeout");
        try argv.append(allocator, timeout_arg.?);
    }

    if (options.verbose) {
        try logStdout("running {s}\n", .{suite.name});
        try logCommand(argv.items);
    }

    const result = try runChildWithTimeoutStreaming(
        allocator,
        argv.items,
        root_dir,
        options.timeout.suite_timeout_ms,
        output,
    );

    if (result.timed_out) {
        try logStderr("suite timed out: {s}\n", .{suite.name});
        return false;
    }
    if (!isZeroExit(result.term)) {
        try logSuiteTermFailure(suite.name, result.term);
        return false;
    }
    return true;
}

fn logSuiteTermFailure(suite_name: []const u8, term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| try logStderr("suite failed: {s} (exit {d})\n", .{ suite_name, code }),
        .signal => |sig| try logStderr("suite failed: {s} (signal {d})\n", .{ suite_name, sig }),
        .stopped => |sig| try logStderr("suite failed: {s} (stopped {d})\n", .{ suite_name, sig }),
        .unknown => |code| try logStderr("suite failed: {s} (status {d})\n", .{ suite_name, code }),
    }
}

fn runSuiteParallel(
    allocator: std.mem.Allocator,
    suite: Suite,
    options: Options,
    exe_dir: []const u8,
    root_dir: []const u8,
    runner_jobs: usize,
    output: *OutputMux,
    failures: *std.atomic.Value(usize),
) void {
    const ok = runSuite(allocator, suite, options, exe_dir, root_dir, runner_jobs, output) catch {
        _ = failures.fetchAdd(1, .seq_cst);
        return;
    };
    if (!ok) {
        _ = failures.fetchAdd(1, .seq_cst);
    }
}

fn projectRootFromExeDir(allocator: std.mem.Allocator, exe_dir: []const u8) ![]const u8 {
    _ = exe_dir;
    return allocator.dupe(u8, ".");
}

fn exeName(comptime base: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) base ++ ".exe" else base;
}

fn listSuites(available: []const Suite, file: zig_api.File) !void {
    _ = file;
    for (available) |suite| {
        std.log.info("{s}: {s}\n", .{ suite.name, suite.description });
    }
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: test_harness [options]
        \\Options:
        \\  --suite <list>      Comma-separated suite names (default: all)
        \\  --list-suites       List available suites
        \\  --tests-dir <dir>   Root directory to scan for tests
        \\  --jobs <n>, -j <n>  Parallel job count for suite runners
        \\  --filter <text>     Only run tests whose relative path contains this text
        \\  --gfortran <path>   Path to gfortran executable (NIST suite only)
        \\  --update-golden     Overwrite golden files (golden suite only)
        \\  -emit-llvm          Emit LLVM IR (default for suites)
        \\  --keep-going        Continue running suites after failures
        \\  --timeout <ms>      Per-test timeout passed to suite runners
        \\  --suite-timeout <ms> Suite timeout for each runner (0 disables, default: 0)
        \\  --verbose           Print command lines and suite names
        \\  --strict-diagnostics Enable strict dg-warning checks (gcc-dg suite only)
        \\  --strict-level <off|error|warning|full> Strict diagnostics level (gcc-dg suite only)
        \\  -h, --help          Show this help
        \\
    );
}

fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_value => |flag| try writer.interface.print("error: missing value for flag {s}\n", .{flag}),
        .unknown_flag => |flag| try writer.interface.print("error: unknown flag: {s}\n", .{flag}),
        .invalid_jobs => |value| try writer.interface.print("error: invalid jobs value: {s} (must be positive integer)\n", .{value}),
        .invalid_timeout => |value| try writer.interface.print("error: invalid timeout value: {s}\n", .{value}),
        .invalid_suite_timeout => |value| try writer.interface.print("error: invalid suite-timeout value: {s}\n", .{value}),
    }
    try writer.interface.flush();
}

const RunResult = struct {
    term: std.process.Child.Term,
    timed_out: bool,
};

fn runChildWithTimeoutStreaming(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ms: u64,
    output: *OutputMux,
) !RunResult {
    const io = zig_api.defaultIo();
    var env_map = try child_env.build(allocator, argv, cwd, ".test-harness-tmp");
    defer env_map.deinit();

    const started_ms: i64 = nowMs();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &env_map,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = builtin.os.tag == .windows,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try multi_reader.checkAnyError();

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    defer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    defer allocator.free(stderr_slice);
    output.write(zig_api.File.stdout(), stdout_slice);
    output.write(zig_api.File.stderr(), stderr_slice);

    const term = try child.wait(io);

    const finished_ms: i64 = nowMs();
    const elapsed_ms: u64 = if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;

    return .{
        .term = term,
        .timed_out = timeout_ms > 0 and elapsed_ms > timeout_ms,
    };
}

fn isZeroExit(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn logCommand(argv: []const []const u8) !void {
    var stdout_file = zig_api.File.stdout();
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(&buffer);
    for (argv, 0..) |arg, idx| {
        if (idx != 0) {
            try writer.interface.writeAll(" ");
        }
        try writer.interface.writeAll(arg);
    }
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

fn logStdout(comptime fmt: []const u8, args: anytype) !void {
    var stdout_file = zig_api.File.stdout();
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writer(&buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn logStderr(comptime fmt: []const u8, args: anytype) !void {
    var stderr_file = zig_api.File.stderr();
    var buffer: [4096]u8 = undefined;
    var writer = stderr_file.writer(&buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

const OutputMux = struct {
    fn write(self: *OutputMux, file: zig_api.File, data: []const u8) void {
        _ = self;
        _ = file.writeAll(data) catch {};
    }
};

fn streamPipeTo(pipe: std.Io.File, out: zig_api.File, output: *OutputMux) void {
    const io = zig_api.defaultIo();
    var reader_file = pipe;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = reader_file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return,
        };
        if (n == 0) break;
        output.write(out, buffer[0..n]);
    }
}

fn defaultJobs() usize {
    return std.Thread.getCpuCount() catch 1;
}

fn pathExists(path: []const u8) bool {
    zig_api.cwd().access(path, .{}) catch return false;
    return true;
}

fn nowMs() i64 {
    return @intCast(@divTrunc(zig_api.nowNs(), std.time.ns_per_ms));
}
