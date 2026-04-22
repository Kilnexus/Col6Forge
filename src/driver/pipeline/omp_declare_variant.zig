const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const diag = @import("../../common/diagnostic.zig");
const catalog = @import("../../common/error_catalog.zig");
const function_type = @import("../../semantic/split/function_type.zig");
const procedure_inference = @import("../../semantic/split/api/procedure_inference.zig");
const symbols = @import("../../semantic/symbol/mod.zig");
const analysis_context = @import("../../semantic/analysis/context.zig");

const AdjustClauseKind = analysis_context.Context.DeclareVariantAdjustArgKind;

const ScanEvent = union(enum) {
    top_owner: []const u8,
    procedure_begin: struct { owner: ?[]const u8, name: []const u8 },
    procedure_end,
    declare_variant: Directive,
};

pub const DirectiveLine = struct {
    line: usize,
    raw_text: []const u8,
    payload_text: []const u8,
};

const Directive = struct {
    line: usize,
    column: usize,
    line_text: []const u8,
    full_text: []const u8,
    variant_name: []const u8,
    lines: []const DirectiveLine,
};

const AdjustItemTag = enum {
    identifier,
    omp_num_args,
    positive_integer,
    range_expr,
};

const AdjustItem = struct {
    tag: AdjustItemTag,
    text: []const u8,
};

const AdjustClause = struct {
    kind: AdjustClauseKind,
    items: []const AdjustItem,
    source_line: DirectiveLine,
    kind_valid: bool,
    has_colon: bool,
};

const ProcedureDef = union(enum) {
    unit: ast.ProgramUnit,
    iface: struct {
        owner_unit: ast.ProgramUnit,
        proc: ast.InterfaceProcedure,
    },
};

