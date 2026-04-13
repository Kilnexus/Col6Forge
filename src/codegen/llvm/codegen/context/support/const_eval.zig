const std = @import("std");
const input = @import("../../../../input.zig");
const evaluator = @import("../../../../../semantic/evaluator.zig");
const common = @import("../../common.zig");
const mod = @import("../mod.zig");

const Context = mod.Context;

pub fn inferConstantCharLen(ctx: *const Context, expr: ?*input.Expr) ?usize {
    const node = expr orelse return 1;
    const value = evaluator.evalConst(node, .{
        .ctx = @constCast(ctx),
        .resolveFn = resolveCodegenConstValue,
        .arrayExtentFn = resolveCodegenArrayExtent,
    }) catch return null;
    return switch (value orelse return null) {
        .integer => |int_val| if (int_val < 0) null else std.math.cast(usize, int_val),
        else => null,
    };
}

pub fn resolveCodegenConstValue(raw_ctx: *anyopaque, name: []const u8) ?input.sema.ConstValue {
    const ctx: *Context = @ptrCast(@alignCast(raw_ctx));
    if (ctx.symbolIndexForName(name)) |idx| {
        const sym = ctx.sem.symbols[idx];
        if (sym.kind == .parameter and sym.const_value != null) {
            return sym.const_value;
        }
    }
    return resolveMirroredPreludeParameterConstValue(ctx, name);
}

pub fn resolveCodegenArrayExtent(raw_ctx: *anyopaque, name: []const u8, dim: ?usize) ?i64 {
    const ctx: *Context = @ptrCast(@alignCast(raw_ctx));
    const idx = ctx.symbolIndexForName(name) orelse return null;
    const sym = ctx.sem.symbols[idx];
    if (sym.dims.len == 0) return null;
    const extent = common.arrayElementCount(ctx.sem, if (dim) |dim_idx| sym.dims[dim_idx .. dim_idx + 1] else sym.dims) catch return null;
    return @intCast(extent);
}

fn resolveMirroredPreludeParameterConstValue(ctx: *Context, name: []const u8) ?input.sema.ConstValue {
    for (ctx.unit.decls) |decl| {
        if (decl != .parameter) continue;
        for (decl.parameter.assigns) |assign| {
            if (!std.ascii.eqlIgnoreCase(assign.name, name)) continue;
            const resolver = evaluator.ConstResolver{
                .ctx = ctx,
                .resolveFn = resolveCodegenConstValue,
                .arrayExtentFn = resolveCodegenArrayExtent,
            };
            return evaluator.evalConst(assign.value, resolver) catch null;
        }
    }
    return null;
}
