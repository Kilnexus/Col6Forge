const std = @import("std");
const tool_args = @import("tool_args.zig");
const tool_json = @import("tool_json.zig");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

const BenchCase = struct {
    name: []const u8,
    median_ms: f64,
    mean_ms: f64,
};

const BenchReport = struct {
    schema_version: u32,
    generated_unix_ms: i64,
    iterations: u32,
    warmup: u32,
    cases: []const BenchCase,
};

const HistoryCase = struct {
    name: []const u8,
    median_ms: f64,
    mean_ms: f64,
};

const HistoryEntry = struct {
    label: []const u8,
    commit_sha: []const u8,
    generated_unix_ms: i64,
    iterations: u32,
    warmup: u32,
    cases: []const HistoryCase,
};

const HistoryReport = struct {
    schema_version: u32,
    updated_unix_ms: i64,
    entries: []const HistoryEntry,
};

const Options = struct {
    history_path: []const u8,
    candidate_path: []const u8,
    markdown_path: []const u8,
    commit_sha: []const u8,
    label: []const u8,
    max_runs: usize,
    show_help: bool,
};

const ParseArgError = union(enum) {
    missing_value: []const u8,
    unknown_flag: []const u8,
    missing_history: void,
    missing_candidate: void,
    missing_markdown: void,
    missing_commit_sha: void,
    missing_label: void,
    invalid_max_runs: []const u8,
};

const ParseArgsOutcome = union(enum) {
    success: Options,
    failure: ParseArgError,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

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

    const candidate = try readReport(allocator, options.candidate_path);
    defer candidate.deinit();

    var history = try readHistoryOrEmpty(allocator, options.history_path);
    defer history.deinit();

    try upsertHistoryEntry(allocator, &history.value, candidate.value, options);
    trimHistory(&history.value, options.max_runs);
    history.value.updated_unix_ms = zig_api.unixMs();

    try ensureParentDir(options.history_path);
    var history_file = try zig_api.cwd().createFile(options.history_path, .{ .truncate = true });
    defer history_file.close();
    try writeJson(history_file, history.value);

    try ensureParentDir(options.markdown_path);
    var markdown_file = try zig_api.cwd().createFile(options.markdown_path, .{ .truncate = true });
    defer markdown_file.close();
    try writeMarkdown(markdown_file, history.value);
}

fn parseArgs(args: []const []const u8) ParseArgsOutcome {
    var history_path: ?[]const u8 = null;
    var candidate_path: ?[]const u8 = null;
    var markdown_path: ?[]const u8 = null;
    var commit_sha: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    var max_runs: usize = 52;
    var show_help = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--history")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            history_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--candidate")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            candidate_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--markdown")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            markdown_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--commit-sha")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            commit_sha = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--label")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            label = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-runs")) {
            if (i + 1 >= args.len) return .{ .failure = .{ .missing_value = arg } };
            i += 1;
            max_runs = std.fmt.parseInt(usize, args[i], 10) catch {
                return .{ .failure = .{ .invalid_max_runs = args[i] } };
            };
            if (max_runs == 0) return .{ .failure = .{ .invalid_max_runs = args[i] } };
            continue;
        }
        return .{ .failure = .{ .unknown_flag = arg } };
    }

    if (!show_help and history_path == null) return .{ .failure = .missing_history };
    if (!show_help and candidate_path == null) return .{ .failure = .missing_candidate };
    if (!show_help and markdown_path == null) return .{ .failure = .missing_markdown };
    if (!show_help and commit_sha == null) return .{ .failure = .missing_commit_sha };
    if (!show_help and label == null) return .{ .failure = .missing_label };

    return .{ .success = .{
        .history_path = history_path orelse "",
        .candidate_path = candidate_path orelse "",
        .markdown_path = markdown_path orelse "",
        .commit_sha = commit_sha orelse "",
        .label = label orelse "",
        .max_runs = max_runs,
        .show_help = show_help,
    } };
}

