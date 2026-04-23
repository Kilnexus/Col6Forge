const std = @import("std");
const aggregators = @import("audit/aggregators.zig");
const audit_engine = @import("audit/engine.zig");
const facades = @import("audit/facades.zig");
const file_sizes = @import("audit/file_sizes.zig");
const thin_entries = @import("audit/thin_entries.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var failures = try audit_engine.run(allocator, "src");
    failures += try aggregators.run(allocator);
    failures += try facades.run(allocator);
    failures += try thin_entries.run(allocator);
    failures += try file_sizes.run(allocator);
    if (failures > 0) {
        std.log.err("architecture audit failed: {d} issue(s)", .{failures});
        return error.ArchitectureAuditFailed;
    }
    std.log.info("architecture audit passed", .{});
}
