const std = @import("std");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

pub fn timeoutMonitor(
    child: *std.process.Child,
    done: *std.atomic.Value(bool),
    timed_out: *std.atomic.Value(bool),
    timeout_ms: u64,
) void {
    const deadline_ns = zig_api.nowNs() + @as(i128, timeout_ms) * std.time.ns_per_ms;
    while (true) {
        if (done.load(.seq_cst)) return;
        const now_ns = zig_api.nowNs();
        if (now_ns >= deadline_ns) break;
        const remaining_ms: u64 = @intCast(@divTrunc(deadline_ns - now_ns, std.time.ns_per_ms));
        const sleep_ms = if (remaining_ms > 50) 50 else remaining_ms;
        std.Io.sleep(zig_api.defaultIo(), .fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
    }
    if (done.load(.seq_cst)) return;
    timed_out.store(true, .seq_cst);
    child.kill(zig_api.defaultIo());
}

pub fn terminateChildNoWait(child: *std.process.Child) void {
    child.kill(zig_api.defaultIo());
}
