const std = @import("std");
const zig_compat = @import("zig_compat.zig");
const COL6FORGE_MAX_UNITS = 256;
const COL6FORGE_FILENAME_MAX = 4096;
const COL6FORGE_UNFORMATTED_MAX_RECORDS: usize = std.math.maxInt(usize);
const COL6FORGE_UNFORMATTED_MAX_RECORD_BYTES: usize = std.math.maxInt(usize);
const COL6FORGE_UNFORMATTED_MAX_TOTAL_BYTES: usize = std.math.maxInt(usize);
const COL6FORGE_STORE_LOCK_STRIPES: usize = 256;

extern fn free(ptr: ?*anyopaque) void;
extern fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn fclose(stream: *FILE) c_int;
extern fn fread(ptr: ?*anyopaque, size: usize, nitems: usize, stream: *FILE) usize;
extern fn fwrite(ptr: ?*const anyopaque, size: usize, nitems: usize, stream: *FILE) usize;
extern fn fseek(stream: *FILE, offset: c_long, origin: c_int) c_int;
extern fn ftell(stream: *FILE) c_long;
extern fn fflush(stream: *FILE) c_int;

const FILE = opaque {};

const DirectUnit = extern struct {
    recl: c_int,
    nextrec: c_int,
    data: ?[*]u8,
    size: usize,
};

const UnformattedRecord = extern struct {
    data: ?[*]u8,
    len: usize,
    is_endfile: u8,
};

const UnformattedUnit = extern struct {
    records: ?[*]UnformattedRecord,
    count: usize,
    capacity: usize,
    pos: usize,
    used: u8,
};

extern var direct_units: [COL6FORGE_MAX_UNITS]DirectUnit;
extern var unformatted_units: [COL6FORGE_MAX_UNITS]UnformattedUnit;
extern fn unit_filename(unit: c_int, buf: ?[*]u8, len: usize) void;

var store_unit_locks: [COL6FORGE_STORE_LOCK_STRIPES]zig_compat.Mutex = [_]zig_compat.Mutex{.{}} ** COL6FORGE_STORE_LOCK_STRIPES;

var extra_direct_units: [COL6FORGE_STORE_LOCK_STRIPES]std.AutoHashMapUnmanaged(c_int, *DirectUnit) =
    [_]std.AutoHashMapUnmanaged(c_int, *DirectUnit){.{}} ** COL6FORGE_STORE_LOCK_STRIPES;
var extra_unformatted_units: [COL6FORGE_STORE_LOCK_STRIPES]std.AutoHashMapUnmanaged(c_int, *UnformattedUnit) =
    [_]std.AutoHashMapUnmanaged(c_int, *UnformattedUnit){.{}} ** COL6FORGE_STORE_LOCK_STRIPES;

const UNFORMATTED_FILE_MAGIC = "C6UF1";
const UNFORMATTED_ENTRY_RECORD: u8 = 0;
const UNFORMATTED_ENTRY_ENDFILE: u8 = 1;

fn zeroDirectUnit() DirectUnit {
    return .{
        .recl = 0,
        .nextrec = 0,
        .data = null,
        .size = 0,
    };
}

fn zeroUnformattedUnit() UnformattedUnit {
    return .{
        .records = null,
        .count = 0,
        .capacity = 0,
        .pos = 0,
        .used = 0,
    };
}

fn isArrayUnit(unit: c_int) bool {
    return unit >= 0 and unit < COL6FORGE_MAX_UNITS;
}

fn unitLockIndex(unit: c_int) usize {
    const bits: u32 = @bitCast(unit);
    return @intCast(bits % COL6FORGE_STORE_LOCK_STRIPES);
}

fn unitLock(unit: c_int) *zig_compat.Mutex {
    return &store_unit_locks[unitLockIndex(unit)];
}

fn runtimeAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

fn ensureExtraDirectUnitLocked(unit: c_int) ?*DirectUnit {
    const stripe = unitLockIndex(unit);
    const map = &extra_direct_units[stripe];
    if (map.get(unit)) |state| return state;

    const state_raw = realloc(null, @sizeOf(DirectUnit)) orelse return null;
    const state_aligned: *align(@alignOf(DirectUnit)) anyopaque = @alignCast(state_raw);
    const state_ptr: *DirectUnit = @ptrCast(state_aligned);
    state_ptr.* = zeroDirectUnit();
    map.put(runtimeAllocator(), unit, state_ptr) catch {
        free(state_raw);
        return null;
    };
    return state_ptr;
}

