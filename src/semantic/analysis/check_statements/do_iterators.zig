const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common_diag = @import("../../../common/diagnostic.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");

pub fn noteLoopStart(self: *context.Context, stmt: ast.Stmt, loop: ast.DoLoopStmt) !void {
    try self.active_do_controls.append(.{
        .name = loop.var_name,
        .end_label = loop.end_label,
        .source = .{
            .line = stmt.source_line,
            .column = stmt.source_column,
            .text = stmt.source_text,
        },
    });
}

pub fn closeLoopRangesEndingAt(self: *context.Context, stmt: ast.Stmt) void {
    const label = stmt.label orelse return;
    while (self.active_do_controls.items.len > 0) {
        const last = self.active_do_controls.items[self.active_do_controls.items.len - 1];
        if (!std.ascii.eqlIgnoreCase(last.end_label, label)) return;
        _ = self.active_do_controls.pop();
    }
}

pub fn rejectActiveControlDefinition(self: *context.Context, expr_node: *ast.Expr) !void {
    const target_name = rootDefinedName(expr_node) orelse return;
    for (self.active_do_controls.items) |control| {
        if (!std.ascii.eqlIgnoreCase(control.name, target_name)) continue;
        return emitDoControlDefinitionDiagnostic(self, expr_node, control);
    }
}

pub fn rejectActiveControlNameDefinition(self: *context.Context, name: []const u8) !void {
    for (self.active_do_controls.items) |control| {
        if (!std.ascii.eqlIgnoreCase(control.name, name)) continue;
        return emitDoControlNameDiagnostic(self, name, control);
    }
}

fn rootDefinedName(expr_node: *ast.Expr) ?[]const u8 {
    return switch (expr_node.*) {
        .identifier => |name| name,
        .call_or_subscript => |call| call.name,
        .substring => |sub| sub.name,
        .component => |component| rootDefinedName(component.base),
        else => null,
    };
}

fn emitDoControlDefinitionDiagnostic(
    self: *context.Context,
    expr_node: *ast.Expr,
    control: context.Context.ActiveDoControl,
) anyerror {
    const source = self.sourceForExpr(expr_node) orelse stmtSource(self);
    return emitDiagnosticAtSource(self, source, control);
}

fn emitDoControlNameDiagnostic(
    self: *context.Context,
    name: []const u8,
    control: context.Context.ActiveDoControl,
) anyerror {
    _ = name;
    return emitDiagnosticAtSource(self, stmtSource(self), control);
}

fn emitDiagnosticAtSource(
    self: *context.Context,
    source: ast.SourceRef,
    control: context.Context.ActiveDoControl,
) anyerror {
    const related = [_]common_diag.DiagnosticSpan{.{
        .file_path = "",
        .line = if (control.source.line == 0) 1 else control.source.line,
        .column = if (control.source.column == 0) 1 else control.source.column,
        .line_text = control.source.text,
        .label = "DO loop begins here",
    }};
    self.setDiagnosticStructured(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "DO variable cannot be redefined inside its loop",
        source.text,
        "cannot be redefined",
        &.{},
        &.{},
        related[0..],
    );
    return error.AssignmentTypeMismatch;
}

fn stmtSource(self: *context.Context) ast.SourceRef {
    const stmt = self.current_stmt orelse return .{};
    return .{
        .line = stmt.source_line,
        .column = stmt.source_column,
        .text = stmt.source_text,
    };
}
