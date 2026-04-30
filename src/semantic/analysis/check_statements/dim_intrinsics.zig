const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../context.zig");
const constants = @import("../resolve_const.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");
const expr_diagnostics = @import("../expr_diagnostics.zig");

pub const CheckError = anyerror;

pub fn checkMaxMinDimArgs(self: *context.Context, name: []const u8, args: []*ast.Expr) CheckError!void {
    if (!isMaxMinDimIntrinsic(name) or args.len < 2) return;
    const dim_arg = args[1];
    if (exprIsOptionalDummy(self, dim_arg)) {
        return expr_diagnostics.emitExprAssignmentMismatch(self, dim_arg, "must not be OPTIONAL");
    }
    if (resolve_expr.exprRank(self, dim_arg) != 0) {
        return expr_diagnostics.emitExprAssignmentMismatch(self, dim_arg, "must be a scalar");
    }
    const dim_spec = try resolve_expr.exprTypeSpec(self, dim_arg);
    if (dim_spec.lowered_kind != .integer) {
        return expr_diagnostics.emitExprAssignmentMismatch(self, dim_arg, "must be INTEGER");
    }
    const value = (try constants.evalConst(self, dim_arg)) orelse return;
    const dim = switch (value) {
        .integer => |int| int,
        else => return,
    };
    const rank = resolve_expr.exprRank(self, args[0]);
    if (dim < 1 or dim > rank) {
        return expr_diagnostics.emitExprAssignmentMismatch(self, dim_arg, "is not a valid dimension index");
    }
}

fn isMaxMinDimIntrinsic(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "maxloc") or
        std.ascii.eqlIgnoreCase(name, "minloc") or
        std.ascii.eqlIgnoreCase(name, "maxval") or
        std.ascii.eqlIgnoreCase(name, "minval");
}

fn exprIsOptionalDummy(self: *context.Context, expr: *ast.Expr) bool {
    const name = switch (expr.*) {
        .identifier => |ident| ident,
        else => return false,
    };
    const idx = resolve_symbols.findSymbolIndex(self, name) orelse return false;
    if (self.symbols.items[idx].storage != .dummy) return false;
    for (self.unit.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                if (!type_decl.optional) continue;
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .optional => |optional_decl| {
                for (optional_decl.names) |opt_name| {
                    if (std.ascii.eqlIgnoreCase(opt_name, name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}