fn ensureExtraUnformattedUnitLocked(unit: c_int) ?*UnformattedUnit {
    const stripe = unitLockIndex(unit);
    const map = &extra_unformatted_units[stripe];
    if (map.get(unit)) |state| return state;

    const state_raw = realloc(null, @sizeOf(UnformattedUnit)) orelse return null;
    const state_aligned: *align(@alignOf(UnformattedUnit)) anyopaque = @alignCast(state_raw);
    const state_ptr: *UnformattedUnit = @ptrCast(state_aligned);
    state_ptr.* = zeroUnformattedUnit();
    map.put(runtimeAllocator(), unit, state_ptr) catch {
        free(state_raw);
        return null;
    };
    return state_ptr;
}

fn removeExtraDirectUnitLocked(unit: c_int) void {
    const stripe = unitLockIndex(unit);
    if (extra_direct_units[stripe].fetchRemove(unit)) |removed| {
        free(@ptrCast(removed.value));
    }
}

fn removeExtraUnformattedUnitLocked(unit: c_int) void {
    const stripe = unitLockIndex(unit);
    if (extra_unformatted_units[stripe].fetchRemove(unit)) |removed| {
        free(@ptrCast(removed.value));
    }
}

fn getDirectUnitLocked(unit: c_int, create_if_missing: bool) ?*DirectUnit {
    if (isArrayUnit(unit)) {
        const idx: usize = @intCast(unit);
        return &direct_units[idx];
    }
    if (create_if_missing) return ensureExtraDirectUnitLocked(unit);
    return extra_direct_units[unitLockIndex(unit)].get(unit);
}

fn getUnformattedUnitLocked(unit: c_int, create_if_missing: bool) ?*UnformattedUnit {
    if (isArrayUnit(unit)) {
        const idx: usize = @intCast(unit);
        return &unformatted_units[idx];
    }
    if (create_if_missing) return ensureExtraUnformattedUnitLocked(unit);
    return extra_unformatted_units[unitLockIndex(unit)].get(unit);
}

fn getDirectUnit(unit: c_int, create_if_missing: bool) ?*DirectUnit {
    if (isArrayUnit(unit)) {
        const idx: usize = @intCast(unit);
        return &direct_units[idx];
    }
    // Non-array unit metadata is striped by unitLockIndex(unit) and must be
    // accessed while holding that stripe's unit lock.
    return getDirectUnitLocked(unit, create_if_missing);
}

fn getUnformattedUnit(unit: c_int, create_if_missing: bool) ?*UnformattedUnit {
    if (isArrayUnit(unit)) {
        const idx: usize = @intCast(unit);
        return &unformatted_units[idx];
    }
    // Non-array unit metadata is striped by unitLockIndex(unit) and must be
    // accessed while holding that stripe's unit lock.
    return getUnformattedUnitLocked(unit, create_if_missing);
}

fn unitFilePath(unit: c_int, out: *[COL6FORGE_FILENAME_MAX]u8) [*:0]const u8 {
    out.* = [_]u8{0} ** out.len;
    unit_filename(unit, out, out.len);
    return @ptrCast(out);
}

fn freeDirectStorage(du: *DirectUnit) void {
    if (du.data) |data| free(@ptrCast(data));
    du.data = null;
    du.size = 0;
    du.nextrec = 0;
}

fn freeUnformattedStorage(uu: *UnformattedUnit) void {
    if (uu.records) |records| {
        var i: usize = 0;
        while (i < uu.count) : (i += 1) {
            if (records[i].data) |data| free(@ptrCast(data));
        }
        free(@ptrCast(records));
    }
    uu.records = null;
    uu.count = 0;
    uu.capacity = 0;
    uu.pos = 0;
    uu.used = 0;
}

fn writeExact(stream: *FILE, src: [*]const u8, n: usize) bool {
    if (n == 0) return true;
    return fwrite(@ptrCast(src), 1, n, stream) == n;
}

fn readExact(stream: *FILE, dst: [*]u8, n: usize) bool {
    if (n == 0) return true;
    return fread(@ptrCast(dst), 1, n, stream) == n;
}

fn writeU64LE(stream: *FILE, value: u64) bool {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    return writeExact(stream, &buf, buf.len);
}

fn readU64LE(stream: *FILE, out: *u64) bool {
    var buf: [8]u8 = undefined;
    if (!readExact(stream, &buf, buf.len)) return false;
    out.* = std.mem.readInt(u64, &buf, .little);
    return true;
}

