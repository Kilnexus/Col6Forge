const std = @import("std");
const fs_compat = @import("../fs_compat.zig");

const rule_id = "AR-AST-002";
const rule_title = "thin entry must keep only approved thin local functions";

const AllowedFn = struct {
    name: []const u8,
    max_lines: usize,
};

const Spec = struct {
    path: []const u8,
    allowed_functions: []const AllowedFn,
};

const specs = [_]Spec{
    .{
        .path = "src/tools/verify_runner.zig",
        .allowed_functions = &.{
            .{ .name = "main", .max_lines = 180 },
        },
    },
    .{
        .path = "src/tools/gcc_dg_runner.zig",
        .allowed_functions = &.{
            .{ .name = "main", .max_lines = 120 },
        },
    },
};

pub fn run(allocator: std.mem.Allocator) !usize {
    var failures: usize = 0;
    inline for (specs) |spec| {
        try checkThinEntryFile(allocator, spec, &failures);
    }
    return failures;
}

fn checkThinEntryFile(allocator: std.mem.Allocator, spec: Spec, failures: *usize) !void {
    const text = try fs_compat.cwd().readFileAlloc(allocator, spec.path, 1024 * 1024);
    defer allocator.free(text);

    const source = try allocator.dupeZ(u8, text);
    defer allocator.free(source);

    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return;

    var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const node_tags = tree.nodes.items(.tag);
    for (node_tags, 0..) |tag, idx| {
        if (tag != .fn_decl) continue;
        const node: std.zig.Ast.Node.Index = @enumFromInt(idx);
        const fn_proto = tree.fullFnProto(&fn_proto_buffer, node) orelse continue;
        const name_token = fn_proto.name_token orelse continue;
        const name = tree.tokenSlice(name_token);
        const allowed = findAllowed(spec.allowed_functions, name) orelse {
            reportViolation(spec.path, tree.tokenStart(fn_proto.firstToken()), text, name);
            failures.* += 1;
            continue;
        };
        const line_count = countLines(tree.getNodeSource(node));
        if (line_count > allowed.max_lines) {
            var detail_buffer: [96]u8 = undefined;
            const detail = try std.fmt.bufPrint(&detail_buffer, "{s} ({d} lines > {d})", .{ name, line_count, allowed.max_lines });
            reportViolation(spec.path, tree.tokenStart(fn_proto.firstToken()), text, detail);
            failures.* += 1;
        }
    }
}

fn findAllowed(allowed_functions: []const AllowedFn, name: []const u8) ?AllowedFn {
    for (allowed_functions) |allowed| {
        if (std.mem.eql(u8, allowed.name, name)) return allowed;
    }
    return null;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    const newline_count = std.mem.count(u8, text, "\n");
    return if (text[text.len - 1] == '\n') newline_count else newline_count + 1;
}

fn reportViolation(path: []const u8, idx: usize, text: []const u8, detail: []const u8) void {
    const line = 1 + std.mem.count(u8, text[0..idx], "\n");
    std.log.err(
        "{s}:{d}: [{s}] forbidden {s}: `{s}`",
        .{ path, line, rule_id, rule_title, detail },
    );
}

test "thin entry allows approved main only" {
    const local_spec: Spec = .{
        .path = "test.zig",
        .allowed_functions = &.{.{ .name = "main", .max_lines = 10 }},
    };
    try std.testing.expect(findAllowed(local_spec.allowed_functions, "main") != null);
}

test "thin entry line counter counts function source lines" {
    try std.testing.expectEqual(@as(usize, 3), countLines("pub fn main() void {\n    return;\n}"));
}
