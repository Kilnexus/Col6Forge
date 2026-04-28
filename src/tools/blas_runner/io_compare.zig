const common = @import("common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const zig_api = Col6Forge.zig_api;
const process_timeout = @import("../process_timeout.zig");
pub const timeoutMonitor = process_timeout.timeoutMonitor;

pub const ProcessResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,
    timed_out: bool,

    pub fn deinit(self: ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runProcessCaptureWithInput(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    input: ?[]const u8,
    timeout_ms: u64,
) !ProcessResult {
    const io = zig_api.defaultIo();
    const resolved_argv = try zig_api.resolveZigArgv(allocator, argv);
    defer resolved_argv.deinit(allocator);
    const base_dir = cwd orelse ".";
    const temp_dir = try std.fs.path.join(allocator, &.{ base_dir, ".blas-runner-tmp" });
    defer allocator.free(temp_dir);
    try zig_api.cwd().makePath(temp_dir);
    var env_map = try zig_api.createProcessEnvMap(allocator);
    defer env_map.deinit();
    const temp_env = if (cwd != null) ".blas-runner-tmp" else temp_dir;
    try env_map.put("TMP", temp_env);
    try env_map.put("TEMP", temp_env);
    try env_map.put("TMPDIR", temp_env);

    var child = try std.process.spawn(io, .{
        .argv = resolved_argv.argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &env_map,
        .stdin = if (input == null) .ignore else .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = builtin.os.tag == .windows,
    });
    defer child.kill(io);

    var done = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    var monitor: ?std.Thread = null;
    var monitor_joined = false;
    if (timeout_ms > 0) {
        monitor = try std.Thread.spawn(.{}, timeoutMonitor, .{ &child, &done, &timed_out, timeout_ms });
    }
    errdefer {
        done.store(true, .seq_cst);
        if (!monitor_joined) {
            if (monitor) |thread| thread.join();
            monitor_joined = true;
        }
    }

    if (input) |bytes| {
        if (child.stdin) |stdin_file| {
            try stdin_file.writeStreamingAll(io, bytes);
            stdin_file.close(io);
        }
        child.stdin = null;
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try multi_reader.checkAnyError();

    done.store(true, .seq_cst);
    if (monitor) |thread| thread.join();
    monitor_joined = true;

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = try child.wait(io),
        .timed_out = timed_out.load(.seq_cst),
    };
}

pub fn isZeroExit(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub const Comparator = struct {
    const CompareResult = struct {
        ok: bool,
        diff: ?[]const u8,
    };

    pub fn compare(
        allocator: std.mem.Allocator,
        ref_term: std.process.Child.Term,
        test_term: std.process.Child.Term,
        ref_stdout: []const u8,
        test_stdout: []const u8,
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
        return compareText(allocator, ref_stdout, test_stdout);
    }

    pub fn compareText(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) !CompareResult {
        if (std.mem.eql(u8, expected, actual)) {
            return .{ .ok = true, .diff = null };
        }

        var exp_it = std.mem.splitScalar(u8, expected, '\n');
        var act_it = std.mem.splitScalar(u8, actual, '\n');
        var line_no: usize = 1;
        var exp_opt = exp_it.next();
        var act_opt = act_it.next();

        while (true) : (line_no += 1) {
            while (exp_opt) |line| {
                if (!isBlankLine(trimCr(line))) break;
                exp_opt = exp_it.next();
            }
            while (act_opt) |line| {
                if (!isBlankLine(trimCr(line))) break;
                act_opt = act_it.next();
            }

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
                if (linesEquivalentIgnoringWhitespace(exp_line, act_line) or linesEquivalentForForLineTrailingZeros(exp_line, act_line)) {
                    exp_opt = exp_it.next();
                    act_opt = act_it.next();
                    continue;
                }
                const diff = try std.fmt.allocPrint(
                    allocator,
                    "line {d} mismatch\nreference:  {s}\ntranslated: {s}\n",
                    .{ line_no, exp_line, act_line },
                );
                return .{ .ok = false, .diff = diff };
            }
            exp_opt = exp_it.next();
            act_opt = act_it.next();
        }

        return .{ .ok = true, .diff = null };
    }
};

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn exitCode(term: std.process.Child.Term) u32 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| 128 + @intFromEnum(signal),
        else => 255,
    };
}

