const std = @import("std");

pub const FunctionCall = struct {
    name: []const u8,
    path: []const u8,
    start_idx: usize,
};

pub const FunctionDefinition = struct {
    name: []const u8,
    start_idx: usize,
};

pub const SymbolAlias = struct {
    name: []const u8,
    path: []const u8,
    start_idx: usize,
};

pub const MemberAccess = struct {
    path: []const u8,
    start_idx: usize,
};

pub const Index = struct {
    function_calls: std.ArrayListUnmanaged(FunctionCall) = .empty,
    function_definitions: std.ArrayListUnmanaged(FunctionDefinition) = .empty,
    symbol_aliases: std.ArrayListUnmanaged(SymbolAlias) = .empty,
    member_accesses: std.ArrayListUnmanaged(MemberAccess) = .empty,
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.function_calls.deinit(allocator);
        self.function_definitions.deinit(allocator);
        self.symbol_aliases.deinit(allocator);
        self.member_accesses.deinit(allocator);
        for (self.owned_strings.items) |value| allocator.free(value);
        self.owned_strings.deinit(allocator);
        self.* = .{};
    }

    pub fn findFunctionCall(self: Index, symbol_name: []const u8) ?usize {
        for (self.function_calls.items) |call| {
            if (std.mem.eql(u8, call.name, symbol_name)) return call.start_idx;
        }
        return null;
    }

    pub fn findFunctionCallOutsidePath(self: Index, symbol_name: []const u8, required_path: []const u8) ?usize {
        for (self.function_calls.items) |call| {
            if (!std.mem.eql(u8, call.name, symbol_name)) continue;
            if (!std.mem.eql(u8, call.path, required_path)) return call.start_idx;
        }
        return null;
    }

    pub fn findAliasOutsidePath(self: Index, symbol_name: []const u8, required_path: []const u8) ?usize {
        for (self.symbol_aliases.items) |alias| {
            if (!std.mem.eql(u8, alias.name, symbol_name)) continue;
            if (!std.mem.eql(u8, alias.path, required_path)) return alias.start_idx;
        }
        return null;
    }

    pub fn findAnyAlias(self: Index, symbol_name: []const u8) ?usize {
        for (self.symbol_aliases.items) |alias| {
            if (std.mem.eql(u8, alias.name, symbol_name)) return alias.start_idx;
        }
        return null;
    }

    pub fn findFirstSymbolUse(self: Index, symbol_name: []const u8) ?usize {
        const call_idx = self.findFunctionCall(symbol_name);
        const alias_idx = self.findAnyAlias(symbol_name);
        return switch (call_idx != null) {
            true => switch (alias_idx != null) {
                true => @min(call_idx.?, alias_idx.?),
                false => call_idx.?,
            },
            false => alias_idx,
        };
    }

    pub fn findMemberAccessPath(self: Index, needle: []const u8) ?usize {
        for (self.member_accesses.items) |access| {
            if (matchesMemberAccessNeedle(access.path, needle)) return access.start_idx;
        }
        return null;
    }
};

