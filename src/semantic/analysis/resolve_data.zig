const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const context = @import("context.zig");
const resolve_const = @import("resolve_const.zig");
const resolve_symbols = @import("resolve_symbols.zig");

const min_compact_array_fill: usize = 8_192;

const ArrayShape = struct {
    rank: usize,
    size: ?usize,
    lowers: []i64,
    extents: ?[]usize,
};

const DataValueSpan = struct {
    value: *ast.Expr,
    count: usize,
};

const DataValueCursor = struct {
    spans: []const DataValueSpan,
    span_idx: usize = 0,
    span_offset: usize = 0,
    remaining: usize,

    fn init(spans: []const DataValueSpan) DataValueCursor {
        var total: usize = 0;
        for (spans) |span| {
            total = std.math.add(usize, total, span.count) catch unreachable;
        }
        return .{
            .spans = spans,
            .remaining = total,
        };
    }

    fn remainingCount(self: *const DataValueCursor) usize {
        return self.remaining;
    }

    fn pop(self: *DataValueCursor) !*ast.Expr {
        if (self.remaining == 0) return error.DataValueCountMismatch;
        while (self.span_idx < self.spans.len) {
            const span = self.spans[self.span_idx];
            if (self.span_offset < span.count) {
                self.span_offset += 1;
                self.remaining -= 1;
                if (self.span_offset == span.count) {
                    self.span_idx += 1;
                    self.span_offset = 0;
                }
                return span.value;
            }
            self.span_idx += 1;
            self.span_offset = 0;
        }
        return error.DataValueCountMismatch;
    }

    // Consume `count` values iff they are all backed by the same expression node.
    fn consumeUniform(self: *DataValueCursor, count: usize) ?*ast.Expr {
        if (count == 0 or self.remaining < count) return null;

        var probe_span_idx = self.span_idx;
        var probe_span_offset = self.span_offset;
        var probe_remaining = count;
        var uniform_value: ?*ast.Expr = null;

        while (probe_remaining > 0) {
            if (probe_span_idx >= self.spans.len) return null;
            const span = self.spans[probe_span_idx];
            if (probe_span_offset >= span.count) {
                probe_span_idx += 1;
                probe_span_offset = 0;
                continue;
            }
            const available = span.count - probe_span_offset;
            const take = @min(available, probe_remaining);
            if (uniform_value) |value| {
                if (value != span.value) return null;
            } else {
                uniform_value = span.value;
            }
            probe_remaining -= take;
            probe_span_offset += take;
            if (probe_span_offset == span.count) {
                probe_span_idx += 1;
                probe_span_offset = 0;
            }
        }

        self.span_idx = probe_span_idx;
        self.span_offset = probe_span_offset;
        self.remaining -= count;
        return uniform_value;
    }
};

pub fn lowerDataStatements(ctx: *context.Context) !void {
    if (ctx.unit.stmts.len == 0) return;
    var first_error: ?anyerror = null;
    for (ctx.unit.stmts) |*stmt| {
        if (stmt.node == .data and stmt.node.data.groups.len > 0) {
            const prev_stmt = ctx.current_stmt;
            ctx.setCurrentStmt(stmt.*);
            const lowered = lowerDataStmt(ctx, stmt.node.data) catch |err| {
                ctx.current_stmt = prev_stmt;
                if (!ctx.usesExplicitDiagnosticBag()) return err;
                if (first_error == null) first_error = err;
                continue;
            };
            ctx.current_stmt = prev_stmt;
            stmt.node = .{ .data = lowered };
        }
    }
    if (first_error) |err| return err;
    if (ctx.unit_backing) |unit_ptr| {
        unit_ptr.stmts = ctx.unit.stmts;
    }
}