fn readReport(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(BenchReport) {
    return tool_json.readReport(BenchReport, allocator, path);
}

fn readHistoryOrEmpty(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(HistoryReport) {
    const data = zig_api.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            const empty =
                \\{
                \\  "schema_version": 1,
                \\  "updated_unix_ms": 0,
                \\  "entries": []
                \\}
            ;
            return std.json.parseFromSlice(HistoryReport, allocator, empty, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
        },
        else => return err,
    };
    defer allocator.free(data);
    return std.json.parseFromSlice(HistoryReport, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn upsertHistoryEntry(
    allocator: std.mem.Allocator,
    history: *HistoryReport,
    candidate: BenchReport,
    options: Options,
) !void {
    var new_cases = try allocator.alloc(HistoryCase, candidate.cases.len);
    for (candidate.cases, 0..) |item, idx| {
        new_cases[idx] = .{
            .name = try allocator.dupe(u8, item.name),
            .median_ms = item.median_ms,
            .mean_ms = item.mean_ms,
        };
    }

    const new_entry = HistoryEntry{
        .label = try allocator.dupe(u8, options.label),
        .commit_sha = try allocator.dupe(u8, options.commit_sha),
        .generated_unix_ms = candidate.generated_unix_ms,
        .iterations = candidate.iterations,
        .warmup = candidate.warmup,
        .cases = new_cases,
    };

    var replace_index: ?usize = null;
    for (history.entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.commit_sha, options.commit_sha)) {
            replace_index = idx;
            break;
        }
    }

    const new_len = if (replace_index != null) history.entries.len else history.entries.len + 1;
    var new_entries = try allocator.alloc(HistoryEntry, new_len);
    for (history.entries, 0..) |entry, idx| {
        if (replace_index != null and idx == replace_index.?) {
            new_entries[idx] = new_entry;
        } else {
            new_entries[idx] = entry;
        }
    }
    if (replace_index == null) {
        new_entries[history.entries.len] = new_entry;
    }
    sortEntries(new_entries);
    history.entries = new_entries;
}

fn sortEntries(entries: []HistoryEntry) void {
    std.sort.heap(HistoryEntry, entries, {}, struct {
        fn lessThan(_: void, a: HistoryEntry, b: HistoryEntry) bool {
            return a.generated_unix_ms < b.generated_unix_ms;
        }
    }.lessThan);
}

fn trimHistory(history: *HistoryReport, max_runs: usize) void {
    if (history.entries.len <= max_runs) return;
    history.entries = history.entries[history.entries.len - max_runs ..];
}

fn writeJson(file: zig_api.File, value: HistoryReport) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

fn writeMarkdown(file: zig_api.File, history: HistoryReport) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(&buffer);

    try writer.interface.writeAll("# Performance Dashboard\n\n");
    try writer.interface.writeAll("Auto-generated from the weekly performance workflow.\n\n");
    if (history.entries.len == 0) {
        try writer.interface.writeAll("No history available yet.\n");
        try writer.interface.flush();
        return;
    }

    const latest = history.entries[history.entries.len - 1];
    const previous = if (history.entries.len >= 2) history.entries[history.entries.len - 2] else null;

    try writer.interface.print("- Latest run: `{s}`\n", .{latest.label});
    try writer.interface.print("- Commit: `{s}`\n", .{latest.commit_sha});
    try writer.interface.print("- Samples: iterations `{d}`, warmup `{d}`\n\n", .{ latest.iterations, latest.warmup });

    try writer.interface.writeAll("## Latest Snapshot\n\n");
    try writer.interface.writeAll("| Case | Median (ms) | Mean (ms) | Previous Median (ms) | Delta |\n");
    try writer.interface.writeAll("| --- | ---: | ---: | ---: | ---: |\n");
    for (latest.cases) |item| {
        const prev_value = if (previous) |prev| findCase(prev.cases, item.name) else null;
        if (prev_value) |prev_case| {
            var delta_buf: [64]u8 = undefined;
            try writer.interface.print(
                "| `{s}` | {d:.3} | {d:.3} | {d:.3} | {s} |\n",
                .{ item.name, item.median_ms, item.mean_ms, prev_case.median_ms, try formatDeltaPercent(item.median_ms, prev_case.median_ms, &delta_buf) },
            );
        } else {
            try writer.interface.print(
                "| `{s}` | {d:.3} | {d:.3} | - | - |\n",
                .{ item.name, item.median_ms, item.mean_ms },
            );
        }
    }

    try writer.interface.writeAll("\n## Trend Charts (Last 12 Runs)\n\n");
    const chart_entries = lastEntries(history.entries, 12);
    for (latest.cases) |item| {
        try writer.interface.print("### `{s}`\n\n", .{item.name});
        try writer.interface.writeAll("```mermaid\nxychart-beta\n");
        try writer.interface.print("    title \"{s} median ms\"\n", .{item.name});
        try writer.interface.writeAll("    x-axis [");
        for (chart_entries, 0..) |entry, idx| {
            if (idx != 0) try writer.interface.writeAll(", ");
            try writer.interface.print("\"{s}\"", .{entry.label});
        }
        try writer.interface.writeAll("]\n");
        const max_y = maxMedianForCase(chart_entries, item.name);
        try writer.interface.print("    y-axis \"Median ms\" 0 --> {d}\n", .{max_y});
        try writer.interface.writeAll("    line [");
        for (chart_entries, 0..) |entry, idx| {
            if (idx != 0) try writer.interface.writeAll(", ");
            const case_value = findCase(entry.cases, item.name) orelse continue;
            try writer.interface.print("{d}", .{@as(u64, @intFromFloat(@round(case_value.median_ms)))});
        }
        try writer.interface.writeAll("]\n```\n\n");
    }

    try writer.interface.writeAll("## Recent History (Last 12 Runs)\n\n");
    try writer.interface.writeAll("| Run | Commit |");
    for (latest.cases) |item| {
        try writer.interface.print(" `{s}` |", .{item.name});
    }
    try writer.interface.writeAll("\n| --- | --- |");
    for (latest.cases) |_| {
        try writer.interface.writeAll(" ---: |");
    }
    try writer.interface.writeAll("\n");
    for (chart_entries) |entry| {
        try writer.interface.print("| `{s}` | `{s}` |", .{ entry.label, entry.commit_sha });
        for (latest.cases) |item| {
            if (findCase(entry.cases, item.name)) |case_value| {
                try writer.interface.print(" {d:.3} |", .{case_value.median_ms});
            } else {
                try writer.interface.writeAll(" - |");
            }
        }
        try writer.interface.writeAll("\n");
    }

    try writer.interface.flush();
}

