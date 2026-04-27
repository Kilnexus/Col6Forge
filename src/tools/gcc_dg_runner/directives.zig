const common = @import("common.zig");
const std = common.std;
const Col6Forge = common.Col6Forge;
const zig_api = Col6Forge.zig_api;
const DgDoKind = enum {
    none,
    compile,
    run,
    link,
    assemble,
    preprocess,
    other,
};

pub const SkipReason = enum {
    no_dg_do,
    do_not_compile,
    dg_do_target_guarded,
    expected_diagnostics,
    target_predicate,
    additional_sources,
    unsupported_dg_options,
    unsupported_dejagnu,
    preprocessed_source,
};

pub const SkipCounts = struct {
    total_sources: usize = 0,
    no_dg_do: usize = 0,
    do_not_compile: usize = 0,
    dg_do_target_guarded: usize = 0,
    expected_diagnostics: usize = 0,
    target_predicate: usize = 0,
    additional_sources: usize = 0,
    unsupported_dg_options: usize = 0,
    unsupported_dejagnu: usize = 0,
    preprocessed_source: usize = 0,

    pub fn add(self: *SkipCounts, reason: SkipReason) void {
        switch (reason) {
            .no_dg_do => self.no_dg_do += 1,
            .do_not_compile => self.do_not_compile += 1,
            .dg_do_target_guarded => self.dg_do_target_guarded += 1,
            .expected_diagnostics => self.expected_diagnostics += 1,
            .target_predicate => self.target_predicate += 1,
            .additional_sources => self.additional_sources += 1,
            .unsupported_dg_options => self.unsupported_dg_options += 1,
            .unsupported_dejagnu => self.unsupported_dejagnu += 1,
            .preprocessed_source => self.preprocessed_source += 1,
        }
    }

    pub fn totalSkipped(self: SkipCounts) usize {
        return self.no_dg_do +
            self.do_not_compile +
            self.dg_do_target_guarded +
            self.expected_diagnostics +
            self.target_predicate +
            self.additional_sources +
            self.unsupported_dg_options +
            self.unsupported_dejagnu +
            self.preprocessed_source;
    }
};

pub const TestCase = struct {
    input_path: []const u8,
    rel_path: []const u8,
    work_name: []const u8,
    bounds_check: bool,
    range_check: bool,
    fbackslash: bool,
    allow_argument_mismatch: bool,
    expect_compile_error: bool,
    expect_should_fail: bool,
    expected_error_patterns: []ExpectedErrorPattern,
    expected_warning_patterns: []ExpectedWarningPattern,
    expected_aux_patterns: []ExpectedAuxPattern,
    expected_output_patterns: []ExpectedOutputPattern,
    prune_output_patterns: []PruneOutputPattern,
};

pub const ExpectedErrorPattern = struct {
    pattern: []const u8,
    line_no: usize,
};

pub const ExpectedWarningPattern = struct {
    pattern: []const u8,
    line_no: usize,
};

pub const AuxDiagKind = enum {
    message,
    note,
    bogus,
};

pub const ExpectedAuxPattern = struct {
    pattern: []const u8,
    line_no: usize,
    kind: AuxDiagKind,
};

pub const ExpectedOutputPattern = struct {
    pattern: []const u8,
    line_no: usize,
};

pub const PruneOutputPattern = struct {
    pattern: []const u8,
    line_no: usize,
};

pub const CaseExpectations = struct {
    bounds_check: bool,
    range_check: bool,
    fbackslash: bool,
    allow_argument_mismatch: bool,
    expect_compile_error: bool,
    expect_should_fail: bool,
    expected_error_patterns: []ExpectedErrorPattern,
    expected_warning_patterns: []ExpectedWarningPattern,
    expected_aux_patterns: []ExpectedAuxPattern,
    expected_output_patterns: []ExpectedOutputPattern,
    prune_output_patterns: []PruneOutputPattern,
};

pub const CaseClassification = union(enum) {
    runnable: CaseExpectations,
    skip: SkipReason,
};

