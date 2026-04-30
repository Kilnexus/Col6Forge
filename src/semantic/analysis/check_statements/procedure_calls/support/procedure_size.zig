const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const context = @import("../../../context.zig");
const assumed_size = @import("../../../assumed_size.zig");
const resolve_expr = @import("../../../resolve_expr.zig");
const resolve_symbols = @import("../../../resolve_symbols.zig");
const procedure_interfaces = @import("../../procedure_interfaces.zig");

pub fn checkActual(
    self: *context.Context,
    intrinsic_name: []const u8,
    expr_node: *ast.Expr,
    emitDiagnostic: fn (*context.Context, *ast.Expr, []const u8) anyerror,
) anyerror!void {
    if (std.ascii.eqlIgnoreCase(intrinsic_name, "c_sizeof")) {
        try checkCSizeofDataInteroperability(self, expr_node, emitDiagnostic);
        if (exprIsProcedureDesignator(self, expr_node)) {
            return emitDiagnostic(self, expr_node, "Procedure unexpected as argument");
        }
        return;
    }
    if (!exprIsProcedureDesignator(self, expr_node)) return;
    return emitDiagnostic(self, expr_node, "shall not be a procedure");
}

fn checkCSizeofDataInteroperability(
    self: *context.Context,
    expr_node: *ast.Expr,
    emitDiagnostic: fn (*context.Context, *ast.Expr, []const u8) anyerror,
) anyerror!void {
    if (assumed_size.exprNeedsExplicitLastUpperBound(self, expr_node)) {
        return emitDiagnostic(self, expr_node, "Assumed-size arrays are not interoperable");
    }
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return;
    if (spec.lowered_kind != .derived) return;
    const derived_name = spec.derived_type_name orelse return;
    if (derivedTypeIsCInteroperable(self, derived_name)) return;
    return emitDiagnostic(self, expr_node, "Expression is a noninteroperable derived type");
}

fn derivedTypeIsCInteroperable(self: *context.Context, derived_name: []const u8) bool {
    const info = resolve_symbols.lookupDerivedType(self, derived_name) orelse return false;
    if (!info.bind_c) return false;
    for (info.components) |component| {
        if (component.allocatable or component.pointer) return false;
        if (component.type_spec.lowered_kind == .derived) {
            const nested = component.type_spec.derived_type_name orelse return false;
            if (!derivedTypeIsCInteroperable(self, nested)) return false;
        }
    }
    return true;
}

fn exprIsProcedureDesignator(self: *context.Context, expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .identifier => |name| blk: {
            if (procedureDeclaratorExists(self, name)) break :blk true;
            if (resolve_symbols.lookupKnownProcedureSig(self, name) != null) break :blk true;
            if (procedure_interfaces.findVisibleProcedureSource(self, name) != null) break :blk true;
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
            break :blk component.procedure;
        },
        else => false,
    };
}

fn procedureDeclaratorExists(self: *context.Context, name: []const u8) bool {
    var decl_idx: usize = self.unit.decls.len;
    while (decl_idx > 0) {
        decl_idx -= 1;
        const decl = self.unit.decls[decl_idx];
        if (decl != .procedure) continue;
        var item_idx: usize = 0;
        while (item_idx < decl.procedure.items.len) : (item_idx += 1) {
            if (std.ascii.eqlIgnoreCase(decl.procedure.items[item_idx].name, name)) return true;
        }
    }
    return false;
}
