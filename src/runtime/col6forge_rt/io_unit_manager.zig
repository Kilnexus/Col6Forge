const std = @import("std");
const runtime_text = @import("runtime_text.zig");
const zig_compat = @import("zig_compat.zig");

const COL6FORGE_MAX_UNITS = 256;
const COL6FORGE_FILENAME_MAX = 4096;

const FILE = opaque {};
extern fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn fclose(stream: *FILE) c_int;
extern fn fseek(stream: *FILE, offset: c_long, origin: c_int) c_int;
extern fn ftell(stream: *FILE) c_long;

extern fn unit_filename(unit: c_int, buf: ?[*]u8, len: usize) void;
extern fn col6forge_trim_filename(file: ?[*]const u8, file_len: c_int, out: ?[*]u8, out_len: usize) void;
extern var unit_pos: [COL6FORGE_MAX_UNITS]c_long;
const OpenState = extern struct {
    opened: c_int,
    filename: [COL6FORGE_FILENAME_MAX]u8,
    access: c_int,
    form: c_int,
    blank: c_int,
};
extern var open_units: [COL6FORGE_MAX_UNITS]OpenState;

const StreamMode = enum(u8) {
    none,
    read_only,
    read_write,
};

const StreamEntry = struct {
    stream: ?*FILE = null,
    mode: StreamMode = .none,
    cursor: c_long = 0,
    has_cursor: bool = false,
    lock: zig_compat.Mutex = .{},
    held: bool = false,
};

var manager_mutex: zig_compat.Mutex = .{};
var fixed_entries: [COL6FORGE_MAX_UNITS]StreamEntry = [_]StreamEntry{.{}} ** COL6FORGE_MAX_UNITS;
var extra_entries: std.AutoHashMapUnmanaged(c_int, *StreamEntry) = .{};
var extra_unit_pos: std.AutoHashMapUnmanaged(c_int, c_long) = .{};
var extra_open_units: std.AutoHashMapUnmanaged(c_int, OpenState) = .{};
var open_filename_index: std.StringHashMapUnmanaged(c_int) = .{};
var open_unit_filename_keys: std.AutoHashMapUnmanaged(c_int, []const u8) = .{};

fn runtimeAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

const asConstCStr = runtime_text.asConstCStr;

fn isFixedUnit(unit: c_int) bool {
    return unit >= 0 and unit < COL6FORGE_MAX_UNITS;
}

fn cstrSlice(value: [*:0]const u8) []const u8 {
    return std.mem.span(value);
}

fn findOpenUnitLocked(unit: c_int) ?*OpenState {
    if (isFixedUnit(unit)) return &open_units[@as(usize, @intCast(unit))];
    return extra_open_units.getPtr(unit);
}

fn ensureOpenUnitLocked(unit: c_int) ?*OpenState {
    if (isFixedUnit(unit)) return &open_units[@as(usize, @intCast(unit))];
    if (extra_open_units.getPtr(unit)) |entry| return entry;

    extra_open_units.put(runtimeAllocator(), unit, .{
        .opened = 0,
        .filename = [_]u8{0} ** COL6FORGE_FILENAME_MAX,
        .access = 0,
        .form = 0,
        .blank = 0,
    }) catch return null;
    return extra_open_units.getPtr(unit);
}

fn writeOpenUnitLocked(ou: *OpenState, file: ?[*]const u8, file_len: c_int, access: c_int, form: c_int, blank: c_int) void {
    ou.opened = 1;
    ou.access = access;
    ou.form = form;
    ou.blank = blank;
    if (file != null and file_len > 0) {
        col6forge_trim_filename(file, file_len, @ptrCast(&ou.filename), ou.filename.len);
    } else {
        ou.filename[0] = 0;
    }
}

fn removeOpenFilenameIndexForUnitLocked(unit: c_int) void {
    if (open_unit_filename_keys.fetchRemove(unit)) |kv| {
        _ = open_filename_index.remove(kv.value);
        runtimeAllocator().free(kv.value);
    }
}

