const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const logical_line = @import("../../logical_line.zig");
const lexer = @import("../../lexer.zig");
const context = @import("../token_stream.zig");
const parse_diag = @import("../diagnostic.zig");
const decl = @import("../decl/mod.zig");
const stmt = @import("../stmt/mod.zig");
const stmt_helpers = @import("../stmt/helpers.zig");
const array_info = @import("../array_info.zig");
const root_header = @import("header.zig");
const root_prelude = @import("prelude.zig");
const root_predicates = @import("predicates.zig");
const root_diagnostics = @import("diagnostics.zig");
const root_decl_diagnostics = @import("decl_diagnostics.zig");
const root_control = @import("control_helpers.zig");
const root_interface = @import("interface.zig");
const root_spec_eval = @import("spec_eval.zig");
const root_binding_owners = @import("binding_owners.zig");
const bind_recovery = @import("units/bind_recovery.zig");
const no_arg_check = @import("units/no_arg_check.zig");
const submodule_validation = @import("units/submodule_validation.zig");

const ProgramUnit = ast.ProgramUnit;
const Decl = ast.Decl;
const DeclSource = ast.DeclSource;
const Stmt = ast.Stmt;
const LineParser = context.LineParser;
const ProgramUnitHeader = root_header.ProgramUnitHeader;
const validateSubmoduleNameAvailability = submodule_validation.validateSubmoduleNameAvailability;
const noteInvalidSubmoduleVisibility = submodule_validation.noteInvalidSubmoduleVisibility;
const noteMissingSubmoduleProcedure = submodule_validation.noteMissingSubmoduleProcedure;
const validateSubmoduleVisibleGenericSpecificReuse = submodule_validation.validateSubmoduleVisibleGenericSpecificReuse;
const validateSubmoduleProcedureMatch = submodule_validation.validateSubmoduleProcedureMatch;
const formalCount = submodule_validation.formalCount;
const headerLineStartsModuleProcedure = submodule_validation.headerLineStartsModuleProcedure;
const lineHasModuleProcedurePrefix = submodule_validation.lineHasModuleProcedurePrefix;
const isEndProcedureTokens = submodule_validation.isEndProcedureTokens;
const noteInvalidModuleProcedureInterfaceBodyLines = submodule_validation.noteInvalidModuleProcedureInterfaceBodyLines;
const noteInvalidModuleProcedureInterfaceBodyDecls = submodule_validation.noteInvalidModuleProcedureInterfaceBodyDecls;

