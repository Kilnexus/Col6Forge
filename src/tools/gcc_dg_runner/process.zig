const builtin = @import("builtin");
const common = @import("common.zig");
const std = common.std;
const Col6Forge = common.Col6Forge;
const zig_api = Col6Forge.zig_api;
const process_timeout = @import("../process_timeout.zig");
const child_env = @import("../child_env.zig");
const cli = @import("cli.zig");
const Options = cli.Options;
const directives = @import("directives.zig");
const TestCase = directives.TestCase;
const AuxDiagKind = directives.AuxDiagKind;
const classifyCase = directives.classifyCase;
const makeWorkName = directives.makeWorkName;
const matchExpectedPattern = directives.matchExpectedPattern;
const patternHasRegexMeta = directives.patternHasRegexMeta;
const stripRegexMeta = directives.stripRegexMeta;
const progress_mod = @import("progress.zig");
const LogState = progress_mod.LogState;
const Progress = progress_mod.Progress;
const logProgress = progress_mod.logProgress;
const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,
    timed_out: bool,

    fn deinit(self: ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

var work_run_counter = std.atomic.Value(u64).init(0);

fn runProcessCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout_ms: ?u64,
) !ProcessResult {
    const io = zig_api.defaultIo();
    const resolved_argv = try zig_api.resolveZigArgv(allocator, argv);
    defer resolved_argv.deinit(allocator);
    var env_map = try child_env.build(allocator, resolved_argv.argv, cwd, ".gcc-dg-runner-tmp");
    defer env_map.deinit();

    var child = try std.process.spawn(io, .{
        .argv = resolved_argv.argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = builtin.os.tag == .windows,
    });
    defer child.kill(io);

    var done = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    var monitor: ?std.Thread = null;
    var monitor_joined = false;
    if (timeout_ms) |limit| {
        if (limit > 0) {
            monitor = try std.Thread.spawn(.{}, process_timeout.timeoutMonitor, .{ &child, &done, &timed_out, limit });
        }
    }
    errdefer {
        done.store(true, .seq_cst);
        if (!monitor_joined) {
            if (monitor) |thread| thread.join();
            monitor_joined = true;
        }
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try multi_reader.checkAnyError();
    done.store(true, .seq_cst);
    if (monitor) |thread| thread.join();
    monitor_joined = true;

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = try child.wait(io),
        .timed_out = timed_out.load(.seq_cst),
    };
}

fn isZeroExit(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn emitPipelineToFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    emit: Col6Forge.EmitKind,
    output_path: []const u8,
    bounds_check: bool,
    range_check: bool,
    fbackslash: bool,
    allow_argument_mismatch: bool,
    diag_bag: *Col6Forge.diag.Bag,
) !void {
    const result = try Col6Forge.runPipelineWithOptionsAndDiagnostics(
        allocator,
        input_path,
        emit,
        .{
            .coarse_source_map = false,
            .capture_profile = false,
            .bounds_check = bounds_check,
            .range_check = range_check,
            .fbackslash = fbackslash,
            .allow_argument_mismatch = allow_argument_mismatch,
        },
        diag_bag,
    );
    defer allocator.free(result.output);
    var out_file = try zig_api.cwd().createFile(output_path, .{ .truncate = true });
    defer out_file.close();
    try out_file.writeAll(result.output);
}

fn formatPipelineFailureText(
    allocator: std.mem.Allocator,
    log_state: *LogState,
    input_path: []const u8,
    diag_bag: *Col6Forge.diag.Bag,
    err: anyerror,
    log_output: bool,
) ![]const u8 {
    if (diag_bag.has()) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        while (diag_bag.take()) |d| {
            errdefer diag_bag.release(d);
            try Col6Forge.writeDiagnostic(&out.writer, d);
            diag_bag.release(d);
        }
        try out.writer.flush();
        const text = try allocator.dupe(u8, out.writer.buffered());
        if (log_output) log_state.stderr("{s}", .{text});
        return text;
    }

    const fallback = try std.fmt.allocPrint(allocator, "pipeline error: {s}", .{@errorName(err)});
    if (log_output) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try Col6Forge.writePipelineErrorDiagnostic(&out.writer, diag_bag, input_path, err);
        try out.writer.flush();
        log_state.stderr("{s}", .{out.writer.buffered()});
    }
    return fallback;
}

