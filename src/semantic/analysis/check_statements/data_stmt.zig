const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const resolve_const = @import("../resolve_const.zig");
const resolve_symbols = @import("../resolve_symbols.zig");

pub const CheckError = anyerror;

pub fn checkDataInit(self: *context.Context, init: ast.DataInit) CheckError!void {
    const name = rootDataTargetName(init.target) orelse return;
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return;
    const sym = self.symbols.items[idx];

    if (declaratorHasInitializer(self, name)) return emitDataTargetDiagnostic(self, init.target, "already is initialized");
    if (sym.is_allocatable) return emitDataTargetDiagnostic(self, init.target, "Cannot change attributes: conflicts with ALLOCATABLE");
    if (sym.storage == .dummy) return emitDataTargetDiagnostic(self, init.target, "conflicts with DUMMY attribute");
    if (sym.is_host_associated) {
        const message = if (self.unit.kind == .function) "Host associated variable" else "Cannot change attributes";
        return emitDataTargetDiagnostic(self, init.target, message);
    }
    if (sym.type_explicit and !declaratorIsLocal(self, name)) return emitDataTargetDiagnostic(self, init.target, "Cannot change attributes");
    if (self.unit.kind == .function) {
        if (self.unit.result_name) |result_name| {
            if (std.ascii.eqlIgnoreCase(name, result_name)) return emitDataTargetDiagnostic(self, init.target, "conflicts with RESULT");
        } else if (std.ascii.eqlIgnoreCase(name, self.unit.name)) {
            return emitDataTargetDiagnostic(self, init.target, "conflicts with FUNCTION");
        }
    }
    if (dataTargetHasNonconstantArrayReference(self, init.target) or dataTargetHasNonconstantArrayBounds(self, init.target)) {
        return emitDataTargetDiagnostic(self, init.target, "non-constant array in DATA");
    }
    if ((try resolve_const.evalConst(self, init.value)) == null) {
        return emitDataTargetDiagnostic(self, init.value, "non-constant initialization");
    }
}

fn rootDataTargetName(expr: *ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .identifier => |name| name,
        .call_or_subscript => |call| call.name,
        .substring => |sub| sub.name,
        .component => |comp| rootDataTargetName(comp.base),
        else => null,
    };
}

fn declaratorHasInitializer(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .type_decl) continue;
        for (decl.type_decl.items) |item| {
            if (item.init == null) continue;
            if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
        }
    }
    return false;
}

fn declaratorIsLocal(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .type_decl) continue;
        for (decl.type_decl.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
        }
    }
    return false;
}

fn dataTargetHasNonconstantArrayReference(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .call_or_subscript => |call| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false;
            if (self.symbols.items[idx].dims.len == 0) break :blk false;
            for (call.args) |arg| {
                if ((resolve_const.evalConst(self, arg) catch null) == null) break :blk true;
            }
            break :blk false;
        },
        .component => |comp| dataTargetHasNonconstantArrayReference(self, comp.base),
        else => false,
    };
}

fn dataTargetHasNonconstantArrayBounds(self: *context.Context, expr: *ast.Expr) bool {
    const name = rootDataTargetName(expr) orelse return false;
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    for (self.symbols.items[idx].dims) |dim| {
        if (dimHasNonconstantBound(self, dim)) return true;
    }
    return false;
}

fn dimHasNonconstantBound(self: *context.Context, dim: *ast.Expr) bool {
    return switch (dim.*) {
        .dim_range => |range| {
            if (range.lower) |lower| {
                if (!exprIsConstant(self, lower)) return true;
            }
            return !exprIsConstant(self, range.upper);
        },
        else => !exprIsConstant(self, dim),
    };
}

fn exprIsConstant(self: *context.Context, expr: *ast.Expr) bool {
    return (resolve_const.evalConst(self, expr) catch null) != null;
}

fn emitDataTargetDiagnostic(self: *context.Context, expr: *ast.Expr, message: []const u8) CheckError {
    const source = self.sourceForExpr(expr) orelse blk: {
        if (self.current_stmt) |stmt| {
            break :blk ast.SourceRef{ .line = stmt.source_line, .column = stmt.source_column, .text = stmt.source_text };
        }
        break :blk ast.SourceRef{};
    };
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
    );
    return error.InvalidArgumentCount;
}