const SourceScanner = struct {
    arena: std.mem.Allocator,
    contents: []const u8,
    offset: usize = 0,
    line_no: usize = 0,
    current_top_owner: ?[]const u8 = null,
    current_owner: ?[]const u8 = null,
    current_procedure: ?[]const u8 = null,

    const RawLine = struct {
        line: usize,
        text: []const u8,
    };

    fn init(arena: std.mem.Allocator, contents: []const u8) SourceScanner {
        return .{ .arena = arena, .contents = contents };
    }

    fn next(self: *SourceScanner) !?ScanEvent {
        while (self.offset <= self.contents.len) {
            const raw = self.readNextRawLine() orelse return null;
            const trimmed = std.mem.trim(u8, raw.text, " \t");
            if (trimmed.len == 0) continue;

            if (startsWithNoCase(trimmed, "!$omp")) {
                if (try self.readDeclareVariantDirective(raw, trimmed)) |directive| return .{ .declare_variant = directive };
            }
            if (isEndProcedureLine(trimmed)) return .procedure_end;
            if (parseProcedureHeader(trimmed)) |proc_name| {
                return .{ .procedure_begin = .{
                    .owner = self.current_procedure orelse self.current_top_owner,
                    .name = proc_name,
                } };
            }
            if (parseTopOwnerHeader(trimmed)) |owner_name| return .{ .top_owner = owner_name };
        }
        return null;
    }

    fn readNextRawLine(self: *SourceScanner) ?RawLine {
        if (self.offset > self.contents.len) return null;
        const start = self.offset;
        var end = start;
        while (end < self.contents.len and self.contents[end] != '\n') : (end += 1) {}
        self.offset = if (end < self.contents.len) end + 1 else self.contents.len + 1;
        self.line_no += 1;

        var line = self.contents[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return .{ .line = self.line_no, .text = line };
    }

    fn readDeclareVariantDirective(self: *SourceScanner, first_raw: RawLine, first_trimmed: []const u8) !?Directive {
        if (indexOfNoCase(first_trimmed, "declare variant") == null) return null;

        var lines = std.array_list.Managed(DirectiveLine).init(self.arena);
        errdefer lines.deinit();
        try lines.append(.{
            .line = first_raw.line,
            .raw_text = first_raw.text,
            .payload_text = directivePayload(first_trimmed),
        });

        while (self.offset <= self.contents.len) {
            const saved_offset = self.offset;
            const saved_line = self.line_no;
            const next_raw = self.readNextRawLine() orelse break;
            const next_trimmed = std.mem.trim(u8, next_raw.text, " \t");
            if (!startsWithNoCase(next_trimmed, "!$omp&")) {
                self.offset = saved_offset;
                self.line_no = saved_line;
                break;
            }
            try lines.append(.{
                .line = next_raw.line,
                .raw_text = next_raw.text,
                .payload_text = directivePayload(next_trimmed),
            });
        }

        const joined = try joinDirectivePayload(self.arena, lines.items);
        const variant_name = parseVariantName(joined) orelse return null;
        return .{
            .line = first_raw.line,
            .column = 1,
            .line_text = first_raw.text,
            .full_text = joined,
            .variant_name = variant_name,
            .lines = try lines.toOwnedSlice(),
        };
    }
};

pub fn collectDeclareVariantAdjustArgs(
    arena: std.mem.Allocator,
    program: ast.Program,
    contents: []const u8,
) ![]const analysis_context.Context.DeclareVariantAdjustArg {
    var scanner = SourceScanner.init(arena, contents);
    var out = std.array_list.Managed(analysis_context.Context.DeclareVariantAdjustArg).init(arena);

    while (try scanner.next()) |event| {
        switch (event) {
            .top_owner => |name| scanner.current_top_owner = name,
            .procedure_begin => |proc| {
                scanner.current_procedure = proc.name;
                scanner.current_owner = proc.owner;
            },
            .procedure_end => {
                scanner.current_procedure = scanner.current_owner;
                scanner.current_owner = scanner.current_top_owner;
            },
            .declare_variant => |directive| {
                try appendDirectiveAdjustArgs(arena, program, directive, scanner.current_owner, scanner.current_procedure, &out);
            },
        }
    }

    return out.toOwnedSlice();
}

pub fn validateDeclareVariantCompatibility(
    arena: std.mem.Allocator,
    program: ast.Program,
    input_path: []const u8,
    contents: []const u8,
    diag_bag: *diag.Bag,
) !void {
    var scanner = SourceScanner.init(arena, contents);
    var first_error: ?anyerror = null;

    while (try scanner.next()) |event| {
        switch (event) {
            .top_owner => |name| scanner.current_top_owner = name,
            .procedure_begin => |proc| {
                scanner.current_procedure = proc.name;
                scanner.current_owner = proc.owner;
            },
            .procedure_end => {
                scanner.current_procedure = scanner.current_owner;
                scanner.current_owner = scanner.current_top_owner;
            },
            .declare_variant => |directive| {
                validateDirective(arena, program, input_path, contents, directive, scanner.current_owner, scanner.current_procedure, diag_bag) catch |err| {
                    if (first_error == null) first_error = err;
                };
            },
        }
    }

    if (first_error) |err| return err;
}


fn appendDirectiveAdjustArgs(
    arena: std.mem.Allocator,
    program: ast.Program,
    directive: Directive,
    owner_name: ?[]const u8,
    base_name: ?[]const u8,
    out: *std.array_list.Managed(analysis_context.Context.DeclareVariantAdjustArg),
) !void {
    const base_proc_name = base_name orelse return;
    const base_proc = findProcedureDef(program, owner_name, base_proc_name) orelse return;
    var clauses = std.array_list.Managed(AdjustClause).init(arena);
    defer clauses.deinit();
    defer freeAdjustClauses(arena, clauses.items);

    try parseAdjustClauses(arena, directive, &clauses);
    for (clauses.items) |clause| {
        for (clause.items) |item| {
            if (item.tag != .identifier) continue;
            try out.append(.{
                .procedure_name = procedureDefName(base_proc),
                .arg_name = item.text,
                .kind = clause.kind,
            });
        }
    }
}


fn validateDirective(
    arena: std.mem.Allocator,
    program: ast.Program,
    input_path: []const u8,
    contents: []const u8,
    directive: Directive,
    owner_name: ?[]const u8,
    base_name: ?[]const u8,
    diag_bag: *diag.Bag,
) !void {
    const base_proc_name = base_name orelse return;
    const base_proc = findProcedureDef(program, owner_name, base_proc_name) orelse return;
    const variant_proc = findProcedureDef(program, owner_name, directive.variant_name) orelse
        findProcedureDef(program, null, directive.variant_name) orelse return;

    var clauses = std.array_list.Managed(AdjustClause).init(arena);
    defer clauses.deinit();
    defer freeAdjustClauses(arena, clauses.items);

    try parseAdjustClauses(arena, directive, &clauses);
    const has_match = containsClauseNoCase(directive.full_text, "match");
    const has_dispatch_match = hasDispatchMatchClause(directive.full_text);

    if (clauses.items.len != 0 and !has_match) {
        addDirectiveDiagnostic(diag_bag, input_path, directive.line, directive.column, directive.line_text, "expected 'match' clause at (1).");
        return error.InvalidArgumentCount;
    }
    if (clauses.items.len != 0 and !has_dispatch_match) {
        addDirectiveDiagnostic(diag_bag, input_path, directive.line, directive.column, directive.line_text, "the 'adjust_args' clause can only be specified if the 'dispatch' selector of the construct selector set appears in the 'match' clause at (1).");
        return error.InvalidArgumentCount;
    }

    const base_sig = try inferProcedureSig(arena, base_proc);
    const variant_sig = try inferProcedureSig(arena, variant_proc);
    if (try validateAdjustClauses(arena, program, input_path, base_proc, base_sig, clauses.items, diag_bag)) {
        return error.InvalidArgumentCount;
    }

    const mismatch = try firstMismatch(arena, base_sig, variant_sig) orelse return;
    const rendered = try std.fmt.allocPrint(
        arena,
        "variant '{s}' and base '{s}' at ({d}) have incompatible types: {s}",
        .{ directive.variant_name, base_proc_name, directive.line, mismatch },
    );

    var spans: [1]diag.DiagnosticSpan = .{.{
        .file_path = input_path,
        .line = headerLineForProcedure(contents, base_proc_name, owner_name) orelse directive.line,
        .column = 1,
        .end_column = 0,
        .line_text = sourceLineAt(contents, headerLineForProcedure(contents, base_proc_name, owner_name) orelse directive.line),
        .label = "base procedure declared here",
    }};
    diag_bag.addDetailed(input_path, directive.line, directive.column, catalog.semantic.invalid_argument_type.code, rendered, directive.line_text, .{
        .stage = .semantic,
        .primary_label = "declare variant compatibility mismatch here",
        .secondary_spans = spans[0..],
    });
    return error.InvalidArgumentCount;
}

fn validateAdjustClauses(
    arena: std.mem.Allocator,
    program: ast.Program,
    input_path: []const u8,
    base_proc: ProcedureDef,
    base_sig: analysis_context.Context.ProcedureSig,
    clauses: []const AdjustClause,
    diag_bag: *diag.Bag,
) !bool {
    var had_error = false;
    var seen_names = std.StringHashMap(void).init(arena);
    defer seen_names.deinit();

    for (clauses) |clause| {
        if (!clause.kind_valid) {
            addDirectiveDiagnostic(diag_bag, input_path, clause.source_line.line, 1, clause.source_line.raw_text, "expected 'nothing', 'need_device_ptr' or 'need_device_addr' at (1).");
            had_error = true;
            continue;
        }
        if (!clause.has_colon) {
            addDirectiveDiagnostic(diag_bag, input_path, clause.source_line.line, 1, clause.source_line.raw_text, "expected ':' at (1).");
            had_error = true;
            continue;
        }
        for (clause.items) |item| {
            if (item.text.len == 0) {
                addDirectiveDiagnostic(diag_bag, input_path, clause.source_line.line, 1, clause.source_line.raw_text, "expected dummy parameter name, 'omp_num_args' or constant positive integer at (1).");
                had_error = true;
                continue;
            }
            switch (item.tag) {
                .identifier => {
                    if (seen_names.contains(item.text)) {
                        addDirectiveDiagnostic(diag_bag, input_path, clause.source_line.line, 1, clause.source_line.raw_text, try std.fmt.allocPrint(arena, "'{s}' at (1) is specified more than once", .{item.text}));
                        had_error = true;
                        continue;
                    }
                    try seen_names.put(item.text, {});

                    const formal = findFormalArg(base_sig, item.text);
                    if (formal == null) {
                        if (findVisibleDeclSource(program, base_proc, item.text)) |decl_source| {
                            const message = try std.fmt.allocPrint(arena, "List item '{s}' at (1), declared at (2), is not a dummy argument", .{item.text});
                            var spans: [1]diag.DiagnosticSpan = .{.{
                                .file_path = input_path,
                                .line = decl_source.line,
                                .column = if (decl_source.column == 0) 1 else decl_source.column,
                                .line_text = decl_source.text,
                                .label = "declared here",
                            }};
                            diag_bag.addDetailed(input_path, clause.source_line.line, 1, catalog.semantic.invalid_argument_type.code, message, clause.source_line.raw_text, .{
                                .stage = .semantic,
                                .primary_label = "invalid adjust_args list item here",
                                .secondary_spans = spans[0..],
                            });
                        } else {
                            addDirectiveDiagnostic(diag_bag, input_path, clause.source_line.line, 1, clause.source_line.raw_text, try std.fmt.allocPrint(arena, "Symbol '{s}' at (1) has no IMPLICIT type", .{item.text}));
                            addDirectiveDiagnostic(diag_bag, input_path, clause.source_line.line, 1, clause.source_line.raw_text, "Expected dummy parameter name or a positive integer at (1).");
                        }
                        had_error = true;
                        continue;
                    }

                    if (clause.kind == .need_device_ptr and !isScalarCPtr(formal.?)) {
                        const message = try std.fmt.allocPrint(
                            arena,
                            "Argument '{s}' at (1) to list item in 'need_device_ptr' at (2) must be a scalar of TYPE(C_PTR)",
                            .{item.text},
                        );
                        const note_text = if (isCPtrType(formal.?.type_spec) and formal.?.rank != 0)
                            &[_]diag.DiagnosticMessage{.{ .text = "Consider using 'need_device_addr' instead" }}
                        else
                            &[_]diag.DiagnosticMessage{};
                        diag_bag.addDetailed(input_path, clause.source_line.line, 1, catalog.semantic.invalid_argument_type.code, message, clause.source_line.raw_text, .{
                            .stage = .semantic,
                            .primary_label = "invalid need_device_ptr item here",
                            .notes = note_text,
                        });
                        had_error = true;
                    }
                },
                .omp_num_args, .positive_integer => {},
                .range_expr => {
                    if (std.mem.indexOfScalar(u8, item.text, ':') == null) {
                        addDirectiveDiagnostic(diag_bag, input_path, clause.source_line.line, 1, clause.source_line.raw_text, "Expected dummy parameter name or a positive integer at (1).");
                        had_error = true;
                    }
                },
            }
        }
    }

    return had_error;
}

fn parseAdjustClauses(
    arena: std.mem.Allocator,
    directive: Directive,
    out: *std.array_list.Managed(AdjustClause),
) !void {
    var pos: usize = 0;
    while (indexOfNoCaseFrom(directive.full_text, "adjust_args", pos)) |idx| {
        const open_idx = std.mem.indexOfScalarPos(u8, directive.full_text, idx, '(') orelse break;
        const close_idx = findMatchingParen(directive.full_text, open_idx) orelse break;
        const body = std.mem.trim(u8, directive.full_text[open_idx + 1 .. close_idx], " \t");
        const clause_line = findClauseLine(directive, "adjust_args", body);
        try out.append(try parseSingleAdjustClause(arena, clause_line, body));
        pos = close_idx + 1;
    }
}

fn parseSingleAdjustClause(
    arena: std.mem.Allocator,
    clause_line: DirectiveLine,
    body: []const u8,
) !AdjustClause {
    if (body.len == 0) {
        return .{
            .kind = .nothing,
            .items = try arena.dupe(AdjustItem, &.{.{ .tag = .range_expr, .text = "" }}),
            .source_line = clause_line,
            .kind_valid = false,
            .has_colon = false,
        };
    }

    const colon_idx = std.mem.indexOfScalar(u8, body, ':');
    const kind_text = std.mem.trim(u8, body[0 .. colon_idx orelse body.len], " \t");
    const parsed_kind = parseAdjustKind(kind_text);
    const kind = parsed_kind orelse .nothing;
    const items_text = if (colon_idx) |idx| std.mem.trim(u8, body[idx + 1 ..], " \t") else "";

    var items = std.array_list.Managed(AdjustItem).init(arena);
    errdefer items.deinit();

    if (parseAdjustKind(kind_text) == null or colon_idx == null) {
        try items.append(.{ .tag = .range_expr, .text = "" });
        return .{
            .kind = kind,
            .items = try items.toOwnedSlice(),
            .source_line = clause_line,
            .kind_valid = parsed_kind != null,
            .has_colon = colon_idx != null,
        };
    }

    if (items_text.len == 0) {
        try items.append(.{ .tag = .range_expr, .text = "" });
        return .{
            .kind = kind,
            .items = try items.toOwnedSlice(),
            .source_line = clause_line,
            .kind_valid = parsed_kind != null,
            .has_colon = true,
        };
    }

    var splitter = std.mem.splitScalar(u8, items_text, ',');
    while (splitter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) {
            try items.append(.{ .tag = .range_expr, .text = "" });
            continue;
        }
        try items.append(.{
            .tag = classifyAdjustItem(trimmed),
            .text = trimmed,
        });
    }

    return .{
        .kind = kind,
        .items = try items.toOwnedSlice(),
        .source_line = clause_line,
        .kind_valid = true,
        .has_colon = true,
    };
}