fn lowerDataStmt(ctx: *context.Context, data: ast.DataStmt) !ast.DataStmt {
    if (data.groups.len == 0) return data;

    var inits = std.array_list.Managed(ast.DataInit).init(ctx.arena);

    for (data.groups) |group| {
        const targets = try expandDataTargets(ctx, group.targets);
        const value_spans = try buildDataValueSpans(ctx, group.values);
        var cursor = DataValueCursor.init(value_spans);

        var target_idx: usize = 0;
        while (target_idx < targets.len) : (target_idx += 1) {
            const target = targets[target_idx];
            const remaining_targets = targets.len - target_idx;
            const remaining_values = cursor.remainingCount();
            if (remaining_values == 0) return error.DataValueCountMismatch;

            if (target.* == .identifier) {
                const symbol_idx = resolve_symbols.findSymbolIndex(ctx, target.identifier);
                const symbol_is_character = if (symbol_idx) |idx| ctx.symbols.items[idx].isCharacter() else false;
                if (try arrayShapeForName(ctx, target.identifier)) |shape| {
                    const reserved_for_rest = remaining_targets - 1;
                    if (remaining_values <= reserved_for_rest) return error.DataValueCountMismatch;

                    const take = if (shape.size) |known_size| known_size else remaining_values - reserved_for_rest;
                    if (take == 0 or take > remaining_values) return error.DataValueCountMismatch;

                    // Keep whole-array DATA initializers compact when values are uniform.
                    if (shape.size != null and take >= min_compact_array_fill and !symbol_is_character) {
                        if (cursor.consumeUniform(take)) |uniform_value| {
                            try ensureAppendBudget(inits.items.len, 1);
                            try inits.append(.{
                                .target = target,
                                .value = uniform_value,
                                .repeat_count = take,
                            });
                            continue;
                        }
                    }

                    var local_idx: usize = 0;
                    while (local_idx < take) : (local_idx += 1) {
                        const elem_target = try buildArrayDataTarget(ctx, target.identifier, shape, local_idx);
                        const value_expr = try cursor.pop();
                        try ensureAppendBudget(inits.items.len, 1);
                        try inits.append(.{ .target = elem_target, .value = value_expr });
                    }
                    continue;
                }
            }

            const value_expr = try cursor.pop();
            try ensureAppendBudget(inits.items.len, 1);
            try inits.append(.{ .target = target, .value = value_expr });
        }

        if (cursor.remainingCount() != 0) return error.DataValueCountMismatch;
    }

    return .{ .inits = try inits.toOwnedSlice(), .groups = &.{} };
}

fn expandDataTargets(ctx: *context.Context, targets: []*ast.Expr) ![]*ast.Expr {
    var out = std.array_list.Managed(*ast.Expr).init(ctx.arena);
    for (targets) |target| {
        try expandTargetExpr(ctx, target, &out);
    }
    return out.toOwnedSlice();
}

fn expandTargetExpr(
    ctx: *context.Context,
    node: *ast.Expr,
    out: *std.array_list.Managed(*ast.Expr),
) !void {
    switch (node.*) {
        .implied_do => |implied| {
            const start_val = (try evalConstInt(ctx, implied.start)) orelse return error.UnsupportedImpliedDo;
            const end_val = (try evalConstInt(ctx, implied.end)) orelse return error.UnsupportedImpliedDo;
            const step_val = if (implied.step) |step|
                (try evalConstInt(ctx, step)) orelse return error.UnsupportedImpliedDo
            else
                1;
            if (step_val == 0) return error.UnsupportedImpliedDo;

            var iter = start_val;
            var invalid_scalar_substring: ?*ast.Expr = null;
            var had_diagnostic = false;
            if (step_val > 0) {
                while (iter <= end_val) : (iter += step_val) {
                    const iter_expr = try makeIntegerLiteral(ctx, iter);
                    for (implied.items) |item| {
                        if (invalid_scalar_substring == null) {
                            invalid_scalar_substring = scalarSubstringUsesImpliedDoVar(ctx, item, implied.var_name);
                        }
                        const expanded = if (exprContainsIdentifier(item, implied.var_name))
                            try cloneExprWithSubstCheap(ctx, item, implied.var_name, iter_expr)
                        else
                            item;
                        if (try validateDataSubstringBounds(ctx, expanded)) {
                            had_diagnostic = true;
                            if (!ctx.usesExplicitDiagnosticBag()) return error.InvalidDataStatement;
                            continue;
                        }
                        try expandTargetExpr(ctx, expanded, out);
                    }
                }
            } else {
                while (iter >= end_val) : (iter += step_val) {
                    const iter_expr = try makeIntegerLiteral(ctx, iter);
                    for (implied.items) |item| {
                        if (invalid_scalar_substring == null) {
                            invalid_scalar_substring = scalarSubstringUsesImpliedDoVar(ctx, item, implied.var_name);
                        }
                        const expanded = if (exprContainsIdentifier(item, implied.var_name))
                            try cloneExprWithSubstCheap(ctx, item, implied.var_name, iter_expr)
                        else
                            item;
                        if (try validateDataSubstringBounds(ctx, expanded)) {
                            had_diagnostic = true;
                            if (!ctx.usesExplicitDiagnosticBag()) return error.InvalidDataStatement;
                            continue;
                        }
                        try expandTargetExpr(ctx, expanded, out);
                    }
                }
            }
            if (had_diagnostic) return error.InvalidDataStatement;
            if (invalid_scalar_substring) |expr| {
                emitDataDiagnostic(ctx, expr, "Invalid substring in data-implied-do");
                return error.InvalidDataStatement;
            }
        },
        else => {
            if (try validateDataSubstringBounds(ctx, node)) return error.InvalidDataStatement;
            try ensureAppendBudget(out.items.len, 1);
            try out.append(node);
        },
    }
}

