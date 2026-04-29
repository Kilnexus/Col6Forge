const std = @import("std");

pub fn compactDirective(text: []const u8, buf: *[256]u8) []const u8 {
    const max_len = @min(text.len, buf.len);
    var out_len: usize = 0;
    for (text[0..max_len]) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        buf.*[out_len] = std.ascii.toUpper(ch);
        out_len += 1;
    }
    return buf[0..out_len];
}