fn freeAdjustClauses(arena: std.mem.Allocator, clauses: []const AdjustClause) void {
    for (clauses) |clause| arena.free(clause.items);
}

fn classifyAdjustItem(text: []const u8) AdjustItemTag {
    if (text.len == 0) return .range_expr;
    if (std.ascii.eqlIgnoreCase(text, "omp_num_args")) return .omp_num_args;
    if (parsePositiveInt(text) != null) return .positive_integer;
    if (std.mem.indexOfScalar(u8, text, ':') != null) return .range_expr;
    if (isIdentifier(text)) return .identifier;
    return .range_expr;
}

fn parseAdjustKind(text: []const u8) ?AdjustClauseKind {
    if (std.ascii.eqlIgnoreCase(text, "nothing")) return .nothing;
    if (std.ascii.eqlIgnoreCase(text, "need_device_ptr")) return .need_device_ptr;
    if (std.ascii.eqlIgnoreCase(text, "need_device_addr")) return .need_device_addr;
    return null;
}

fn containsClauseNoCase(text: []const u8, clause_name: []const u8) bool {
    return indexOfNoCase(text, clause_name) != null;
}

fn hasDispatchMatchClause(text: []const u8) bool {
    var compact = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer compact.deinit();
    for (text) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        compact.append(std.ascii.toLower(ch)) catch return false;
    }
    return std.mem.indexOf(u8, compact.items, "match(construct={dispatch})") != null;
}

