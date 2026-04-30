const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const case_insensitive = @import("../../../common/case_insensitive.zig");
const context = @import("../context.zig");
const intrinsics = @import("../intrinsics.zig");
const resolve_const = @import("../resolve_const.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");

pub const CheckError = anyerror;

pub fn checkOpenControl(self: *context.Context, node: ?*ast.Expr, allowed: []const []const u8) CheckError!void {
    const expr_node = node orelse return;
    self.setCurrentSource(self.sourceForExpr(expr_node));
    try checkDefaultCharacterControlExpr(self, expr_node);
    if (controlLiteralText(expr_node)) |text| {
        if (!textInSet(text, allowed)) {
            self.setCurrentSource(self.sourceForExpr(expr_node));
            return error.InvalidIoControlValue;
        }
    }
}

pub fn checkCharControlExpr(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    const ty = try resolve_expr.exprType(self, expr_node);
    if (ty != .character) {
        self.setCurrentSource(self.sourceForExpr(expr_node));
        return error.InvalidIoControlType;
    }
}

pub fn checkDefaultCharacterControlExpr(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    const spec = try resolve_expr.exprTypeSpec(self, expr_node);
    if (spec.lowered_kind == .character and (spec.kind_value orelse 1) == 1) return;
    const source = self.sourceForExpr(expr_node) orelse self.current_source orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_io_control_type.code,
        "must be a character string of default kind",
        source.text,
    );
    return error.InvalidIoControlType;
}

pub fn checkIoFormatExpr(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    const spec = try resolve_expr.exprTypeSpec(self, expr_node);
    if (spec.lowered_kind == .integer) return;
    if (spec.lowered_kind == .character and (spec.kind_value orelse 1) == 1) return;
    const source = self.sourceForExpr(expr_node) orelse self.current_source orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_io_control_type.code,
        "FORMAT expression must be of type default-kind CHARACTER or of INTEGER",
        source.text,
    );
    return error.InvalidIoControlType;
}

pub fn checkFormatSpec(self: *context.Context, format_spec: ast.FormatSpec) CheckError!void {
    switch (format_spec) {
        .expr => |fmt_expr| try checkIoFormatExpr(self, fmt_expr),
        else => {},
    }
}

pub fn checkNamedDefaultCharacterControls(
    self: *context.Context,
    controls: []const ast.ControlItem,
    names: []const []const u8,
) CheckError!void {
    for (controls) |ctrl| {
        const name = ctrl.name orelse continue;
        if (!textInSet(name, names)) continue;
        self.setCurrentSource(if (ctrl.source.line != 0) ctrl.source else self.sourceForExpr(ctrl.value));
        try checkDefaultCharacterControlExpr(self, ctrl.value);
    }
}

pub fn checkNamedCharacterControls(
    self: *context.Context,
    controls: []const ast.ControlItem,
    names: []const []const u8,
) CheckError!void {
    for (controls) |ctrl| {
        const name = ctrl.name orelse continue;
        if (!textInSet(name, names)) continue;
        const spec = try resolve_expr.exprTypeSpec(self, ctrl.value);
        if (spec.lowered_kind == .character) {
            if ((spec.kind_value orelse 1) == 1) continue;
            self.setCurrentSource(if (ctrl.source.line != 0) ctrl.source else self.sourceForExpr(ctrl.value));
            try checkDefaultCharacterControlExpr(self, ctrl.value);
        }
        const source = if (ctrl.source.line != 0) ctrl.source else (self.sourceForExpr(ctrl.value) orelse self.current_source orelse ast.SourceRef{});
        self.setDiagnostic(
            if (source.line == 0) 1 else source.line,
            if (source.column == 0) 1 else source.column,
            catalog.semantic.invalid_io_control_type.code,
            "I/O control specifier must be of type CHARACTER",
            source.text,
        );
        return error.InvalidIoControlType;
    }
}

