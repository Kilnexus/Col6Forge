const std = @import("std");
const zig_ast = @import("zig_ast/source_index.zig");
const fs_compat = @import("../fs_compat.zig");

const rule_id = "AR-AST-001";
const rule_title = "facade entry must stay implementation-free";

const Spec = struct {
    path: []const u8,
};

const specs = [_]Spec{
    .{ .path = "src/semantic/analysis/mod.zig" },
    .{ .path = "src/semantic/tests/legacy_common_equivalence_tests.zig" },
    .{ .path = "src/codegen/llvm/codegen/module/tests.zig" },
    .{ .path = "src/codegen/llvm/codegen/expression/tests/mod.zig" },
    .{ .path = "src/frontend/parser/root/tests.zig" },
    .{ .path = "src/frontend/parser/stmt/tests.zig" },
    .{ .path = "src/driver/pipeline/tests.zig" },
};

pub fn run(allocator: std.mem.Allocator) !usize {
    var failures: usize = 0;
    inline for (specs) |spec| {
        try checkFacadeFile(allocator, spec.path, &failures);
    }
    return failures;
}

fn checkFacadeFile(allocator: std.mem.Allocator, path: []const u8, failures: *usize) !void {
    const text = try fs_compat.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(text);

    var index = (try zig_ast.buildIndex(allocator, text)) orelse return;
    defer index.deinit(allocator);

    for (index.definitions.definitions.items) |definition| {
        const line = 1 + std.mem.count(u8, text[0..definition.start_idx], "\n");
        std.log.err(
            "{s}:{d}: [{s}] forbidden {s}: `{s}`",
            .{ path, line, rule_id, rule_title, definition.name },
        );
        failures.* += 1;
    }
}

test "facade entries may stay import-only without local definitions" {
    const text =
        "const _foo = @import(\"tests/foo.zig\");\n" ++
        "test { _ = _foo; }\n";

    var index = (try zig_ast.buildIndex(std.testing.allocator, text)).?;
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), index.definitions.definitions.items.len);
}

test "facade check flags local function definitions" {
    const text =
        "const helper = @import(\"helpers.zig\");\n" ++
        "fn localImpl() void {}\n";

    var index = (try zig_ast.buildIndex(std.testing.allocator, text)).?;
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), index.definitions.definitions.items.len);
    try std.testing.expectEqualStrings("localImpl", index.definitions.definitions.items[0].name);
}
