const common = @import("common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const fallback_policy = common.fallback_policy;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const zig_api = common.zig_api;
const runtime = @import("runtime.zig");
const cases = @import("cases.zig");
const runner_io = @import("runner_io.zig");

const LogState = runtime.LogState;
const parseRuntimeBackend = runtime.parseRuntimeBackend;
const defaultJobs = runtime.defaultJobs;
const defaultGfortran = cases.defaultGfortran;
const parseDialect = runner_io.parseDialect;
pub const Options = struct {
    tests_dir: []const u8,
    filter: ?[]const u8,
    gfortran_path: []const u8,
    runtime_backend: RuntimeBackend,
    emit: Col6Forge.EmitKind,
    dialect: Col6Forge.Dialect,
    show_help: bool,
    timeout_ms: u64,
    jobs: usize,
    incremental: bool,
    clean_cache: bool,
    profile_summary: bool,
    fallback_policy: fallback_policy.Policy,
};

const StageSamples = struct {
    values: std.ArrayList(u64) = .empty,

    fn deinit(self: *StageSamples, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }

    fn append(self: *StageSamples, allocator: std.mem.Allocator, ns: u64) !void {
        try self.values.append(allocator, ns);
    }

    fn sort(self: *StageSamples) void {
        std.sort.heap(u64, self.values.items, {}, std.sort.asc(u64));
    }
};

pub const PipelineProfileCollector = struct {
    enabled: bool,
    mutex: std.Io.Mutex = .init,
    count: usize = 0,
    failures: usize = 0,
    read: StageSamples = .{},
    normalize: StageSamples = .{},
    parse: StageSamples = .{},
    semantic: StageSamples = .{},
    codegen: StageSamples = .{},
    codegen_prelude: StageSamples = .{},
    codegen_common_layouts: StageSamples = .{},
    codegen_format_maps: StageSamples = .{},
    codegen_unit_emit: StageSamples = .{},
    codegen_intrinsic_wrappers: StageSamples = .{},
    codegen_string_globals: StageSamples = .{},
    codegen_entry_main: StageSamples = .{},
    codegen_decls: StageSamples = .{},
    total: StageSamples = .{},

    pub fn init(enabled: bool) PipelineProfileCollector {
        return .{ .enabled = enabled };
    }

    pub fn deinit(self: *PipelineProfileCollector, allocator: std.mem.Allocator) void {
        self.read.deinit(allocator);
        self.normalize.deinit(allocator);
        self.parse.deinit(allocator);
        self.semantic.deinit(allocator);
        self.codegen.deinit(allocator);
        self.codegen_prelude.deinit(allocator);
        self.codegen_common_layouts.deinit(allocator);
        self.codegen_format_maps.deinit(allocator);
        self.codegen_unit_emit.deinit(allocator);
        self.codegen_intrinsic_wrappers.deinit(allocator);
        self.codegen_string_globals.deinit(allocator);
        self.codegen_entry_main.deinit(allocator);
        self.codegen_decls.deinit(allocator);
        self.total.deinit(allocator);
    }

    pub fn record(self: *PipelineProfileCollector, allocator: std.mem.Allocator, sample: Col6Forge.PipelineProfileSample) !void {
        if (!self.enabled) return;
        self.mutex.lockUncancelable(zig_api.defaultIo());
        defer self.mutex.unlock(zig_api.defaultIo());

        self.count += 1;
        if (sample.failed_stage != .none) self.failures += 1;
        try self.read.append(allocator, sample.read_ns);
        try self.normalize.append(allocator, sample.normalize_ns);
        try self.parse.append(allocator, sample.parse_ns);
        try self.semantic.append(allocator, sample.semantic_ns);
        try self.codegen.append(allocator, sample.codegen_ns);
        try self.codegen_prelude.append(allocator, sample.codegen_prelude_ns);
        try self.codegen_common_layouts.append(allocator, sample.codegen_common_layouts_ns);
        try self.codegen_format_maps.append(allocator, sample.codegen_format_maps_ns);
        try self.codegen_unit_emit.append(allocator, sample.codegen_unit_emit_ns);
        try self.codegen_intrinsic_wrappers.append(allocator, sample.codegen_intrinsic_wrappers_ns);
        try self.codegen_string_globals.append(allocator, sample.codegen_string_globals_ns);
        try self.codegen_entry_main.append(allocator, sample.codegen_entry_main_ns);
        try self.codegen_decls.append(allocator, sample.codegen_decls_ns);
        try self.total.append(allocator, sample.total_ns);
    }

    pub fn print(self: *PipelineProfileCollector, log_state: *LogState) void {
        if (!self.enabled or self.count == 0) return;
        self.mutex.lockUncancelable(zig_api.defaultIo());
        defer self.mutex.unlock(zig_api.defaultIo());

        self.read.sort();
        self.normalize.sort();
        self.parse.sort();
        self.semantic.sort();
        self.codegen.sort();
        self.codegen_prelude.sort();
        self.codegen_common_layouts.sort();
        self.codegen_format_maps.sort();
        self.codegen_unit_emit.sort();
        self.codegen_intrinsic_wrappers.sort();
        self.codegen_string_globals.sort();
        self.codegen_entry_main.sort();
        self.codegen_decls.sort();
        self.total.sort();

        log_state.stdout(
            "pipeline profile summary: samples={d} failed={d}\n",
            .{ self.count, self.failures },
        );
        printStageLine(log_state, "read", self.read.values.items);
        printStageLine(log_state, "normalize", self.normalize.values.items);
        printStageLine(log_state, "parse", self.parse.values.items);
        printStageLine(log_state, "semantic", self.semantic.values.items);
        printStageLine(log_state, "codegen", self.codegen.values.items);
        printStageLine(log_state, "  cg.prelude", self.codegen_prelude.values.items);
        printStageLine(log_state, "  cg.common", self.codegen_common_layouts.values.items);
        printStageLine(log_state, "  cg.format", self.codegen_format_maps.values.items);
        printStageLine(log_state, "  cg.emit", self.codegen_unit_emit.values.items);
        printStageLine(log_state, "  cg.wrap", self.codegen_intrinsic_wrappers.values.items);
        printStageLine(log_state, "  cg.strings", self.codegen_string_globals.values.items);
        printStageLine(log_state, "  cg.main", self.codegen_entry_main.values.items);
        printStageLine(log_state, "  cg.decls", self.codegen_decls.values.items);
        printStageLine(log_state, "total", self.total.values.items);
    }
};

fn printStageLine(log_state: *LogState, name: []const u8, samples: []const u64) void {
    if (samples.len == 0) return;
    const p50 = percentileNs(samples, 0.50);
    const p95 = percentileNs(samples, 0.95);
    const max_ns = samples[samples.len - 1];
    const avg = avgNs(samples);
    log_state.stdout(
        "  {s}: avg_ms={d:.3} p50_ms={d:.3} p95_ms={d:.3} max_ms={d:.3}\n",
        .{ name, nsToMsF64(avg), nsToMs(p50), nsToMs(p95), nsToMs(max_ns) },
    );
}

fn percentileNs(samples: []const u64, q: f64) u64 {
    if (samples.len == 0) return 0;
    const clamped = @max(0.0, @min(1.0, q));
    const idx_f = clamped * @as(f64, @floatFromInt(samples.len - 1));
    const idx: usize = @intFromFloat(@round(idx_f));
    return samples[idx];
}

fn avgNs(samples: []const u64) f64 {
    if (samples.len == 0) return 0.0;
    var sum: f64 = 0.0;
    for (samples) |ns| sum += @as(f64, @floatFromInt(ns));
    return sum / @as(f64, @floatFromInt(samples.len));
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn nsToMsF64(ns: f64) f64 {
    return ns / 1_000_000.0;
}

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_runtime_backend: []const u8,
    invalid_std: []const u8,
    invalid_timeout: []const u8,
    invalid_jobs: []const u8,
    invalid_max_fallbacks: []const u8,
    invalid_fallback_policy: []const u8,
    duplicate_suite_flag: struct {
        first: []const u8,
        second: []const u8,
    },
    conflicting_suite_selection: struct {
        tests_dir: []const u8,
        suite_flag: []const u8,
    },
    conflicting_fallback_policy: void,
    missing_fallback_budget: void,
    redundant_fallback_budget: void,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

pub fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var tests_dir: []const u8 = "tests/NIST_F78_test_suite";
    var tests_dir_set = false;
    var filter: ?[]const u8 = null;
    var gfortran_path: []const u8 = defaultGfortran();
    var runtime_backend: RuntimeBackend = .c;
    var emit: Col6Forge.EmitKind = .llvm;
    var dialect: Col6Forge.Dialect = .default;
    var show_help = false;
    var timeout_ms: u64 = 120_000;
    var jobs = defaultJobs();
    var incremental = true;
    var clean_cache = false;
    var profile_summary = false;
    var fail_on_fallback = false;
    var fallback_mode: ?fallback_policy.Mode = null;
    var max_fallbacks: ?usize = null;
    var suite: ?TestSuite = null;
    var suite_flag: ?[]const u8 = null;

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
            tests_dir_set = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--filter")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            filter = args[i];
            continue;
        }
        if (std.ascii.eqlIgnoreCase(arg, "--fcvs21_f95")) {
            if (suite_flag != null) {
                return .{
                    .failure = .{
                        .duplicate_suite_flag = .{
                            .first = suite_flag.?,
                            .second = arg,
                        },
                    },
                };
            }
            suite = .fcvs21_f95;
            suite_flag = arg;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(arg, "--fcsv78")) {
            if (suite_flag != null) {
                return .{
                    .failure = .{
                        .duplicate_suite_flag = .{
                            .first = suite_flag.?,
                            .second = arg,
                        },
                    },
                };
            }
            suite = .fcsv78;
            suite_flag = arg;
            continue;
        }
        if (std.mem.eql(u8, arg, "--gfortran")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            gfortran_path = args[i];
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
        if (std.mem.eql(u8, arg, "--runtime-backend")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            runtime_backend = parseRuntimeBackend(args[i]) catch {
                return .{ .failure = .{ .invalid_runtime_backend = args[i] } };
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
        if (std.mem.eql(u8, arg, "--fallback-policy")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            fallback_mode = fallback_policy.parseMode(args[i]) catch {
                return .{ .failure = .{ .invalid_fallback_policy = args[i] } };
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--fail-on-fallback")) {
            fail_on_fallback = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-fallbacks")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            max_fallbacks = std.fmt.parseInt(usize, args[i], 10) catch {
                return .{ .failure = .{ .invalid_max_fallbacks = args[i] } };
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--incremental")) {
            incremental = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-incremental")) {
            incremental = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--clean-cache")) {
            clean_cache = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile-summary")) {
            profile_summary = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-emit-llvm")) {
            emit = .llvm;
            continue;
        }
        return .{ .failure = .{ .unknown_flag = arg } };
    }

    if (suite != null and tests_dir_set) {
        return .{
            .failure = .{
                .conflicting_suite_selection = .{
                    .tests_dir = tests_dir,
                    .suite_flag = suite_flag.?,
                },
            },
        };
    }

    if (suite != null) {
        tests_dir = suiteTestsDir(suite.?);
    }

    const resolved_fallback_policy = fallback_policy.Policy.resolve(
        fallback_mode,
        fail_on_fallback,
        max_fallbacks,
    ) catch |err| switch (err) {
        error.ConflictingFallbackPolicy => return .{ .failure = .conflicting_fallback_policy },
        error.MissingFallbackBudget => return .{ .failure = .missing_fallback_budget },
        error.RedundantFallbackBudget => return .{ .failure = .redundant_fallback_budget },
    };

    return .{ .success = .{
        .tests_dir = tests_dir,
        .filter = filter,
        .gfortran_path = gfortran_path,
        .runtime_backend = runtime_backend,
        .emit = emit,
        .dialect = dialect,
        .show_help = show_help,
        .timeout_ms = timeout_ms,
        .jobs = jobs,
        .incremental = incremental,
        .clean_cache = clean_cache,
        .profile_summary = profile_summary,
        .fallback_policy = resolved_fallback_policy,
    } };
}

pub fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_value => |flag| try writer.interface.print("error: missing value for flag {s}\n", .{flag}),
        .unknown_flag => |flag| try writer.interface.print("error: unknown flag: {s}\n", .{flag}),
        .invalid_runtime_backend => |value| try writer.interface.print("error: invalid runtime backend: {s} (expected c or zig)\n", .{value}),
        .invalid_std => |value| try writer.interface.print("error: invalid Fortran standard: {s} (expected default, f95, f77, or legacy)\n", .{value}),
        .invalid_timeout => |value| try writer.interface.print("error: invalid timeout value: {s}\n", .{value}),
        .invalid_jobs => |value| try writer.interface.print("error: invalid jobs value: {s} (must be positive integer)\n", .{value}),
        .invalid_max_fallbacks => |value| try writer.interface.print("error: invalid max-fallbacks value: {s}\n", .{value}),
        .invalid_fallback_policy => |value| try writer.interface.print("error: invalid fallback policy: {s} (expected disabled, report, budget, or strict)\n", .{value}),
        .duplicate_suite_flag => |flags| try writer.interface.print("error: conflicting suite flags: {s} and {s}\n", .{ flags.first, flags.second }),
        .conflicting_suite_selection => |conflict| try writer.interface.print("error: cannot combine --tests-dir {s} with suite flag {s}\n", .{ conflict.tests_dir, conflict.suite_flag }),
        .conflicting_fallback_policy => try writer.interface.print("error: conflicting fallback policy flags\n", .{}),
        .missing_fallback_budget => try writer.interface.print("error: budget fallback policy requires --max-fallbacks <n>\n", .{}),
        .redundant_fallback_budget => try writer.interface.print("error: --max-fallbacks may only be used with implicit or explicit budget fallback policy\n", .{}),
    }
    try writer.interface.flush();
}

pub fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: verify_runner [--tests-dir <dir>] [--fcvs21_f95 | --fcsv78] [--filter <text>] [--std <default|f77>] [--runtime-backend <c|zig>] [--timeout <ms>] [--jobs <n>] [--incremental|--no-incremental] [--clean-cache] [--profile-summary] [-emit-llvm]
        \\Options:
        \\  --tests-dir <dir>  Root directory to scan for .f files (default: tests/NIST_F78_test_suite)
        \\  --fcvs21_f95       Use the Fortran 95 adapted NIST F78 suite
        \\  --fcsv78           Use the original NIST F78 suite
        \\  --filter <text>    Only run tests whose relative path contains this text
        \\  --std <mode>       Fortran dialect gate for pipeline runs (default: default)
        \\  --gfortran <path>  Path to gfortran executable (default: gfortran or gfortran.exe)
        \\  --runtime-backend  Runtime backend: c (default) or zig (experimental)
        \\  --timeout <ms>     Per-test timeout in milliseconds (default: 120000)
        \\  --jobs <n>, -j <n> Parallel job count (default: 1 on Windows, else min(CPU cores, 4))
        \\  --fallback-policy <mode> Fallback gate: disabled, report (default), budget, or strict
        \\  --fail-on-fallback      Compatibility alias for --fallback-policy strict
        \\  --max-fallbacks <n>     Budget threshold for fallback-policy budget (or implicit budget mode)
        \\  --incremental      Enable translation/object/runtime cache (default)
        \\  --no-incremental   Disable incremental cache and rebuild everything
        \\  --clean-cache      Delete zig-cache/verify/cache before running
        \\  --profile-summary  Print pipeline stage timing summary (p50/p95/max)
        \\  -emit-llvm         Emit LLVM IR (default)
        \\  -h, --help         Show this help
        \\
        \\Examples:
        \\  zig build verify -- --filter FM715
        \\  zig build verify -- --fcvs21_f95 --filter FM715
        \\  zig build verify -- --fcsv78 --filter FM715
        \\
    );
}