fn formatPipelineFailureMatchText(
    allocator: std.mem.Allocator,
    diag_bag: *Col6Forge.diag.Bag,
) ![]const u8 {
    if (!diag_bag.has()) return try allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (diag_bag.items.items) |item| {
        try out.appendSlice(allocator, item.message);
        try out.append(allocator, '\n');
        if (item.line_text.len != 0) {
            try out.appendSlice(allocator, item.line_text);
            try out.append(allocator, '\n');
        }
        for (item.notes) |note| {
            try out.appendSlice(allocator, note.text);
            try out.append(allocator, '\n');
        }
        for (item.helps) |help| {
            try out.appendSlice(allocator, help.text);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

fn matchExpectedErrors(
    allocator: std.mem.Allocator,
    case: TestCase,
    diag_text: []const u8,
    log_state: *LogState,
) !bool {
    for (case.expected_error_patterns) |expected| {
        if (expected.pattern.len == 0) continue;
        const ok = try matchExpectedPattern(allocator, expected.pattern, diag_text);
        if (!ok) {
            log_state.stderr(
                "dg-error mismatch: {s} (directive line {d})\nexpected pattern: {s}\nactual diagnostic: {s}\n",
                .{ case.rel_path, expected.line_no, expected.pattern, diag_text },
            );
            return false;
        }
    }
    return true;
}

fn matchExpectedWarnings(
    allocator: std.mem.Allocator,
    case: TestCase,
    warning_text: []const u8,
    log_state: *LogState,
) !bool {
    for (case.expected_warning_patterns) |expected| {
        if (expected.pattern.len == 0) continue;
        const ok = try matchExpectedPattern(allocator, expected.pattern, warning_text);
        if (!ok) {
            log_state.stderr(
                "dg-warning mismatch: {s} (directive line {d})\nexpected pattern: {s}\nactual diagnostic: {s}\n",
                .{ case.rel_path, expected.line_no, expected.pattern, warning_text },
            );
            return false;
        }
    }
    return true;
}

fn auxKindLabel(kind: AuxDiagKind) []const u8 {
    return switch (kind) {
        .message => "message",
        .note => "note",
        .bogus => "bogus",
    };
}

fn matchExpectedAux(
    allocator: std.mem.Allocator,
    case: TestCase,
    diag_text: []const u8,
    log_state: *LogState,
) !bool {
    for (case.expected_aux_patterns) |expected| {
        if (expected.pattern.len == 0) continue;
        const found = try matchExpectedPattern(allocator, expected.pattern, diag_text);
        switch (expected.kind) {
            .bogus => {
                if (found) {
                    log_state.stderr(
                        "dg-bogus mismatch: {s} (directive line {d})\nforbidden pattern found: {s}\nactual diagnostic: {s}\n",
                        .{ case.rel_path, expected.line_no, expected.pattern, diag_text },
                    );
                    return false;
                }
            },
            else => {
                if (!found) {
                    log_state.stderr(
                        "dg-{s} mismatch: {s} (directive line {d})\nexpected pattern: {s}\nactual diagnostic: {s}\n",
                        .{ auxKindLabel(expected.kind), case.rel_path, expected.line_no, expected.pattern, diag_text },
                    );
                    return false;
                }
            },
        }
    }
    return true;
}

fn replaceAllLiteralAlloc(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0) return try allocator.dupe(u8, haystack);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    while (true) {
        const idx = std.mem.indexOfPos(u8, haystack, cursor, needle) orelse {
            try out.appendSlice(allocator, haystack[cursor..]);
            break;
        };
        try out.appendSlice(allocator, haystack[cursor..idx]);
        try out.appendSlice(allocator, replacement);
        cursor = idx + needle.len;
    }
    return out.toOwnedSlice(allocator);
}

fn pruneOutputText(allocator: std.mem.Allocator, case: TestCase, source_text: []const u8) ![]const u8 {
    var current: []const u8 = try allocator.dupe(u8, source_text);
    for (case.prune_output_patterns) |prune| {
        if (prune.pattern.len == 0) continue;
        var literal = prune.pattern;
        var owned_literal: ?[]const u8 = null;
        defer if (owned_literal) |value| allocator.free(value);
        if (patternHasRegexMeta(prune.pattern)) {
            owned_literal = try stripRegexMeta(allocator, prune.pattern);
            literal = owned_literal.?;
        }
        if (literal.len == 0) continue;
        const replaced = try replaceAllLiteralAlloc(allocator, current, literal, "");
        allocator.free(current);
        current = replaced;
    }
    return current;
}

fn matchExpectedOutput(
    allocator: std.mem.Allocator,
    case: TestCase,
    diag_text: []const u8,
    log_state: *LogState,
) !bool {
    const pruned = try pruneOutputText(allocator, case, diag_text);
    defer allocator.free(pruned);
    for (case.expected_output_patterns) |expected| {
        if (expected.pattern.len == 0) continue;
        const ok = try matchExpectedPattern(allocator, expected.pattern, pruned);
        if (!ok) {
            log_state.stderr(
                "dg-output mismatch: {s} (directive line {d})\nexpected pattern: {s}\nactual diagnostic(after prune): {s}\n",
                .{ case.rel_path, expected.line_no, expected.pattern, pruned },
            );
            return false;
        }
    }
    return true;
}

fn joinDiagnosticStreams(allocator: std.mem.Allocator, stderr_text: []const u8, stdout_text: []const u8) ![]const u8 {
    if (stderr_text.len == 0 and stdout_text.len == 0) return try allocator.dupe(u8, "");
    if (stderr_text.len == 0) return try allocator.dupe(u8, stdout_text);
    if (stdout_text.len == 0) return try allocator.dupe(u8, stderr_text);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ stderr_text, stdout_text });
}

