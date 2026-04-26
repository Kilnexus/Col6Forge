const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

pub fn report(input_path: []const u8, diag_bag: *const Col6Forge.diag.Bag, err: anyerror) !void {
    var stderr = zig_api.File.stderr();
    var buffer: [4096]u8 = undefined;
    var writer = stderr.writer(&buffer);
    try Col6Forge.writePipelineErrorDiagnosticWithOptions(&writer.interface, diag_bag, input_path, err, .{
        .ansi = stderr.isTty(),
        .max_source_width = 100,
        .group_related_spans = true,
    });
    try writer.interface.flush();
}