fn loadDirectFromFile(unit: c_int, du: *DirectUnit) void {
    if (du.data != null) return;
    var path: [COL6FORGE_FILENAME_MAX]u8 = undefined;
    const file = fopen(unitFilePath(unit, &path), "rb") orelse return;
    defer _ = fclose(file);
    if (fseek(file, 0, 2) != 0) return;
    const size_pos = ftell(file);
    if (size_pos <= 0) return;
    if (fseek(file, 0, 0) != 0) return;

    const size: usize = @intCast(size_pos);
    const raw = realloc(null, size) orelse return;
    const data: [*]u8 = @ptrCast(raw);
    if (!readExact(file, data, size)) {
        free(raw);
        return;
    }
    du.data = data;
    du.size = size;
    if (du.recl > 0) {
        const recl: usize = @intCast(du.recl);
        const recs = size / recl;
        du.nextrec = @intCast(recs + 1);
    } else {
        du.nextrec = 1;
    }
}

fn flushDirectToFile(unit: c_int, du: *DirectUnit) void {
    if (du.data == null) return;
    var path: [COL6FORGE_FILENAME_MAX]u8 = undefined;
    const file = fopen(unitFilePath(unit, &path), "wb") orelse return;
    defer _ = fclose(file);
    _ = writeExact(file, du.data.?, du.size);
    _ = fflush(file);
}

fn loadUnformattedFromFile(unit: c_int, uu: *UnformattedUnit) void {
    if (uu.count != 0 or uu.records != null) return;

    var path: [COL6FORGE_FILENAME_MAX]u8 = undefined;
    const file = fopen(unitFilePath(unit, &path), "rb") orelse return;
    defer _ = fclose(file);

    var magic: [UNFORMATTED_FILE_MAGIC.len]u8 = undefined;
    if (!readExact(file, &magic, magic.len)) return;
    if (!std.mem.eql(u8, magic[0..], UNFORMATTED_FILE_MAGIC)) return;

    while (true) {
        var tag: [1]u8 = .{0};
        const got = fread(&tag, 1, 1, file);
        if (got == 0) break;
        if (tag[0] == UNFORMATTED_ENTRY_RECORD) {
            var len_u64: u64 = 0;
            if (!readU64LE(file, &len_u64)) {
                freeUnformattedStorage(uu);
                return;
            }
            const len: usize = @intCast(len_u64);
            if (!unformattedEnsureCapacityLocal(uu, uu.count + 1)) {
                freeUnformattedStorage(uu);
                return;
            }
            if (uu.records == null) {
                freeUnformattedStorage(uu);
                return;
            }
            var data: ?[*]u8 = null;
            if (len > 0) {
                const raw = realloc(null, len) orelse {
                    freeUnformattedStorage(uu);
                    return;
                };
                data = @ptrCast(raw);
                if (!readExact(file, data.?, len)) {
                    free(raw);
                    freeUnformattedStorage(uu);
                    return;
                }
            }
            const rec = &uu.records.?[uu.count];
            rec.data = data;
            rec.len = len;
            rec.is_endfile = 0;
            uu.count += 1;
        } else if (tag[0] == UNFORMATTED_ENTRY_ENDFILE) {
            if (!unformattedEnsureCapacityLocal(uu, uu.count + 1)) {
                freeUnformattedStorage(uu);
                return;
            }
            if (uu.records == null) {
                freeUnformattedStorage(uu);
                return;
            }
            const rec = &uu.records.?[uu.count];
            rec.data = null;
            rec.len = 0;
            rec.is_endfile = 1;
            uu.count += 1;
        } else {
            freeUnformattedStorage(uu);
            return;
        }
    }
    uu.pos = 0;
    uu.used = if (uu.count > 0) 1 else 0;
}

fn flushUnformattedToFile(unit: c_int, uu: *UnformattedUnit) void {
    if (uu.count == 0 or uu.records == null) return;

    var path: [COL6FORGE_FILENAME_MAX]u8 = undefined;
    const file = fopen(unitFilePath(unit, &path), "wb") orelse return;
    defer _ = fclose(file);

    if (!writeExact(file, UNFORMATTED_FILE_MAGIC.ptr, UNFORMATTED_FILE_MAGIC.len)) return;
    const records = uu.records.?;
    var i: usize = 0;
    while (i < uu.count) : (i += 1) {
        const rec = records[i];
        if (rec.is_endfile != 0) {
            var tag: [1]u8 = .{UNFORMATTED_ENTRY_ENDFILE};
            if (!writeExact(file, &tag, 1)) return;
            continue;
        }
        var tag: [1]u8 = .{UNFORMATTED_ENTRY_RECORD};
        if (!writeExact(file, &tag, 1)) return;
        if (!writeU64LE(file, @intCast(rec.len))) return;
        if (rec.len > 0 and rec.data != null) {
            if (!writeExact(file, rec.data.?, rec.len)) return;
        }
    }
    _ = fflush(file);
}

