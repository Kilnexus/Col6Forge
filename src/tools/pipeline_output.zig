const std = @import("std");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

pub fn emitPipelineToFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    emit: Col6Forge.EmitKind,
    output_path: []const u8,
    diag_bag: *Col6Forge.diag.Bag,
) !void {
    var out_file = try zig_api.cwd().createFile(output_path, .{ .truncate = true });
    defer out_file.close();
    var out_buf: [32 * 1024]u8 = undefined;
    var out_writer = out_file.writer(&out_buf);
    try Col6Forge.runPipelineToWriterWithOptionsAndDiagnostics(
        allocator,
        input_path,
        emit,
        &out_writer.interface,
        .{ .coarse_source_map = true },
        diag_bag,
    );
    try out_writer.interface.flush();
}

pub fn printPipelineError(path: []const u8, diag_bag: *const Col6Forge.diag.Bag, err: anyerror) void {
    var stderr = zig_api.File.stderr();
    var buffer: [4096]u8 = undefined;
    var writer = stderr.writer(&buffer);
    Col6Forge.writePipelineErrorDiagnostic(&writer.interface, diag_bag, path, err) catch |write_err| {
        std.log.err("pipeline error: {s} ({s}, {s})\n", .{ path, @errorName(err), @errorName(write_err) });
        return;
    };
    writer.interface.flush() catch {};
}