pub fn emitFallbackSummary(log_state: *LogState, tracker: *fallback_policy.Tracker) !void {
    if (!tracker.policy.shouldPrintSummary()) return;

    var summary_buf: [256]u8 = undefined;
    var summary_writer: std.Io.Writer = .fixed(&summary_buf);
    try fallback_policy.writeSummary(&summary_writer, tracker.stats);
    if (tracker.stats.total() > 0) {
        log_state.stderr("{s}\n", .{summary_writer.buffered()});
    } else {
        log_state.stdout("{s}\n", .{summary_writer.buffered()});
    }

    tracker.enforce() catch |err| {
        if (err == error.FallbackBudgetExceeded) {
            var budget_buf: [128]u8 = undefined;
            var budget_writer: std.Io.Writer = .fixed(&budget_buf);
            try fallback_policy.writeBudgetExceeded(
                &budget_writer,
                tracker.stats,
                tracker.policy.max_fallbacks.?,
            );
            log_state.stderr("{s}\n", .{budget_writer.buffered()});
        }
        return err;
    };
}

const TestSuite = enum {
    fcvs21_f95,
    fcsv78,
};

fn suiteTestsDir(suite: TestSuite) []const u8 {
    return switch (suite) {
        .fcvs21_f95 => "tests/NIST_F78_test_suite/fcvs21_f95",
        .fcsv78 => "tests/NIST_F78_test_suite/FCSV78",
    };
}

test "parseArgs recognizes verify fallback budget gate" {
    const args = [_][]const u8{
        "verify_runner",
        "--max-fallbacks",
        "2",
    };

    const options = switch (parseArgs(&args)) {
        .success => |opts| opts,
        .failure => |err| return err,
    };

    try std.testing.expectEqual(fallback_policy.Mode.budget, options.fallback_policy.mode);
    try std.testing.expectEqual(@as(?usize, 2), options.fallback_policy.max_fallbacks);
}

test "parseArgs recognizes verify strict fallback gate" {
    const args = [_][]const u8{
        "verify_runner",
        "--fail-on-fallback",
    };

    const options = switch (parseArgs(&args)) {
        .success => |opts| opts,
        .failure => |err| return err,
    };

    try std.testing.expectEqual(fallback_policy.Mode.strict, options.fallback_policy.mode);
}