pub fn parseModuleContainer(self: anytype, units: *std.array_list.Managed(ProgramUnit)) !void {
    const module_header_source = root_diagnostics.sourceFromLine(self.lines[self.index]);
    const module_name = try self.moduleHeaderName(self.index);
    self.index += 1;
    var module_decls = std.array_list.Managed(Decl).init(self.arena);
    var module_decl_sources = std.array_list.Managed(DeclSource).init(self.arena);
    var module_uses = std.array_list.Managed(ast.UseStmt).init(self.arena);
    var module_param_ints = std.StringHashMap(i64).init(self.arena);
    var module_array_names = std.StringHashMap(array_info.ArrayInfo).init(self.arena);
    var saw_contains = false;
    while (self.index < self.lines.len) {
        const line = self.lines[self.index];
        root_diagnostics.noteFallbackForLine(self.diag_bag, line);
        if (self.isStandaloneEndAt(self.index)) {
            var stored_decls: []const Decl = try module_decls.toOwnedSlice();
            var stored_decl_sources: []const DeclSource = try module_decl_sources.toOwnedSlice();
            if (module_uses.items.len != 0) {
                const imported = try root_prelude.importPreludeDecls(self.arena, stored_decls, stored_decl_sources, module_uses.items, &self.module_preludes, self.diag_bag);
                stored_decls = imported.decls;
                stored_decl_sources = imported.decl_sources;
            }
            stored_decls = try root_binding_owners.annotateDeclBindingOwners(self.arena, stored_decls, module_name, .module);
            stored_decl_sources = try root_prelude.annotateDeclSourcesOwner(self.arena, stored_decl_sources, module_name);
            try self.module_preludes.put(module_name, .{
                .decls = stored_decls,
                .decl_sources = stored_decl_sources,
            });
            try units.append(.{
                .kind = .module,
                .name = module_name,
                .source = module_header_source,
                .args = &.{},
                .decls = @constCast(stored_decls),
                .decl_sources = @constCast(stored_decl_sources),
                .use_imports = try module_uses.toOwnedSlice(),
                .stmts = &.{},
                .expr_sources = &.{},
            });
            self.index += 1;
            return;
        }
        if (self.isModuleEndAt(self.index)) {
            var stored_decls: []const Decl = try module_decls.toOwnedSlice();
            var stored_decl_sources: []const DeclSource = try module_decl_sources.toOwnedSlice();
            if (module_uses.items.len != 0) {
                const imported = try root_prelude.importPreludeDecls(self.arena, stored_decls, stored_decl_sources, module_uses.items, &self.module_preludes, self.diag_bag);
                stored_decls = imported.decls;
                stored_decl_sources = imported.decl_sources;
            }
            stored_decls = try root_binding_owners.annotateDeclBindingOwners(self.arena, stored_decls, module_name, .module);
            stored_decl_sources = try root_prelude.annotateDeclSourcesOwner(self.arena, stored_decl_sources, module_name);
            try self.module_preludes.put(module_name, .{
                .decls = stored_decls,
                .decl_sources = stored_decl_sources,
            });
            try units.append(.{
                .kind = .module,
                .name = module_name,
                .source = module_header_source,
                .args = &.{},
                .decls = @constCast(stored_decls),
                .decl_sources = @constCast(stored_decl_sources),
                .use_imports = try module_uses.toOwnedSlice(),
                .stmts = &.{},
                .expr_sources = &.{},
            });
            self.index += 1;
            return;
        }
        if (self.isContainsAt(self.index)) {
            self.index += 1;
            saw_contains = true;
            break;
        }
        if (self.isInterfaceStartAt(self.index)) {
            const decl_node = self.parseInterfaceBlock() catch |err| {
                const tokens = self.tokensForIndex(self.index) catch |tok_err| {
                    root_diagnostics.setLexerOrLineDiagnostic(self.diag_bag, self.lex_diag_bag, line, tok_err);
                    return tok_err;
                };
                const lp = LineParser.init(line, tokens);
                root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, lp, err);
                return err;
            };
            try module_decls.append(decl_node);
            try module_decl_sources.append(root_diagnostics.sourceFromLine(line));
            continue;
        }
        const tokens = self.tokensForIndex(self.index) catch {
            self.index += 1;
            continue;
        };
        var lp = LineParser.init(line, tokens);
        if (try root_prelude.tryParsePreludeUseImport(&lp, self.arena)) |use_import| {
            try module_uses.append(use_import);
            self.index += 1;
            continue;
        }
        if (root_predicates.isDerivedTypeStartTokens(line, tokens)) {
            const decl_node = try self.parseDerivedTypeDef();
            try module_decls.append(decl_node);
            try module_decl_sources.append(root_diagnostics.sourceFromLine(line));
            continue;
        }
        if (decl.isDeclarationStart(lp)) {
            const decl_node = decl.parseDecl(&lp, self.arena) catch {
                self.index += 1;
                continue;
            };
            if (decl_node == .parameter) {
                try root_spec_eval.recordParamInts(&module_param_ints, decl_node.parameter.assigns);
            }
            try root_spec_eval.recordArrayNames(self.arena, &module_array_names, decl_node, &module_param_ints);
            try root_decl_diagnostics.noteDeclaratorInitializerShapeDiagnostics(
                self.arena,
                self.diag_bag,
                line,
                decl_node,
                &module_param_ints,
                &module_array_names,
            );
            try module_decls.append(decl_node);
            try module_decl_sources.append(root_diagnostics.sourceFromLine(line));
        } else if (moduleLineLooksLikeStatementFunction(lp)) {
            self.diag_bag.set(
                line.span.start_line,
                if (line.segments.len > 0) line.segments[0].column else 1,
                catalog.semantic.assignment_type_mismatch.code,
                "Unexpected STATEMENT FUNCTION",
                line.text,
            );
        }
        self.index += 1;
    }
    var stored_decls: []const Decl = try module_decls.toOwnedSlice();
    var stored_decl_sources: []const DeclSource = try module_decl_sources.toOwnedSlice();
    if (module_uses.items.len != 0) {
        const imported = try root_prelude.importPreludeDecls(self.arena, stored_decls, stored_decl_sources, module_uses.items, &self.module_preludes, self.diag_bag);
        stored_decls = imported.decls;
        stored_decl_sources = imported.decl_sources;
    }
    stored_decls = try root_binding_owners.annotateDeclBindingOwners(self.arena, stored_decls, module_name, .module);
    stored_decl_sources = try root_prelude.annotateDeclSourcesOwner(self.arena, stored_decl_sources, module_name);
    try self.module_preludes.put(module_name, .{
        .decls = stored_decls,
        .decl_sources = stored_decl_sources,
    });
    try units.append(.{
        .kind = .module,
        .name = module_name,
        .source = module_header_source,
        .args = &.{},
        .decls = @constCast(stored_decls),
        .decl_sources = @constCast(stored_decl_sources),
        .use_imports = try module_uses.toOwnedSlice(),
        .stmts = &.{},
        .expr_sources = &.{},
    });
    if (!saw_contains) return;

    while (self.index < self.lines.len) {
        root_diagnostics.noteFallbackForLine(self.diag_bag, self.lines[self.index]);
        if (self.isModuleEndAt(self.index)) {
            self.index += 1;
            return;
        }
        if (self.isStandaloneEndAt(self.index)) {
            self.index += 1;
            return;
        }
        var unit = try self.parseProgramUnit();
        unit.owner_name = module_name;
        unit.owner_kind = .module;
        if (stored_decls.len != 0) {
            unit = try root_prelude.prependDecls(self.arena, unit, stored_decls, stored_decl_sources);
        }
        try units.append(unit);
    }
}

fn moduleLineLooksLikeStatementFunction(lp: LineParser) bool {
    var scan = lp;
    _ = scan.expectIdentifier() orelse return false;
    _ = scan.expect(.l_paren) orelse return false;
    _ = scan.expectIdentifier() orelse return false;
    while (scan.consume(.comma)) {
        _ = scan.expectIdentifier() orelse return false;
    }
    _ = scan.expect(.r_paren) orelse return false;
    return scan.peekIs(.equals);
}

