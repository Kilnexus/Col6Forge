const context = @import("context.zig");
const check_statements = @import("check_statements/mod.zig");

pub const Checker = struct {
    ctx: *context.Context,

    pub fn init(ctx: *context.Context) Checker {
        return .{ .ctx = ctx };
    }

    pub fn run(self: *Checker) !void {
        const ctx = self.ctx;
        if (!ctx.enterUnitScope()) return error.MissingUnitScope;
        var first_stmt_error: ?anyerror = null;
        for (ctx.unit.stmts) |stmt| {
            const diag_count_before = ctx.diagnosticCount();
            check_statements.checkStmt(ctx, stmt) catch |err| {
                check_statements.closeCompletedDoRanges(ctx, stmt);
                if (!ctx.usesExplicitDiagnosticBag()) return err;
                if (first_stmt_error == null) first_stmt_error = err;
                if (ctx.diagnosticCount() == diag_count_before) {
                    ctx.recordSemanticError(err);
                }
                continue;
            };
            if (stmt.node == .do_loop) try check_statements.noteDoLoopStart(ctx, stmt);
            check_statements.closeCompletedDoRanges(ctx, stmt);
        }
        if (first_stmt_error) |err| return err;
    }
};
