const common = @import("common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const fallback_policy = common.fallback_policy;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const zig_api = common.zig_api;
const cli = @import("cli.zig");
const cases = @import("cases.zig");
const runner_io = @import("runner_io.zig");
const compare = @import("compare.zig");
const runtime = @import("runtime.zig");

const Options = cli.Options;
const PipelineProfileCollector = cli.PipelineProfileCollector;
const TestCase = cases.TestCase;
const Comparator = compare.Comparator;
const LogState = runtime.LogState;
const Progress = runtime.Progress;
const DirLocks = runtime.DirLocks;
const RuntimeArtifacts = runtime.RuntimeArtifacts;
const reportPipelineError = runner_io.reportPipelineError;
const resolveVerifyWorkDir = runner_io.resolveVerifyWorkDir;
const prepareExePath = runner_io.prepareExePath;
const isTimedOut = runner_io.isTimedOut;
const hashFileXx64 = runner_io.hashFileXx64;
const buildVerifyCachePath = runner_io.buildVerifyCachePath;
const fileExistsAbsolute = runner_io.fileExistsAbsolute;
const copyFileAbsolute = runner_io.copyFileAbsolute;
const runProcessCapture = runner_io.runProcessCapture;
const exitCode = runner_io.exitCode;
const emitPipelineToFile = runner_io.emitPipelineToFile;
const remainingTimeoutMs = runner_io.remainingTimeoutMs;
const cleanupWorkDir = runner_io.cleanupWorkDir;
const copyCaseSupportFiles = runner_io.copyCaseSupportFiles;
const findCompanionInputPath = runner_io.findCompanionInputPath;
const cleanupFortranScratchFiles = runner_io.cleanupFortranScratchFiles;
const runProcessCaptureWithInput = runner_io.runProcessCaptureWithInput;
const runZigCcLinkWithWindowsRetry = runner_io.runZigCcLinkWithWindowsRetry;
const deleteFileAbsoluteIfExists = runner_io.deleteFileAbsoluteIfExists;
const deleteWindowsLinkSidecarsIfExists = runner_io.deleteWindowsLinkSidecarsIfExists;
const prepareGfortranSource = runner_io.prepareGfortranSource;
const computeLinkedExeCacheKey = runner_io.computeLinkedExeCacheKey;
const isZeroExit = runner_io.isZeroExit;
const allowsProcessorDependentOutputDiff = compare.allowsProcessorDependentOutputDiff;
const tryRecoverRuntimeCacheAndRelink = runtime.tryRecoverRuntimeCacheAndRelink;
const logProgress = runtime.logProgress;

fn workDirArg(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (builtin.os.tag == .windows) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "./{s}", .{base});
}

