const builtin_mod = @import("builtin");
pub const std = @import("std");
pub const Col6Forge = @import("Col6Forge");
pub const zig_api = Col6Forge.zig_api;
pub const fallback_policy = @import("../fallback_policy.zig");
pub const builtin = builtin_mod;

pub const RuntimeBackend = enum {
    c,
    zig,
};

pub const CACHE_SCHEMA_VERSION: u32 = 3;
pub const HOST_CACHE_TAG = std.fmt.comptimePrint(
    "{s}-{s}-{s}",
    .{ @tagName(builtin_mod.os.tag), @tagName(builtin_mod.cpu.arch), @tagName(builtin_mod.abi) },
);

pub fn emitCacheTag(_: Col6Forge.EmitKind) []const u8 {
    return "default";
}

pub fn runtimeBackendTag(backend: RuntimeBackend) []const u8 {
    return @tagName(backend);
}
