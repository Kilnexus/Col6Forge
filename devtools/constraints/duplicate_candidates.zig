const std = @import("std");
const model = @import("model.zig");
const domains = @import("audit/domains.zig");
const duplicates = @import("audit/duplicates.zig");
const arg_utils = @import("args.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var root: []const u8 = "src";
    var top: usize = 25;
    var min_normalized_len: usize = 96;
    var fingerprint_mode: duplicates.FingerprintMode = .ast;
    var selected_domain: ?model.SourceDomain = null;
    var selected_path_prefix: ?[]const u8 = null;

    const args = try arg_utils.allocArgs(allocator, init.minimal.args);
    defer arg_utils.freeArgs(allocator, args);

    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--root")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            root = args[arg_idx];
        } else if (std.mem.eql(u8, arg, "--top")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            const value = args[arg_idx];
            top = try std.fmt.parseInt(usize, value, 10);
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
        } else if (std.mem.eql(u8, arg, "--domain")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            const value = args[arg_idx];
            selected_domain = parseDomainLabel(value) orelse {
                std.log.err("unknown domain: {s}", .{value});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--path-prefix")) {
            arg_idx += 1;
            if (arg_idx >= args.len) return error.MissingArgumentValue;
            selected_path_prefix = args[arg_idx];
        } else {
            std.log.err("unknown arg: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    const clusters = try duplicates.findDuplicateClustersWithMode(allocator, root, min_normalized_len, fingerprint_mode);
    defer {
        for (clusters) |*cluster| cluster.deinit(allocator);
        allocator.free(clusters);
    }

    if (clusters.len == 0) {
        std.log.info("no duplicate function-body clusters found in {s} with normalized length >= {d}", .{ root, min_normalized_len });
        return;
    }

    var shown: usize = 0;
    for (clusters) |cluster| {
        if (!clusterMatchesFilters(cluster, selected_domain, selected_path_prefix)) continue;
        shown += 1;
        if (shown == top) break;
    }
    if (shown == 0) {
        const filter_label = try renderFilterLabel(allocator, selected_domain, selected_path_prefix);
        defer allocator.free(filter_label);
        std.log.info("no duplicate function-body clusters matched {s} in {s} with normalized length >= {d}", .{ filter_label, root, min_normalized_len });
        return;
    }
    const filter_suffix = try renderFilterSuffix(allocator, selected_domain, selected_path_prefix);
    defer allocator.free(filter_suffix);

    std.log.info(
        "duplicate function-body clusters: {d} total, showing {d}, root={s}, min_normalized_len={d}{s}",
        .{ clusters.len, shown, root, min_normalized_len, filter_suffix },
    );
    var printed: usize = 0;
    for (clusters) |cluster| {
        if (!clusterMatchesFilters(cluster, selected_domain, selected_path_prefix)) continue;
        const label_buf = try clusterDomainLabel(allocator, cluster);
        defer allocator.free(label_buf);
        printed += 1;
        std.log.info(
            "cluster {d}: members={d}, normalized_len={d}, domains={s}",
            .{ printed, cluster.members.len, cluster.normalized_len, label_buf },
        );
        for (cluster.members) |member| {
            std.log.info("  - {s}:{d} fn {s}", .{ member.path, member.line, member.name });
        }
        if (printed == shown) break;
    }
}

fn parseFingerprintMode(value: []const u8) ?duplicates.FingerprintMode {
    if (std.mem.eql(u8, value, "lexical")) return .lexical;
    if (std.mem.eql(u8, value, "ast")) return .ast;
    return null;
}

fn parseDomainLabel(label: []const u8) ?model.SourceDomain {
    inline for (@typeInfo(model.SourceDomain).@"enum".fields) |field| {
        const domain: model.SourceDomain = @enumFromInt(field.value);
        if (std.mem.eql(u8, domains.label(domain), label)) return domain;
    }
    return null;
}

fn clusterTouchesDomain(cluster: duplicates.Cluster, domain: model.SourceDomain) bool {
    for (cluster.members) |member| {
        if (domains.classify(member.path)) |member_domain| {
            if (member_domain == domain) return true;
        }
    }
    return false;
}

fn clusterTouchesPathPrefix(cluster: duplicates.Cluster, path_prefix: []const u8) bool {
    for (cluster.members) |member| {
        if (std.mem.startsWith(u8, member.path, path_prefix)) return true;
    }
    return false;
}

fn clusterMatchesFilters(
    cluster: duplicates.Cluster,
    selected_domain: ?model.SourceDomain,
    selected_path_prefix: ?[]const u8,
) bool {
    if (selected_domain) |domain| {
        if (!clusterTouchesDomain(cluster, domain)) return false;
    }
    if (selected_path_prefix) |path_prefix| {
        if (!clusterTouchesPathPrefix(cluster, path_prefix)) return false;
    }
    return true;
}

fn clusterDomainLabel(allocator: std.mem.Allocator, cluster: duplicates.Cluster) ![]u8 {
    var seen: [@typeInfo(model.SourceDomain).@"enum".fields.len]bool = [_]bool{false} ** @typeInfo(model.SourceDomain).@"enum".fields.len;
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    for (cluster.members) |member| {
        const domain = domains.classify(member.path) orelse continue;
        const idx: usize = @intFromEnum(domain);
        if (seen[idx]) continue;
        seen[idx] = true;
        try parts.append(allocator, domains.label(domain));
    }

    if (parts.items.len == 0) return allocator.dupe(u8, "unknown");
    return std.mem.join(allocator, ",", parts.items);
}

fn renderFilterLabel(
    allocator: std.mem.Allocator,
    selected_domain: ?model.SourceDomain,
    selected_path_prefix: ?[]const u8,
) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    if (selected_domain) |domain| {
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "domain={s}", .{domains.label(domain)}));
    }
    if (selected_path_prefix) |path_prefix| {
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "path-prefix={s}", .{path_prefix}));
    }
    if (parts.items.len == 0) return allocator.dupe(u8, "the current filters");

    defer for (parts.items) |part| allocator.free(part);
    return std.mem.join(allocator, ", ", parts.items);
}

