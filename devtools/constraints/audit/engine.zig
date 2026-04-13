const std = @import("std");
const Col6Forge = @import("Col6Forge");
const model = @import("../model.zig");
const registry = @import("../registry.zig");
const declarations = @import("declarations.zig");
const domains = @import("domains.zig");
const imports = @import("imports.zig");
const symbols = @import("symbols.zig");
const zig_ast = @import("zig_ast/mod.zig");

const CombinedSymbolIndex = struct {
    lexical: symbols.Index,
    ast_source: ?zig_ast.source_index.Index = null,

    fn deinit(self: *CombinedSymbolIndex, allocator: std.mem.Allocator) void {
        self.lexical.deinit(allocator);
        if (self.ast_source) |*index| index.deinit(allocator);
        self.* = undefined;
    }

    fn findFunctionCall(self: CombinedSymbolIndex, symbol_name: []const u8, backend: model.RuleBackend) ?usize {
        return switch (backend) {
            .lexical_only => self.lexical.findFunctionCall(symbol_name),
            .ast_only => self.findAstFunctionCall(symbol_name),
            .kind_default => unreachable,
        };
    }

    fn findFunctionCallOutsidePath(self: CombinedSymbolIndex, symbol_name: []const u8, required_path: []const u8, backend: model.RuleBackend) ?usize {
        return switch (backend) {
            .lexical_only => self.lexical.findFunctionCallOutsidePath(symbol_name, required_path),
            .ast_only => self.findAstFunctionCallOutsidePath(symbol_name, required_path),
            .kind_default => unreachable,
        };
    }

    fn findAliasOutsidePath(self: CombinedSymbolIndex, symbol_name: []const u8, required_path: []const u8, backend: model.RuleBackend) ?usize {
        return switch (backend) {
            .lexical_only => self.lexical.findAliasOutsidePath(symbol_name, required_path),
            .ast_only => self.findAstAliasOutsidePath(symbol_name, required_path),
            .kind_default => unreachable,
        };
    }

    fn findAnyAlias(self: CombinedSymbolIndex, symbol_name: []const u8, backend: model.RuleBackend) ?usize {
        return switch (backend) {
            .lexical_only => self.lexical.findAnyAlias(symbol_name),
            .ast_only => self.findAstAnyAlias(symbol_name),
            .kind_default => unreachable,
        };
    }

    fn findFirstSymbolUse(self: CombinedSymbolIndex, symbol_name: []const u8, backend: model.RuleBackend) ?usize {
        const call_idx = self.findFunctionCall(symbol_name, backend);
        const alias_idx = self.findAnyAlias(symbol_name, backend);
        return switch (call_idx != null) {
            true => switch (alias_idx != null) {
                true => @min(call_idx.?, alias_idx.?),
                false => call_idx.?,
            },
            false => alias_idx,
        };
    }

    fn findMemberAccessPath(self: CombinedSymbolIndex, needle: []const u8, backend: model.RuleBackend) ?usize {
        return switch (backend) {
            .lexical_only => self.lexical.findMemberAccessPath(needle),
            .ast_only => self.findAstMemberAccessPath(needle),
            .kind_default => unreachable,
        };
    }

    fn findImportLiteralContaining(self: CombinedSymbolIndex, text: []const u8, fragment: []const u8, backend: model.RuleBackend) ?usize {
        return switch (backend) {
            .lexical_only => findLexicalImportLiteralContaining(text, fragment),
            .ast_only => self.findAstImportLiteralContaining(fragment),
            .kind_default => unreachable,
        };
    }

    fn findOwnedSymbolDefinition(self: CombinedSymbolIndex, text: []const u8, symbol_name: []const u8, definition_kind: model.DefinitionKind, backend: model.RuleBackend) ?usize {
        return switch (backend) {
            .lexical_only => declarations.findOwnedSymbolDefinition(text, symbol_name, definition_kind),
            .ast_only => self.findAstOwnedSymbolDefinition(symbol_name, definition_kind),
            .kind_default => unreachable,
        };
    }

    fn findAstFunctionCall(self: CombinedSymbolIndex, symbol_name: []const u8) ?usize {
        const index = self.ast_source orelse return null;
        return index.symbols.findFunctionCall(symbol_name);
    }

    fn findAstFunctionCallOutsidePath(self: CombinedSymbolIndex, symbol_name: []const u8, required_path: []const u8) ?usize {
        const index = self.ast_source orelse return null;
        return index.symbols.findFunctionCallOutsidePath(symbol_name, required_path);
    }

    fn findAstAliasOutsidePath(self: CombinedSymbolIndex, symbol_name: []const u8, required_path: []const u8) ?usize {
        const index = self.ast_source orelse return null;
        return index.symbols.findAliasOutsidePath(symbol_name, required_path);
    }

    fn findAstAnyAlias(self: CombinedSymbolIndex, symbol_name: []const u8) ?usize {
        const index = self.ast_source orelse return null;
        return index.symbols.findAnyAlias(symbol_name);
    }

    fn findAstMemberAccessPath(self: CombinedSymbolIndex, needle: []const u8) ?usize {
        const index = self.ast_source orelse return null;
        return index.symbols.findMemberAccessPath(needle);
    }

    fn findAstImportLiteralContaining(self: CombinedSymbolIndex, fragment: []const u8) ?usize {
        const index = self.ast_source orelse return null;
        return index.imports.findLiteralContaining(fragment);
    }

    fn findAstOwnedSymbolDefinition(self: CombinedSymbolIndex, symbol_name: []const u8, definition_kind: model.DefinitionKind) ?usize {
        const index = self.ast_source orelse return null;
        return index.definitions.findOwnedSymbolDefinition(symbol_name, definition_kind);
    }
};

