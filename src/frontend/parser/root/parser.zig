const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const logical_line = @import("../../logical_line.zig");
const lexer = @import("../../lexer.zig");
const context = @import("../token_stream.zig");
const parse_diag = @import("../diagnostic.zig");
const decl = @import("../decl/mod.zig");
const expr = @import("../expr.zig");
const root_header = @import("header.zig");
const root_prelude = @import("prelude.zig");
const root_predicates = @import("predicates.zig");
const root_expand = @import("expand.zig");
const root_units = @import("units.zig");
const root_diagnostics = @import("diagnostics.zig");
const root_control = @import("control_helpers.zig");

const Program = ast.Program;
const LexicalOwnerKind = ast.LexicalOwnerKind;
const ProgramUnit = ast.ProgramUnit;
const Decl = ast.Decl;
const DeclSource = ast.DeclSource;
const LineParser = context.LineParser;
const ProgramUnitHeader = root_header.ProgramUnitHeader;
const ModulePreludeMap = root_prelude.ModulePreludeMap;

pub fn parseProgram(arena_allocator: std.mem.Allocator, lines: []logical_line.LogicalLine) !Program {
    var diag_bag = parse_diag.Bag.init(arena_allocator);
    defer diag_bag.deinit();
    return parseProgramWithDiagnostics(arena_allocator, lines, &diag_bag);
}

pub fn parseProgramWithDiagnostics(
    arena_allocator: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    diag_bag: *parse_diag.Bag,
) !Program {
    diag_bag.clear();
    var lex_diag_bag = lexer.Bag.init(arena_allocator);
    defer lex_diag_bag.deinit();

    const token_cache = try arena_allocator.alloc(?[]lexer.Token, lines.len);
    @memset(token_cache, null);
    var expr_capture = expr.SourceCapture.init(arena_allocator);
    const prev_capture = expr.pushSourceCapture(&expr_capture);
    defer expr.restoreSourceCapture(prev_capture);
    var parser = Parser{
        .arena = arena_allocator,
        .lines = lines,
        .token_cache = token_cache,
        .index = 0,
        .block_data_counter = 0,
        .implicit_program_counter = 0,
        .pending_owner_name = null,
        .pending_owner_kind = null,
        .pending_owner_decls = null,
        .pending_owner_decl_sources = null,
        .in_submodule_spec_part = false,
        .module_preludes = ModulePreludeMap.initContext(arena_allocator, .{}),
        .expr_capture = &expr_capture,
        .diag_bag = diag_bag,
        .lex_diag_bag = &lex_diag_bag,
    };
    const program = try parser.parseProgram();
    return root_expand.expandEntries(arena_allocator, program);
}