const RecordRange = struct {
    offset: usize,
    end: usize,
};

fn directRecordRange(rec: c_int, recl_size: usize) ?RecordRange {
    if (rec <= 0) return null;
    const rec_index: usize = @intCast(rec - 1);
    const offset_res = @mulWithOverflow(rec_index, recl_size);
    if (offset_res[1] != 0) return null;
    const end_res = @addWithOverflow(offset_res[0], recl_size);
    if (end_res[1] != 0) return null;
    return .{ .offset = offset_res[0], .end = end_res[0] };
}

fn unformattedTruncateLocal(unit: ?*UnformattedUnit, new_count: usize) void {
    if (unit == null) return;
    const u = unit.?;
    if (new_count >= u.count) {
        u.count = new_count;
        return;
    }
    if (u.records) |records| {
        var i = new_count;
        while (i < u.count) : (i += 1) {
            if (records[i].data) |data| {
                free(@ptrCast(data));
            }
            records[i].data = null;
            records[i].len = 0;
            records[i].is_endfile = 0;
        }
    }
    u.count = new_count;
    if (u.pos > u.count) u.pos = u.count;
}

pub export fn direct_signature_size(sig: [*:0]const u8) callconv(.c) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (sig[i] != 0) : (i += 1) {
        switch (sig[i]) {
            'i', 'r' => total += 4,
            'd' => total += 8,
            'l' => total += 1,
            'c' => {
                var len: usize = 0;
                i += 1;
                while (sig[i] != 0 and sig[i] != ';') : (i += 1) {
                    if (sig[i] >= '0' and sig[i] <= '9') {
                        len = (len * 10) + @as(usize, sig[i] - '0');
                    }
                }
                total += len;
            },
            else => {},
        }
    }
    return total;
}

fn unformattedEnsureCapacityLocal(unit: *UnformattedUnit, needed: usize) bool {
    if (needed > COL6FORGE_UNFORMATTED_MAX_RECORDS) return false;
    if (unit.capacity >= needed) return true;

    var new_cap: usize = if (unit.capacity == 0) 8 else unit.capacity;
    while (new_cap < needed) {
        if (new_cap >= COL6FORGE_UNFORMATTED_MAX_RECORDS) {
            new_cap = COL6FORGE_UNFORMATTED_MAX_RECORDS;
            break;
        }
        const doubled = @mulWithOverflow(new_cap, @as(usize, 2));
        if (doubled[1] != 0) {
            new_cap = COL6FORGE_UNFORMATTED_MAX_RECORDS;
            break;
        }
        new_cap = @min(doubled[0], COL6FORGE_UNFORMATTED_MAX_RECORDS);
    }
    if (new_cap < needed) return false;

    const bytes_mul = @mulWithOverflow(new_cap, @as(usize, @sizeOf(UnformattedRecord)));
    if (bytes_mul[1] != 0) return false;
    const prev: ?*anyopaque = if (unit.records) |records| @ptrCast(records) else null;
    const new_records_raw = realloc(prev, bytes_mul[0]) orelse return false;
    const aligned: *align(@alignOf(UnformattedRecord)) anyopaque = @alignCast(new_records_raw);
    const new_records: [*]UnformattedRecord = @ptrCast(aligned);
    var i = unit.capacity;
    while (i < new_cap) : (i += 1) {
        new_records[i].data = null;
        new_records[i].len = 0;
        new_records[i].is_endfile = 0;
    }
    unit.records = new_records;
    unit.capacity = new_cap;
    return true;
}

fn directEnsureCapacity(du: *DirectUnit, needed: usize) void {
    if (du.size >= needed) return;

    const prev: ?*anyopaque = if (du.data) |data| @ptrCast(data) else null;
    const new_data_raw = realloc(prev, needed);
    if (new_data_raw == null) return;
    const new_data: [*]u8 = @ptrCast(new_data_raw.?);
    if (needed > du.size) {
        var i = du.size;
        while (i < needed) : (i += 1) {
            new_data[i] = 0;
        }
    }
    du.data = new_data;
    du.size = needed;
}