pub fn parseSubmoduleContainer(self: anytype, units: *std.array_list.Managed(ProgramUnit)) !void {
    const header_line = self.lines[self.index];
    const header_tokens = try self.tokensForIndex(self.index);
    var header_lp = LineParser.init(header_line, header_tokens);
    const submodule_header = try root_header.parseSubmoduleHeader(self.arena, &header_lp);
    validateSubmoduleNameAvailability(self.diag_bag, header_line, &self.module_preludes, submodule_header.name);
    self.index += 1;

    var module_decls = std.array_list.Managed(Decl).init(self.arena);
    var module_decl_sources = std.array_list.Managed(DeclSource).init(self.arena);
    var module_uses = std.array_list.Managed(ast.UseStmt).init(self.arena);
    var module_param_ints = std.StringHashMap(i64).init(self.arena);
    var module_array_names = std.StringHashMap(array_info.ArrayInfo).init(self.arena);
    var saw_contains = false;
    var module_procedure_count: usize = 0;
    const prev_in_submodule_spec_part = self.in_submodule_spec_part;
    self.in_submodule_spec_part = true;
    defer self.in_submodule_spec_part = prev_in_submodule_spec_part;

    while (self.index < self.lines.len) {
        const line = self.lines[self.index];
        root_diagnostics.noteFallbackForLine(self.diag_bag, line);
        if (self.isStandaloneEndAt(self.index) or self.isSubmoduleEndAt(self.index)) break;
        if (self.isContainsAt(self.index)) {
            self.in_submodule_spec_part = false;
            self.index += 1;
            saw_contains = true;
            break;
        }
        if (self.isInterfaceStartAt(self.index)) {
            const decl_node = self.parseInterfaceBlock() catch |err| {
                const tokens = self.tokensForIndex(self.index) catch |tok_err| {
                    root_diagnostics.setLexerOrLineDiagnostic(self.diag_bag, self.lex_diag_bag, line, tok_err);
                    return tok_err;
                };
                const lp = LineParser.init(line, tokens);
                root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, lp, err);
                return err;
            };
            if (decl_node == .interface_block) {
                const parent_decls = if (self.module_preludes.get(submodule_header.parent_name)) |parent_prelude|
                    parent_prelude.decls
                else
                    &.{};
                validateSubmoduleVisibleGenericSpecificReuse(self.diag_bag, decl_node.interface_block, parent_decls);
            }
            try module_decls.append(decl_node);
            try module_decl_sources.append(root_diagnostics.sourceFromLine(line));
            continue;
        }
        const tokens = self.tokensForIndex(self.index) catch {
            self.index += 1;
            continue;
        };
        noteInvalidSubmoduleVisibility(self.diag_bag, line, tokens);
        var lp = LineParser.init(line, tokens);
        if (try root_prelude.tryParsePreludeUseImport(&lp, self.arena)) |use_import| {
            try module_uses.append(use_import);
            self.index += 1;
            continue;
        }
        if (root_predicates.isDerivedTypeStartTokens(line, tokens)) {
            const decl_node = try self.parseDerivedTypeDef();
            try module_decls.append(decl_node);
            try module_decl_sources.append(root_diagnostics.sourceFromLine(line));
            continue;
        }
        if (decl.isDeclarationStart(lp)) {
            const decl_node = decl.parseDecl(&lp, self.arena) catch {
                self.index += 1;
                continue;
            };
            if (decl_node == .parameter) {
                try root_spec_eval.recordParamInts(&module_param_ints, decl_node.parameter.assigns);
            }
            try root_spec_eval.recordArrayNames(self.arena, &module_array_names, decl_node, &module_param_ints);
            try root_decl_diagnostics.noteDeclaratorInitializerShapeDiagnostics(
                self.arena,
                self.diag_bag,
                line,
                decl_node,
                &module_param_ints,
                &module_array_names,
            );
            try module_decls.append(decl_node);
            try module_decl_sources.append(root_diagnostics.sourceFromLine(line));
        }
        self.index += 1;
    }

    var stored_decls: []const Decl = try module_decls.toOwnedSlice();
    var stored_decl_sources: []const DeclSource = try module_decl_sources.toOwnedSlice();
    if (module_uses.items.len != 0) {
        const imported = try root_prelude.importPreludeDecls(self.arena, stored_decls, stored_decl_sources, module_uses.items, &self.module_preludes, self.diag_bag);
        stored_decls = imported.decls;
        stored_decl_sources = imported.decl_sources;
    }
    if (self.module_preludes.get(submodule_header.parent_name)) |parent_prelude| {
        const merged = try root_prelude.prependDecls(self.arena, .{
            .kind = .module,
            .name = submodule_header.name,
            .source = root_diagnostics.sourceFromLine(header_line),
            .owner_name = submodule_header.parent_name,
            .owner_kind = .module,
            .args = &.{},
            .decls = @constCast(stored_decls),
            .decl_sources = @constCast(stored_decl_sources),
            .stmts = &.{},
            .expr_sources = &.{},
        }, parent_prelude.decls, parent_prelude.decl_sources);
        stored_decls = merged.decls;
        stored_decl_sources = merged.decl_sources;
    }
    stored_decls = try root_binding_owners.annotateDeclBindingOwners(self.arena, stored_decls, submodule_header.name, .module);
    stored_decl_sources = try root_prelude.annotateDeclSourcesOwner(self.arena, stored_decl_sources, submodule_header.name);
    try self.module_preludes.put(submodule_header.name, .{
        .decls = stored_decls,
        .decl_sources = stored_decl_sources,
    });
    try units.append(.{
        .kind = .module,
        .name = submodule_header.name,
        .source = root_diagnostics.sourceFromLine(header_line),
        .owner_name = submodule_header.parent_name,
        .owner_kind = .module,
        .args = &.{},
        .decls = @constCast(stored_decls),
        .decl_sources = @constCast(stored_decl_sources),
        .use_imports = try module_uses.toOwnedSlice(),
        .stmts = &.{},
        .expr_sources = &.{},
    });

    if (!saw_contains) {
        noteMissingSubmoduleProcedure(self.diag_bag, header_line);
        if (self.isSubmoduleEndAt(self.index) or self.isStandaloneEndAt(self.index)) self.index += 1;
        return;
    }

    while (self.index < self.lines.len) {
        root_diagnostics.noteFallbackForLine(self.diag_bag, self.lines[self.index]);
        if (self.isSubmoduleEndAt(self.index) or self.isStandaloneEndAt(self.index)) {
            if (module_procedure_count == 0) noteMissingSubmoduleProcedure(self.diag_bag, header_line);
            self.index += 1;
            return;
        }
        if (self.pending_owner_name != null) {
            const end_line = self.lines[self.index];
            const end_tokens = self.tokensForIndex(self.index) catch {
                self.index += 1;
                continue;
            };
            if (isEndProcedureTokens(end_line, end_tokens)) {
                self.pending_owner_name = null;
                self.pending_owner_kind = null;
                self.pending_owner_decls = null;
                self.pending_owner_decl_sources = null;
                self.pending_owner_args = null;
                self.index += 1;
                continue;
            }
        }
        const unit_header_line = self.lines[self.index];
        const parsing_internal = self.pending_owner_name != null;
        var unit = if (try parseInheritedModuleProcedureUnit(self, stored_decls)) |parsed| parsed else try self.parseProgramUnit();
        const requires_interface = unit.is_module_procedure;
        if (!parsing_internal) {
            unit.is_module_procedure = true;
            module_procedure_count += 1;
            validateSubmoduleProcedureMatch(self.diag_bag, unit_header_line, unit, requires_interface, stored_decls);
            unit.owner_name = submodule_header.name;
            unit.owner_kind = .module;
            if (stored_decls.len != 0) {
                unit = try root_prelude.prependDecls(self.arena, unit, stored_decls, stored_decl_sources);
            }
        }
        try units.append(unit);
        if (!parsing_internal and root_control.unitHasContains(unit)) {
            self.pending_owner_name = unit.name;
            self.pending_owner_kind = .procedure;
            self.pending_owner_decls = unit.decls;
            self.pending_owner_decl_sources = unit.decl_sources;
            self.pending_owner_args = unit.args;
        }
    }
}

