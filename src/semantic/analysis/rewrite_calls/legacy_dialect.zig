const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../context.zig");
const resolve_expr = @import("../resolve_expr/mod.zig");
const resolve_symbols = @import("../resolve_symbols.zig");
const symbols = @import("../../symbol/mod.zig");

const RewriteResult = struct {
    stmts: []ast.Stmt,
    changed: bool,
};

const RewriteState = struct {
    next_temp_idx: usize = 0,
};

pub fn lowerLegacyDialectLoops(ctx: *context.Context) !void {
    if (ctx.dialect != .f77_legacy) return;
    var state = RewriteState{};
    const rewritten = try rewriteStmtList(ctx, &state, ctx.unit.stmts);
    if (rewritten.changed) {
        ctx.replaceUnitStmts(rewritten.stmts);
    }
}

fn rewriteStmtList(
    ctx: *context.Context,
    state: *RewriteState,
    stmts: []const ast.Stmt,
) anyerror!RewriteResult {
    var out = std.array_list.Managed(ast.Stmt).init(ctx.arena);
    errdefer out.deinit();

    var changed = false;
    var idx: usize = 0;
    while (idx < stmts.len) {
        const stmt = stmts[idx];
        if (stmt.node == .do_loop and try shouldLowerLegacyArithmeticDo(ctx, stmt.node.do_loop)) {
            const end_idx = findLoopEndIndex(stmts, idx, stmt.node.do_loop.end_label) orelse return error.InvalidDoLabel;
            const body_result = try rewriteStmtList(ctx, state, stmts[idx + 1 .. end_idx + 1]);
            try appendLoweredLegacyRealDo(ctx, state, &out, stmt, stmt.node.do_loop, body_result.stmts);
            changed = true;
            if (body_result.changed) changed = true;
            idx = end_idx + 1;
            continue;
        }

        var stmt_copy = stmt;
        if (try rewriteNestedStmt(ctx, state, &stmt_copy)) changed = true;
        try out.append(stmt_copy);
        idx += 1;
    }

    return .{
        .stmts = try out.toOwnedSlice(),
        .changed = changed,
    };
}

fn rewriteNestedStmt(
    ctx: *context.Context,
    state: *RewriteState,
    stmt: *ast.Stmt,
) anyerror!bool {
    var changed = false;
    switch (stmt.node) {
        .associate_block => |*associate| {
            const result = try rewriteStmtList(ctx, state, associate.stmts);
            if (result.changed) {
                associate.stmts = result.stmts;
                changed = true;
            }
        },
        .select_type_block => |*select_type| {
            for (select_type.clauses) |*clause| {
                const result = try rewriteStmtList(ctx, state, clause.stmts);
                if (result.changed) {
                    clause.stmts = result.stmts;
                    changed = true;
                }
            }
        },
        .if_single => |*ifs| {
            var inner_stmt = ast.Stmt{
                .label = null,
                .node = ifs.stmt.*,
                .source_line = stmt.source_line,
                .source_column = stmt.source_column,
                .source_text = stmt.source_text,
            };
            if (try rewriteNestedStmt(ctx, state, &inner_stmt)) {
                const node_ptr = try ctx.arena.create(ast.StmtNode);
                node_ptr.* = inner_stmt.node;
                ifs.stmt = node_ptr;
                changed = true;
            }
        },
        .if_block => |*ifb| {
            const then_result = try rewriteStmtList(ctx, state, ifb.then_stmts);
            const else_result = try rewriteStmtList(ctx, state, ifb.else_stmts);
            if (then_result.changed or else_result.changed) {
                ifb.then_stmts = then_result.stmts;
                ifb.else_stmts = else_result.stmts;
                changed = true;
            }
        },
        else => {},
    }
    return changed;
}

fn shouldLowerLegacyArithmeticDo(ctx: *context.Context, loop: ast.DoLoopStmt) !bool {
    const loop_idx = resolve_symbols.findSymbolIndex(ctx, loop.var_name) orelse return error.UnknownSymbol;
    const loop_sym = ctx.symbols.items[loop_idx];
    if (loop_sym.dims.len != 0) return false;
    if (!isLegacyDialectDoControlKind(loop_sym.loweredKind())) return false;
    if (loop_sym.loweredKind() != .integer) return true;
    if (try exprNeedsLegacyArithmeticLowering(ctx, loop.start)) return true;
    if (try exprNeedsLegacyArithmeticLowering(ctx, loop.end)) return true;
    if (loop.step) |step| {
        if (try exprNeedsLegacyArithmeticLowering(ctx, step)) return true;
    }
    return false;
}

