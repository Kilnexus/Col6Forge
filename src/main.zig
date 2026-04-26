const std = @import("std");
const Col6Forge = @import("Col6Forge");
const cc_driver = @import("driver/cc_driver.zig");
const pause_mode_shared = @import("driver/shared/pause_mode.zig");
const pipeline_error = @import("driver/shared/pipeline_error.zig");
const zig_api = Col6Forge.zig_api;
const cli_args = Col6Forge.process_args;
const allocArgs = cli_args.allocArgs;
const freeArgs = cli_args.freeArgs;
const getEnvVarOwned = cli_args.getEnvVarOwned;

pub fn main(init: std.process.Init) void {
    runMain(init) catch |err| {
        var stderr = zig_api.File.stderr();
        var buffer: [512]u8 = undefined;
        var writer = stderr.writer(&buffer);
        writer.interface.print("internal error: {s}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn runMain(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try allocArgs(allocator, init.minimal.args);
    defer freeArgs(allocator, args);

    if (args.len >= 1 and isCcToolInvocation(args[0])) {
        cc_driver.runOrExit(allocator, args);
    }

    if (args.len >= 2 and std.mem.eql(u8, args[1], "cc")) {
        cc_driver.runOrExit(allocator, args);
    }

    const parsed = switch (parseArgs(allocator, args)) {
        .success => |value| value,
        .failure => |parse_err| failWithUsage(parse_err),
    };
    if (parsed.show_help) {
        try printUsage(zig_api.File.stdout());
        return;
    }

    if (parsed.output_path) |path| {
        const null_output_value = getEnvVarOwned(allocator, init, "COL6FORGE_NULL_OUTPUT") catch null;
        defer if (null_output_value) |value| allocator.free(value);
        const use_null_output = if (null_output_value) |value| value.len > 0 and value[0] == '1' else false;
        if (use_null_output) {
            var diag_bag = Col6Forge.diag.Bag.init(allocator);
            defer diag_bag.deinit();
            var null_buf: [256]u8 = undefined;
            var null_writer: std.Io.Writer.Discarding = .init(&null_buf);
            Col6Forge.runPipelineToWriterWithOptionsAndDiagnostics(
                allocator,
                parsed.input_path,
                parsed.emit,
                &null_writer.writer,
                .{
                    .bounds_check = parsed.bounds_check,
                    .dialect = parsed.dialect,
                    .pause_mode = parsed.pause_mode,
                    .time_report = parsed.time_report,
                },
                &diag_bag,
            ) catch |err| {
                failPipeline(parsed.input_path, &diag_bag, err);
            };
            return;
        }
        const count_output_value = getEnvVarOwned(allocator, init, "COL6FORGE_COUNT_OUTPUT") catch null;
        defer if (count_output_value) |value| allocator.free(value);
        const use_count_output = if (count_output_value) |value| value.len > 0 and value[0] == '1' else false;
        if (use_count_output) {
            var diag_bag = Col6Forge.diag.Bag.init(allocator);
            defer diag_bag.deinit();
            var count_writer = CountingOutputWriter{};
            Col6Forge.runPipelineToWriterWithOptionsAndDiagnostics(
                allocator,
                parsed.input_path,
                parsed.emit,
                &count_writer,
                .{
                    .bounds_check = parsed.bounds_check,
                    .dialect = parsed.dialect,
                    .pause_mode = parsed.pause_mode,
                    .time_report = parsed.time_report,
                },
                &diag_bag,
            ) catch |err| {
                failPipeline(parsed.input_path, &diag_bag, err);
            };
            var msg_buf: [64]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "emitted {d} bytes\n", .{count_writer.count});
            try zig_api.File.stdout().writeAll(msg);
            return;
        }
        var diag_bag = Col6Forge.diag.Bag.init(allocator);
        defer diag_bag.deinit();
        var output_file = try zig_api.cwd().createFile(path, .{ .truncate = true });
        defer output_file.close();
        var file_writer = FileOutputWriter{ .file = &output_file, .allocator = allocator };
        Col6Forge.runPipelineToWriterWithOptionsAndDiagnostics(
            allocator,
            parsed.input_path,
            parsed.emit,
            &file_writer,
            .{
                .bounds_check = parsed.bounds_check,
                .dialect = parsed.dialect,
                .pause_mode = parsed.pause_mode,
                .time_report = parsed.time_report,
            },
            &diag_bag,
        ) catch |err| {
            failPipeline(parsed.input_path, &diag_bag, err);
        };
    } else {
        var diag_bag = Col6Forge.diag.Bag.init(allocator);
        defer diag_bag.deinit();
        const result = Col6Forge.runPipelineWithOptionsAndDiagnostics(
            allocator,
            parsed.input_path,
            parsed.emit,
            .{
                .bounds_check = parsed.bounds_check,
                .dialect = parsed.dialect,
                .pause_mode = parsed.pause_mode,
                .time_report = parsed.time_report,
            },
            &diag_bag,
        ) catch |err| {
            failPipeline(parsed.input_path, &diag_bag, err);
        };
        defer allocator.free(result.output);
        try zig_api.File.stdout().writeAll(result.output);
    }
}

fn isCcToolInvocation(argv0: []const u8) bool {
    const base = crossPlatformBasename(argv0);
    const name = if (std.ascii.endsWithIgnoreCase(base, ".exe")) base[0 .. base.len - 4] else base;
    return std.ascii.eqlIgnoreCase(name, "col6forge-cc") or std.ascii.eqlIgnoreCase(name, "col6cc");
}

fn crossPlatformBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, idx| {
        if (ch == '/' or ch == '\\') start = idx + 1;
    }
    return path[start..];
}

