const std = @import("std");
const baseline = @import("audit/duplicate_baseline.zig");
const duplicates = @import("audit/duplicates.zig");
const arg_utils = @import("args.zig");
const Col6Forge = @import("Col6Forge");
const zig_api = Col6Forge.zig_api;

const baseline_path = "devtools/constraints/audit/duplicate_baseline.zig";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var root: []const u8 = baseline.root;
    var min_normalized_len: usize = baseline.min_normalized_len;
    var fingerprint_mode: duplicates.FingerprintMode = baseline.fingerprint_mode;
    var advisory_fingerprint_mode: ?duplicates.FingerprintMode = baseline.advisory_fingerprint_mode;
    var advisory_top_clusters: usize = baseline.advisory_top_clusters;
    var write = false;

    const args = try arg_utils.allocArgs(allocator, init.minimal.args);
    defer arg_utils.freeArgs(allocator, args);

    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--root")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            root = args[arg_idx];
        } else if (std.mem.eql(u8, arg, "--min-normalized-len")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            const value = args[arg_idx];
            min_normalized_len = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--fingerprint")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            const value = args[arg_idx];
            fingerprint_mode = parseFingerprintMode(value) orelse {
                std.log.err("unknown fingerprint mode: {s}", .{value});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--advisory-fingerprint")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            const value = args[arg_idx];
            if (std.mem.eql(u8, value, "none")) {
                advisory_fingerprint_mode = null;
            } else {
                advisory_fingerprint_mode = parseFingerprintMode(value) orelse {
                    std.log.err("unknown advisory fingerprint mode: {s}", .{value});
                    return error.InvalidArgument;
                };
            }
        } else if (std.mem.eql(u8, arg, "--advisory-top")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            const value = args[arg_idx];
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

    const cwd = zig_api.cwd();
    const current = cwd.readFileAlloc(allocator, baseline_path, 16 * 1024 * 1024) catch null;
    defer if (current) |buf| allocator.free(buf);

    if (current) |buf| {
        if (std.mem.eql(u8, buf, rendered)) {
            std.log.info("duplicate baseline already up to date: {d} clusters", .{clusters.len});
            return;
        }
    }

    var out_file = try cwd.createFile(baseline_path, .{ .truncate = true });
    defer out_file.close();
    try out_file.writeAll(rendered);
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
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(
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
    try writer.writeAll(
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
    try writer.flush();
    return allocator.dupe(u8, writer.buffered());
}

fn parseFingerprintMode(value: []const u8) ?duplicates.FingerprintMode {
    if (std.mem.eql(u8, value, "lexical")) return .lexical;
    if (std.mem.eql(u8, value, "ast")) return .ast;
    return null;
}
