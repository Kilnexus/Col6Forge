const std = @import("std");
const model = @import("../model.zig");

const DomainSpec = struct {
    domain: model.SourceDomain,
    prefix: []const u8,
};

const prefix_specs = [_]DomainSpec{
    .{ .domain = .ast, .prefix = "src/ast/" },
    .{ .domain = .common, .prefix = "src/compat/" },
    .{ .domain = .common, .prefix = "src/common/" },
    .{ .domain = .format, .prefix = "src/format/" },
    .{ .domain = .frontend, .prefix = "src/frontend/" },
    .{ .domain = .semantic, .prefix = "src/semantic/" },
    .{ .domain = .codegen, .prefix = "src/codegen/" },
    .{ .domain = .driver, .prefix = "src/driver/" },
    .{ .domain = .runtime, .prefix = "src/runtime/" },
    .{ .domain = .tools, .prefix = "src/tools/" },
    .{ .domain = .scratch, .prefix = "src/tmp/" },
};

const exact_specs = [_]struct {
    domain: model.SourceDomain,
    path: []const u8,
}{
    .{ .domain = .root_entry, .path = "src/main.zig" },
    .{ .domain = .root_entry, .path = "src/root.zig" },
    .{ .domain = .scratch, .path = "src/tmp_c_loc_diag.zig" },
    .{ .domain = .scratch, .path = "src/tmp_c_loc_symbols.zig" },
};

pub fn classify(rel_path: []const u8) ?model.SourceDomain {
    for (exact_specs) |spec| {
        if (std.mem.eql(u8, rel_path, spec.path)) return spec.domain;
    }
    if (std.mem.startsWith(u8, rel_path, "src/tmp_") and std.mem.endsWith(u8, rel_path, ".zig")) {
        return .scratch;
    }
    for (prefix_specs) |spec| {
        if (std.mem.startsWith(u8, rel_path, spec.prefix)) return spec.domain;
    }
    return null;
}

pub fn label(domain: model.SourceDomain) []const u8 {
    return switch (domain) {
        .root_entry => "root-entry",
        .ast => "ast",
        .common => "common",
        .format => "format",
        .frontend => "frontend",
        .semantic => "semantic",
        .codegen => "codegen",
        .driver => "driver",
        .runtime => "runtime",
        .tools => "tools",
        .scratch => "scratch",
    };
}

test "classify recognizes semantic and root files" {
    try std.testing.expectEqual(model.SourceDomain.semantic, classify("src/semantic/mod.zig").?);
    try std.testing.expectEqual(model.SourceDomain.root_entry, classify("src/root.zig").?);
    try std.testing.expectEqual(model.SourceDomain.scratch, classify("src/tmp_c_loc_diag.zig").?);
    try std.testing.expectEqual(model.SourceDomain.scratch, classify("src/tmp_c_loc_symbols.zig").?);
    try std.testing.expectEqual(model.SourceDomain.scratch, classify("src/tmp_c_loc_steps.zig").?);
}