const FileOutputWriter = struct {
    file: *zig_api.File,
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *FileOutputWriter, bytes: []const u8) !void {
        try self.file.writeAll(bytes);
    }

    pub fn print(self: *FileOutputWriter, comptime fmt: []const u8, args: anytype) !void {
        var stack_buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&stack_buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => {
                const heap_text = try std.fmt.allocPrint(self.allocator, fmt, args);
                defer self.allocator.free(heap_text);
                try self.file.writeAll(heap_text);
                return;
            },
        };
        try self.file.writeAll(text);
    }
};

const CountingOutputWriter = struct {
    count: u128 = 0,

    pub fn writeAll(self: *CountingOutputWriter, bytes: []const u8) !void {
        self.count +%= bytes.len;
    }

    pub fn print(self: *CountingOutputWriter, comptime fmt: []const u8, args: anytype) !void {
        var stack_buf: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&stack_buf, fmt, args);
        try self.writeAll(text);
    }
};

const ParsedArgs = struct {
    input_path: []const u8,
    output_path: ?[]const u8,
    emit: Col6Forge.EmitKind,
    bounds_check: bool,
    dialect: Col6Forge.Dialect,
    pause_mode: Col6Forge.PauseMode,
    time_report: bool,
    show_help: bool,
};

const ParseArgError = union(enum) {
    missing_output_path,
    missing_std,
    missing_pause_mode,
    invalid_std: []const u8,
    invalid_pause_mode: []const u8,
    unknown_flag: []const u8,
    too_many_inputs: struct {
        first: []const u8,
        extra: []const u8,
    },
    missing_input_file,
};

const ParseArgsOutcome = union(enum) {
    success: ParsedArgs,
    failure: ParseArgError,
};

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ParseArgsOutcome {
    _ = allocator;
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var emit: Col6Forge.EmitKind = .llvm;
    var bounds_check = false;
    var dialect: Col6Forge.Dialect = .default;
    var pause_mode: Col6Forge.PauseMode = .auto;
    var time_report = false;
    var show_help = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-emit-llvm")) {
            emit = .llvm;
            continue;
        }
        if (std.mem.eql(u8, arg, "-fbounds-check")) {
            bounds_check = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-std")) {
            if (i + 1 >= args.len) return .{ .failure = .missing_std };
            i += 1;
            dialect = parseDialect(args[i]) orelse return .{ .failure = .{ .invalid_std = args[i] } };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-std=")) {
            const value = arg["-std=".len..];
            dialect = parseDialect(value) orelse return .{ .failure = .{ .invalid_std = value } };
            continue;
        }
        if (std.mem.eql(u8, arg, "-fpause-mode")) {
            if (i + 1 >= args.len) return .{ .failure = .missing_pause_mode };
            i += 1;
            pause_mode = pause_mode_shared.parsePauseMode(args[i]) orelse return .{ .failure = .{ .invalid_pause_mode = args[i] } };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-fpause-mode=")) {
            const value = arg["-fpause-mode=".len..];
            pause_mode = pause_mode_shared.parsePauseMode(value) orelse return .{ .failure = .{ .invalid_pause_mode = value } };
            continue;
        }
        if (std.mem.eql(u8, arg, "-ftime-report") or std.mem.eql(u8, arg, "--time-report")) {
            time_report = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-o")) {
            if (i + 1 >= args.len) return .{ .failure = .missing_output_path };
            i += 1;
            output_path = args[i];
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return .{ .failure = .{ .unknown_flag = arg } };
        if (input_path == null) {
            input_path = arg;
            continue;
        }
        return .{
            .failure = .{
                .too_many_inputs = .{
                    .first = input_path.?,
                    .extra = arg,
                },
            },
        };
    }

    if (show_help) {
        return .{ .success = .{
            .input_path = "",
            .output_path = output_path,
            .emit = emit,
            .bounds_check = bounds_check,
            .dialect = dialect,
            .pause_mode = pause_mode,
            .time_report = time_report,
            .show_help = true,
        } };
    }
    if (input_path == null) return .{ .failure = .missing_input_file };

    return .{ .success = .{
        .input_path = input_path.?,
        .output_path = output_path,
        .emit = emit,
        .bounds_check = bounds_check,
        .dialect = dialect,
        .pause_mode = pause_mode,
        .time_report = time_report,
        .show_help = false,
    } };
}