fn indexOpenFilenameForUnitLocked(unit: c_int, filename: [*:0]const u8) void {
    const name = cstrSlice(filename);
    if (name.len == 0) return;

    if (open_filename_index.get(name)) |owner_unit| {
        if (owner_unit != unit) {
            removeOpenFilenameIndexForUnitLocked(owner_unit);
        } else {
            return;
        }
    }

    const allocator = runtimeAllocator();
    const key = allocator.dupe(u8, name) catch return;
    errdefer allocator.free(key);

    if (open_filename_index.fetchPut(allocator, key, unit) catch return) |old| {
        allocator.free(old.key);
    }
    if (open_unit_filename_keys.fetchPut(allocator, unit, key) catch {
        _ = open_filename_index.remove(key);
        return;
    }) |old_unit_key| {
        _ = open_filename_index.remove(old_unit_key.value);
        allocator.free(old_unit_key.value);
    }
}

fn openUnitFilenameMatchesLocked(unit: c_int, wanted_name: []const u8) bool {
    const ou = findOpenUnitLocked(unit) orelse return false;
    return ou.opened != 0 and ou.filename[0] != 0 and std.mem.eql(u8, cstrSlice(asConstCStr(&ou.filename)), wanted_name);
}

pub const OpenMeta = extern struct {
    opened: c_int,
    access: c_int,
    form: c_int,
    blank: c_int,
};

pub fn openCopyFilename(unit: c_int, out: ?[*]u8, len: usize) c_int {
    if (out == null or len == 0) return 0;
    manager_mutex.lock();
    defer manager_mutex.unlock();

    const ou = findOpenUnitLocked(unit) orelse return 0;
    if (ou.opened == 0 or ou.filename[0] == 0) return 0;
    var i: usize = 0;
    while (i + 1 < len and ou.filename[i] != 0) : (i += 1) out.?[i] = ou.filename[i];
    out.?[i] = 0;
    return 1;
}

pub fn openIsOpen(unit: c_int) c_int {
    manager_mutex.lock();
    defer manager_mutex.unlock();
    const ou = findOpenUnitLocked(unit) orelse return 0;
    return if (ou.opened != 0) 1 else 0;
}

pub fn openBlankCode(unit: c_int) c_int {
    manager_mutex.lock();
    defer manager_mutex.unlock();
    const ou = findOpenUnitLocked(unit) orelse return 0;
    return if (ou.opened != 0) ou.blank else 0;
}

pub fn openGetMeta(unit: c_int, out: ?*OpenMeta) c_int {
    if (out == null) return 0;
    const meta = out.?;
    meta.* = .{ .opened = 0, .access = 0, .form = 0, .blank = 0 };

    manager_mutex.lock();
    defer manager_mutex.unlock();

    const ou = findOpenUnitLocked(unit) orelse return 0;
    meta.* = .{
        .opened = ou.opened,
        .access = ou.access,
        .form = ou.form,
        .blank = ou.blank,
    };
    return 1;
}

pub fn openSet(unit: c_int, file: ?[*]const u8, file_len: c_int, access: c_int, form: c_int, blank: c_int) void {
    manager_mutex.lock();
    defer manager_mutex.unlock();

    removeOpenFilenameIndexForUnitLocked(unit);
    const ou = ensureOpenUnitLocked(unit) orelse return;
    writeOpenUnitLocked(ou, file, file_len, access, form, blank);
    if (ou.opened != 0 and ou.filename[0] != 0) {
        indexOpenFilenameForUnitLocked(unit, asConstCStr(&ou.filename));
    }
}

pub fn openClear(unit: c_int) void {
    manager_mutex.lock();
    defer manager_mutex.unlock();

    removeOpenFilenameIndexForUnitLocked(unit);
    const ou = findOpenUnitLocked(unit) orelse return;
    ou.opened = 0;
    ou.filename[0] = 0;
    ou.access = 0;
    ou.form = 0;
    ou.blank = 0;
}

