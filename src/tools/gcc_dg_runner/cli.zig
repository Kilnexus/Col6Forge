const common = @import("common.zig");
const std = common.std;
const Col6Forge = common.Col6Forge;
const zig_api = Col6Forge.zig_api;
pub const Options = struct {
    tests_dir: []const u8,
    filter: ?[]const u8,
    emit: Col6Forge.EmitKind,
    timeout_ms: u64,
    jobs: usize,
    show_help: bool,
    verbose: bool,
    keep_work: bool,
    strict_level: StrictLevel,
};

pub const StrictLevel = enum {
    off,
    err_only,
    warning,
    full,
};

pub const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_timeout: []const u8,
    invalid_jobs: []const u8,
};

pub const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

pub fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var tests_dir: []const u8 = "tests/gcc-tests/gfortran.dg";
    var filter: ?[]const u8 = null;
    var emit: Col6Forge.EmitKind = .llvm;
    var timeout_ms: u64 = 120_000;
    var jobs = defaultJobs();
    var show_help = false;
    var verbose = false;
    var keep_work = false;
    var strict_level: StrictLevel = .off;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tests-dir")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            tests_dir = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--filter")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            filter = args[i];
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
        if (std.mem.eql(u8, arg, "-emit-llvm")) {
            emit = .llvm;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep-work")) {
            keep_work = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-diagnostics")) {
            strict_level = .warning;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-strict-diagnostics")) {
            strict_level = .off;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-level")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            const value = args[i];
            if (std.mem.eql(u8, value, "off")) {
                strict_level = .off;
            } else if (std.mem.eql(u8, value, "error")) {
                strict_level = .err_only;
            } else if (std.mem.eql(u8, value, "warning")) {
                strict_level = .warning;
            } else if (std.mem.eql(u8, value, "full")) {
                strict_level = .full;
            } else {
                return .{ .failure = .{ .unknown_flag = value } };
            }
            continue;
        }
        return .{ .failure = .{ .unknown_flag = arg } };
    }

    return .{ .success = .{
        .tests_dir = tests_dir,
        .filter = filter,
        .emit = emit,
        .timeout_ms = timeout_ms,
        .jobs = jobs,
        .show_help = show_help,
        .verbose = verbose,
        .keep_work = keep_work,
        .strict_level = strict_level,
    } };
}

pub fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
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

pub fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: gcc_dg_runner [--tests-dir <dir>] [--filter <text>] [--timeout <ms>] [--jobs <n>] [--keep-work] [--strict-diagnostics] [--strict-level <off|error|warning|full>] [-emit-llvm]
        \\Options:
        \\  --tests-dir <dir>  Root directory to scan for GCC gfortran.dg tests (default: tests/gcc-tests/gfortran.dg)
        \\  --filter <text>    Only run tests whose relative path contains this text
        \\  --timeout <ms>     Per-test timeout in milliseconds (default: 120000)
        \\  --jobs <n>, -j <n> Parallel job count (default: min(CPU cores, 4))
        \\  --keep-work        Keep zig-cache/gcc-dg/<case> work directories after each case
        \\  --strict-diagnostics    Fail on dg-warning mismatch (default: off)
        \\  --no-strict-diagnostics Disable strict warning matching
        \\  --strict-level <off|error|warning|full> Strictness level (default: off)
        \\  --verbose          Print additional skip/selection context
        \\  -emit-llvm         Emit LLVM IR (default)
        \\  -h, --help         Show this help
        \\
        \\Notes:
        \\  - Phase-1 executes `dg-do compile` tests.
        \\  - `dg-error` expectations are diagnostic metadata at strict-level off.
        \\  - `dg-error` failure and text matching start at strict-level error.
        \\  - `dg-warning` expectations are enforced in strict-level warning/full.
        \\  - `dg-message`/`dg-note`/`dg-bogus` expectations are enforced in strict-level full.
        \\  - `dg-output`/`dg-prune-output` expectations are enforced in strict-level full.
        \\  - Tests with unsupported `dg-options` language/runtime switches are skipped.
        \\  - Tests that require unsupported dejagnu diagnostics/target predicates/multi-source
        \\    orchestration are skipped and reported in summary.
        \\
    );
}

pub fn strictLevelLabel(level: StrictLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .err_only => "error",
        .warning => "warning",
        .full => "full",
    };
}

pub fn defaultJobs() usize {
    const cpu = std.Thread.getCpuCount() catch 1;
    return if (cpu > 4) 4 else cpu;
}