fn parseDialect(value: []const u8) ?Col6Forge.Dialect {
    if (std.ascii.eqlIgnoreCase(value, "default")) return .default;
    if (std.ascii.eqlIgnoreCase(value, "f95")) return .default;
    if (std.ascii.eqlIgnoreCase(value, "f77")) return .f77_legacy;
    if (std.ascii.eqlIgnoreCase(value, "legacy")) return .f77_legacy;
    return null;
}

fn reportPipelineError(input_path: []const u8, diag_bag: *const Col6Forge.diag.Bag, err: anyerror) !void {
    return pipeline_error.report(input_path, diag_bag, err);
}

fn failPipeline(input_path: []const u8, diag_bag: *const Col6Forge.diag.Bag, err: anyerror) noreturn {
    reportPipelineError(input_path, diag_bag, err) catch {
        var stderr = zig_api.File.stderr();
        var buffer: [512]u8 = undefined;
        var writer = stderr.writer(&buffer);
        writer.interface.print("pipeline error: {s} ({s})\n", .{ input_path, @errorName(err) }) catch {};
        writer.interface.flush() catch {};
    };
    std.process.exit(1);
}

fn writeParseArgError(writer: *std.Io.Writer, parse_err: ParseArgError) void {
    switch (parse_err) {
        .missing_output_path => writer.print("error: missing output path after -o\n", .{}) catch {},
        .missing_std => writer.print("error: missing standard after -std\n", .{}) catch {},
        .missing_pause_mode => writer.print("error: missing pause mode after -fpause-mode\n", .{}) catch {},
        .invalid_std => |value| writer.print("error: invalid Fortran standard: {s}\n", .{value}) catch {},
        .invalid_pause_mode => |value| writer.print("error: invalid pause mode: {s}\n", .{value}) catch {},
        .unknown_flag => |flag| writer.print("error: unknown flag: {s}\n", .{flag}) catch {},
        .too_many_inputs => |inputs| writer.print("error: multiple input files provided: {s} and {s}\n", .{ inputs.first, inputs.extra }) catch {},
        .missing_input_file => writer.print("error: missing input file\n", .{}) catch {},
    }
}

test "main entry import graph accepts repository array_constructor_14 file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const result = try Col6Forge.runPipelineWithOptions(
        allocator,
        "tests/gcc-tests/gfortran.dg/array_constructor_14.f90",
        .llvm,
        .{},
    );
    defer allocator.free(result.output);
    try testing.expect(result.output.len != 0);
}

test "main entry import graph accepts repository whole_file_9 file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const result = try Col6Forge.runPipelineWithOptions(
        allocator,
        "tests/gcc-tests/gfortran.dg/whole_file_9.f90",
        .llvm,
        .{},
    );
    defer allocator.free(result.output);
    try testing.expect(result.output.len != 0);
}

test "main parseArgs accepts -std=f77" {
    const parsed = parseArgs(std.testing.allocator, &[_][]const u8{ "col6forge", "-std=f77", "input.f" }).success;
    try std.testing.expectEqual(Col6Forge.Dialect.f77_legacy, parsed.dialect);
}

