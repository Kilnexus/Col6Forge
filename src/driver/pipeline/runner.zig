const std = @import("std");
const logical_line = @import("../../frontend/logical_line.zig");
const diag = @import("../../common/diagnostic.zig");
const catalog = @import("../../common/error_catalog.zig");
const source_form = @import("../../frontend/source_form.zig");
const profile_mod = @import("profile.zig");
const diagnostics = @import("diagnostics.zig");
const emit_mod = @import("emit.zig");
const types = @import("types.zig");
const zig_api = @import("../../compat/zig_api.zig");

const PipelineProfile = profile_mod.PipelineProfile;
const nowNs = profile_mod.nowNs;
const elapsedNs = profile_mod.elapsedNs;

pub fn runPipeline(allocator: std.mem.Allocator, input_path: []const u8, emit: types.EmitKind) !types.PipelineResult {
    return runPipelineWithOptions(allocator, input_path, emit, .{});
}

pub fn runPipelineWithOptions(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    emit: types.EmitKind,
    options: types.PipelineOptions,
) !types.PipelineResult {
    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();
    return runPipelineWithOptionsAndDiagnostics(allocator, input_path, emit, options, &diag_bag);
}

pub fn runPipelineWithOptionsAndDiagnostics(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    emit: types.EmitKind,
    options: types.PipelineOptions,
    diag_bag: *diag.Bag,
) !types.PipelineResult {
    _ = emit;
    diag_bag.clear();
    profile_mod.clearLastProfile();
    var profile = PipelineProfile{
        .time_report = options.time_report,
        .capture_profile = options.capture_profile,
        .input_path = input_path,
        .mode = .buffer,
    };
    const total_start = nowNs();
    defer {
        profile.total_ns = elapsedNs(total_start);
        if (profile.capture_profile) profile_mod.storeLastProfileSample(profile);
        profile.emit();
    }

    const contents = try readInputFile(allocator, input_path, diag_bag, &profile);
    defer allocator.free(contents);
    const expanded_contents = try expandIncludeStatements(allocator, input_path, contents, 0);
    defer allocator.free(expanded_contents);
    const logical_lines = try normalizeInput(allocator, input_path, expanded_contents, options, diag_bag, &profile);
    defer source_form.freeLogicalLines(allocator, logical_lines);

    const output = emit_mod.emitLlvmModule(allocator, input_path, expanded_contents, logical_lines, options, diag_bag, &profile) catch |err| {
        profile.markFailure(.pipeline);
        return err;
    };
    return .{ .output = output };
}

pub fn runPipelineToWriter(allocator: std.mem.Allocator, input_path: []const u8, emit: types.EmitKind, writer: anytype) !void {
    return runPipelineToWriterWithOptions(allocator, input_path, emit, writer, .{});
}

pub fn runPipelineToWriterWithOptions(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    emit: types.EmitKind,
    writer: anytype,
    options: types.PipelineOptions,
) !void {
    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();
    return runPipelineToWriterWithOptionsAndDiagnostics(allocator, input_path, emit, writer, options, &diag_bag);
}

pub fn runPipelineToWriterWithOptionsAndDiagnostics(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    emit: types.EmitKind,
    writer: anytype,
    options: types.PipelineOptions,
    diag_bag: *diag.Bag,
) !void {
    _ = emit;
    diag_bag.clear();
    profile_mod.clearLastProfile();
    var profile = PipelineProfile{
        .time_report = options.time_report,
        .capture_profile = options.capture_profile,
        .input_path = input_path,
        .mode = .writer,
    };
    const total_start = nowNs();
    defer {
        profile.total_ns = elapsedNs(total_start);
        if (profile.capture_profile) profile_mod.storeLastProfileSample(profile);
        profile.emit();
    }

    const contents = try readInputFile(allocator, input_path, diag_bag, &profile);
    defer allocator.free(contents);
    const expanded_contents = try expandIncludeStatements(allocator, input_path, contents, 0);
    defer allocator.free(expanded_contents);
    const logical_lines = try normalizeInput(allocator, input_path, expanded_contents, options, diag_bag, &profile);
    defer source_form.freeLogicalLines(allocator, logical_lines);

    emit_mod.emitLlvmModuleToWriter(allocator, input_path, expanded_contents, logical_lines, writer, options, diag_bag, &profile) catch |err| {
        profile.markFailure(.pipeline);
        return err;
    };
}

