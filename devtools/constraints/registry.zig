const std = @import("std");
const model = @import("model.zig");
const rules = @import("rules/mod.zig");

pub const file_rules =
    rules.text.file_rules ++
    rules.legacy_calls.file_rules ++
    rules.usage.file_rules ++
    rules.imports.file_rules ++
    rules.ownership.file_rules;

pub const project_rules = rules.project.project_rules;

pub fn validateRules() !void {
    for (file_rules, 0..) |rule, idx| {
        try validateRule(rule);
        for (file_rules[idx + 1 ..]) |other| {
            if (std.mem.eql(u8, rule.id, other.id)) return error.DuplicateAuditRuleId;
        }
    }
    for (project_rules, 0..) |rule, idx| {
        try validateRule(rule);
        for (project_rules[idx + 1 ..]) |other| {
            if (std.mem.eql(u8, rule.id, other.id)) return error.DuplicateAuditRuleId;
        }
    }
    for (file_rules) |file_rule| {
        for (project_rules) |project_rule| {
            if (std.mem.eql(u8, file_rule.id, project_rule.id)) return error.DuplicateAuditRuleId;
        }
    }
}

fn validateRule(rule: model.AuditRule) !void {
    if (rule.id.len == 0 or rule.title.len == 0) return error.IncompleteAuditRule;
    const backend = model.effectiveBackend(rule);
    switch (rule.kind) {
        .forbidden_text, .forbidden_import_path_fragment, .forbidden_member_access_path => if (rule.needle == null or rule.needle.?.len == 0) return error.AuditRuleMissingNeedle,
        .forbidden_function_call => {
            if (rule.symbol_name == null or rule.symbol_name.?.len == 0) return error.AuditRuleMissingSymbolName;
            if (rule.needle != null) return error.AuditRuleUnexpectedNeedle;
            if (rule.call_path != null) return error.AuditRuleUnexpectedCallPath;
            if (rule.alias_path != null) return error.AuditRuleUnexpectedAliasPath;
        },
        .owned_symbol_usage => {
            if (rule.symbol_name == null or rule.symbol_name.?.len == 0) return error.AuditRuleMissingSymbolName;
            const has_import = rule.needle != null and rule.needle.?.len != 0;
            const has_call_path = rule.call_path != null and rule.call_path.?.len != 0;
            const has_alias_path = rule.alias_path != null and rule.alias_path.?.len != 0;
            if (!has_import and !has_call_path and !has_alias_path) return error.AuditRuleMissingUsageConstraint;
        },
        .owned_symbol_definition => {
            if (rule.symbol_name == null or rule.symbol_name.?.len == 0) return error.AuditRuleMissingSymbolName;
            if (rule.owner_exact_path == null or rule.owner_exact_path.?.len == 0) return error.AuditRuleMissingOwnerPath;
            if (rule.definition_kind == null) return error.AuditRuleMissingDefinitionKind;
            if (rule.needle != null) return error.AuditRuleUnexpectedNeedle;
            if (rule.call_path != null) return error.AuditRuleUnexpectedCallPath;
            if (rule.alias_path != null) return error.AuditRuleUnexpectedAliasPath;
        },
        .bare_error_code_literal, .error_catalog_consistency => {
            if (rule.needle != null) return error.AuditRuleUnexpectedNeedle;
            if (rule.call_path != null) return error.AuditRuleUnexpectedCallPath;
            if (rule.alias_path != null) return error.AuditRuleUnexpectedAliasPath;
        },
    }
    switch (rule.kind) {
        .forbidden_text, .bare_error_code_literal, .error_catalog_consistency => {
            if (backend == .ast_only) return error.AuditRuleInvalidBackend;
        },
        else => {},
    }
}

pub fn isAllowedCompatFile(rel_path: []const u8) bool {
    return std.mem.eql(u8, rel_path, "src/semantic/symbol/entity.zig") or
        std.mem.eql(u8, rel_path, "src/tools/error_catalog_docgen.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/architecture_audit.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/model.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/registry.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/rules/text.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/rules/legacy_calls.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/rules/usage.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/rules/imports.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/rules/ownership.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/rules/project.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/rules/mod.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/audit/declarations.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/audit/symbols.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/audit/engine.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/audit/imports.zig") or
        std.mem.eql(u8, rel_path, "devtools/constraints/audit/domains.zig");
}

pub fn ruleAppliesToFile(rule: model.AuditRule, rel_path: []const u8, domain: model.SourceDomain) bool {
    if (rule.exclude_tests and std.mem.indexOf(u8, rel_path, "/tests/") != null) return false;
    for (rule.excluded_exact_paths) |excluded| {
        if (std.mem.eql(u8, rel_path, excluded)) return false;
    }
    for (rule.excluded_path_prefixes) |excluded_prefix| {
        if (std.mem.startsWith(u8, rel_path, excluded_prefix)) return false;
    }
    return switch (rule.scope) {
        .any => true,
        .prefix => |prefix| std.mem.startsWith(u8, rel_path, prefix),
        .domain => |expected| expected == domain,
    };
}

test "allowed compat file is exempt" {
    try std.testing.expect(isAllowedCompatFile("src/semantic/symbol/entity.zig"));
    try std.testing.expect(isAllowedCompatFile("src/tools/error_catalog_docgen.zig"));
    try std.testing.expect(isAllowedCompatFile("devtools/constraints/architecture_audit.zig"));
    try std.testing.expect(!isAllowedCompatFile("src/semantic/analysis/resolve_symbols.zig"));
}

test "domain-scoped rule only applies inside its source domain" {
    const rule = model.AuditRule{
        .id = "AR-TEST-001",
        .title = "domain rule",
        .kind = .forbidden_text,
        .scope = .{ .domain = .semantic },
        .needle = "x",
    };
    try std.testing.expect(ruleAppliesToFile(rule, "src/semantic/a.zig", .semantic));
    try std.testing.expect(!ruleAppliesToFile(rule, "src/codegen/a.zig", .codegen));
}

test "prefix exclusions suppress otherwise matching rules" {
    const rule = model.AuditRule{
        .id = "AR-TEST-002",
        .title = "prefix exclusion rule",
        .kind = .owned_symbol_usage,
        .scope = .{ .prefix = "src/runtime/" },
        .needle = "runtime_args.zig",
        .symbol_name = "runtimeArgCount",
        .excluded_path_prefixes = &.{"src/runtime/facade/"},
    };
    try std.testing.expect(ruleAppliesToFile(rule, "src/runtime/core/a.zig", .runtime));
    try std.testing.expect(!ruleAppliesToFile(rule, "src/runtime/facade/a.zig", .runtime));
}

test "registry validates" {
    try validateRules();
}
