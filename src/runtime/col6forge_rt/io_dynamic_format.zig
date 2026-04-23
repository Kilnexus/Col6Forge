const std = @import("std");

const runtime_text = @import("runtime_text.zig");
const TabKind = enum { absolute, relative_right, relative_left };
const BlankCtrl = enum { nulls, zeros };
const SignCtrl = enum { default, plus, suppress };
const RealKind = enum { e, d, g };

const IntSpec = struct {
    width: usize,
    min_digits: usize = 0,
    explicit_min_digits: bool = false,
};
const RealSpec = struct { width: usize, precision: usize = 0, exp_width: usize = 0, kind: RealKind = .e };
const CharSpec = struct { width: usize = 0 };
const LogicalSpec = struct { width: usize = 0 };
const TabSpec = struct { kind: TabKind, count: usize };

const Token = union(enum) {
    literal: []const u8,
    spaces: usize,
    tab: TabSpec,
    int: IntSpec,
    real: RealSpec,
    real_fixed: RealSpec,
    char: CharSpec,
    logical: LogicalSpec,
    colon: void,
    blank: BlankCtrl,
    sign: SignCtrl,
    scale: i32,
};

const TokenSequence = struct {
    items: []Token,
    has_descriptor: bool,
    reversion_offset: ?usize,
    flat_len: usize,
};

const DYNFMT_MAX_TOKENS: usize = 4096;
const DYNFMT_MAX_REPEAT: usize = 4096;
const DYNFMT_MAX_LITERAL_BYTES: usize = 1 << 20;
const DYNFMT_TLS_SCRATCH_BYTES: usize = 64 * 1024;
const DYNFMT_HEAP_ALLOCATOR = std.heap.page_allocator;

threadlocal var dynfmt_tls_scratch: [DYNFMT_TLS_SCRATCH_BYTES]u8 = undefined;

extern fn col6forge_write_v(
    unit: c_int,
    fmt: ?[*:0]const u8,
    arg_ptrs: ?[*]?*anyopaque,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
    strict_status: c_int,
) c_int;
extern fn col6forge_write_internal_v(
    buf: ?[*]u8,
    len: c_int,
    count: c_int,
    fmt: ?[*:0]const u8,
    arg_ptrs: ?[*]?*anyopaque,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
) void;
extern fn col6forge_formatted_write_stream_begin(
    unit: c_int,
    fmt: ?[*:0]const u8,
    strict_status: c_int,
) ?*anyopaque;
extern fn col6forge_write_internal_stream_begin(
    buf: ?[*]u8,
    len: c_int,
    count: c_int,
    fmt: ?[*:0]const u8,
) ?*anyopaque;
extern fn col6forge_formatted_write_stream_next(
    state_any: ?*anyopaque,
    arg_ptr: ?*anyopaque,
    arg_kind: c_int,
    arg_len: c_int,
) c_int;
extern fn col6forge_formatted_write_stream_finish(state_any: ?*anyopaque) c_int;
extern fn col6forge_formatted_read_core(
    unit: c_int,
    fmt: ?[*:0]const u8,
    arg_ptrs: ?[*]?*anyopaque,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
    status_mode: c_int,
) c_int;
extern fn col6forge_read_internal_core(
    buf: ?[*]u8,
    len: c_int,
    count: c_int,
    fmt: ?[*:0]const u8,
    arg_ptrs: ?[*]?*anyopaque,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
) c_int;

