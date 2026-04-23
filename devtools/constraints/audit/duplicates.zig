const std = @import("std");
const fs_compat = @import("../fs_compat.zig");

pub const FingerprintMode = enum {
    lexical,
    ast,
};

pub const FunctionFingerprint = struct {
    path: []u8,
    name: []u8,
    normalized_body: []u8,
    line: usize,

    fn deinit(self: *FunctionFingerprint, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        allocator.free(self.normalized_body);
        self.* = undefined;
    }
};

pub const Cluster = struct {
    body_hash: u64,
    normalized_len: usize,
    members: []FunctionFingerprint,

    pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
        for (self.members) |*member| member.deinit(allocator);
        allocator.free(self.members);
        self.* = undefined;
    }
};

pub fn findDuplicateClusters(
    allocator: std.mem.Allocator,
    root: []const u8,
    min_normalized_len: usize,
) ![]Cluster {
    return findDuplicateClustersWithMode(allocator, root, min_normalized_len, .lexical);
}

pub fn findDuplicateClustersWithMode(
    allocator: std.mem.Allocator,
    root: []const u8,
    min_normalized_len: usize,
    mode: FingerprintMode,
) ![]Cluster {
    var functions = std.ArrayList(FunctionFingerprint).empty;
    defer {
        for (functions.items) |*item| item.deinit(allocator);
        functions.deinit(allocator);
    }

    try scanTree(allocator, root, &functions, mode);
    std.mem.sort(FunctionFingerprint, functions.items, {}, lessThanFunctionFingerprint);

    var clusters = std.ArrayList(Cluster).empty;
    errdefer {
        for (clusters.items) |*cluster| cluster.deinit(allocator);
        clusters.deinit(allocator);
    }

    var group_start: usize = 0;
    while (group_start < functions.items.len) {
        var group_end = group_start + 1;
        while (group_end < functions.items.len and std.mem.eql(u8, functions.items[group_start].normalized_body, functions.items[group_end].normalized_body)) : (group_end += 1) {}

        const group = functions.items[group_start..group_end];
        if (group.len > 1 and group[0].normalized_body.len >= min_normalized_len) {
            var members = try allocator.alloc(FunctionFingerprint, group.len);
            errdefer allocator.free(members);
            for (group, 0..) |member, idx| {
                members[idx] = .{
                    .path = try allocator.dupe(u8, member.path),
                    .name = try allocator.dupe(u8, member.name),
                    .normalized_body = try allocator.dupe(u8, member.normalized_body),
                    .line = member.line,
                };
            }
            try clusters.append(allocator, .{
                .body_hash = bodyHash(group[0].normalized_body),
                .normalized_len = group[0].normalized_body.len,
                .members = members,
            });
        }
        group_start = group_end;
    }

    std.mem.sort(Cluster, clusters.items, {}, lessThanCluster);
    return clusters.toOwnedSlice(allocator);
}

fn scanTree(
    allocator: std.mem.Allocator,
    root: []const u8,
    out: *std.ArrayList(FunctionFingerprint),
    mode: FingerprintMode,
) !void {
    var dir = if (std.fs.path.isAbsolute(root))
        try fs_compat.openDirAbsolute(root, .{ .iterate = true })
    else
        try fs_compat.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const rel_path_native = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(rel_path_native);

        const rel_path = try normalizePath(allocator, rel_path_native);
        defer allocator.free(rel_path);

        const text = try dir.readFileAlloc(allocator, entry.path, 16 * 1024 * 1024);
        defer allocator.free(text);

        switch (mode) {
            .lexical => try scanFileLexical(allocator, rel_path, text, out),
            .ast => try scanFileAst(allocator, rel_path, text, out),
        }
    }
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return out;
}

fn scanFileLexical(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    text: []const u8,
    out: *std.ArrayList(FunctionFingerprint),
) !void {
    var idx: usize = 0;
    while (idx < text.len) {
        const token = nextToken(text, idx) orelse break;
        idx = token.next_idx;
        if (!std.mem.eql(u8, token.lexeme, "fn")) continue;

        const name_token = nextIdentifierToken(text, idx) orelse continue;
        const body = findFunctionBody(text, name_token.next_idx) orelse {
            idx = name_token.next_idx;
            continue;
        };
        idx = body.end_idx;

        const normalized_body = try normalizeBody(allocator, text[body.start_idx..body.end_idx]);
        errdefer allocator.free(normalized_body);

        try out.append(allocator, .{
            .path = try allocator.dupe(u8, rel_path),
            .name = try allocator.dupe(u8, name_token.lexeme),
            .normalized_body = normalized_body,
            .line = 1 + std.mem.count(u8, text[0..token.start_idx], "\n"),
        });
    }
}

