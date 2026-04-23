const std = @import("std");
const model = @import("../../model.zig");
const source_index = @import("source_index.zig");

pub const Definition = struct {
    name: []const u8,
    kind: model.DefinitionKind,
    start_idx: usize,
};

pub const Index = struct {
    definitions: std.ArrayListUnmanaged(Definition) = .empty,
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.definitions.deinit(allocator);
        for (self.owned_strings.items) |value| allocator.free(value);
        self.owned_strings.deinit(allocator);
        self.* = .{};
    }

    pub fn findOwnedSymbolDefinition(self: Index, symbol_name: []const u8, definition_kind: model.DefinitionKind) ?usize {
        for (self.definitions.items) |entry| {
            if (entry.kind != definition_kind) continue;
            if (std.mem.eql(u8, entry.name, symbol_name)) return entry.start_idx;
        }
        return null;
    }
};

pub fn buildIndex(allocator: std.mem.Allocator, text: []const u8) !?Index {
    var combined = (try source_index.buildIndex(allocator, text)) orelse return null;
    return combined.intoDefinitions(allocator);
}

test "finds AST-backed function and type definitions" {
    const text =
        "pub fn foo() void {}\n" ++
        "pub const Bar = struct {};\n" ++
        "const Baz = packed union { a: i32 };\n" ++
        "const Qux = enum { x };\n" ++
        "const Alias = Other.Type;\n";

    var index = (try buildIndex(std.testing.allocator, text)).?;
    defer index.deinit(std.testing.allocator);

    try std.testing.expect(index.findOwnedSymbolDefinition("foo", .function) != null);
    try std.testing.expect(index.findOwnedSymbolDefinition("Bar", .type_struct) != null);
    try std.testing.expect(index.findOwnedSymbolDefinition("Baz", .type_union) != null);
    try std.testing.expect(index.findOwnedSymbolDefinition("Qux", .type_enum) != null);
    try std.testing.expect(index.findOwnedSymbolDefinition("Alias", .type_struct) == null);
}