const Parser = struct {
    text: []const u8,
    idx: usize = 0,
    allocator: std.mem.Allocator,

    fn skipSep(self: *Parser) void {
        while (self.idx < self.text.len and (self.text[self.idx] == ' ' or self.text[self.idx] == '\t' or self.text[self.idx] == ',')) : (self.idx += 1) {}
    }

    fn parseUnsigned(self: *Parser) !?usize {
        const start = self.idx;
        while (self.idx < self.text.len and std.ascii.isDigit(self.text[self.idx])) : (self.idx += 1) {}
        if (self.idx == start) return null;
        var v: usize = 0;
        for (self.text[start..self.idx]) |ch| {
            const mul = @mulWithOverflow(v, @as(usize, 10));
            if (mul[1] != 0) return error.NumberTooLarge;
            const add = @addWithOverflow(mul[0], @as(usize, ch - '0'));
            if (add[1] != 0) return error.NumberTooLarge;
            v = add[0];
        }
        return v;
    }

    fn parseQuotedLiteral(self: *Parser, quote: u8) ![]const u8 {
        self.idx += 1;
        var buf = std.array_list.Managed(u8).init(self.allocator);
        errdefer buf.deinit();
        var closed = false;
        while (self.idx < self.text.len) {
            if (self.text[self.idx] == quote) {
                if (self.idx + 1 < self.text.len and self.text[self.idx + 1] == quote) {
                    try buf.append(quote);
                    self.idx += 2;
                    continue;
                }
                self.idx += 1;
                closed = true;
                break;
            }
            try buf.append(self.text[self.idx]);
            self.idx += 1;
        }
        if (!closed) return error.UnterminatedString;
        return buf.toOwnedSlice();
    }

    fn appendToken(self: *Parser, out: *std.array_list.Managed(Token), tok: Token) !void {
        _ = self;
        if (out.items.len >= DYNFMT_MAX_TOKENS) return error.FormatTooLarge;
        try out.append(tok);
    }

    fn appendRepeatedToken(self: *Parser, out: *std.array_list.Managed(Token), tok: Token, repeat: usize) !void {
        if (repeat > DYNFMT_MAX_TOKENS - out.items.len) return error.FormatTooLarge;
        try out.ensureTotalCapacity(out.items.len + repeat);
        var i: usize = 0;
        while (i < repeat) : (i += 1) {
            try self.appendToken(out, tok);
        }
    }

    fn appendFlatToken(self: *Parser, out: *std.array_list.Managed(Token), tok: Token, flat_len: *usize) !void {
        try self.appendToken(out, tok);
        flat_len.* += 1;
    }

    fn appendRepeatedFlatToken(self: *Parser, out: *std.array_list.Managed(Token), tok: Token, repeat: usize, flat_len: *usize) !void {
        try self.appendRepeatedToken(out, tok, repeat);
        flat_len.* += repeat;
    }

    fn appendRepeatGroup(
        self: *Parser,
        out: *std.array_list.Managed(Token),
        group: []const Token,
        repeat: usize,
        group_flat_len: usize,
        flat_len: *usize,
    ) !void {
        _ = self;
        if (repeat == 0 or group_flat_len == 0) return;
        const expanded_mul = @mulWithOverflow(group.len, repeat);
        if (expanded_mul[1] != 0) return error.FormatTooLarge;
        const expanded_add = @addWithOverflow(out.items.len, expanded_mul[0]);
        if (expanded_add[1] != 0 or expanded_add[0] > DYNFMT_MAX_TOKENS) return error.FormatTooLarge;
        const flat_mul = @mulWithOverflow(group_flat_len, repeat);
        if (flat_mul[1] != 0) return error.FormatTooLarge;
        try out.ensureTotalCapacity(expanded_add[0]);
        for (0..repeat) |_| {
            try out.appendSlice(group);
        }
        flat_len.* += flat_mul[0];
    }

    fn parseSequence(self: *Parser, stop_on_rparen: bool) !TokenSequence {
        var out = std.array_list.Managed(Token).init(self.allocator);
        errdefer out.deinit();
        var has_descriptor = false;
        var reversion_offset: ?usize = null;
        var flat_len: usize = 0;
        while (true) {
            self.skipSep();
            if (self.idx >= self.text.len) {
                if (stop_on_rparen) return error.UnmatchedParen;
                break;
            }
            if (stop_on_rparen and self.text[self.idx] == ')') {
                self.idx += 1;
                break;
            }

            var repeat: usize = 1;
            const repeat_start = self.idx;
            if (try self.parseUnsigned()) |n| repeat = n else self.idx = repeat_start;
            if (repeat == 0 or repeat > DYNFMT_MAX_REPEAT) return error.RepeatTooLarge;
            if (self.idx >= self.text.len) break;
            const ch = self.text[self.idx];

            if (ch == '(') {
                self.idx += 1;
                const group = try self.parseSequence(true);
                const group_start = flat_len;
                if (group.has_descriptor) {
                    has_descriptor = true;
                    reversion_offset = group_start + (group.reversion_offset orelse 0);
                }
                try self.appendRepeatGroup(&out, group.items, repeat, group.flat_len, &flat_len);
                continue;
            }
            if (ch == '\'' or ch == '"') {
                if (repeat != 1) return error.UnexpectedToken;
                try self.appendFlatToken(&out, .{ .literal = try self.parseQuotedLiteral(ch) }, &flat_len);
                continue;
            }
            if (ch == '/') {
                self.idx += 1;
                if (repeat > DYNFMT_MAX_LITERAL_BYTES) return error.FormatTooLarge;
                const lit = try self.allocator.alloc(u8, repeat);
                @memset(lit, '\n');
                try self.appendFlatToken(&out, .{ .literal = lit }, &flat_len);
                continue;
            }
            if (ch == ':' ) {
                self.idx += 1;
                try self.appendRepeatedFlatToken(&out, .{ .colon = {} }, repeat, &flat_len);
                continue;
            }
            if (ch == 'X' or ch == 'x') {
                self.idx += 1;
                try self.appendFlatToken(&out, .{ .spaces = repeat }, &flat_len);
                continue;
            }
            if (ch == 'H' or ch == 'h') {
                self.idx += 1;
                if (repeat > DYNFMT_MAX_LITERAL_BYTES or self.idx + repeat > self.text.len) return error.UnexpectedToken;
                const lit = self.text[self.idx .. self.idx + repeat];
                self.idx += repeat;
                try self.appendFlatToken(&out, .{ .literal = lit }, &flat_len);
                continue;
            }

            if (ch == 'P' or ch == 'p') {
                self.idx += 1;
                try self.appendFlatToken(&out, .{ .scale = @intCast(repeat) }, &flat_len);
                continue;
            }
            if (ch == 'B' or ch == 'b') {
                self.idx += 1;
                if (self.idx >= self.text.len) return error.UnexpectedToken;
                const ctrl = switch (std.ascii.toUpper(self.text[self.idx])) {
                    'N' => BlankCtrl.nulls,
                    'Z' => BlankCtrl.zeros,
                    else => return error.UnexpectedToken,
                };
                self.idx += 1;
                try self.appendRepeatedFlatToken(&out, .{ .blank = ctrl }, repeat, &flat_len);
                continue;
            }
            if (ch == 'S' or ch == 's') {
                self.idx += 1;
                var ctrl = SignCtrl.default;
                if (self.idx < self.text.len) {
                    const n = std.ascii.toUpper(self.text[self.idx]);
                    if (n == 'P') {
                        ctrl = .plus;
                        self.idx += 1;
                    } else if (n == 'S') {
                        ctrl = .suppress;
                        self.idx += 1;
                    }
                }
                try self.appendRepeatedFlatToken(&out, .{ .sign = ctrl }, repeat, &flat_len);
                continue;
            }
            if (ch == 'T' or ch == 't') {
                self.idx += 1;
                var kind = TabKind.absolute;
                if (self.idx < self.text.len) {
                    const n = std.ascii.toUpper(self.text[self.idx]);
                    if (n == 'R') {
                        kind = .relative_right;
                        self.idx += 1;
                    } else if (n == 'L') {
                        kind = .relative_left;
                        self.idx += 1;
                    }
                }
                const count = (try self.parseUnsigned()) orelse return error.UnexpectedToken;
                try self.appendRepeatedFlatToken(&out, .{ .tab = .{ .kind = kind, .count = count } }, repeat, &flat_len);
                continue;
            }

            const upper = std.ascii.toUpper(ch);
            if (upper == 'I' or upper == 'E' or upper == 'D' or upper == 'G' or upper == 'F' or upper == 'A' or upper == 'L') {
                has_descriptor = true;
                self.idx += 1;
                switch (upper) {
                    'I' => {
                        const width = (try self.parseUnsigned()) orelse return error.UnexpectedToken;
                        var min_digits: usize = 0;
                        var explicit_min_digits = false;
                        if (self.idx < self.text.len and self.text[self.idx] == '.') {
                            explicit_min_digits = true;
                            self.idx += 1;
                            min_digits = (try self.parseUnsigned()) orelse return error.UnexpectedToken;
                        }
                        try self.appendRepeatedFlatToken(
                            &out,
                            .{ .int = .{ .width = width, .min_digits = min_digits, .explicit_min_digits = explicit_min_digits } },
                            repeat,
                            &flat_len,
                        );
                    },
                    'E', 'D', 'G', 'F' => {
                        const width = (try self.parseUnsigned()) orelse return error.UnexpectedToken;
                        var precision: usize = 0;
                        var exp_width: usize = 0;
                        if (self.idx < self.text.len and self.text[self.idx] == '.') {
                            self.idx += 1;
                            precision = (try self.parseUnsigned()) orelse return error.UnexpectedToken;
                        }
                        if (self.idx < self.text.len and (self.text[self.idx] == 'E' or self.text[self.idx] == 'e')) {
                            self.idx += 1;
                            exp_width = (try self.parseUnsigned()) orelse return error.UnexpectedToken;
                        }
                        const spec: RealSpec = .{ .width = width, .precision = precision, .exp_width = exp_width, .kind = switch (upper) { 'D' => .d, 'G' => .g, else => .e } };
                        try self.appendRepeatedFlatToken(&out, if (upper == 'F') .{ .real_fixed = spec } else .{ .real = spec }, repeat, &flat_len);
                    },
                    'A' => {
                        const width = (try self.parseUnsigned()) orelse 0;
                        try self.appendRepeatedFlatToken(&out, .{ .char = .{ .width = width } }, repeat, &flat_len);
                    },
                    'L' => {
                        const width = (try self.parseUnsigned()) orelse return error.UnexpectedToken;
                        try self.appendRepeatedFlatToken(&out, .{ .logical = .{ .width = width } }, repeat, &flat_len);
                    },
                    else => unreachable,
                }
                continue;
            }

            return error.UnexpectedToken;
        }
        if (stop_on_rparen and has_descriptor) reversion_offset = 0;
        return .{
            .items = try out.toOwnedSlice(),
            .has_descriptor = has_descriptor,
            .reversion_offset = reversion_offset,
            .flat_len = flat_len,
        };
    }
};