pub const ParsedDiagDirectives = struct {
    has_error: bool = false,
    has_should_fail: bool = false,
    error_patterns: []ExpectedErrorPattern,
    warning_patterns: []ExpectedWarningPattern,
    aux_patterns: []ExpectedAuxPattern,
    output_patterns: []ExpectedOutputPattern,
    prune_output_patterns: []PruneOutputPattern,
};

pub const SupportedDgOptions = struct {
    bounds_check: bool = false,
    range_check: bool = false,
    fbackslash: bool = false,
    allow_argument_mismatch: bool = false,
};

pub fn collectRunnableCases(
    persist_allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    tests_dir: []const u8,
    filter: ?[]const u8,
    skips: *SkipCounts,
) ![]TestCase {
    var list: std.ArrayList(TestCase) = .empty;
    var dir = try zig_api.cwd().openDir(tests_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(temp_allocator);
    defer walker.deinit();

    while (try walker.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!isFortranSource(entry.path)) continue;
        if (filter) |needle| {
            if (!std.mem.containsAtLeast(u8, entry.path, 1, needle)) continue;
        }

        skips.total_sources += 1;

        const classification = try classifyCase(persist_allocator, temp_allocator, tests_dir, entry.path);
        const expectations = switch (classification) {
            .skip => |skip_reason| {
                skips.add(skip_reason);
                continue;
            },
            .runnable => |value| value,
        };

        const input_path = try std.fs.path.join(persist_allocator, &.{ tests_dir, entry.path });
        const rel_path = try persist_allocator.dupe(u8, entry.path);
        const work_name = try makeWorkName(persist_allocator, entry.path);
        try list.append(persist_allocator, .{
            .input_path = input_path,
            .rel_path = rel_path,
            .work_name = work_name,
            .bounds_check = expectations.bounds_check,
            .range_check = expectations.range_check,
            .fbackslash = expectations.fbackslash,
            .allow_argument_mismatch = expectations.allow_argument_mismatch,
            .expect_compile_error = expectations.expect_compile_error,
            .expect_should_fail = expectations.expect_should_fail,
            .expected_error_patterns = expectations.expected_error_patterns,
            .expected_warning_patterns = expectations.expected_warning_patterns,
            .expected_aux_patterns = expectations.expected_aux_patterns,
            .expected_output_patterns = expectations.expected_output_patterns,
            .prune_output_patterns = expectations.prune_output_patterns,
        });
    }

    std.sort.heap(TestCase, list.items, {}, testCaseLessThan);
    return list.toOwnedSlice(persist_allocator);
}

fn testCaseLessThan(_: void, a: TestCase, b: TestCase) bool {
    return std.mem.order(u8, a.input_path, b.input_path) == .lt;
}

pub fn classifyCase(
    persist_allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    tests_dir: []const u8,
    rel_path: []const u8,
) !CaseClassification {
    if (isPreprocessedFortran(rel_path)) return .{ .skip = .preprocessed_source };

    const input_path = try std.fs.path.join(temp_allocator, &.{ tests_dir, rel_path });
    defer temp_allocator.free(input_path);

    const bytes = zig_api.cwd().readFileAlloc(temp_allocator, input_path, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileTooBig => return .{ .skip = .unsupported_dejagnu },
        else => return err,
    };
    defer temp_allocator.free(bytes);

    const dg_do = parseDgDoKind(bytes);
    if (dg_do == .none) return .{ .skip = .no_dg_do };
    if (dg_do != .compile) return .{ .skip = .do_not_compile };
    if (dgDoHasTargetGuard(bytes)) return .{ .skip = .dg_do_target_guarded };
    if (hasTargetPredicates(bytes)) return .{ .skip = .target_predicate };
    if (hasAdditionalSources(bytes)) return .{ .skip = .additional_sources };
    if (hasUnsupportedDgOptions(bytes)) return .{ .skip = .unsupported_dg_options };
    if (hasUnsupportedDejagnu(bytes)) return .{ .skip = .unsupported_dejagnu };

    const parsed_diag = try parseDiagDirectives(persist_allocator, bytes);
    const supported_options = parseSupportedDgOptions(bytes);

    return .{ .runnable = .{
        .bounds_check = supported_options.bounds_check,
        .range_check = supported_options.range_check,
        .fbackslash = supported_options.fbackslash,
        .allow_argument_mismatch = supported_options.allow_argument_mismatch,
        .expect_compile_error = parsed_diag.has_error,
        .expect_should_fail = parsed_diag.has_should_fail,
        .expected_error_patterns = parsed_diag.error_patterns,
        .expected_warning_patterns = parsed_diag.warning_patterns,
        .expected_aux_patterns = parsed_diag.aux_patterns,
        .expected_output_patterns = parsed_diag.output_patterns,
        .prune_output_patterns = parsed_diag.prune_output_patterns,
    } };
}

