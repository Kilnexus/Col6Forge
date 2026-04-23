const common = @import("common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const fallback_policy = common.fallback_policy;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const cases = @import("cases.zig");
const runner_io = @import("runner_io.zig");
const sanitizeWorkName = cases.sanitizeWorkName;
const findCompanionInputPath = runner_io.findCompanionInputPath;

pub const Comparator = struct {
    pub const CompareResult = struct {
        ok: bool,
        diff: ?[]const u8,
    };

    pub fn compare(
        allocator: std.mem.Allocator,
        ref_term: std.process.Child.Term,
        test_term: std.process.Child.Term,
        ref_stdout: []const u8,
        test_stdout: []const u8,
        allow_text_diff: bool,
    ) !CompareResult {
        const ref_code = exitCode(ref_term);
        const test_code = exitCode(test_term);
        if (ref_code != test_code) {
            const diff = try std.fmt.allocPrint(
                allocator,
                "exit code mismatch\nreference: {d}\ntranslated: {d}\n",
                .{ ref_code, test_code },
            );
            return .{ .ok = false, .diff = diff };
        }
        if (allow_text_diff) {
            return .{ .ok = true, .diff = null };
        }
        return compareText(allocator, ref_stdout, test_stdout);
    }

    fn compareText(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) !CompareResult {
        if (std.mem.eql(u8, expected, actual)) {
            return .{ .ok = true, .diff = null };
        }

        var exp_it = std.mem.splitScalar(u8, expected, '\n');
        var act_it = std.mem.splitScalar(u8, actual, '\n');
        var line_no: usize = 1;

        while (true) : (line_no += 1) {
            const exp_opt = exp_it.next();
            const act_opt = act_it.next();

            if (exp_opt == null and act_opt == null) {
                break;
            }
            if (exp_opt == null and act_opt != null) {
                const diff = try std.fmt.allocPrint(
                    allocator,
                    "translated has extra content at line {d}\nactual: {s}\n",
                    .{ line_no, trimCr(act_opt.?) },
                );
                return .{ .ok = false, .diff = diff };
            }
            if (act_opt == null and exp_opt != null) {
                const diff = try std.fmt.allocPrint(
                    allocator,
                    "reference has extra content at line {d}\nexpected: {s}\n",
                    .{ line_no, trimCr(exp_opt.?) },
                );
                return .{ .ok = false, .diff = diff };
            }

            const exp_line = trimCr(exp_opt.?);
            const act_line = trimCr(act_opt.?);
            if (!std.mem.eql(u8, exp_line, act_line)) {
                if (linesEquivalentWithNumericTolerance(exp_line, act_line)) {
                    continue;
                }
                const diff = try std.fmt.allocPrint(
                    allocator,
                    "line {d} mismatch\nreference:  {s}\ntranslated: {s}\n",
                    .{ line_no, exp_line, act_line },
                );
                return .{ .ok = false, .diff = diff };
            }
        }

        return .{ .ok = true, .diff = null };
    }
};

fn exitCode(term: std.process.Child.Term) u32 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| 128 + @intFromEnum(signal),
        else => 255,
    };
}

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn testCaseStemEquals(input_path: []const u8, stem: []const u8) bool {
    const base = std.fs.path.basename(input_path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    return std.ascii.eqlIgnoreCase(base[0..dot], stem);
}

pub fn allowsProcessorDependentOutputDiff(input_path: []const u8) bool {
    // FM905/FM907 are NIST list-directed output inspection tests whose text
    // rendering is explicitly processor-dependent.
    return testCaseStemEquals(input_path, "FM905") or
        testCaseStemEquals(input_path, "FM907") or
        // FM257 exercises PAUSE behavior, which is terminal/environment-dependent.
        testCaseStemEquals(input_path, "FM257");
}

fn linesEquivalentWithNumericTolerance(expected: []const u8, actual: []const u8) bool {
    var exp_idx: usize = 0;
    var act_idx: usize = 0;
    while (true) {
        while (exp_idx < expected.len and std.ascii.isWhitespace(expected[exp_idx])) : (exp_idx += 1) {}
        while (act_idx < actual.len and std.ascii.isWhitespace(actual[act_idx])) : (act_idx += 1) {}

        if (exp_idx == expected.len and act_idx == actual.len) return true;
        if (exp_idx == expected.len or act_idx == actual.len) return false;

        if (parseNumericToken(expected, exp_idx)) |exp_tok| {
            if (parseNumericToken(actual, act_idx)) |act_tok| {
                if (!numericTokensEquivalent(exp_tok, act_tok)) return false;
                exp_idx = exp_tok.end;
                act_idx = act_tok.end;
                continue;
            }
        }

        if (expected[exp_idx] != actual[act_idx]) return false;
        exp_idx += 1;
        act_idx += 1;
    }
}

const NumericToken = struct {
    raw: []const u8,
    end: usize,
    kind: enum { integer, float },
    int_value: i64 = 0,
    float_value: f64 = 0.0,
    tolerance: f64 = 0.0,
};

fn numericTokensEquivalent(expected: NumericToken, actual: NumericToken) bool {
    if (expected.kind == .integer and actual.kind == .integer) {
        return expected.int_value == actual.int_value;
    }

    const exp_float = if (expected.kind == .integer) @as(f64, @floatFromInt(expected.int_value)) else expected.float_value;
    const act_float = if (actual.kind == .integer) @as(f64, @floatFromInt(actual.int_value)) else actual.float_value;
    if (exp_float == act_float) return true;
    if (std.math.isNan(exp_float) or std.math.isNan(act_float)) return false;
    if (!std.math.isFinite(exp_float) or !std.math.isFinite(act_float)) return false;
    if (exp_float == 0.0 and act_float == 0.0) return true;

    const tol = @max(expected.tolerance, actual.tolerance);
    return @abs(exp_float - act_float) <= tol;
}

fn parseNumericToken(text: []const u8, start_idx: usize) ?NumericToken {
    if (start_idx >= text.len) return null;
    var i = start_idx;
    if (text[i] == '+' or text[i] == '-') {
        i += 1;
        if (i >= text.len) return null;
    }

    var saw_digit = false;
    var saw_dot = false;
    var digits_before_dot: usize = 0;
    var frac_digits: usize = 0;

    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        saw_digit = true;
        digits_before_dot += 1;
    }
    if (i < text.len and text[i] == '.') {
        saw_dot = true;
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            saw_digit = true;
            frac_digits += 1;
        }
    }
    if (!saw_digit) return null;

    var exponent: i32 = 0;
    var has_exponent = false;
    var explicit_exponent = false;
    const mantissa_end = i;

    if (i < text.len) {
        const ch = text[i];
        if ((ch == 'e' or ch == 'E' or ch == 'd' or ch == 'D') and i + 2 < text.len) {
            const sign = text[i + 1];
            if ((sign == '+' or sign == '-') and std.ascii.isDigit(text[i + 2])) {
                explicit_exponent = true;
                has_exponent = true;
                i += 2;
                const exp_start = i;
                while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
                exponent = std.fmt.parseInt(i32, text[exp_start - 1 .. i], 10) catch return null;
            }
        } else if ((ch == '+' or ch == '-') and i + 1 < text.len and std.ascii.isDigit(text[i + 1])) {
            has_exponent = true;
            i += 1;
            const exp_start = i;
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
            exponent = std.fmt.parseInt(i32, text[exp_start - 1 .. i], 10) catch return null;
        }
    }

    const raw = text[start_idx..i];
    if (!saw_dot and !has_exponent) {
        const int_value = std.fmt.parseInt(i64, raw, 10) catch return null;
        return .{
            .raw = raw,
            .end = i,
            .kind = .integer,
            .int_value = int_value,
            .tolerance = 0.0,
        };
    }

    var buf: [128]u8 = undefined;
    if (raw.len + 1 > buf.len) return null;
    var out: usize = 0;
    var src: usize = 0;
    while (src < raw.len) : (src += 1) {
        const ch = raw[src];
        if (!explicit_exponent and src == mantissa_end - start_idx and has_exponent) {
            buf[out] = 'e';
            out += 1;
        }
        buf[out] = switch (ch) {
            'D' => 'E',
            'd' => 'e',
            else => ch,
        };
        out += 1;
    }

    const float_value = std.fmt.parseFloat(f64, buf[0..out]) catch return null;
    const lsd_exp: i32 = exponent + @as(i32, @intCast(digits_before_dot)) - @as(i32, @intCast(frac_digits)) - 1;
    const tolerance = 0.5 * std.math.pow(f64, 10.0, @as(f64, @floatFromInt(lsd_exp)));
    return .{
        .raw = raw,
        .end = i,
        .kind = .float,
        .float_value = float_value,
        .tolerance = tolerance,
    };
}

