const std = @import("std");
const mapping = @import("mapping.zig");
const fs_compat = @import("fs_compat.zig");

const output_path = "docs/constraints.md";

pub fn main(init: std.process.Init) !void {
    try mapping.validateEntries();

    const allocator = init.gpa;

    var mode: enum { check, write } = .check;
    const args = try allocArgs(allocator, init.minimal.args);
    defer freeArgs(allocator, args);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            mode = .check;
        } else if (std.mem.eql(u8, arg, "--write")) {
            mode = .write;
        } else {
            std.log.err("unknown arg: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    const rendered = try render(allocator);
    defer allocator.free(rendered);

    switch (mode) {
        .write => {
            try fs_compat.cwd().writeFile(.{
                .sub_path = output_path,
                .data = rendered,
            });
            std.log.info("wrote {s}", .{output_path});
        },
        .check => {
            const current = fs_compat.cwd().readFileAlloc(allocator, output_path, 8 * 1024 * 1024) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.err("{s} is missing; run constraints-docs", .{output_path});
                    return error.ConstraintDocOutOfDate;
                },
                else => return err,
            };
            defer allocator.free(current);

            if (!std.mem.eql(u8, current, rendered)) {
                std.log.err("{s} is out of date; run constraints-docs", .{output_path});
                return error.ConstraintDocOutOfDate;
            }
            std.log.info("constraint documentation is up to date", .{});
        },
    }
}

fn allocArgs(allocator: std.mem.Allocator, args_src: std.process.Args) ![][]const u8 {
    var it = try std.process.Args.Iterator.initAllocator(args_src, allocator);
    defer it.deinit();

    var args = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }

    while (it.next()) |arg| {
        try args.append(try allocator.dupe(u8, arg));
    }

    return args.toOwnedSlice();
}

fn freeArgs(allocator: std.mem.Allocator, args: [][]const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn render(allocator: std.mem.Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(
        "# Compiler Constraints\n\n" ++
            "This document is generated from the code-native constraint registry in `devtools/constraints/mapping.zig`.\n\n" ++
            "The registry is the executable source of truth for constraint metadata and enforcement wiring.\n" ++
            "This document is a public English reference for the currently registered constraints.\n\n" ++
            "## Registered Constraints\n\n",
    );

    for (mapping.entries) |entry| {
        const primary = try mapping.joinExecutors(allocator, entry.primary);
        defer allocator.free(primary);
        const secondary = try mapping.joinExecutors(allocator, entry.secondary);
        defer allocator.free(secondary);

        try out.print("### {s}: {s}\n\n", .{ entry.id, entry.summary });
        try out.print("- Class: {s}\n", .{mapping.classLabel(entry.class)});
        try out.print("- Blocking: {s}\n", .{mapping.blockingLabel(entry.blocking)});
        try out.print("- Primary Enforcers: {s}\n", .{primary});
        try out.print("- Secondary Enforcers: {s}\n", .{secondary});
        try out.print("- Rationale: {s}\n\n", .{entry.rationale});
    }

    return out.toOwnedSlice();
}