fn scanFileAst(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    text: []const u8,
    out: *std.ArrayList(FunctionFingerprint),
) !void {
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
        const node_data = tree.nodeData(node).node_and_node;
        const proto_node = node_data[0];
        const body_node = node_data[1];
        const fn_proto = tree.fullFnProto(&fn_proto_buffer, proto_node) orelse continue;
        const name_token = fn_proto.name_token orelse continue;

        const normalized_body = try normalizeBodyAst(allocator, tree.getNodeSource(body_node));
        errdefer allocator.free(normalized_body);

        try out.append(allocator, .{
            .path = try allocator.dupe(u8, rel_path),
            .name = try allocator.dupe(u8, tree.tokenSlice(name_token)),
            .normalized_body = normalized_body,
            .line = 1 + std.mem.count(u8, text[0..tree.tokenStart(fn_proto.firstToken())], "\n"),
        });
    }
}

const BodyMatch = struct {
    start_idx: usize,
    end_idx: usize,
};

fn findFunctionBody(text: []const u8, start: usize) ?BodyMatch {
    var idx = start;
    while (idx < text.len) {
        if (startsWithLineComment(text, idx)) {
            idx = skipLineComment(text, idx);
            continue;
        }
        if (startsWithBlockComment(text, idx)) {
            idx = skipBlockComment(text, idx);
            continue;
        }
        if (text[idx] == '"' or text[idx] == '\'') {
            idx = skipQuotedLiteral(text, idx);
            continue;
        }
        if (text[idx] == ';') return null;
        if (text[idx] == '{') {
            const end_idx = skipBalancedBraces(text, idx) orelse return null;
            return .{ .start_idx = idx, .end_idx = end_idx };
        }
        idx += 1;
    }
    return null;
}

fn skipBalancedBraces(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var idx = start;
    while (idx < text.len) {
        if (startsWithLineComment(text, idx)) {
            idx = skipLineComment(text, idx);
            continue;
        }
        if (startsWithBlockComment(text, idx)) {
            idx = skipBlockComment(text, idx);
            continue;
        }
        if (text[idx] == '"' or text[idx] == '\'') {
            idx = skipQuotedLiteral(text, idx);
            continue;
        }
        switch (text[idx]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return idx + 1;
            },
            else => {},
        }
        idx += 1;
    }
    return null;
}