fn emitTranslatedLl(
    allocator: std.mem.Allocator,
    abs_input_path: []const u8,
    options: Options,
    ll_path: []const u8,
    ll_cache_path: ?[]const u8,
    log_state: *LogState,
    profile_collector: *PipelineProfileCollector,
) !bool {
    var pipeline_diag_bag = Col6Forge.diag.Bag.init(allocator);
    defer pipeline_diag_bag.deinit();
    emitPipelineToFile(
        allocator,
        abs_input_path,
        options.emit,
        ll_path,
        options.dialect,
        options.profile_summary,
        &pipeline_diag_bag,
    ) catch |err| {
        try reportPipelineError(log_state, &pipeline_diag_bag, abs_input_path, err);
        return false;
    };
    if (options.profile_summary) {
        if (Col6Forge.takeLastPipelineProfileSample()) |sample| {
            profile_collector.record(allocator, sample) catch |err| {
                log_state.stderr("profile record failed: {s}\n", .{@errorName(err)});
            };
        }
    }
    if (ll_cache_path) |cache_path| {
        copyFileAbsolute(ll_path, cache_path) catch |err| {
            log_state.stderr("failed to update cached ll: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
            return false;
        };
    }
    return true;
}

pub fn processCase(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cache_dir: []const u8,
    runtime_cache_key: []const u8,
    runtime_artifacts: *RuntimeArtifacts,
    compiler_cache_key: []const u8,
    ref_compiler_cache_key: []const u8,
    gfortran_cmd: []const u8,
    case: TestCase,
    options: Options,
    log_state: *LogState,
    dir_locks: *DirLocks,
    profile_collector: *PipelineProfileCollector,
) !bool {
    var timer = runner_io.Stopwatch.start();
    const abs_input_path = try std.fs.path.join(allocator, &.{ root_path, case.input_path });
    defer allocator.free(abs_input_path);

    const abs_case_dir = try std.fs.path.join(allocator, &.{ root_path, case.case_dir });
    defer allocator.free(abs_case_dir);

    const work_dir = try resolveVerifyWorkDir(allocator, root_path, case.work_name);
    defer allocator.free(work_dir);
    try zig_api.cwd().makePath(work_dir);

    const ll_path = try std.fs.path.join(allocator, &.{ work_dir, "translated.ll" });
    defer allocator.free(ll_path);
    const translated_obj_path = try std.fs.path.join(allocator, &.{ work_dir, "translated.o" });
    defer allocator.free(translated_obj_path);
    const ref_exe = try prepareExePath(allocator, work_dir, "ref");
    defer allocator.free(ref_exe);
    const ref_exe_arg = try workDirArg(allocator, ref_exe);
    defer allocator.free(ref_exe_arg);
    const test_exe = try prepareExePath(allocator, work_dir, "test");
    defer allocator.free(test_exe);
    const test_exe_arg = try workDirArg(allocator, test_exe);
    defer allocator.free(test_exe_arg);
    if (isTimedOut(options.timeout_ms, &timer)) {
        log_state.stderr("timeout: {s}\n", .{abs_input_path});
        cleanupWorkDir(work_dir);
        return false;
    }

    const source_hash = if (options.incremental) try hashFileXx64(abs_input_path) else 0;
    const ref_exe_cache_path = if (options.incremental)
        try buildVerifyCachePath(
            allocator,
            cache_dir,
            ref_compiler_cache_key,
            source_hash,
            options.emit,
            if (builtin.os.tag == .windows) ".ref.exe" else ".ref",
        )
    else
        null;
    defer if (ref_exe_cache_path) |p| allocator.free(p);

    const ref_timeout = remainingTimeoutMs(options.timeout_ms, &timer);
    if (ref_timeout != null and ref_timeout.? == 0) {
        log_state.stderr("timeout: {s}\n", .{abs_input_path});
        cleanupWorkDir(work_dir);
        return false;
    }

    var ref_cache_lock: ?*std.Io.Mutex = null;
    if (options.incremental) {
        ref_cache_lock = try dir_locks.get(ref_exe_cache_path.?);
    }

    var need_ref_compile = true;
    if (options.incremental) {
        const lock = ref_cache_lock.?;
        lock.lockUncancelable(zig_api.defaultIo());
        defer lock.unlock(zig_api.defaultIo());

        if (fileExistsAbsolute(ref_exe_cache_path.?)) {
            if (copyFileAbsolute(ref_exe_cache_path.?, ref_exe)) {
                need_ref_compile = false;
            } else |err| {
                // Cache read failure should not abort the case; fall back to rebuild.
                log_state.stderr("failed to copy cached reference exe (rebuild): {s} ({s})\n", .{ abs_input_path, @errorName(err) });
            }
        }
    }

    if (need_ref_compile) {
        const ref_source = try prepareGfortranSource(allocator, abs_input_path, work_dir);
        defer if (ref_source.owned) allocator.free(ref_source.path);

        const ref_compile = runProcessCapture(
            allocator,
            &.{ gfortran_cmd, "-std=legacy", "-o", ref_exe, ref_source.path },
            null,
            ref_timeout,
        ) catch |err| {
            if (err == error.FileNotFound) {
                log_state.stderr("gfortran not found (use --gfortran or set GFORTRAN/FC)\n", .{});
            }
            log_state.stderr("gfortran failed: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
            return false;
        };
        defer ref_compile.deinit(allocator);
        if (ref_compile.timed_out) {
            log_state.stderr("timeout: gfortran compile {s}\n", .{abs_input_path});
            cleanupWorkDir(work_dir);
            return false;
        }
        if (!isZeroExit(ref_compile.term)) {
            const code = exitCode(ref_compile.term);
            log_state.lock();
            defer log_state.unlock();
            var stderr_file = zig_api.File.stderr();
            var buffer: [4096]u8 = undefined;
            var writer = stderr_file.writer(&buffer);
            writer.interface.print("\n=== GFORTRAN COMPILE ERROR ===\n", .{}) catch {};
            writer.interface.print("Exit Code: {d}\n", .{code}) catch {};
            writer.interface.print("Work Dir : {s}\n", .{work_dir}) catch {};
            writer.interface.print("Command  : {s} -std=legacy -o {s} {s}\n", .{ gfortran_cmd, ref_exe, ref_source.path }) catch {};
            writer.interface.print("STDOUT   : \n{s}\n", .{ref_compile.stdout}) catch {};
            writer.interface.print("STDERR   : \n{s}\n", .{ref_compile.stderr}) catch {};
            writer.interface.print("==============================\n", .{}) catch {};
            writer.interface.flush() catch {};
            return false;
        }
        if (options.incremental) {
            const lock = ref_cache_lock.?;
            lock.lockUncancelable(zig_api.defaultIo());
            defer lock.unlock(zig_api.defaultIo());

            // Another worker may have populated the cache while we compiled.
            if (fileExistsAbsolute(ref_exe_cache_path.?)) {
                copyFileAbsolute(ref_exe_cache_path.?, ref_exe) catch {};
            } else {
                copyFileAbsolute(ref_exe, ref_exe_cache_path.?) catch {};
            }
        }
    }

    const compile_timeout = remainingTimeoutMs(options.timeout_ms, &timer);
    if (compile_timeout != null and compile_timeout.? == 0) {
        log_state.stderr("timeout: {s}\n", .{abs_input_path});
        cleanupWorkDir(work_dir);
        return false;
    }

    const ll_cache_path = if (options.incremental)
        try buildVerifyCachePath(allocator, cache_dir, compiler_cache_key, source_hash, options.emit, ".ll")
    else
        null;
    defer if (ll_cache_path) |p| allocator.free(p);
    const obj_cache_path = if (options.incremental)
        try buildVerifyCachePath(allocator, cache_dir, compiler_cache_key, source_hash, options.emit, ".o")
    else
        null;
    defer if (obj_cache_path) |p| allocator.free(p);
    const linked_exe_cache_key = if (options.incremental)
        try computeLinkedExeCacheKey(allocator, compiler_cache_key, runtime_cache_key, options.runtime_backend)
    else
        null;
    defer if (linked_exe_cache_key) |p| allocator.free(p);
    const test_exe_cache_path = if (options.incremental)
        try buildVerifyCachePath(
            allocator,
            cache_dir,
            linked_exe_cache_key.?,
            source_hash,
            options.emit,
            if (builtin.os.tag == .windows) ".test.exe" else ".test",
        )
    else
        null;
    defer if (test_exe_cache_path) |p| allocator.free(p);

    if (options.incremental) {
        if (fileExistsAbsolute(obj_cache_path.?)) {
            copyFileAbsolute(obj_cache_path.?, translated_obj_path) catch |err| {
                log_state.stderr("failed to copy cached object: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
                return false;
            };
        } else {
            var used_cached_ll = false;
            if (fileExistsAbsolute(ll_cache_path.?)) {
                copyFileAbsolute(ll_cache_path.?, ll_path) catch |err| {
                    log_state.stderr("failed to copy cached ll: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
                    return false;
                };
                used_cached_ll = true;
            } else {
                if (!(try emitTranslatedLl(
                    allocator,
                    abs_input_path,
                    options,
                    ll_path,
                    ll_cache_path.?,
                    log_state,
                    profile_collector,
                ))) {
                    return false;
                }
            }

            const object_timeout = remainingTimeoutMs(options.timeout_ms, &timer);
            if (object_timeout != null and object_timeout.? == 0) {
                log_state.stderr("timeout: {s}\n", .{abs_input_path});
                cleanupWorkDir(work_dir);
                return false;
            }
            const object_compile = runProcessCapture(
                allocator,
                &.{ "zig", "cc", "-O0", "-c", "-o", translated_obj_path, ll_path },
                null,
                object_timeout,
            ) catch |err| {
                log_state.stderr("zig cc failed: {s} ({s})\n", .{ ll_path, @errorName(err) });
                return false;
            };
            defer object_compile.deinit(allocator);
            if (object_compile.timed_out) {
                log_state.stderr("timeout: zig cc {s}\n", .{abs_input_path});
                cleanupWorkDir(work_dir);
                return false;
            }
            if (!isZeroExit(object_compile.term)) {
                if (used_cached_ll) {
                    log_state.stderr("cached ll rejected by zig cc; regenerating: {s}\n", .{abs_input_path});
                    deleteFileAbsoluteIfExists(ll_path);
                    if (!(try emitTranslatedLl(
                        allocator,
                        abs_input_path,
                        options,
                        ll_path,
                        ll_cache_path.?,
                        log_state,
                        profile_collector,
                    ))) {
                        return false;
                    }
                    const retry_timeout = remainingTimeoutMs(options.timeout_ms, &timer);
                    if (retry_timeout != null and retry_timeout.? == 0) {
                        log_state.stderr("timeout: {s}\n", .{abs_input_path});
                        cleanupWorkDir(work_dir);
                        return false;
                    }
                    const retry_compile = runProcessCapture(
                        allocator,
                        &.{ "zig", "cc", "-O0", "-c", "-o", translated_obj_path, ll_path },
                        null,
                        retry_timeout,
                    ) catch |err| {
                        log_state.stderr("zig cc failed after ll regenerate: {s} ({s})\n", .{ ll_path, @errorName(err) });
                        return false;
                    };
                    defer retry_compile.deinit(allocator);
                    if (retry_compile.timed_out) {
                        log_state.stderr("timeout: zig cc {s}\n", .{abs_input_path});
                        cleanupWorkDir(work_dir);
                        return false;
                    }
                    if (!isZeroExit(retry_compile.term)) {
                        log_state.stderr("zig cc compile failed after ll regenerate: {s}\n{s}\n", .{ ll_path, retry_compile.stderr });
                        return false;
                    }
                } else {
                    log_state.stderr("zig cc compile failed: {s}\n{s}\n", .{ ll_path, object_compile.stderr });
                    return false;
                }
            }
            copyFileAbsolute(translated_obj_path, obj_cache_path.?) catch {};
        }
    } else {
        if (!(try emitTranslatedLl(
            allocator,
            abs_input_path,
            options,
            ll_path,
            null,
            log_state,
            profile_collector,
        ))) {
            return false;
        }
    }

    const link_timeout = remainingTimeoutMs(options.timeout_ms, &timer);
    if (link_timeout != null and link_timeout.? == 0) {
        log_state.stderr("timeout: {s}\n", .{abs_input_path});
        cleanupWorkDir(work_dir);
        return false;
    }

    copyCaseSupportFiles(allocator, abs_case_dir, work_dir) catch |err| {
        log_state.stderr("failed to copy support files: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
        return false;
    };
    const stdin_input_path = try findCompanionInputPath(allocator, work_dir, case.input_path);
    defer if (stdin_input_path) |path| allocator.free(path);
    var used_cached_test_exe = false;

    if (options.incremental) {
        var link_cache_lock: ?*std.Io.Mutex = null;
        link_cache_lock = try dir_locks.get(test_exe_cache_path.?);
        link_cache_lock.?.lockUncancelable(zig_api.defaultIo());
        defer if (link_cache_lock) |lock| lock.unlock(zig_api.defaultIo());

        var need_link = true;
        if (fileExistsAbsolute(test_exe_cache_path.?)) {
            if (copyFileAbsolute(test_exe_cache_path.?, test_exe)) {
                need_link = false;
                used_cached_test_exe = true;
            } else |_| {}
        }

        if (need_link) {
            var compile_args: std.ArrayList([]const u8) = .empty;
            defer compile_args.deinit(allocator);
            try compile_args.appendSlice(allocator, &.{ "zig", "cc", "-O0", "-o", test_exe, translated_obj_path });
            try runtime_artifacts.appendToArgs(allocator, &compile_args);
            var our_compile = runZigCcLinkWithWindowsRetry(
                allocator,
                compile_args.items,
                null,
                link_timeout,
                test_exe,
            ) catch |err| {
                log_state.stderr("zig cc link failed: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
                return false;
            };
            defer our_compile.deinit(allocator);
            if (our_compile.timed_out) {
                log_state.stderr("timeout: zig cc {s}\n", .{abs_input_path});
                cleanupWorkDir(work_dir);
                return false;
            }
            if (!isZeroExit(our_compile.term) and
                options.incremental and
                try tryRecoverRuntimeCacheAndRelink(
                    allocator,
                    root_path,
                    cache_dir,
                    runtime_cache_key,
                    runtime_artifacts,
                    options,
                    log_state,
                    dir_locks,
                    abs_input_path,
                    work_dir,
                    test_exe,
                    translated_obj_path,
                    link_timeout,
                    &our_compile,
                ))
            {
                // relink succeeded after runtime-cache rebuild
            }
            if (!isZeroExit(our_compile.term)) {
                log_state.stderr("zig cc compile failed: {s}\n{s}\n", .{ ll_path, our_compile.stderr });
                return false;
            }
            copyFileAbsolute(test_exe, test_exe_cache_path.?) catch {};
        }
    } else {
        var compile_args: std.ArrayList([]const u8) = .empty;
        defer compile_args.deinit(allocator);
        try compile_args.appendSlice(allocator, &.{ "zig", "cc", "-O0", "-o", test_exe, ll_path });
        try runtime_artifacts.appendToArgs(allocator, &compile_args);
        const our_compile = runZigCcLinkWithWindowsRetry(
            allocator,
            compile_args.items,
            null,
            link_timeout,
            test_exe,
        ) catch |err| {
            log_state.stderr("zig cc link failed: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
            return false;
        };
        defer our_compile.deinit(allocator);
        if (our_compile.timed_out) {
            log_state.stderr("timeout: zig cc {s}\n", .{abs_input_path});
            cleanupWorkDir(work_dir);
            return false;
        }
        if (!isZeroExit(our_compile.term)) {
            log_state.stderr("zig cc compile failed: {s}\n{s}\n", .{ ll_path, our_compile.stderr });
            return false;
        }
    }

    const ref_run_timeout = remainingTimeoutMs(options.timeout_ms, &timer);
    if (ref_run_timeout != null and ref_run_timeout.? == 0) {
        log_state.stderr("timeout: {s}\n", .{abs_input_path});
        cleanupWorkDir(work_dir);
        return false;
    }

    try cleanupFortranScratchFiles(work_dir);
    const ref_run = runProcessCaptureWithInput(
        allocator,
        &.{ref_exe_arg},
        work_dir,
        ref_run_timeout,
        stdin_input_path,
    ) catch |err| {
        log_state.stderr("reference run failed: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
        return false;
    };
    defer ref_run.deinit(allocator);
    if (ref_run.timed_out) {
        log_state.stderr("timeout: reference run {s}\n", .{abs_input_path});
        cleanupWorkDir(work_dir);
        return false;
    }

    const test_run_timeout = remainingTimeoutMs(options.timeout_ms, &timer);
    if (test_run_timeout != null and test_run_timeout.? == 0) {
        log_state.stderr("timeout: {s}\n", .{abs_input_path});
        cleanupWorkDir(work_dir);
        return false;
    }

    try cleanupFortranScratchFiles(work_dir);
    const test_run = blk: {
        break :blk runProcessCaptureWithInput(
            allocator,
            &.{test_exe_arg},
            work_dir,
            test_run_timeout,
            stdin_input_path,
        ) catch |err| {
            if (err == error.InvalidExe and options.incremental and used_cached_test_exe) {
                log_state.stderr("cached translated exe invalid, rebuilding: {s}\n", .{abs_input_path});
                deleteFileAbsoluteIfExists(test_exe_cache_path.?);
                deleteFileAbsoluteIfExists(test_exe);

                var compile_args: std.ArrayList([]const u8) = .empty;
                defer compile_args.deinit(allocator);
                try compile_args.appendSlice(allocator, &.{ "zig", "cc", "-O0", "-o", test_exe, translated_obj_path });
                try runtime_artifacts.appendToArgs(allocator, &compile_args);
                const rebuilt = runZigCcLinkWithWindowsRetry(
                    allocator,
                    compile_args.items,
                    null,
                    test_run_timeout,
                    test_exe,
                ) catch |link_err| {
                    log_state.stderr("zig cc link failed while rebuilding translated exe: {s} ({s})\n", .{ abs_input_path, @errorName(link_err) });
                    return false;
                };
                defer rebuilt.deinit(allocator);
                if (rebuilt.timed_out) {
                    log_state.stderr("timeout: zig cc rebuild {s}\n", .{abs_input_path});
                    cleanupWorkDir(work_dir);
                    return false;
                }
                if (!isZeroExit(rebuilt.term)) {
                    log_state.stderr("zig cc rebuild failed: {s}\n{s}\n", .{ ll_path, rebuilt.stderr });
                    return false;
                }
                copyFileAbsolute(test_exe, test_exe_cache_path.?) catch {};
                try cleanupFortranScratchFiles(work_dir);
                break :blk runProcessCaptureWithInput(
                    allocator,
                    &.{test_exe_arg},
                    work_dir,
                    test_run_timeout,
                    stdin_input_path,
                ) catch |retry_err| {
                    log_state.stderr("translated run failed after cache rebuild: {s} ({s})\n", .{ abs_input_path, @errorName(retry_err) });
                    return false;
                };
            }
            log_state.stderr("translated run failed: {s} ({s})\n", .{ abs_input_path, @errorName(err) });
            return false;
        };
    };
    defer test_run.deinit(allocator);
    if (test_run.timed_out) {
        log_state.stderr("timeout: translated run {s}\n", .{abs_input_path});
        cleanupWorkDir(work_dir);
        return false;
    }

    const comparison = try Comparator.compare(
        allocator,
        ref_run.term,
        test_run.term,
        ref_run.stdout,
        test_run.stdout,
        allowsProcessorDependentOutputDiff(case.input_path),
    );
    if (!comparison.ok) {
        log_state.stderr("mismatch: {s}\n{s}\n", .{ abs_input_path, comparison.diff.? });
        allocator.free(comparison.diff.?);
        return false;
    }
    if (comparison.diff) |diff| {
        allocator.free(diff);
    }

    return true;
}

pub fn runCaseParallel(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cache_dir: []const u8,
    runtime_cache_key: []const u8,
    runtime_artifacts: *RuntimeArtifacts,
    compiler_cache_key: []const u8,
    ref_compiler_cache_key: []const u8,
    gfortran_cmd: []const u8,
    case: TestCase,
    options: Options,
    log_state: *LogState,
    progress: *Progress,
    dir_locks: *DirLocks,
    failures: *std.atomic.Value(usize),
    profile_collector: *PipelineProfileCollector,
) void {
    logProgress(log_state, progress, case.input_path);
    const ok = processCase(
        allocator,
        root_path,
        cache_dir,
        runtime_cache_key,
        runtime_artifacts,
        compiler_cache_key,
        ref_compiler_cache_key,
        gfortran_cmd,
        case,
        options,
        log_state,
        dir_locks,
        profile_collector,
    ) catch |err| {
        log_state.stderr("case failed with internal error: {s} ({s})\n", .{ case.input_path, @errorName(err) });
        _ = failures.fetchAdd(1, .seq_cst);
        _ = progress.completed.fetchAdd(1, .seq_cst);
        return;
    };
    if (!ok) {
        log_state.stderr("case returned failure: {s}\n", .{case.input_path});
        _ = failures.fetchAdd(1, .seq_cst);
    }
    _ = progress.completed.fetchAdd(1, .seq_cst);
}

