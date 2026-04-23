const common = @import("lapack_runner/common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const fallback_policy = common.fallback_policy;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const MAX_RUN_OUTPUT_BYTES = common.MAX_RUN_OUTPUT_BYTES;
const LapackCase = common.LapackCase;
const SupportLibs = common.SupportLibs;
const ALL_CASES = common.ALL_CASES;

const build_helpers = @import("lapack_runner/build_helpers.zig");
const io_compare = @import("lapack_runner/io_compare.zig");
const cli_args = Col6Forge.process_args;
const allocArgs = cli_args.allocArgs;
const freeArgs = cli_args.freeArgs;
const getEnvVarOwned = cli_args.getEnvVarOwned;

const buildSupportLibs = build_helpers.buildSupportLibs;
const buildStaticLib = build_helpers.buildStaticLib;
const buildSourcePaths = build_helpers.buildSourcePaths;
const resolveCaseSourcesFromMakefile = build_helpers.resolveCaseSourcesFromMakefile;
const extractMakeVarSources = build_helpers.extractMakeVarSources;
const appendObjectTokensFromLine = build_helpers.appendObjectTokensFromLine;
const objectTokenToFortranSource = build_helpers.objectTokenToFortranSource;
const collectFortranSources = build_helpers.collectFortranSources;
const lessThanString = build_helpers.lessThanString;
const isFortranFile = build_helpers.isFortranFile;
const compileReferenceCase = build_helpers.compileReferenceCase;
const selectTranslatedSources = build_helpers.selectTranslatedSources;
const shouldTranslate = build_helpers.shouldTranslate;
const TranslateResult = build_helpers.TranslateResult;
const translateSources = build_helpers.translateSources;
const sourceInList = build_helpers.sourceInList;
const compileTranslatedCase = build_helpers.compileTranslatedCase;
const shouldLinkRuntimeArtifacts = build_helpers.shouldLinkRuntimeArtifacts;
const recordFallback = build_helpers.recordFallback;
const formatFallbackSummary = build_helpers.formatFallbackSummary;
const formatFallbackBudgetExceeded = build_helpers.formatFallbackBudgetExceeded;
const absolutizePath = build_helpers.absolutizePath;
const buildExePath = build_helpers.buildExePath;
const writeFile = build_helpers.writeFile;
const emitPipelineToFile = build_helpers.emitPipelineToFile;
const emitCacheTag = build_helpers.emitCacheTag;
const runtimeBackendTag = build_helpers.runtimeBackendTag;
const fileExistsAbsolute = build_helpers.fileExistsAbsolute;
const hashFileXx64 = build_helpers.hashFileXx64;
const copyFileAbsolute = build_helpers.copyFileAbsolute;
const buildSourceLlCachePath = build_helpers.buildSourceLlCachePath;
const buildTranslatedObjCachePath = build_helpers.buildTranslatedObjCachePath;
const getOrBuildTranslatedObject = build_helpers.getOrBuildTranslatedObject;
const computeRuntimeCacheKey = build_helpers.computeRuntimeCacheKey;
const computeCompilerCacheKey = build_helpers.computeCompilerCacheKey;
const printPipelineError = build_helpers.printPipelineError;
const cleanupWorkDir = build_helpers.cleanupWorkDir;
const RuntimeArtifacts = build_helpers.RuntimeArtifacts;
const prepareRuntimeArtifacts = build_helpers.prepareRuntimeArtifacts;
const ProcessResult = io_compare.ProcessResult;
const ProcessRedirectResult = io_compare.ProcessRedirectResult;
const runProcessCaptureWithInputPath = io_compare.runProcessCaptureWithInputPath;
const runProcessStreamToFilesWithInputPath = io_compare.runProcessStreamToFilesWithInputPath;
const runProcessPipeToFiles = io_compare.runProcessPipeToFiles;
const pumpPipeToFile = io_compare.pumpPipeToFile;
const runProcessCaptureWithInput = io_compare.runProcessCaptureWithInput;
const timeoutMonitor = io_compare.timeoutMonitor;
const terminateChildNoWait = io_compare.terminateChildNoWait;
const isZeroExit = io_compare.isZeroExit;
const exitCode = io_compare.exitCode;
const fileExists = io_compare.fileExists;
const buildRunArtifactPath = io_compare.buildRunArtifactPath;
const readFileLimitedAbsolute = io_compare.readFileLimitedAbsolute;
const retryStdoutComparisonWithCapturedRuns = io_compare.retryStdoutComparisonWithCapturedRuns;
const outputsEquivalent = io_compare.outputsEquivalent;
const equivalentTextWithNumericTolerance = io_compare.equivalentTextWithNumericTolerance;
const NumericToken = io_compare.NumericToken;
const numericTokensEquivalent = io_compare.numericTokensEquivalent;
const parseNumericToken = io_compare.parseNumericToken;
const isHorizontalSpace = io_compare.isHorizontalSpace;
const trimCr = io_compare.trimCr;
const isTimingLine = io_compare.isTimingLine;
const zig_api = Col6Forge.zig_api;
const Options = struct {
    lapack_dir: []const u8,
    testing_dir: ?[]const u8,
    filter: ?[]const u8,
    exact_case: ?[]const u8,
    gfortran_path: []const u8,
    runtime_backend: RuntimeBackend,
    timeout_ms: u64,
    keep_workdir: bool,
    translate_sources: bool,
    strict_translate: bool,
    fallback_policy: fallback_policy.Policy,
    emit: Col6Forge.EmitKind,
    show_help: bool,
    incremental: bool,
    clean_cache: bool,
    prepare_only: bool,
};

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    invalid_runtime_backend: []const u8,
    invalid_timeout: []const u8,
    invalid_max_fallbacks: []const u8,
    invalid_fallback_policy: []const u8,
    conflicting_fallback_policy: void,
    missing_fallback_budget: void,
    redundant_fallback_budget: void,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

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

    const root_path = try allocator.dupe(u8, ".");
    defer allocator.free(root_path);

    const cache_rel = try std.fs.path.join(allocator, &.{ "zig-cache", "lapack-verify", "cache", HOST_CACHE_TAG });
    defer allocator.free(cache_rel);
    if (options.clean_cache) cleanupWorkDir(cache_rel);
    try zig_api.cwd().makePath(cache_rel);
    const cache_dir = try std.fs.path.join(allocator, &.{ root_path, cache_rel });
    defer allocator.free(cache_dir);
    const runtime_cache_key = try computeRuntimeCacheKey(allocator, root_path);
    defer allocator.free(runtime_cache_key);
    const compiler_cache_key = try computeCompilerCacheKey(allocator, root_path);
    defer allocator.free(compiler_cache_key);

    const testing_dir = options.testing_dir orelse try std.fs.path.join(arena_allocator, &.{ options.lapack_dir, "TESTING" });
    const lin_dir = try std.fs.path.join(arena_allocator, &.{ testing_dir, "LIN" });
    const lapack_src_dir = try std.fs.path.join(arena_allocator, &.{ options.lapack_dir, "SRC" });
    const blas_src_dir = try std.fs.path.join(arena_allocator, &.{ options.lapack_dir, "BLAS", "SRC" });
    const matgen_dir = try std.fs.path.join(arena_allocator, &.{ testing_dir, "MATGEN" });
    const install_dir = try std.fs.path.join(arena_allocator, &.{ options.lapack_dir, "INSTALL" });

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

    const cases = try collectCases(arena_allocator, options.filter, options.exact_case);
    if (cases.len == 0) {
        std.log.warn("no LAPACK-lite cases selected\n", .{});
        return;
    }

    const common_rel = try std.fs.path.join(allocator, &.{ "zig-cache", "lapack-verify", "common", HOST_CACHE_TAG });
    defer allocator.free(common_rel);
    try zig_api.cwd().makePath(common_rel);
    const common_abs = try std.fs.path.join(allocator, &.{ root_path, common_rel });
    defer allocator.free(common_abs);

    const libs = try buildSupportLibs(
        allocator,
        root_path,
        common_abs,
        gfortran_cmd,
        options.timeout_ms,
        lapack_src_dir,
        blas_src_dir,
        matgen_dir,
        install_dir,
    );
    defer {
        allocator.free(libs.blas_lib);
        allocator.free(libs.lapack_lib);
        allocator.free(libs.tmg_lib);
    }

    const runtime_output_dir = if (options.incremental) cache_dir else common_abs;
    var runtime_artifacts = prepareRuntimeArtifacts(
        allocator,
        root_path,
        runtime_output_dir,
        options.runtime_backend,
        options.timeout_ms,
        runtime_cache_key,
        options.incremental,
    ) catch |err| {
        std.log.err("runtime backend prepare failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer runtime_artifacts.deinit(allocator);

    if (options.prepare_only) {
        std.log.info("LAPACK-lite preparation completed\n", .{});
        return;
    }

    var failures: usize = 0;
    var fallback_tracker = fallback_policy.Tracker.init(options.fallback_policy);
    for (cases, 0..) |case, i| {
        std.log.info("[{d}/{d}] Running {s}\n", .{ i + 1, cases.len, case.name });
        const ok = processCase(
            allocator,
            root_path,
            cache_dir,
            runtime_cache_key,
            compiler_cache_key,
            testing_dir,
            lin_dir,
            gfortran_cmd,
            case,
            libs,
            options,
            &fallback_tracker,
        ) catch |err| {
            std.log.err("internal error: {s} ({s})\n", .{ case.name, @errorName(err) });
            failures += 1;
            continue;
        };
        if (!ok) failures += 1;
    }

    if (options.fallback_policy.shouldPrintSummary()) {
        var summary_buf: [256]u8 = undefined;
        const text = try formatFallbackSummary(&summary_buf, fallback_tracker.stats);
        if (fallback_tracker.stats.total() > 0) {
            std.log.warn("{s}\n", .{text});
        } else {
            std.log.info("{s}\n", .{text});
        }
    }
    fallback_tracker.enforce() catch |err| {
        if (err == error.FallbackBudgetExceeded) {
            var budget_buf: [128]u8 = undefined;
            const text = try formatFallbackBudgetExceeded(
                &budget_buf,
                fallback_tracker.stats,
                fallback_tracker.policy.max_fallbacks.?,
            );
            std.log.err("{s}\n", .{text});
        }
        return err;
    };

    if (failures > 0) {
        std.log.err("LAPACK-lite verification failed: {d}\n", .{failures});
        return error.LapackVerificationFailed;
    }
    std.log.info("LAPACK-lite verification passed\n", .{});
}

fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var lapack_dir: []const u8 = "tests/LAPACK-lite-3.1.1";
    var testing_dir: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var exact_case: ?[]const u8 = null;
    var gfortran_path: []const u8 = defaultGfortran();
    var runtime_backend: RuntimeBackend = .c;
    var timeout_ms: u64 = 300_000;
    var keep_workdir = false;
    var translate_sources = true;
    var strict_translate = false;
    var fail_on_fallback = false;
    var fallback_mode: ?fallback_policy.Mode = null;
    var max_fallbacks: ?usize = null;
    var emit: Col6Forge.EmitKind = .llvm;
    var show_help = false;
    var incremental = true;
    var clean_cache = false;
    var prepare_only = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--lapack-dir")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            lapack_dir = args[i];
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
        if (std.mem.eql(u8, arg, "--case")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            exact_case = args[i];
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
        if (std.mem.eql(u8, arg, "--translate-sources")) {
            translate_sources = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-translate-sources")) {
            translate_sources = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-translate")) {
            strict_translate = true;
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
        if (std.mem.eql(u8, arg, "--prepare-only")) {
            prepare_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-emit-llvm")) {
            emit = .llvm;
            continue;
        }
        return .{ .failure = .{ .unknown_flag = arg } };
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
        .lapack_dir = lapack_dir,
        .testing_dir = testing_dir,
        .filter = filter,
        .exact_case = exact_case,
        .gfortran_path = gfortran_path,
        .runtime_backend = runtime_backend,
        .timeout_ms = timeout_ms,
        .keep_workdir = keep_workdir,
        .translate_sources = translate_sources,
        .strict_translate = strict_translate,
        .fallback_policy = resolved_fallback_policy,
        .emit = emit,
        .show_help = show_help,
        .incremental = incremental,
        .clean_cache = clean_cache,
        .prepare_only = prepare_only,
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
        .invalid_max_fallbacks => |value| try writer.interface.print("error: invalid max-fallbacks value: {s}\n", .{value}),
        .invalid_fallback_policy => |value| try writer.interface.print("error: invalid fallback policy: {s} (expected disabled, report, budget, or strict)\n", .{value}),
        .conflicting_fallback_policy => try writer.interface.print("error: conflicting fallback policy flags\n", .{}),
        .missing_fallback_budget => try writer.interface.print("error: budget fallback policy requires --max-fallbacks <n>\n", .{}),
        .redundant_fallback_budget => try writer.interface.print("error: --max-fallbacks may only be used with implicit or explicit budget fallback policy\n", .{}),
    }
    try writer.interface.flush();
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: lapack_runner [--lapack-dir <dir>] [--testing-dir <dir>] [--filter <text>] [--case <name>] [--gfortran <path>] [--runtime-backend <c|zig>] [--timeout <ms>] [--keep-workdir] [--incremental|--no-incremental] [--clean-cache] [--prepare-only]
        \\Options:
        \\  --lapack-dir <dir>      LAPACK-lite root directory (default: tests/LAPACK-lite-3.1.1)
        \\  --testing-dir <dir>     Testing directory (default: <lapack-dir>/TESTING)
        \\  --filter <text>         Run only case names containing text (e.g. xlintstds)
        \\  --case <name>           Run only the exact case name (e.g. xlintstzc)
        \\  --gfortran <path>       Path to gfortran executable
        \\  --runtime-backend       Runtime backend: c (default) or zig (experimental)
        \\  --timeout <ms>          Per-command timeout milliseconds (default: 300000)
        \\  --keep-workdir          Keep zig-cache/lapack-verify/<case> and /common
        \\  --translate-sources     Translate eligible case sources (default)
        \\  --no-translate-sources  Keep case sources on gfortran side
        \\  --strict-translate      Fail when any source translation fails (default: best-effort fallback)
        \\  --fallback-policy <mode> Fallback gate: disabled, report (default), budget, or strict
        \\  --fail-on-fallback      Compatibility alias for --fallback-policy strict
        \\  --max-fallbacks <n>     Budget threshold for fallback-policy budget (or implicit budget mode)
        \\  --incremental           Enable translation/object/runtime cache (default)
        \\  --no-incremental        Disable incremental cache and rebuild everything
        \\  --clean-cache           Delete zig-cache/lapack-verify/cache before running
        \\  --prepare-only          Build shared support libs/runtime cache and exit
        \\  -emit-llvm              Emit LLVM IR (default)
        \\  -h, --help              Show this help
        \\Examples:
        \\  zig build lapack-verify -- --filter xlintstds
        \\  zig build lapack-verify -- --case xeigtstz
        \\  zig build lapack-verify -- --no-translate-sources
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

fn collectCases(allocator: std.mem.Allocator, filter: ?[]const u8, exact_case: ?[]const u8) ![]LapackCase {
    var list: std.ArrayList(LapackCase) = .empty;
    for (ALL_CASES) |case| {
        if (exact_case) |needle| {
            if (!std.mem.eql(u8, case.name, needle)) continue;
        }
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
    testing_dir: []const u8,
    lin_dir: []const u8,
    gfortran_cmd: []const u8,
    case: LapackCase,
    libs: SupportLibs,
    options: Options,
    fallback_tracker: *fallback_policy.Tracker,
) !bool {
    _ = lin_dir;
    const work_rel = try std.fs.path.join(allocator, &.{ "zig-cache", "lapack-verify", case.name });
    defer allocator.free(work_rel);
    cleanupWorkDir(work_rel);
    try zig_api.cwd().makePath(work_rel);

    const work_abs = try std.fs.path.join(allocator, &.{ root_path, work_rel });
    defer allocator.free(work_abs);
    const ref_dir = try std.fs.path.join(allocator, &.{ work_abs, "ref" });
    defer allocator.free(ref_dir);
    const test_dir = try std.fs.path.join(allocator, &.{ work_abs, "test" });
    defer allocator.free(test_dir);
    const ll_dir = try std.fs.path.join(allocator, &.{ work_abs, "translated" });
    defer allocator.free(ll_dir);
    try zig_api.cwd().makePath(ref_dir);
    try zig_api.cwd().makePath(test_dir);
    try zig_api.cwd().makePath(ll_dir);

    const case_dir = try std.fs.path.join(allocator, &.{ testing_dir, case.suite_dir });
    defer allocator.free(case_dir);

    const source_names = try resolveCaseSourcesFromMakefile(allocator, case_dir, case.make_vars);
    defer {
        for (source_names) |name| allocator.free(name);
        allocator.free(source_names);
    }

    const source_paths = try buildSourcePaths(allocator, root_path, case_dir, source_names);
    defer {
        for (source_paths) |p| allocator.free(p);
        allocator.free(source_paths);
    }

    const ref_exe = try buildExePath(allocator, ref_dir, "ref");
    defer allocator.free(ref_exe);
    if (!try compileReferenceCase(allocator, gfortran_cmd, ref_exe, source_paths, libs, options.timeout_ms, ref_dir)) {
        return false;
    }

    const enable_translation = options.translate_sources and case.allow_translation;
    const candidate_sources = try selectTranslatedSources(allocator, source_paths, enable_translation);
    defer allocator.free(candidate_sources);
    const translated = try translateSources(
        allocator,
        ll_dir,
        cache_dir,
        compiler_cache_key,
        candidate_sources,
        options.emit,
        options.strict_translate,
        fallback_tracker,
        options.incremental,
    );
    defer {
        allocator.free(translated.sources);
        for (translated.ll_paths) |p| allocator.free(p);
        allocator.free(translated.ll_paths);
    }
    if (enable_translation) {
        std.log.info("  translated {d}/{d} source files\n", .{ translated.sources.len, candidate_sources.len });
    }

    const test_exe = try buildExePath(allocator, test_dir, "test");
    defer allocator.free(test_exe);
    if (!try compileTranslatedCase(
        allocator,
        root_path,
        gfortran_cmd,
        test_exe,
        source_paths,
        translated.sources,
        translated.ll_paths,
        cache_dir,
        runtime_cache_key,
        libs,
        options.runtime_backend,
        options.timeout_ms,
        test_dir,
        options.strict_translate,
        fallback_tracker,
        options.incremental,
    )) {
        return false;
    }

    for (case.inputs, 0..) |input_name, input_idx| {
        if (case.inputs.len > 1) {
            std.log.info("  input [{d}/{d}] {s}\n", .{ input_idx + 1, case.inputs.len, input_name });
        }
        const input_rel = try std.fs.path.join(allocator, &.{ testing_dir, input_name });
        defer allocator.free(input_rel);
        const input_path = try absolutizePath(allocator, root_path, input_rel);
        defer allocator.free(input_path);

        if (builtin.os.tag == .windows) {
            const ref_run = try runProcessCaptureWithInputPath(allocator, ref_exe, ref_dir, input_path, options.timeout_ms);
            defer ref_run.deinit(allocator);
            if (ref_run.timed_out) {
                std.log.warn("timeout: reference run {s} ({s})\n", .{ case.name, input_name });
                return false;
            }
            const test_run = try runProcessCaptureWithInputPath(allocator, test_exe, test_dir, input_path, options.timeout_ms);
            defer test_run.deinit(allocator);
            if (test_run.timed_out) {
                std.log.warn("timeout: translated run {s} ({s})\n", .{ case.name, input_name });
                return false;
            }

            const ref_code = exitCode(ref_run.term);
            const test_code = exitCode(test_run.term);
            if (ref_code != test_code) {
                std.log.warn("exit code mismatch: {s} ({s}) ref={d} test={d}\n", .{ case.name, input_name, ref_code, test_code });
                return false;
            }
            if (!outputsEquivalent(ref_run.stdout, test_run.stdout)) {
                std.log.warn("stdout mismatch: {s} ({s})\n", .{ case.name, input_name });
                return false;
            }
        } else {
            const ref_stdout_path = try buildRunArtifactPath(allocator, ref_dir, input_name, "stdout");
            defer allocator.free(ref_stdout_path);
            const ref_stderr_path = try buildRunArtifactPath(allocator, ref_dir, input_name, "stderr");
            defer allocator.free(ref_stderr_path);
            const test_stdout_path = try buildRunArtifactPath(allocator, test_dir, input_name, "stdout");
            defer allocator.free(test_stdout_path);
            const test_stderr_path = try buildRunArtifactPath(allocator, test_dir, input_name, "stderr");
            defer allocator.free(test_stderr_path);

            const ref_run = try runProcessStreamToFilesWithInputPath(
                allocator,
                ref_exe,
                ref_dir,
                input_path,
                ref_stdout_path,
                ref_stderr_path,
                options.timeout_ms,
            );
            if (ref_run.timed_out) {
                std.log.warn("timeout: reference run {s} ({s})\n", .{ case.name, input_name });
                return false;
            }
            const test_run = try runProcessStreamToFilesWithInputPath(
                allocator,
                test_exe,
                test_dir,
                input_path,
                test_stdout_path,
                test_stderr_path,
                options.timeout_ms,
            );
            if (test_run.timed_out) {
                std.log.warn("timeout: translated run {s} ({s})\n", .{ case.name, input_name });
                return false;
            }

            const ref_code = exitCode(ref_run.term);
            const test_code = exitCode(test_run.term);
            if (ref_code != test_code) {
                std.log.warn("exit code mismatch: {s} ({s}) ref={d} test={d}\n", .{ case.name, input_name, ref_code, test_code });
                return false;
            }
            const ref_stdout = readFileLimitedAbsolute(allocator, ref_stdout_path, MAX_RUN_OUTPUT_BYTES) catch |err| {
                std.log.warn("failed to read reference stdout: {s} ({s}, {s})\n", .{ case.name, input_name, @errorName(err) });
                return false;
            };
            defer allocator.free(ref_stdout);
            const test_stdout = readFileLimitedAbsolute(allocator, test_stdout_path, MAX_RUN_OUTPUT_BYTES) catch |err| {
                std.log.warn("failed to read translated stdout: {s} ({s}, {s})\n", .{ case.name, input_name, @errorName(err) });
                return false;
            };
            defer allocator.free(test_stdout);
            if (!outputsEquivalent(ref_stdout, test_stdout)) {
                const retry_ok = retryStdoutComparisonWithCapturedRuns(
                    allocator,
                    ref_exe,
                    ref_dir,
                    test_exe,
                    test_dir,
                    input_path,
                    options.timeout_ms,
                ) catch false;
                if (retry_ok) continue;
                std.log.warn("stdout mismatch: {s} ({s})\n", .{ case.name, input_name });
                return false;
            }
        }
    }

    if (!options.keep_workdir) cleanupWorkDir(work_rel);
    return true;
}

test "parseArgs recognizes fail-on-fallback gate" {
    const testing = std.testing;

    const args = [_][]const u8{
        "lapack_runner",
        "--fail-on-fallback",
        "--strict-translate",
    };

    const options = switch (parseArgs(&args)) {
        .success => |opts| opts,
        .failure => |err| return err,
    };

    try testing.expectEqual(fallback_policy.Mode.strict, options.fallback_policy.mode);
    try testing.expect(options.strict_translate);
}

test "parseArgs recognizes max-fallbacks gate" {
    const testing = std.testing;

    const args = [_][]const u8{
        "lapack_runner",
        "--max-fallbacks",
        "7",
    };

    const options = switch (parseArgs(&args)) {
        .success => |opts| opts,
        .failure => |err| return err,
    };

    try testing.expectEqual(fallback_policy.Mode.budget, options.fallback_policy.mode);
    try testing.expectEqual(@as(?usize, 7), options.fallback_policy.max_fallbacks);
}

test "parseArgs recognizes explicit fallback policy" {
    const args = [_][]const u8{
        "lapack_runner",
        "--fallback-policy",
        "disabled",
    };

    const options = switch (parseArgs(&args)) {
        .success => |opts| opts,
        .failure => |err| return err,
    };

    try std.testing.expectEqual(fallback_policy.Mode.disabled, options.fallback_policy.mode);
}

test "outputsEquivalent accepts optional Fortran exponent markers" {
    try std.testing.expect(outputsEquivalent(
        " Relative machine underflow is taken to be    0.222507-307\n",
        " Relative machine underflow is taken to be   0.222507D-307\n",
    ));
    try std.testing.expect(outputsEquivalent(
        " Relative machine overflow  is taken to be    0.179769+309\n",
        " Relative machine overflow  is taken to be   0.179769E+309\n",
    ));
}

test "outputsEquivalent accepts numeric differences within printed precision" {
    try std.testing.expect(outputsEquivalent(
        " ratio  1.234567E+03\n",
        " ratio  1.2345669E+03\n",
    ));
    try std.testing.expect(outputsEquivalent(
        " value -0.000000E+00\n",
        " value  0.000000E+00\n",
    ));
}

test "outputsEquivalent rejects numeric differences beyond printed precision" {
    try std.testing.expect(!outputsEquivalent(
        " ratio  1.234567E+03\n",
        " ratio  1.234500E+03\n",
    ));
}

test "outputsEquivalent accepts numeric differences inside punctuation" {
    try std.testing.expect(outputsEquivalent(
        " value=(1.234567E+03,-0.000000E+00)\n",
        " value=(1.2345669D+03,0.000000E+00)\n",
    ));
}

test "shouldLinkRuntimeArtifacts only links runtime when translated objects exist" {
    try std.testing.expect(!shouldLinkRuntimeArtifacts(0));
    try std.testing.expect(shouldLinkRuntimeArtifacts(1));
}