fn scalarSubstringUsesImpliedDoVar(ctx: *context.Context, node: *ast.Expr, var_name: []const u8) ?*ast.Expr {
    return switch (node.*) {
        .substring => |sub| blk: {
            const idx = resolve_symbols.findSymbolIndex(ctx, sub.name) orelse break :blk null;
            if (ctx.symbols.items[idx].dims.len != 0) break :blk null;
            if (sub.start) |start| {
                if (exprContainsIdentifier(start, var_name)) break :blk node;
            }
            if (sub.end) |end| {
                if (exprContainsIdentifier(end, var_name)) break :blk node;
            }
            break :blk null;
        },
        .component => |comp| scalarSubstringUsesImpliedDoVar(ctx, comp.base, var_name),
        .implied_do => null,
        else => null,
    };
}

fn validateDataSubstringBounds(ctx: *context.Context, node: *ast.Expr) !bool {
    switch (node.*) {
        .substring => |sub| {
            const idx = resolve_symbols.findSymbolIndex(ctx, sub.name) orelse return false;
            const sym = ctx.symbols.items[idx];
            if (!sym.isCharacter()) return false;
            const char_len = sym.effectiveCharLen() orelse return false;
            if (sub.start) |start_expr| {
                const start = (try evalConstInt(ctx, start_expr)) orelse return false;
                if (start < 1) {
                    emitDataDiagnostic(ctx, start_expr, "Substring start index at (1) is less than one");
                    return true;
                }
            }
            if (sub.end) |end_expr| {
                const end = (try evalConstInt(ctx, end_expr)) orelse return false;
                if (end > @as(i64, @intCast(char_len))) {
                    emitDataDiagnostic(ctx, end_expr, "Substring end index at (1) exceeds the string length");
                    return true;
                }
            }
            return false;
        },
        .component => |comp| return validateDataSubstringBounds(ctx, comp.base),
        else => return false,
    }
}

fn buildDataValueSpans(ctx: *context.Context, specs: []ast.DataValueSpec) ![]DataValueSpan {
    var out = std.array_list.Managed(DataValueSpan).init(ctx.arena);
    var total: usize = 0;
    for (specs) |spec| {
        const repeat: usize = if (spec.repeat) |repeat_expr| blk: {
            const repeat_i = (try evalConstInt(ctx, repeat_expr)) orelse return error.UnsupportedImpliedDo;
            if (repeat_i < 0) return error.UnsupportedImpliedDo;
            break :blk std.math.cast(usize, repeat_i) orelse return error.DataExpansionTooLarge;
        } else 1;
        if (repeat == 0) continue;
        total = std.math.add(usize, total, repeat) catch return error.DataExpansionTooLarge;

        if (out.items.len > 0 and out.items[out.items.len - 1].value == spec.value) {
            const next = std.math.add(usize, out.items[out.items.len - 1].count, repeat) catch return error.DataExpansionTooLarge;
            out.items[out.items.len - 1].count = next;
        } else {
            try out.append(.{ .value = spec.value, .count = repeat });
        }
    }
    return out.toOwnedSlice();
}

