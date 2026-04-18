const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const diag = @import("../../common/diagnostic.zig");
const symbols = @import("../../semantic/symbol/mod.zig");
const omp_declare_variant = @import("omp_declare_variant.zig");

const DirectiveLine = omp_declare_variant.DirectiveLine;

const ClauseDirective = struct {
    line: usize,
    column: usize,
    line_text: []const u8,
    full_text: []const u8,
    lines: []const DirectiveLine,
};

const RawLine = struct {
    line: usize,
    text: []const u8,
};

const ScanState = struct {
    current_top_owner: ?[]const u8 = null,
    current_owner: ?[]const u8 = null,
    current_procedure: ?[]const u8 = null,
};

const PostSemanticValidationContext = struct {
    program: ast.Program,
    sem: symbols.SemanticProgram,
    input_path: []const u8,
    diag_bag: *diag.Bag,
};

const PreSemanticValidationContext = struct {
    program: ast.Program,
    input_path: []const u8,
    contents: []const u8,
    diag_bag: *diag.Bag,
};

pub fn validateMinimalDirectiveCompatibility(
    arena: std.mem.Allocator,
    program: ast.Program,
    sem: symbols.SemanticProgram,
    input_path: []const u8,
    contents: []const u8,
    diag_bag: *diag.Bag,
) !void {
    try scanClauseDirectives(arena, contents, PostSemanticValidationContext{
        .program = program,
        .sem = sem,
        .input_path = input_path,
        .diag_bag = diag_bag,
    }, handlePostSemanticClauseDirective);
}

pub fn validatePreSemanticDirectiveCompatibility(
    arena: std.mem.Allocator,
    program: ast.Program,
    input_path: []const u8,
    contents: []const u8,
    diag_bag: *diag.Bag,
) !void {
    try scanClauseDirectives(arena, contents, PreSemanticValidationContext{
        .program = program,
        .input_path = input_path,
        .contents = contents,
        .diag_bag = diag_bag,
    }, handlePreSemanticClauseDirective);
}

fn scanClauseDirectives(
    arena: std.mem.Allocator,
    contents: []const u8,
    context: anytype,
    handler: anytype,
) !void {
    var offset: usize = 0;
    var line_no: usize = 0;
    var state = ScanState{};
    var first_error: ?anyerror = null;

    while (readNextRawLine(contents, &offset, &line_no)) |raw| {
        const trimmed = std.mem.trim(u8, raw.text, " \t");
        if (trimmed.len == 0) continue;

        if (omp_declare_variant.startsWithNoCase(trimmed, "!$omp")) {
            const directive = try readClauseDirective(arena, contents, &offset, &line_no, raw, trimmed);
            handler(arena, directive, state, context) catch |err| {
                if (first_error == null) first_error = err;
            };
            continue;
        }

        if (omp_declare_variant.isEndProcedureLine(trimmed)) {
            state.current_procedure = state.current_owner;
            state.current_owner = state.current_top_owner;
            continue;
        }
        if (omp_declare_variant.parseProcedureHeader(trimmed)) |proc_name| {
            state.current_procedure = proc_name;
            state.current_owner = state.current_top_owner;
            continue;
        }
        if (omp_declare_variant.parseTopOwnerHeader(trimmed)) |owner_name| {
            state.current_top_owner = owner_name;
            continue;
        }
    }

    if (first_error) |err| return err;
}

fn handlePostSemanticClauseDirective(
    arena: std.mem.Allocator,
    directive: ClauseDirective,
    state: ScanState,
    ctx: PostSemanticValidationContext,
) !void {
    try validateClauseDirective(
        arena,
        ctx.program,
        ctx.sem,
        ctx.input_path,
        directive,
        state.current_top_owner,
        state.current_owner,
        state.current_procedure,
        ctx.diag_bag,
    );
}

fn handlePreSemanticClauseDirective(
    arena: std.mem.Allocator,
    directive: ClauseDirective,
    state: ScanState,
    ctx: PreSemanticValidationContext,
) !void {
    try validatePreSemanticClauseDirective(
        arena,
        ctx.program,
        ctx.input_path,
        ctx.contents,
        directive,
        state.current_top_owner,
        state.current_owner,
        state.current_procedure,
        ctx.diag_bag,
    );
}