fn trimFormatCopy(allocator: std.mem.Allocator, fmt_ptr: ?[*]const u8, fmt_len: c_int) ![]u8 {
    if (fmt_ptr == null or fmt_len <= 0) return error.InvalidFormat;
    const src = fmt_ptr.?[0..@intCast(fmt_len)];
    var s: usize = 0;
    var e: usize = src.len;
    while (s < e and (src[s] == ' ' or src[s] == '\t' or src[s] == '\n' or src[s] == '\r')) : (s += 1) {}
    while (e > s and (src[e - 1] == ' ' or src[e - 1] == '\t' or src[e - 1] == '\n' or src[e - 1] == '\r')) : (e -= 1) {}
    if (e <= s) return error.InvalidFormat;
    return allocator.dupe(u8, src[s..e]);
}

const sliceAsConstCStr = runtime_text.sliceAsConstCStr;

fn appendEscapedLiteral(buf: *std.array_list.Managed(u8), text: []const u8) !void {
    for (text) |ch| {
        if (ch == '%') try buf.appendSlice("%%") else try buf.append(ch);
    }
}

fn kindAt(arg_kinds: ?[*]const u8, i: usize, n: usize) u8 {
    if (i >= n or arg_kinds == null) return 0;
    return arg_kinds.?[i];
}