pub fn parseProgramUnit(self: anytype) !ProgramUnit {
    if (self.index >= self.lines.len) return error.UnexpectedEOF;
    const expr_mark = self.expr_capture.mark();
    const header_line = self.lines[self.index];
    root_diagnostics.noteFallbackForLine(self.diag_bag, header_line);
    const header_tokens = self.tokensForIndex(self.index) catch |err| {
        if (try bind_recovery.recoverMalformedBindProcedureHeader(self, header_line, err)) |recovered| {
            return recovered;
        }
        root_diagnostics.setLexerOrLineDiagnostic(self.diag_bag, self.lex_diag_bag, header_line, err);
        return err;
    };
    var lp = LineParser.init(header_line, header_tokens);
    var parsed_implicit_program = false;
    if (stmt_helpers.looksLikeBlankInsensitiveAssignment(lp)) {
        parsed_implicit_program = true;
    }
    const header = root_header.parseProgramUnitHeader(self.arena, &lp, &self.block_data_counter) catch |err| switch (err) {
        error.ExpectedProgramUnit => blk: {
            parsed_implicit_program = true;
            break :blk try self.syntheticProgramHeader();
        },
        else => {
            if (try bind_recovery.recoverMalformedBindProcedureHeader(self, header_line, err)) |recovered| {
                return recovered;
            }
            root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, header_line, lp, err);
            return err;
        },
    };
    var unit: ProgramUnit = undefined;
    if (parsed_implicit_program) {
        const implicit = try self.syntheticProgramHeader();
        unit = try self.parseProgramUnitBody(implicit, false, header_line, expr_mark);
    } else {
        self.index += 1;
        unit = try self.parseProgramUnitBody(header, true, header_line, expr_mark);
    }
    if (self.pending_owner_name) |owner_name| {
        if (self.pending_owner_decls) |owner_decls| {
            if (owner_decls.len != 0) {
                const owner_decl_sources = self.pending_owner_decl_sources orelse &.{};
                unit = try root_prelude.prependDecls(self.arena, unit, owner_decls, owner_decl_sources);
            }
        }
        unit.owner_name = owner_name;
        unit.owner_kind = self.pending_owner_kind;
    }
    return unit;
}