pub fn openFindUnitByFilename(file: ?[*]const u8, file_len: c_int, out_unit: ?*c_int) c_int {
    if (out_unit == null) return 0;
    out_unit.?.* = -1;

    var name: [COL6FORGE_FILENAME_MAX]u8 = [_]u8{0} ** COL6FORGE_FILENAME_MAX;
    col6forge_trim_filename(file, file_len, &name, name.len);
    if (name[0] == 0) return 0;
    const wanted_name = cstrSlice(asConstCStr(&name));

    manager_mutex.lock();
    defer manager_mutex.unlock();

    var found_unit: c_int = -1;
    if (open_filename_index.get(wanted_name)) |indexed_unit| {
        if (openUnitFilenameMatchesLocked(indexed_unit, wanted_name)) {
            found_unit = indexed_unit;
        } else {
            _ = open_filename_index.remove(wanted_name);
            removeOpenFilenameIndexForUnitLocked(indexed_unit);
        }
    }

    if (found_unit < 0) {
        var i: usize = 0;
        while (i < COL6FORGE_MAX_UNITS) : (i += 1) {
            const unit: c_int = @intCast(i);
            if (openUnitFilenameMatchesLocked(unit, wanted_name)) {
                found_unit = unit;
                break;
            }
        }
    }
    if (found_unit < 0) {
        var it = extra_open_units.iterator();
        while (it.next()) |kv| {
            if (openUnitFilenameMatchesLocked(kv.key_ptr.*, wanted_name)) {
                found_unit = kv.key_ptr.*;
                break;
            }
        }
    }

    if (found_unit >= 0 and open_filename_index.get(wanted_name) == null) {
        if (findOpenUnitLocked(found_unit)) |ou| {
            indexOpenFilenameForUnitLocked(found_unit, asConstCStr(&ou.filename));
        }
    }

    out_unit.?.* = found_unit;
    return if (found_unit >= 0) 1 else 0;
}

pub fn posGet(unit: c_int, out: ?*c_long) c_int {
    if (out == null) return 0;
    const out_ptr = out.?;

    manager_mutex.lock();
    defer manager_mutex.unlock();

    if (isFixedUnit(unit)) {
        out_ptr.* = unit_pos[@as(usize, @intCast(unit))];
        return 1;
    }
    if (extra_unit_pos.get(unit)) |pos| {
        out_ptr.* = pos;
        return 1;
    }

    out_ptr.* = 0;
    return 0;
}

pub fn posSet(unit: c_int, pos: c_long) void {
    manager_mutex.lock();
    defer manager_mutex.unlock();

    if (isFixedUnit(unit)) {
        unit_pos[@as(usize, @intCast(unit))] = pos;
        return;
    }

    const allocator = runtimeAllocator();
    extra_unit_pos.put(allocator, unit, pos) catch {};
}

pub fn posClear(unit: c_int) void {
    posSet(unit, 0);
}

fn findEntry(unit: c_int) ?*StreamEntry {
    if (isFixedUnit(unit)) return &fixed_entries[@as(usize, @intCast(unit))];
    manager_mutex.lock();
    defer manager_mutex.unlock();
    return extra_entries.get(unit);
}

fn ensureEntry(unit: c_int) ?*StreamEntry {
    if (isFixedUnit(unit)) return &fixed_entries[@as(usize, @intCast(unit))];

    manager_mutex.lock();
    defer manager_mutex.unlock();

    if (extra_entries.get(unit)) |entry| return entry;

    const allocator = runtimeAllocator();
    const entry = allocator.create(StreamEntry) catch return null;
    entry.* = .{};
    extra_entries.put(allocator, unit, entry) catch {
        allocator.destroy(entry);
        return null;
    };
    return entry;
}

fn closeEntryStream(entry: *StreamEntry) void {
    if (entry.stream) |stream| {
        const pos = ftell(stream);
        if (pos >= 0) {
            entry.cursor = pos;
            entry.has_cursor = true;
        }
        _ = fclose(stream);
    }
    entry.stream = null;
    entry.mode = .none;
}

fn reopenEntryStream(entry: *StreamEntry, unit: c_int, mode: [*:0]const u8, mode_kind: StreamMode) bool {
    var name: [COL6FORGE_FILENAME_MAX]u8 = [_]u8{0} ** COL6FORGE_FILENAME_MAX;
    unit_filename(unit, &name, name.len);

    closeEntryStream(entry);
    entry.stream = fopen(asConstCStr(&name), mode) orelse return false;
    entry.mode = mode_kind;
    return true;
}

fn ensureReadable(entry: *StreamEntry, unit: c_int) bool {
    if (entry.stream != null) return true;
    return reopenEntryStream(entry, unit, "rb", .read_only);
}