fn readNextRawLine(contents: []const u8, offset: *usize, line_no: *usize) ?RawLine {
    if (offset.* > contents.len) return null;
    const start = offset.*;
    var end = start;
    while (end < contents.len and contents[end] != '\n') : (end += 1) {}
    offset.* = if (end < contents.len) end + 1 else contents.len + 1;
    line_no.* += 1;

    var line = contents[start..end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return .{ .line = line_no.*, .text = line };
}

fn readClauseDirective(
    arena: std.mem.Allocator,
    contents: []const u8,
    offset: *usize,
    line_no: *usize,
    first_raw: RawLine,
    first_trimmed: []const u8,
) !ClauseDirective {
    var lines = std.array_list.Managed(DirectiveLine).init(arena);
    errdefer lines.deinit();
    try lines.append(.{
        .line = first_raw.line,
        .raw_text = first_raw.text,
        .payload_text = omp_declare_variant.directivePayload(first_trimmed),
    });

    while (offset.* <= contents.len) {
        const saved_offset = offset.*;
        const saved_line = line_no.*;
        const next_raw = readNextRawLine(contents, offset, line_no) orelse break;
        const next_trimmed = std.mem.trim(u8, next_raw.text, " \t");
        if (!omp_declare_variant.startsWithNoCase(next_trimmed, "!$omp&")) {
            offset.* = saved_offset;
            line_no.* = saved_line;
            break;
        }
        try lines.append(.{
            .line = next_raw.line,
            .raw_text = next_raw.text,
            .payload_text = omp_declare_variant.directivePayload(next_trimmed),
        });
    }

    return .{
        .line = first_raw.line,
        .column = 1,
        .line_text = first_raw.text,
        .full_text = try omp_declare_variant.joinDirectivePayload(arena, lines.items),
        .lines = try lines.toOwnedSlice(),
    };
}

fn validateClauseDirective(
    arena: std.mem.Allocator,
    program: ast.Program,
    sem: symbols.SemanticProgram,
    input_path: []const u8,
    directive: ClauseDirective,
    current_top_owner: ?[]const u8,
    current_owner: ?[]const u8,
    current_procedure: ?[]const u8,
    diag_bag: *diag.Bag,
) !void {
    if (omp_declare_variant.indexOfNoCase(directive.full_text, "declare variant") != null) return;

    var had_error = false;

    if (findClauseBody(directive.full_text, "reduction")) |body| {
        const entities = try collectReductionEntities(arena, body);
        for (entities) |entity| {
            if (!entityIsProcedurePointer(program, current_top_owner, current_owner, current_procedure, entity)) continue;
            const clause_line = findClauseLine(directive, "reduction", entity);
            const message = try std.fmt.allocPrint(arena, "Procedure pointer '{s}' may not appear in an OpenMP REDUCTION clause", .{entity});
            omp_declare_variant.addDirectiveDiagnostic(diag_bag, input_path, clause_line.line, 1, clause_line.raw_text, message);
            had_error = true;
        }
    }

    if (findClauseBody(directive.full_text, "linear")) |body| {
        const entities = try collectLinearEntities(arena, body);
        for (entities) |entity| {
            if (entityIsInteger(sem, current_top_owner, current_owner, current_procedure, entity)) continue;
            const clause_line = findClauseLine(directive, "linear", entity);
            const message = try std.fmt.allocPrint(arena, "'{s}' in LINEAR clause must be INTEGER", .{entity});
            omp_declare_variant.addDirectiveDiagnostic(diag_bag, input_path, clause_line.line, 1, clause_line.raw_text, message);
            had_error = true;
        }
    }

    if (had_error) return error.InvalidArgumentType;
}

fn validatePreSemanticClauseDirective(
    arena: std.mem.Allocator,
    program: ast.Program,
    input_path: []const u8,
    contents: []const u8,
    directive: ClauseDirective,
    current_top_owner: ?[]const u8,
    current_owner: ?[]const u8,
    current_procedure: ?[]const u8,
    diag_bag: *diag.Bag,
) !void {
    _ = current_top_owner;
    _ = current_owner;
    _ = current_procedure;
    if (omp_declare_variant.indexOfNoCase(directive.full_text, "declare variant") != null) return;

    var had_error = false;

    if (findClauseBody(directive.full_text, "firstprivate")) |body| {
        const entities = try collectClauseEntityNames(arena, body);
        for (entities) |entity| {
            if (!programDeclaresPolymorphicArrayBeforeLine(program, directive.line, entity) and
                !rawSourceDeclaresPolymorphicArray(contents, directive.line, entity)) continue;
            const clause_line = findClauseLine(directive, "firstprivate", entity);
            const message = "Sorry, polymorphic arrays not yet supported for firstprivate";
            omp_declare_variant.addDirectiveDiagnostic(diag_bag, input_path, clause_line.line, 1, clause_line.raw_text, message);
            had_error = true;
        }
    }

    if (had_error) return error.InvalidArgumentType;
}

fn findClauseBody(text: []const u8, clause_name: []const u8) ?[]const u8 {
    const idx = omp_declare_variant.indexOfNoCase(text, clause_name) orelse return null;
    const rest = std.mem.trimLeft(u8, text[idx + clause_name.len ..], " \t");
    if (rest.len == 0 or rest[0] != '(') return null;
    const close_idx = omp_declare_variant.findMatchingParen(rest, 0) orelse return null;
    return rest[1..close_idx];
}

fn collectReductionEntities(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    const colon_idx = std.mem.lastIndexOfScalar(u8, body, ':') orelse return &.{};
    return collectClauseEntityNames(arena, body[colon_idx + 1 ..]);
}

fn collectLinearEntities(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    return collectClauseEntityNames(arena, body);
}

fn collectClauseEntityNames(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(arena);
    var i: usize = 0;
    while (i < body.len) {
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == ',')) : (i += 1) {}
        if (i >= body.len) break;

        const start = i;
        while (i < body.len and (std.ascii.isAlphabetic(body[i]) or std.ascii.isDigit(body[i]) or body[i] == '_')) : (i += 1) {}
        if (i > start) try out.append(body[start..i]);

        var depth: usize = 0;
        while (i < body.len) : (i += 1) {
            const ch = body[i];
            if (ch == '(') depth += 1;
            if (ch == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
            if (depth == 0 and ch == ',') {
                i += 1;
                break;
            }
        }
    }
    return out.toOwnedSlice();
}

