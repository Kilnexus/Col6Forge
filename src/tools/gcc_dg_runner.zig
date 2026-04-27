//! GCC gfortran.dg compile-suite runner for Col6Forge.
//!
//! Phase-1 scope:
//! - run only dg-do compile tests
//! - support dg-error compile-failure expectations
//! - skip target-guarded / unsupported dejagnu / multi-source tests
//! - compile translated LLVM IR with zig cc -c
const common = @import("gcc_dg_runner/common.zig");
const std = common.std;
const Col6Forge = common.Col6Forge;
const zig_api = Col6Forge.zig_api;
const cli_args = Col6Forge.process_args;
const cli = @import("gcc_dg_runner/cli.zig");
const Options = cli.Options;
const parseArgs = cli.parseArgs;
const printParseArgError = cli.printParseArgError;
const printUsage = cli.printUsage;
const directives = @import("gcc_dg_runner/directives.zig");
const SkipCounts = directives.SkipCounts;
const collectRunnableCases = directives.collectRunnableCases;
const countExpectedErrorCases = directives.countExpectedErrorCases;
const countExpectedShouldFailCases = directives.countExpectedShouldFailCases;
const countExpectedWarningCases = directives.countExpectedWarningCases;
const countExpectedAuxCases = directives.countExpectedAuxCases;
const countExpectedOutputCases = directives.countExpectedOutputCases;
const process_mod = @import("gcc_dg_runner/process.zig");
const processCase = process_mod.processCase;
const runCaseParallel = process_mod.runCaseParallel;
const progress_mod = @import("gcc_dg_runner/progress.zig");
const LogState = progress_mod.LogState;
const Progress = progress_mod.Progress;
const logProgress = progress_mod.logProgress;
const printSummary = progress_mod.printSummary;
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const args = try cli_args.allocArgs(allocator, init.minimal.args);
    defer cli_args.freeArgs(allocator, args);

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

    var log_state: LogState = .{};
    var skips = SkipCounts{};
    const cases = try collectRunnableCases(
        arena_allocator,
        allocator,
        options.tests_dir,
        options.filter,
        &skips,
    );

    if (options.verbose) {
        log_state.stdout("selected {d} runnable cases from {d} source files\n", .{ cases.len, skips.total_sources });
    }
    const expected_error_cases = countExpectedErrorCases(cases);
    const expected_should_fail_cases = countExpectedShouldFailCases(cases);
    const expected_warning_cases = countExpectedWarningCases(cases);
    const expected_aux_cases = countExpectedAuxCases(cases);
    const expected_output_cases = countExpectedOutputCases(cases);

    if (cases.len == 0) {
        printSummary(&log_state, cases.len, 0, 0, expected_error_cases, expected_should_fail_cases, expected_warning_cases, expected_aux_cases, expected_output_cases, options, skips);
        return;
    }

    var progress = try Progress.init(cases.len);
    defer progress.deinit();

    var failures: usize = 0;
    for (cases) |case| {
        logProgress(&log_state, &progress, case.rel_path);
        const ok = processCase(allocator, root_path, case, options, &log_state) catch {
            failures += 1;
            _ = progress.completed.fetchAdd(1, .seq_cst);
            continue;
        };
        if (!ok) failures += 1;
        _ = progress.completed.fetchAdd(1, .seq_cst);
    }
    const passed = cases.len - failures;
    printSummary(&log_state, cases.len, passed, failures, expected_error_cases, expected_should_fail_cases, expected_warning_cases, expected_aux_cases, expected_output_cases, options, skips);
    if (failures > 0) return error.GccDgVerificationFailed;
}