pub fn run(allocator: std.mem.Allocator, root: []const u8) !usize {
    try registry.validateRules();

    var failures: usize = 0;
    try scanTree(allocator, root, &failures);
    try runProjectRules(&failures);
    return failures;
}

fn scanTree(allocator: std.mem.Allocator, root: []const u8, failures: *usize) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
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

        if (registry.isAllowedCompatFile(rel_path)) continue;

        const domain = domains.classify(rel_path) orelse {
            std.log.err("{s}: unclassified source file; add it to the constraints domain registry", .{rel_path});
            failures.* += 1;
            continue;
        };

        const text = try std.fs.cwd().readFileAlloc(allocator, rel_path, 16 * 1024 * 1024);
        defer allocator.free(text);

        try scanFile(allocator, rel_path, domain, text, failures);
    }
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return out;
}

fn scanFile(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    domain: model.SourceDomain,
    text: []const u8,
    failures: *usize,
) !void {
    var symbol_index: CombinedSymbolIndex = .{
        .lexical = try symbols.buildIndex(allocator, text),
        .ast_source = null,
    };
    defer symbol_index.deinit(allocator);

    symbol_index.ast_source = try zig_ast.source_index.buildIndex(allocator, text);

    for (registry.file_rules) |rule| {
        if (!registry.ruleAppliesToFile(rule, rel_path, domain)) continue;
        try applyFileRule(rule, rel_path, domain, text, symbol_index, failures);
    }
}

fn applyFileRule(
    rule: model.AuditRule,
    rel_path: []const u8,
    domain: model.SourceDomain,
    text: []const u8,
    symbol_index: CombinedSymbolIndex,
    failures: *usize,
) !void {
    _ = domain;
    const backend = model.effectiveBackend(rule);
    switch (rule.kind) {
        .forbidden_text => {
            const needle = rule.needle orelse return error.AuditRuleMissingNeedle;
            if (std.mem.indexOf(u8, text, needle)) |idx| {
                reportViolation(rel_path, idx, text, rule.id, rule.title, needle);
                failures.* += 1;
            }
        },
        .forbidden_import_path_fragment => {
            const fragment = rule.needle orelse return error.AuditRuleMissingNeedle;
            if (symbol_index.findImportLiteralContaining(text, fragment, backend)) |idx| {
                reportViolation(rel_path, idx, text, rule.id, rule.title, fragment);
                failures.* += 1;
            }
        },
        .forbidden_function_call => {
            const symbol_name = rule.symbol_name orelse return error.AuditRuleMissingSymbolName;
            if (symbol_index.findFunctionCall(symbol_name, backend)) |idx| {
                reportViolation(rel_path, idx, text, rule.id, rule.title, symbol_name);
                failures.* += 1;
            }
        },
        .owned_symbol_usage => try applyOwnedSymbolUsage(rule, rel_path, text, symbol_index, failures),
        .forbidden_member_access_path => {
            const needle = rule.needle orelse return error.AuditRuleMissingNeedle;
            if (symbol_index.findMemberAccessPath(needle, backend)) |idx| {
                reportViolation(rel_path, idx, text, rule.id, rule.title, needle);
                failures.* += 1;
            }
        },
        .owned_symbol_definition => {
            const symbol_name = rule.symbol_name orelse return error.AuditRuleMissingSymbolName;
            const owner_path = rule.owner_exact_path orelse return error.AuditRuleMissingOwnerPath;
            const definition_kind = rule.definition_kind orelse return error.AuditRuleMissingDefinitionKind;
            if (std.mem.eql(u8, rel_path, owner_path)) return;
            if (symbol_index.findOwnedSymbolDefinition(text, symbol_name, definition_kind, backend)) |idx| {
                reportViolation(rel_path, idx, text, rule.id, rule.title, symbol_name);
                failures.* += 1;
            }
        },
        .bare_error_code_literal => scanBareErrorCodeLiterals(rule, rel_path, text, failures),
        .error_catalog_consistency => return error.InvalidFileRuleKind,
    }
}