fn readInputFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    diag_bag: *diag.Bag,
    profile: *PipelineProfile,
) ![]u8 {
    const max_size = 64 * 1024 * 1024;
    const read_start = nowNs();
    const contents = zig_api.cwd().readFileAlloc(allocator, input_path, max_size) catch |err| {
        profile.read_ns = elapsedNs(read_start);
        profile.markFailure(.read);
        if (err == error.FileNotFound) {
            diag_bag.add(input_path, 1, 1, catalog.pipeline.input_not_found.code, catalog.pipeline.input_not_found.message, "");
        }
        return err;
    };
    profile.read_ns = elapsedNs(read_start);
    return contents;
}

fn expandIncludeStatements(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    contents: []const u8,
    depth: usize,
) ![]u8 {
    if (depth >= 32) return allocator.dupe(u8, contents);

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw_line| {
        const line = trimCr(raw_line);
        if (parseIncludeFilename(line)) |include_name| {
            if (try readIncludeFile(allocator, input_path, include_name)) |included| {
                defer allocator.free(included.path);
                defer allocator.free(included.contents);
                const expanded = try expandIncludeStatements(allocator, included.path, included.contents, depth + 1);
                defer allocator.free(expanded);
                try out.appendSlice(expanded);
                if (expanded.len == 0 or expanded[expanded.len - 1] != '\n') try out.append('\n');
                continue;
            }
        }
        try out.appendSlice(line);
        try out.append('\n');
    }

    return out.toOwnedSlice();
}

const IncludeFile = struct {
    path: []u8,
    contents: []u8,
};

fn readIncludeFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    include_name: []const u8,
) !?IncludeFile {
    const include_path = if (std.fs.path.isAbsolute(include_name))
        try allocator.dupe(u8, include_name)
    else blk: {
        const dir = std.fs.path.dirname(input_path) orelse ".";
        break :blk try std.fs.path.join(allocator, &.{ dir, include_name });
    };
    errdefer allocator.free(include_path);

    const max_size = 64 * 1024 * 1024;
    const included = zig_api.cwd().readFileAlloc(allocator, include_path, max_size) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(include_path);
            return null;
        },
        else => return err,
    };
    return .{ .path = include_path, .contents = included };
}

fn parseIncludeFilename(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!startsWithWordIgnoreCase(trimmed, "include")) return null;
    var rest = std.mem.trimStart(u8, trimmed["include".len..], " \t");
    if (rest.len < 2) return null;
    const quote = rest[0];
    if (quote != '"' and quote != '\'') return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, quote) orelse return null;
    return rest[0..end];
}

fn startsWithWordIgnoreCase(text: []const u8, word: []const u8) bool {
    if (text.len < word.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[0..word.len], word)) return false;
    if (text.len == word.len) return true;
    const next = text[word.len];
    return !(std.ascii.isAlphabetic(next) or std.ascii.isDigit(next) or next == '_');
}

fn trimCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn normalizeInput(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    contents: []const u8,
    options: types.PipelineOptions,
    diag_bag: *diag.Bag,
    profile: *PipelineProfile,
) ![]logical_line.LogicalLine {
    const normalize_start = nowNs();
    const logical_lines = source_form.normalizePath(.auto, allocator, input_path, contents, options.coarse_source_map) catch |err| {
        profile.normalize_ns = elapsedNs(normalize_start);
        profile.markFailure(.normalize);
        diagnostics.setDefaultDiagnostic(diag_bag, input_path, contents, catalog.pipeline.normalize_failed.code, catalog.pipeline.normalize_failed.message, err);
        return err;
    };
    profile.normalize_ns = elapsedNs(normalize_start);
    return logical_lines;
}