fn arrayShapeForName(ctx: *context.Context, name: []const u8) !?ArrayShape {
    const idx = resolve_symbols.findSymbolIndex(ctx, name) orelse return null;
    const sym = ctx.symbols.items[idx];
    if (sym.dims.len == 0) return null;
    return try buildArrayShape(ctx, sym.dims);
}

fn buildArrayShape(ctx: *context.Context, dims: []*ast.Expr) !ArrayShape {
    const rank = dims.len;
    const lowers = try ctx.arena.alloc(i64, rank);
    const extents_all = try ctx.arena.alloc(usize, rank);

    var all_known = true;
    var total: usize = 1;

    for (dims, 0..) |dim_expr, idx| {
        if (try evalDimLowerExtent(ctx, dim_expr)) |info| {
            lowers[idx] = info.lower;
            extents_all[idx] = info.extent;
            const prod = @mulWithOverflow(total, info.extent);
            if (prod[1] == 0) {
                total = prod[0];
            } else {
                all_known = false;
            }
        } else {
            all_known = false;
            lowers[idx] = (try evalDimLowerBound(ctx, dim_expr)) orelse 1;
            extents_all[idx] = 0;
        }
    }

    return .{
        .rank = rank,
        .size = if (all_known) total else null,
        .lowers = lowers,
        .extents = if (all_known) extents_all else null,
    };
}

const DimLowerExtent = struct {
    lower: i64,
    extent: usize,
};

fn evalDimLowerExtent(ctx: *context.Context, dim_expr: *ast.Expr) !?DimLowerExtent {
    switch (dim_expr.*) {
        .dim_range => |range| {
            if (range.stride != null) return null;
            const upper = (try evalConstInt(ctx, range.upper)) orelse return null;
            const lower = if (range.lower) |lower_expr|
                (try evalConstInt(ctx, lower_expr)) orelse return null
            else
                1;
            const extent_i = upper - lower + 1;
            if (extent_i <= 0) return error.DataValueCountMismatch;
            return .{ .lower = lower, .extent = @intCast(extent_i) };
        },
        else => {
            const extent_i = (try evalConstInt(ctx, dim_expr)) orelse return null;
            if (extent_i <= 0) return error.DataValueCountMismatch;
            return .{ .lower = 1, .extent = @intCast(extent_i) };
        },
    }
}

fn evalDimLowerBound(ctx: *context.Context, dim_expr: *ast.Expr) !?i64 {
    switch (dim_expr.*) {
        .dim_range => |range| {
            if (range.lower) |lower_expr| {
                return try evalConstInt(ctx, lower_expr);
            }
            return 1;
        },
        else => return 1,
    }
}

fn buildArrayDataTarget(
    ctx: *context.Context,
    name: []const u8,
    shape: ArrayShape,
    linear_idx: usize,
) !*ast.Expr {
    const args = try ctx.arena.alloc(*ast.Expr, shape.rank);

    if (shape.extents) |extents| {
        var rem = linear_idx;
        var dim: usize = 0;
        while (dim < shape.rank) : (dim += 1) {
            const extent = extents[dim];
            if (extent == 0) return error.DataValueCountMismatch;
            const offset = rem % extent;
            rem /= extent;
            const subscript = shape.lowers[dim] + @as(i64, @intCast(offset));
            args[dim] = try makeIntegerLiteral(ctx, subscript);
        }
        if (rem != 0) return error.DataValueCountMismatch;
    } else {
        var dim: usize = 0;
        while (dim < shape.rank) : (dim += 1) {
            const subscript: i64 = if (dim == 0)
                shape.lowers[0] + @as(i64, @intCast(linear_idx))
            else
                shape.lowers[dim];
            args[dim] = try makeIntegerLiteral(ctx, subscript);
        }
    }

    const target = try ctx.arena.create(ast.Expr);
    target.* = .{ .call_or_subscript = .{ .name = name, .args = args } };
    return target;
}

fn evalConstInt(ctx: *context.Context, expr_node: *ast.Expr) !?i64 {
    const value = try resolve_const.evalConst(ctx, expr_node);
    return switch (value orelse return null) {
        .integer => |v| v,
        else => null,
    };
}

fn makeIntegerLiteral(ctx: *context.Context, value: i64) !*ast.Expr {
    const text = try std.fmt.allocPrint(ctx.arena, "{d}", .{value});
    const node = try ctx.arena.create(ast.Expr);
    node.* = .{ .literal = .{ .kind = .integer, .text = text } };
    return node;
}