pub const Parser = struct {
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    token_cache: []?[]lexer.Token,
    index: usize,
    block_data_counter: usize,
    implicit_program_counter: usize,
    pending_owner_name: ?[]const u8,
    pending_owner_kind: ?LexicalOwnerKind,
    pending_owner_decls: ?[]const Decl,
    pending_owner_decl_sources: ?[]const DeclSource,
    in_submodule_spec_part: bool,
    module_preludes: ModulePreludeMap,
    expr_capture: *expr.SourceCapture,
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,

    pub fn tokensForIndex(self: *Parser, line_index: usize) ![]lexer.Token {
        if (self.token_cache[line_index]) |cached| return cached;
        const tokens = try lexer.lexLogicalLineWithDiagnostics(self.arena, self.lines[line_index], self.lex_diag_bag);
        self.token_cache[line_index] = tokens;
        return tokens;
    }

    fn maybeTokensForIndex(self: *Parser, line_index: usize) ?[]lexer.Token {
        return self.tokensForIndex(line_index) catch null;
    }

    pub fn isStandaloneEndAt(self: *Parser, line_index: usize) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        return root_predicates.isStandaloneEndTokens(line, tokens);
    }

    fn isProgramUnitEndAt(self: *Parser, line_index: usize) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        return root_predicates.isProgramUnitEndTokens(line, tokens);
    }

    pub fn isModuleEndAt(self: *Parser, line_index: usize) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        return root_predicates.isModuleEndTokens(line, tokens);
    }

    pub fn isSubmoduleEndAt(self: *Parser, line_index: usize) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        return root_predicates.isSubmoduleEndTokens(line, tokens);
    }

    fn isModuleHeaderAt(self: *Parser, line_index: usize) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        return root_predicates.isModuleHeaderTokens(line, tokens);
    }

    fn isSubmoduleHeaderAt(self: *Parser, line_index: usize) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        return root_predicates.isSubmoduleHeaderTokens(line, tokens);
    }

    fn lineStartsWithKeyword(self: *Parser, line_index: usize, keyword: []const u8) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        var lp = LineParser.init(line, tokens);
        return lp.consumeKeyword(keyword);
    }

    pub fn isContainsAt(self: *Parser, line_index: usize) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        return root_predicates.isContainsTokens(line, tokens);
    }

    pub fn isInterfaceStartAt(self: *Parser, line_index: usize) bool {
        const line = self.lines[line_index];
        const tokens = self.maybeTokensForIndex(line_index) orelse return false;
        return root_predicates.isInterfaceStartTokens(line, tokens);
    }

    fn parseProgram(self: *Parser) !Program {
        var units = std.array_list.Managed(ProgramUnit).init(self.arena);
        while (self.index < self.lines.len) {
            root_diagnostics.noteFallbackForLine(self.diag_bag, self.lines[self.index]);
            if (self.isStandaloneEndAt(self.index)) {
                if (self.pending_owner_name != null) {
                    self.pending_owner_name = null;
                    self.pending_owner_kind = null;
                    self.pending_owner_decls = null;
                    self.pending_owner_decl_sources = null;
                }
                self.index += 1;
                continue;
            }
            if (self.isProgramUnitEndAt(self.index)) {
                self.pending_owner_name = null;
                self.pending_owner_kind = null;
                self.pending_owner_decls = null;
                self.pending_owner_decl_sources = null;
                self.index += 1;
                continue;
            }
            if (self.isModuleEndAt(self.index)) {
                self.index += 1;
                continue;
            }
            if (self.isSubmoduleEndAt(self.index)) {
                self.index += 1;
                continue;
            }
            if (self.isModuleHeaderAt(self.index)) {
                try self.parseModuleContainer(&units);
                continue;
            }
            if (self.isSubmoduleHeaderAt(self.index)) {
                try self.parseSubmoduleContainer(&units);
                continue;
            }
            if (self.lineStartsWithKeyword(self.index, "SUBMODULE")) {
                const line = self.lines[self.index];
                self.diag_bag.set(
                    line.span.start_line,
                    if (line.segments.len > 0) line.segments[0].column else 1,
                    catalog.parser.unexpected_token.code,
                    "Syntax error in SUBMODULE statement",
                    line.text,
                );
                self.index += 1;
                continue;
            }
            if (self.isContainsAt(self.index)) {
                self.index += 1;
                continue;
            }
            const unit_start_index = self.index;
            const unit = try self.parseProgramUnit();
            if (unit.is_module_procedure and self.pending_owner_name == null) {
                const header_line = self.lines[unit_start_index];
                self.diag_bag.set(
                    header_line.span.start_line,
                    if (header_line.segments.len > 0) header_line.segments[0].column else 1,
                    catalog.parser.unexpected_token.code,
                    "found outside of a module",
                    header_line.text,
                );
                for (unit.stmts) |stmt_node| {
                    switch (stmt_node.node) {
                        .assignment => self.diag_bag.set(
                            if (stmt_node.source_line == 0) 1 else stmt_node.source_line,
                            if (stmt_node.source_column == 0) 1 else stmt_node.source_column,
                            catalog.parser.unexpected_token.code,
                            "Unexpected assignment",
                            stmt_node.source_text,
                        ),
                        else => {},
                    }
                }
                if (self.index > 0) {
                    const end_line = self.lines[self.index - 1];
                    self.diag_bag.set(
                        end_line.span.start_line,
                        if (end_line.segments.len > 0) end_line.segments[0].column else 1,
                        catalog.parser.unexpected_token.code,
                        "Expecting END PROGRAM statement",
                        end_line.text,
                    );
                }
            }
            try units.append(unit);
            if (root_control.unitHasContains(unit)) {
                self.pending_owner_name = unit.name;
                self.pending_owner_kind = .procedure;
                self.pending_owner_decls = unit.decls;
                self.pending_owner_decl_sources = unit.decl_sources;
            }
        }
        return .{ .units = try units.toOwnedSlice() };
    }

    pub fn parseModuleContainer(self: *Parser, units: *std.array_list.Managed(ProgramUnit)) !void {
        return root_units.parseModuleContainer(self, units);
    }

    pub fn parseSubmoduleContainer(self: *Parser, units: *std.array_list.Managed(ProgramUnit)) !void {
        return root_units.parseSubmoduleContainer(self, units);
    }

    pub fn parseProgramUnit(self: *Parser) !ProgramUnit {
        return root_units.parseProgramUnit(self);
    }

    pub fn parseProgramUnitBody(
        self: *Parser,
        header: ProgramUnitHeader,
        skip_duplicate_header: bool,
        header_line: logical_line.LogicalLine,
        expr_mark: usize,
    ) !ProgramUnit {
        return root_units.parseProgramUnitBody(self, header, skip_duplicate_header, header_line, expr_mark);
    }

    pub fn importUsedModulePreludes(self: *Parser, unit: ProgramUnit) !ProgramUnit {
        return root_units.importUsedModulePreludes(self, unit);
    }

    pub fn syntheticProgramHeader(self: *Parser) !ProgramUnitHeader {
        const name = try std.fmt.allocPrint(self.arena, "__COL6FORGE_PROGRAM{d}", .{self.implicit_program_counter});
        self.implicit_program_counter += 1;
        return .{
            .kind = .program,
            .name = name,
            .is_module_procedure = false,
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
    }

    pub fn moduleHeaderName(self: *Parser, line_index: usize) ![]const u8 {
        return root_units.moduleHeaderName(self, line_index);
    }

    pub fn parseDerivedTypeDef(self: *Parser) !Decl {
        if (self.index >= self.lines.len) return error.UnexpectedEOF;
        const header_line = self.lines[self.index];
        const header_tokens = try self.tokensForIndex(self.index);
        var lp = LineParser.init(header_line, header_tokens);
        const header = root_header.parseDerivedTypeHeader(self.arena, &lp) catch |err| switch (err) {
            error.DuplicateAbstractAttribute => {
                self.diag_bag.set(
                    header_line.span.start_line,
                    if (header_line.segments.len > 0) header_line.segments[0].column else 1,
                    catalog.parser.unexpected_token.code,
                    "Duplicate ABSTRACT attribute",
                    header_line.text,
                );
                var scan_index = self.index + 1;
                while (scan_index < self.lines.len) : (scan_index += 1) {
                    const scan_line = self.lines[scan_index];
                    const scan_tokens = self.tokensForIndex(scan_index) catch continue;
                    if (!root_predicates.isDerivedTypeEndTokens(scan_line, scan_tokens)) continue;
                    self.diag_bag.set(
                        scan_line.span.start_line,
                        if (scan_line.segments.len > 0) scan_line.segments[0].column else 1,
                        catalog.parser.unexpected_token.code,
                        "Expecting END MODULE statement",
                        scan_line.text,
                    );
                    break;
                }
                return err;
            },
            else => return err,
        };
        self.index += 1;
        var components = std.array_list.Managed(ast.TypeDecl).init(self.arena);
        var component_sources = std.array_list.Managed(DeclSource).init(self.arena);
        var procedure_components = std.array_list.Managed(ast.ProcedureDecl).init(self.arena);
        var procedure_component_sources = std.array_list.Managed(DeclSource).init(self.arena);
        var bindings = std.array_list.Managed(ast.TypeBoundProcedureBinding).init(self.arena);
        var final_subroutines = std.array_list.Managed([]const u8).init(self.arena);
        var in_contains = false;
        var sequence = false;
        var saw_binding_stmt = false;

        while (self.index < self.lines.len) {
            const line = self.lines[self.index];
            root_diagnostics.noteFallbackForLine(self.diag_bag, line);
            const tokens = self.tokensForIndex(self.index) catch |err| {
                if (in_contains) {
                    const trimmed = std.mem.trim(u8, line.text, " \t");
                    if (std.mem.startsWith(u8, trimmed, "PROCEDURE")) {
                        self.diag_bag.set(
                            line.span.start_line,
                            if (line.segments.len > 0) line.segments[0].column else 1,
                            catalog.semantic.duplicate_declaration.code,
                            "Expected binding name",
                            line.text,
                        );
                        self.index += 1;
                        continue;
                    }
                }
                root_diagnostics.setLexerOrLineDiagnostic(self.diag_bag, self.lex_diag_bag, line, err);
                self.index += 1;
                continue;
            };
            if (root_predicates.isSubmoduleHeaderTokens(line, tokens)) {
                self.diag_bag.set(
                    line.span.start_line,
                    if (line.segments.len > 0) line.segments[0].column else 1,
                    catalog.parser.unexpected_token.code,
                    "SUBMODULE declaration at this position is not allowed in a derived type definition",
                    line.text,
                );
                self.index += 1;
                continue;
            }
            if (self.in_submodule_spec_part) {
                noteInvalidSubmoduleVisibility(self.diag_bag, line, tokens);
            }
            if (root_predicates.isDerivedTypeEndTokens(line, tokens)) {
                self.index += 1;
                return .{ .derived_type_def = .{
                    .name = header.name,
                    .parent_name = header.parent_name,
                    .abstract = header.abstract,
                    .sequence = sequence,
                    .bind_c = header.bind_c,
                    .components = try components.toOwnedSlice(),
                    .component_sources = try component_sources.toOwnedSlice(),
                    .procedure_components = try procedure_components.toOwnedSlice(),
                    .procedure_component_sources = try procedure_component_sources.toOwnedSlice(),
                    .bindings = try bindings.toOwnedSlice(),
                    .final_subroutines = try final_subroutines.toOwnedSlice(),
                } };
            }
            var body_lp = LineParser.init(line, tokens);
            if (body_lp.consumeKeyword("CONTAINS")) {
                in_contains = true;
                self.index += 1;
                continue;
            }
            if (!in_contains and body_lp.consumeKeyword("SEQUENCE") and body_lp.peek() == null) {
                sequence = true;
                self.index += 1;
                continue;
            }
            if (!in_contains and decl.isDeclarationStart(body_lp)) {
                const component_decl = decl.parseDecl(&body_lp, self.arena) catch |err| {
                    root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, body_lp, err);
                    self.index += 1;
                    continue;
                };
                if (component_decl == .type_decl) {
                    try components.append(component_decl.type_decl);
                    try component_sources.append(root_diagnostics.sourceFromLine(line));
                } else if (component_decl == .procedure) {
                    try procedure_components.append(component_decl.procedure);
                    try procedure_component_sources.append(root_diagnostics.sourceFromLine(line));
                }
            } else if (in_contains and body_lp.consumeKeyword("PRIVATE") and body_lp.peek() == null) {
                if (saw_binding_stmt) {
                    self.diag_bag.set(
                        line.span.start_line,
                        if (line.segments.len > 0) line.segments[0].column else 1,
                        catalog.semantic.duplicate_declaration.code,
                        "must precede",
                        line.text,
                    );
                }
            } else if (in_contains and body_lp.isKeywordSplit("GENERIC")) {
                const type_bound_bindings = root_header.parseTypeBoundGenericBindings(self.arena, &body_lp) catch |err| {
                    root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, body_lp, err);
                    return err;
                };
                for (type_bound_bindings) |binding| {
                    var stored = binding;
                    stored.source = root_diagnostics.sourceFromLine(line);
                    try bindings.append(stored);
                }
                saw_binding_stmt = true;
            } else if (in_contains and body_lp.isKeywordSplit("FINAL")) {
                const final_names = root_header.parseTypeBoundFinalBindings(self.arena, &body_lp) catch |err| {
                    root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, body_lp, err);
                    return err;
                };
                for (final_names) |name| {
                    try final_subroutines.append(name);
                }
            } else if (in_contains and body_lp.isKeywordSplit("PROCEDURE")) {
                const type_bound_bindings = root_header.parseTypeBoundProcedureBindings(self.arena, &body_lp) catch |err| {
                    root_diagnostics.setParseDiagnosticFromStream(self.diag_bag, line, body_lp, err);
                    return err;
                };
                for (type_bound_bindings) |binding| {
                    var stored = binding;
                    stored.source = root_diagnostics.sourceFromLine(line);
                    try bindings.append(stored);
                }
                saw_binding_stmt = true;
            }
            self.index += 1;
        }
        return error.UnexpectedEOF;
    }

    pub fn parseInterfaceBlock(self: *Parser) anyerror!Decl {
        return root_units.parseInterfaceBlock(self);
    }
};

