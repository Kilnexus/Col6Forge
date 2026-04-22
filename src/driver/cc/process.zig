const std = @import("std");
const Col6Forge = @import("Col6Forge");
const types = @import("types.zig");
const zig_api = Col6Forge.zig_api;

pub fn runProcessCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !types.ProcessResult {
    const result = try std.process.run(allocator, zig_api.defaultIo(), .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

pub fn runCheckedCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    step_name: []const u8,
) !void {
    for (argv, 0..) |arg, idx| {
        if (!std.unicode.utf8ValidateSlice(arg)) {
            var stderr = zig_api.File.stderr();
            var buffer: [512]u8 = undefined;
            var writer = stderr.writer(&buffer);
            try writer.interface.print("{s} invalid utf8 at argv[{d}]\\n", .{ step_name, idx });
            try writer.interface.flush();
            return error.InvalidArguments;
        }
    }

    const result = runProcessCapture(allocator, argv) catch |err| {
        var stderr = zig_api.File.stderr();
        var buffer: [512]u8 = undefined;
        var writer = stderr.writer(&buffer);
        try writer.interface.print("{s} failed to start: {s}\n", .{ step_name, @errorName(err) });
        try writer.interface.flush();
        return error.CommandFailed;
    };
    defer result.deinit(allocator);

    if (isZeroExit(result.term)) return;

    var stderr = zig_api.File.stderr();
    var buffer: [8192]u8 = undefined;
    var writer = stderr.writer(&buffer);
    try writer.interface.print("=== {s} FAILED ===\n", .{step_name});
    try writer.interface.print("command: ", .{});
    for (argv, 0..) |arg, idx| {
        if (idx != 0) try writer.interface.writeAll(" ");
        try writer.interface.writeAll(arg);
    }
    try writer.interface.writeAll("\n");
    if (result.stdout.len != 0) {
        try writer.interface.print("stdout:\n{s}\n", .{result.stdout});
    }
    if (result.stderr.len != 0) {
        try writer.interface.print("stderr:\n{s}\n", .{result.stderr});
    }
    try writer.interface.flush();
    return error.CommandFailed;
}

pub fn runPassthroughCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try runProcessCapture(allocator, argv);
    defer result.deinit(allocator);

    if (result.stdout.len != 0) {
        try zig_api.File.stdout().writeAll(result.stdout);
    }
    if (result.stderr.len != 0) {
        try zig_api.File.stderr().writeAll(result.stderr);
    }
    if (!isZeroExit(result.term)) {
        return error.CommandFailed;
    }
}

pub fn isZeroExit(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