fn normalizeBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var idx: usize = 0;
    while (idx < body.len) {
        if (startsWithLineComment(body, idx)) {
            idx = skipLineComment(body, idx);
            continue;
        }
        if (startsWithBlockComment(body, idx)) {
            idx = skipBlockComment(body, idx);
            continue;
        }
        if (std.ascii.isWhitespace(body[idx])) {
            idx += 1;
            continue;
        }
        if (body[idx] == '"' or body[idx] == '\'') {
            try out.appendSlice(allocator, "STR;");
            idx = skipQuotedLiteral(body, idx);
            continue;
        }
        if (body[idx] == '@') {
            const builtin = consumeBuiltin(body, idx);
            try out.appendSlice(allocator, body[idx..builtin]);
            try out.append(allocator, ';');
            idx = builtin;
            continue;
        }
        if (std.ascii.isDigit(body[idx])) {
            idx = consumeNumber(body, idx);
            try out.appendSlice(allocator, "NUM;");
            continue;
        }
        if (isIdentifierStart(body[idx])) {
            const ident_end = consumeIdentifier(body, idx);
            const ident = body[idx..ident_end];
            if (isKeyword(ident)) {
                try out.appendSlice(allocator, ident);
            } else {
                try out.appendSlice(allocator, "ID");
            }
            try out.append(allocator, ';');
            idx = ident_end;
            continue;
        }

        try out.append(allocator, body[idx]);
        idx += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn normalizeBodyAst(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const source = try allocator.dupeZ(u8, body);
    defer allocator.free(source);

    var tokenizer = std.zig.Tokenizer.init(source);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .identifier => try out.appendSlice(allocator, "ID;"),
            .builtin => try out.appendSlice(allocator, "BUILTIN;"),
            .number_literal => try out.appendSlice(allocator, "NUM;"),
            .char_literal,
            .multiline_string_literal_line,
            .string_literal,
            .invalid_periodasterisks,
            .invalid,
            => try out.appendSlice(allocator, "STR;"),
            .doc_comment,
            .container_doc_comment,
            => {},
            else => {
                if (isKeywordTag(token.tag)) {
                    try out.appendSlice(allocator, @tagName(token.tag));
                } else {
                    try out.appendSlice(allocator, @tagName(token.tag));
                }
                try out.append(allocator, ';');
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn isKeywordTag(tag: std.zig.Token.Tag) bool {
    return std.mem.startsWith(u8, @tagName(tag), "keyword_");
}

const Token = struct {
    start_idx: usize,
    next_idx: usize,
    lexeme: []const u8,
};

fn nextToken(text: []const u8, start: usize) ?Token {
    var idx = start;
    while (idx < text.len) {
        if (startsWithLineComment(text, idx)) {
            idx = skipLineComment(text, idx);
            continue;
        }
        if (startsWithBlockComment(text, idx)) {
            idx = skipBlockComment(text, idx);
            continue;
        }
        if (text[idx] == '"' or text[idx] == '\'') {
            idx = skipQuotedLiteral(text, idx);
            continue;
        }
        if (isIdentifierStart(text[idx])) {
            const end_idx = consumeIdentifier(text, idx);
            return .{
                .start_idx = idx,
                .next_idx = end_idx,
                .lexeme = text[idx..end_idx],
            };
        }
        idx += 1;
    }
    return null;
}

fn nextIdentifierToken(text: []const u8, start: usize) ?Token {
    var idx = start;
    while (idx < text.len) {
        if (startsWithLineComment(text, idx)) {
            idx = skipLineComment(text, idx);
            continue;
        }
        if (startsWithBlockComment(text, idx)) {
            idx = skipBlockComment(text, idx);
            continue;
        }
        if (text[idx] == '"' or text[idx] == '\'') {
            idx = skipQuotedLiteral(text, idx);
            continue;
        }
        if (isIdentifierStart(text[idx])) {
            const end_idx = consumeIdentifier(text, idx);
            return .{
                .start_idx = idx,
                .next_idx = end_idx,
                .lexeme = text[idx..end_idx],
            };
        }
        idx += 1;
    }
    return null;
}

fn consumeIdentifier(text: []const u8, start: usize) usize {
    var idx = start + 1;
    while (idx < text.len and isIdentifierContinue(text[idx])) : (idx += 1) {}
    return idx;
}

fn consumeBuiltin(text: []const u8, start: usize) usize {
    var idx = start + 1;
    while (idx < text.len and isIdentifierContinue(text[idx])) : (idx += 1) {}
    return idx;
}

fn consumeNumber(text: []const u8, start: usize) usize {
    var idx = start + 1;
    while (idx < text.len) : (idx += 1) {
        const ch = text[idx];
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '\'' or ch == '+' or ch == '-') continue;
        break;
    }
    return idx;
}

fn startsWithLineComment(text: []const u8, idx: usize) bool {
    return idx + 1 < text.len and text[idx] == '/' and text[idx + 1] == '/';
}

fn startsWithBlockComment(text: []const u8, idx: usize) bool {
    return idx + 1 < text.len and text[idx] == '/' and text[idx + 1] == '*';
}

fn skipLineComment(text: []const u8, start: usize) usize {
    var idx = start + 2;
    while (idx < text.len and text[idx] != '\n') : (idx += 1) {}
    return idx;
}

fn skipBlockComment(text: []const u8, start: usize) usize {
    var idx = start + 2;
    while (idx + 1 < text.len) : (idx += 1) {
        if (text[idx] == '*' and text[idx + 1] == '/') return idx + 2;
    }
    return text.len;
}

fn skipQuotedLiteral(text: []const u8, start: usize) usize {
    const quote = text[start];
    var idx = start + 1;
    while (idx < text.len) : (idx += 1) {
        if (text[idx] == '\\') {
            idx += 1;
            continue;
        }
        if (text[idx] == quote) return idx + 1;
    }
    return text.len;
}

fn isIdentifierStart(ch: u8) bool {
    return ch == '_' or std.ascii.isAlphabetic(ch);
}

fn isIdentifierContinue(ch: u8) bool {
    return ch == '_' or std.ascii.isAlphanumeric(ch);
}

fn isKeyword(ident: []const u8) bool {
    return std.mem.eql(u8, ident, "const") or
        std.mem.eql(u8, ident, "var") or
        std.mem.eql(u8, ident, "if") or
        std.mem.eql(u8, ident, "else") or
        std.mem.eql(u8, ident, "switch") or
        std.mem.eql(u8, ident, "while") or
        std.mem.eql(u8, ident, "for") or
        std.mem.eql(u8, ident, "return") or
        std.mem.eql(u8, ident, "break") or
        std.mem.eql(u8, ident, "continue") or
        std.mem.eql(u8, ident, "defer") or
        std.mem.eql(u8, ident, "errdefer") or
        std.mem.eql(u8, ident, "orelse") or
        std.mem.eql(u8, ident, "catch") or
        std.mem.eql(u8, ident, "and") or
        std.mem.eql(u8, ident, "or") or
        std.mem.eql(u8, ident, "try") or
        std.mem.eql(u8, ident, "pub") or
        std.mem.eql(u8, ident, "inline") or
        std.mem.eql(u8, ident, "comptime");
}

fn lessThanFunctionFingerprint(_: void, lhs: FunctionFingerprint, rhs: FunctionFingerprint) bool {
    const order = std.mem.order(u8, lhs.normalized_body, rhs.normalized_body);
    if (order != .eq) return order == .lt;
    const path_order = std.mem.order(u8, lhs.path, rhs.path);
    if (path_order != .eq) return path_order == .lt;
    return lhs.line < rhs.line;
}

fn lessThanCluster(_: void, lhs: Cluster, rhs: Cluster) bool {
    if (lhs.members.len != rhs.members.len) return lhs.members.len > rhs.members.len;
    if (lhs.normalized_len != rhs.normalized_len) return lhs.normalized_len > rhs.normalized_len;
    if (lhs.body_hash != rhs.body_hash) return lhs.body_hash < rhs.body_hash;
    return std.mem.order(u8, lhs.members[0].path, rhs.members[0].path) == .lt;
}

pub fn bodyHash(normalized_body: []const u8) u64 {
    return std.hash.Wyhash.hash(0, normalized_body);
}

test "normalizes renamed duplicate bodies to the same fingerprint" {
    const lhs =
        "{\n" ++
        "    const local_value = input + 1;\n" ++
        "    return local_value;\n" ++
        "}\n";
    const rhs =
        "{\n" ++
        "    const other = source + 7;\n" ++
        "    return other;\n" ++
        "}\n";

    const lhs_norm = try normalizeBody(std.testing.allocator, lhs);
    defer std.testing.allocator.free(lhs_norm);
    const rhs_norm = try normalizeBody(std.testing.allocator, rhs);
    defer std.testing.allocator.free(rhs_norm);

    try std.testing.expectEqualStrings(lhs_norm, rhs_norm);
}

test "finds duplicate clusters across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/a");
    try tmp.dir.makePath("src/b");
    try tmp.dir.writeFile(.{
        .sub_path = "src/a/one.zig",
        .data =
            "fn alpha(x: i32) i32 {\n" ++
            "    const value = x + 1;\n" ++
            "    return value;\n" ++
            "}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "src/b/two.zig",
        .data =
            "fn beta(y: i32) i32 {\n" ++
            "    const other = y + 2;\n" ++
            "    return other;\n" ++
            "}\n",
    });

    const real_src = try tmp.dir.realpathAlloc(std.testing.allocator, "src");
    defer std.testing.allocator.free(real_src);

    const clusters = try findDuplicateClusters(std.testing.allocator, real_src, 1);
    defer {
        for (clusters) |*cluster| cluster.deinit(std.testing.allocator);
        std.testing.allocator.free(clusters);
    }

    try std.testing.expect(clusters.len >= 1);
    try std.testing.expectEqual(@as(usize, 2), clusters[0].members.len);
}

test "AST mode finds duplicate clusters across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/a");
    try tmp.dir.makePath("src/b");
    try tmp.dir.writeFile(.{
        .sub_path = "src/a/one.zig",
        .data =
            "fn alpha(x: i32) i32 {\n" ++
            "    const value = x + 1;\n" ++
            "    return value;\n" ++
            "}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "src/b/two.zig",
        .data =
            "fn beta(y: i32) i32 {\n" ++
            "    const other = y + 7;\n" ++
            "    return other;\n" ++
            "}\n",
    });

    const real_src = try tmp.dir.realpathAlloc(std.testing.allocator, "src");
    defer std.testing.allocator.free(real_src);

    const clusters = try findDuplicateClustersWithMode(std.testing.allocator, real_src, 1, .ast);
    defer {
        for (clusters) |*cluster| cluster.deinit(std.testing.allocator);
        std.testing.allocator.free(clusters);
    }

    try std.testing.expect(clusters.len >= 1);
    try std.testing.expectEqual(@as(usize, 2), clusters[0].members.len);
}