fn ensureWritable(entry: *StreamEntry, unit: c_int, start_pos: c_long) bool {
    const start_at_zero = start_pos == 0;

    if (entry.stream == null) {
        return reopenEntryStream(entry, unit, if (start_at_zero) "wb+" else "rb+", .read_write);
    }
    if (start_at_zero) {
        return reopenEntryStream(entry, unit, "wb+", .read_write);
    }
    if (entry.mode == .read_only) {
        return reopenEntryStream(entry, unit, "rb+", .read_write);
    }
    return true;
}

pub fn acquire(unit: c_int, out_stream: ?*?*anyopaque, out_start_pos: ?*c_long, want_write: bool) c_int {
    if (out_stream == null) return 0;
    const entry = ensureEntry(unit) orelse return 0;

    entry.lock.lock();
    var unlock_on_return = true;
    defer if (unlock_on_return) {
        entry.held = false;
        entry.lock.unlock();
    };

    entry.held = true;

    var start_pos: c_long = 0;
    if (entry.has_cursor) {
        start_pos = entry.cursor;
    } else {
        _ = posGet(unit, &start_pos);
    }

    const ready = if (want_write) ensureWritable(entry, unit, start_pos) else ensureReadable(entry, unit);
    if (!ready) return 0;

    const stream = entry.stream.?;
    if (fseek(stream, start_pos, 0) != 0) {
        closeEntryStream(entry);
        return 0;
    }

    entry.cursor = start_pos;
    entry.has_cursor = true;
    out_stream.?.* = @ptrCast(stream);
    if (out_start_pos) |start_ptr| start_ptr.* = start_pos;

    unlock_on_return = false;
    return 1;
}

pub fn release(unit: c_int, stream: ?*anyopaque, start_pos: c_long, commit_pos: c_int) void {
    _ = stream;
    const entry = findEntry(unit) orelse return;
    if (!entry.held) return;

    if (entry.stream) |s| {
        if (commit_pos != 0) {
            const pos = ftell(s);
            const final_pos = if (pos >= 0) pos else start_pos;
            entry.cursor = final_pos;
            entry.has_cursor = true;
            posSet(unit, final_pos);
        } else {
            _ = fseek(s, start_pos, 0);
            entry.cursor = start_pos;
            entry.has_cursor = true;
            posSet(unit, start_pos);
        }
    } else if (commit_pos == 0) {
        entry.cursor = start_pos;
        entry.has_cursor = true;
        posSet(unit, start_pos);
    } else if (entry.has_cursor) {
        posSet(unit, entry.cursor);
    } else {
        posSet(unit, start_pos);
    }

    entry.held = false;
    entry.lock.unlock();
}

pub fn setPos(unit: c_int, pos: c_long) c_int {
    const entry = ensureEntry(unit) orelse return 0;
    entry.lock.lock();
    defer entry.lock.unlock();

    if (entry.stream) |stream| {
        if (fseek(stream, pos, 0) != 0) return 0;
    }

    entry.cursor = pos;
    entry.has_cursor = true;
    posSet(unit, pos);
    return 1;
}

pub fn getPos(unit: c_int, out: ?*c_long) c_int {
    if (out == null) return 0;
    const out_ptr = out.?;

    if (findEntry(unit)) |entry| {
        entry.lock.lock();
        defer entry.lock.unlock();

        if (entry.stream) |stream| {
            const pos = ftell(stream);
            if (pos >= 0) {
                entry.cursor = pos;
                entry.has_cursor = true;
                out_ptr.* = pos;
                return 1;
            }
        }

        if (entry.has_cursor) {
            out_ptr.* = entry.cursor;
            return 1;
        }
    }

    return posGet(unit, out);
}

pub fn invalidate(unit: c_int) void {
    if (unit < 0) {
        var idx: usize = 0;
        while (idx < fixed_entries.len) : (idx += 1) {
            const entry = &fixed_entries[idx];
            entry.lock.lock();
            closeEntryStream(entry);
            entry.lock.unlock();
        }

        manager_mutex.lock();
        defer manager_mutex.unlock();
        var it = extra_entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            entry.lock.lock();
            closeEntryStream(entry);
            entry.lock.unlock();
        }
        return;
    }

    const entry = findEntry(unit) orelse return;
    entry.lock.lock();
    closeEntryStream(entry);
    entry.lock.unlock();
}