fn entityIsProcedurePointer(
    program: ast.Program,
    current_top_owner: ?[]const u8,
    current_owner: ?[]const u8,
    current_procedure: ?[]const u8,
    name: []const u8,
) bool {
    const current_unit = findActiveProgramUnit(program, current_top_owner, current_owner, current_procedure) orelse return false;
    if (programUnitDeclaresProcedurePointer(current_unit, name)) return true;
    if (current_owner) |owner_name| {
        if (findOwnerProgramUnit(program, owner_name)) |owner_unit| {
            if (programUnitDeclaresProcedurePointer(owner_unit, name)) return true;
        }
    }
    return false;
}

fn entityIsInteger(
    sem: symbols.SemanticProgram,
    current_top_owner: ?[]const u8,
    current_owner: ?[]const u8,
    current_procedure: ?[]const u8,
    name: []const u8,
) bool {
    if (findSemanticSymbolForDirectiveContext(sem, current_top_owner, current_owner, current_procedure, name)) |sym| {
        return sym.loweredKind() == .integer;
    }
    return false;
}

fn entityIsPolymorphicArray(
    program: ast.Program,
    sem: symbols.SemanticProgram,
    before_line: usize,
    current_top_owner: ?[]const u8,
    current_owner: ?[]const u8,
    current_procedure: ?[]const u8,
    name: []const u8,
) bool {
    if (findSemanticSymbolForDirectiveContext(sem, current_top_owner, current_owner, current_procedure, name)) |sym| {
        if (sym.type_spec.polymorphic and sym.dims.len > 0) return true;
    }

    for (program.units) |unit| {
        if (!unitMatchesDirectiveContext(unit, current_top_owner, current_owner, current_procedure)) continue;
        if (programUnitDeclaresPolymorphicArrayBeforeLine(unit, name, before_line)) return true;
    }
    for (program.units) |unit| {
        if (programUnitDeclaresPolymorphicArrayBeforeLine(unit, name, before_line)) return true;
    }
    if (current_owner) |owner_name| {
        if (findOwnerProgramUnit(program, owner_name)) |owner_unit| {
            if (programUnitDeclaresPolymorphicArrayBeforeLine(owner_unit, name, before_line)) return true;
        }
    }
    return false;
}

