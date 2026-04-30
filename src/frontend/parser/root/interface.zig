const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const logical_line = @import("../../logical_line.zig");
const lexer = @import("../../lexer.zig");
const context = @import("../token_stream.zig");
const parse_diag = @import("../diagnostic.zig");
const stmt = @import("../stmt/mod.zig");

const ProgramUnit = ast.ProgramUnit;
const DeclSource = ast.DeclSource;
const LineParser = context.LineParser;

pub const InterfaceEndStatus = enum {
    none,
    valid,
    invalid_end_interface,
    other_end_stmt,
};

pub fn interfaceProcedureFromUnit(
    unit: ProgramUnit,
    source: DeclSource,
    end_source: DeclSource,
) ast.InterfaceProcedure {
    return .{
        .kind = unit.kind,
        .name = unit.name,
        .source = source,
        .end_source = end_source,
        .pure = unit.pure,
        .elemental = unit.elemental,
        .recursive = unit.recursive,
        .bind_c = unit.bind_c,
        .bind_name = unit.bind_name,
        .result_name = unit.result_name,
        .args = unit.args,
        .alt_return_dummy_count = unit.alt_return_dummy_count,
        .type_spec = declaredProcedureResultTypeSpec(unit),
        .decls = unit.decls,
        .decl_sources = unit.decl_sources,
    };
}

pub fn cloneProcedureResultDecl(
    arena: std.mem.Allocator,
    decls: []const ast.Decl,
    result_name: []const u8,
) !?ast.Decl {
    for (decls) |decl_node| {
        switch (decl_node) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    const items = try arena.alloc(ast.Declarator, 1);
                    items[0] = item;
                    return .{ .type_decl = .{
                        .type_kind = type_decl.type_kind,
                        .kind_selector = type_decl.kind_selector,
                        .derived_type_name = type_decl.derived_type_name,
                        .polymorphic = type_decl.polymorphic,
                        .items = items,
                        .parameter = type_decl.parameter,
                        .save = type_decl.save,
                        .allocatable = type_decl.allocatable,
                        .pointer = type_decl.pointer,
                        .optional = type_decl.optional,
                        .intent = type_decl.intent,
                        .external = type_decl.external,
                        .asynchronous = type_decl.asynchronous,
                        .contiguous = type_decl.contiguous,
                        .value_attr = type_decl.value_attr,
                        .volatile_attr = type_decl.volatile_attr,
                        .bind_c = type_decl.bind_c,
                        .bind_name_expr = type_decl.bind_name_expr,
                    } };
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    const items = try arena.alloc(ast.Declarator, 1);
                    items[0] = item;
                    return .{ .procedure = .{
                        .interface = procedure_decl.interface,
                        .items = items,
                        .pointer = procedure_decl.pointer,
                        .optional = procedure_decl.optional,
                        .save = procedure_decl.save,
                        .nopass = procedure_decl.nopass,
                        .pass_name = procedure_decl.pass_name,
                        .private = procedure_decl.private,
                    } };
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    const items = try arena.alloc(ast.Declarator, 1);
                    items[0] = item;
                    return .{ .dimension = .{
                        .items = items,
                        .allocatable = dimension_decl.allocatable,
                        .pointer = dimension_decl.pointer,
                    } };
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn classifyInterfaceEnd(
    arena: std.mem.Allocator,
    line: logical_line.LogicalLine,
    tokens: []lexer.Token,
    expected_name: ?[]const u8,
) !InterfaceEndStatus {
    var lp = LineParser.init(line, tokens);
    if (!lp.consumeKeyword("END")) return .none;
    if (!lp.consumeKeyword("INTERFACE")) return .other_end_stmt;
    if (lp.peek() == null) return .valid;

    const end_name = parseInterfaceGenericName(arena, &lp) catch return .invalid_end_interface;
    if (lp.peek() != null) return .invalid_end_interface;
    if (expected_name == null) return .invalid_end_interface;
    return if (std.ascii.eqlIgnoreCase(expected_name.?, end_name orelse return .invalid_end_interface))
        .valid
    else
        .invalid_end_interface;
}

pub fn noteInvalidInterfaceEnd(
    diag_bag: *parse_diag.Bag,
    line: logical_line.LogicalLine,
    interface_name: ?[]const u8,
) void {
    diag_bag.set(line.span.start_line, 1, catalog.parser.unexpected_token.code, invalidInterfaceEndMessage(interface_name), line.text);
}

pub fn noteMissingInterfaceEnd(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine) void {
    diag_bag.set(line.span.start_line, 1, catalog.parser.unexpected_token.code, "Expecting END INTERFACE", line.text);
}

pub fn noteUnexpectedInterfaceEof(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine) void {
    diag_bag.set(line.span.start_line, 1, catalog.parser.unexpected_eof.code, "Unexpected end of file", line.text);
}

pub fn consumeUnexpectedInterfaceStart(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine, lp: *LineParser) bool {
    if (!lp.consumeKeyword("INTERFACE") and !(lp.consumeKeyword("ABSTRACT") and lp.consumeKeyword("INTERFACE"))) return false;
    diag_bag.set(line.span.start_line, 1, catalog.parser.unexpected_token.code, "Unexpected INTERFACE statement", line.text);
    return true;
}

pub fn consumeUnexpectedAttributeDeclaration(diag_bag: *parse_diag.Bag, line: logical_line.LogicalLine, lp: *LineParser) bool {
    if (!lp.consumeKeyword("EXTERNAL")) return false;
    diag_bag.set(line.span.start_line, 1, catalog.parser.unexpected_token.code, "Unexpected attribute declaration statement in INTERFACE", line.text);
    return true;
}

pub fn parseInterfaceGenericName(arena: std.mem.Allocator, lp: *LineParser) !?[]const u8 {
    if (lp.peek() == null) return null;
    if (lp.isKeywordSplit("ASSIGNMENT")) {
        return (try stmt.action_stmt.parseAssignmentGenericSpec(arena, lp)).normalized_name;
    }
    if (lp.isKeywordSplit("OPERATOR")) {
        return (try stmt.action_stmt.parseOperatorGenericSpec(arena, lp)).normalized_name;
    }
    return lp.readName(arena);
}

fn invalidInterfaceEndMessage(interface_name: ?[]const u8) []const u8 {
    const name = interface_name orelse return "Expecting END INTERFACE";
    if (std.mem.startsWith(u8, name, "operator(")) return "Expecting END INTERFACE OPERATOR";
    if (std.mem.startsWith(u8, name, "assignment(")) return "Expecting END INTERFACE ASSIGNMENT";
    return "Expecting END INTERFACE";
}

fn declaredProcedureResultTypeSpec(unit: ProgramUnit) ?ast.ProcedureTypeSpec {
    const result_name = unit.result_name orelse unit.name;
    for (unit.decls) |decl_node| {
        switch (decl_node) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return .{
                        .type_kind = type_decl.type_kind,
                        .kind_selector = type_decl.kind_selector,
                        .derived_type_name = type_decl.derived_type_name,
                        .polymorphic = type_decl.polymorphic,
                    };
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return switch (procedure_decl.interface) {
                        .type_spec => |type_spec| type_spec,
                        else => null,
                    };
                }
            },
            else => {},
        }
    }
    return null;
}