fn noteInvalidSubmoduleVisibility(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    tokens: []lexer.Token,
) void {
    var lp = LineParser.init(line, tokens);
    if (lp.consumeKeyword("PRIVATE") and lp.peek() == null) {
        diag_bag.set(
            line.span.start_line,
            if (line.segments.len > 0) line.segments[0].column else 1,
            catalog.parser.unexpected_token.code,
            "PRIVATE statement",
            line.text,
        );
        return;
    }
    lp = LineParser.init(line, tokens);
    if (lp.consumeKeyword("PUBLIC") and lp.peek() == null) {
        diag_bag.set(
            line.span.start_line,
            if (line.segments.len > 0) line.segments[0].column else 1,
            catalog.parser.unexpected_token.code,
            "PUBLIC statement",
            line.text,
        );
        return;
    }

    var scan = LineParser.init(line, tokens);
    _ = scan.next();
    while (scan.peek()) |tok| {
        _ = scan.next();
        if (tok.kind != .identifier) continue;
        const text = scan.tokenText(tok);
        if (std.ascii.eqlIgnoreCase(text, "PRIVATE")) {
            diag_bag.set(line.span.start_line, tok.column, catalog.parser.unexpected_token.code, "PRIVATE attribute", line.text);
            return;
        }
        if (std.ascii.eqlIgnoreCase(text, "PUBLIC")) {
            diag_bag.set(line.span.start_line, tok.column, catalog.parser.unexpected_token.code, "PUBLIC attribute", line.text);
            return;
        }
    }
}
