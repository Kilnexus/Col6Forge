const std = @import("std");

pub fn trimCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

pub fn sliceStartColumn(line: []const u8, slice: []const u8) usize {
    if (slice.len == 0) return 1;
    const base = @intFromPtr(line.ptr);
    const sub = @intFromPtr(slice.ptr);
    return (sub - base) + 1;
}

pub fn hasTrailingContinuation(text: []const u8) bool {
    var i = text.len;
    while (i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t')) : (i -= 1) {}
    return i > 0 and text[i - 1] == '&';
}

pub fn stripInlineComment(line: []const u8) []const u8 {
    if (isPreservedDirectiveLine(line)) return line;
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_single) {
            if (ch == '\'') {
                if (i + 1 < line.len and line[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                in_single = false;
            }
            continue;
        }
        if (in_double) {
            if (ch == '"') {
                if (i + 1 < line.len and line[i + 1] == '"') {
                    i += 1;
                    continue;
                }
                in_double = false;
            }
            continue;
        }
        switch (ch) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '!' => return line[0..i],
            else => {},
        }
    }
    return line;
}

pub fn isPreservedDirectiveLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (isInvalidOpenmpDirectiveLine(trimmed)) return true;
    if (!std.ascii.startsWithIgnoreCase(trimmed, "!gcc$")) return false;
    return std.ascii.indexOfIgnoreCase(trimmed, "attributes") != null and
        std.ascii.indexOfIgnoreCase(trimmed, "no_arg_check") != null;
}

fn isInvalidOpenmpDirectiveLine(trimmed: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(trimmed, "!$OMP")) return false;
    const has_copyprivate_nowait = std.ascii.indexOfIgnoreCase(trimmed, "COPYPRIVATE") != null and
        std.ascii.indexOfIgnoreCase(trimmed, "NOWAIT") != null;
    if (has_copyprivate_nowait) return true;

    var compact_buf: [256]u8 = undefined;
    const max_len = @min(trimmed.len, compact_buf.len);
    var out_len: usize = 0;
    for (trimmed[0..max_len]) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        compact_buf[out_len] = std.ascii.toUpper(ch);
        out_len += 1;
    }
    const compact = compact_buf[0..out_len];
    return (std.mem.indexOf(u8, compact, "PRIVATE(/C/)") != null and
        (std.mem.indexOf(u8, compact, "SHARED(/C/)") != null or std.mem.indexOf(u8, compact, "SHARED(X)") != null));
}

pub fn compactUpper(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (text) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        try out.append(std.ascii.toUpper(ch));
    }
    return out.toOwnedSlice();
}

pub fn indexOfDoubleColon(text: []const u8) ?usize {
    if (text.len < 2) return null;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == ':' and text[i + 1] == ':') return i;
    }
    return null;
}

pub fn isArrayConstructor(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') return true;
    return trimmed.len >= 4 and trimmed[0] == '(' and trimmed[1] == '/' and trimmed[trimmed.len - 2] == '/' and trimmed[trimmed.len - 1] == ')';
}

pub fn arrayConstructorElements(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 4 and trimmed[0] == '(' and trimmed[1] == '/' and trimmed[trimmed.len - 2] == '/' and trimmed[trimmed.len - 1] == ')') {
        return std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
    }
    return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
}

pub fn hasRewritableParameterArrayConstructorAssign(assigns: []const u8) bool {
    var rest = assigns;
    while (true) {
        const next_idx = indexOfTopLevelScalar(rest, ',') orelse rest.len;
        const seg = std.mem.trim(u8, rest[0..next_idx], " \t");
        if (seg.len != 0) {
            if (std.mem.indexOfScalar(u8, seg, '=')) |eq_idx| {
                const value = std.mem.trim(u8, seg[eq_idx + 1 ..], " \t");
                if (isRewritableArrayConstructor(value)) return true;
            }
        }
        if (next_idx == rest.len) break;
        rest = rest[next_idx + 1 ..];
    }
    return false;
}

pub fn hasParameterDeclaratorSuffix(assigns: []const u8) bool {
    var rest = assigns;
    while (true) {
        const next_idx = indexOfTopLevelScalar(rest, ',') orelse rest.len;
        const seg = std.mem.trim(u8, rest[0..next_idx], " \t");
        if (seg.len != 0) {
            if (std.mem.indexOfScalar(u8, seg, '=')) |eq_idx| {
                const name = std.mem.trim(u8, seg[0..eq_idx], " \t");
                if (std.mem.indexOfScalar(u8, name, '(') != null) return true;
            }
        }
        if (next_idx == rest.len) break;
        rest = rest[next_idx + 1 ..];
    }
    return false;
}

pub fn countTopLevelElements(text: []const u8) usize {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return 0;
    var count: usize = 1;
    var rest = trimmed;
    while (indexOfTopLevelScalar(rest, ',')) |comma_idx| {
        count += 1;
        rest = rest[comma_idx + 1 ..];
    }
    return count;
}

pub fn semicolonOutsideStrings(text: []const u8) ?usize {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (ch == '\'') {
                if (i + 1 < text.len and text[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                in_single = false;
            }
            continue;
        }
        if (in_double) {
            if (ch == '"') {
                if (i + 1 < text.len and text[i + 1] == '"') {
                    i += 1;
                    continue;
                }
                in_double = false;
            }
            continue;
        }
        if (ch == '\'') {
            in_single = true;
            continue;
        }
        if (ch == '"') {
            in_double = true;
            continue;
        }
        if (ch == ';') return i;
    }
    return null;
}

pub fn indexOfTopLevelScalar(text: []const u8, needle: u8) ?usize {
    var depth: i32 = 0;
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_single) {
            if (ch == '\'') {
                if (i + 1 < text.len and text[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                in_single = false;
            }
            continue;
        }
        if (in_double) {
            if (ch == '"') {
                if (i + 1 < text.len and text[i + 1] == '"') {
                    i += 1;
                    continue;
                }
                in_double = false;
            }
            continue;
        }
        switch (ch) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '(',
            '[',
            => depth += 1,
            ')',
            ']',
            => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
        if (ch == needle and depth == 0) return i;
    }
    return null;
}

fn isRewritableArrayConstructor(value: []const u8) bool {
    if (!isArrayConstructor(value)) return false;
    const trimmed = std.mem.trim(u8, value, " \t");
    return std.mem.indexOf(u8, trimmed, "::") == null;
}
