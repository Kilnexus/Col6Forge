const std = @import("std");
const context = @import("context.zig");
const resolve_symbols = @import("resolve_symbols.zig");

const BindingInfo = context.Context.DerivedTypeInfo.BindingInfo;

pub const BindingSearchOptions = struct {
    skip_generic: bool = false,
};

pub fn findBindingByName(
    bindings: []const BindingInfo,
    name: []const u8,
    options: BindingSearchOptions,
) ?BindingInfo {
    for (bindings) |binding| {
        if (options.skip_generic and binding.is_generic) continue;
        if (std.ascii.eqlIgnoreCase(binding.name, name)) return binding;
    }
    return null;
}

pub fn findAncestorBindingByName(
    self: *context.Context,
    parent_name: ?[]const u8,
    name: []const u8,
    options: BindingSearchOptions,
) ?BindingInfo {
    var current_name = parent_name;
    while (current_name) |parent| {
        const derived = resolve_symbols.lookupDerivedType(self, parent) orelse return null;
        if (findBindingByName(derived.bindings, name, options)) |binding| return binding;
        current_name = derived.parent_name;
    }
    return null;
}
