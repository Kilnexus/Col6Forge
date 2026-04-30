const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../context.zig");
const AssociateAlias = struct {
    name: []const u8,
    selector: *ast.Expr,
};

pub fn lowerAssociateBlocks(ctx: *context.Context) !void {
    const lowered = try lowerAssociateStmtList(ctx, ctx.unit.stmts, &.{});
    if (lowered.changed) {
        ctx.replaceUnitStmts(lowered.stmts);
    }
}

const RewriteResult = struct {
    stmts: []ast.Stmt,
    changed: bool,
};

fn lowerAssociateStmtList(
    ctx: *context.Context,
    stmts: []ast.Stmt,
    aliases: []const AssociateAlias,
) anyerror!RewriteResult {
    var out = std.array_list.Managed(ast.Stmt).init(ctx.arena);
    errdefer out.deinit();

    var changed = false;
    for (stmts) |stmt| {
        switch (stmt.node) {
            .associate_block => |assoc| {
                var nested_aliases = std.array_list.Managed(AssociateAlias).init(ctx.arena);
                defer nested_aliases.deinit();
                try nested_aliases.appendSlice(aliases);
                for (assoc.bindings) |binding| {
                    try nested_aliases.append(.{
                        .name = binding.name,
                        .selector = binding.selector,
                    });
                }
                const lowered_body = try lowerAssociateStmtList(ctx, assoc.stmts, nested_aliases.items);
                try out.appendSlice(lowered_body.stmts);
                changed = true;
                if (lowered_body.changed) changed = true;
            },
            .select_type_block => |select_type| {
                for (select_type.clauses) |clause| {
                    const lowered_body = try lowerAssociateStmtList(ctx, clause.stmts, aliases);
                    try out.appendSlice(lowered_body.stmts);
                    changed = true;
                    if (lowered_body.changed) changed = true;
                }
            },
            .orphan_select_type_clause => {
                try out.append(stmt);
            },
            else => {
                var stmt_copy = stmt;
                const stmt_changed = try substituteStmtAliases(ctx, &stmt_copy, aliases);
                try out.append(stmt_copy);
                if (stmt_changed) changed = true;
            },
        }
    }
    return .{
        .stmts = try out.toOwnedSlice(),
        .changed = changed,
    };
}