fn programDeclaresPolymorphicArrayBeforeLine(program: ast.Program, before_line: usize, name: []const u8) bool {
    for (program.units) |unit| {
        if (programUnitDeclaresPolymorphicArrayBeforeLine(unit, name, before_line)) return true;
    }
    return false;
}

fn findSemanticSymbolForDirectiveContext(
    sem: symbols.SemanticProgram,
    current_top_owner: ?[]const u8,
    current_owner: ?[]const u8,
    current_procedure: ?[]const u8,
    name: []const u8,
) ?symbols.Symbol {
    if (current_procedure) |proc_name| {
        if (findSemanticUnitByName(sem, proc_name)) |unit| {
            if (lookupSemanticSymbol(unit, name)) |sym| return sym;
        }
    }
    if (current_owner) |owner_name| {
        if (findSemanticUnitByName(sem, owner_name)) |unit| {
            if (lookupSemanticSymbol(unit, name)) |sym| return sym;
        }
    }
    if (current_top_owner) |top_owner| {
        if (findSemanticUnitByName(sem, top_owner)) |unit| {
            if (lookupSemanticSymbol(unit, name)) |sym| return sym;
        }
    }
    if (findImplicitMainSemanticUnit(sem)) |unit| {
        if (lookupSemanticSymbol(unit, name)) |sym| return sym;
    }
    return null;
}

fn findSemanticUnitByName(sem: symbols.SemanticProgram, name: []const u8) ?*const symbols.SemanticUnit {
    for (sem.units) |*unit| {
        if (std.ascii.eqlIgnoreCase(unit.name, name)) return unit;
    }
    return null;
}

fn findImplicitMainSemanticUnit(sem: symbols.SemanticProgram) ?*const symbols.SemanticUnit {
    for (sem.units) |*unit| {
        if (std.ascii.startsWithIgnoreCase(unit.name, "__COL6FORGE_PROGRAM")) return unit;
    }
    return null;
}

fn lookupSemanticSymbol(unit: *const symbols.SemanticUnit, name: []const u8) ?symbols.Symbol {
    for (unit.symbols) |sym| {
        if (std.ascii.eqlIgnoreCase(sym.name, name)) return sym.normalized();
    }
    return null;
}

fn findActiveProgramUnit(
    program: ast.Program,
    current_top_owner: ?[]const u8,
    current_owner: ?[]const u8,
    current_procedure: ?[]const u8,
) ?ast.ProgramUnit {
    if (current_procedure) |proc_name| {
        for (program.units) |unit| {
            if (!std.ascii.eqlIgnoreCase(unit.name, proc_name)) continue;
            if (current_owner == null and unit.owner_name == null) return unit;
            if (current_owner != null and unit.owner_name != null and std.ascii.eqlIgnoreCase(unit.owner_name.?, current_owner.?)) return unit;
        }
    }
    if (current_top_owner) |owner_name| {
        if (findOwnerProgramUnit(program, owner_name)) |unit| return unit;
    }
    for (program.units) |unit| {
        if (unit.kind == .program and unit.owner_name == null and std.ascii.startsWithIgnoreCase(unit.name, "__COL6FORGE_PROGRAM")) return unit;
    }
    return null;
}

