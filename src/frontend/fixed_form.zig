const std = @import("std");
const logical_line = @import("logical_line.zig");

pub const Segment = logical_line.Segment;
pub const LogicalLine = logical_line.LogicalLine;
pub const mapIndexToPos = logical_line.mapIndexToPos;
pub const mapIndexToPosExclusive = logical_line.mapIndexToPosExclusive;

pub fn normalizeFixedForm(allocator: std.mem.Allocator, contents: []const u8) ![]LogicalLine {
    return normalizeFixedFormWithMapMode(allocator, contents, false);
}

pub fn normalizeFixedFormWithMapMode(
    allocator: std.mem.Allocator,
    contents: []const u8,
    coarse_source_map: bool,
) ![]LogicalLine {
    var list = std.array_list.Managed(LogicalLine).init(allocator);
    var buffer = std.array_list.Managed(u8).init(allocator);
    var segments = std.array_list.Managed(Segment).init(allocator);
    defer buffer.deinit();
    defer segments.deinit();
    var current_label: ?[]const u8 = null;
    var current_start: usize = 0;
    var current_end: usize = 0;
    var in_stmt = false;
    var string_state = StringState{};

    var it = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (it.next()) |raw_line| : (line_no += 1) {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        if (isCommentLine(line)) {
            continue;
        }

        const layout = lineLayout(line);
        var line_string_state = if (layout.is_cont and in_stmt) string_state else StringState{};
        const prepared = prepareCodeField(line, layout, &line_string_state);
        const code = prepared.bytes[0..prepared.len];
        const trimmed_code = std.mem.trimEnd(u8, code, " \t");

        if (trimmed_code.len == 0 and !layout.is_cont) {
            if (in_stmt) {
                const text_owned = try makeTextOwned(allocator, &buffer);
                const segments_owned = try makeSegmentsOwned(
                    allocator,
                    &segments,
                    coarse_source_map,
                    current_start,
                    text_owned.len,
                );
                try list.append(.{
                    .label = current_label,
                    .text = text_owned,
                    .span = .{ .start_line = current_start, .end_line = current_end },
                    .segments = segments_owned,
                });
                in_stmt = false;
                current_label = null;
                string_state = .{};
            }
            continue;
        }

        if (!layout.is_cont or !in_stmt) {
            if (in_stmt) {
                const text_owned = try makeTextOwned(allocator, &buffer);
                const segments_owned = try makeSegmentsOwned(
                    allocator,
                    &segments,
                    coarse_source_map,
                    current_start,
                    text_owned.len,
                );
                try list.append(.{
                    .label = current_label,
                    .text = text_owned,
                    .span = .{ .start_line = current_start, .end_line = current_end },
                    .segments = segments_owned,
                });
            }
            const label = try parseLabel(allocator, line);
            current_start = line_no;
            current_end = line_no;
            current_label = label;
            in_stmt = true;
            string_state = .{};
        } else {
            current_end = line_no;
        }

        if (code.len > 0 and (trimmed_code.len > 0 or layout.is_cont)) {
            try buffer.appendSlice(code);
            if (!coarse_source_map) {
                try segments.append(.{
                    .line = line_no,
                    .column = layout.code_column,
                    .length = code.len,
                });
            }
        }
        string_state = line_string_state;
    }

    if (in_stmt) {
        const text_owned = try makeTextOwned(allocator, &buffer);
        const segments_owned = try makeSegmentsOwned(
            allocator,
            &segments,
            coarse_source_map,
            current_start,
            text_owned.len,
        );
        try list.append(.{
            .label = current_label,
            .text = text_owned,
            .span = .{ .start_line = current_start, .end_line = current_end },
            .segments = segments_owned,
        });
    }

    return list.toOwnedSlice();
}

fn makeTextOwned(allocator: std.mem.Allocator, buffer: *std.array_list.Managed(u8)) ![]u8 {
    const out = try allocator.alloc(u8, buffer.items.len);
    @memcpy(out, buffer.items);
    buffer.clearRetainingCapacity();
    return out;
}

