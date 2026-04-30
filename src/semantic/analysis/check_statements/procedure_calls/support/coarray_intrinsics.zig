const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const context = @import("../../../context.zig");
const constants = @import("../../../resolve_const.zig");
const resolve_expr = @import("../../../resolve_expr.zig");
const expr_diagnostics = @import("../../../expr_diagnostics.zig");

pub const CheckError = anyerror;

pub fn checkExprArgs(self: *context.Context, name: []const u8, args: []*ast.Expr) CheckError!void {
    if (std.ascii.eqlIgnoreCase(name, "image_status")) return checkImageStatusArgs(self, args);
    if (std.ascii.eqlIgnoreCase(name, "failed_images")) return checkImageSetArgs(self, name, args);
    if (std.ascii.eqlIgnoreCase(name, "stopped_images")) return checkImageSetArgs(self, name, args);
}

fn checkImageStatusArgs(self: *context.Context, args: []*ast.Expr) CheckError!void {
    if (args.len == 0) return;
    if (args.len == 1 and exprLineHasKeyword(self, args[0], "team")) {
        return expr_diagnostics.emitExprInvalidArgument(self, args[0], "Missing actual argument 'image' in call to 'image_status' at (1)");
    }
    try checkImageArg(self, "image_status", args[0]);
    if (args.len >= 2) try checkTeamArg(self, "image_status", args[1]);
}

fn checkImageSetArgs(self: *context.Context, name: []const u8, args: []*ast.Expr) CheckError!void {
    for (args) |arg| {
        if (exprLineHasKeyword(self, arg, "team")) return checkTeamArg(self, name, arg);
        if (exprLineHasKeyword(self, arg, "kind")) return checkKindArg(self, name, arg);
    }
}

fn checkImageArg(self: *context.Context, name: []const u8, arg: *ast.Expr) CheckError!void {
    if (resolve_expr.exprRank(self, arg) != 0) return expr_diagnostics.emitExprInvalidArgument(self, arg, "'image' argument of 'image_status' intrinsic at (1) must be a scalar");
    const spec = try resolve_expr.exprTypeSpec(self, arg);
    if (spec.lowered_kind != .integer) return expr_diagnostics.emitExprInvalidArgument(self, arg, "'image' argument of 'image_status' intrinsic at (1) must be INTEGER");
    const value = constInteger(self, arg) orelse return;
    if (value <= 0) return expr_diagnostics.emitExprInvalidArgument(self, arg, "'image' argument of 'image_status' intrinsic at (1) must be positive");
    _ = name;
}

fn checkTeamArg(self: *context.Context, name: []const u8, arg: *ast.Expr) CheckError!void {
    const spec = try resolve_expr.exprTypeSpec(self, arg);
    if (spec.lowered_kind == .derived) {
        if (spec.derived_type_name) |type_name| {
            if (std.ascii.eqlIgnoreCase(type_name, "team_type")) return;
        }
    }
    const message = try std.fmt.allocPrint(self.arena, "'team' argument of '{s}' intrinsic at (1) shall be of type 'team_type'", .{name});
    return expr_diagnostics.emitExprInvalidArgument(self, arg, message);
}

fn checkKindArg(self: *context.Context, name: []const u8, arg: *ast.Expr) CheckError!void {
    const spec = try resolve_expr.exprTypeSpec(self, arg);
    if (spec.lowered_kind != .integer) {
        const message = try std.fmt.allocPrint(self.arena, "'kind' argument of '{s}' intrinsic at (1) must be INTEGER", .{name});
        return expr_diagnostics.emitExprInvalidArgument(self, arg, message);
    }
    const value = constInteger(self, arg) orelse {
        return expr_diagnostics.emitExprInvalidArgument(self, arg, "Constant expression required at (1)");
    };
    if (value <= 0) {
        const message = try std.fmt.allocPrint(self.arena, "'kind' argument of '{s}' intrinsic at (1) must be positive", .{name});
        return expr_diagnostics.emitExprInvalidArgument(self, arg, message);
    }
    if (value != 1 and value != 2 and value != 4 and value != 8) {
        const message = try std.fmt.allocPrint(self.arena, "'kind' argument of '{s}' intrinsic at (1) shall specify a valid integer kind", .{name});
        return expr_diagnostics.emitExprInvalidArgument(self, arg, message);
    }
}

fn constInteger(self: *context.Context, arg: *ast.Expr) ?i64 {
    const value = constants.evalConst(self, arg) catch return null;
    return switch (value orelse return null) {
        .integer => |int| int,
        else => null,
    };
}

fn exprLineHasKeyword(self: *context.Context, arg: *ast.Expr, keyword: []const u8) bool {
    if (sourceTextHasKeyword((self.sourceForExpr(arg) orelse ast.SourceRef{}).text, keyword)) return true;
    return sourceTextHasKeyword((self.current_source orelse ast.SourceRef{}).text, keyword);
}

fn sourceTextHasKeyword(text: []const u8, keyword: []const u8) bool {
    var start: usize = 0;
    while (std.ascii.indexOfIgnoreCase(text[start..], keyword)) |rel| {
        var pos = start + rel + keyword.len;
        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) : (pos += 1) {}
        if (pos < text.len and text[pos] == '=') return true;
        start += rel + keyword.len;
    }
    return false;
}