fn isFloatKind(kind: u8) bool {
    return kind == 'f' or kind == 'F' or kind == 'D';
}

fn descriptorCount(tokens: []const Token) usize {
    var n: usize = 0;
    for (tokens) |t| switch (t) { .int, .real, .real_fixed, .char, .logical => n += 1, else => {} };
    return n;
}

fn appendInternalTabMarker(out: *std.array_list.Managed(u8), tab: TabSpec) !void {
    try out.append(0x01);
    try out.append(switch (tab.kind) {
        .absolute => 'T',
        .relative_right => 'R',
        .relative_left => 'L',
    });
    try out.print("{d}", .{tab.count});
    try out.append(0x02);
}

fn appendReversionAnchorIfNeeded(out: *std.array_list.Managed(u8), seq: TokenSequence, flat_index: usize) !void {
    if (seq.reversion_offset != null and seq.reversion_offset.? == flat_index) {
        try out.append(0x03);
    }
}

fn lowerWrite(allocator: std.mem.Allocator, tokens: []const Token, arg_kinds: ?[*]const u8, arg_count: c_int, internal_mode: bool) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    const nargs: usize = @intCast(@max(arg_count, 0));
    var arg_i: usize = 0;
    var sign_plus = false;
    for (tokens) |t| {
        switch (t) {
            .literal => |lit| try appendEscapedLiteral(&out, lit),
            .spaces => |c| for (0..c) |_| try out.append(' '),
            .tab => |tab| {
                if (internal_mode) {
                    try appendInternalTabMarker(&out, tab);
                } else {
                    switch (tab.kind) {
                        .absolute, .relative_right => for (0..tab.count) |_| try out.append(' '),
                        .relative_left => {},
                    }
                }
            },
            .blank, .scale => {},
            .sign => |s| sign_plus = (s == .plus),
            .colon => if (arg_i >= nargs) break,
            .int => |s| {
                if (arg_i >= nargs) break;
                try out.append('%');
                if (sign_plus) try out.append('+');
                if (s.width > 0) try out.print("{d}", .{s.width});
                if (s.explicit_min_digits) try out.print(".{d}", .{s.min_digits});
                try out.append('d');
                arg_i += 1;
            },
            .real, .real_fixed => |s| {
                if (arg_i >= nargs) break;
                try out.append('%');
                if (sign_plus) try out.append('+');
                if (s.width > 0) try out.print("{d}", .{s.width});
                try out.print(".{d}f", .{s.precision});
                arg_i += 1;
            },
            .char => |s| {
                if (arg_i >= nargs) break;
                const k = kindAt(arg_kinds, arg_i, nargs);
                if (k == 'i' or k == 'j') {
                    if (s.width > 0) try out.print("%{d}d", .{s.width}) else try out.appendSlice("%d");
                } else if (isFloatKind(k)) {
                    if (s.width > 0) try out.print("%{d}.0f", .{s.width}) else try out.appendSlice("%.0f");
                } else {
                    if (s.width > 0) try out.print("%{d}s", .{s.width}) else try out.appendSlice("%s");
                }
                arg_i += 1;
            },
            .logical => |s| {
                if (arg_i >= nargs) break;
                if (s.width > 0) try out.print("%{d}c", .{s.width}) else try out.appendSlice("%c");
                arg_i += 1;
            },
        }
    }
    if (descriptorCount(tokens) > 0) try out.append('\n');
    try out.append(0);
    return out.toOwnedSlice();
}

