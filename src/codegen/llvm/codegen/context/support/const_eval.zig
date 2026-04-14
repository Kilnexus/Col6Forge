const std = @import("std");
const input = @import("../../../../input.zig");
const evaluator = @import("../../../../../semantic/evaluator.zig");
const common = @import("../../common.zig");
const mod = @import("../mod.zig");

const Context = mod.Context;
const resolver_magic: u64 = 0x434F444547454E43; // "CODEGENC"

const ResolverBridge = struct {
    magic: u64 = resolver_magic,
    ctx: *Context,
};

pub const CodegenConstResolver = struct {
    bridge: ResolverBridge,
    resolver: evaluator.ConstResolver,
};

pub fn makeCodegenConstResolver(ctx: *Context) CodegenConstResolver {
    var out: CodegenConstResolver = undefined;
    out.bridge = .{ .ctx = ctx };
    out.resolver = .{
        .ctx = @ptrCast(&out.bridge),
        .resolveFn = resolveCodegenConstValue,
        .arrayExtentFn = resolveCodegenArrayExtent,
    };
    return out;
}

fn unwrapResolverContext(raw_ctx: *anyopaque) *Context {
    const bridge: *ResolverBridge = @ptrCast(@alignCast(raw_ctx));
    std.debug.assert(bridge.magic == resolver_magic);
    return bridge.ctx;
}

pub fn inferConstantCharLen(ctx: *const Context, expr: ?*input.Expr) ?usize {
    const node = expr orelse return 1;
    const resolver = makeCodegenConstResolver(@constCast(ctx));
    const value = evaluator.evalConst(node, resolver.resolver) catch return null;
    return switch (value orelse return null) {
        .integer => |int_val| if (int_val < 0) null else std.math.cast(usize, int_val),
        else => null,
    };
}

pub fn resolveCodegenConstValue(raw_ctx: *anyopaque, name: []const u8) ?input.sema.ConstValue {
    const ctx = unwrapResolverContext(raw_ctx);
    if (ctx.symbolIndexForName(name)) |idx| {
        const sym = ctx.sem.symbols[idx];
        return sym.const_value;
    }
    return null;
}

pub fn resolveCodegenArrayExtent(raw_ctx: *anyopaque, name: []const u8, dim: ?usize) ?i64 {
    const ctx = unwrapResolverContext(raw_ctx);
    const idx = ctx.symbolIndexForName(name) orelse return null;
    const sym = ctx.sem.symbols[idx];
    if (sym.dims.len == 0) return null;
    const extent = common.arrayElementCount(ctx.sem, if (dim) |dim_idx| sym.dims[dim_idx .. dim_idx + 1] else sym.dims) catch return null;
    return @intCast(extent);
}