fn unformattedTotalBytes(unit: *const UnformattedUnit) usize {
    if (unit.records == null or unit.count == 0) return 0;
    const records = unit.records.?;
    var total: usize = 0;
    var i: usize = 0;
    while (i < unit.count) : (i += 1) {
        const added = @addWithOverflow(total, records[i].len);
        if (added[1] != 0) return std.math.maxInt(usize);
        total = added[0];
    }
    return total;
}

pub export fn col6forge_open_direct(unit: c_int, recl: c_int) callconv(.c) void {
    if (recl <= 0) return;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const du = getDirectUnit(unit, true) orelse return;
    du.recl = recl;
    du.nextrec = 1;
}

fn resolvedDirectRecl(du: *DirectUnit, requested_recl: c_int) ?c_int {
    if (du.recl <= 0) return null;
    if (requested_recl > 0 and requested_recl != du.recl) return null;
    return du.recl;
}

pub export fn col6forge_direct_record_ptr(unit: c_int, rec: c_int, recl: c_int) callconv(.c) ?[*]u8 {
    if (rec <= 0) return null;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const du = getDirectUnit(unit, false) orelse return null;
    const recl_local = resolvedDirectRecl(du, recl) orelse return null;
    loadDirectFromFile(unit, du);

    const recl_size: usize = @intCast(recl_local);
    const range = directRecordRange(rec, recl_size) orelse return null;
    directEnsureCapacity(du, range.end);
    if (du.data == null or du.size < range.end) return null;

    const record = du.data.? + range.offset;
    var i: usize = 0;
    while (i < recl_size) : (i += 1) {
        record[i] = ' ';
    }
    return record;
}

pub export fn col6forge_direct_record_ptr_ro(unit: c_int, rec: c_int, recl: c_int) callconv(.c) ?[*]u8 {
    if (rec <= 0) return null;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const du = getDirectUnit(unit, false) orelse return null;
    const recl_local = resolvedDirectRecl(du, recl) orelse return null;
    loadDirectFromFile(unit, du);
    if (du.data == null) return null;

    const recl_size: usize = @intCast(recl_local);
    const range = directRecordRange(rec, recl_size) orelse return null;
    if (du.size < range.end) return null;
    return du.data.? + range.offset;
}

fn directLastRecord(rec: c_int, count: c_int) ?c_int {
    if (rec <= 0 or count <= 0) return null;
    const count_minus_one = @subWithOverflow(count, 1);
    if (count_minus_one[1] != 0) return null;
    const last = @addWithOverflow(rec, count_minus_one[0]);
    if (last[1] != 0) return null;
    return last[0];
}

pub export fn col6forge_direct_record_span_ptr(unit: c_int, rec: c_int, recl: c_int, count: c_int) callconv(.c) ?[*]u8 {
    const last_rec = directLastRecord(rec, count) orelse return null;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const du = getDirectUnit(unit, false) orelse return null;
    const recl_local = resolvedDirectRecl(du, recl) orelse return null;
    loadDirectFromFile(unit, du);

    const recl_size: usize = @intCast(recl_local);
    const first = directRecordRange(rec, recl_size) orelse return null;
    const last = directRecordRange(last_rec, recl_size) orelse return null;
    if (last.end < first.offset) return null;

    directEnsureCapacity(du, last.end);
    if (du.data == null or du.size < last.end) return null;

    const begin_ptr = du.data.? + first.offset;
    const span_len = last.end - first.offset;
    var i: usize = 0;
    while (i < span_len) : (i += 1) {
        begin_ptr[i] = ' ';
    }
    return begin_ptr;
}

pub export fn col6forge_direct_record_span_ptr_ro(unit: c_int, rec: c_int, recl: c_int, count: c_int) callconv(.c) ?[*]u8 {
    const last_rec = directLastRecord(rec, count) orelse return null;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const du = getDirectUnit(unit, false) orelse return null;
    const recl_local = resolvedDirectRecl(du, recl) orelse return null;
    loadDirectFromFile(unit, du);
    if (du.data == null) return null;

    const recl_size: usize = @intCast(recl_local);
    const first = directRecordRange(rec, recl_size) orelse return null;
    const last = directRecordRange(last_rec, recl_size) orelse return null;
    if (last.end < first.offset) return null;
    if (du.size < last.end) return null;
    return du.data.? + first.offset;
}

pub export fn col6forge_direct_record_commit(unit: c_int, rec: c_int) callconv(.c) void {
    if (rec <= 0) return;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const du = getDirectUnit(unit, false) orelse return;
    du.nextrec = rec + 1;
}