fn findOwnerProgramUnit(program: ast.Program, owner_name: []const u8) ?ast.ProgramUnit {
    for (program.units) |unit| {
        if (std.ascii.eqlIgnoreCase(unit.name, owner_name) and unit.owner_name == null) return unit;
    }
    return null;
}

fn programUnitDeclaresProcedurePointer(unit: ast.ProgramUnit, name: []const u8) bool {
    for (unit.decls) |decl| {
        if (decl != .procedure) continue;
        const procedure_decl = decl.procedure;
        if (!procedure_decl.pointer) continue;
        for (procedure_decl.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
        }
    }
    return false;
}

fn programUnitDeclaresPolymorphicArrayBeforeLine(unit: ast.ProgramUnit, name: []const u8, before_line: usize) bool {
    for (unit.decls, 0..) |decl, decl_idx| {
        if (decl != .type_decl) continue;
        const type_decl = decl.type_decl;
        if (!type_decl.polymorphic) continue;
        const source = if (decl_idx < unit.decl_sources.len) unit.decl_sources[decl_idx] else ast.DeclSource{};
        if (source.line != 0 and source.line >= before_line) continue;
        for (type_decl.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            if (item.dims.len > 0) return true;
        }
    }
    return false;
}

fn unitMatchesDirectiveContext(
    unit: ast.ProgramUnit,
    current_top_owner: ?[]const u8,
    current_owner: ?[]const u8,
    current_procedure: ?[]const u8,
) bool {
    if (current_procedure) |proc_name| {
        if (std.ascii.eqlIgnoreCase(unit.name, proc_name)) {
            if (current_owner == null and unit.owner_name == null) return true;
            if (current_owner != null and unit.owner_name != null and std.ascii.eqlIgnoreCase(unit.owner_name.?, current_owner.?)) return true;
        }
    }
    if (current_owner) |owner_name| {
        if (std.ascii.eqlIgnoreCase(unit.name, owner_name)) return true;
        if (unit.owner_name != null and std.ascii.eqlIgnoreCase(unit.owner_name.?, owner_name)) return true;
    }
    if (current_top_owner) |top_owner| {
        if (std.ascii.eqlIgnoreCase(unit.name, top_owner)) return true;
        if (unit.owner_name != null and std.ascii.eqlIgnoreCase(unit.owner_name.?, top_owner)) return true;
    }
    return false;
}

fn rawSourceDeclaresPolymorphicArray(contents: []const u8, before_line: usize, name: []const u8) bool {
    var offset: usize = 0;
    var line_no: usize = 0;
    while (readNextRawLine(contents, &offset, &line_no)) |raw| {
        if (raw.line >= before_line) break;
        const trimmed = std.mem.trim(u8, raw.text, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '!') continue;
        if (omp_declare_variant.indexOfNoCase(trimmed, "class") == null) continue;
        if (indexOfIdentifierNoCase(trimmed, name)) |name_idx| {
            const after_name = trimmed[name_idx + name.len ..];
            const after_trimmed = std.mem.trimLeft(u8, after_name, " \t");
            if (after_trimmed.len != 0 and after_trimmed[0] == '(') return true;
        }
    }
    return false;
}

fn indexOfIdentifierNoCase(text: []const u8, needle: []const u8) ?usize {
    var start: usize = 0;
    while (omp_declare_variant.indexOfNoCase(text[start..], needle)) |rel_idx| {
        const idx = start + rel_idx;
        const before_ok = idx == 0 or !isIdentifierChar(text[idx - 1]);
        const after_idx = idx + needle.len;
        const after_ok = after_idx >= text.len or !isIdentifierChar(text[after_idx]);
        if (before_ok and after_ok) return idx;
        start = idx + 1;
        if (start >= text.len) break;
    }
    return null;
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_';
}

fn findClauseLine(directive: ClauseDirective, clause_name: []const u8, body: []const u8) DirectiveLine {
    for (directive.lines) |line| {
        if (!omp_declare_variant.containsCaseInsensitive(line.payload_text, clause_name)) continue;
        if (body.len == 0 or omp_declare_variant.containsCaseInsensitive(line.payload_text, body)) return line;
    }
    return directive.lines[directive.lines.len - 1];
}