pub fn buildIndex(allocator: std.mem.Allocator, text: []const u8) !Index {
    var out: Index = .{};
    errdefer out.deinit(allocator);

    var idx: usize = 0;
    var expect_fn_name = false;
    var expect_binding_name = false;

    while (idx < text.len) {
        if (text[idx] == '/' and idx + 1 < text.len and text[idx + 1] == '/') {
            idx += 2;
            while (idx < text.len and text[idx] != '\n') : (idx += 1) {}
            continue;
        }
        if (text[idx] == '"' or text[idx] == '\'') {
            idx = skipQuotedLiteral(text, idx);
            continue;
        }
        if (!isIdentifierStart(text[idx])) {
            if (!std.ascii.isWhitespace(text[idx]) and text[idx] != '.' and !expect_fn_name) expect_binding_name = false;
            idx += 1;
            continue;
        }

        const start_idx = idx;
        idx += 1;
        while (idx < text.len and isIdentifierContinue(text[idx])) : (idx += 1) {}
        const ident = text[start_idx..idx];

        const access = try parseAccessPath(allocator, &out, text, ident, start_idx, idx);
        idx = access.cursor;
        const next_idx = skipWhitespace(text, idx);

        if (std.mem.eql(u8, ident, "pub")) continue;
        if (std.mem.eql(u8, ident, "fn")) {
            expect_fn_name = true;
            continue;
        }
        if (std.mem.eql(u8, ident, "const") or std.mem.eql(u8, ident, "var")) {
            expect_binding_name = true;
            continue;
        }
        if (expect_fn_name) {
            if (next_idx < text.len and text[next_idx] == '(') {
                try out.function_definitions.append(allocator, .{
                    .name = ident,
                    .start_idx = start_idx,
                });
            }
            expect_fn_name = false;
            continue;
        }
        if (expect_binding_name) {
            try maybeAppendAlias(allocator, &out, text, ident, start_idx, idx);
            expect_binding_name = false;
            continue;
        }

        if (isCallLikeKeyword(ident)) continue;
        if (next_idx < text.len and text[next_idx] == '(') {
            const call_name = lastPathSegment(access.path);
            try out.function_calls.append(allocator, .{
                .name = call_name,
                .path = access.path,
                .start_idx = start_idx,
            });
        }
    }

    return out;
}

fn maybeAppendAlias(
    allocator: std.mem.Allocator,
    out: *Index,
    text: []const u8,
    alias_name: []const u8,
    alias_start_idx: usize,
    alias_cursor: usize,
) !void {
    const equals_idx = skipWhitespace(text, alias_cursor);
    if (equals_idx >= text.len or text[equals_idx] != '=') return;

    const rhs_start = skipWhitespace(text, equals_idx + 1);
    if (rhs_start >= text.len or !isIdentifierStart(text[rhs_start])) return;

    var rhs_end = rhs_start + 1;
    while (rhs_end < text.len and isIdentifierContinue(text[rhs_end])) : (rhs_end += 1) {}
    const rhs_head = text[rhs_start..rhs_end];
    const access = try parseAccessPath(allocator, out, text, rhs_head, rhs_start, rhs_end);
    const terminator_idx = skipWhitespace(text, access.cursor);
    if (terminator_idx >= text.len or text[terminator_idx] != ';') return;

    try out.symbol_aliases.append(allocator, .{
        .name = alias_name,
        .path = access.path,
        .start_idx = alias_start_idx,
    });
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var idx = start;
    while (idx < text.len and std.ascii.isWhitespace(text[idx])) : (idx += 1) {}
    return idx;
}

fn isIdentifierStart(ch: u8) bool {
    return ch == '_' or std.ascii.isAlphabetic(ch);
}

fn isIdentifierContinue(ch: u8) bool {
    return ch == '_' or std.ascii.isAlphanumeric(ch);
}

fn isCallLikeKeyword(ident: []const u8) bool {
    return std.mem.eql(u8, ident, "if") or
        std.mem.eql(u8, ident, "while") or
        std.mem.eql(u8, ident, "for") or
        std.mem.eql(u8, ident, "switch") or
        std.mem.eql(u8, ident, "catch") or
        std.mem.eql(u8, ident, "orelse");
}

const AccessPath = struct {
    path: []const u8,
    cursor: usize,
};

fn parseAccessPath(
    allocator: std.mem.Allocator,
    out: *Index,
    text: []const u8,
    head: []const u8,
    start_idx: usize,
    cursor_start: usize,
) !AccessPath {
    var cursor = cursor_start;
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    var saw_dot = false;
    try builder.appendSlice(allocator, head);

    while (true) {
        const dot_idx = skipWhitespace(text, cursor);
        if (dot_idx >= text.len or text[dot_idx] != '.') break;

        const ident_start = skipWhitespace(text, dot_idx + 1);
        if (ident_start >= text.len or !isIdentifierStart(text[ident_start])) break;

        var ident_end = ident_start + 1;
        while (ident_end < text.len and isIdentifierContinue(text[ident_end])) : (ident_end += 1) {}

        saw_dot = true;
        try builder.append(allocator, '.');
        try builder.appendSlice(allocator, text[ident_start..ident_end]);
        cursor = ident_end;
    }

    if (saw_dot) {
        const owned = try builder.toOwnedSlice(allocator);
        try out.owned_strings.append(allocator, owned);
        try out.member_accesses.append(allocator, .{
            .path = owned,
            .start_idx = start_idx,
        });
        return .{
            .path = owned,
            .cursor = cursor,
        };
    }
    return .{
        .path = head,
        .cursor = cursor,
    };
}