fn cleanupWorkDir(path: []const u8) void {
    if (builtin.os.tag == .windows) return;
    zig_api.cwd().deleteTree(path) catch {};
}

pub fn processCase(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    case: TestCase,
    options: Options,
    log_state: *LogState,
) !bool {
    const check_warnings = options.strict_level == .warning or options.strict_level == .full;
    const check_aux = options.strict_level == .full;
    const check_output = options.strict_level == .full;
    const expect_failure = case.expect_compile_error or case.expect_should_fail;

    const abs_input_path = try std.fs.path.join(allocator, &.{ root_path, case.input_path });
    defer allocator.free(abs_input_path);

    const work_run_id = work_run_counter.fetchAdd(1, .seq_cst) + 1;
    const work_run_component = try std.fmt.allocPrint(allocator, "{x}", .{work_run_id});
    defer allocator.free(work_run_component);

    const work_dir_rel = try std.fs.path.join(allocator, &.{ "zig-cache", "gcc-dg", case.work_name, work_run_component });
    defer allocator.free(work_dir_rel);
    try zig_api.cwd().makePath(work_dir_rel);

    const work_dir = try std.fs.path.join(allocator, &.{ root_path, work_dir_rel });
    defer allocator.free(work_dir);

    const ll_path = try std.fs.path.join(allocator, &.{ work_dir, "translated.ll" });
    defer allocator.free(ll_path);
    const obj_path = try std.fs.path.join(allocator, &.{ work_dir, "translated.o" });
    defer allocator.free(obj_path);

    var compile_failed = false;
    var diag_text: []const u8 = "";
    var match_text: []const u8 = "";
    var warning_diag_text: []const u8 = "";
    var pipeline_diag_bag = Col6Forge.diag.Bag.init(allocator);
    defer pipeline_diag_bag.deinit();

    emitPipelineToFile(allocator, abs_input_path, options.emit, ll_path, case.bounds_check, case.range_check, case.fbackslash, case.allow_argument_mismatch, &pipeline_diag_bag) catch |err| {
        compile_failed = true;
        match_text = try formatPipelineFailureMatchText(allocator, &pipeline_diag_bag);
        diag_text = try formatPipelineFailureText(allocator, log_state, abs_input_path, &pipeline_diag_bag, err, !expect_failure);
    };

    if (!compile_failed) {
        const compile = runProcessCapture(
            allocator,
            &.{ "zig", "cc", "-O0", "-c", "-o", obj_path, ll_path },
            null,
            options.timeout_ms,
        ) catch |err| {
            log_state.stderr("zig cc failed: {s} ({s})\n", .{ case.rel_path, @errorName(err) });
            return false;
        };
        defer compile.deinit(allocator);

        if (compile.timed_out) {
            log_state.stderr("timeout: {s}\n", .{case.rel_path});
            return false;
        }
        if (!isZeroExit(compile.term)) {
            compile_failed = true;
            const err_text = if (compile.stderr.len > 0) compile.stderr else compile.stdout;
            const short = if (err_text.len > 16 * 1024) err_text[0 .. 16 * 1024] else err_text;
            diag_text = try allocator.dupe(u8, short);
            if (!expect_failure) {
                log_state.stderr("compile failed: {s}\n{s}\n", .{ case.rel_path, short });
            }
        } else if (!expect_failure and
            ((check_warnings and case.expected_warning_patterns.len > 0) or
                (check_aux and case.expected_aux_patterns.len > 0) or
                (check_output and (case.expected_output_patterns.len > 0 or case.prune_output_patterns.len > 0))))
        {
            warning_diag_text = try joinDiagnosticStreams(allocator, compile.stderr, compile.stdout);
        }
    }

    if (expect_failure) {
        defer if (diag_text.len > 0) allocator.free(diag_text);
        defer if (match_text.len > 0) allocator.free(match_text);
        if (!compile_failed) {
            log_state.stderr("expected compile failure but succeeded: {s}\n", .{case.rel_path});
            return false;
        }
        if (case.expect_compile_error) {
            const candidate = if (match_text.len != 0) match_text else diag_text;
            const matched = try matchExpectedErrors(allocator, case, candidate, log_state);
            if (!matched) return false;
        }
        if (check_warnings and case.expected_warning_patterns.len > 0) {
            const candidate = if (match_text.len != 0) match_text else diag_text;
            const warnings_ok = try matchExpectedWarnings(allocator, case, candidate, log_state);
            if (!warnings_ok) return false;
        } else if (case.expected_warning_patterns.len > 0 and options.verbose) {
            log_state.stdout("strict-level off: skipping dg-warning check for {s}\n", .{case.rel_path});
        }
        if (check_aux and case.expected_aux_patterns.len > 0) {
            const candidate = if (match_text.len != 0) match_text else diag_text;
            const aux_ok = try matchExpectedAux(allocator, case, candidate, log_state);
            if (!aux_ok) return false;
        } else if (case.expected_aux_patterns.len > 0 and options.verbose) {
            log_state.stdout("strict-level not full: skipping dg-message/note/bogus checks for {s}\n", .{case.rel_path});
        }
        if (check_output and case.expected_output_patterns.len > 0) {
            const candidate = if (match_text.len != 0) match_text else diag_text;
            const out_ok = try matchExpectedOutput(allocator, case, candidate, log_state);
            if (!out_ok) return false;
        } else if ((case.expected_output_patterns.len > 0 or case.prune_output_patterns.len > 0) and options.verbose) {
            log_state.stdout("strict-level not full: skipping dg-output/prune-output checks for {s}\n", .{case.rel_path});
        }
    } else {
        if (diag_text.len > 0) allocator.free(diag_text);
        if (match_text.len > 0) allocator.free(match_text);
        if (compile_failed) return false;
        defer if (warning_diag_text.len > 0) allocator.free(warning_diag_text);
        if (case.expected_warning_patterns.len > 0) {
            if (check_warnings) {
                const warnings_ok = try matchExpectedWarnings(allocator, case, warning_diag_text, log_state);
                if (!warnings_ok) return false;
            } else if (options.verbose) {
                log_state.stdout("strict-level off: skipping dg-warning check for {s}\n", .{case.rel_path});
            }
        }
        if (case.expected_aux_patterns.len > 0) {
            if (check_aux) {
                const aux_ok = try matchExpectedAux(allocator, case, warning_diag_text, log_state);
                if (!aux_ok) return false;
            } else if (options.verbose) {
                log_state.stdout("strict-level not full: skipping dg-message/note/bogus checks for {s}\n", .{case.rel_path});
            }
        }
        if (case.expected_output_patterns.len > 0) {
            if (check_output) {
                const out_ok = try matchExpectedOutput(allocator, case, warning_diag_text, log_state);
                if (!out_ok) return false;
            } else if (options.verbose) {
                log_state.stdout("strict-level not full: skipping dg-output/prune-output checks for {s}\n", .{case.rel_path});
            }
        } else if (case.prune_output_patterns.len > 0 and options.verbose and !check_output) {
            log_state.stdout("strict-level not full: skipping dg-output/prune-output checks for {s}\n", .{case.rel_path});
        }
    }

    if (!options.keep_work) {
        cleanupWorkDir(work_dir_rel);
    } else if (options.verbose) {
        log_state.stdout("kept work dir: {s}\n", .{work_dir_rel});
    }

    return true;
}