fn parseDgDoKind(text: []const u8) DgDoKind {
    const idx = indexOfNoCase(text, "dg-do") orelse return .none;
    var i = idx + "dg-do".len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '{' or text[i] == '}')) : (i += 1) {}
    const start = i;
    while (i < text.len and (std.ascii.isAlphabetic(text[i]) or text[i] == '-' or text[i] == '_')) : (i += 1) {}
    if (i <= start) return .other;
    const token = text[start..i];
    if (eqlNoCase(token, "compile")) return .compile;
    if (eqlNoCase(token, "run")) return .run;
    if (eqlNoCase(token, "link")) return .link;
    if (eqlNoCase(token, "assemble")) return .assemble;
    if (eqlNoCase(token, "preprocess")) return .preprocess;
    return .other;
}

fn dgDoHasTargetGuard(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = trimCr(raw_line);
        if (!containsNoCase(line, "dg-do")) continue;
        if (!containsNoCase(line, "target")) continue;
        const target_expr = extractTargetExpr(line) orelse return true;
        if (!isUniversalTargetExpr(target_expr)) return true;
    }
    return false;
}

fn extractTargetExpr(line: []const u8) ?[]const u8 {
    const idx = indexOfNoCase(line, "target") orelse return null;
    var rest = line[idx + "target".len ..];
    rest = std.mem.trimStart(u8, rest, " \t");
    if (rest.len == 0) return null;

    if (rest[0] == '{') {
        var depth: usize = 0;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const ch = rest[i];
            if (ch == '{') depth += 1 else if (ch == '}') {
                if (depth == 0) break;
                depth -= 1;
                if (depth == 0) {
                    const inner = rest[1..i];
                    return std.mem.trim(u8, inner, " \t");
                }
            }
        }
        if (rest.len <= 1) return null;
        return std.mem.trim(u8, rest[1..], " \t}");
    }

    const end = std.mem.indexOfScalar(u8, rest, '}') orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \t");
}

fn isUniversalTargetExpr(expr: []const u8) bool {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const ch = expr[i];
        if (ch == ' ' or ch == '\t' or ch == '"' or ch == '\'') continue;
        if (ch == '\\' and i + 1 < expr.len) {
            const next = expr[i + 1];
            if (next == '*' or next == '-') continue;
        }
        if (ch == '{' or ch == '}') continue;
        if (n >= buf.len) return false;
        buf[n] = ch;
        n += 1;
    }
    return std.mem.eql(u8, buf[0..n], "*-*-*");
}

fn hasTargetPredicates(text: []const u8) bool {
    return containsNoCase(text, "dg-skip-if") or
        containsNoCase(text, "dg-require-effective-target") or
        containsNoCase(text, "dg-require-visibility");
}

fn hasAdditionalSources(text: []const u8) bool {
    return containsNoCase(text, "dg-additional-sources") or
        containsNoCase(text, "dg-compile-aux-modules");
}

fn hasUnsupportedDejagnu(text: []const u8) bool {
    // Keep only directives that materially change orchestration beyond this runner's model.
    // Many dg-* checks (dg-final/dg-optimized/dg-lto-*/dg-add-options/...) are post-pass
    // or driver-detail assertions and are treated as no-op instead of hard skip.
    return containsNoCase(text, "dg-runtest") or
        containsNoCase(text, "dg-extra-ld-options");
}

