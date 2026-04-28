const common = @import("blas_runner/common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const BlasCase = common.BlasCase;
const ALL_CASES = common.ALL_CASES;

const build_helpers = @import("blas_runner/build_helpers.zig");
const io_compare = @import("blas_runner/io_compare.zig");
const cli_args = Col6Forge.process_args;
const allocArgs = cli_args.allocArgs;
const freeArgs = cli_args.freeArgs;
const getEnvVarOwned = cli_args.getEnvVarOwned;

const RuntimeArtifacts = build_helpers.RuntimeArtifacts;
const prepareRuntimeArtifacts = build_helpers.prepareRuntimeArtifacts;
const buildSourcePaths = build_helpers.buildSourcePaths;
const maybePatchDriverForDeterministicRandom = build_helpers.maybePatchDriverForDeterministicRandom;
const compileReference = build_helpers.compileReference;
const selectTranslatedSources = build_helpers.selectTranslatedSources;
const translateSources = build_helpers.translateSources;
const compileTranslated = build_helpers.compileTranslated;
const parseSummaryOutputName = build_helpers.parseSummaryOutputName;
const readOptionalFile = build_helpers.readOptionalFile;
const computeRuntimeCacheKey = build_helpers.computeRuntimeCacheKey;
const computeCompilerCacheKey = build_helpers.computeCompilerCacheKey;
const cleanupWorkDir = build_helpers.cleanupWorkDir;
const buildExePath = build_helpers.buildExePath;
const file_ops = Col6Forge.file_ops;
const ProcessResult = io_compare.ProcessResult;
const runProcessCaptureWithInput = io_compare.runProcessCaptureWithInput;
const Comparator = io_compare.Comparator;
const zig_api = Col6Forge.zig_api;
const Options = struct {
    blas_dir: []const u8,
    testing_dir: ?[]const u8,
    filter: ?[]const u8,
    gfortran_path: []const u8,
    runtime_backend: RuntimeBackend,
    timeout_ms: u64,
    keep_workdir: bool,
    translate_f90: bool,
    translate_driver: bool,
    show_help: bool,
    emit: Col6Forge.EmitKind,
    incremental: bool,
    clean_cache: bool,
};

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_runtime_backend: []const u8,
    invalid_timeout: []const u8,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

fn workDirExeArg(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (builtin.os.tag == .windows) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "./{s}", .{base});
}

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

    const testing_dir = options.testing_dir orelse try std.fs.path.join(arena_allocator, &.{ options.blas_dir, "TESTING" });

    const root_path = try allocator.dupe(u8, ".");
    defer allocator.free(root_path);

    const cache_rel = try std.fs.path.join(allocator, &.{ "zig-cache", "blas-verify", "cache", HOST_CACHE_TAG });
    defer allocator.free(cache_rel);
    const cache_dir = if (builtin.os.tag == .linux)
        try zig_api.runnerWorkDir(allocator, root_path, "blas-verify-cache", HOST_CACHE_TAG)
    else
        try std.fs.path.join(allocator, &.{ root_path, cache_rel });
    defer allocator.free(cache_dir);
    if (options.clean_cache) cleanupWorkDir(cache_dir);
    try zig_api.cwd().makePath(cache_dir);
    const runtime_cache_key = try computeRuntimeCacheKey(allocator, root_path);
    defer allocator.free(runtime_cache_key);
    const compiler_cache_key = try computeCompilerCacheKey(allocator, root_path);
    defer allocator.free(compiler_cache_key);

    var gfortran_cmd = options.gfortran_path;
    if (std.mem.eql(u8, gfortran_cmd, defaultGfortran())) {
        if (getEnvVarOwned(allocator, init, "GFORTRAN") catch null) |value| {
            defer allocator.free(value);
            gfortran_cmd = try arena_allocator.dupe(u8, value);
        } else if (getEnvVarOwned(allocator, init, "FC") catch null) |value| {
            defer allocator.free(value);
            gfortran_cmd = try arena_allocator.dupe(u8, value);
        }
    }

    const cases = try collectCases(arena_allocator, options.filter);
    if (cases.len == 0) {
        std.log.warn("no BLAS cases selected\n", .{});
        return;
    }

    var failures: usize = 0;
    for (cases, 0..) |case, idx| {
        std.log.info("[{d}/{d}] Running {s}\n", .{ idx + 1, cases.len, case.name });
        const ok = processCase(
            allocator,
            root_path,
            cache_dir,
            runtime_cache_key,
            compiler_cache_key,
            options.blas_dir,
            testing_dir,
            gfortran_cmd,
            case,
            options,
        ) catch |err| {
            std.log.err("internal error: {s} ({s})\n", .{ case.name, @errorName(err) });
            failures += 1;
            continue;
        };
        if (!ok) failures += 1;
    }

    if (failures > 0) {
        std.log.err("BLAS verification failed: {d}\n", .{failures});
        return error.BlasVerificationFailed;
    }

    std.log.info("BLAS verification passed\n", .{});
}

fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var blas_dir: []const u8 = "tests/BLAS-3.12.0";
    var testing_dir: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var gfortran_path: []const u8 = defaultGfortran();
    var runtime_backend: RuntimeBackend = .c;
    var timeout_ms: u64 = 120_000;
    var keep_workdir = false;
    var translate_f90 = false;
    var translate_driver = false;
    var show_help = false;
    var emit: Col6Forge.EmitKind = .llvm;
    var incremental = true;
    var clean_cache = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--blas-dir")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            blas_dir = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--testing-dir")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            testing_dir = args[i];
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
        if (std.mem.eql(u8, arg, "--keep-workdir")) {
            keep_workdir = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--translate-f90")) {
            translate_f90 = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-translate-f90")) {
            translate_f90 = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--translate-driver")) {
            translate_driver = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-translate-driver")) {
            translate_driver = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-emit-llvm")) {
            emit = .llvm;
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
        return .{ .failure = .{ .unknown_flag = arg } };
    }

    return .{ .success = .{
        .blas_dir = blas_dir,
        .testing_dir = testing_dir,
        .filter = filter,
        .gfortran_path = gfortran_path,
        .runtime_backend = runtime_backend,
        .timeout_ms = timeout_ms,
        .keep_workdir = keep_workdir,
        .translate_f90 = translate_f90,
        .translate_driver = translate_driver,
        .show_help = show_help,
        .emit = emit,
        .incremental = incremental,
        .clean_cache = clean_cache,
    } };
}

fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_value => |flag| try writer.interface.print("error: missing value for flag {s}\n", .{flag}),
        .unknown_flag => |flag| try writer.interface.print("error: unknown flag: {s}\n", .{flag}),
        .invalid_runtime_backend => |value| try writer.interface.print("error: invalid runtime backend: {s} (expected c or zig)\n", .{value}),
        .invalid_timeout => |value| try writer.interface.print("error: invalid timeout value: {s}\n", .{value}),
    }
    try writer.interface.flush();
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: blas_runner [--blas-dir <dir>] [--testing-dir <dir>] [--filter <text>] [--gfortran <path>] [--runtime-backend <c|zig>] [--timeout <ms>] [--keep-workdir] [--translate-f90] [--no-translate-f90] [--incremental|--no-incremental] [--clean-cache]
        \\Options:
        \\  --blas-dir <dir>     BLAS root directory (default: tests/BLAS-3.12.0)
        \\  --testing-dir <dir>  BLAS testing directory (default: <blas-dir>/TESTING)
        \\  --filter <text>      Run only case names containing text (e.g. xblat3d)
        \\  --gfortran <path>    Path to gfortran executable
        \\  --runtime-backend    Runtime backend: c (default) or zig (experimental)
        \\  --timeout <ms>       Per-command timeout in milliseconds (default: 120000)
        \\  --keep-workdir       Keep zig-cache/blas-verify/<case> even on success
        \\  --translate-f90      Translate BLAS .f90 sources (experimental, opt-in)
        \\  --no-translate-f90   Keep BLAS .f90 sources on gfortran fallback side (default)
        \\  --translate-driver   Translate BLAS test driver source (experimental)
        \\  --no-translate-driver
        \\                       Keep BLAS test driver on gfortran side (default)
        \\  --incremental        Enable translation/object/runtime cache (default)
        \\  --no-incremental     Disable incremental cache and rebuild everything
        \\  --clean-cache        Delete zig-cache/blas-verify/cache before running
        \\  -emit-llvm           Emit LLVM IR (default)
        \\  -h, --help           Show this help
        \\Examples:
        \\  zig build blas-verify -- --filter xblat3d
        \\  zig build blas-verify -- --filter xblat3 --keep-workdir
        \\  zig build blas-verify -- --blas-dir tests/BLAS-3.12.0
        \\
    );
}

