const ast = @import("../../ast/nodes.zig");
const case_insensitive = @import("../../common/case_insensitive.zig");
const context = @import("context.zig");

pub fn markInitialized(self: *context.Context, name: []const u8) !void {
    const key = try case_insensitive.lowerDup(self.arena, name);
    const source = self.current_decl_source orelse ast.DeclSource{};
    try self.initialized_symbols.put(key, source);
}

pub fn initializedSource(self: *context.Context, name: []const u8) ?ast.DeclSource {
    const key = case_insensitive.lowerDup(self.arena, name) catch return null;
    return self.initialized_symbols.get(key);
}