fn hasUnsupportedDgOptions(text: []const u8) bool {
    if (containsNoCase(text, "dg-add-options")) return true;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = trimCr(raw_line);
        if (!containsNoCase(line, "dg-options") and !containsNoCase(line, "dg-additional-options")) continue;

        if (containsNoCase(line, "dg-options")) {
            const payload = extractDirectivePattern(line, "dg-options") orelse return true;
            if (optionsTextHasUnsupportedFlags(payload)) return true;
        }
        if (containsNoCase(line, "dg-additional-options")) {
            const payload = extractDirectivePattern(line, "dg-additional-options") orelse return true;
            if (optionsTextHasUnsupportedFlags(payload)) return true;
        }
    }
    return false;
}

fn optionsTextHasUnsupportedFlags(text: []const u8) bool {
    return containsNoCase(text, "-std=") or
        containsNoCase(text, "-fopenmp") or
        containsNoCase(text, "-fopenacc") or
        containsNoCase(text, "-fcoarray") or
        containsNoCase(text, "-cpp") or
        containsNoCase(text, "-nocpp") or
        containsNoCase(text, "-ffixed-form") or
        containsNoCase(text, "-ffree-form") or
        containsNoCase(text, "-fdec");
}

fn parseSupportedDgOptions(text: []const u8) SupportedDgOptions {
    var result: SupportedDgOptions = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = trimCr(raw_line);
        if (!containsNoCase(line, "dg-options") and !containsNoCase(line, "dg-additional-options")) continue;
        if (containsNoCase(line, "-fcheck=bounds")) result.bounds_check = true;
        if (containsNoCase(line, "-fno-range-check")) result.range_check = false;
        if (containsNoCase(line, "-frange-check")) result.range_check = true;
        if (containsNoCase(line, "-fno-backslash")) result.fbackslash = false;
        if (containsNoCase(line, "-fbackslash")) result.fbackslash = true;
        if (containsNoCase(line, "-fallow-argument-mismatch")) result.allow_argument_mismatch = true;
    }
    return result;
}