fn defaultGfortran() []const u8 {
    return if (builtin.os.tag == .windows) "gfortran.exe" else "gfortran";
}

fn parseRuntimeBackend(text: []const u8) !RuntimeBackend {
    if (std.ascii.eqlIgnoreCase(text, "c")) return .c;
    if (std.ascii.eqlIgnoreCase(text, "zig")) return .zig;
    return error.InvalidRuntimeBackend;
}

fn collectCases(allocator: std.mem.Allocator, filter: ?[]const u8) ![]BlasCase {
    var list: std.ArrayList(BlasCase) = .empty;
    for (ALL_CASES) |case| {
        if (filter) |needle| {
            if (!std.mem.containsAtLeast(u8, case.name, 1, needle)) continue;
        }
        try list.append(allocator, case);
    }
    return list.toOwnedSlice(allocator);
}

fn processCase(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cache_dir: []const u8,
    runtime_cache_key: []const u8,
    compiler_cache_key: []const u8,
    blas_dir: []const u8,
    testing_dir: []const u8,
    gfortran_cmd: []const u8,
    case: BlasCase,
    options: Options,
) !bool {
    const work_dir = try zig_api.runnerWorkDir(allocator, root_path, "blas-verify", case.name);
    defer allocator.free(work_dir);
    cleanupWorkDir(work_dir);
    try zig_api.cwd().makePath(work_dir);

    const ref_dir = try std.fs.path.join(allocator, &.{ work_dir, "ref" });
    defer allocator.free(ref_dir);
    const test_dir = try std.fs.path.join(allocator, &.{ work_dir, "test" });
    defer allocator.free(test_dir);
    const ll_dir = try std.fs.path.join(allocator, &.{ work_dir, "translated" });
    defer allocator.free(ll_dir);

    try zig_api.cwd().makePath(ref_dir);
    try zig_api.cwd().makePath(test_dir);
    try zig_api.cwd().makePath(ll_dir);

    var input_data: ?[]const u8 = null;
    if (case.input) |input_name| {
        const input_path = try std.fs.path.join(allocator, &.{ testing_dir, input_name });
        defer allocator.free(input_path);
        input_data = try zig_api.cwd().readFileAlloc(allocator, input_path, 16 * 1024 * 1024);
    }
    defer if (input_data) |buf| allocator.free(buf);

    const summary_name = if (input_data) |buf| parseSummaryOutputName(allocator, buf) catch null else null;
    defer if (summary_name) |name| allocator.free(name);

    var source_paths = try buildSourcePaths(allocator, root_path, blas_dir, testing_dir, case);
    defer {
        for (source_paths) |path| allocator.free(path);
        allocator.free(source_paths);
    }
    if (try maybePatchDriverForDeterministicRandom(allocator, source_paths[0], work_dir)) |patched_driver| {
        allocator.free(source_paths[0]);
        source_paths[0] = patched_driver;
    }

    const ref_exe = try buildExePath(allocator, ref_dir, "ref");
    defer allocator.free(ref_exe);
    const cached_ref_exe = try buildReferenceExePath(allocator, cache_dir, case.name, gfortran_cmd, source_paths, options.incremental);
    defer allocator.free(cached_ref_exe);
    if (options.incremental and file_ops.pathExists(cached_ref_exe)) {
        try file_ops.copyExecutable(cached_ref_exe, ref_exe);
    } else {
        const compile_target = if (options.incremental) cached_ref_exe else ref_exe;
        const ref_ok = try compileReference(allocator, gfortran_cmd, compile_target, source_paths, options.timeout_ms, ref_dir);
        if (!ref_ok) {
            std.log.err("reference compile failed: {s}\n", .{case.name});
            return false;
        }
        if (options.incremental) try file_ops.copyExecutable(cached_ref_exe, ref_exe);
    }

    const trans_sources = try selectTranslatedSources(allocator, source_paths, options.translate_f90, options.translate_driver);
    defer allocator.free(trans_sources);

    const ll_paths = try translateSources(allocator, ll_dir, cache_dir, compiler_cache_key, trans_sources, options.emit, options.incremental);
    defer {
        for (ll_paths) |path| allocator.free(path);
        allocator.free(ll_paths);
    }

    const test_exe = try buildExePath(allocator, test_dir, "test");
    defer allocator.free(test_exe);
    const test_compile_ok = try compileTranslated(
        allocator,
        root_path,
        gfortran_cmd,
        test_exe,
        source_paths,
        trans_sources,
        ll_paths,
        cache_dir,
        runtime_cache_key,
        options.runtime_backend,
        options.timeout_ms,
        test_dir,
        options.incremental,
    );
    if (!test_compile_ok) {
        std.log.err("translated compile failed: {s}\n", .{case.name});
        return false;
    }

    const ref_run_arg = try workDirExeArg(allocator, ref_exe);
    defer allocator.free(ref_run_arg);
    const ref_run = try runProcessCaptureWithInput(allocator, &.{ref_run_arg}, ref_dir, input_data, options.timeout_ms);
    defer ref_run.deinit(allocator);
    if (ref_run.timed_out) {
        std.log.warn("timeout: reference run {s}\n", .{case.name});
        return false;
    }

    const test_run_arg = try workDirExeArg(allocator, test_exe);
    defer allocator.free(test_run_arg);
    const test_run = try runProcessCaptureWithInput(allocator, &.{test_run_arg}, test_dir, input_data, options.timeout_ms);
    defer test_run.deinit(allocator);
    if (test_run.timed_out) {
        std.log.warn("timeout: translated run {s}\n", .{case.name});
        return false;
    }

    const output_cmp = try Comparator.compare(allocator, ref_run.term, test_run.term, ref_run.stdout, test_run.stdout);
    defer if (output_cmp.diff) |d| allocator.free(d);
    if (!output_cmp.ok) {
        std.log.warn("stdout mismatch: {s}\n{s}\n", .{ case.name, output_cmp.diff.? });
        return false;
    }

    if (summary_name) |name| {
        const ref_summary = try readOptionalFile(allocator, ref_dir, name);
        defer if (ref_summary) |buf| allocator.free(buf);
        const test_summary = try readOptionalFile(allocator, test_dir, name);
        defer if (test_summary) |buf| allocator.free(buf);

        if (ref_summary == null and test_summary == null) {
            // no summary output on either side
        } else if (ref_summary == null or test_summary == null) {
            std.log.warn("summary file presence mismatch: {s} ({s})\n", .{ case.name, name });
            return false;
        } else {
            const summary_cmp = try Comparator.compareText(allocator, ref_summary.?, test_summary.?);
            defer if (summary_cmp.diff) |d| allocator.free(d);
            if (!summary_cmp.ok) {
                std.log.warn("summary mismatch: {s} ({s})\n{s}\n", .{ case.name, name, summary_cmp.diff.? });
                return false;
            }
        }
    }

    if (!options.keep_workdir) {
        cleanupWorkDir(work_dir);
    }

    return true;
}

fn buildReferenceExePath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    case_name: []const u8,
    gfortran_cmd: []const u8,
    source_paths: []const []const u8,
    incremental: bool,
) ![]const u8 {
    if (!incremental) return buildExePath(allocator, cache_dir, "ref_uncached");

    const cache_key = try computeReferenceCacheKey(allocator, gfortran_cmd, source_paths);
    defer allocator.free(cache_key);
    const base_name = try std.fmt.allocPrint(allocator, "ref_v{d}_{s}_{s}", .{ CACHE_SCHEMA_VERSION, case_name, cache_key });
    defer allocator.free(base_name);
    return buildExePath(allocator, cache_dir, base_name);
}

fn computeReferenceCacheKey(
    allocator: std.mem.Allocator,
    gfortran_cmd: []const u8,
    source_paths: []const []const u8,
) ![]const u8 {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(gfortran_cmd);
    for (source_paths) |path| {
        hasher.update(std.fs.path.basename(path));
        var digest = try file_ops.hashFileXx64(path);
        hasher.update(std.mem.asBytes(&digest));
    }
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{hasher.final()});
}