pub export fn col6forge_inquire_direct(unit: c_int, recl: ?*c_int, nextrec: ?*c_int) callconv(.c) void {
    if (recl == null or nextrec == null) return;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const recl_ptr = recl.?;
    const nextrec_ptr = nextrec.?;
    const du = getDirectUnit(unit, false) orelse {
        recl_ptr.* = 0;
        nextrec_ptr.* = 1;
        return;
    };
    loadDirectFromFile(unit, du);
    const r = du.recl;
    recl_ptr.* = r;
    if (du.nextrec > 0) {
        nextrec_ptr.* = du.nextrec;
        return;
    }
    if (r > 0) {
        const records = du.size / @as(usize, @intCast(r));
        nextrec_ptr.* = @intCast(records + 1);
        du.nextrec = nextrec_ptr.*;
        return;
    }
    nextrec_ptr.* = 1;
    du.nextrec = 1;
}

pub export fn col6forge_direct_get_recl(unit: c_int) callconv(.c) c_int {
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const du = getDirectUnit(unit, false) orelse return 0;
    loadDirectFromFile(unit, du);
    return du.recl;
}

fn unformattedBeginWriteSizedLocked(unit: c_int, record_size: usize, out_record: ?*?[*]u8, out_len: ?*usize) c_int {
    const uu = getUnformattedUnit(unit, true) orelse return 0;
    uu.used = 1;

    if (record_size > COL6FORGE_UNFORMATTED_MAX_RECORD_BYTES) return 0;
    if (uu.pos >= uu.count and uu.count >= COL6FORGE_UNFORMATTED_MAX_RECORDS) return 0;

    const old_len: usize = if (uu.pos < uu.count and uu.records != null) uu.records.?[uu.pos].len else 0;
    const current_total = unformattedTotalBytes(uu);
    if (current_total == std.math.maxInt(usize)) return 0;
    if (current_total < old_len) return 0;
    const without_old = current_total - old_len;
    const projected = @addWithOverflow(without_old, record_size);
    if (projected[1] != 0 or projected[0] > COL6FORGE_UNFORMATTED_MAX_TOTAL_BYTES) return 0;

    if (uu.pos < uu.count) {
        if (uu.records == null) return 0;
        const records = uu.records.?;
        const old_data = records[uu.pos].data;
        const old_record_len = records[uu.pos].len;
        var record: ?[*]u8 = null;

        if (record_size == 0) {
            if (old_data) |data| free(@ptrCast(data));
        } else if (old_data) |data| {
            const resized_raw = realloc(@ptrCast(data), record_size) orelse return 0;
            record = @ptrCast(resized_raw);
            if (record_size > old_record_len) {
                var i: usize = old_record_len;
                while (i < record_size) : (i += 1) {
                    record.?[i] = 0;
                }
            }
        } else {
            const record_raw = realloc(null, record_size) orelse return 0;
            record = @ptrCast(record_raw);
            var i: usize = 0;
            while (i < record_size) : (i += 1) {
                record.?[i] = 0;
            }
        }

        records[uu.pos].data = record;
        records[uu.pos].len = record_size;
        records[uu.pos].is_endfile = 0;
        uu.pos += 1;
        unformattedTruncateLocal(uu, uu.pos);
        if (out_record) |p| p.* = records[uu.pos - 1].data;
        if (out_len) |p| p.* = record_size;
        return 1;
    }

    if (!unformattedEnsureCapacityLocal(uu, uu.count + 1)) return 0;
    if (uu.records == null) return 0;

    var record: ?[*]u8 = null;
    if (record_size > 0) {
        const record_raw = realloc(null, record_size) orelse return 0;
        record = @ptrCast(record_raw);
        var i: usize = 0;
        while (i < record_size) : (i += 1) {
            record.?[i] = 0;
        }
    }

    const records = uu.records.?;
    records[uu.count].data = record;
    records[uu.count].len = record_size;
    records[uu.count].is_endfile = 0;
    uu.count += 1;
    uu.pos = uu.count;
    if (out_record) |p| p.* = records[uu.count - 1].data;
    if (out_len) |p| p.* = record_size;
    return 1;
}