fn lowerRead(allocator: std.mem.Allocator, tokens: []const Token, arg_kinds: ?[*]const u8, arg_count: c_int) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    const nargs: usize = @intCast(@max(arg_count, 0));
    var arg_i: usize = 0;
    for (tokens) |t| {
        switch (t) {
            .literal => |lit| try appendEscapedLiteral(&out, lit),
            .spaces => |c| for (0..c) |_| try out.append(' '),
            .tab => |tab| {
                const d: u8 = switch (tab.kind) { .absolute => 'T', .relative_right => 'R', .relative_left => 'U' };
                try out.print("%{d}{c}", .{ tab.count, d });
            },
            .blank => |b| try out.appendSlice(if (b == .nulls) "%N" else "%Z"),
            .sign => {},
            .scale => |value| try out.print("%{d}P", .{value}),
            .colon => if (arg_i >= nargs) break,
            .int => |s| {
                if (arg_i >= nargs) break;
                if (s.width > 0) try out.print("%{d}d", .{s.width}) else try out.appendSlice("%d");
                arg_i += 1;
            },
            .real, .real_fixed => |s| {
                if (arg_i >= nargs) break;
                const spec = if (kindAt(arg_kinds, arg_i, nargs) == 'D') "lf" else "f";
                if (s.width > 0) {
                    try out.print("%{d}.{d}{s}", .{ s.width, s.precision, spec });
                } else {
                    try out.print("%.{d}{s}", .{ s.precision, spec });
                }
                arg_i += 1;
            },
            .char => |s| {
                if (arg_i >= nargs) break;
                const w = if (s.width > 0) s.width else 1;
                try out.print("%{d}c", .{w});
                arg_i += 1;
            },
            .logical => |s| {
                if (arg_i >= nargs) break;
                if (s.width > 0) try out.print("%{d}L", .{s.width}) else try out.appendSlice("%L");
                arg_i += 1;
            },
        }
    }
    try out.append(0);
    return out.toOwnedSlice();
}

fn lowerWriteStream(allocator: std.mem.Allocator, seq: TokenSequence, internal_mode: bool) ![]u8 {
    _ = internal_mode;
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var sign_plus = false;
    var scale_factor: i32 = 0;
    for (seq.items, 0..) |t, idx| {
        try appendReversionAnchorIfNeeded(&out, seq, idx);
        const sign_flag: u8 = if (sign_plus) 1 else 0;
        switch (t) {
            .literal => |lit| try appendEscapedLiteral(&out, lit),
            .spaces => |count| for (0..count) |_| try out.append(' '),
            .tab => |tab| {
                try appendInternalTabMarker(&out, tab);
            },
            .blank => {},
            .scale => |value| scale_factor = value,
            .sign => |ctrl| sign_plus = (ctrl == .plus),
            .colon => {},
            .int => |spec| try out.print(
                "%I{d},{d},{d};",
                .{
                    spec.width,
                    if (spec.explicit_min_digits and spec.min_digits == 0) -1 else @as(i32, @intCast(spec.min_digits)),
                    sign_flag,
                },
            ),
            .real_fixed => |spec| try out.print("%F{d},{d},{d};", .{ spec.width, spec.precision, sign_flag }),
            .real => |spec| {
                const real_kind: u8 = switch (spec.kind) {
                    .e => 'E',
                    .d => 'D',
                    .g => 'G',
                };
                try out.print(
                    "%R{c},{d},{d},{d},{d},{d};",
                    .{ real_kind, spec.width, spec.precision, spec.exp_width, scale_factor, sign_flag },
                );
            },
            .char => |spec| try out.print("%S{d};", .{spec.width}),
            .logical => |spec| try out.print("%L{d};", .{spec.width}),
        }
    }
    try out.append(0);
    return out.toOwnedSlice();
}