fn findLoopEndIndex(stmts: []const ast.Stmt, start_idx: usize, end_label: []const u8) ?usize {
    const canonical_end = canonicalNumericLabel(end_label);
    var idx = start_idx + 1;
    while (idx < stmts.len) : (idx += 1) {
        const stmt_label = stmts[idx].label orelse continue;
        if (std.ascii.eqlIgnoreCase(stmt_label, end_label)) return idx;
        if (std.mem.eql(u8, canonicalNumericLabel(stmt_label), canonical_end)) return idx;
    }
    return null;
}

fn appendLoweredLegacyRealDo(
    ctx: *context.Context,
    state: *RewriteState,
    out: *std.array_list.Managed(ast.Stmt),
    stmt: ast.Stmt,
    loop: ast.DoLoopStmt,
    rewritten_body: []const ast.Stmt,
) !void {
    const loop_idx = resolve_symbols.findSymbolIndex(ctx, loop.var_name) orelse return error.UnknownSymbol;
    const loop_sym = ctx.symbols.items[loop_idx];
    const loop_spec = loop_sym.type_spec;

    const start_name = try nextGeneratedName(ctx, state, "__c6f_legacy_do_start");
    const end_name = try nextGeneratedName(ctx, state, "__c6f_legacy_do_end");
    const step_name = try nextGeneratedName(ctx, state, "__c6f_legacy_do_step");
    const synthetic_end_label = try nextGeneratedName(ctx, state, "__c6f_legacy_do_done");

    try installGeneratedScalarTemp(ctx, start_name, loop_spec);
    try installGeneratedScalarTemp(ctx, end_name, loop_spec);
    try installGeneratedScalarTemp(ctx, step_name, loop_spec);

    try out.append(makeAssignmentStmt(
        stmt,
        try identifierExpr(ctx, start_name),
        try cloneExpr(ctx, loop.start),
    ));
    try out.append(makeAssignmentStmt(
        stmt,
        try identifierExpr(ctx, end_name),
        try cloneExpr(ctx, loop.end),
    ));
    try out.append(makeAssignmentStmt(
        stmt,
        try identifierExpr(ctx, step_name),
        if (loop.step) |step_expr| try cloneExpr(ctx, step_expr) else try unitStepLiteralExpr(ctx, loop_sym),
    ));
    try out.append(try makeZeroStepGuardStmt(ctx, stmt, step_name, loop_sym));
    try out.append(makeAssignmentStmt(
        stmt,
        try identifierExpr(ctx, loop.var_name),
        try identifierExpr(ctx, start_name),
    ));
    try out.append(.{
        .label = stmt.label,
        .node = .{
            .do_while = .{
                .end_label = synthetic_end_label,
                .condition = try makeLegacyDoConditionExpr(ctx, loop.var_name, end_name, step_name, loop_sym),
            },
        },
        .source_line = stmt.source_line,
        .source_column = stmt.source_column,
        .source_text = stmt.source_text,
    });
    try out.appendSlice(rewritten_body);
    try out.append(makeAssignmentStmt(
        stmt,
        try identifierExpr(ctx, loop.var_name),
        try binaryExpr(
            ctx,
            .add,
            try identifierExpr(ctx, loop.var_name),
            try identifierExpr(ctx, step_name),
        ),
    ));
    try out.append(.{
        .label = synthetic_end_label,
        .node = .{ .cont = {} },
        .source_line = stmt.source_line,
        .source_column = stmt.source_column,
        .source_text = stmt.source_text,
    });
}

fn installGeneratedScalarTemp(ctx: *context.Context, name: []const u8, spec: symbols.TypeSpec) !void {
    var symbol = symbols.Symbol.init(name, spec, &.{}, .variable, .local);
    symbol.type_explicit = true;
    symbol.is_generated_temp = true;
    _ = try resolve_symbols.internSymbol(ctx, symbol);
}