fn makeSegmentsOwned(
    allocator: std.mem.Allocator,
    segments: *std.array_list.Managed(Segment),
    coarse_source_map: bool,
    start_line: usize,
    text_len: usize,
) ![]Segment {
    if (!coarse_source_map) {
        const out = try allocator.alloc(Segment, segments.items.len);
        @memcpy(out, segments.items);
        segments.clearRetainingCapacity();
        return out;
    }

    segments.clearRetainingCapacity();
    const out = try allocator.alloc(Segment, 1);
    out[0] = .{
        .line = start_line,
        .column = 1,
        .length = text_len,
    };
    return out;
}

pub fn freeLogicalLines(allocator: std.mem.Allocator, lines: []LogicalLine) void {
    logical_line.freeLogicalLines(allocator, lines);
}

fn isCommentLine(line: []const u8) bool {
    if (line.len == 0) return false;
    return line[0] == 'c' or line[0] == 'C' or line[0] == '*' or line[0] == '!';
}

const StringState = struct {
    in_single: bool = false,
    in_double: bool = false,
    hollerith_remaining: usize = 0,
};

const LineLayout = struct {
    is_cont: bool,
    has_label_area: bool,
    code_start: usize,
    code_column: usize,
};

const PreparedCode = struct {
    bytes: [66]u8,
    len: usize,
};

fn lineLayout(line: []const u8) LineLayout {
    if (line.len > 0 and line[0] == '\t') {
        if (line.len >= 2 and line[1] >= '1' and line[1] <= '9') {
            return .{
                .is_cont = true,
                .has_label_area = false,
                .code_start = 2,
                .code_column = 7,
            };
        }
        return .{
            .is_cont = false,
            .has_label_area = false,
            .code_start = 1,
            .code_column = 7,
        };
    }

    if (line.len >= 6) {
        const mark = line[5];
        if (mark != ' ' and mark != '0') {
            return .{
                .is_cont = true,
                .has_label_area = true,
                .code_start = 6,
                .code_column = 7,
            };
        }
    }

    // Compatibility extension for legacy sources where continuation marker is
    // shifted right by one or two columns.
    if (line.len >= 7 and line[0] == ' ' and line[1] == ' ' and line[2] == ' ' and line[3] == ' ' and line[4] == ' ' and line[5] == ' ') {
        const mark = line[6];
        if (mark >= '1' and mark <= '9' and (line.len == 7 or line[7] == ' ' or line[7] == '\t')) {
            return .{
                .is_cont = true,
                .has_label_area = true,
                .code_start = 7,
                .code_column = 8,
            };
        }
    }
    if (line.len >= 8 and line[0] == ' ' and line[1] == ' ' and line[2] == ' ' and line[3] == ' ' and line[4] == ' ' and line[5] == ' ' and line[6] == ' ') {
        const mark = line[7];
        if (mark >= '1' and mark <= '9' and (line.len == 8 or line[8] == ' ' or line[8] == '\t')) {
            return .{
                .is_cont = true,
                .has_label_area = true,
                .code_start = 8,
                .code_column = 9,
            };
        }
    }

    return .{
        .is_cont = false,
        .has_label_area = true,
        .code_start = 6,
        .code_column = 7,
    };
}

fn parseLabel(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const layout = lineLayout(line);
    if (!layout.has_label_area) return null;

    const end = if (line.len < 5) line.len else 5;

    var compact_buf: [5]u8 = undefined;
    var compact_len: usize = 0;
    var idx: usize = 0;
    while (idx < end) : (idx += 1) {
        const ch = line[idx];
        if (ch == ' ' or ch == '\t') continue;
        compact_buf[compact_len] = ch;
        compact_len += 1;
    }
    if (compact_len == 0) return null;

    var all_digits = true;
    var i: usize = 0;
    while (i < compact_len) : (i += 1) {
        const ch = compact_buf[i];
        if (!std.ascii.isDigit(ch)) {
            all_digits = false;
            break;
        }
    }

    var start: usize = 0;
    if (all_digits) {
        while (start < compact_len and compact_buf[start] == '0') : (start += 1) {}
        if (start == compact_len) {
            compact_buf[0] = '0';
            compact_len = 1;
            start = 0;
        }
    }

    const out_len = compact_len - start;
    const owned = try allocator.alloc(u8, out_len);
    @memcpy(owned, compact_buf[start..compact_len]);
    return owned;
}

