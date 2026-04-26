const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

pub fn report(log_state: anytype, diag_bag: *const Col6Forge.diag.Bag, input_path: []const u8, err: anyerror) !void {
    var stderr = zig_api.File.stderr();
    var buffer: [4096]u8 = undefined;
    var writer = stderr.writer(&buffer);
    log_state.lock();
    defer log_state.unlock();
    try Col6Forge.writePipelineErrorDiagnostic(&writer.interface, diag_bag, input_path, err);
    try writer.interface.flush();
}
