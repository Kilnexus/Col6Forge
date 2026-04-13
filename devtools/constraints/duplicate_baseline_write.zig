const std = @import("std");
const baseline = @import("audit/duplicate_baseline.zig");
const duplicates = @import("audit/duplicates.zig");

const baseline_path = "devtools/constraints/audit/duplicate_baseline.zig";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var root: []const u8 = baseline.root;
    var min_normalized_len: usize = baseline.min_normalized_len;
    var fingerprint_mode: duplicates.FingerprintMode = baseline.fingerprint_mode;
    var advisory_fingerprint_mode: ?duplicates.FingerprintMode = baseline.advisory_fingerprint_mode;
    var advisory_top_clusters: usize = baseline.advisory_top_clusters;
    var write = false;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) {
            root = args.next() orelse return error.MissingArgumentValue;
        } else if (std.mem.eql(u8, arg, "--min-normalized-len")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            min_normalized_len = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--fingerprint")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            fingerprint_mode = parseFingerprintMode(value) orelse {
                std.log.err("unknown fingerprint mode: {s}", .{value});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--advisory-fingerprint")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            if (std.mem.eql(u8, value, "none")) {
                advisory_fingerprint_mode = null;
            } else {
                advisory_fingerprint_mode = parseFingerprintMode(value) orelse {
                    std.log.err("unknown advisory fingerprint mode: {s}", .{value});
                    return error.InvalidArgument;
                };
            }
        } else if (std.mem.eql(u8, arg, "--advisory-top")) {
            const value = args.next() orelse return error.MissingArgumentValue;
            advisory_top_clusters = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--write")) {
            write = true;
        } else {
            std.log.err("unknown arg: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    if (!write) {
        std.log.err("use --write to refresh {s}", .{baseline_path});
        return error.MissingWriteMode;
    }

    const clusters = try duplicates.findDuplicateClustersWithMode(
        allocator,
        root,
        min_normalized_len,
        fingerprint_mode,
    );
    defer {
        for (clusters) |*cluster| cluster.deinit(allocator);
        allocator.free(clusters);
    }

    const rendered = try renderBaseline(
        allocator,
        clusters,
        root,
        min_normalized_len,
        fingerprint_mode,
        advisory_fingerprint_mode,
        advisory_top_clusters,
    );
    defer allocator.free(rendered);

    const cwd = std.fs.cwd();
    const current = cwd.readFileAlloc(allocator, baseline_path, 16 * 1024 * 1024) catch null;
    defer if (current) |buf| allocator.free(buf);

    if (current) |buf| {
        if (std.mem.eql(u8, buf, rendered)) {
            std.log.info("duplicate baseline already up to date: {d} clusters", .{clusters.len});
            return;
        }
    }

    try cwd.writeFile(.{
        .sub_path = baseline_path,
        .data = rendered,
    });
    std.log.info(
        "wrote duplicate baseline: {d} clusters to {s} (fingerprint={s})",
        .{ clusters.len, baseline_path, @tagName(fingerprint_mode) },
    );
}

fn renderBaseline(
    allocator: std.mem.Allocator,
    clusters: []const duplicates.Cluster,
    root: []const u8,
    min_normalized_len: usize,
    fingerprint_mode: duplicates.FingerprintMode,
    advisory_fingerprint_mode: ?duplicates.FingerprintMode,
    advisory_top_clusters: usize,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    try out.appendSlice(allocator,
        \\const duplicates = @import("duplicates.zig");
        \\
    );
    try writer.print("pub const root = \"{s}\";\n", .{root});
    try writer.print("pub const min_normalized_len: usize = {d};\n", .{min_normalized_len});
    try writer.print("pub const fingerprint_mode: duplicates.FingerprintMode = .{s};\n\n", .{@tagName(fingerprint_mode)});
    if (advisory_fingerprint_mode) |mode| {
        try writer.print("pub const advisory_fingerprint_mode: ?duplicates.FingerprintMode = .{s};\n", .{@tagName(mode)});
    } else {
        try writer.writeAll("pub const advisory_fingerprint_mode: ?duplicates.FingerprintMode = null;\n");
    }
    try writer.print("pub const advisory_top_clusters: usize = {d};\n\n", .{advisory_top_clusters});
    try out.appendSlice(allocator,
        \\pub const AllowedCluster = struct {
        \\    body_hash: u64,
        \\    max_members: usize,
        \\    normalized_len: usize,
        \\};
        \\
        \\pub const allowed_clusters = [_]AllowedCluster{
        \\
    );

    for (clusters) |cluster| {
        try writer.print(
            "    .{{ .body_hash = 0x{x}, .max_members = {d}, .normalized_len = {d} }},\n",
            .{ cluster.body_hash, cluster.members.len, cluster.normalized_len },
        );
    }
    try writer.writeAll("};\n");
    return out.toOwnedSlice(allocator);
}

fn parseFingerprintMode(value: []const u8) ?duplicates.FingerprintMode {
    if (std.mem.eql(u8, value, "lexical")) return .lexical;
    if (std.mem.eql(u8, value, "ast")) return .ast;
    return null;
}
