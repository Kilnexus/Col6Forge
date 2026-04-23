const std = @import("std");
const runtime_text = @import("runtime_text.zig");
const zig_compat = @import("zig_compat.zig");

const FILE = opaque {};

extern fn col6forge_rt_stdin() ?*FILE;
extern fn col6forge_rt_stderr() ?*FILE;
extern fn col6forge_rt_stdout() ?*FILE;
extern fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, stream: *FILE) usize;
extern fn fflush(stream: *FILE) c_int;
extern fn fgetc(stream: *FILE) c_int;
extern fn exit(status: c_int) noreturn;

const PauseAction = enum {
    continue_,
    wait,
    stop,
};

fn resolvePauseAction(mode: c_int, interactive: bool) PauseAction {
    return switch (mode) {
        1 => .continue_,
        2 => .stop,
        else => if (interactive) .wait else .continue_,
    };
}

const cstrlen = runtime_text.cstrlen;

fn isInteractiveStdio() bool {
    return zig_compat.stdinIsTty() and zig_compat.stderrIsTty();
}

fn pauseOutput() ?*FILE {
    return col6forge_rt_stderr() orelse col6forge_rt_stdout();
}

fn payloadLen(payload: ?[*:0]const u8) usize {
    if (payload == null) return 0;
    return cstrlen(payload.?);
}

fn writePausePayload(out: *FILE, payload: ?[*:0]const u8) bool {
    const len = payloadLen(payload);
    if (len == 0) return false;
    const prefix = "PAUSE: ";
    const suffix = "\n";
    const text = payload.?;
    _ = fwrite(@ptrCast(prefix.ptr), 1, prefix.len, out);
    _ = fwrite(@ptrCast(text), 1, len, out);
    _ = fwrite(@ptrCast(suffix.ptr), 1, suffix.len, out);
    return true;
}

fn waitForEnter(payload: ?[*:0]const u8) void {
    if (pauseOutput()) |out| {
        _ = writePausePayload(out, payload);
        const msg = "PAUSE: press Enter to continue...\n";
        _ = fwrite(@ptrCast(msg.ptr), 1, msg.len, out);
        _ = fflush(out);
    }

    const input = col6forge_rt_stdin() orelse return;
    while (true) {
        const ch = fgetc(input);
        if (ch == -1 or ch == 10) break;
    }
}

fn emitPauseContinueNotice(payload: ?[*:0]const u8) void {
    if (pauseOutput()) |out| {
        if (writePausePayload(out, payload)) {
            _ = fflush(out);
            return;
        }
        const nl = "\n";
        _ = fwrite(@ptrCast(nl.ptr), 1, nl.len, out);
        _ = fflush(out);
    }
}

pub export fn col6forge_pause_with_payload(mode: c_int, payload: ?[*:0]const u8) callconv(.c) void {
    const interactive = isInteractiveStdio();
    switch (resolvePauseAction(mode, interactive)) {
        .continue_ => {
            // Legacy PAUSE in batch mode still leaves a visible separator line.
            if (mode == 0 and !interactive) emitPauseContinueNotice(payload);
            return;
        },
        .wait => waitForEnter(payload),
        .stop => {
            emitPauseContinueNotice(payload);
            exit(0);
        },
    }
}

pub export fn col6forge_pause(mode: c_int) callconv(.c) void {
    col6forge_pause_with_payload(mode, null);
}

test "resolvePauseAction auto waits only for interactive" {
    try std.testing.expect(resolvePauseAction(0, true) == .wait);
    try std.testing.expect(resolvePauseAction(0, false) == .continue_);
}

test "resolvePauseAction continue always continues" {
    try std.testing.expect(resolvePauseAction(1, true) == .continue_);
    try std.testing.expect(resolvePauseAction(1, false) == .continue_);
}

test "resolvePauseAction stop is predictable" {
    try std.testing.expect(resolvePauseAction(2, true) == .stop);
    try std.testing.expect(resolvePauseAction(2, false) == .stop);
}

test "payloadLen handles null and empty payload" {
    try std.testing.expectEqual(@as(usize, 0), payloadLen(null));
    const empty = "";
    try std.testing.expectEqual(@as(usize, 0), payloadLen(empty));
    const text = "INIT DONE";
    try std.testing.expectEqual(@as(usize, 9), payloadLen(text));
}