fn parseInheritedModuleProcedureUnit(self: anytype, available_decls: []const Decl) !?ProgramUnit {
    if (self.index >= self.lines.len) return null;
    const line = self.lines[self.index];
    const tokens = self.tokensForIndex(self.index) catch return null;
    var lp = LineParser.init(line, tokens);
    if (!lp.consumeKeyword("MODULE")) return null;
    if (!lp.consumeKeyword("PROCEDURE")) return null;
    _ = stmt.action_stmt.consumeDoubleColon(&lp);
    const procedure_name = lp.readName(self.arena) orelse return error.MissingName;

    const proc_header = findInheritedInterfaceProcedure(available_decls, procedure_name);
    const missing_interface = proc_header == null;
    const header: ProgramUnitHeader = if (proc_header) |proc|
        try programUnitHeaderFromInterfaceProcedure(self.arena, proc)
    else blk: {
        self.diag_bag.set(
            line.span.start_line,
            if (line.segments.len > 0) line.segments[0].column else 1,
            catalog.parser.unexpected_token.code,
            "must be in a generic module interface",
            line.text,
        );
        break :blk .{
            .kind = .subroutine,
            .name = procedure_name,
            .is_module_procedure = true,
            .pure = false,
            .elemental = false,
            .recursive = false,
            .bind_c = false,
            .bind_name = null,
            .result_name = null,
            .args = &.{},
            .alt_return_dummy_count = 0,
            .type_decl = null,
        };
    };

    const expr_mark = self.expr_capture.mark();
    self.index += 1;
    const unit = try self.parseProgramUnitBody(header, false, line, expr_mark);
    if (missing_interface and self.index > 0) {
        const end_line = self.lines[self.index - 1];
        const end_tokens = self.tokensForIndex(self.index - 1) catch return unit;
        if (isEndProcedureTokens(end_line, end_tokens)) {
            self.diag_bag.set(
                end_line.span.start_line,
                if (end_line.segments.len > 0) end_line.segments[0].column else 1,
                catalog.parser.unexpected_token.code,
                "Expecting END SUBMODULE statement",
                end_line.text,
            );
        }
    }
    return unit;
}

fn findInheritedInterfaceProcedure(available_decls: []const Decl, procedure_name: []const u8) ?ast.InterfaceProcedure {
    for (available_decls) |decl_node| {
        if (decl_node != .interface_block) continue;
        for (decl_node.interface_block.procedure_headers) |proc_header| {
            if (std.ascii.eqlIgnoreCase(proc_header.name, procedure_name)) return proc_header;
        }
    }
    return null;
}

fn programUnitHeaderFromInterfaceProcedure(
    arena: std.mem.Allocator,
    proc_header: ast.InterfaceProcedure,
) !ProgramUnitHeader {
    var type_decl: ?ast.Decl = null;
    const result_name = proc_header.result_name orelse proc_header.name;
    if (try root_interface.cloneProcedureResultDecl(arena, proc_header.decls, result_name)) |result_decl| {
        type_decl = result_decl;
    } else if (proc_header.type_spec) |type_spec| {
        const decl_items = try arena.alloc(ast.Declarator, 1);
        decl_items[0] = .{
            .name = result_name,
            .dims = &.{},
            .char_len = null,
            .char_len_deferred = false,
        };
        type_decl = .{ .type_decl = .{
            .type_kind = type_spec.type_kind,
            .kind_selector = type_spec.kind_selector,
            .derived_type_name = type_spec.derived_type_name,
            .polymorphic = type_spec.polymorphic,
            .items = decl_items,
            .allocatable = false,
        } };
    }
    return .{
        .kind = proc_header.kind,
        .name = proc_header.name,
        .is_module_procedure = true,
        .pure = proc_header.pure,
        .elemental = proc_header.elemental,
        .recursive = proc_header.recursive,
        .bind_c = proc_header.bind_c,
        .bind_name = proc_header.bind_name,
        .result_name = proc_header.result_name,
        .args = proc_header.args,
        .alt_return_dummy_count = proc_header.alt_return_dummy_count,
        .type_decl = type_decl,
    };
}