fn lowerReadStream(allocator: std.mem.Allocator, seq: TokenSequence) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    for (seq.items, 0..) |t, idx| {
        try appendReversionAnchorIfNeeded(&out, seq, idx);
        switch (t) {
            .literal => |lit| try appendEscapedLiteral(&out, lit),
            .spaces => |count| for (0..count) |_| try out.append(' '),
            .tab => |tab| {
                const d: u8 = switch (tab.kind) {
                    .absolute => 'T',
                    .relative_right => 'R',
                    .relative_left => 'U',
                };
                try out.print("%{d}{c}", .{ tab.count, d });
            },
            .blank => |ctrl| try out.appendSlice(if (ctrl == .nulls) "%N" else "%Z"),
            .sign => {},
            .scale => |value| try out.print("%{d}P", .{value}),
            .colon => {},
            .int => |spec| if (spec.width > 0) {
                try out.print("%{d}d", .{spec.width});
            } else {
                try out.appendSlice("%d");
            },
            .real, .real_fixed => |spec| if (spec.width > 0) {
                try out.print("%{d}.{d}f", .{ spec.width, spec.precision });
            } else {
                try out.print("%.{d}f", .{spec.precision});
            },
            .char => |spec| try out.print("%{d}c", .{if (spec.width > 0) spec.width else 1}),
            .logical => |spec| if (spec.width > 0) {
                try out.print("%{d}L", .{spec.width});
            } else {
                try out.appendSlice("%L");
            },
        }
    }
    try out.append(0);
    return out.toOwnedSlice();
}

fn parseTokens(a: std.mem.Allocator, trimmed: []const u8) !TokenSequence {
    const l = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.InvalidFormat;
    const r = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return error.InvalidFormat;
    if (r <= l) return error.InvalidFormat;
    var p = Parser{ .text = trimmed[l + 1 .. r], .allocator = a };
    var toks = try p.parseSequence(false);
    p.skipSep();
    if (p.idx != p.text.len) return error.InvalidFormat;
    if (toks.reversion_offset == null and toks.has_descriptor) toks.reversion_offset = 0;
    return toks;
}

pub const LowerMode = enum {
    write_external,
    write_internal,
    read_any,
    write_stream_external,
    write_stream_internal,
    read_stream,
};

pub const LoweredFormat = struct {
    bytes: []u8,
    heap_owned: bool,
};

const LoweredWriteFormat = struct {
    bytes: []u8,
    heap_owned: bool,
    uses_stream: bool,
};

fn lowerFormatWithAlloc(
    parse_allocator: std.mem.Allocator,
    out_allocator: std.mem.Allocator,
    mode: LowerMode,
    fmt_ptr: ?[*]const u8,
    fmt_len: c_int,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
) ![]u8 {
    const trimmed = try trimFormatCopy(parse_allocator, fmt_ptr, fmt_len);
    const toks = try parseTokens(parse_allocator, trimmed);
    return switch (mode) {
        .write_external => lowerWrite(out_allocator, toks.items, arg_kinds, arg_count, false),
        .write_internal => lowerWrite(out_allocator, toks.items, arg_kinds, arg_count, true),
        .read_any => lowerRead(out_allocator, toks.items, arg_kinds, arg_count),
        .write_stream_external => lowerWriteStream(out_allocator, toks, false),
        .write_stream_internal => lowerWriteStream(out_allocator, toks, true),
        .read_stream => lowerReadStream(out_allocator, toks),
    };
}

pub fn lowerFormat(
    mode: LowerMode,
    fmt_ptr: ?[*]const u8,
    fmt_len: c_int,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
) !LoweredFormat {
    var scratch = std.heap.FixedBufferAllocator.init(&dynfmt_tls_scratch);
    const scratch_alloc = scratch.allocator();
    const in_scratch = lowerFormatWithAlloc(scratch_alloc, scratch_alloc, mode, fmt_ptr, fmt_len, arg_kinds, arg_count) catch |err| switch (err) {
        error.OutOfMemory => {
            var arena = std.heap.ArenaAllocator.init(DYNFMT_HEAP_ALLOCATOR);
            defer arena.deinit();
            const heap_bytes = try lowerFormatWithAlloc(arena.allocator(), DYNFMT_HEAP_ALLOCATOR, mode, fmt_ptr, fmt_len, arg_kinds, arg_count);
            return .{ .bytes = heap_bytes, .heap_owned = true };
        },
        else => return err,
    };
    return .{ .bytes = in_scratch, .heap_owned = false };
}

fn tokenSequenceNeedsWriteStream(seq: TokenSequence) bool {
    for (seq.items) |item| {
        if (item == .tab) return true;
    }
    return false;
}