fn findFormalArg(sig: analysis_context.Context.ProcedureSig, name: []const u8) ?analysis_context.Context.ProcedureSig.ArgSig {
    for (sig.args) |arg| {
        if (std.ascii.eqlIgnoreCase(arg.name, name)) return arg;
    }
    return null;
}

fn isScalarCPtr(arg: analysis_context.Context.ProcedureSig.ArgSig) bool {
    return arg.rank == 0 and isCPtrType(arg.type_spec);
}

fn isCPtrType(spec: symbols.TypeSpec) bool {
    return spec.lowered_kind == .derived and spec.derived_type_name != null and std.ascii.eqlIgnoreCase(spec.derived_type_name.?, "c_ptr");
}

fn findVisibleDeclSource(program: ast.Program, base_proc: ProcedureDef, name: []const u8) ?ast.DeclSource {
    switch (base_proc) {
        .unit => |unit| {
            if (findDeclSourceInUnit(unit, name)) |source| return source;
            const owner_name = unit.owner_name orelse return null;
            for (program.units) |candidate| {
                if (candidate.owner_name != null) continue;
                if (!std.ascii.eqlIgnoreCase(candidate.name, owner_name)) continue;
                if (findDeclSourceInUnit(candidate, name)) |source| return source;
            }
            return null;
        },
        .iface => |iface| {
            if (findDeclSourceInInterfaceProc(iface.owner_unit, iface.proc, name)) |source| return source;
            if (findDeclSourceInUnit(iface.owner_unit, name)) |source| return source;
            const owner_name = iface.owner_unit.owner_name orelse return null;
            for (program.units) |candidate| {
                if (candidate.owner_name != null) continue;
                if (!std.ascii.eqlIgnoreCase(candidate.name, owner_name)) continue;
                if (findDeclSourceInUnit(candidate, name)) |source| return source;
            }
            return null;
        },
    }
}

