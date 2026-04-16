const std = @import("std");
const utils = @import("../utils.zig");
const context = @import("../context/mod.zig");

const Context = context.Context;

pub fn uniqueProcedureIRNameBySuffix(ctx: *Context, name: []const u8) !?[]const u8 {
    const lowered = try utils.lowerName(ctx.allocator, name);
    const owned_suffix = try std.fmt.allocPrint(ctx.allocator, "__{s}_", .{lowered});
    const plain_suffix = try std.fmt.allocPrint(ctx.allocator, "{s}_", .{lowered});

    var match: ?[]const u8 = null;

    var defined_it = ctx.defined.iterator();
    while (defined_it.next()) |entry| {
        const candidate = entry.key_ptr.*;
        if (!matchesProcedureSuffix(candidate, plain_suffix, owned_suffix)) continue;
        if (match) |existing| {
            if (!std.mem.eql(u8, existing, candidate)) return null;
        } else {
            match = candidate;
        }
    }

    var decl_it = ctx.decls.iterator();
    while (decl_it.next()) |entry| {
        const candidate = entry.key_ptr.*;
        if (!matchesProcedureSuffix(candidate, plain_suffix, owned_suffix)) continue;
        if (match) |existing| {
            if (!std.mem.eql(u8, existing, candidate)) return null;
        } else {
            match = candidate;
        }
    }

    return match;
}

fn matchesProcedureSuffix(candidate: []const u8, plain_suffix: []const u8, owned_suffix: []const u8) bool {
    return std.mem.eql(u8, candidate, plain_suffix) or std.mem.endsWith(u8, candidate, owned_suffix);
}
