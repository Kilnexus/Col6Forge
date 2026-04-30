const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const context = @import("../../../context.zig");
const resolve_expr = @import("../../../resolve_expr.zig");
const resolve_symbols = @import("../../../resolve_symbols.zig");
const procedure_interfaces = @import("../../procedure_interfaces.zig");

pub fn checkActual(
    self: *context.Context,
    expr_node: *ast.Expr,
    emitDiagnostic: fn (*context.Context, *ast.Expr, []const u8) anyerror,
) anyerror!void {
    if (currentFunctionResultReference(self, expr_node)) |result_name| {
        const message = std.fmt.allocPrint(
            self.arena,
            "Function result '{s}' at (1) is invalid as X argument to C_FUNLOC",
            .{result_name},
        ) catch "Function result at (1) is invalid as X argument to C_FUNLOC";
        return emitDiagnostic(self, expr_node, message);
    }
    if (!exprIsProcedureTarget(self, expr_node)) {
        return emitDiagnostic(self, expr_node, "Argument X at (1) to C_FUNLOC shall be a procedure or a procedure pointer");
    }
}

fn currentFunctionResultReference(self: *context.Context, expr_node: *ast.Expr) ?[]const u8 {
    if (self.unit.kind != .function or expr_node.* != .identifier) return null;
    const name = expr_node.identifier;
    if (self.unit.result_name) |result_name| {
        return if (std.ascii.eqlIgnoreCase(name, result_name)) result_name else null;
    }
    return if (std.ascii.eqlIgnoreCase(name, self.unit.name)) self.unit.name else null;
}

fn exprIsProcedureTarget(self: *context.Context, expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .identifier => |name| blk: {
            if (resolve_symbols.lookupKnownProcedureSig(self, name) != null) break :blk true;
            if (procedure_interfaces.findVisibleProcedureSource(self, name) != null) break :blk true;
            if (procedureDeclaratorIsPointer(self, name)) break :blk true;
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.kind == .function or sym.kind == .subroutine or sym.is_external;
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk false;
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk false;
            if (base_spec.lowered_kind != .derived) break :blk false;
            const derived_name = base_spec.derived_type_name orelse break :blk false;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk false;
            break :blk component.procedure and component.pointer;
        },
        else => false,
    };
}

fn procedureDeclaratorIsPointer(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .procedure) continue;
        if (!decl.procedure.pointer) continue;
        for (decl.procedure.items) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
        }
    }
    return false;
}