fn lowerWriteFormatWithAlloc(
    parse_allocator: std.mem.Allocator,
    out_allocator: std.mem.Allocator,
    internal_mode: bool,
    fmt_ptr: ?[*]const u8,
    fmt_len: c_int,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
) !LoweredWriteFormat {
    const trimmed = try trimFormatCopy(parse_allocator, fmt_ptr, fmt_len);
    const toks = try parseTokens(parse_allocator, trimmed);
    const uses_stream = tokenSequenceNeedsWriteStream(toks);
    return .{
        .bytes = if (uses_stream)
            try lowerWriteStream(out_allocator, toks, internal_mode)
        else
            try lowerWrite(out_allocator, toks.items, arg_kinds, arg_count, internal_mode),
        .heap_owned = false,
        .uses_stream = uses_stream,
    };
}

fn lowerWriteFormatAuto(
    internal_mode: bool,
    fmt_ptr: ?[*]const u8,
    fmt_len: c_int,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
) !LoweredWriteFormat {
    var scratch = std.heap.FixedBufferAllocator.init(&dynfmt_tls_scratch);
    const scratch_alloc = scratch.allocator();
    const in_scratch = lowerWriteFormatWithAlloc(scratch_alloc, scratch_alloc, internal_mode, fmt_ptr, fmt_len, arg_kinds, arg_count) catch |err| switch (err) {
        error.OutOfMemory => {
            var arena = std.heap.ArenaAllocator.init(DYNFMT_HEAP_ALLOCATOR);
            defer arena.deinit();
            var heap_lowered = try lowerWriteFormatWithAlloc(arena.allocator(), DYNFMT_HEAP_ALLOCATOR, internal_mode, fmt_ptr, fmt_len, arg_kinds, arg_count);
            heap_lowered.heap_owned = true;
            return heap_lowered;
        },
        else => return err,
    };
    return in_scratch;
}

fn runtimeCStringLen(text: [*:0]const u8) c_int {
    var len: usize = 0;
    while (text[len] != 0) : (len += 1) {}
    return @intCast(@min(len, @as(usize, @intCast(std.math.maxInt(c_int)))));
}

fn runtimeStreamArgLen(arg_ptr: ?*anyopaque, kind: u8) c_int {
    if (kind != 's') return 0;
    const text: [*:0]const u8 = @ptrCast(arg_ptr orelse return 0);
    return runtimeCStringLen(text);
}

fn executeLoweredWriteStreamExternal(
    unit: c_int,
    lowered: []u8,
    arg_ptrs: ?[*]?*anyopaque,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
    strict_status: c_int,
) c_int {
    const fmt_c: [*:0]const u8 = @ptrCast(lowered.ptr);
    const state = col6forge_formatted_write_stream_begin(unit, fmt_c, strict_status) orelse return if (strict_status != 0) 1 else 0;
    const total: usize = @intCast(@max(arg_count, 0));
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const arg_ptr = if (arg_ptrs) |ptrs| ptrs[i] else null;
        const kind = kindAt(arg_kinds, i, total);
        if (col6forge_formatted_write_stream_next(state, arg_ptr, kind, runtimeStreamArgLen(arg_ptr, kind)) != 0) break;
    }
    return col6forge_formatted_write_stream_finish(state);
}

fn executeLoweredWriteStreamInternal(
    buf: ?[*]u8,
    len: c_int,
    count: c_int,
    lowered: []u8,
    arg_ptrs: ?[*]?*anyopaque,
    arg_kinds: ?[*]const u8,
    arg_count: c_int,
) void {
    const fmt_c: [*:0]const u8 = @ptrCast(lowered.ptr);
    const state = col6forge_write_internal_stream_begin(buf, len, count, fmt_c) orelse return;
    const total: usize = @intCast(@max(arg_count, 0));
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const arg_ptr = if (arg_ptrs) |ptrs| ptrs[i] else null;
        const kind = kindAt(arg_kinds, i, total);
        if (col6forge_formatted_write_stream_next(state, arg_ptr, kind, runtimeStreamArgLen(arg_ptr, kind)) != 0) break;
    }
    _ = col6forge_formatted_write_stream_finish(state);
}

pub export fn col6forge_write_fmt_expr_v(unit: c_int, fmt_ptr: ?[*]const u8, fmt_len: c_int, arg_ptrs: ?[*]?*anyopaque, arg_kinds: ?[*]const u8, arg_count: c_int, strict_status: c_int) callconv(.c) c_int {
    const lowered = lowerWriteFormatAuto(false, fmt_ptr, fmt_len, arg_kinds, arg_count) catch return if (strict_status != 0) 1 else 0;
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    if (lowered.uses_stream) return executeLoweredWriteStreamExternal(unit, lowered.bytes, arg_ptrs, arg_kinds, arg_count, strict_status);
    return col6forge_write_v(unit, sliceAsConstCStr(lowered.bytes), arg_ptrs, arg_kinds, arg_count, strict_status);
}

