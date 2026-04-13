const std = @import("std");
const baseline = @import("audit/duplicate_baseline.zig");
const duplicates = @import("audit/duplicates.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try validateBaseline();

    const clusters = try duplicates.findDuplicateClustersWithMode(
        allocator,
        baseline.root,
        baseline.min_normalized_len,
        baseline.fingerprint_mode,
    );
    defer {
        for (clusters) |*cluster| cluster.deinit(allocator);
        allocator.free(clusters);
    }

    var failed = false;
    for (clusters) |cluster| {
        const allowed = findAllowed(cluster.body_hash) orelse {
            failed = true;
            reportUnexpected(cluster);
            continue;
        };
        if (cluster.members.len > allowed.max_members) {
            failed = true;
            reportExpanded(cluster, allowed);
        }
    }

    if (failed) return error.DuplicateBaselineViolation;

    std.log.info(
        "duplicate baseline passed: {d} current clusters, {d} allowed clusters, root={s}, min_normalized_len={d}, fingerprint={s}",
        .{
            clusters.len,
            baseline.allowed_clusters.len,
            baseline.root,
            baseline.min_normalized_len,
            @tagName(baseline.fingerprint_mode),
        },
    );
}

fn validateBaseline() !void {
    for (baseline.allowed_clusters, 0..) |entry, idx| {
        if (entry.max_members < 2 or entry.normalized_len == 0) return error.InvalidDuplicateBaselineEntry;
        for (baseline.allowed_clusters[idx + 1 ..]) |other| {
            if (entry.body_hash == other.body_hash) return error.DuplicateBaselineHash;
        }
    }
}

fn findAllowed(body_hash: u64) ?baseline.AllowedCluster {
    for (baseline.allowed_clusters) |entry| {
        if (entry.body_hash == body_hash) return entry;
    }
    return null;
}

fn reportUnexpected(cluster: duplicates.Cluster) void {
    std.log.err(
        "unexpected duplicate cluster: body_hash=0x{x}, members={d}, normalized_len={d}",
        .{ cluster.body_hash, cluster.members.len, cluster.normalized_len },
    );
    for (cluster.members) |member| {
        std.log.err("  - {s}:{d} fn {s}", .{ member.path, member.line, member.name });
    }
}

fn reportExpanded(cluster: duplicates.Cluster, allowed: baseline.AllowedCluster) void {
    std.log.err(
        "duplicate cluster exceeded baseline: body_hash=0x{x}, current_members={d}, allowed_members={d}, normalized_len={d}",
        .{ cluster.body_hash, cluster.members.len, allowed.max_members, cluster.normalized_len },
    );
    for (cluster.members) |member| {
        std.log.err("  - {s}:{d} fn {s}", .{ member.path, member.line, member.name });
    }
}