fn prepareCodeField(line: []const u8, layout: LineLayout, string_state: *StringState) PreparedCode {
    var out: PreparedCode = .{
        .bytes = undefined,
        .len = 0,
    };
    const field_width = 72 - layout.code_column + 1;
    const preserve_trailing_blanks = string_state.in_single or string_state.in_double;

    var src_idx = layout.code_start;
    while (src_idx < line.len and out.len < field_width) : (src_idx += 1) {
        const ch = line[src_idx];
        if (string_state.hollerith_remaining != 0) {
            out.bytes[out.len] = ch;
            out.len += 1;
            string_state.hollerith_remaining -= 1;
            continue;
        }
        if (string_state.in_single) {
            out.bytes[out.len] = ch;
            out.len += 1;
            if (ch == '\'') {
                if (src_idx + 1 < line.len and line[src_idx + 1] == '\'' and out.len < field_width) {
                    out.bytes[out.len] = line[src_idx + 1];
                    out.len += 1;
                    src_idx += 1;
                    continue;
                }
                string_state.in_single = false;
            }
            continue;
        }
        if (string_state.in_double) {
            out.bytes[out.len] = ch;
            out.len += 1;
            if (ch == '"') {
                if (src_idx + 1 < line.len and line[src_idx + 1] == '"' and out.len < field_width) {
                    out.bytes[out.len] = line[src_idx + 1];
                    out.len += 1;
                    src_idx += 1;
                    continue;
                }
                string_state.in_double = false;
            }
            continue;
        }

        if (std.ascii.isDigit(ch)) {
            var digit_end = src_idx;
            while (digit_end < line.len and digit_end - layout.code_start < field_width and std.ascii.isDigit(line[digit_end])) : (digit_end += 1) {}
            if (digit_end < line.len and digit_end - layout.code_start < field_width and (line[digit_end] == 'H' or line[digit_end] == 'h')) {
                var hollerith_len: usize = 0;
                var parse_ok = true;
                var digit_idx = src_idx;
                while (digit_idx < digit_end) : (digit_idx += 1) {
                    hollerith_len = std.math.mul(usize, hollerith_len, 10) catch {
                        parse_ok = false;
                        break;
                    };
                    hollerith_len = std.math.add(usize, hollerith_len, @as(usize, line[digit_idx] - '0')) catch {
                        parse_ok = false;
                        break;
                    };
                }
                if (parse_ok) {
                    var copy_idx = src_idx;
                    while (copy_idx <= digit_end and out.len < field_width) : (copy_idx += 1) {
                        out.bytes[out.len] = line[copy_idx];
                        out.len += 1;
                    }
                    string_state.hollerith_remaining = hollerith_len;
                    src_idx = digit_end;
                    continue;
                }
            }
        }

        if (ch == '!') break;

        out.bytes[out.len] = ch;
        out.len += 1;
        if (ch == '\'') {
            string_state.in_single = true;
        } else if (ch == '"') {
            string_state.in_double = true;
        }
    }

    if (preserve_trailing_blanks or string_state.in_single or string_state.in_double or string_state.hollerith_remaining != 0) {
        while (out.len < field_width and (preserve_trailing_blanks or string_state.in_single or string_state.in_double or string_state.hollerith_remaining != 0)) {
            out.bytes[out.len] = ' ';
            out.len += 1;
            if (string_state.hollerith_remaining != 0) {
                string_state.hollerith_remaining -= 1;
            }
        }
    }

    return out;
}

