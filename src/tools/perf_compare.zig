const std = @import("std");
const tool_args = @import("tool_args.zig");
const tool_json = @import("tool_json.zig");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

const InputCase = struct {
    name: []const u8,
    median_ms: f64,
};

const InputReport = struct {
    schema_version: u32,
    generated_unix_ms: i64,
    iterations: u32,
    warmup: u32,
    cases: []const InputCase,
};

const Options = struct {
    base_path: []const u8,
    candidate_path: []const u8,
    max_regression_pct: f64,
    allow_missing_base: bool,
    show_help: bool,
};

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_max_regression: []const u8,
    missing_base: void,
    missing_candidate: void,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
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

    const base_report = try readReport(allocator, options.base_path);
    defer base_report.deinit();

    const candidate_report = try readReport(allocator, options.candidate_path);
    defer candidate_report.deinit();

    var regressions: usize = 0;
    var missing: usize = 0;

    for (candidate_report.value.cases) |candidate_case| {
        const base_case = findCase(base_report.value.cases, candidate_case.name);
        if (base_case == null) {
            if (options.allow_missing_base) {
                std.log.warn("missing base case: {s} (skipped)\n", .{candidate_case.name});
                continue;
            }
            std.log.err("missing base case: {s}\n", .{candidate_case.name});
            missing += 1;
            continue;
        }

        const base_median = base_case.?.median_ms;
        const candidate_median = candidate_case.median_ms;
        if (base_median <= 0.0) {
            std.log.warn("invalid base median <= 0 for {s}, skipping\n", .{candidate_case.name});
            continue;
        }

        const delta_pct = ((candidate_median - base_median) / base_median) * 100.0;
        const verdict = if (delta_pct > options.max_regression_pct) "REGRESSION" else "ok";
        std.log.info(
            "{s}: base={d:.3}ms candidate={d:.3}ms delta={d:.2}% [{s}]\n",
            .{ candidate_case.name, base_median, candidate_median, delta_pct, verdict },
        );
        if (delta_pct > options.max_regression_pct) regressions += 1;
    }

    if (missing > 0) {
        std.log.err("missing base cases: {d}\n", .{missing});
        return error.PerfComparisonMissingBaseCases;
    }
    if (regressions > 0) {
        std.log.err("performance regressions detected: {d}\n", .{regressions});
        return error.PerformanceRegressionDetected;
    }

    std.log.info("performance regression check passed\n", .{});
}

fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var base_path: ?[]const u8 = null;
    var candidate_path: ?[]const u8 = null;
    var max_regression_pct: f64 = 12.0;
    var allow_missing_base = false;
    var show_help = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--base")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            base_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--candidate")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            candidate_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-regression-pct")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            max_regression_pct = std.fmt.parseFloat(f64, args[i]) catch {
                return .{ .failure = .{ .invalid_max_regression = args[i] } };
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-missing-base")) {
            allow_missing_base = true;
            continue;
        }
        return .{ .failure = .{ .unknown_flag = arg } };
    }

    if (!show_help and base_path == null) return .{ .failure = .missing_base };
    if (!show_help and candidate_path == null) return .{ .failure = .missing_candidate };

    return .{ .success = .{
        .base_path = base_path orelse "",
        .candidate_path = candidate_path orelse "",
        .max_regression_pct = max_regression_pct,
        .allow_missing_base = allow_missing_base,
        .show_help = show_help,
    } };
}

fn readReport(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(InputReport) {
    return tool_json.readReport(InputReport, allocator, path);
}

fn findCase(cases: []const InputCase, name: []const u8) ?InputCase {
    for (cases) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_value => |flag| try writer.interface.print("error: missing value for flag {s}\n", .{flag}),
        .unknown_flag => |flag| try writer.interface.print("error: unknown flag: {s}\n", .{flag}),
        .invalid_max_regression => |value| try writer.interface.print("error: invalid max regression percentage: {s}\n", .{value}),
        .missing_base => try writer.interface.writeAll("error: missing --base <path>\n"),
        .missing_candidate => try writer.interface.writeAll("error: missing --candidate <path>\n"),
    }
    try writer.interface.flush();
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: perf_compare --base <path> --candidate <path> [--max-regression-pct <value>] [--allow-missing-base]
        \\Options:
        \\  --base <path>              Baseline JSON report path
        \\  --candidate <path>         Candidate JSON report path
        \\  --max-regression-pct <n>   Maximum allowed slowdown percentage (default: 12.0)
        \\  --allow-missing-base       Skip candidate cases missing in baseline
        \\  -h, --help                 Show this help
        \\
    );
}
