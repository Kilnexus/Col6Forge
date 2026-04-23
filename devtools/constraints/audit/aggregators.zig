const std = @import("std");
const fs_compat = @import("../fs_compat.zig");

const rule_id = "AR-AST-003";
const rule_title = "test aggregator entry must stay import-and-test only";

const Spec = struct {
    path: []const u8,
};

const specs = [_]Spec{
    .{ .path = "src/codegen/llvm/codegen/module/tests.zig" },
    .{ .path = "src/codegen/llvm/codegen/expression/tests/mod.zig" },
    .{ .path = "src/frontend/parser/root/tests.zig" },
    .{ .path = "src/frontend/parser/stmt/tests.zig" },
    .{ .path = "src/driver/pipeline/tests.zig" },
    .{ .path = "src/semantic/tests/legacy_common_equivalence_tests.zig" },
};

pub fn run(allocator: std.mem.Allocator) !usize {
    var failures: usize = 0;
    inline for (specs) |spec| {
        try checkAggregatorFile(allocator, spec.path, &failures);
    }
    return failures;
}

fn checkAggregatorFile(allocator: std.mem.Allocator, path: []const u8, failures: *usize) !void {
    const text = try fs_compat.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(text);

    const source = try allocator.dupeZ(u8, text);
    defer allocator.free(source);

    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return;

    for (tree.rootDecls()) |node| {
        const tag = tree.nodes.items(.tag)[@intFromEnum(node)];
        switch (tag) {
            .test_decl => {},
            .global_var_decl, .simple_var_decl, .local_var_decl, .aligned_var_decl => {
                if (!isImportAliasDecl(tree, node)) {
                    reportViolation(path, tree.tokenStart(tree.firstToken(node)), text, "non-import top-level declaration");
                    failures.* += 1;
                }
            },
            else => {
                reportViolation(path, tree.tokenStart(tree.firstToken(node)), text, @tagName(tag));
                failures.* += 1;
            },
        }
    }
}

fn isImportAliasDecl(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    const var_decl = tree.fullVarDecl(node) orelse return false;
    const init_node = var_decl.ast.init_node.unwrap() orelse return false;
    const init_tag = tree.nodes.items(.tag)[@intFromEnum(init_node)];
    switch (init_tag) {
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
        else => return false,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@import")) return false;

    var builtin_param_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&builtin_param_buffer, init_node) orelse return false;
    if (params.len != 1) return false;
    const param_source = tree.getNodeSource(params[0]);
    return param_source.len >= 2 and param_source[0] == '"' and param_source[param_source.len - 1] == '"';
}

fn reportViolation(path: []const u8, idx: usize, text: []const u8, detail: []const u8) void {
    const line = 1 + std.mem.count(u8, text[0..idx], "\n");
    std.log.err(
        "{s}:{d}: [{s}] forbidden {s}: `{s}`",
        .{ path, line, rule_id, rule_title, detail },
    );
}

test "aggregator allows import aliases and test blocks" {
    const text =
        "const _foo = @import(\"foo.zig\");\n" ++
        "const _bar = @import(\"bar.zig\");\n" ++
        "test { _ = _foo; _ = _bar; }\n";

    const source = try std.testing.allocator.dupeZ(u8, text);
    defer std.testing.allocator.free(source);
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    for (tree.rootDecls()) |node| {
        const tag = tree.nodes.items(.tag)[@intFromEnum(node)];
        if (tag == .test_decl) continue;
        try std.testing.expect(isImportAliasDecl(tree, node));
    }
}

test "aggregator rejects non-import top-level alias" {
    const text = "const helper = deps.helper;\n";
    const source = try std.testing.allocator.dupeZ(u8, text);
    defer std.testing.allocator.free(source);
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expect(!isImportAliasDecl(tree, tree.rootDecls()[0]));
}
