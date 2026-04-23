const common = @import("common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const fallback_policy = common.fallback_policy;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const zig_api = common.zig_api;

pub const TestCase = struct {
    input_path: []const u8,
    case_dir: []const u8,
    work_name: []const u8,
};

pub fn collectTestCases(
    allocator: std.mem.Allocator,
    tests_dir: []const u8,
    filter: ?[]const u8,
    dialect: Col6Forge.Dialect,
) ![]TestCase {
    var list: std.ArrayList(TestCase) = .empty;
    var dir = try zig_api.cwd().openDir(tests_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!isFortranSource(entry.path)) continue;
        if (filter) |needle| {
            if (!std.mem.containsAtLeast(u8, entry.path, 1, needle)) continue;
        }
        if (shouldSkipDefaultLegacyCase(entry.path, dialect)) continue;

        const input_path = try std.fs.path.join(allocator, &.{ tests_dir, entry.path });
        const case_dir = std.fs.path.dirname(input_path) orelse tests_dir;
        const work_name = try sanitizeWorkName(allocator, entry.path);

        try list.append(allocator, .{ .input_path = input_path, .case_dir = case_dir, .work_name = work_name });
    }

    std.sort.heap(TestCase, list.items, {}, testCaseLessThan);
    return list.toOwnedSlice(allocator);
}

fn shouldSkipDefaultLegacyCase(rel_path: []const u8, dialect: Col6Forge.Dialect) bool {
    if (dialect != .default) return false;
    const base = std.fs.path.basename(rel_path);
    return std.ascii.eqlIgnoreCase(base, "FM719.f") or
        std.ascii.eqlIgnoreCase(base, "FM719.FOR") or
        std.ascii.eqlIgnoreCase(rel_path, "fcvs21_f95/FM719.f") or
        std.ascii.eqlIgnoreCase(rel_path, "fcvs21_f95\\FM719.f") or
        std.ascii.eqlIgnoreCase(rel_path, "FCSV78/FM719.FOR") or
        std.ascii.eqlIgnoreCase(rel_path, "FCSV78\\FM719.FOR");
}

fn testCaseLessThan(_: void, a: TestCase, b: TestCase) bool {
    return std.mem.order(u8, a.input_path, b.input_path) == .lt;
}

fn isFortranSource(path: []const u8) bool {
    const exts = [_][]const u8{
        ".f",
        ".for",
        ".f77",
        ".f90",
        ".f95",
        ".f03",
        ".f08",
    };
    for (exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

pub fn sanitizeWorkName(allocator: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
    const base_name = std.fs.path.basename(rel_path);
    var stem_buf: [32]u8 = undefined;
    var stem_len: usize = 0;
    for (base_name) |c| {
        const mapped: u8 = switch (c) {
            '/', '\\', ':', '.', ' ' => '_',
            else => std.ascii.toLower(c),
        };
        if (!std.ascii.isAlphanumeric(mapped) and mapped != '_') continue;
        if (stem_len == stem_buf.len) break;
        stem_buf[stem_len] = mapped;
        stem_len += 1;
    }
    if (stem_len == 0) {
        stem_buf[0] = 'c';
        stem_buf[1] = 'a';
        stem_buf[2] = 's';
        stem_buf[3] = 'e';
        stem_len = 4;
    }

    var hasher = std.hash.XxHash64.init(0);
    hasher.update(rel_path);
    const digest = hasher.final();
    return std.fmt.allocPrint(allocator, "{s}_{x:0>16}", .{ stem_buf[0..stem_len], digest });
}

fn exeName(comptime base: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) base ++ ".exe" else base;
}

pub fn defaultGfortran() []const u8 {
    return if (builtin.os.tag == .windows) "gfortran.exe" else "gfortran";
}

test "verify runner default dialect skips legacy FM719 cases" {
    try std.testing.expect(shouldSkipDefaultLegacyCase("fcvs21_f95/FM719.f", .default));
    try std.testing.expect(shouldSkipDefaultLegacyCase("FM719.f", .default));
    try std.testing.expect(shouldSkipDefaultLegacyCase("FM719.FOR", .default));
    try std.testing.expect(!shouldSkipDefaultLegacyCase("fcvs21_f95/FM719.f", .f77_legacy));
}