fn matchesMemberAccessNeedle(path: []const u8, needle: []const u8) bool {
    if (!std.mem.startsWith(u8, path, needle)) return false;
    return path.len == needle.len or path[needle.len] == '.';
}

fn lastPathSegment(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return path;
    return path[dot + 1 ..];
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

test "builds function definition and call index" {
    const text =
        "pub fn keep() void {}\n" ++
        "fn local() void { helper(); mod.legacy(); if (cond) other(); }\n";
    var index = try buildIndex(std.testing.allocator, text);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), index.function_definitions.items.len);
    try std.testing.expect(index.findFunctionCall("helper") != null);
    try std.testing.expect(index.findFunctionCall("legacy") != null);
    try std.testing.expect(index.findFunctionCallOutsidePath("legacy", "mod.legacy") == null);
    try std.testing.expect(index.findFunctionCall("if") == null);
    try std.testing.expect(index.findMemberAccessPath("mod.legacy") != null);
}

test "ignores comments and string literals" {
    const text =
        "// emitWriteFormatted()\n" ++
        "const s = \"emitReadFormatted()\";\n" ++
        "realCall();\n";
    var index = try buildIndex(std.testing.allocator, text);
    defer index.deinit(std.testing.allocator);

    try std.testing.expect(index.findFunctionCall("emitWriteFormatted") == null);
    try std.testing.expect(index.findFunctionCall("emitReadFormatted") == null);
    try std.testing.expect(index.findFunctionCall("realCall") != null);
}

test "indexes member access chains with boundary-aware matching" {
    const text =
        "const x = sym.compat.type_kind;\n" ++
        "const y = sym.char_len_kind;\n";
    var index = try buildIndex(std.testing.allocator, text);
    defer index.deinit(std.testing.allocator);

    try std.testing.expect(index.findMemberAccessPath("sym.compat") != null);
    try std.testing.expect(index.findMemberAccessPath("sym.compat.type_kind") != null);
    try std.testing.expect(index.findMemberAccessPath("sym.char_len") == null);
    try std.testing.expect(index.findMemberAccessPath("sym.char_len_kind") != null);
}

test "tracks qualified function call paths" {
    const text =
        "fn run() void {\n" ++
        "    shared.runtimeArgCount(arg_count);\n" ++
        "    runtimeArgCount(arg_count);\n" ++
        "}\n";
    var index = try buildIndex(std.testing.allocator, text);
    defer index.deinit(std.testing.allocator);

    try std.testing.expect(index.findFunctionCallOutsidePath("runtimeArgCount", "shared.runtimeArgCount") != null);
    try std.testing.expect(index.findFunctionCallOutsidePath("runtimeArgCount", "runtimeArgCount") != null);
}

test "tracks symbol alias bindings" {
    const text =
        "const runtimeArgCount = shared.runtimeArgCount;\n" ++
        "pub const offsetBytes = shared.offsetBytes;\n" ++
        "const ignored_import = @import(\"shared.zig\");\n";
    var index = try buildIndex(std.testing.allocator, text);
    defer index.deinit(std.testing.allocator);

    try std.testing.expect(index.findAliasOutsidePath("runtimeArgCount", "shared.runtimeArgCount") == null);
    try std.testing.expect(index.findAliasOutsidePath("offsetBytes", "shared.offsetBytes") == null);
    try std.testing.expect(index.findAliasOutsidePath("runtimeArgCount", "runtimeArgCount") != null);
    try std.testing.expectEqual(@as(usize, 2), index.symbol_aliases.items.len);
}
