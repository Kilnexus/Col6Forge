const common = @import("common.zig");
const std = common.std;
const Col6Forge = common.Col6Forge;
const zig_api = Col6Forge.zig_api;
const cli = @import("cli.zig");
const Options = cli.Options;
const strictLevelLabel = cli.strictLevelLabel;
const directives = @import("directives.zig");
const SkipCounts = directives.SkipCounts;
pub fn printSummary(
    log_state: *LogState,
    runnable: usize,
    passed: usize,
    failed: usize,
    expected_error_cases: usize,
    expected_should_fail_cases: usize,
    expected_warning_cases: usize,
    expected_aux_cases: usize,
    expected_output_cases: usize,
    options: Options,
    skips: SkipCounts,
) void {
    log_state.stdout("gcc-dg compile summary\n", .{});
    log_state.stdout("  scanned fortran sources: {d}\n", .{skips.total_sources});
    log_state.stdout("  runnable: {d}, passed: {d}, failed: {d}\n", .{ runnable, passed, failed });
    log_state.stdout("  strict diagnostics mode: {s}\n", .{strictLevelLabel(options.strict_level)});
    log_state.stdout("  runnable with dg-error expectation: {d}\n", .{expected_error_cases});
    log_state.stdout("  runnable with dg-shouldfail expectation: {d}\n", .{expected_should_fail_cases});
    log_state.stdout("  runnable with dg-warning expectation: {d}\n", .{expected_warning_cases});
    log_state.stdout("  runnable with dg-message/note/bogus expectation: {d}\n", .{expected_aux_cases});
    log_state.stdout("  runnable with dg-output/prune-output expectation: {d}\n", .{expected_output_cases});
    log_state.stdout("  skipped: {d}\n", .{skips.totalSkipped()});
    log_state.stdout("    no dg-do: {d}\n", .{skips.no_dg_do});
    log_state.stdout("    dg-do not compile: {d}\n", .{skips.do_not_compile});
    log_state.stdout("    dg-do target-guarded: {d}\n", .{skips.dg_do_target_guarded});
    log_state.stdout("    expected diagnostics: {d}\n", .{skips.expected_diagnostics});
    log_state.stdout("    target predicates: {d}\n", .{skips.target_predicate});
    log_state.stdout("    additional sources/modules: {d}\n", .{skips.additional_sources});
    log_state.stdout("    unsupported dg-options: {d}\n", .{skips.unsupported_dg_options});
    log_state.stdout("    unsupported dejagnu directives: {d}\n", .{skips.unsupported_dejagnu});
    log_state.stdout("    preprocessed source (.F*): {d}\n", .{skips.preprocessed_source});
}

pub const LogState = struct {
    mutex: std.Io.Mutex = .init,

    pub fn lock(self: *LogState) void {
        self.mutex.lockUncancelable(zig_api.defaultIo());
    }

    pub fn unlock(self: *LogState) void {
        self.mutex.unlock(zig_api.defaultIo());
    }

    pub fn stdout(self: *LogState, comptime fmt: []const u8, args: anytype) void {
        self.print(zig_api.File.stdout(), fmt, args);
    }

    pub fn stderr(self: *LogState, comptime fmt: []const u8, args: anytype) void {
        self.print(zig_api.File.stderr(), fmt, args);
    }

    pub fn print(self: *LogState, file: zig_api.File, comptime fmt: []const u8, args: anytype) void {
        self.lock();
        defer self.unlock();
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }
};

pub const Progress = struct {
    total: usize,
    started: std.atomic.Value(usize),
    completed: std.atomic.Value(usize),
    start_ns: i128,

    pub fn init(total: usize) !Progress {
        return .{
            .total = total,
            .started = std.atomic.Value(usize).init(0),
            .completed = std.atomic.Value(usize).init(0),
            .start_ns = zig_api.nowNs(),
        };
    }

    pub fn deinit(_: *Progress) void {}
};

pub fn logProgress(log_state: *LogState, progress: *Progress, path: []const u8) void {
    const started = progress.started.fetchAdd(1, .seq_cst) + 1;
    const completed = progress.completed.load(.seq_cst);
    const elapsed_ns = zig_api.nowNs() - progress.start_ns;
    const elapsed_ms: u64 = @intCast(@divTrunc(if (elapsed_ns > 0) elapsed_ns else 0, std.time.ns_per_ms));
    const eta_ms = estimateEtaMs(elapsed_ms, completed, progress.total);

    var elapsed_buf: [32]u8 = undefined;
    var eta_buf: [32]u8 = undefined;
    const elapsed_str = formatDuration(&elapsed_buf, elapsed_ms);
    const eta_str = formatDuration(&eta_buf, eta_ms);
    const name = std.fs.path.basename(path);

    log_state.stdout("[{d}/{d}] Running {s} | elapsed {s} | eta {s}\n", .{
        started,
        progress.total,
        name,
        elapsed_str,
        eta_str,
    });
}

fn estimateEtaMs(elapsed_ms: u64, completed: usize, total: usize) u64 {
    if (completed == 0 or total <= completed) return 0;
    const avg_ms = elapsed_ms / completed;
    return avg_ms * (total - completed);
}

fn formatDuration(buf: []u8, total_ms: u64) []const u8 {
    const total_seconds = total_ms / 1000;
    const seconds = total_seconds % 60;
    const minutes = (total_seconds / 60) % 60;
    const hours = total_seconds / 3600;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "00:00:00";
}

