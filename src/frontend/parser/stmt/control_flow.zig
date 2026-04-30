const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../token_stream.zig");
const expr = @import("../expr.zig");
const helpers = @import("helpers.zig");

const LineParser = context.LineParser;
const Stmt = ast.Stmt;
const StmtNode = ast.StmtNode;
const Expr = ast.Expr;

const ParseStmtError = anyerror;

pub const DoContext = struct {
    const ScopeKind = enum {
        do_loop,
        block_construct,
    };

    const DoFrame = struct {
        cycle_label: []const u8,
        exit_label: ?[]const u8,
    };

    const BlockFrame = struct {
        name: ?[]const u8,
        end_label: []const u8,
    };

    const ScopeFrame = struct {
        kind: ScopeKind,
        name: ?[]const u8 = null,
        cycle_label: ?[]const u8 = null,
        exit_label: ?[]const u8 = null,
        end_label: ?[]const u8 = null,
    };

    scope_stack: std.array_list.Managed(ScopeFrame),
    counter: usize,
    pending: std.array_list.Managed(Stmt),

    pub fn init(arena: std.mem.Allocator) DoContext {
        return .{
            .scope_stack = std.array_list.Managed(ScopeFrame).init(arena),
            .counter = 0,
            .pending = std.array_list.Managed(Stmt).init(arena),
        };
    }

    pub fn nextLabel(self: *DoContext, arena: std.mem.Allocator) ![]const u8 {
        const label = try std.fmt.allocPrint(arena, "ENDDO{d}", .{self.counter});
        self.counter += 1;
        return label;
    }

    pub fn push(self: *DoContext, label: []const u8) !void {
        try self.scope_stack.append(.{
            .kind = .do_loop,
            .cycle_label = label,
            .exit_label = null,
        });
    }

    pub fn pop(self: *DoContext) ?[]const u8 {
        return if (self.popLoop()) |frame| frame.cycle_label else null;
    }

    pub fn popLoopOrError(self: *DoContext) !DoFrame {
        if (self.scope_stack.items.len == 0) return error.EndDoWithoutDo;
        const top = self.scope_stack.items[self.scope_stack.items.len - 1];
        if (top.kind != .do_loop) return error.EndDoWithoutDo;
        _ = self.scope_stack.pop();
        return .{
            .cycle_label = top.cycle_label orelse return error.InternalParserState,
            .exit_label = top.exit_label,
        };
    }

    pub fn popLoop(self: *DoContext) ?DoFrame {
        return self.popLoopOrError() catch null;
    }

    pub fn peek(self: *const DoContext) ?[]const u8 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.scope_stack.items[i];
            if (frame.kind == .do_loop) return frame.cycle_label;
        }
        return null;
    }

    pub fn peekTopLoop(self: *const DoContext) ?[]const u8 {
        if (self.scope_stack.items.len == 0) return null;
        const top = self.scope_stack.items[self.scope_stack.items.len - 1];
        if (top.kind != .do_loop) return null;
        return top.cycle_label;
    }

    pub fn peekExitLabel(self: *const DoContext) ?[]const u8 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.scope_stack.items[i];
            if (frame.kind != .do_loop) continue;
            return frame.exit_label orelse frame.cycle_label;
        }
        return null;
    }

    pub fn bindDoExitLabel(self: *DoContext, cycle_label: []const u8, exit_label: []const u8) void {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.scope_stack.items[i];
            if (frame.kind != .do_loop) continue;
            if (!std.mem.eql(u8, frame.cycle_label.?, cycle_label)) continue;
            frame.exit_label = exit_label;
            return;
        }
    }

    pub fn ensureInnermostDoExitLabel(self: *DoContext, arena: std.mem.Allocator) !?[]const u8 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.scope_stack.items[i];
            if (frame.kind != .do_loop) continue;
            if (frame.exit_label) |exit_label| return exit_label;
            const exit_label = try self.nextLoopExitLabel(arena);
            frame.exit_label = exit_label;
            return exit_label;
        }
        return null;
    }

    pub fn ensureNamedDoExitLabel(self: *DoContext, arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = &self.scope_stack.items[i];
            if (frame.kind != .do_loop) continue;
            const frame_name = frame.name orelse continue;
            if (!std.ascii.eqlIgnoreCase(frame_name, name)) continue;
            if (frame.exit_label) |exit_label| return exit_label;
            const exit_label = try self.nextLoopExitLabel(arena);
            frame.exit_label = exit_label;
            return exit_label;
        }
        return null;
    }

    pub fn nextLoopExitLabel(self: *DoContext, arena: std.mem.Allocator) ![]const u8 {
        const label = try std.fmt.allocPrint(arena, "EXITDO{d}", .{self.counter});
        self.counter += 1;
        return label;
    }

    pub fn nextBlockLabel(self: *DoContext, arena: std.mem.Allocator) ![]const u8 {
        const label = try std.fmt.allocPrint(arena, "ENDBLOCK{d}", .{self.counter});
        self.counter += 1;
        return label;
    }

    pub fn pushBlock(self: *DoContext, name: ?[]const u8, end_label: []const u8) !void {
        try self.scope_stack.append(.{
            .kind = .block_construct,
            .name = name,
            .end_label = end_label,
        });
    }

    pub fn popBlock(self: *DoContext) ?BlockFrame {
        if (self.scope_stack.items.len == 0) return null;
        const top = self.scope_stack.items[self.scope_stack.items.len - 1];
        if (top.kind != .block_construct) return null;
        _ = self.scope_stack.pop();
        return .{
            .name = top.name,
            .end_label = top.end_label orelse return null,
        };
    }

    pub fn resolveBlockExit(self: *DoContext, name: ?[]const u8) ?[]const u8 {
        if (name == null) {
            var i = self.scope_stack.items.len;
            while (i > 0) {
                i -= 1;
                const frame = self.scope_stack.items[i];
                if (frame.kind == .block_construct) return frame.end_label;
            }
            return null;
        }
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.scope_stack.items[i];
            if (frame.kind != .block_construct) continue;
            if (frame.name) |block_name| {
                if (std.ascii.eqlIgnoreCase(block_name, name.?)) {
                    return frame.end_label;
                }
            }
        }
        return null;
    }

    pub fn isInsideBlock(self: *const DoContext) bool {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].kind == .block_construct) return true;
        }
        return false;
    }

    pub fn topIsBlockConstruct(self: *const DoContext) bool {
        if (self.scope_stack.items.len == 0) return false;
        return self.scope_stack.items[self.scope_stack.items.len - 1].kind == .block_construct;
    }

    pub fn updateTopDoName(self: *DoContext, name: []const u8, cycle_label: []const u8, exit_label: ?[]const u8) !void {
        if (self.scope_stack.items.len == 0) return error.UnexpectedToken;
        const top = &self.scope_stack.items[self.scope_stack.items.len - 1];
        if (top.kind != .do_loop) return error.UnexpectedToken;
        const top_cycle = top.cycle_label orelse return error.InternalParserState;
        if (!std.mem.eql(u8, top_cycle, cycle_label)) return error.InternalParserState;
        top.name = name;
        if (exit_label) |label| top.exit_label = label;
    }

    pub fn pushNamedDo(self: *DoContext, name: []const u8, cycle_label: []const u8, exit_label: ?[]const u8) !void {
        return self.updateTopDoName(name, cycle_label, exit_label);
    }

    pub fn resolveNamedDoExit(self: *DoContext, name: []const u8) ?[]const u8 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.scope_stack.items[i];
            if (frame.kind != .do_loop) continue;
            const frame_name = frame.name orelse continue;
            if (std.ascii.eqlIgnoreCase(frame_name, name)) return frame.exit_label orelse frame.cycle_label;
        }
        return null;
    }

    pub fn resolveNamedDoCycle(self: *DoContext, name: []const u8) ?[]const u8 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.scope_stack.items[i];
            if (frame.kind != .do_loop) continue;
            const frame_name = frame.name orelse continue;
            if (std.ascii.eqlIgnoreCase(frame_name, name)) return frame.cycle_label;
        }
        return null;
    }

    pub fn pushPending(self: *DoContext, stmt: Stmt) !void {
        try self.pending.append(stmt);
    }

    pub fn popPending(self: *DoContext) ?Stmt {
        if (self.pending.items.len == 0) return null;
        const idx = self.pending.items.len - 1;
        const stmt = self.pending.items[idx];
        self.pending.shrinkRetainingCapacity(idx);
        return stmt;
    }

    pub fn hasPending(self: *const DoContext) bool {
        return self.pending.items.len != 0;
    }
};

