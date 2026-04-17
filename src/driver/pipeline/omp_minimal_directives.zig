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

pub fn validateMinimalDirectiveCompatibility(
    arena: std.mem.Allocator,
    program: ast.Program,
    sem: symbols.SemanticProgram,
    input_path: []const u8,
    contents: []const u8,
    diag_bag: *diag.Bag,
) !void {
    var offset: usize = 0;
    var line_no: usize = 0;
    var current_top_owner: ?[]const u8 = null;
    var current_owner: ?[]const u8 = null;
    var current_procedure: ?[]const u8 = null;
    var first_error: ?anyerror = null;

    while (readNextRawLine(contents, &offset, &line_no)) |raw| {
        const trimmed = std.mem.trim(u8, raw.text, " \t");
        if (trimmed.len == 0) continue;

        if (omp_declare_variant.startsWithNoCase(trimmed, "!$omp")) {
            const directive = try readClauseDirective(arena, contents, &offset, &line_no, raw, trimmed);
            validateClauseDirective(
                arena,
                program,
                sem,
                input_path,
                directive,
                current_top_owner,
                current_owner,
                current_procedure,
                diag_bag,
            ) catch |err| {
                if (first_error == null) first_error = err;
            };
            continue;
        }

        if (omp_declare_variant.isEndProcedureLine(trimmed)) {
            current_procedure = current_owner;
            current_owner = current_top_owner;
            continue;
        }
        if (omp_declare_variant.parseProcedureHeader(trimmed)) |proc_name| {
            current_procedure = proc_name;
            current_owner = current_top_owner;
            continue;
        }
        if (omp_declare_variant.parseTopOwnerHeader(trimmed)) |owner_name| {
            current_top_owner = owner_name;
            continue;
        }
    }

    if (first_error) |err| return err;
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

fn findClauseLine(directive: ClauseDirective, clause_name: []const u8, body: []const u8) DirectiveLine {
    for (directive.lines) |line| {
        if (!omp_declare_variant.containsCaseInsensitive(line.payload_text, clause_name)) continue;
        if (body.len == 0 or omp_declare_variant.containsCaseInsensitive(line.payload_text, body)) return line;
    }
    return directive.lines[directive.lines.len - 1];
}