fn unformattedBeginReadSizedLocked(unit: c_int, record_size_hint: usize, out_record: ?*?[*]u8, out_len: ?*usize) c_int {
    _ = record_size_hint;
    const uu = getUnformattedUnit(unit, true) orelse return 1;
    loadUnformattedFromFile(unit, uu);
    uu.used = 1;

    if (uu.pos >= uu.count) return -1;
    if (uu.records == null) return -1;
    const records = uu.records.?;
    const rec = &records[uu.pos];
    if (rec.is_endfile != 0) {
        uu.pos += 1;
        return -1;
    }
    uu.pos += 1;
    if (out_record) |p| p.* = rec.data;
    if (out_len) |p| p.* = rec.len;
    return 0;
}

pub export fn col6forge_unformatted_begin_write(unit: c_int, sig: ?[*:0]const u8, out_record: ?*?[*]u8, out_len: ?*usize) callconv(.c) c_int {
    if (sig == null) return 0;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();
    return unformattedBeginWriteSizedLocked(unit, direct_signature_size(sig.?), out_record, out_len);
}

pub export fn col6forge_unformatted_begin_write_len(unit: c_int, record_size: usize, out_record: ?*?[*]u8, out_len: ?*usize) callconv(.c) c_int {
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();
    return unformattedBeginWriteSizedLocked(unit, record_size, out_record, out_len);
}

pub export fn col6forge_unformatted_begin_read(unit: c_int, sig: ?[*:0]const u8, out_record: ?*?[*]u8, out_len: ?*usize) callconv(.c) c_int {
    if (sig == null) return 1;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();
    return unformattedBeginReadSizedLocked(unit, direct_signature_size(sig.?), out_record, out_len);
}

pub export fn col6forge_unformatted_begin_read_len(unit: c_int, record_size_hint: usize, out_record: ?*?[*]u8, out_len: ?*usize) callconv(.c) c_int {
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();
    return unformattedBeginReadSizedLocked(unit, record_size_hint, out_record, out_len);
}

pub export fn col6forge_unformatted_rewind(unit: c_int) callconv(.c) c_int {
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const uu = getUnformattedUnit(unit, false) orelse return 0;
    if (uu.used != 0 and (uu.count > 0 or uu.pos > 0)) {
        uu.pos = 0;
        return 1;
    }
    return 0;
}

pub export fn col6forge_unformatted_backspace(unit: c_int) callconv(.c) c_int {
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const uu = getUnformattedUnit(unit, false) orelse return 0;
    if (uu.used != 0 and (uu.count > 0 or uu.pos > 0)) {
        if (uu.pos > 0) uu.pos -= 1;
        return 1;
    }
    return 0;
}

pub export fn col6forge_unformatted_endfile(unit: c_int) callconv(.c) c_int {
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const uu = getUnformattedUnit(unit, false) orelse return 0;
    if (uu.used == 0) return 0;

    if (uu.count > 0 or uu.pos > 0) {
        unformattedTruncateLocal(uu, uu.pos);
    }
    if (!unformattedEnsureCapacityLocal(uu, uu.pos + 1)) return 0;
    if (uu.records == null) return 0;
    const records = uu.records.?;
    if (uu.pos < uu.count) {
        if (records[uu.pos].data) |data| {
            free(@ptrCast(data));
        }
    }
    records[uu.pos].data = null;
    records[uu.pos].len = 0;
    records[uu.pos].is_endfile = 1;
    uu.count = uu.pos + 1;
    uu.pos = uu.count;
    return 1;
}

pub export fn col6forge_record_store_reset(unit: c_int) callconv(.c) void {
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();
    const array_unit = isArrayUnit(unit);

    if (getDirectUnit(unit, false)) |du| {
        freeDirectStorage(du);
        du.recl = 0;
    }
    if (getUnformattedUnit(unit, false)) |uu| {
        freeUnformattedStorage(uu);
    }
    if (!array_unit) {
        removeExtraDirectUnitLocked(unit);
        removeExtraUnformattedUnitLocked(unit);
    }
}

pub export fn col6forge_record_store_close(unit: c_int, status: c_int) callconv(.c) void {
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();
    const array_unit = isArrayUnit(unit);

    const du = getDirectUnit(unit, false);
    const uu = getUnformattedUnit(unit, false);

    if (status != 2) {
        if (uu) |u| {
            if (u.count > 0 or u.used != 0) {
                flushUnformattedToFile(unit, u);
            } else if (du) |d| {
                flushDirectToFile(unit, d);
            }
        } else if (du) |d| {
            flushDirectToFile(unit, d);
        }
    }

    if (du) |d| {
        freeDirectStorage(d);
        d.recl = 0;
    }
    if (uu) |u| {
        freeUnformattedStorage(u);
    }
    if (!array_unit) {
        removeExtraDirectUnitLocked(unit);
        removeExtraUnformattedUnitLocked(unit);
    }
}