fn substituteStmtAliases(
    ctx: *context.Context,
    stmt: *ast.Stmt,
    aliases: []const AssociateAlias,
) anyerror!bool {
    if (aliases.len == 0) {
        switch (stmt.node) {
            .if_block => |*ifb| {
                const then_result = try lowerAssociateStmtList(ctx, ifb.then_stmts, aliases);
                const else_result = try lowerAssociateStmtList(ctx, ifb.else_stmts, aliases);
                if (then_result.changed or else_result.changed) {
                    ifb.then_stmts = then_result.stmts;
                    ifb.else_stmts = else_result.stmts;
                    return true;
                }
                return false;
            },
            .associate_block => unreachable,
            .select_type_block => unreachable,
            .orphan_select_type_clause => return false,
            else => return false,
        }
    }

    var changed = false;
    switch (stmt.node) {
        .assignment => |*assign| {
            const new_target = try substituteExprAliases(ctx, assign.target, aliases);
            const new_value = try substituteExprAliases(ctx, assign.value, aliases);
            assign.target = new_target.expr;
            assign.value = new_value.expr;
            changed = new_target.changed or new_value.changed;
        },
        .pointer_assignment => |*assign| {
            const new_target = try substituteExprAliases(ctx, assign.target, aliases);
            const new_value = try substituteExprAliases(ctx, assign.value, aliases);
            assign.target = new_target.expr;
            assign.value = new_value.expr;
            changed = new_target.changed or new_value.changed;
        },
        .nullify => |*nullify| {
            for (nullify.items, 0..) |item, idx| {
                const result = try substituteExprAliases(ctx, item, aliases);
                nullify.items[idx] = result.expr;
                changed = changed or result.changed;
            }
        },
        .call => |*call| {
            if (call.binding_base) |base| {
                const result = try substituteExprAliases(ctx, base, aliases);
                call.binding_base = result.expr;
                changed = changed or result.changed;
            }
            for (call.args) |*arg| {
                switch (arg.*) {
                    .expr => |*actual| {
                        const result = try substituteExprAliases(ctx, actual.value, aliases);
                        actual.value = result.expr;
                        changed = changed or result.changed;
                    },
                    .alt_return => {},
                }
            }
        },
        .write => |*write| {
            const unit_result = try substituteExprAliases(ctx, write.unit, aliases);
            write.unit = unit_result.expr;
            changed = changed or unit_result.changed;
            if (write.rec) |rec| {
                const result = try substituteExprAliases(ctx, rec, aliases);
                write.rec = result.expr;
                changed = changed or result.changed;
            }
            for (write.args, 0..) |arg, idx| {
                const result = try substituteExprAliases(ctx, arg, aliases);
                write.args[idx] = result.expr;
                changed = changed or result.changed;
            }
            if (write.iostat) |io| {
                const result = try substituteExprAliases(ctx, io, aliases);
                write.iostat = result.expr;
                changed = changed or result.changed;
            }
            for (write.controls) |*ctrl| {
                const result = try substituteExprAliases(ctx, ctrl.value, aliases);
                ctrl.value = result.expr;
                changed = changed or result.changed;
            }
        },
        .read => |*read| {
            const unit_result = try substituteExprAliases(ctx, read.unit, aliases);
            read.unit = unit_result.expr;
            changed = changed or unit_result.changed;
            if (read.rec) |rec| {
                const result = try substituteExprAliases(ctx, rec, aliases);
                read.rec = result.expr;
                changed = changed or result.changed;
            }
            for (read.args, 0..) |arg, idx| {
                const result = try substituteExprAliases(ctx, arg, aliases);
                read.args[idx] = result.expr;
                changed = changed or result.changed;
            }
            if (read.iostat) |io| {
                const result = try substituteExprAliases(ctx, io, aliases);
                read.iostat = result.expr;
                changed = changed or result.changed;
            }
            for (read.controls) |*ctrl| {
                const result = try substituteExprAliases(ctx, ctrl.value, aliases);
                ctrl.value = result.expr;
                changed = changed or result.changed;
            }
        },
        .rewind => |*rewind| {
            const result = try substituteExprAliases(ctx, rewind.unit, aliases);
            rewind.unit = result.expr;
            changed = result.changed;
        },
        .backspace => |*backspace| {
            const result = try substituteExprAliases(ctx, backspace.unit, aliases);
            backspace.unit = result.expr;
            changed = result.changed;
        },
        .endfile => |*endfile| {
            const result = try substituteExprAliases(ctx, endfile.unit, aliases);
            endfile.unit = result.expr;
            changed = result.changed;
        },
        .open => |*open_stmt| {
            const unit_result = try substituteExprAliases(ctx, open_stmt.unit, aliases);
            open_stmt.unit = unit_result.expr;
            changed = changed or unit_result.changed;
            if (open_stmt.recl) |recl| {
                const result = try substituteExprAliases(ctx, recl, aliases);
                open_stmt.recl = result.expr;
                changed = changed or result.changed;
            }
            if (open_stmt.file) |file_expr| {
                const result = try substituteExprAliases(ctx, file_expr, aliases);
                open_stmt.file = result.expr;
                changed = changed or result.changed;
            }
            if (open_stmt.access) |access| {
                const result = try substituteExprAliases(ctx, access, aliases);
                open_stmt.access = result.expr;
                changed = changed or result.changed;
            }
            if (open_stmt.form) |form| {
                const result = try substituteExprAliases(ctx, form, aliases);
                open_stmt.form = result.expr;
                changed = changed or result.changed;
            }
            if (open_stmt.blank) |blank| {
                const result = try substituteExprAliases(ctx, blank, aliases);
                open_stmt.blank = result.expr;
                changed = changed or result.changed;
            }
            if (open_stmt.status) |status| {
                const result = try substituteExprAliases(ctx, status, aliases);
                open_stmt.status = result.expr;
                changed = changed or result.changed;
            }
            for (open_stmt.controls) |*ctrl| {
                const result = try substituteExprAliases(ctx, ctrl.value, aliases);
                ctrl.value = result.expr;
                changed = changed or result.changed;
            }
        },
        .inquire => |*inq| {
            for (inq.controls) |*ctrl| {
                const result = try substituteExprAliases(ctx, ctrl.value, aliases);
                ctrl.value = result.expr;
                changed = changed or result.changed;
            }
        },
        .close => |*cls| {
            for (cls.controls) |*ctrl| {
                const result = try substituteExprAliases(ctx, ctrl.value, aliases);
                ctrl.value = result.expr;
                changed = changed or result.changed;
            }
        },
        .allocate => |*allocate| {
            if (allocate.type_spec) |*type_spec| {
                if (type_spec.kind_selector) |kind_selector| {
                    const result = try substituteExprAliases(ctx, kind_selector, aliases);
                    type_spec.kind_selector = result.expr;
                    changed = changed or result.changed;
                }
                if (type_spec.char_len) |char_len| {
                    const result = try substituteExprAliases(ctx, char_len, aliases);
                    type_spec.char_len = result.expr;
                    changed = changed or result.changed;
                }
            }
            for (allocate.items) |*item| {
                const target_result = try substituteExprAliases(ctx, item.target, aliases);
                item.target = target_result.expr;
                changed = changed or target_result.changed;
                for (item.dims, 0..) |dim, idx| {
                    const result = try substituteExprAliases(ctx, dim, aliases);
                    item.dims[idx] = result.expr;
                    changed = changed or result.changed;
                }
            }
            for (allocate.options) |*option| {
                const result = try substituteExprAliases(ctx, option.value, aliases);
                option.value = result.expr;
                changed = changed or result.changed;
            }
        },
        .deallocate => |*deallocate| {
            for (deallocate.items) |*item| {
                const result = try substituteExprAliases(ctx, item.target, aliases);
                item.target = result.expr;
                changed = changed or result.changed;
            }
            for (deallocate.options) |*option| {
                const result = try substituteExprAliases(ctx, option.value, aliases);
                option.value = result.expr;
                changed = changed or result.changed;
            }
        },
        .data => |*data| {
            for (data.inits) |*init| {
                const target_result = try substituteExprAliases(ctx, init.target, aliases);
                const value_result = try substituteExprAliases(ctx, init.value, aliases);
                init.target = target_result.expr;
                init.value = value_result.expr;
                changed = changed or target_result.changed or value_result.changed;
            }
            for (data.groups) |*group| {
                for (group.targets, 0..) |target, idx| {
                    const result = try substituteExprAliases(ctx, target, aliases);
                    group.targets[idx] = result.expr;
                    changed = changed or result.changed;
                }
                for (group.values) |*value_spec| {
                    const value_result = try substituteExprAliases(ctx, value_spec.value, aliases);
                    value_spec.value = value_result.expr;
                    changed = changed or value_result.changed;
                    if (value_spec.repeat) |repeat| {
                        const repeat_result = try substituteExprAliases(ctx, repeat, aliases);
                        value_spec.repeat = repeat_result.expr;
                        changed = changed or repeat_result.changed;
                    }
                }
            }
        },
        .arith_if => |*arith| {
            const result = try substituteExprAliases(ctx, arith.condition, aliases);
            arith.condition = result.expr;
            changed = result.changed;
        },
        .do_loop => |*loop| {
            const start_result = try substituteExprAliases(ctx, loop.start, aliases);
            const end_result = try substituteExprAliases(ctx, loop.end, aliases);
            loop.start = start_result.expr;
            loop.end = end_result.expr;
            changed = start_result.changed or end_result.changed;
            if (loop.step) |step| {
                const step_result = try substituteExprAliases(ctx, step, aliases);
                loop.step = step_result.expr;
                changed = changed or step_result.changed;
            }
        },
        .do_while => |*loop| {
            const result = try substituteExprAliases(ctx, loop.condition, aliases);
            loop.condition = result.expr;
            changed = result.changed;
        },
        .computed_goto => |*gt| {
            const result = try substituteExprAliases(ctx, gt.selector, aliases);
            gt.selector = result.expr;
            changed = result.changed;
        },
        .if_single => |*ifs| {
            const cond_result = try substituteExprAliases(ctx, ifs.condition, aliases);
            ifs.condition = cond_result.expr;
            changed = cond_result.changed;
            var inner_stmt = ast.Stmt{
                .label = null,
                .node = ifs.stmt.*,
                .source_line = stmt.source_line,
                .source_column = stmt.source_column,
                .source_text = stmt.source_text,
            };
            const inner_changed = try substituteStmtAliases(ctx, &inner_stmt, aliases);
            if (inner_changed) {
                const node_ptr = try ctx.arena.create(ast.StmtNode);
                node_ptr.* = inner_stmt.node;
                ifs.stmt = node_ptr;
                changed = true;
            }
        },
        .if_block => |*ifb| {
            const cond_result = try substituteExprAliases(ctx, ifb.condition, aliases);
            ifb.condition = cond_result.expr;
            changed = cond_result.changed;
            const then_result = try lowerAssociateStmtList(ctx, ifb.then_stmts, aliases);
            const else_result = try lowerAssociateStmtList(ctx, ifb.else_stmts, aliases);
            if (then_result.changed or else_result.changed) {
                ifb.then_stmts = then_result.stmts;
                ifb.else_stmts = else_result.stmts;
                changed = true;
            }
        },
        .where_stmt => |*where| {
            const mask_result = try substituteExprAliases(ctx, where.mask, aliases);
            const target_result = try substituteExprAliases(ctx, where.target, aliases);
            const value_result = try substituteExprAliases(ctx, where.value, aliases);
            where.mask = mask_result.expr;
            where.target = target_result.expr;
            where.value = value_result.expr;
            changed = mask_result.changed or target_result.changed or value_result.changed;
        },
        .ret => |*ret| {
            if (ret.value) |value| {
                const result = try substituteExprAliases(ctx, value, aliases);
                ret.value = result.expr;
                changed = result.changed;
            }
        },
        .associate_block => unreachable,
        .select_type_block => unreachable,
        .orphan_select_type_clause,
        .assign_label,
        .use_stmt,
        .format,
        .pause,
        .stop,
        .do_infinite,
        .goto,
        .assigned_goto,
        .cont,
        .entry,
        => {},
    }
    return changed;
}