pub fn parseProgramUnitBody(
    self: anytype,
    header: ProgramUnitHeader,
    skip_duplicate_header: bool,
    header_line: logical_line.LogicalLine,
    expr_mark: usize,
) !ProgramUnit {
    var decls = std.array_list.Managed(Decl).init(self.arena);
    var decl_sources = std.array_list.Managed(DeclSource).init(self.arena);
    var stmts = std.array_list.Managed(Stmt).init(self.arena);
    var do_ctx = stmt.DoContext.init(self.arena);
    var param_ints = std.StringHashMap(i64).init(self.arena);
    var param_strings = std.StringHashMap(ast.Literal).init(self.arena);
    var array_names = std.StringHashMap(array_info.ArrayInfo).init(self.arena);
    var pending_no_arg_check = std.StringHashMap(void).init(self.arena);
    var spec_part_open = true;
    const implicit_program_recovery = header.kind == .program and std.mem.startsWith(u8, header.name, "__COL6FORGE_PROGRAM");
    var recovered_stmt_error = false;
    var saw_unexpected_end_recovery = false;
    var saw_program_unit_end = false;
    var deferred_contains_section = false;
    if (header.type_decl) |type_decl| {
        try decls.append(type_decl);
        try decl_sources.append(root_diagnostics.sourceFromLine(header_line));
    }
    while (self.index < self.lines.len) {
        const line = self.lines[self.index];
        root_diagnostics.noteFallbackForLine(self.diag_bag, line);
        if (spec_part_open and try no_arg_check.consumeNoArgCheckDirectiveLine(self.arena, line, &pending_no_arg_check)) {
            no_arg_check.applyPendingNoArgCheckToDecls(decls.items, &pending_no_arg_check);
            self.index += 1;
            continue;
        }
        const tokens = self.tokensForIndex(self.index) catch |err| {
            root_diagnostics.setLexerOrLineDiagnostic(self.diag_bag, self.lex_diag_bag, line, err);
            return err;
        };
        var stmt_lp = LineParser.init(line, tokens);
        if (skip_duplicate_header and decls.items.len == 0 and stmts.items.len == 0) {
            if (root_header.isDuplicateProgramUnitTokens(self.arena, line, tokens, header)) {
                self.index += 1;
                continue;
            }
        }
        if (!do_ctx.hasPending()) {
            if (stmt_lp.isKeywordSplit("CONTAINS")) {
                try stmts.append(root_control.makeContainsStmt(line));
                self.index += 1;
                deferred_contains_section = true;
                break;
            }
            if (root_predicates.isEndSelectTokens(line, tokens)) {
                root_control.noteUnexpectedProgramUnitEnd(self.diag_bag, line, header.kind);
                self.index += 1;
                break;
            }
            const explicit_program_unit_end = root_predicates.isProgramUnitEndTokens(line, tokens);
            if (explicit_program_unit_end or
                (stmt_lp.isKeywordSplit("END") and
                    !root_control.isEndDoLine(stmt_lp) and
                    !root_control.isEndIfLine(stmt_lp) and
                    !root_control.isEndBlockLine(stmt_lp)))
            {
                saw_program_unit_end = true;
                if (implicit_program_recovery and recovered_stmt_error) {
                    self.diag_bag.set(
                        line.span.start_line,
                        if (line.segments.len > 0) line.segments[0].column else 1,
                        catalog.parser.unexpected_token.code,
                        "Unexpected END statement",
                        line.text,
                    );
                    saw_unexpected_end_recovery = true;
                }
                if (headerLineStartsModuleProcedure(header_line) and !isEndProcedureTokens(line, tokens)) {
                    self.diag_bag.set(
                        line.span.start_line,
                        if (line.segments.len > 0) line.segments[0].column else 1,
                        catalog.parser.unexpected_token.code,
                        "Expecting END PROCEDURE statement",
                        line.text,
                    );
                }
                self.index += 1;
                break;
            }
        }
        if (spec_part_open and root_predicates.isDerivedTypeStartTokens(line, tokens)) {
            const decl_node = self.parseDerivedTypeDef() catch |err| {
                if (err == error.DuplicateAbstractAttribute) return err;
                root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, stmt_lp, err);
                return err;
            };
            try decls.append(decl_node);
            try decl_sources.append(root_diagnostics.sourceFromLine(line));
            continue;
        }
        if (spec_part_open and root_predicates.isInterfaceStartTokens(line, tokens)) {
            const decl_node = self.parseInterfaceBlock() catch |err| {
                root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, stmt_lp, err);
                return err;
            };
            try decls.append(decl_node);
            try decl_sources.append(root_diagnostics.sourceFromLine(line));
            continue;
        }
        if ((spec_part_open or do_ctx.isInsideBlock()) and decl.isDeclarationStart(stmt_lp)) {
            var decl_node = decl.parseDecl(&stmt_lp, self.arena) catch |err| {
                root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, stmt_lp, err);
                return err;
            };
            if (do_ctx.isInsideBlock() and saveDeclSpecifiesCommonBlock(decl_node)) {
                self.diag_bag.set(
                    line.span.start_line,
                    if (line.segments.len > 0) line.segments[0].column else 1,
                    catalog.parser.unexpected_token.code,
                    "SAVE of a COMMON block is not allowed in a BLOCK construct",
                    line.text,
                );
                return error.UnexpectedToken;
            }
            no_arg_check.applyPendingNoArgCheck(&decl_node, &pending_no_arg_check);
            if (decl_node == .parameter) {
                try root_spec_eval.recordParamInts(&param_ints, decl_node.parameter.assigns);
                try root_spec_eval.recordParamStrings(&param_strings, decl_node.parameter.assigns);
            }
            try root_spec_eval.recordArrayNames(self.arena, &array_names, decl_node, &param_ints);
            try root_decl_diagnostics.noteDeclaratorInitializerShapeDiagnostics(
                self.arena,
                self.diag_bag,
                line,
                decl_node,
                &param_ints,
                &array_names,
            );
            try decls.append(decl_node);
            try decl_sources.append(root_diagnostics.sourceFromLine(line));
            self.index += 1;
            continue;
        }
        const stmt_start_index = self.index;
        var stmt_node = stmt.parseStatementWithDiagnostics(
            self.arena,
            self.lines,
            &self.index,
            &do_ctx,
            &param_ints,
            &param_strings,
            &array_names,
            self.diag_bag,
            self.lex_diag_bag,
        ) catch |err| {
            if (!self.diag_bag.has()) {
                const err_line = root_diagnostics.lineAtIndexOrLast(self.lines, self.index, line);
                const err_col = if (err_line.segments.len > 0) err_line.segments[0].column else 1;
                root_diagnostics.setParseDiagnosticForLine(self.diag_bag, err_line, err_line.span.start_line, err_col, err);
            }
            if (self.index == stmt_start_index and self.diag_bag.has() and err == error.UnexpectedToken) {
                recovered_stmt_error = true;
                self.index += 1;
                try stmts.append(.{
                    .label = line.label,
                    .node = .{ .cont = {} },
                    .source_line = line.span.start_line,
                    .source_column = if (line.segments.len > 0) line.segments[0].column else 1,
                    .source_text = line.text,
                });
                continue;
            }
            return err;
        };
        root_diagnostics.stampStmtSource(&stmt_node, line);
        if (spec_part_open and !root_control.stmtKeepsSpecificationPartOpen(stmt_node)) {
            spec_part_open = false;
        }
        try stmts.append(stmt_node);
    }

    if (implicit_program_recovery and recovered_stmt_error and saw_unexpected_end_recovery and self.lines.len != 0) {
        const eof_line = self.lines[self.lines.len - 1];
        self.diag_bag.set(
            eof_line.span.start_line,
            if (eof_line.segments.len > 0) eof_line.segments[0].column else 1,
            catalog.parser.unexpected_eof.code,
            "Unexpected end of file",
            eof_line.text,
        );
    }
    if (!implicit_program_recovery and !saw_program_unit_end and !deferred_contains_section and self.lines.len != 0) {
        const eof_line = self.lines[self.lines.len - 1];
        self.diag_bag.set(
            eof_line.span.start_line,
            if (eof_line.segments.len > 0) eof_line.segments[0].column else 1,
            catalog.parser.unexpected_eof.code,
            "Unexpected end of file",
            eof_line.text,
        );
    }

    var unit = ProgramUnit{
        .kind = header.kind,
        .name = header.name,
        .source = root_diagnostics.sourceFromLine(header_line),
        .is_module_procedure = header.is_module_procedure,
        .pure = header.pure,
        .elemental = header.elemental,
        .recursive = header.recursive,
        .bind_c = header.bind_c,
        .bind_name = header.bind_name,
        .result_name = header.result_name,
        .args = header.args,
        .alt_return_dummy_count = header.alt_return_dummy_count,
        .decls = try decls.toOwnedSlice(),
        .decl_sources = try decl_sources.toOwnedSlice(),
        .stmts = try stmts.toOwnedSlice(),
        .expr_sources = try self.expr_capture.sliceFrom(expr_mark),
    };
    unit = try self.importUsedModulePreludes(unit);
    return unit;
}