fn nextGeneratedName(ctx: *context.Context, state: *RewriteState, prefix: []const u8) ![]const u8 {
    defer state.next_temp_idx += 1;
    return std.fmt.allocPrint(ctx.arena, "{s}_{d}", .{ prefix, state.next_temp_idx });
}

fn makeAssignmentStmt(source_stmt: ast.Stmt, target: *ast.Expr, value: *ast.Expr) ast.Stmt {
    return .{
        .label = null,
        .node = .{
            .assignment = .{
                .target = target,
                .value = value,
            },
        },
        .source_line = source_stmt.source_line,
        .source_column = source_stmt.source_column,
        .source_text = source_stmt.source_text,
    };
}

fn makeZeroStepGuardStmt(
    ctx: *context.Context,
    source_stmt: ast.Stmt,
    step_name: []const u8,
    loop_sym: symbols.Symbol,
) !ast.Stmt {
    const cond = try binaryExpr(
        ctx,
        .eq,
        try identifierExpr(ctx, step_name),
        try zeroLiteralExpr(ctx, loop_sym),
    );
    const stop_ptr = try ctx.arena.create(ast.StmtNode);
    stop_ptr.* = .{ .stop = {} };
    return .{
        .label = null,
        .node = .{
            .if_single = .{
                .condition = cond,
                .stmt = stop_ptr,
            },
        },
        .source_line = source_stmt.source_line,
        .source_column = source_stmt.source_column,
        .source_text = source_stmt.source_text,
    };
}

fn makeLegacyDoConditionExpr(
    ctx: *context.Context,
    var_name: []const u8,
    end_name: []const u8,
    step_name: []const u8,
    loop_sym: symbols.Symbol,
) !*ast.Expr {
    const forward = try binaryExpr(
        ctx,
        .and_,
        try binaryExpr(
            ctx,
            .ge,
            try identifierExpr(ctx, step_name),
            try zeroLiteralExpr(ctx, loop_sym),
        ),
        try binaryExpr(
            ctx,
            .le,
            try identifierExpr(ctx, var_name),
            try identifierExpr(ctx, end_name),
        ),
    );
    const backward = try binaryExpr(
        ctx,
        .and_,
        try binaryExpr(
            ctx,
            .lt,
            try identifierExpr(ctx, step_name),
            try zeroLiteralExpr(ctx, loop_sym),
        ),
        try binaryExpr(
            ctx,
            .ge,
            try identifierExpr(ctx, var_name),
            try identifierExpr(ctx, end_name),
        ),
    );
    return binaryExpr(ctx, .or_, forward, backward);
}

fn identifierExpr(ctx: *context.Context, name: []const u8) !*ast.Expr {
    const expr = try ctx.arena.create(ast.Expr);
    expr.* = .{ .identifier = name };
    return expr;
}

fn binaryExpr(
    ctx: *context.Context,
    op: ast.BinaryOp,
    left: *ast.Expr,
    right: *ast.Expr,
) !*ast.Expr {
    const expr = try ctx.arena.create(ast.Expr);
    expr.* = .{
        .binary = .{
            .op = op,
            .left = left,
            .right = right,
        },
    };
    return expr;
}

fn zeroLiteralExpr(ctx: *context.Context, loop_sym: symbols.Symbol) !*ast.Expr {
    return switch (loop_sym.loweredKind()) {
        .double_precision => literalExpr(ctx, .real, "0.0D0"),
        .real => literalExpr(ctx, .real, "0.0"),
        else => literalExpr(ctx, .integer, "0"),
    };
}

fn unitStepLiteralExpr(ctx: *context.Context, loop_sym: symbols.Symbol) !*ast.Expr {
    return switch (loop_sym.loweredKind()) {
        .double_precision => literalExpr(ctx, .real, "1.0D0"),
        .real => literalExpr(ctx, .real, "1.0"),
        else => literalExpr(ctx, .integer, "1"),
    };
}

fn literalExpr(ctx: *context.Context, kind: ast.LiteralKind, text: []const u8) !*ast.Expr {
    const expr = try ctx.arena.create(ast.Expr);
    expr.* = .{
        .literal = .{
            .kind = kind,
            .text = text,
        },
    };
    return expr;
}