const ExprRewrite = struct {
    expr: *ast.Expr,
    changed: bool,
};

fn substituteExprAliases(
    ctx: *context.Context,
    expr_node: *ast.Expr,
    aliases: []const AssociateAlias,
) anyerror!ExprRewrite {
    const alias = findAssociateAlias(aliases, expr_node);
    if (alias) |matched| {
        return .{
            .expr = try cloneAssociateExpr(ctx, matched.selector),
            .changed = true,
        };
    }

    switch (expr_node.*) {
        .identifier, .literal => return .{ .expr = expr_node, .changed = false },
        .call_or_subscript => |call| {
            const alias_by_name = findAssociateAliasByName(aliases, call.name);
            if (alias_by_name) |matched| {
                const lowered = try lowerAssociateSubscript(ctx, matched.selector, call.args, aliases);
                return .{
                    .expr = lowered,
                    .changed = true,
                };
            }
            var changed = false;
            const args = try ctx.arena.alloc(*ast.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| {
                const result = try substituteExprAliases(ctx, arg, aliases);
                args[idx] = result.expr;
                changed = changed or result.changed;
            }
            if (!changed) return .{ .expr = expr_node, .changed = false };
            return .{
                .expr = try newExpr(ctx, .{ .call_or_subscript = .{
                    .name = call.name,
                    .args = args,
                } }),
                .changed = true,
            };
        },
        .array_constructor => |ctor| {
            var changed = false;
            const items = try ctx.arena.alloc(*ast.Expr, ctor.items.len);
            for (ctor.items, 0..) |item, idx| {
                const result = try substituteExprAliases(ctx, item, aliases);
                items[idx] = result.expr;
                changed = changed or result.changed;
            }
            if (!changed) return .{ .expr = expr_node, .changed = false };

            var type_spec = ctor.type_spec;
            if (ctor.type_spec) |existing| {
                type_spec = existing;
                if (existing.kind_selector) |kind_selector| {
                    const result = try substituteExprAliases(ctx, kind_selector, aliases);
                    type_spec.?.kind_selector = result.expr;
                    changed = changed or result.changed;
                }
            }
            return .{
                .expr = try newExpr(ctx, .{ .array_constructor = .{
                    .type_spec = type_spec,
                    .items = items,
                } }),
                .changed = true,
            };
        },
        .substring => |sub| {
            var changed = false;
            const args = try ctx.arena.alloc(*ast.Expr, sub.args.len);
            for (sub.args, 0..) |arg, idx| {
                const result = try substituteExprAliases(ctx, arg, aliases);
                args[idx] = result.expr;
                changed = changed or result.changed;
            }
            var start = sub.start;
            if (sub.start) |start_expr| {
                const result = try substituteExprAliases(ctx, start_expr, aliases);
                start = result.expr;
                changed = changed or result.changed;
            }
            var end_expr = sub.end;
            if (sub.end) |end_value| {
                const result = try substituteExprAliases(ctx, end_value, aliases);
                end_expr = result.expr;
                changed = changed or result.changed;
            }
            if (!changed) return .{ .expr = expr_node, .changed = false };
            return .{
                .expr = try newExpr(ctx, .{ .substring = .{
                    .name = sub.name,
                    .args = args,
                    .start = start,
                    .end = end_expr,
                } }),
                .changed = true,
            };
        },
        .component => |comp| {
            const base_result = try substituteExprAliases(ctx, comp.base, aliases);
            var changed = base_result.changed;
            const args = try ctx.arena.alloc(*ast.Expr, comp.args.len);
            for (comp.args, 0..) |arg, idx| {
                const result = try substituteExprAliases(ctx, arg, aliases);
                args[idx] = result.expr;
                changed = changed or result.changed;
            }
            if (!changed) return .{ .expr = expr_node, .changed = false };
            return .{
                .expr = try newExpr(ctx, .{ .component = .{
                    .base = base_result.expr,
                    .name = comp.name,
                    .args = args,
                    .has_parens = comp.has_parens,
                } }),
                .changed = true,
            };
        },
        .dim_range => |range| {
            var changed = false;
            var lower = range.lower;
            if (range.lower) |lower_expr| {
                const result = try substituteExprAliases(ctx, lower_expr, aliases);
                lower = result.expr;
                changed = changed or result.changed;
            }
            const upper_result = try substituteExprAliases(ctx, range.upper, aliases);
            var stride = range.stride;
            changed = changed or upper_result.changed;
            if (range.stride) |stride_expr| {
                const result = try substituteExprAliases(ctx, stride_expr, aliases);
                stride = result.expr;
                changed = changed or result.changed;
            }
            if (!changed) return .{ .expr = expr_node, .changed = false };
            return .{
                .expr = try newExpr(ctx, .{ .dim_range = .{
                    .lower = lower,
                    .upper = upper_result.expr,
                    .stride = stride,
                    .assumed_shape = range.assumed_shape,
                } }),
                .changed = true,
            };
        },
        .unary => |un| {
            const result = try substituteExprAliases(ctx, un.expr, aliases);
            if (!result.changed) return .{ .expr = expr_node, .changed = false };
            return .{
                .expr = try newExpr(ctx, .{ .unary = .{
                    .op = un.op,
                    .expr = result.expr,
                } }),
                .changed = true,
            };
        },
        .binary => |bin| {
            const left_result = try substituteExprAliases(ctx, bin.left, aliases);
            const right_result = try substituteExprAliases(ctx, bin.right, aliases);
            if (!left_result.changed and !right_result.changed) return .{ .expr = expr_node, .changed = false };
            return .{
                .expr = try newExpr(ctx, .{ .binary = .{
                    .op = bin.op,
                    .left = left_result.expr,
                    .right = right_result.expr,
                } }),
                .changed = true,
            };
        },
        .complex_literal => |complex| {
            const real_result = try substituteExprAliases(ctx, complex.real, aliases);
            const imag_result = try substituteExprAliases(ctx, complex.imag, aliases);
            if (!real_result.changed and !imag_result.changed) return .{ .expr = expr_node, .changed = false };
            return .{
                .expr = try newExpr(ctx, .{ .complex_literal = .{
                    .real = real_result.expr,
                    .imag = imag_result.expr,
                } }),
                .changed = true,
            };
        },
        .implied_do => |implied| {
            var changed = false;
            const items = try ctx.arena.alloc(*ast.Expr, implied.items.len);
            for (implied.items, 0..) |item, idx| {
                const result = try substituteExprAliases(ctx, item, aliases);
                items[idx] = result.expr;
                changed = changed or result.changed;
            }
            const start_result = try substituteExprAliases(ctx, implied.start, aliases);
            const end_result = try substituteExprAliases(ctx, implied.end, aliases);
            changed = changed or start_result.changed or end_result.changed;
            var step = implied.step;
            if (implied.step) |step_expr| {
                const result = try substituteExprAliases(ctx, step_expr, aliases);
                step = result.expr;
                changed = changed or result.changed;
            }
            if (!changed) return .{ .expr = expr_node, .changed = false };
            return .{
                .expr = try newExpr(ctx, .{ .implied_do = .{
                    .items = items,
                    .var_name = implied.var_name,
                    .start = start_result.expr,
                    .end = end_result.expr,
                    .step = step,
                } }),
                .changed = true,
            };
        },
    }
}

fn findAssociateAlias(aliases: []const AssociateAlias, expr_node: *ast.Expr) ?AssociateAlias {
    return switch (expr_node.*) {
        .identifier => |name| findAssociateAliasByName(aliases, name),
        else => null,
    };
}

fn findAssociateAliasByName(aliases: []const AssociateAlias, name: []const u8) ?AssociateAlias {
    var i = aliases.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(aliases[i].name, name)) return aliases[i];
    }
    return null;
}