test "directRecordRange validates record offsets safely" {
    try std.testing.expect(directRecordRange(0, 8) == null);

    const r1 = directRecordRange(1, 8).?;
    try std.testing.expectEqual(@as(usize, 0), r1.offset);
    try std.testing.expectEqual(@as(usize, 8), r1.end);

    const r2 = directRecordRange(3, 8).?;
    try std.testing.expectEqual(@as(usize, 16), r2.offset);
    try std.testing.expectEqual(@as(usize, 24), r2.end);

    try std.testing.expect(directRecordRange(2, std.math.maxInt(usize)) == null);
    try std.testing.expect(directRecordRange(std.math.maxInt(c_int), std.math.maxInt(usize)) == null);
}

test "direct record access requires explicit RECL and rejects mismatch" {
    const unit: c_int = 201;
    const lock = unitLock(unit);
    lock.lock();
    defer lock.unlock();

    const du = getDirectUnit(unit, true).?;
    if (du.data) |data| free(@ptrCast(data));
    du.data = null;
    du.size = 0;
    du.recl = 0;
    du.nextrec = 1;

    try std.testing.expect(col6forge_direct_record_ptr(unit, 1, 16) == null);
    try std.testing.expect(col6forge_direct_record_ptr_ro(unit, 1, 16) == null);

    col6forge_open_direct(unit, 16);
    try std.testing.expect(col6forge_direct_record_ptr(unit, 1, 16) != null);
    try std.testing.expect(col6forge_direct_record_ptr(unit, 2, 8) == null);
    try std.testing.expect(col6forge_direct_record_ptr_ro(unit, 1, 8) == null);
    try std.testing.expect(col6forge_direct_record_ptr_ro(unit, 1, 16) != null);
}

test "direct and unformatted storage support non-array unit numbers" {
    const direct_unit: c_int = -31;
    const unformatted_unit: c_int = 1000;

    col6forge_open_direct(direct_unit, 8);
    const dst_opt = col6forge_direct_record_ptr(direct_unit, 1, 8);
    try std.testing.expect(dst_opt != null);
    const dst = dst_opt.?;
    dst[0] = 0x12;
    dst[1] = 0x34;
    dst[2] = 0x56;
    dst[3] = 0x78;
    col6forge_direct_record_commit(direct_unit, 1);
    const src_opt = col6forge_direct_record_ptr_ro(direct_unit, 1, 8);
    try std.testing.expect(src_opt != null);
    const src = src_opt.?;
    try std.testing.expectEqual(@as(u8, 0x12), src[0]);
    try std.testing.expectEqual(@as(u8, 0x78), src[3]);

    var write_rec: ?[*]u8 = null;
    var write_len: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), col6forge_unformatted_begin_write_len(unformatted_unit, 4, &write_rec, &write_len));
    try std.testing.expect(write_rec != null);
    try std.testing.expectEqual(@as(usize, 4), write_len);
    write_rec.?[0] = 9;
    write_rec.?[1] = 8;
    write_rec.?[2] = 7;
    write_rec.?[3] = 6;

    try std.testing.expectEqual(@as(c_int, 1), col6forge_unformatted_rewind(unformatted_unit));
    var read_rec: ?[*]u8 = null;
    var read_len: usize = 0;
    try std.testing.expectEqual(@as(c_int, 0), col6forge_unformatted_begin_read_len(unformatted_unit, 4, &read_rec, &read_len));
    try std.testing.expect(read_rec != null);
    try std.testing.expectEqual(@as(usize, 4), read_len);
    try std.testing.expectEqual(@as(u8, 9), read_rec.?[0]);
    try std.testing.expectEqual(@as(u8, 6), read_rec.?[3]);
}

test "reset and close drop non-array unit state" {
    const unit: c_int = 1500;

    col6forge_open_direct(unit, 8);
    try std.testing.expectEqual(@as(c_int, 8), col6forge_direct_get_recl(unit));

    col6forge_record_store_reset(unit);
    try std.testing.expectEqual(@as(c_int, 0), col6forge_direct_get_recl(unit));

    col6forge_open_direct(unit, 8);
    const rec = col6forge_direct_record_ptr(unit, 1, 8);
    try std.testing.expect(rec != null);
    rec.?[0] = 42;
    col6forge_record_store_close(unit, 1);
    try std.testing.expectEqual(@as(c_int, 0), col6forge_direct_get_recl(unit));
}