fn renderFilterSuffix(
    allocator: std.mem.Allocator,
    selected_domain: ?model.SourceDomain,
    selected_path_prefix: ?[]const u8,
) ![]u8 {
    if (selected_domain == null and selected_path_prefix == null) return allocator.dupe(u8, "");
    const label = try renderFilterLabel(allocator, selected_domain, selected_path_prefix);
    defer allocator.free(label);
    return std.fmt.allocPrint(allocator, ", {s}", .{label});
}

test "parseDomainLabel accepts canonical labels" {
    try std.testing.expectEqual(model.SourceDomain.codegen, parseDomainLabel("codegen").?);
    try std.testing.expectEqual(model.SourceDomain.root_entry, parseDomainLabel("root-entry").?);
    try std.testing.expect(parseDomainLabel("missing") == null);
}

test "parseFingerprintMode accepts canonical labels" {
    try std.testing.expectEqual(duplicates.FingerprintMode.lexical, parseFingerprintMode("lexical").?);
    try std.testing.expectEqual(duplicates.FingerprintMode.ast, parseFingerprintMode("ast").?);
    try std.testing.expect(parseFingerprintMode("missing") == null);
}

test "clusterMatchesFilters honors path prefix" {
    const members = [_]duplicates.FunctionFingerprint{
        .{ .path = @constCast("src/codegen/a.zig"), .name = @constCast("alpha"), .normalized_body = @constCast("X"), .line = 1 },
        .{ .path = @constCast("src/runtime/b.zig"), .name = @constCast("beta"), .normalized_body = @constCast("X"), .line = 2 },
    };
    const cluster = duplicates.Cluster{
        .body_hash = 1,
        .normalized_len = 1,
        .members = @constCast(members[0..]),
    };
    try std.testing.expect(clusterMatchesFilters(cluster, .codegen, null));
    try std.testing.expect(clusterMatchesFilters(cluster, null, "src/runtime/"));
    try std.testing.expect(!clusterMatchesFilters(cluster, .semantic, null));
    try std.testing.expect(!clusterMatchesFilters(cluster, null, "src/frontend/"));
}