fn cloneExprWithSubst(
    ctx: *context.Context,
    node: *ast.Expr,
    name: []const u8,
    replacement: *ast.Expr,
) !*ast.Expr {
    if (!exprContainsIdentifier(node, name)) return node;
    switch (node.*) {
        .identifier => |ident| {
            if (std.ascii.eqlIgnoreCase(ident, name)) {
                return replacement;
            }
            return node;
        },
        .array_constructor => |ctor| {
            const items = try ctx.arena.alloc(*ast.Expr, ctor.items.len);
            for (ctor.items, 0..) |item, idx| {
                items[idx] = try cloneExprWithSubst(ctx, item, name, replacement);
            }
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .array_constructor = .{ .type_spec = ctor.type_spec, .items = items } };
            return cloned;
        },
        .literal => |lit| {
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .literal = lit };
            return cloned;
        },
        .unary => |un| {
            const expr_node = try cloneExprWithSubst(ctx, un.expr, name, replacement);
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .unary = .{ .op = un.op, .expr = expr_node } };
            return cloned;
        },
        .binary => |bin| {
            const left = try cloneExprWithSubst(ctx, bin.left, name, replacement);
            const right = try cloneExprWithSubst(ctx, bin.right, name, replacement);
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .binary = .{ .op = bin.op, .left = left, .right = right } };
            return cloned;
        },
        .complex_literal => |lit| {
            const real = try cloneExprWithSubst(ctx, lit.real, name, replacement);
            const imag = try cloneExprWithSubst(ctx, lit.imag, name, replacement);
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .complex_literal = .{ .real = real, .imag = imag } };
            return cloned;
        },
        .call_or_subscript => |call| {
            const args = try ctx.arena.alloc(*ast.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, arg, name, replacement);
            }
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .call_or_subscript = .{ .name = call.name, .args = args } };
            return cloned;
        },
        .substring => |sub| {
            const args = try ctx.arena.alloc(*ast.Expr, sub.args.len);
            for (sub.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, arg, name, replacement);
            }
            const start_expr = if (sub.start) |s| try cloneExprWithSubst(ctx, s, name, replacement) else null;
            const end_expr = if (sub.end) |e| try cloneExprWithSubst(ctx, e, name, replacement) else null;
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .substring = .{ .name = sub.name, .args = args, .start = start_expr, .end = end_expr } };
            return cloned;
        },
        .component => |comp| {
            const base = try cloneExprWithSubst(ctx, comp.base, name, replacement);
            const args = try ctx.arena.alloc(*ast.Expr, comp.args.len);
            for (comp.args, 0..) |arg, idx| {
                args[idx] = try cloneExprWithSubst(ctx, arg, name, replacement);
            }
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .component = .{ .base = base, .name = comp.name, .args = args, .has_parens = comp.has_parens } };
            return cloned;
        },
        .dim_range => |range| {
            const lower = if (range.lower) |l| try cloneExprWithSubst(ctx, l, name, replacement) else null;
            const upper = try cloneExprWithSubst(ctx, range.upper, name, replacement);
            const stride = if (range.stride) |s| try cloneExprWithSubst(ctx, s, name, replacement) else null;
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .dim_range = .{ .lower = lower, .upper = upper, .stride = stride, .assumed_shape = range.assumed_shape } };
            return cloned;
        },
        .implied_do => |implied| {
            const items = try ctx.arena.alloc(*ast.Expr, implied.items.len);
            for (implied.items, 0..) |item, idx| {
                items[idx] = try cloneExprWithSubst(ctx, item, name, replacement);
            }
            const start = try cloneExprWithSubst(ctx, implied.start, name, replacement);
            const end = try cloneExprWithSubst(ctx, implied.end, name, replacement);
            const step = if (implied.step) |s| try cloneExprWithSubst(ctx, s, name, replacement) else null;
            const cloned = try ctx.arena.create(ast.Expr);
            cloned.* = .{ .implied_do = .{
                .items = items,
                .var_name = implied.var_name,
                .start = start,
                .end = end,
                .step = step,
            } };
            return cloned;
        },
    }
}