fn parseDiagDirectives(allocator: std.mem.Allocator, text: []const u8) !ParsedDiagDirectives {
    var errors: std.ArrayList(ExpectedErrorPattern) = .empty;
    var warnings: std.ArrayList(ExpectedWarningPattern) = .empty;
    var aux: std.ArrayList(ExpectedAuxPattern) = .empty;
    var outputs: std.ArrayList(ExpectedOutputPattern) = .empty;
    var prune_outputs: std.ArrayList(PruneOutputPattern) = .empty;
    errdefer {
        for (errors.items) |item| allocator.free(item.pattern);
        errors.deinit(allocator);
        for (warnings.items) |item| allocator.free(item.pattern);
        warnings.deinit(allocator);
        for (aux.items) |item| allocator.free(item.pattern);
        aux.deinit(allocator);
        for (outputs.items) |item| allocator.free(item.pattern);
        outputs.deinit(allocator);
        for (prune_outputs.items) |item| allocator.free(item.pattern);
        prune_outputs.deinit(allocator);
    }

    var has_error = false;
    var has_should_fail = false;

    var line_no: usize = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| : (line_no += 1) {
        const line = trimCr(raw_line);
        if (!containsNoCase(line, "dg-")) continue;
        if (directiveIsXfail(line)) continue;
        if (!directiveAppliesToHost(line)) continue;

        if (containsNoCase(line, "dg-error")) {
            has_error = true;
            const pattern_text = extractDirectivePattern(line, "dg-error") orelse "";
            const cleaned = try normalizeExpectedPattern(allocator, pattern_text);
            try errors.append(allocator, .{
                .pattern = cleaned,
                .line_no = line_no,
            });
            continue;
        }
        if (containsNoCase(line, "dg-shouldfail")) {
            has_should_fail = true;
            continue;
        }
        if (containsNoCase(line, "dg-warning")) {
            const pattern_text = extractDirectivePattern(line, "dg-warning") orelse "";
            const cleaned = try normalizeExpectedPattern(allocator, pattern_text);
            try warnings.append(allocator, .{
                .pattern = cleaned,
                .line_no = line_no,
            });
            continue;
        }
        if (containsNoCase(line, "dg-message")) {
            const pattern_text = extractDirectivePattern(line, "dg-message") orelse "";
            const cleaned = try normalizeExpectedPattern(allocator, pattern_text);
            try aux.append(allocator, .{
                .pattern = cleaned,
                .line_no = line_no,
                .kind = .message,
            });
            continue;
        }
        if (containsNoCase(line, "dg-note")) {
            const pattern_text = extractDirectivePattern(line, "dg-note") orelse "";
            const cleaned = try normalizeExpectedPattern(allocator, pattern_text);
            try aux.append(allocator, .{
                .pattern = cleaned,
                .line_no = line_no,
                .kind = .note,
            });
            continue;
        }
        if (containsNoCase(line, "dg-bogus")) {
            const pattern_text = extractDirectivePattern(line, "dg-bogus") orelse "";
            const cleaned = try normalizeExpectedPattern(allocator, pattern_text);
            try aux.append(allocator, .{
                .pattern = cleaned,
                .line_no = line_no,
                .kind = .bogus,
            });
            continue;
        }
        if (containsNoCase(line, "dg-output")) {
            const pattern_text = extractDirectivePattern(line, "dg-output") orelse "";
            const cleaned = try normalizeExpectedPattern(allocator, pattern_text);
            try outputs.append(allocator, .{
                .pattern = cleaned,
                .line_no = line_no,
            });
            continue;
        }
        if (containsNoCase(line, "dg-prune-output")) {
            const pattern_text = extractDirectivePattern(line, "dg-prune-output") orelse "";
            const cleaned = try normalizeExpectedPattern(allocator, pattern_text);
            try prune_outputs.append(allocator, .{
                .pattern = cleaned,
                .line_no = line_no,
            });
            continue;
        }
    }

    return .{
        .has_error = has_error,
        .has_should_fail = has_should_fail,
        .error_patterns = try errors.toOwnedSlice(allocator),
        .warning_patterns = try warnings.toOwnedSlice(allocator),
        .aux_patterns = try aux.toOwnedSlice(allocator),
        .output_patterns = try outputs.toOwnedSlice(allocator),
        .prune_output_patterns = try prune_outputs.toOwnedSlice(allocator),
    };
}

fn directiveAppliesToHost(line: []const u8) bool {
    const guard_idx = indexOfNoCase(line, "{ target") orelse return true;
    const target_expr = extractTargetExpr(line[guard_idx..]) orelse return false;
    return isUniversalTargetExpr(target_expr);
}

fn directiveIsXfail(line: []const u8) bool {
    return containsNoCase(line, "{ xfail") or
        containsNoCase(line, " xfail ");
}

fn extractDirectivePattern(line: []const u8, directive: []const u8) ?[]const u8 {
    const idx = indexOfNoCase(line, directive) orelse return null;
    var i = idx + directive.len;
    while (i < line.len and line[i] != '"') : (i += 1) {}
    if (i >= line.len) return null;
    i += 1;
    const start = i;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            if (i + 1 < line.len) i += 1;
            continue;
        }
        if (line[i] == '"') return line[start..i];
    }
    return null;
}

fn normalizeExpectedPattern(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, pattern.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];
        if (ch == '\\' and i + 1 < pattern.len) {
            const next = pattern[i + 1];
            switch (next) {
                '\\', '"' => {
                    try out.append(allocator, next);
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(allocator, ch);
    }

    const owned = try out.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, owned, " \t");
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return result;
}

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn indexOfNoCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) : (j += 1) {}
        if (j == needle.len) return i;
    }
    return null;
}

fn containsNoCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfNoCase(haystack, needle) != null;
}

fn eqlNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}

fn normalizeForMatch(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var prev_space = true;
    for (text) |ch_raw| {
        const ch = std.ascii.toLower(ch_raw);
        const is_space = ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
        if (is_space) {
            if (!prev_space) {
                try out.append(allocator, ' ');
                prev_space = true;
            }
            continue;
        }
        try out.append(allocator, ch);
        prev_space = false;
    }
    const owned = try out.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, owned, " ");
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return result;
}