fn failWithUsage(parse_err: ParseArgError) noreturn {
    printUsage(zig_api.File.stderr()) catch {};
    var stderr = zig_api.File.stderr();
    var buffer: [256]u8 = undefined;
    var writer = stderr.writer(&buffer);
    writeParseArgError(&writer.interface, parse_err);
    writer.interface.flush() catch {};
    std.process.exit(2);
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage:
        \\  col6forge <file.f> -emit-llvm -o <out.ll>
        \\  col6forge cc <file.f> [options] [extra_link_inputs...] [-- <zig-cc-flags...>]
        \\  col6forge-cc <file.f> [options] [extra_link_inputs...] [-- <zig-cc-flags...>]
        \\Options (IR mode):
        \\  -emit-llvm    Emit LLVM IR (default)
        \\  -fbounds-check  Enable runtime array bounds checking
        \\  -std <default|f77>  Fortran dialect gate for semantic lowering (default: default)
        \\  -fpause-mode <auto|continue|stop>  PAUSE runtime policy (default: auto)
        \\  -ftime-report, --time-report  Print parse/sema/codegen timing report to stderr
        \\  -o <path>     Write output to file
        \\  -h, --help    Show this help
        \\
        \\Run `col6forge cc --help` for compiler-driver mode details.
        \\
    );
}

test "args parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const missing_input = parseArgs(allocator, &[_][]const u8{"col6forge"});
    try testing.expect(missing_input == .failure);
    try testing.expect(missing_input.failure == .missing_input_file);

    const missing_output = parseArgs(allocator, &[_][]const u8{ "col6forge", "-o" });
    try testing.expect(missing_output == .failure);
    try testing.expect(missing_output.failure == .missing_output_path);

    const unknown_flag = parseArgs(allocator, &[_][]const u8{ "col6forge", "-bogus", "file.f" });
    try testing.expect(unknown_flag == .failure);
    try testing.expectEqualStrings("-bogus", unknown_flag.failure.unknown_flag);

    const too_many = parseArgs(allocator, &[_][]const u8{ "col6forge", "a.f", "b.f" });
    try testing.expect(too_many == .failure);
    try testing.expectEqualStrings("a.f", too_many.failure.too_many_inputs.first);
    try testing.expectEqualStrings("b.f", too_many.failure.too_many_inputs.extra);

    const help = parseArgs(allocator, &[_][]const u8{ "col6forge", "-h", "-o", "out.ll" }).success;
    try testing.expect(help.show_help);
    try testing.expectEqualStrings("", help.input_path);
    try testing.expectEqualStrings("out.ll", help.output_path.?);
    try testing.expectEqual(Col6Forge.EmitKind.llvm, help.emit);
    try testing.expect(!help.bounds_check);
    try testing.expect(help.pause_mode == .auto);
    try testing.expect(!help.time_report);

    const parsed = parseArgs(allocator, &[_][]const u8{ "col6forge", "-emit-llvm", "input.f" }).success;
    try testing.expect(!parsed.show_help);
    try testing.expectEqualStrings("input.f", parsed.input_path);
    try testing.expect(parsed.output_path == null);
    try testing.expectEqual(Col6Forge.EmitKind.llvm, parsed.emit);
    try testing.expect(!parsed.bounds_check);
    try testing.expect(parsed.pause_mode == .auto);
    try testing.expect(!parsed.time_report);

    const parsed_bounds = parseArgs(allocator, &[_][]const u8{ "col6forge", "-fbounds-check", "input.f" }).success;
    try testing.expect(parsed_bounds.bounds_check);

    const parsed_pause = parseArgs(allocator, &[_][]const u8{ "col6forge", "-fpause-mode=stop", "input.f" }).success;
    try testing.expect(parsed_pause.pause_mode == .stop);

    const parsed_timing = parseArgs(allocator, &[_][]const u8{ "col6forge", "-ftime-report", "input.f" }).success;
    try testing.expect(parsed_timing.time_report);
}

test "cc executable name detection" {
    const testing = std.testing;
    try testing.expect(isCcToolInvocation("col6forge-cc"));
    try testing.expect(isCcToolInvocation("col6forge-cc.exe"));
    try testing.expect(isCcToolInvocation("C:\\tools\\col6cc.exe"));
    try testing.expect(!isCcToolInvocation("col6forge"));
}