test "linesEquivalentWithNumericTolerance keeps token boundaries" {
    const testing = std.testing;
    try testing.expect(linesEquivalentWithNumericTolerance("10  20", "10 20"));
    try testing.expect(linesEquivalentWithNumericTolerance("  A   =   B  ", "A = B"));
    try testing.expect(!linesEquivalentWithNumericTolerance("10 20", "1020"));
    try testing.expect(!linesEquivalentWithNumericTolerance("A B C", "A BC"));
}

test "linesEquivalentWithNumericTolerance accepts numeric differences inside punctuation" {
    const testing = std.testing;
    try testing.expect(linesEquivalentWithNumericTolerance(
        "VALUE=(1.234567E+03,-0.000000E+00)",
        "VALUE=(1.2345669D+03,0.000000E+00)",
    ));
}

test "sanitizeWorkName keeps extension distinctions to avoid workdir collisions" {
    const testing = std.testing;

    const f_name = try sanitizeWorkName(testing.allocator, "fcvs21_f95/FM405.f");
    defer testing.allocator.free(f_name);
    const for_name = try sanitizeWorkName(testing.allocator, "FCSV78/FM405.FOR");
    defer testing.allocator.free(for_name);

    try testing.expect(!std.mem.eql(u8, f_name, for_name));
    try testing.expect(std.mem.indexOfScalar(u8, f_name, '.') == null);
    try testing.expect(std.mem.indexOfScalar(u8, for_name, '.') == null);
}

test "findCompanionInputPath prefers normalized DAT companion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "FM923.DAT", .data = "normalized\n" });
    try tmp.dir.writeFile(.{ .sub_path = "FM923.DAT.ORIG", .data = "original\n" });

    const case_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(case_dir);

    const input_path = try findCompanionInputPath(allocator, case_dir, "tests/NIST_F78_test_suite/FCSV78/FM923.FOR");
    defer if (input_path) |path| allocator.free(path);

    try testing.expect(input_path != null);
    try testing.expect(std.ascii.endsWithIgnoreCase(input_path.?, "FM923.DAT"));
}

test "findCompanionInputPath returns null without DAT companion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "FM923.DAT.ORIG", .data = "original\n" });

    const case_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(case_dir);

    const input_path = try findCompanionInputPath(allocator, case_dir, "tests/NIST_F78_test_suite/FCSV78/FM923.FOR");
    defer if (input_path) |path| allocator.free(path);

    try testing.expect(input_path == null);
}