pub fn rejectNamedIoControl(
    self: *context.Context,
    controls: []const ast.ControlItem,
    name: []const u8,
    message: []const u8,
) CheckError!void {
    for (controls) |ctrl| {
        const ctrl_name = ctrl.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(ctrl_name, name)) continue;
        const source = if (ctrl.source.line != 0) ctrl.source else (self.sourceForExpr(ctrl.value) orelse self.current_source orelse ast.SourceRef{});
        self.setDiagnostic(
            if (source.line == 0) 1 else source.line,
            if (source.column == 0) 1 else source.column,
            catalog.semantic.invalid_io_control_value.code,
            message,
            source.text,
        );
        return error.InvalidIoControlValue;
    }
}

pub fn checkReadFormatPositiveWidths(self: *context.Context, format_spec: ast.FormatSpec) CheckError!void {
    switch (format_spec) {
        .inline_items => |items| try checkReadFormatItemsPositiveWidths(self, items),
        else => {},
    }
}

fn checkReadFormatItemsPositiveWidths(self: *context.Context, items: []const ast.FormatItem) CheckError!void {
    for (items) |item| {
        switch (item) {
            .int => |fmt| if (fmt.width == 0) return emitReadFormatWidthDiagnostic(self),
            .real, .real_fixed => |fmt| if (fmt.width == 0) return emitReadFormatWidthDiagnostic(self),
            .char => |fmt| if (fmt.width == 0) return emitReadFormatWidthDiagnostic(self),
            .logical => |fmt| if (fmt.width == 0) return emitReadFormatWidthDiagnostic(self),
            .repeat_group => |group| try checkReadFormatItemsPositiveWidths(self, group.items),
            else => {},
        }
    }
}

fn emitReadFormatWidthDiagnostic(self: *context.Context) CheckError!void {
    const source = self.current_source orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_format_statement.code,
        "Positive width required in format",
        source.text,
    );
    return error.InvalidFormatStatement;
}

pub fn checkDataTransferUnit(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    const spec = try resolve_expr.exprTypeSpec(self, expr_node);
    if (spec.lowered_kind == .integer) return;
    if (spec.lowered_kind == .character and !exprReferencesParameter(self, expr_node)) return;
    const source = self.sourceForExpr(expr_node) orelse self.current_source orelse ast.SourceRef{};
    const message = if (spec.lowered_kind == .character)
        "internal file unit must not be a character PARAMETER"
    else
        "UNIT expression must be an INTEGER expression or a CHARACTER variable";
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_io_control_type.code,
        message,
        source.text,
    );
    return error.InvalidIoControlType;
}

pub fn checkInquireFileUnitControls(self: *context.Context, controls: []const ast.ControlItem) CheckError!void {
    var saw_file = false;
    var saw_unit = false;
    var fallback_source: ?ast.SourceRef = null;
    for (controls) |ctrl| {
        if (fallback_source == null) fallback_source = ctrl.source;
        if (ctrl.name) |name| {
            if (std.ascii.eqlIgnoreCase(name, "FILE")) {
                saw_file = true;
            } else if (std.ascii.eqlIgnoreCase(name, "UNIT")) {
                saw_unit = true;
                try checkInquireUnitValue(self, ctrl);
            }
        } else {
            saw_unit = true;
            try checkInquireUnitValue(self, ctrl);
        }
    }
    if (saw_file and saw_unit) {
        return emitInquireControlDiagnostic(self, fallback_source, "INQUIRE statement cannot contain both FILE and UNIT");
    }
    if (!saw_file and !saw_unit) {
        return emitInquireControlDiagnostic(self, fallback_source, "INQUIRE requires either FILE or UNIT");
    }
}

fn checkInquireUnitValue(self: *context.Context, ctrl: ast.ControlItem) CheckError!void {
    const value = (try resolve_const.evalConst(self, ctrl.value)) orelse return;
    const unit = switch (value) {
        .integer => |int| int,
        else => return,
    };
    if (unit != -1 and unit != -2) return;
    const source = if (ctrl.source.line != 0) ctrl.source else (self.sourceForExpr(ctrl.value) orelse self.current_source orelse ast.SourceRef{});
    const message = std.fmt.allocPrint(self.arena, "UNIT number cannot be {d}", .{unit}) catch "invalid negative UNIT number";
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_io_control_value.code,
        message,
        source.text,
    );
    return error.InvalidIoControlValue;
}