pub export fn col6forge_write_internal_fmt_expr_v(buf: ?[*]u8, len: c_int, count: c_int, fmt_ptr: ?[*]const u8, fmt_len: c_int, arg_ptrs: ?[*]?*anyopaque, arg_kinds: ?[*]const u8, arg_count: c_int) callconv(.c) void {
    const lowered = lowerWriteFormatAuto(true, fmt_ptr, fmt_len, arg_kinds, arg_count) catch return;
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    if (lowered.uses_stream) {
        executeLoweredWriteStreamInternal(buf, len, count, lowered.bytes, arg_ptrs, arg_kinds, arg_count);
        return;
    }
    col6forge_write_internal_v(buf, len, count, sliceAsConstCStr(lowered.bytes), arg_ptrs, arg_kinds, arg_count);
}

pub export fn col6forge_read_fmt_expr_core(unit: c_int, fmt_ptr: ?[*]const u8, fmt_len: c_int, arg_ptrs: ?[*]?*anyopaque, arg_kinds: ?[*]const u8, arg_count: c_int, status_mode: c_int) callconv(.c) c_int {
    const lowered = lowerFormat(.read_any, fmt_ptr, fmt_len, arg_kinds, arg_count) catch return if (status_mode != 0) 1 else -1;
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    return col6forge_formatted_read_core(unit, sliceAsConstCStr(lowered.bytes), arg_ptrs, arg_kinds, arg_count, status_mode);
}

pub export fn col6forge_read_internal_fmt_expr_core(buf: ?[*]u8, len: c_int, count: c_int, fmt_ptr: ?[*]const u8, fmt_len: c_int, arg_ptrs: ?[*]?*anyopaque, arg_kinds: ?[*]const u8, arg_count: c_int) callconv(.c) c_int {
    const lowered = lowerFormat(.read_any, fmt_ptr, fmt_len, arg_kinds, arg_count) catch return 1;
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    return col6forge_read_internal_core(buf, len, count, sliceAsConstCStr(lowered.bytes), arg_ptrs, arg_kinds, arg_count);
}

test "lowerWrite maps A descriptor with D kind to numeric format" {
    const fmt = "(A5)";
    var kinds = [_]u8{'D'};
    const lowered = try lowerFormat(.write_external, fmt.ptr, @intCast(fmt.len), &kinds, 1);
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    try std.testing.expectEqualStrings("%5.0f\n", std.mem.sliceTo(lowered.bytes, 0));
}

test "lowerWrite keeps A descriptor as string for s kind" {
    const fmt = "(A5)";
    var kinds = [_]u8{'s'};
    const lowered = try lowerFormat(.write_external, fmt.ptr, @intCast(fmt.len), &kinds, 1);
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    try std.testing.expectEqualStrings("%5s\n", std.mem.sliceTo(lowered.bytes, 0));
}

test "lowerRead preserves real descriptor precision" {
    const fmt = "(F5.2, E10.3)";
    var kinds = [_]u8{ 'f', 'D' };
    const lowered = try lowerFormat(.read_any, fmt.ptr, @intCast(fmt.len), &kinds, 2);
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    try std.testing.expectEqualStrings("%5.2f%10.3lf", std.mem.sliceTo(lowered.bytes, 0));
}

test "lowerReadStream preserves runtime descriptors and reversion without arg metadata" {
    const fmt = "(I5, 2(I5))";
    const lowered = try lowerFormat(.read_stream, fmt.ptr, @intCast(fmt.len), null, 0);
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    try std.testing.expectEqualStrings("%5d\x03%5d%5d", std.mem.sliceTo(lowered.bytes, 0));
}

test "lowerWriteStreamInternal emits stream runtime descriptors" {
    const fmt = "(A4,':',I4)";
    const lowered = try lowerFormat(.write_stream_internal, fmt.ptr, @intCast(fmt.len), null, 0);
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    try std.testing.expectEqualStrings("\x03%S4;:%I4,0,0;", std.mem.sliceTo(lowered.bytes, 0));
}

test "lowerWriteStreamExternal preserves tab markers for runtime stream execution" {
    const fmt = "(TR26, A14, T25, A13)";
    const lowered = try lowerFormat(.write_stream_external, fmt.ptr, @intCast(fmt.len), null, 0);
    defer if (lowered.heap_owned) DYNFMT_HEAP_ALLOCATOR.free(lowered.bytes);
    try std.testing.expectEqualStrings("\x03\x01R26\x02%S14;\x01T25\x02%S13;", std.mem.sliceTo(lowered.bytes, 0));
}