test "normalizeFixedForm joins continuations and preserves labels" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const src_text =
        "      A=1\n" ++
        "     +B=2\n" ++
        "C comment\n" ++
        "      \n" ++
        "  10  CONTINUE\n";
    const lines = try normalizeFixedForm(allocator, src_text);
    defer freeLogicalLines(allocator, lines);

    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expect(lines[0].label == null);
    try testing.expectEqualStrings("A=1B=2", lines[0].text);
    try testing.expectEqual(@as(usize, 1), lines[0].span.start_line);
    try testing.expectEqual(@as(usize, 2), lines[0].span.end_line);
    try testing.expectEqual(@as(usize, 2), lines[0].segments.len);
    try testing.expectEqual(@as(usize, 1), lines[0].segments[0].line);
    try testing.expectEqual(@as(usize, 7), lines[0].segments[0].column);
    try testing.expectEqual(@as(usize, 3), lines[0].segments[0].length);
    try testing.expectEqual(@as(usize, 2), lines[0].segments[1].line);
    try testing.expectEqual(@as(usize, 7), lines[0].segments[1].column);
    try testing.expectEqual(@as(usize, 3), lines[0].segments[1].length);

    try testing.expectEqualStrings("10", lines[1].label.?);
    try testing.expectEqualStrings("CONTINUE", lines[1].text);
    try testing.expectEqual(@as(usize, 5), lines[1].span.start_line);
    try testing.expectEqual(@as(usize, 5), lines[1].span.end_line);
}

test "normalizeFixedForm supports continuation marker in column 7" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const src_text =
        "       DIMENSION A(10)\n" ++
        "      1 ,B(10)\n";
    const lines = try normalizeFixedForm(allocator, src_text);
    defer freeLogicalLines(allocator, lines);

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings(" DIMENSION A(10),B(10)", lines[0].text);
}

test "normalizeFixedForm supports continuation marker in column 8" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const src_text =
        "       FORMAT('A'\n" ++
        "       1 ,'B')\n";
    const lines = try normalizeFixedForm(allocator, src_text);
    defer freeLogicalLines(allocator, lines);

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings(" FORMAT('A','B')", lines[0].text);
}

test "normalizeFixedForm preserves implicit blanks for continued string literals" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const src_text =
        "      PRINT *, 'HELLO\n" ++
        "     +WORLD'\n";
    const lines = try normalizeFixedForm(allocator, src_text);
    defer freeLogicalLines(allocator, lines);

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(@as(usize, 132), lines[0].text.len);
    try testing.expectEqualStrings("PRINT *, 'HELLO", lines[0].text[0..15]);
    try testing.expectEqualStrings("WORLD'", lines[0].text[66..72]);
}

test "normalizeFixedForm supports tab-format statement and continuation lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const src_text =
        "\tA=1\n" ++
        "\t1+2\n";
    const lines = try normalizeFixedForm(allocator, src_text);
    defer freeLogicalLines(allocator, lines);

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expect(lines[0].label == null);
    try testing.expectEqualStrings("A=1+2", lines[0].text);
    try testing.expectEqual(@as(usize, 7), lines[0].segments[0].column);
    try testing.expectEqual(@as(usize, 7), lines[0].segments[1].column);
}

test "normalizeFixedForm strips inline bang comments outside strings" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const src_text =
        "      A = 1 ! Initialize A\n" ++
        "      B = '! still string' ! trailing comment\n";
    const lines = try normalizeFixedForm(allocator, src_text);
    defer freeLogicalLines(allocator, lines);

    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("A = 1", lines[0].text);
    try testing.expectEqualStrings("B = '! still string'", lines[1].text);
}

test "normalizeFixedForm keeps bang inside Hollerith literal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const src_text = "70090 FORMAT(27H!FIRST PRINT LINE!     OVER)\n";
    const lines = try normalizeFixedForm(allocator, src_text);
    defer freeLogicalLines(allocator, lines);

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("70090", lines[0].label.?);
    try testing.expectEqualStrings("FORMAT(27H!FIRST PRINT LINE!     OVER)", lines[0].text);
}
