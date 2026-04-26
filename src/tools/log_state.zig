const std = @import("std");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

pub const LogState = struct {
    mutex: std.Io.Mutex = .init,

    pub fn lock(self: *LogState) void {
        self.mutex.lockUncancelable(zig_api.defaultIo());
    }

    pub fn unlock(self: *LogState) void {
        self.mutex.unlock(zig_api.defaultIo());
    }

    pub fn stdout(self: *LogState, comptime fmt: []const u8, args: anytype) void {
        self.print(zig_api.File.stdout(), fmt, args);
    }

    pub fn stderr(self: *LogState, comptime fmt: []const u8, args: anytype) void {
        self.print(zig_api.File.stderr(), fmt, args);
    }

    pub fn print(self: *LogState, file: zig_api.File, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(zig_api.defaultIo());
        defer self.mutex.unlock(zig_api.defaultIo());
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(&buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }
};
