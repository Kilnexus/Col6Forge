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
    const logical_lines = try normalizeInput(allocator, input_path, contents, options, diag_bag, &profile);
    defer source_form.freeLogicalLines(allocator, logical_lines);

    const output = emit_mod.emitLlvmModule(allocator, input_path, contents, logical_lines, options, diag_bag, &profile) catch |err| {
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
    const logical_lines = try normalizeInput(allocator, input_path, contents, options, diag_bag, &profile);
    defer source_form.freeLogicalLines(allocator, logical_lines);

    emit_mod.emitLlvmModuleToWriter(allocator, input_path, contents, logical_lines, writer, options, diag_bag, &profile) catch |err| {
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