pub fn parseDoStatement(arena: std.mem.Allocator, lp: *LineParser, do_ctx: *DoContext) ParseStmtError!StmtNode {
    if (lp.isKeywordSplit("WHILE")) {
        _ = lp.consumeKeyword("WHILE");
        _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
        const condition = try expr.parseExpr(lp, arena, 0);
        _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
        const end_label = try do_ctx.nextLabel(arena);
        try do_ctx.push(end_label);
        return .{ .do_while = .{
            .end_label = end_label,
            .condition = condition,
        } };
    }

    if (lp.peek() == null) {
        const end_label = try do_ctx.nextLabel(arena);
        try do_ctx.push(end_label);
        return .{ .do_infinite = .{
            .end_label = end_label,
        } };
    }

    const next_tok = lp.peek() orelse return error.UnexpectedToken;
    var end_label: []const u8 = undefined;
    var var_name: []const u8 = undefined;

    if (next_tok.kind == .integer) {
        end_label = try helpers.parseLabelToken(lp);
        try do_ctx.push(end_label);
        _ = lp.consume(.comma);
        if (lp.isKeywordSplit("WHILE")) {
            _ = lp.consumeKeyword("WHILE");
            _ = lp.expect(.l_paren) orelse return error.UnexpectedToken;
            const condition = try expr.parseExpr(lp, arena, 0);
            _ = lp.expect(.r_paren) orelse return error.UnexpectedToken;
            return .{ .do_while = .{
                .end_label = end_label,
                .condition = condition,
            } };
        }
        var_name = lp.readName(arena) orelse return error.MissingName;
    } else if (next_tok.kind == .identifier and helpers.nextTokenIs(lp.*, .equals)) {
        end_label = try do_ctx.nextLabel(arena);
        try do_ctx.push(end_label);
        var_name = lp.readName(arena) orelse return error.MissingName;
    } else {
        // Legacy labeled DO requires a numeric statement label; reject other heads.
        return error.UnexpectedToken;
    }

    _ = lp.expect(.equals) orelse return error.UnexpectedToken;
    const start_expr = try expr.parseExpr(lp, arena, 0);
    _ = lp.expect(.comma) orelse return error.UnexpectedToken;
    const end_expr = try expr.parseExpr(lp, arena, 0);
    var step_expr: ?*Expr = null;
    if (lp.consume(.comma)) {
        step_expr = try expr.parseExpr(lp, arena, 0);
    }
    return .{ .do_loop = .{
        .end_label = end_label,
        .var_name = var_name,
        .start = start_expr,
        .end = end_expr,
        .step = step_expr,
    } };
}
