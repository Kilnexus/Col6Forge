const ast = @import("../../../../../ast/nodes.zig");
const context = @import("../../../context.zig");
const expr_attributes = @import("../../../expr_attributes.zig");
const resolve_symbols = @import("../../../resolve_symbols.zig");
const diagnostics = @import("../../procedure_call_diagnostics.zig");
const resolution = @import("resolution.zig");

pub fn check(
    self: *context.Context,
    callee_name: ?[]const u8,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
    skip_no_arg_check_compat: bool,
) anyerror!void {
    if (skip_no_arg_check_compat or !formal.allocatable) return;
    if (actualIsFunctionResult(self, actual_expr)) {
        return diagnostics.emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "is a function result");
    }
    if (!expr_attributes.isAllocatableEntity(self, actual_expr)) {
        return diagnostics.emitProcedureActualCallDiagnostic(self, callee_name, formal.name, actual_expr, error.InvalidArgumentCount, "must be ALLOCATABLE");
    }
}

fn actualIsFunctionResult(self: *context.Context, expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .call_or_subscript => |call| blk: {
            const sig = resolve_symbols.lookupKnownProcedureSig(self, call.name) orelse
                resolution.lookupProcedureDeclaratorSig(self, call.name) orelse break :blk false;
            break :blk sig.kind == .function;
        },
        else => false,
    };
}