fn findDeclSourceInInterfaceProc(unit: ast.ProgramUnit, proc: ast.InterfaceProcedure, name: []const u8) ?ast.DeclSource {
    const active_decls = if (proc.decls.len != 0) proc.decls else unit.decls;
    const active_sources = if (proc.decl_sources.len != 0) proc.decl_sources else unit.decl_sources;
    return findDeclSourceInDecls(active_decls, active_sources, name);
}

fn findDeclSourceInUnit(unit: ast.ProgramUnit, name: []const u8) ?ast.DeclSource {
    return findDeclSourceInDecls(unit.decls, unit.decl_sources, name);
}

fn findDeclSourceInDecls(decls: []const ast.Decl, sources: []const ast.DeclSource, name: []const u8) ?ast.DeclSource {
    for (decls, 0..) |decl, decl_idx| {
        const source = if (decl_idx < sources.len) sources[decl_idx] else ast.DeclSource{};
        switch (decl) {
            .type_decl => |type_decl| for (type_decl.items) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, name)) return source;
            },
            .procedure => |procedure_decl| for (procedure_decl.items) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, name)) return source;
            },
            .dimension => |dimension_decl| for (dimension_decl.items) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, name)) return source;
            },
            else => {},
        }
    }
    return null;
}

pub fn addDirectiveDiagnostic(
    diag_bag: *diag.Bag,
    input_path: []const u8,
    line: usize,
    column: usize,
    line_text: []const u8,
    message: []const u8,
) void {
    diag_bag.addDetailed(input_path, line, column, catalog.semantic.invalid_argument_type.code, message, line_text, .{
        .stage = .semantic,
        .primary_label = "invalid OpenMP declare variant clause here",
    });
}