fn lastEntries(entries: []const HistoryEntry, count: usize) []const HistoryEntry {
    if (entries.len <= count) return entries;
    return entries[entries.len - count ..];
}

fn maxMedianForCase(entries: []const HistoryEntry, case_name: []const u8) u64 {
    var max_value: f64 = 0.0;
    for (entries) |entry| {
        if (findCase(entry.cases, case_name)) |item| {
            if (item.median_ms > max_value) max_value = item.median_ms;
        }
    }
    if (max_value <= 0.0) return 1;
    return @max(1, @as(u64, @intFromFloat(@ceil(max_value * 1.2))));
}

fn findCase(cases: []const HistoryCase, name: []const u8) ?HistoryCase {
    for (cases) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn formatDeltaPercent(current: f64, previous: f64, scratch: []u8) ![]const u8 {
    if (previous == 0.0) return "-";
    const delta_pct = ((current - previous) / previous) * 100.0;
    return std.fmt.bufPrint(scratch, "{d:.2}%", .{delta_pct});
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    try zig_api.cwd().makePath(dir);
}

fn printParseArgError(file: zig_api.File, parse_err: ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_value => |flag| try writer.interface.print("error: missing value for flag {s}\n", .{flag}),
        .unknown_flag => |flag| try writer.interface.print("error: unknown flag: {s}\n", .{flag}),
        .missing_history => try writer.interface.writeAll("error: missing --history <path>\n"),
        .missing_candidate => try writer.interface.writeAll("error: missing --candidate <path>\n"),
        .missing_markdown => try writer.interface.writeAll("error: missing --markdown <path>\n"),
        .missing_commit_sha => try writer.interface.writeAll("error: missing --commit-sha <sha>\n"),
        .missing_label => try writer.interface.writeAll("error: missing --label <text>\n"),
        .invalid_max_runs => |value| try writer.interface.print("error: invalid max runs value: {s}\n", .{value}),
    }
    try writer.interface.flush();
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage: perf_dashboard --history <path> --candidate <path> --markdown <path> --commit-sha <sha> --label <text> [--max-runs <n>]
        \\Options:
        \\  --history <path>       Performance history JSON to update
        \\  --candidate <path>     Current benchmark JSON report
        \\  --markdown <path>      Markdown dashboard output path
        \\  --commit-sha <sha>     Commit associated with the candidate benchmark
        \\  --label <text>         Human-readable run label (for example 2026-03-16)
        \\  --max-runs <n>         Keep at most this many history entries (default: 52)
        \\  -h, --help             Show this help
        \\
    );
}