fn cloneExpr(ctx: *context.Context, node: *ast.Expr) !*ast.Expr {
    const cloned = try ctx.arena.create(ast.Expr);
    switch (node.*) {
        .identifier => |name| cloned.* = .{ .identifier = name },
        .literal => |lit| cloned.* = .{ .literal = lit },
        .array_constructor => |ctor| {
            const items = try ctx.arena.alloc(*ast.Expr, ctor.items.len);
            for (ctor.items, 0..) |item, idx| items[idx] = try cloneExpr(ctx, item);
            cloned.* = .{ .array_constructor = .{ .type_spec = ctor.type_spec, .items = items } };
        },
        .call_or_subscript => |call| {
            const args = try ctx.arena.alloc(*ast.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| args[idx] = try cloneExpr(ctx, arg);
            cloned.* = .{ .call_or_subscript = .{ .name = call.name, .args = args } };
        },
        .substring => |sub| {
            const args = try ctx.arena.alloc(*ast.Expr, sub.args.len);
            for (sub.args, 0..) |arg, idx| args[idx] = try cloneExpr(ctx, arg);
            cloned.* = .{
                .substring = .{
                    .name = sub.name,
                    .args = args,
                    .start = if (sub.start) |start| try cloneExpr(ctx, start) else null,
                    .end = if (sub.end) |end_expr| try cloneExpr(ctx, end_expr) else null,
                },
            };
        },
        .component => |comp| {
            const args = try ctx.arena.alloc(*ast.Expr, comp.args.len);
            for (comp.args, 0..) |arg, idx| args[idx] = try cloneExpr(ctx, arg);
            cloned.* = .{
                .component = .{
                    .base = try cloneExpr(ctx, comp.base),
                    .name = comp.name,
                    .args = args,
                    .has_parens = comp.has_parens,
                },
            };
        },
        .dim_range => |range| {
            cloned.* = .{
                .dim_range = .{
                    .lower = if (range.lower) |lower| try cloneExpr(ctx, lower) else null,
                    .upper = try cloneExpr(ctx, range.upper),
                    .stride = if (range.stride) |stride| try cloneExpr(ctx, stride) else null,
                    .assumed_shape = range.assumed_shape,
                },
            };
        },
        .unary => |un| {
            cloned.* = .{ .unary = .{ .op = un.op, .expr = try cloneExpr(ctx, un.expr) } };
        },
        .binary => |bin| {
            cloned.* = .{
                .binary = .{
                    .op = bin.op,
                    .left = try cloneExpr(ctx, bin.left),
                    .right = try cloneExpr(ctx, bin.right),
                },
            };
        },
        .complex_literal => |lit| {
            cloned.* = .{
                .complex_literal = .{
                    .real = try cloneExpr(ctx, lit.real),
                    .imag = try cloneExpr(ctx, lit.imag),
                },
            };
        },
        .implied_do => |implied| {
            const items = try ctx.arena.alloc(*ast.Expr, implied.items.len);
            for (implied.items, 0..) |item, idx| items[idx] = try cloneExpr(ctx, item);
            cloned.* = .{
                .implied_do = .{
                    .items = items,
                    .var_name = implied.var_name,
                    .start = try cloneExpr(ctx, implied.start),
                    .end = try cloneExpr(ctx, implied.end),
                    .step = if (implied.step) |step| try cloneExpr(ctx, step) else null,
                },
            };
        },
    }
    return cloned;
}

fn canonicalNumericLabel(label: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, label, "0");
    return if (trimmed.len == 0) "0" else trimmed;
}

fn exprNeedsLegacyArithmeticLowering(ctx: *context.Context, expr: *ast.Expr) !bool {
    const kind = (try resolve_expr.exprTypeSpec(ctx, expr)).lowered_kind;
    if (!isLegacyDialectDoControlKind(kind)) return false;
    return kind != .integer;
}

fn isLegacyDialectDoControlKind(kind: ast.TypeKind) bool {
    return switch (kind) {
        .integer, .real, .double_precision => true,
        else => false,
    };
}
