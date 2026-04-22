const std = @import("std");
const logical_line = @import("../logical_line.zig");
const mapped_text = @import("mapped_text.zig");
const predicates = @import("predicates.zig");
const parameters = @import("parameters.zig");
const rewrite = @import("rewrite.zig");

pub const Segment = logical_line.Segment;
pub const LogicalLine = logical_line.LogicalLine;

const KindState = parameters.KindState;

pub fn normalizeFreeFormWithMapMode(
    allocator: std.mem.Allocator,
    contents: []const u8,
    coarse_source_map: bool,
) ![]LogicalLine {
    var list = std.array_list.Managed(LogicalLine).init(allocator);
    var buffer = std.array_list.Managed(u8).init(allocator);
    var segments = std.array_list.Managed(Segment).init(allocator);
    var kind_state: KindState = .unknown;
    defer buffer.deinit();
    defer segments.deinit();

    var in_stmt = false;
    var continued = false;
    var stmt_start: usize = 0;
    var stmt_end: usize = 0;

    var it = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (it.next()) |raw_line| : (line_no += 1) {
        const line = predicates.trimCr(raw_line);
        const code_no_comment = predicates.stripInlineComment(line);
        const trimmed = std.mem.trim(u8, code_no_comment, " \t");

        if (trimmed.len == 0) {
            if (in_stmt and !continued) {
                try flushLogicalLine(allocator, &list, &buffer, &segments, stmt_start, stmt_end, coarse_source_map, &kind_state);
                in_stmt = false;
            }
            continue;
        }

        var part = trimmed;
        if (continued and part.len > 0 and part[0] == '&') {
            part = std.mem.trimStart(u8, part[1..], " \t");
        }

        const cont = predicates.hasTrailingContinuation(part);
        if (cont) {
            var end = part.len;
            while (end > 0 and (part[end - 1] == ' ' or part[end - 1] == '\t')) : (end -= 1) {}
            if (end > 0 and part[end - 1] == '&') {
                end -= 1;
                while (end > 0 and (part[end - 1] == ' ' or part[end - 1] == '\t')) : (end -= 1) {}
            }
            part = part[0..end];
        }

        if (!in_stmt) {
            in_stmt = true;
            stmt_start = line_no;
            stmt_end = line_no;
        } else {
            stmt_end = line_no;
        }

        if (part.len > 0) {
            try buffer.appendSlice(part);
            if (!coarse_source_map) {
                try segments.append(.{
                    .line = line_no,
                    .column = predicates.sliceStartColumn(line, part),
                    .length = part.len,
                });
            }
        }

        continued = cont;
        if (!continued) {
            try flushLogicalLine(allocator, &list, &buffer, &segments, stmt_start, stmt_end, coarse_source_map, &kind_state);
            in_stmt = false;
        }
    }

    if (in_stmt) {
        try flushLogicalLine(allocator, &list, &buffer, &segments, stmt_start, stmt_end, coarse_source_map, &kind_state);
    }

    return list.toOwnedSlice();
}

fn flushLogicalLine(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(LogicalLine),
    buffer: *std.array_list.Managed(u8),
    segments: *std.array_list.Managed(Segment),
    start_line: usize,
    end_line: usize,
    coarse_source_map: bool,
    kind_state: *KindState,
) !void {
    const raw = try mapped_text.takeBufferedMappedText(allocator, buffer, segments, start_line, coarse_source_map);
    defer raw.deinit(allocator);
    try rewrite.rewriteAndAppend(allocator, list, raw, start_line, end_line, kind_state);
    buffer.clearRetainingCapacity();
    segments.clearRetainingCapacity();
}
