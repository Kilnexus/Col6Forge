const ast = @import("../../ast/nodes.zig");
const context = @import("context.zig");
const resolve_expr = @import("resolve_expr.zig");
const resolve_symbols = @import("resolve_symbols.zig");

pub fn isAllocatableEntity(self: *context.Context, expr: *ast.Expr) bool {
    return exprHasComponentBackedAttribute(self, expr, .allocatable);
}

pub fn isPointerEntity(self: *context.Context, expr: *ast.Expr) bool {
    return exprHasComponentBackedAttribute(self, expr, .pointer);
}

pub fn isCAddressableDataTarget(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.is_target or sym.is_pointer;
        },
        .call_or_subscript => |call| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.kind == .variable and call.args.len != 0 and (sym.is_target or sym.is_pointer);
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk false;
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk false;
            if (base_spec.lowered_kind != .derived) break :blk false;
            const derived_name = base_spec.derived_type_name orelse break :blk false;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk false;
            break :blk component.pointer;
        },
        .substring => |sub| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, sub.name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.is_target or sym.is_pointer;
        },
        else => false,
    };
}

const Attribute = enum {
    allocatable,
    pointer,
};

fn exprHasComponentBackedAttribute(self: *context.Context, expr: *ast.Expr, attr: Attribute) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk switch (attr) {
                .allocatable => sym.is_allocatable,
                .pointer => sym.is_pointer,
            };
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk false;
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk false;
            if (base_spec.lowered_kind != .derived) break :blk false;
            const derived_name = base_spec.derived_type_name orelse break :blk false;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk false;
            break :blk switch (attr) {
                .allocatable => component.allocatable,
                .pointer => component.pointer,
            };
        },
        else => false,
    };
}