fn lowerAssociateSubscript(
    ctx: *context.Context,
    selector: *ast.Expr,
    args: []*ast.Expr,
    aliases: []const AssociateAlias,
) anyerror!*ast.Expr {
    const lowered_args = try ctx.arena.alloc(*ast.Expr, args.len);
    for (args, 0..) |arg, idx| {
        lowered_args[idx] = (try substituteExprAliases(ctx, arg, aliases)).expr;
    }

    return switch (selector.*) {
        .identifier => |name| try newExpr(ctx, .{ .call_or_subscript = .{
            .name = name,
            .args = lowered_args,
        } }),
        .component => |comp| blk: {
            if (comp.args.len != 0) return cloneAssociateExpr(ctx, selector);
            break :blk try newExpr(ctx, .{ .component = .{
                .base = try cloneAssociateExpr(ctx, comp.base),
                .name = comp.name,
                .args = lowered_args,
                .has_parens = true,
            } });
        },
        .call_or_subscript => cloneAssociateExpr(ctx, selector),
        else => cloneAssociateExpr(ctx, selector),
    };
}

fn cloneAssociateExpr(ctx: *context.Context, expr_node: *ast.Expr) anyerror!*ast.Expr {
    return switch (expr_node.*) {
        .identifier, .literal => newExpr(ctx, expr_node.*),
        .array_constructor => |ctor| blk: {
            const items = try ctx.arena.alloc(*ast.Expr, ctor.items.len);
            for (ctor.items, 0..) |item, idx| items[idx] = try cloneAssociateExpr(ctx, item);
            var type_spec = ctor.type_spec;
            if (ctor.type_spec) |existing| {
                type_spec = existing;
                if (existing.kind_selector) |kind_selector| {
                    type_spec.?.kind_selector = try cloneAssociateExpr(ctx, kind_selector);
                }
            }
            break :blk try newExpr(ctx, .{ .array_constructor = .{
                .type_spec = type_spec,
                .items = items,
            } });
        },
        .call_or_subscript => |call| blk: {
            const args = try ctx.arena.alloc(*ast.Expr, call.args.len);
            for (call.args, 0..) |arg, idx| args[idx] = try cloneAssociateExpr(ctx, arg);
            break :blk try newExpr(ctx, .{ .call_or_subscript = .{
                .name = call.name,
                .args = args,
            } });
        },
        .substring => |sub| blk: {
            const args = try ctx.arena.alloc(*ast.Expr, sub.args.len);
            for (sub.args, 0..) |arg, idx| args[idx] = try cloneAssociateExpr(ctx, arg);
            break :blk try newExpr(ctx, .{ .substring = .{
                .name = sub.name,
                .args = args,
                .start = if (sub.start) |start| try cloneAssociateExpr(ctx, start) else null,
                .end = if (sub.end) |end_expr| try cloneAssociateExpr(ctx, end_expr) else null,
            } });
        },
        .component => |comp| blk: {
            const args = try ctx.arena.alloc(*ast.Expr, comp.args.len);
            for (comp.args, 0..) |arg, idx| args[idx] = try cloneAssociateExpr(ctx, arg);
            break :blk try newExpr(ctx, .{ .component = .{
                .base = try cloneAssociateExpr(ctx, comp.base),
                .name = comp.name,
                .args = args,
                .has_parens = comp.has_parens,
            } });
        },
        .dim_range => |range| try newExpr(ctx, .{ .dim_range = .{
            .lower = if (range.lower) |lower| try cloneAssociateExpr(ctx, lower) else null,
            .upper = try cloneAssociateExpr(ctx, range.upper),
            .stride = if (range.stride) |stride| try cloneAssociateExpr(ctx, stride) else null,
            .assumed_shape = range.assumed_shape,
        } }),
        .unary => |un| try newExpr(ctx, .{ .unary = .{
            .op = un.op,
            .expr = try cloneAssociateExpr(ctx, un.expr),
        } }),
        .binary => |bin| try newExpr(ctx, .{ .binary = .{
            .op = bin.op,
            .left = try cloneAssociateExpr(ctx, bin.left),
            .right = try cloneAssociateExpr(ctx, bin.right),
        } }),
        .complex_literal => |complex| try newExpr(ctx, .{ .complex_literal = .{
            .real = try cloneAssociateExpr(ctx, complex.real),
            .imag = try cloneAssociateExpr(ctx, complex.imag),
        } }),
        .implied_do => |implied| blk: {
            const items = try ctx.arena.alloc(*ast.Expr, implied.items.len);
            for (implied.items, 0..) |item, idx| items[idx] = try cloneAssociateExpr(ctx, item);
            break :blk try newExpr(ctx, .{ .implied_do = .{
                .items = items,
                .var_name = implied.var_name,
                .start = try cloneAssociateExpr(ctx, implied.start),
                .end = try cloneAssociateExpr(ctx, implied.end),
                .step = if (implied.step) |step| try cloneAssociateExpr(ctx, step) else null,
            } });
        },
    };
}

fn newExpr(ctx: *context.Context, value: ast.Expr) anyerror!*ast.Expr {
    const node = try ctx.arena.create(ast.Expr);
    node.* = value;
    return node;
}