pub fn patternHasRegexMeta(pattern: []const u8) bool {
    for (pattern) |ch| {
        switch (ch) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => return true,
            else => {},
        }
    }
    return false;
}

fn orderedTokensMatch(allocator: std.mem.Allocator, actual: []const u8, pattern: []const u8) !bool {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(allocator);
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (!(std.ascii.isAlphabetic(pattern[i]) or std.ascii.isDigit(pattern[i]) or pattern[i] == '_')) continue;
        const start = i;
        i += 1;
        while (i < pattern.len and (std.ascii.isAlphabetic(pattern[i]) or std.ascii.isDigit(pattern[i]) or pattern[i] == '_')) : (i += 1) {}
        const token = pattern[start..i];
        if (token.len >= 3) try tokens.append(allocator, token);
        if (i == 0) break;
        i -= 1;
    }

    if (tokens.items.len == 0) {
        const bare = try stripRegexMeta(allocator, pattern);
        defer allocator.free(bare);
        if (bare.len == 0) return true;
        return std.mem.indexOf(u8, actual, bare) != null;
    }

    var cursor: usize = 0;
    for (tokens.items) |token| {
        const found = std.mem.indexOfPos(u8, actual, cursor, token) orelse return false;
        cursor = found + token.len;
    }
    return true;
}

pub fn stripRegexMeta(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (pattern) |ch| {
        switch (ch) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\' => {},
            else => try out.append(allocator, ch),
        }
    }
    const owned = try out.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, owned, " ");
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(owned);
    return result;
}

pub fn matchExpectedPattern(allocator: std.mem.Allocator, pattern: []const u8, actual: []const u8) !bool {
    if (pattern.len == 0) return true;
    const pattern_norm = try normalizeForMatch(allocator, pattern);
    defer allocator.free(pattern_norm);
    if (pattern_norm.len == 0) return true;

    const actual_norm = try normalizeForMatch(allocator, actual);
    defer allocator.free(actual_norm);

    if (!patternHasRegexMeta(pattern_norm)) {
        return std.mem.indexOf(u8, actual_norm, pattern_norm) != null;
    }
    return orderedTokensMatch(allocator, actual_norm, pattern_norm);
}

fn isFortranSource(path: []const u8) bool {
    const exts = [_][]const u8{
        ".f",
        ".for",
        ".f77",
        ".f90",
        ".f95",
        ".f03",
        ".f08",
        ".F",
        ".FOR",
        ".F77",
        ".F90",
        ".F95",
        ".F03",
        ".F08",
    };
    for (exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

fn isPreprocessedFortran(path: []const u8) bool {
    const preprocessed_exts = [_][]const u8{
        ".F",
        ".FOR",
        ".F77",
        ".F90",
        ".F95",
        ".F03",
        ".F08",
    };
    for (preprocessed_exts) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

pub fn makeWorkName(allocator: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
    var hasher = std.hash.XxHash64.init(0);
    hasher.update(rel_path);
    const digest = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{digest});
}

pub fn countExpectedErrorCases(cases: []const TestCase) usize {
    var count: usize = 0;
    for (cases) |case| {
        if (case.expect_compile_error) count += 1;
    }
    return count;
}

pub fn countExpectedShouldFailCases(cases: []const TestCase) usize {
    var count: usize = 0;
    for (cases) |case| {
        if (case.expect_should_fail) count += 1;
    }
    return count;
}

pub fn countExpectedWarningCases(cases: []const TestCase) usize {
    var count: usize = 0;
    for (cases) |case| {
        if (case.expected_warning_patterns.len > 0) count += 1;
    }
    return count;
}

pub fn countExpectedAuxCases(cases: []const TestCase) usize {
    var count: usize = 0;
    for (cases) |case| {
        if (case.expected_aux_patterns.len > 0) count += 1;
    }
    return count;
}

pub fn countExpectedOutputCases(cases: []const TestCase) usize {
    var count: usize = 0;
    for (cases) |case| {
        if (case.expected_output_patterns.len > 0 or case.prune_output_patterns.len > 0) count += 1;
    }
    return count;
}