fn saveDeclSpecifiesCommonBlock(decl_node: Decl) bool {
    if (decl_node != .save) return false;
    for (decl_node.save.items) |item| {
        if (item == .common) return true;
    }
    return false;
}

pub fn importUsedModulePreludes(self: anytype, unit: ProgramUnit) !ProgramUnit {
    var imported = unit;
    var seen = std.StringHashMap(void).init(self.arena);
    for (unit.stmts) |stmt_node| {
        if (stmt_node.node != .use_stmt) continue;
        const use_stmt = stmt_node.node.use_stmt;
        const prelude = try root_prelude.lookupPreludeOrBuiltin(self.arena, use_stmt.module_name, &self.module_preludes) orelse continue;
        if (!use_stmt.has_only and use_stmt.only_items.len == 0) {
            if (seen.contains(use_stmt.module_name)) continue;
            imported = try root_prelude.prependDecls(self.arena, imported, prelude.decls, prelude.decl_sources);
            try seen.put(use_stmt.module_name, {});
            continue;
        }
        const selected = if (use_stmt.has_only)
            try root_prelude.selectPreludeDecls(self.arena, prelude, use_stmt, self.diag_bag)
        else
            try root_prelude.importPreludeDecls(self.arena, &.{}, &.{}, &.{use_stmt}, &self.module_preludes, self.diag_bag);
        if (selected.decls.len == 0) continue;
        imported = try root_prelude.prependDecls(self.arena, imported, selected.decls, selected.decl_sources);
    }
    return imported;
}

pub fn moduleHeaderName(self: anytype, line_index: usize) ![]const u8 {
    const line = self.lines[line_index];
    const tokens = try self.tokensForIndex(line_index);
    var lp = LineParser.init(line, tokens);
    if (!lp.consumeKeyword("MODULE")) return error.ExpectedProgramUnit;
    return lp.readName(self.arena) orelse error.MissingName;
}

