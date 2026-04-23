const std = @import("std");
const source_index = @import("source_index.zig");

pub const ImportLiteral = struct {
    literal: []const u8,
    start_idx: usize,
};

pub const Index = struct {
    import_literals: std.ArrayListUnmanaged(ImportLiteral) = .empty,
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.import_literals.deinit(allocator);
        for (self.owned_strings.items) |value| allocator.free(value);
        self.owned_strings.deinit(allocator);
        self.* = .{};
    }

    pub fn findLiteralContaining(self: Index, fragment: []const u8) ?usize {
        for (self.import_literals.items) |entry| {
            if (std.mem.indexOf(u8, entry.literal, fragment) != null) return entry.start_idx;
        }
        return null;
    }
};

pub fn buildIndex(allocator: std.mem.Allocator, text: []const u8) !?Index {
    var combined = (try source_index.buildIndex(allocator, text)) orelse return null;
    return combined.intoImports(allocator);
}

test "builds AST-backed import literal index" {
    const text =
        "const a = @import(\"foo/bar.zig\");\n" ++
        "const b = @import(\"baz.zig\");\n";

    var index = (try buildIndex(std.testing.allocator, text)).?;
    defer index.deinit(std.testing.allocator);

    try std.testing.expect(index.findLiteralContaining("foo/") != null);
    try std.testing.expect(index.findLiteralContaining("baz") != null);
    try std.testing.expect(index.findLiteralContaining("qux") == null);
}