pub fn runCaseParallel(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    case: TestCase,
    options: Options,
    log_state: *LogState,
    progress: *Progress,
    failures: *std.atomic.Value(usize),
) void {
    logProgress(log_state, progress, case.rel_path);
    const ok = processCase(allocator, root_path, case, options, log_state) catch {
        _ = failures.fetchAdd(1, .seq_cst);
        _ = progress.completed.fetchAdd(1, .seq_cst);
        return;
    };
    if (!ok) _ = failures.fetchAdd(1, .seq_cst);
    _ = progress.completed.fetchAdd(1, .seq_cst);
}

test "processCase accepts repository c_ptr_tests_16 case" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const root_path = try allocator.dupe(u8, ".");
    defer allocator.free(root_path);

    const tests_dir = "tests/gcc-tests/gfortran.dg";
    const rel_path = "c_ptr_tests_16.f90";
    const classification = try classifyCase(allocator, allocator, tests_dir, rel_path);
    const expectations = switch (classification) {
        .skip => |reason| {
            std.debug.print("unexpected skip: {s}\n", .{@tagName(reason)});
            return error.TestUnexpectedResult;
        },
        .runnable => |value| value,
    };

    const input_path = try std.fs.path.join(allocator, &.{ tests_dir, rel_path });
    defer allocator.free(input_path);
    const work_name = try makeWorkName(allocator, rel_path);
    defer allocator.free(work_name);

    const case: TestCase = .{
        .input_path = input_path,
        .rel_path = rel_path,
        .work_name = work_name,
        .bounds_check = expectations.bounds_check,
        .range_check = expectations.range_check,
        .fbackslash = expectations.fbackslash,
        .allow_argument_mismatch = expectations.allow_argument_mismatch,
        .expect_compile_error = expectations.expect_compile_error,
        .expect_should_fail = expectations.expect_should_fail,
        .expected_error_patterns = expectations.expected_error_patterns,
        .expected_warning_patterns = expectations.expected_warning_patterns,
        .expected_aux_patterns = expectations.expected_aux_patterns,
        .expected_output_patterns = expectations.expected_output_patterns,
        .prune_output_patterns = expectations.prune_output_patterns,
    };

    var log_state: LogState = .{};
    const ok = try processCase(
        allocator,
        root_path,
        case,
        .{
            .tests_dir = tests_dir,
            .filter = rel_path,
            .emit = .llvm,
            .timeout_ms = 120_000,
            .jobs = 1,
            .show_help = false,
            .verbose = false,
            .keep_work = false,
            .strict_level = .off,
        },
        &log_state,
    );
    try testing.expect(ok);
}