fn inferProcedureSig(arena: std.mem.Allocator, proc_def: ProcedureDef) !analysis_context.Context.ProcedureSig {
    return switch (proc_def) {
        .unit => |unit| .{
            .kind = unit.kind,
            .arg_count = unit.args.len,
            .alt_return_count = unit.alt_return_dummy_count,
            .args = try procedure_inference.inferProcedureArgSigs(arena, unit),
            .pure = unit.pure,
            .elemental = unit.elemental,
            .is_pointer = function_type.inferProcedureIsPointer(unit),
            .result_rank = if (unit.kind == .function) function_type.inferFunctionResultRank(unit) else 0,
            .result_type_spec = if (unit.kind == .function) function_type.inferFunctionTypeSpec(unit) else null,
            .result_shape_signature = if (unit.kind == .function) try function_type.inferFunctionResultShapeSignature(arena, unit) else &.{},
            .result_allocatable = if (unit.kind == .function) function_type.inferFunctionResultAllocatable(unit) else false,
            .result_contiguous = if (unit.kind == .function) function_type.inferFunctionResultContiguous(unit) else false,
            .result_procedure_pointer = if (unit.kind == .function) function_type.inferFunctionResultIsProcedurePointer(unit) else false,
            .actual_requires_explicit_interface = unit.owner_name != null,
            .definition_known_from_current_program = true,
        },
        .iface => |iface| .{
            .kind = iface.proc.kind,
            .arg_count = iface.proc.args.len,
            .alt_return_count = iface.proc.alt_return_dummy_count,
            .args = try procedure_inference.inferInterfaceProcedureArgSigs(arena, iface.owner_unit, iface.proc),
            .pure = iface.proc.pure,
            .elemental = iface.proc.elemental,
            .is_pointer = false,
            .result_rank = if (iface.proc.kind == .function) procedure_inference.interfaceProcedureResultRank(iface.proc) else 0,
            .result_type_spec = if (iface.proc.kind == .function) procedure_inference.interfaceProcedureResultTypeSpec(iface.owner_unit, iface.proc) else null,
            .result_shape_signature = if (iface.proc.kind == .function) try procedure_inference.interfaceProcedureResultShapeSignature(arena, iface.proc) else &.{},
            .result_allocatable = if (iface.proc.kind == .function) procedure_inference.interfaceProcedureResultAttrs(iface.proc).allocatable else false,
            .result_contiguous = if (iface.proc.kind == .function) procedure_inference.interfaceProcedureResultAttrs(iface.proc).contiguous else false,
            .result_procedure_pointer = if (iface.proc.kind == .function) procedure_inference.interfaceProcedureResultAttrs(iface.proc).procedure_pointer else false,
            .actual_requires_explicit_interface = true,
            .definition_known_from_current_program = true,
        },
    };
}

fn firstMismatch(
    allocator: std.mem.Allocator,
    base_sig: analysis_context.Context.ProcedureSig,
    variant_sig: analysis_context.Context.ProcedureSig,
) !?[]const u8 {
    if (base_sig.kind != variant_sig.kind) {
        return if (base_sig.kind == .subroutine) "base is a SUBROUTINE but variant is a FUNCTION" else "base is a FUNCTION but variant is a SUBROUTINE";
    }
    if (base_sig.arg_count != variant_sig.arg_count or base_sig.alt_return_count != variant_sig.alt_return_count) {
        return "wrong number of arguments";
    }

    const count = @min(base_sig.args.len, variant_sig.args.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const base_arg = base_sig.args[idx];
        const variant_arg = variant_sig.args[idx];
        if (base_arg.rank != variant_arg.rank) {
            return try std.fmt.allocPrint(allocator, "Rank mismatch in argument '{s}'", .{base_arg.name});
        }
        if (!typeSpecCompatible(base_arg.type_spec, variant_arg.type_spec)) {
            return try formatTypeMismatch(allocator, base_arg.name, base_arg.type_spec, variant_arg.type_spec);
        }
    }
    return null;
}

fn formatTypeMismatch(
    allocator: std.mem.Allocator,
    arg_name: []const u8,
    expected: symbols.TypeSpec,
    actual: symbols.TypeSpec,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Type mismatch in argument '{s}' ({s}/{s})", .{
        arg_name,
        typeSpecLabel(expected),
        typeSpecLabel(actual),
    });
}

