const std = @import("std");
const tool_args = @import("tool_args.zig");
const child_env = @import("child_env.zig");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

const BenchCaseSpec = struct {
    name: []const u8,
    step: []const u8,
    filter: []const u8,
};

const CaseReport = struct {
    name: []const u8,
    step: []const u8,
    filter: []const u8,
    samples_ms: []const u64,
    median_ms: f64,
    mean_ms: f64,
};

const BenchReport = struct {
    schema_version: u32,
    generated_unix_ms: i64,
    iterations: u32,
    warmup: u32,
    cases: []const CaseReport,
};

const Options = struct {
    output_path: ?[]const u8,
    iterations: u32,
    warmup: u32,
    timeout_ms: u64,
    case_filter: ?[]const u8,
    show_help: bool,
};

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_iterations: []const u8,
    invalid_warmup: []const u8,
    invalid_timeout: []const u8,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

const default_cases = [_]BenchCaseSpec{
    .{ .name = "blas:xblat3d", .step = "blas-verify", .filter = "xblat3d" },
    .{ .name = "lapack:xlintstds", .step = "lapack-verify", .filter = "xlintstds" },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try tool_args.allocArgs(allocator, init.minimal.args);
    defer tool_args.freeArgs(allocator, args);

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

    const cases = try collectSelectedCases(allocator, options.case_filter);
    defer allocator.free(cases);
    if (cases.len == 0) {
        std.log.err("no benchmark cases selected\n", .{});
        return error.NoCasesSelected;
    }

    var reports: std.ArrayList(CaseReport) = .empty;
    defer {
        for (reports.items) |item| allocator.free(item.samples_ms);
        reports.deinit(allocator);
    }

    for (cases, 0..) |case_spec, idx| {
        std.log.info("[{d}/{d}] benchmark {s}\n", .{ idx + 1, cases.len, case_spec.name });

        var warmup_idx: u32 = 0;
        while (warmup_idx < options.warmup) : (warmup_idx += 1) {
            _ = try runCaseOnce(allocator, init, case_spec, options.timeout_ms);
        }

        var samples: std.ArrayList(u64) = .empty;
        defer samples.deinit(allocator);
        var iter_idx: u32 = 0;
        while (iter_idx < options.iterations) : (iter_idx += 1) {
            const elapsed_ms = try runCaseOnce(allocator, init, case_spec, options.timeout_ms);
            std.log.info("  run {d}/{d}: {d} ms\n", .{ iter_idx + 1, options.iterations, elapsed_ms });
            try samples.append(allocator, elapsed_ms);
        }

        const mean_ms = computeMean(samples.items);
        const median_ms = try computeMedian(allocator, samples.items);
        const owned_samples = try samples.toOwnedSlice(allocator);

        try reports.append(allocator, .{
            .name = case_spec.name,
            .step = case_spec.step,
            .filter = case_spec.filter,
            .samples_ms = owned_samples,
            .median_ms = median_ms,
            .mean_ms = mean_ms,
        });
    }

    const report = BenchReport{
        .schema_version = 1,
        .generated_unix_ms = zig_api.unixMs(),
        .iterations = options.iterations,
        .warmup = options.warmup,
        .cases = reports.items,
    };

    if (options.output_path) |path| {
        try ensureParentDir(path);
        var out_file = try zig_api.cwd().createFile(path, .{ .truncate = true });
        defer out_file.close();
        try writeJsonReport(out_file, report);
        std.log.info("wrote benchmark report: {s}\n", .{path});
    } else {
        try writeJsonReport(zig_api.File.stdout(), report);
    }
}

fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var output_path: ?[]const u8 = null;
    var iterations: u32 = 3;
    var warmup: u32 = 2;
    var timeout_ms: u64 = 600_000;
    var case_filter: ?[]const u8 = null;
    var show_help = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            output_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--iterations")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            iterations = std.fmt.parseInt(u32, args[i], 10) catch {
                return .{ .failure = .{ .invalid_iterations = args[i] } };
            };
            if (iterations == 0) return .{ .failure = .{ .invalid_iterations = args[i] } };
            continue;
        }
        if (std.mem.eql(u8, arg, "--warmup")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            warmup = std.fmt.parseInt(u32, args[i], 10) catch {
                return .{ .failure = .{ .invalid_warmup = args[i] } };
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
        if (std.mem.eql(u8, arg, "--case-filter")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            case_filter = args[i];
            continue;
        }
        return .{ .failure = .{ .unknown_flag = arg } };
    }

    return .{ .success = .{
        .output_path = output_path,
        .iterations = iterations,
        .warmup = warmup,
        .timeout_ms = timeout_ms,
        .case_filter = case_filter,
        .show_help = show_help,
    } };
}

fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_value => |flag| try writer.interface.print("error: missing value for flag {s}\n", .{flag}),
        .unknown_flag => |flag| try writer.interface.print("error: unknown flag: {s}\n", .{flag}),
        .invalid_iterations => |value| try writer.interface.print("error: invalid iterations value: {s}\n", .{value}),
        .invalid_warmup => |value| try writer.interface.print("error: invalid warmup value: {s}\n", .{value}),
        .invalid_timeout => |value| try writer.interface.print("error: invalid timeout value: {s}\n", .{value}),
    }
    try writer.interface.flush();
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: perf_bench [--output <path>] [--iterations <n>] [--warmup <n>] [--timeout <ms>] [--case-filter <text>]
        \\Options:
        \\  --output <path>       Write JSON benchmark report to this file
        \\  --iterations <n>      Number of measured runs per case (default: 3)
        \\  --warmup <n>          Number of warmup runs per case (default: 2)
        \\  --timeout <ms>        Timeout passed to suite runners (default: 600000)
        \\  --case-filter <text>  Only run case names containing this text
        \\  -h, --help            Show this help
        \\Default benchmark cases:
        \\  blas:xblat3d     -> zig build blas-verify -- --filter xblat3d
        \\  lapack:xlintstds -> zig build lapack-verify -- --filter xlintstds
        \\
    );
}

fn collectSelectedCases(allocator: std.mem.Allocator, case_filter: ?[]const u8) ![]BenchCaseSpec {
    var list: std.ArrayList(BenchCaseSpec) = .empty;
    for (default_cases) |case_spec| {
        if (case_filter) |needle| {
            if (!std.mem.containsAtLeast(u8, case_spec.name, 1, needle)) continue;
        }
        try list.append(allocator, case_spec);
    }
    return list.toOwnedSlice(allocator);
}

fn runCaseOnce(allocator: std.mem.Allocator, init: std.process.Init, case_spec: BenchCaseSpec, timeout_ms: u64) !u64 {
    const timeout_arg = try std.fmt.allocPrint(allocator, "{d}", .{timeout_ms});
    defer allocator.free(timeout_arg);
    const cache_dir = Col6Forge.process_args.getEnvVarOwned(allocator, init, "COL6FORGE_ZIG_CACHE_DIR") catch null;
    defer if (cache_dir) |value| allocator.free(value);
    const global_cache_dir = Col6Forge.process_args.getEnvVarOwned(allocator, init, "COL6FORGE_ZIG_GLOBAL_CACHE_DIR") catch null;
    defer if (global_cache_dir) |value| allocator.free(value);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "zig",
        "build",
    });
    if (cache_dir) |value| {
        try argv.appendSlice(allocator, &.{ "--cache-dir", value });
    }
    if (global_cache_dir) |value| {
        try argv.appendSlice(allocator, &.{ "--global-cache-dir", value });
    }
    try argv.appendSlice(allocator, &.{
        case_spec.step,
        "--",
        "--filter",
        case_spec.filter,
        "--incremental",
        "--timeout",
        timeout_arg,
    });

    const resolved_argv = try zig_api.resolveZigArgv(allocator, argv.items);
    defer resolved_argv.deinit(allocator);
    var env_map = try child_env.build(allocator, resolved_argv.argv, null, ".perf-bench-tmp");
    defer env_map.deinit();

    const started_ms = nowMs();

    const io = zig_api.defaultIo();
    var child = try std.process.spawn(io, .{
        .argv = resolved_argv.argv,
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = false,
    });
    defer child.kill(io);
    const term = try child.wait(io);

    const finished_ms = nowMs();
    const elapsed_ms: u64 = if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;

    if (!isZeroExit(term)) {
        std.log.err("benchmark command failed ({s})\n", .{case_spec.name});
        return error.BenchmarkCommandFailed;
    }

    return elapsed_ms;
}

fn computeMean(values: []const u64) f64 {
    if (values.len == 0) return 0.0;
    var total: u128 = 0;
    for (values) |value| total += value;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(values.len));
}

fn computeMedian(allocator: std.mem.Allocator, values: []const u64) !f64 {
    if (values.len == 0) return 0.0;
    const sorted = try allocator.dupe(u64, values);
    defer allocator.free(sorted);

    std.sort.heap(u64, sorted, {}, struct {
        fn lessThan(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lessThan);

    const mid = sorted.len / 2;
    if (sorted.len % 2 == 1) {
        return @as(f64, @floatFromInt(sorted[mid]));
    }
    return (@as(f64, @floatFromInt(sorted[mid - 1])) + @as(f64, @floatFromInt(sorted[mid]))) / 2.0;
}

fn writeJsonReport(file: zig_api.File, report: BenchReport) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    try zig_api.cwd().makePath(dir);
}

fn isZeroExit(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn nowMs() i64 {
    return @intCast(@divTrunc(zig_api.nowNs(), std.time.ns_per_ms));
}
