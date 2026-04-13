const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const logical_line = @import("../../../logical_line.zig");
const lexer = @import("../../../lexer.zig");
const context = @import("../../token_stream.zig");
const decl = @import("../../decl/mod.zig");
const parse_diag = @import("../../diagnostic.zig");
const array_info = @import("../../array_info.zig");
const stmt_shared = @import("shared.zig");

const Stmt = ast.Stmt;
const LineParser = context.LineParser;
const DoContext = @import("../control_flow.zig").DoContext;
const defaultSourceColumn = stmt_shared.defaultSourceColumn;
const setStmtSourceIfMissing = stmt_shared.setStmtSourceIfMissing;
const lexLine = stmt_shared.lexLine;

pub const ParseStatementFn = *const fn (
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,
) anyerror!Stmt;

pub fn parseNestedStmtBlock(
    arena: std.mem.Allocator,
    lines: []logical_line.LogicalLine,
    index: *usize,
    do_ctx: *DoContext,
    param_ints: *const std.StringHashMap(i64),
    param_strings: *const std.StringHashMap(ast.Literal),
    array_names: *const std.StringHashMap(array_info.ArrayInfo),
    diag_bag: *parse_diag.Bag,
    lex_diag_bag: *lexer.Bag,
    parse_statement_fn: ParseStatementFn,
    comptime stopFn: anytype,
) anyerror![]Stmt {
    var stmts = std.array_list.Managed(Stmt).init(arena);
    while (index.* < lines.len) {
        const line = lines[index.*];
        const tokens = try lexLine(arena, line, diag_bag, lex_diag_bag);
        defer arena.free(tokens);
        const lp = LineParser.init(line, tokens);
        if (stopFn(lp)) break;
        if (decl.isDeclarationStart(lp)) return error.DeclarationInIfBlock;
        var stmt = try parse_statement_fn(arena, lines, index, do_ctx, param_ints, param_strings, array_names, diag_bag, lex_diag_bag);
        if (stmt.source_line == 0) {
            _ = defaultSourceColumn;
            setStmtSourceIfMissing(&stmt, line);
        }
        try stmts.append(stmt);
    }
    return stmts.toOwnedSlice();
}