fn emitInquireControlDiagnostic(self: *context.Context, source_opt: ?ast.SourceRef, message: []const u8) CheckError!void {
    const source = source_opt orelse self.current_source orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_io_control_value.code,
        message,
        source.text,
    );
    return error.InvalidIoControlValue;
}

fn exprReferencesParameter(self: *context.Context, expr_node: *ast.Expr) bool {
    switch (expr_node.*) {
        .identifier => |name| return symbolIsParameter(self, name),
        .call_or_subscript => |call| return symbolIsParameter(self, call.name),
        .substring => |sub| return symbolIsParameter(self, sub.name),
        .component => |comp| return exprReferencesParameter(self, comp.base),
        else => return false,
    }
}

fn symbolIsParameter(self: *context.Context, name: []const u8) bool {
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    return self.symbols.items[idx].kind == .parameter;
}

pub fn controlLiteralText(expr_node: *ast.Expr) ?[]const u8 {
    switch (expr_node.*) {
        .literal => |lit| {
            if (lit.kind != .string and lit.kind != .hollerith) return null;
            var text = lit.text;
            if (text.len >= 2 and text[0] == text[text.len - 1] and (text[0] == '\'' or text[0] == '"')) {
                text = text[1 .. text.len - 1];
            }
            return std.mem.trim(u8, text, " \t");
        },
        else => return null,
    }
}

pub fn checkCallAltReturnLabel(self: *context.Context, label: []const u8) CheckError!void {
    if (!stmtListHasLabel(self.unit.stmts, label)) return error.InvalidArgumentCount;
}

pub fn isHomogeneousMaxMinIntrinsic(name: []const u8) bool {
    var upper_buf: [64]u8 = undefined;
    if (name.len > upper_buf.len) return false;
    for (name, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    const upper = upper_buf[0..name.len];
    return std.mem.eql(u8, upper, "MAX") or std.mem.eql(u8, upper, "MIN");
}

pub const lowerDup = case_insensitive.lowerDup;

pub fn lookupIntrinsicArity(self: *context.Context, name: []const u8) ?intrinsics.Arity {
    var key_buf: [128]u8 = undefined;
    var key_owned: ?[]const u8 = null;
    const key: []const u8 = blk: {
        if (name.len <= key_buf.len) {
            for (name, 0..) |ch, i| key_buf[i] = std.ascii.toLower(ch);
            break :blk key_buf[0..name.len];
        }
        const owned = lowerDup(self.arena, name) catch return intrinsics.arity(name);
        key_owned = owned;
        break :blk owned;
    };
    if (self.intrinsic_arity_cache.get(key)) |cached| return cached;
    const resolved = intrinsics.arity(name);
    const cache_key = key_owned orelse (lowerDup(self.arena, name) catch return resolved);
    self.intrinsic_arity_cache.put(cache_key, resolved) catch {};
    return resolved;
}

fn stmtListHasLabel(stmts: []const ast.Stmt, label: []const u8) bool {
    for (stmts) |stmt| {
        if (stmt.label) |stmt_label| {
            if (std.mem.eql(u8, stmt_label, label)) return true;
        }
        switch (stmt.node) {
            .if_block => |ifb| {
                if (stmtListHasLabel(ifb.then_stmts, label)) return true;
                if (stmtListHasLabel(ifb.else_stmts, label)) return true;
            },
            else => {},
        }
    }
    return false;
}

pub fn textInSet(text: []const u8, allowed: []const []const u8) bool {
    var upper_buf: [256]u8 = undefined;
    if (text.len <= upper_buf.len) {
        for (text, 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
        const upper = upper_buf[0..text.len];
        for (allowed) |candidate| {
            if (std.mem.eql(u8, upper, candidate)) return true;
        }
        return false;
    }
    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(text, candidate)) return true;
    }
    return false;
}