fn typeSpecCompatible(a: symbols.TypeSpec, b: symbols.TypeSpec) bool {
    if (a.lowered_kind != b.lowered_kind) return false;
    if (a.lowered_kind == .derived) {
        if (a.polymorphic != b.polymorphic) return false;
        if (a.derived_type_name == null or b.derived_type_name == null) return a.derived_type_name == null and b.derived_type_name == null;
        return std.ascii.eqlIgnoreCase(a.derived_type_name.?, b.derived_type_name.?);
    }
    if (a.lowered_kind == .character and a.char_len_kind == .constant and b.char_len_kind == .constant) {
        if (a.char_len != null and b.char_len != null and a.char_len.? != b.char_len.?) return false;
    }
    if (a.kind_value != null and b.kind_value != null and a.kind_value.? != b.kind_value.?) return false;
    return true;
}

fn typeSpecLabel(spec: symbols.TypeSpec) []const u8 {
    if (spec.lowered_kind == .derived) {
        if (spec.derived_type_name) |name| {
            if (std.ascii.eqlIgnoreCase(name, "c_ptr")) return "TYPE(c_ptr)";
            if (std.ascii.eqlIgnoreCase(name, "c_funptr")) return "TYPE(c_funptr)";
            return "TYPE(derived)";
        }
        return "TYPE(derived)";
    }
    return switch (spec.lowered_kind) {
        .integer => "INTEGER",
        .real => if (spec.declared_kind == .double_precision) "DOUBLE PRECISION" else "REAL",
        .complex => if (spec.declared_kind == .complex_double) "COMPLEX*16" else "COMPLEX",
        .logical => "LOGICAL",
        .character => "CHARACTER",
        .derived => unreachable,
        else => "TYPE",
    };
}

fn findProcedureDef(program: ast.Program, owner_name: ?[]const u8, name: []const u8) ?ProcedureDef {
    for (program.units) |*unit| {
        if (unit.kind == .subroutine or unit.kind == .function) {
            if (std.ascii.eqlIgnoreCase(unit.name, name)) {
                if (owner_name == null and unit.owner_name == null) return .{ .unit = unit.* };
                if (owner_name != null and unit.owner_name != null and std.ascii.eqlIgnoreCase(owner_name.?, unit.owner_name.?)) return .{ .unit = unit.* };
            }
        }
        const header_owner_name = unit.name;
        const owner_matches =
            (owner_name == null and unit.owner_name == null and (unit.kind == .program or unit.kind == .module)) or
            (owner_name != null and std.ascii.eqlIgnoreCase(owner_name.?, header_owner_name));
        if (!owner_matches) continue;
        for (unit.decls) |decl| {
            if (decl != .interface_block) continue;
            for (decl.interface_block.procedure_headers) |proc_header| {
                if (!std.ascii.eqlIgnoreCase(proc_header.name, name)) continue;
                return .{ .iface = .{
                    .owner_unit = unit.*,
                    .proc = proc_header,
                } };
            }
        }
    }
    return null;
}

fn procedureDefName(proc_def: ProcedureDef) []const u8 {
    return switch (proc_def) {
        .unit => |unit| unit.name,
        .iface => |iface| iface.proc.name,
    };
}

fn parseVariantName(text: []const u8) ?[]const u8 {
    const idx = indexOfNoCase(text, "declare variant") orelse return null;
    const open_idx = std.mem.indexOfScalarPos(u8, text, idx, '(') orelse return null;
    const close_idx = findMatchingParen(text, open_idx) orelse return null;
    const name = std.mem.trim(u8, text[open_idx + 1 .. close_idx], " \t");
    return if (name.len == 0) null else name;
}

pub fn parseTopOwnerHeader(trimmed: []const u8) ?[]const u8 {
    if (parseHeaderName(trimmed, "program")) |name| return name;
    if (parseHeaderName(trimmed, "module")) |name| return name;
    return null;
}

pub fn parseProcedureHeader(trimmed: []const u8) ?[]const u8 {
    if (startsWithNoCase(trimmed, "end ")) return null;
    if (parseHeaderName(trimmed, "subroutine")) |name| return name;
    if (parseHeaderName(trimmed, "function")) |name| return name;
    if (indexOfNoCase(trimmed, " function ")) |idx| {
        const rest = trimmed[idx + " function ".len ..];
        return parseLeadingIdentifier(rest);
    }
    return null;
}

fn parseHeaderName(trimmed: []const u8, keyword: []const u8) ?[]const u8 {
    if (!startsWithNoCase(trimmed, keyword)) return null;
    const rest = std.mem.trimStart(u8, trimmed[keyword.len..], " \t");
    return parseLeadingIdentifier(rest);
}