fn applyOwnedSymbolUsage(
    rule: model.AuditRule,
    rel_path: []const u8,
    text: []const u8,
    symbol_index: CombinedSymbolIndex,
    failures: *usize,
) !void {
    const symbol_name = rule.symbol_name orelse return error.AuditRuleMissingSymbolName;
    const backend = model.effectiveBackend(rule);
    const first_use_idx = symbol_index.findFirstSymbolUse(symbol_name, backend) orelse return;

    if (rule.needle) |fragment| {
        if (symbol_index.findImportLiteralContaining(text, fragment, backend) == null) {
            reportViolation(rel_path, first_use_idx, text, rule.id, rule.title, fragment);
            failures.* += 1;
            return;
        }
    }

    if (rule.call_path) |required_call_path| {
        if (symbol_index.findFunctionCallOutsidePath(symbol_name, required_call_path, backend)) |idx| {
            reportViolation(rel_path, idx, text, rule.id, rule.title, required_call_path);
            failures.* += 1;
            return;
        }
    }

    if (rule.alias_path) |required_alias_path| {
        if (symbol_index.findAliasOutsidePath(symbol_name, required_alias_path, backend)) |idx| {
            reportViolation(rel_path, idx, text, rule.id, rule.title, required_alias_path);
            failures.* += 1;
        }
    }
}

fn findLexicalImportLiteralContaining(text: []const u8, fragment: []const u8) ?usize {
    var cursor: usize = 0;
    while (imports.findNextLiteral(text, cursor)) |match| {
        cursor = match.next_cursor;
        if (std.mem.indexOf(u8, match.literal, fragment) != null) return match.start_idx;
    }
    return null;
}

fn scanBareErrorCodeLiterals(
    rule: model.AuditRule,
    rel_path: []const u8,
    text: []const u8,
    failures: *usize,
) void {
    var idx: usize = 0;
    while (idx + 7 < text.len) : (idx += 1) {
        if (text[idx] != '"') continue;
        if (text[idx + 1] != 'C' or text[idx + 2] != 'F') continue;
        if (!std.ascii.isDigit(text[idx + 3]) or !std.ascii.isDigit(text[idx + 4]) or !std.ascii.isDigit(text[idx + 5]) or !std.ascii.isDigit(text[idx + 6])) continue;
        if (text[idx + 7] != '"') continue;

        reportViolation(rel_path, idx, text, rule.id, rule.title, text[idx + 1 .. idx + 7]);
        failures.* += 1;
    }
}

fn runProjectRules(failures: *usize) !void {
    for (registry.project_rules) |rule| {
        switch (rule.kind) {
            .error_catalog_consistency => verifyErrorCatalog(rule, failures),
            else => return error.InvalidProjectRuleKind,
        }
    }
}

fn verifyErrorCatalog(rule: model.AuditRule, failures: *usize) void {
    const docs = Col6Forge.error_catalog.allDocs();

    for (docs, 0..) |entry, idx| {
        if (entry.stage.len == 0 or entry.info.code.len == 0 or entry.info.message.len == 0) {
            std.log.err("[{s}] {s}: error catalog entry {d} is incomplete", .{ rule.id, rule.title, idx });
            failures.* += 1;
        }
        if (idx > 0 and std.mem.order(u8, docs[idx - 1].info.code, entry.info.code) != .lt) {
            std.log.err(
                "[{s}] {s}: error catalog ordering regression: {s} then {s}",
                .{ rule.id, rule.title, docs[idx - 1].info.code, entry.info.code },
            );
            failures.* += 1;
        }
        for (docs[idx + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.info.code, other.info.code)) {
                std.log.err("[{s}] {s}: duplicate error code in catalog: {s}", .{ rule.id, rule.title, entry.info.code });
                failures.* += 1;
            }
        }
    }
}

fn reportViolation(
    rel_path: []const u8,
    idx: usize,
    text: []const u8,
    rule_id: []const u8,
    title: []const u8,
    detail: []const u8,
) void {
    const line = 1 + std.mem.count(u8, text[0..idx], "\n");
    std.log.err("{s}:{d}: [{s}] forbidden {s}: `{s}`", .{ rel_path, line, rule_id, title, detail });
}
