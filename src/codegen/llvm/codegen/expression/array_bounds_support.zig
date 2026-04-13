const ast = @import("../../../input.zig");
const context = @import("../context/mod.zig");
const memory = @import("./memory.zig");

pub const Context = context.Context;
pub const ValueRef = context.ValueRef;

const ComponentDimValueKind = enum {
    lower,
    extent,
};

pub fn shouldUseExtentBounds(ctx: *Context, expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .call_or_subscript => |call| call.args.len != 0,
        .component => |comp| comp.args.len != 0,
        .substring => |sub| blk: {
            const sym = ctx.findSymbol(sub.name) orelse break :blk false;
            break :blk sym.dims.len != 0;
        },
        else => false,
    };
}

pub fn emitComponentDimLowerValue(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    dim_index: usize,
) !ValueRef {
    return emitComponentDimValue(ctx, builder, comp, dim_index, .lower);
}

pub fn emitComponentDimExtentValue(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    dim_index: usize,
) !ValueRef {
    return emitComponentDimValue(ctx, builder, comp, dim_index, .extent);
}

fn emitComponentDimValue(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    dim_index: usize,
    comptime kind: ComponentDimValueKind,
) !ValueRef {
    const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse return error.UnknownSymbol;
    const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse return error.UnknownSymbol;
    if (component.pointer or component.allocatable) {
        return switch (kind) {
            .lower => memory.emitComponentDimLower(ctx, builder, comp, dim_index),
            .extent => memory.emitComponentDimExtent(ctx, builder, comp, dim_index),
        };
    }
    return switch (kind) {
        .lower => memory.emitDimLower(ctx, builder, component.dims[dim_index]),
        .extent => memory.emitDimValue(ctx, builder, component.dims[dim_index]),
    };
}