fn linesEquivalentIgnoringWhitespace(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and std.ascii.isWhitespace(a[i])) : (i += 1) {}
        while (j < b.len and std.ascii.isWhitespace(b[j])) : (j += 1) {}
        if (i >= a.len or j >= b.len) break;
        while (i < a.len and j < b.len and !std.ascii.isWhitespace(a[i]) and !std.ascii.isWhitespace(b[j])) : ({
            i += 1;
            j += 1;
        }) {
            if (a[i] != b[j]) return false;
        }
        if (i < a.len and !std.ascii.isWhitespace(a[i])) return false;
        if (j < b.len and !std.ascii.isWhitespace(b[j])) return false;
    }
    while (i < a.len and std.ascii.isWhitespace(a[i])) : (i += 1) {}
    while (j < b.len and std.ascii.isWhitespace(b[j])) : (j += 1) {}
    return i == a.len and j == b.len;
}

fn linesEquivalentForForLineTrailingZeros(a: []const u8, b: []const u8) bool {
    var tokens_a: [64][]const u8 = undefined;
    var tokens_b: [64][]const u8 = undefined;
    const count_a = tokenizeWhitespace(a, &tokens_a);
    const count_b = tokenizeWhitespace(b, &tokens_b);
    if (count_a < 3 or count_b < 3) return false;

    if (!std.ascii.eqlIgnoreCase(tokens_a[0], "FOR")) return false;
    if (!std.ascii.eqlIgnoreCase(tokens_b[0], "FOR")) return false;

    const first_num_a = firstNumericToken(tokens_a[0..count_a]) orelse return false;
    const first_num_b = firstNumericToken(tokens_b[0..count_b]) orelse return false;
    if (first_num_a != first_num_b) return false;

    var i_prefix: usize = 0;
    while (i_prefix < first_num_a) : (i_prefix += 1) {
        if (!std.ascii.eqlIgnoreCase(tokens_a[i_prefix], tokens_b[i_prefix])) return false;
    }

    var end_a = count_a;
    while (end_a > first_num_a and isZeroNumericToken(tokens_a[end_a - 1])) : (end_a -= 1) {}
    var end_b = count_b;
    while (end_b > first_num_b and isZeroNumericToken(tokens_b[end_b - 1])) : (end_b -= 1) {}
    if (end_a != end_b) return false;

    var i: usize = first_num_a;
    while (i < end_a) : (i += 1) {
        if (!std.mem.eql(u8, tokens_a[i], tokens_b[i])) return false;
    }
    return true;
}

fn tokenizeWhitespace(line: []const u8, out: *[64][]const u8) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t(),");
    while (it.next()) |tok| {
        if (count >= out.len) break;
        out[count] = tok;
        count += 1;
    }
    return count;
}

fn firstNumericToken(tokens: []const []const u8) ?usize {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (isNumericToken(tokens[i])) return i;
    }
    return null;
}

fn isNumericToken(tok: []const u8) bool {
    if (std.fmt.parseInt(i64, tok, 10) catch null != null) return true;
    return parseFloatToken(tok) != null;
}

fn isZeroNumericToken(tok: []const u8) bool {
    if (std.fmt.parseInt(i64, tok, 10) catch null) |v| return v == 0;
    if (parseFloatToken(tok)) |v| return v == 0.0;
    return false;
}

fn parseFloatToken(tok: []const u8) ?f64 {
    if (tok.len == 0) return null;
    var buf: [64]u8 = undefined;
    if (tok.len >= buf.len) return null;
    for (tok, 0..) |ch, i| {
        buf[i] = switch (ch) {
            'D' => 'E',
            'd' => 'e',
            else => ch,
        };
    }
    return std.fmt.parseFloat(f64, buf[0..tok.len]) catch null;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |ch| {
        if (!std.ascii.isWhitespace(ch)) return false;
    }
    return true;
}