pub fn parseInterfaceBlock(self: anytype) anyerror!Decl {
    if (self.index >= self.lines.len) return error.UnexpectedEOF;
    const header_line = self.lines[self.index];
    const header_tokens = try self.tokensForIndex(self.index);
    var lp = LineParser.init(header_line, header_tokens);
    const is_abstract = lp.consumeKeyword("ABSTRACT");
    if (!lp.consumeKeyword("INTERFACE")) return error.UnexpectedToken;
    var invalid_named_abstract = false;
    if (is_abstract) {
        var lookahead = lp;
        if (stmt.action_stmt.consumeDoubleColon(&lookahead)) {
            invalid_named_abstract = true;
            _ = lookahead.readName(self.arena);
            lp = lookahead;
        }
    }
    const interface_name = if (invalid_named_abstract) null else try root_interface.parseInterfaceGenericName(self.arena, &lp);
    self.index += 1;
    var module_procedures = std.array_list.Managed([]const u8).init(self.arena);
    var module_procedure_sources = std.array_list.Managed(DeclSource).init(self.arena);
    var specific_procedures = std.array_list.Managed([]const u8).init(self.arena);
    var specific_procedure_sources = std.array_list.Managed(DeclSource).init(self.arena);
    var procedures = std.array_list.Managed([]const u8).init(self.arena);
    var procedure_sources = std.array_list.Managed(DeclSource).init(self.arena);
    var procedure_headers = std.array_list.Managed(ast.InterfaceProcedure).init(self.arena);
    var deferred_error: ?anyerror = null;

    while (self.index < self.lines.len) {
        const line = self.lines[self.index];
        root_diagnostics.noteFallbackForLine(self.diag_bag, line);
        const tokens = try self.tokensForIndex(self.index);
        switch (try root_interface.classifyInterfaceEnd(self.arena, line, tokens, interface_name)) {
            .valid => {
                if (invalid_named_abstract) {
                    self.diag_bag.set(
                        header_line.span.start_line,
                        1,
                        catalog.parser.unexpected_token.code,
                        "Syntax error in ABSTRACT INTERFACE statement",
                        header_line.text,
                    );
                    self.diag_bag.set(
                        line.span.start_line,
                        1,
                        catalog.parser.unexpected_token.code,
                        "Expecting END MODULE statement",
                        line.text,
                    );
                }
                self.index += 1;
                if (deferred_error) |err| return err;
                return .{ .interface_block = .{
                    .abstract = is_abstract,
                    .name = interface_name,
                    .module_procedures = try module_procedures.toOwnedSlice(),
                    .module_procedure_sources = try module_procedure_sources.toOwnedSlice(),
                    .specific_procedures = try specific_procedures.toOwnedSlice(),
                    .specific_procedure_sources = try specific_procedure_sources.toOwnedSlice(),
                    .procedures = try procedures.toOwnedSlice(),
                    .procedure_sources = try procedure_sources.toOwnedSlice(),
                    .procedure_headers = try procedure_headers.toOwnedSlice(),
                } };
            },
            .invalid_end_interface => {
                root_interface.noteInvalidInterfaceEnd(self.diag_bag, line, interface_name);
                self.index += 1;
                continue;
            },
            .other_end_stmt => {
                root_interface.noteMissingInterfaceEnd(self.diag_bag, line);
                self.index += 1;
                continue;
            },
            .none => {},
        }
        var body_lp = LineParser.init(line, tokens);
        if (body_lp.consumeKeyword("MODULE") and body_lp.consumeKeyword("PROCEDURE")) {
            _ = stmt.action_stmt.consumeDoubleColon(&body_lp);
            while (true) {
                const procedure_name = body_lp.readName(self.arena) orelse return error.MissingName;
                try module_procedures.append(procedure_name);
                try module_procedure_sources.append(.{
                    .line = line.span.start_line,
                    .column = 1,
                    .text = line.text,
                });
                if (!body_lp.consume(.comma)) break;
            }
        } else if (body_lp.consumeKeyword("PROCEDURE")) {
            _ = stmt.action_stmt.consumeDoubleColon(&body_lp);
            while (true) {
                const procedure_name = body_lp.readName(self.arena) orelse return error.MissingName;
                try specific_procedures.append(procedure_name);
                try specific_procedure_sources.append(.{
                    .line = line.span.start_line,
                    .column = 1,
                    .text = line.text,
                });
                if (!body_lp.consume(.comma)) break;
            }
        } else if (body_lp.consumeKeyword("INTERFACE") or (body_lp.consumeKeyword("ABSTRACT") and body_lp.consumeKeyword("INTERFACE"))) {
            self.diag_bag.set(
                line.span.start_line,
                1,
                catalog.parser.unexpected_token.code,
                "Unexpected INTERFACE statement",
                line.text,
            );
        } else {
            var block_data_counter: usize = 0;
            const line_has_module_prefix = lineHasModuleProcedurePrefix(line, tokens);
            const header = root_header.parseProgramUnitHeader(self.arena, &body_lp, &block_data_counter) catch |err| blk: {
                if (err == error.UnexpectedToken and bind_recovery.isBindCProcedureHeaderMissingParens(line, tokens)) {
                    self.diag_bag.set(
                        line.span.start_line,
                        if (line.segments.len > 0) line.segments[0].column else 1,
                        catalog.parser.unexpected_token.code,
                        "Missing required parentheses",
                        line.text,
                    );
                    deferred_error = error.UnexpectedToken;
                }
                break :blk null;
            };
            if (header != null) {
                if (bind_recovery.isBindCProcedureHeaderMissingParens(line, tokens)) {
                    self.diag_bag.set(
                        line.span.start_line,
                        if (line.segments.len > 0) line.segments[0].column else 1,
                        catalog.parser.unexpected_token.code,
                        "Missing required parentheses",
                        line.text,
                    );
                    deferred_error = error.UnexpectedToken;
                    self.index += 1;
                    continue;
                }
                const body_start_index = self.index + 1;
                const expr_mark = self.expr_capture.mark();
                self.index += 1;
                const proc_unit = try self.parseProgramUnitBody(header.?, true, line, expr_mark);
                const proc_source = root_diagnostics.sourceFromLine(line);
                const end_line = self.lines[self.index - 1];
                noteInvalidModuleProcedureInterfaceBodyLines(self, line_has_module_prefix, body_start_index, self.index - 1);
                noteInvalidModuleProcedureInterfaceBodyDecls(self.diag_bag, proc_unit);
                try procedures.append(proc_unit.name);
                try procedure_sources.append(proc_source);
                try procedure_headers.append(root_interface.interfaceProcedureFromUnit(proc_unit, proc_source, .{
                    .line = end_line.span.start_line,
                    .column = 1,
                    .text = end_line.text,
                }));
                continue;
            }
        }
        self.index += 1;
    }
    root_interface.noteUnexpectedInterfaceEof(self.diag_bag, self.lines[self.lines.len - 1]);
    return error.UnexpectedEOF;
}
