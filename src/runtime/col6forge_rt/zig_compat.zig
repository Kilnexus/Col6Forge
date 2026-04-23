const std = @import("std");

const has_legacy_fs = @hasDecl(std.fs, "cwd");
const has_thread_mutex = @hasDecl(std.Thread, "Mutex");

threadlocal var threaded_io_ready: bool = false;
threadlocal var threaded_io: if (has_legacy_fs) void else std.Io.Threaded = if (has_legacy_fs) {} else undefined;

fn io() std.Io {
    if (comptime has_legacy_fs) unreachable;
    if (!threaded_io_ready) {
        threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
        threaded_io_ready = true;
    }
    return threaded_io.io();
}

const RawMutex = if (has_thread_mutex) std.Thread.Mutex else std.Io.Mutex;

fn rawMutexInit() RawMutex {
    return if (comptime has_thread_mutex) .{} else .init;
}

fn rawLock(mutex: *RawMutex) void {
    if (comptime has_thread_mutex) {
        mutex.lock();
    } else {
        mutex.lockUncancelable(io());
    }
}

fn rawUnlock(mutex: *RawMutex) void {
    if (comptime has_thread_mutex) {
        mutex.unlock();
    } else {
        mutex.unlock(io());
    }
}

pub const Mutex = struct {
    raw: RawMutex = rawMutexInit(),

    pub fn lock(self: *Mutex) void {
        rawLock(&self.raw);
    }

    pub fn unlock(self: *Mutex) void {
        rawUnlock(&self.raw);
    }
};

pub fn fileExists(path: []const u8) bool {
    if (comptime has_legacy_fs) {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
    return true;
}

pub fn stdinIsTty() bool {
    if (comptime has_legacy_fs) return std.fs.File.stdin().isTty();
    return std.Io.File.stdin().isTty(io()) catch false;
}

pub fn stderrIsTty() bool {
    if (comptime has_legacy_fs) return std.fs.File.stderr().isTty();
    return std.Io.File.stderr().isTty(io()) catch false;
}