fn parseLeadingIdentifier(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    var len: usize = 0;
    while (len < text.len) : (len += 1) {
        const ch = text[len];
        if (!(std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_')) break;
    }
    if (len == 0) return null;
    return text[0..len];
}

pub fn isEndProcedureLine(trimmed: []const u8) bool {
    return startsWithNoCase(trimmed, "end subroutine") or startsWithNoCase(trimmed, "endsubroutine") or startsWithNoCase(trimmed, "end function") or startsWithNoCase(trimmed, "endfunction");
}

pub fn startsWithNoCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

pub fn indexOfNoCase(text: []const u8, needle: []const u8) ?usize {
    return indexOfNoCaseFrom(text, needle, 0);
}

fn indexOfNoCaseFrom(text: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0 or text.len < needle.len or start >= text.len) return null;
    var i = start;
    while (i + needle.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn findMatchingParen(text: []const u8, open_idx: usize) ?usize {
    if (open_idx >= text.len or text[open_idx] != '(') return null;
    var depth: usize = 0;
    var idx = open_idx;
    while (idx < text.len) : (idx += 1) {
        switch (text[idx]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return idx;
            },
            else => {},
        }
    }
    return null;
}

pub fn directivePayload(trimmed: []const u8) []const u8 {
    const no_comment = stripHarnessComment(trimmed);
    if (startsWithNoCase(no_comment, "!$omp&")) return std.mem.trim(u8, no_comment["!$omp&".len..], " \t");
    if (startsWithNoCase(no_comment, "!$omp")) return std.mem.trim(u8, no_comment["!$omp".len..], " \t");
    return no_comment;
}

fn stripHarnessComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, " ! {")) |idx| return std.mem.trimEnd(u8, line[0..idx], " \t");
    if (std.mem.indexOf(u8, line, " !{")) |idx| return std.mem.trimEnd(u8, line[0..idx], " \t");
    return line;
}

pub fn joinDirectivePayload(arena: std.mem.Allocator, lines: []const DirectiveLine) ![]const u8 {
    var out = std.array_list.Managed(u8).init(arena);
    for (lines, 0..) |line, idx| {
        var payload = std.mem.trim(u8, line.payload_text, " \t");
        if (payload.len != 0 and payload[payload.len - 1] == '&') {
            payload = std.mem.trimEnd(u8, payload[0 .. payload.len - 1], " \t");
        }
        if (idx != 0 and payload.len != 0) try out.append(' ');
        try out.appendSlice(payload);
    }
    return out.toOwnedSlice();
}

fn findClauseLine(directive: Directive, clause_name: []const u8, body: []const u8) DirectiveLine {
    for (directive.lines) |line| {
        if (!containsCaseInsensitive(line.payload_text, clause_name)) continue;
        if (body.len == 0 or containsCaseInsensitive(line.payload_text, body)) return line;
    }
    return directive.lines[directive.lines.len - 1];
}

pub fn containsCaseInsensitive(text: []const u8, needle: []const u8) bool {
    return indexOfNoCase(text, needle) != null;
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text[1..]) |ch| {
        if (!(std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    }
    return true;
}

fn parsePositiveInt(text: []const u8) ?usize {
    const value = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (value == 0) null else value;
}

fn headerLineForProcedure(contents: []const u8, proc_name: []const u8, owner_name: ?[]const u8) ?usize {
    _ = owner_name;
    var scanner = SourceScanner.init(std.heap.page_allocator, contents);
    while (scanner.next() catch null) |event| {
        switch (event) {
            .top_owner => |name| scanner.current_top_owner = name,
            .procedure_begin => |proc| {
                scanner.current_owner = proc.owner;
                scanner.current_procedure = proc.name;
                if (std.ascii.eqlIgnoreCase(proc.name, proc_name)) return scanner.line_no;
            },
            .procedure_end => {
                scanner.current_procedure = scanner.current_owner;
                scanner.current_owner = scanner.current_top_owner;
            },
            .declare_variant => {},
        }
    }
    return null;
}

fn sourceLineAt(contents: []const u8, line_no: usize) []const u8 {
    if (line_no == 0) return "";
    var current: usize = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= contents.len) : (i += 1) {
        const is_end = i == contents.len or contents[i] == '\n';
        if (!is_end) continue;
        if (current == line_no) {
            var slice = contents[start..i];
            if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
            return slice;
        }
        current += 1;
        start = i + 1;
    }
    return "";
}