fn cloneExprWithSubstCheap(
    ctx: *context.Context,
    node: *ast.Expr,
    name: []const u8,
    replacement: *ast.Expr,
) !*ast.Expr {
    if (try cloneSimpleCallSubscriptWithSubst(ctx, node, name, replacement)) |fast| {
        return fast;
    }
    return cloneExprWithSubst(ctx, node, name, replacement);
}

fn cloneSimpleCallSubscriptWithSubst(
    ctx: *context.Context,
    node: *ast.Expr,
    name: []const u8,
    replacement: *ast.Expr,
) !?*ast.Expr {
    if (node.* != .call_or_subscript) return null;
    const call = node.call_or_subscript;
    if (call.args.len == 0) return node;

    const args = try ctx.arena.alloc(*ast.Expr, call.args.len);
    var changed = false;
    for (call.args, 0..) |arg, idx| {
        switch (arg.*) {
            .identifier => |ident| {
                if (std.ascii.eqlIgnoreCase(ident, name)) {
                    args[idx] = replacement;
                    changed = true;
                } else {
                    args[idx] = arg;
                }
            },
            else => {
                if (exprContainsIdentifier(arg, name)) return null;
                args[idx] = arg;
            },
        }
    }
    if (!changed) return node;

    const cloned = try ctx.arena.create(ast.Expr);
    cloned.* = .{ .call_or_subscript = .{ .name = call.name, .args = args } };
    return cloned;
}

fn exprContainsIdentifier(node: *ast.Expr, name: []const u8) bool {
    return switch (node.*) {
        .identifier => |ident| std.ascii.eqlIgnoreCase(ident, name),
        .array_constructor => |ctor| blk: {
            for (ctor.items) |item| {
                if (exprContainsIdentifier(item, name)) break :blk true;
            }
            break :blk false;
        },
        .literal => false,
        .unary => |un| exprContainsIdentifier(un.expr, name),
        .binary => |bin| exprContainsIdentifier(bin.left, name) or exprContainsIdentifier(bin.right, name),
        .complex_literal => |lit| exprContainsIdentifier(lit.real, name) or exprContainsIdentifier(lit.imag, name),
        .call_or_subscript => |call| blk: {
            for (call.args) |arg| {
                if (exprContainsIdentifier(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .component => |comp| blk: {
            if (exprContainsIdentifier(comp.base, name)) break :blk true;
            for (comp.args) |arg| {
                if (exprContainsIdentifier(arg, name)) break :blk true;
            }
            break :blk false;
        },
        .substring => |sub| blk: {
            for (sub.args) |arg| {
                if (exprContainsIdentifier(arg, name)) break :blk true;
            }
            if (sub.start) |start_expr| {
                if (exprContainsIdentifier(start_expr, name)) break :blk true;
            }
            if (sub.end) |end_expr| {
                if (exprContainsIdentifier(end_expr, name)) break :blk true;
            }
            break :blk false;
        },
        .dim_range => |range| blk: {
            if (range.lower) |lower| {
                if (exprContainsIdentifier(lower, name)) break :blk true;
            }
            if (exprContainsIdentifier(range.upper, name)) break :blk true;
            if (range.stride) |stride| {
                if (exprContainsIdentifier(stride, name)) break :blk true;
            }
            break :blk false;
        },
        .implied_do => |implied| blk: {
            for (implied.items) |item| {
                if (exprContainsIdentifier(item, name)) break :blk true;
            }
            if (exprContainsIdentifier(implied.start, name)) break :blk true;
            if (exprContainsIdentifier(implied.end, name)) break :blk true;
            if (implied.step) |step_expr| {
                if (exprContainsIdentifier(step_expr, name)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn ensureAppendBudget(current_len: usize, add_len: usize) !void {
    _ = std.math.add(usize, current_len, add_len) catch return error.DataExpansionTooLarge;
}

fn emitDataDiagnostic(ctx: *context.Context, expr: *ast.Expr, message: []const u8) void {
    const source = ctx.sourceForExpr(expr) orelse blk: {
        if (ctx.current_stmt) |stmt| {
            break :blk ast.SourceRef{ .line = stmt.source_line, .column = stmt.source_column, .text = stmt.source_text };
        }
        break :blk ast.SourceRef{};
    };
    ctx.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_data_stmt_reference.code,
        message,
        source.text,
    );
}
