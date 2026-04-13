const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const symbols = @import("../symbol/mod.zig");
const evaluator = @import("../evaluator.zig");
const context = @import("context.zig");
const resolve_expr = @import("resolve_expr/mod.zig");
const symbols_mod = @import("resolve_symbols.zig");
const literals = @import("../evaluator/literals.zig");
const array_dim_queries = @import("array_dim_queries.zig");

const ConstValue = symbols.ConstValue;

pub fn evalConst(self: *context.Context, expr: *ast.Expr) anyerror!?ConstValue {
    const key: usize = @intFromPtr(expr);
    if (self.const_eval_cache.get(key)) |cached| return cached;
    const computed = try evalConstUncached(self, expr);
    try self.const_eval_cache.put(key, computed);
    return computed;
}

fn evalConstUncached(self: *context.Context, expr: *ast.Expr) anyerror!?ConstValue {
    if (expr.* == .call_or_subscript) {
        const call = expr.call_or_subscript;
        if (call.args.len == 0 and symbols_mod.lookupDerivedType(self, call.name) != null) {
            const bytes_i64 = derivedTypeStorageBytes(self, call.name) orelse return null;
            const bytes = std.math.cast(usize, bytes_i64) orelse return null;
            const out = try self.arena.alloc(u8, bytes);
            @memset(out, 0);
            return .{ .string = out };
        }
    }

    const resolver = evaluator.ConstResolver{
        .ctx = @ptrCast(self),
        .resolveFn = resolveConstValue,
        .allocator = self.arena,
        .internStringFn = internConstString,
        .arrayExtentFn = resolveArrayExtent,
        .arrayLowerBoundFn = resolveArrayLowerBound,
        .exprMeasureFn = resolveConstExprMeasure,
        .exprTypeSpecFn = resolveConstExprTypeSpec,
        .derivedExtendsFn = resolveDerivedTypeExtends,
        .componentConstFn = resolveConstComponentValue,
    };
    return evaluator.evalConst(expr, resolver);
}

pub fn exprMeasure(
    self: *context.Context,
    expr: *ast.Expr,
    measure: evaluator.ExprMeasureKind,
) ?i64 {
    return constExprMeasure(self, expr, measure);
}

fn resolveConstValue(ctx: *anyopaque, name: []const u8) ?ConstValue {
    const self: *context.Context = @ptrCast(@alignCast(ctx));
    if (symbols_mod.findSymbolIndex(self, name)) |idx| {
        return self.symbols.items[idx].const_value;
    }
    if (symbols_mod.lookupHostAssociatedParameter(self, name)) |host_sym| {
        return host_sym.const_value;
    }
    if (!maybeBuiltinConstName(name)) return null;
    if (symbols_mod.findBuiltinConstant(self, name)) |builtin| return builtin.value;
    return null;
}

fn internConstString(ctx: *anyopaque, text: []const u8) anyerror![]const u8 {
    const self: *context.Context = @ptrCast(@alignCast(ctx));
    return self.internConstString(text);
}

fn resolveArrayExtent(ctx: *anyopaque, name: []const u8, dim: ?usize) ?i64 {
    const self: *context.Context = @ptrCast(@alignCast(ctx));
    const idx = symbols_mod.findSymbolIndex(self, name) orelse return null;
    const sym = self.symbols.items[idx];
    if (sym.dims.len == 0) return null;
    if (dim) |requested_dim| {
        if (requested_dim == 0 or requested_dim > sym.dims.len) return null;
        return evalDimExtent(self, sym.dims[requested_dim - 1]);
    }
    var total: i64 = 1;
    for (sym.dims) |dim_expr| {
        const extent = evalDimExtent(self, dim_expr) orelse return null;
        total = std.math.mul(i64, total, extent) catch return null;
    }
    return total;
}

fn resolveArrayLowerBound(ctx: *anyopaque, name: []const u8, dim: usize) ?i64 {
    const self: *context.Context = @ptrCast(@alignCast(ctx));
    return array_dim_queries.resolveArrayLowerBound(self, name, dim, evalDimLower);
}

fn resolveConstExprMeasure(
    ctx: *anyopaque,
    expr: *const ast.Expr,
    measure: evaluator.ExprMeasureKind,
) ?i64 {
    const self: *context.Context = @ptrCast(@alignCast(ctx));
    return constExprMeasure(self, @constCast(expr), measure);
}

fn resolveConstExprTypeSpec(ctx: *anyopaque, expr: *const ast.Expr) ?symbols.TypeSpec {
    const self: *context.Context = @ptrCast(@alignCast(ctx));
    return resolve_expr.exprTypeSpec(self, @constCast(expr)) catch null;
}

fn resolveDerivedTypeExtends(ctx: *anyopaque, candidate: []const u8, base: []const u8) bool {
    const self: *context.Context = @ptrCast(@alignCast(ctx));
    return symbols_mod.isSameOrExtension(self, candidate, base);
}

fn resolveConstComponentValue(raw_ctx: *anyopaque, base: *const ast.Expr, name: []const u8) ?ConstValue {
    const self: *context.Context = @ptrCast(@alignCast(raw_ctx));
    const base_value = evalConst(self, @constCast(base)) catch return null;
    const base_bytes = switch (base_value orelse return null) {
        .string => |bytes| bytes,
        else => return null,
    };
    const base_spec = resolve_expr.exprTypeSpec(self, @constCast(base)) catch return null;
    if (base_spec.lowered_kind != .derived) return null;
    const derived_name = base_spec.derived_type_name orelse return null;
    const slice = derivedComponentRawSlice(self, derived_name, name, base_bytes) orelse return null;
    return .{ .string = slice };
}

fn constExprMeasure(
    self: *context.Context,
    expr: *ast.Expr,
    measure: evaluator.ExprMeasureKind,
) ?i64 {
    const element_bytes = constExprElementStorageBytes(self, expr) orelse return null;
    return switch (measure) {
        .storage_size_bits => std.math.mul(i64, element_bytes, 8) catch null,
        .sizeof_bytes, .c_sizeof_bytes => blk: {
            const count = constExprElementCount(self, expr) orelse return null;
            break :blk std.math.mul(i64, element_bytes, count) catch null;
        },
    };
}

fn constExprElementCount(self: *context.Context, expr: *ast.Expr) ?i64 {
    return switch (expr.*) {
        .identifier => |name| resolveArrayExtent(@ptrCast(self), name, null) orelse 1,
        .component => |comp| blk: {
            if (comp.has_parens) break :blk null;
            const base_count = constExprElementCount(self, comp.base) orelse 1;
            const component = constComponentInfo(self, comp) orelse break :blk null;
            const local_count = dimsElementCount(self, component.dims) orelse 1;
            break :blk std.math.mul(i64, base_count, local_count) catch null;
        },
        .array_constructor => |ctor| std.math.cast(i64, ctor.items.len) orelse null,
        else => if (resolve_expr.exprRank(self, expr) == 0) 1 else null,
    };
}

fn constExprElementStorageBytes(self: *context.Context, expr: *ast.Expr) ?i64 {
    return switch (expr.*) {
        .literal => |lit| switch (lit.kind) {
            .string, .hollerith => blk: {
                const bytes = literals.decodeLiteralBytes(lit, null) catch return null;
                break :blk std.math.cast(i64, bytes.?.len) orelse null;
            },
            else => typeSpecStorageBytes(self, literalTypeSpec(expr)),
        },
        .identifier => |name| blk: {
            const idx = symbols_mod.findSymbolIndex(self, name) orelse break :blk null;
            break :blk symbolElementStorageBytes(self, self.symbols.items[idx]);
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk null;
            const component = constComponentInfo(self, comp) orelse break :blk null;
            break :blk componentElementStorageBytes(self, component);
        },
        .array_constructor, .call_or_subscript, .substring, .dim_range, .unary, .binary, .complex_literal, .implied_do => blk: {
            const spec = resolve_expr.exprTypeSpec(self, expr) catch break :blk null;
            break :blk typeSpecStorageBytes(self, spec);
        },
    };
}

fn literalTypeSpec(expr: *ast.Expr) symbols.TypeSpec {
    return switch (expr.*) {
        .literal => |lit| switch (lit.kind) {
            .integer => .fromResolvedKind(.integer, .integer, null),
            .real => .fromResolvedKind(.real, if (evaluator.realLiteralHasDoublePrecisionHint(lit.text)) .double_precision else .real, null),
            .logical => .fromResolvedKind(.logical, .logical, null),
            .string, .hollerith => .fromResolvedKind(.character, .character, null),
            .assumed_size => .fromResolvedKind(.integer, .integer, null),
        },
        else => .fromResolvedKind(.integer, .integer, null),
    };
}

fn symbolElementStorageBytes(self: *context.Context, sym: symbols.Symbol) ?i64 {
    const direct = typeSpecStorageBytes(self, sym.type_spec) orelse return null;
    if (!(sym.is_pointer or sym.is_allocatable)) return direct;
    return descriptorStorageBytes(sym.dims.len);
}

fn typeSpecStorageBytes(self: *context.Context, spec: symbols.TypeSpec) ?i64 {
    return switch (spec.lowered_kind) {
        .integer, .logical => bitsToBytes(integerStorageBitsForTypeSpec(self, spec)),
        .real => bitsToBytes(realStorageBits(spec.kind_value) orelse 32),
        .double_precision => 8,
        .complex => bitsToBytes(complexStorageBits(spec.kind_value) orelse 64),
        .complex_double => 16,
        .character => blk: {
            const len = switch (spec.char_len_kind) {
                .constant => spec.char_len orelse break :blk null,
                .none => spec.char_len orelse 1,
                .assumed, .deferred => break :blk null,
            };
            const bytes_per_char = characterStorageBytes(spec.kind_value);
            const total = std.math.mul(usize, len, bytes_per_char) catch return null;
            break :blk std.math.cast(i64, total) orelse null;
        },
        .derived => blk: {
            if (isIsoCBindingHandleType(spec)) break :blk @sizeOf(usize);
            if (spec.polymorphic and spec.derived_type_name == null) break :blk @sizeOf(usize);
            const name = spec.derived_type_name orelse break :blk null;
            break :blk derivedTypeStorageBytes(self, name);
        },
    };
}

fn derivedTypeStorageBytes(self: *context.Context, name: []const u8) ?i64 {
    const derived = symbols_mod.lookupDerivedType(self, name) orelse return null;
    var size: usize = 0;
    var alignment: usize = 1;

    if (derived.parent_name) |parent_name| {
        const parent_size_i64 = derivedTypeStorageBytes(self, parent_name) orelse return null;
        const parent_size = std.math.cast(usize, parent_size_i64) orelse return null;
        const parent_alignment = derivedTypeAlignment(self, parent_name) orelse return null;
        size = alignForward(size, parent_alignment);
        size += parent_size;
        alignment = @max(alignment, parent_alignment);
    }

    for (derived.components) |component| {
        const info = componentStorageInfo(self, component) orelse return null;
        size = alignForward(size, info.alignment);
        size += info.storage_size;
        alignment = @max(alignment, info.alignment);
    }

    return std.math.cast(i64, alignForward(size, alignment)) orelse null;
}

fn derivedTypeAlignment(self: *context.Context, name: []const u8) ?usize {
    const derived = symbols_mod.lookupDerivedType(self, name) orelse return null;
    var alignment: usize = 1;
    if (derived.parent_name) |parent_name| {
        alignment = @max(alignment, derivedTypeAlignment(self, parent_name) orelse return null);
    }
    for (derived.components) |component| {
        const info = componentStorageInfo(self, component) orelse return null;
        alignment = @max(alignment, info.alignment);
    }
    return alignment;
}

const ComponentStorageInfo = struct {
    storage_size: usize,
    element_size: usize,
    alignment: usize,
};

fn componentStorageInfo(
    self: *context.Context,
    component: context.Context.DerivedTypeInfo.ComponentInfo,
) ?ComponentStorageInfo {
    const direct = componentDirectStorageInfo(self, component) orelse return null;
    if (!(component.pointer or component.allocatable)) return direct;
    return .{
        .storage_size = std.math.cast(usize, descriptorStorageBytes(component.dims.len)) orelse return null,
        .element_size = direct.element_size,
        .alignment = @max(@alignOf(usize), @alignOf(i64)),
    };
}

fn derivedComponentRawSlice(
    self: *context.Context,
    derived_name: []const u8,
    component_name: []const u8,
    raw: []const u8,
) ?[]const u8 {
    const derived = symbols_mod.lookupDerivedType(self, derived_name) orelse return null;
    var offset: usize = 0;
    var alignment: usize = 1;

    if (derived.parent_name) |parent_name| {
        const parent_size_i64 = derivedTypeStorageBytes(self, parent_name) orelse return null;
        const parent_size = std.math.cast(usize, parent_size_i64) orelse return null;
        const parent_alignment = derivedTypeAlignment(self, parent_name) orelse return null;
        offset = alignForward(offset, parent_alignment);
        alignment = @max(alignment, parent_alignment);
        if (std.ascii.eqlIgnoreCase(parent_name, component_name)) {
            if (offset + parent_size > raw.len) return null;
            return raw[offset .. offset + parent_size];
        }
        offset += parent_size;
    }

    for (derived.components) |component| {
        const info = componentStorageInfo(self, component) orelse return null;
        offset = alignForward(offset, info.alignment);
        if (std.ascii.eqlIgnoreCase(component.name, component_name)) {
            if (offset + info.storage_size > raw.len) return null;
            return raw[offset .. offset + info.storage_size];
        }
        offset += info.storage_size;
    }

    return null;
}

fn componentDirectStorageInfo(
    self: *context.Context,
    component: context.Context.DerivedTypeInfo.ComponentInfo,
) ?ComponentStorageInfo {
    const element_bytes_i64 = typeSpecStorageBytes(self, component.type_spec) orelse return null;
    const element_bytes = std.math.cast(usize, element_bytes_i64) orelse return null;
    const count = dimsElementCount(self, component.dims) orelse 1;
    const count_usize = std.math.cast(usize, count) orelse return null;
    return .{
        .storage_size = std.math.mul(usize, element_bytes, count_usize) catch return null,
        .element_size = element_bytes,
        .alignment = alignmentForTypeSpec(self, component.type_spec) orelse return null,
    };
}

fn componentElementStorageBytes(
    self: *context.Context,
    component: context.Context.DerivedTypeInfo.ComponentInfo,
) ?i64 {
    const info = componentStorageInfo(self, component) orelse return null;
    return std.math.cast(i64, info.element_size) orelse null;
}

fn constComponentInfo(
    self: *context.Context,
    comp: ast.ComponentExpr,
) ?context.Context.DerivedTypeInfo.ComponentInfo {
    const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch return null;
    if (base_spec.lowered_kind != .derived) return null;
    const derived_name = base_spec.derived_type_name orelse return null;
    return symbols_mod.lookupDerivedComponent(self, derived_name, comp.name);
}

fn dimsElementCount(self: *context.Context, dims: []*ast.Expr) ?i64 {
    if (dims.len == 0) return 1;
    var total: i64 = 1;
    for (dims) |dim_expr| {
        const extent = evalDimExtent(self, dim_expr) orelse return null;
        total = std.math.mul(i64, total, extent) catch return null;
    }
    return total;
}

fn integerStorageBitsForTypeSpec(self: *context.Context, spec: symbols.TypeSpec) i64 {
    const kind_value = spec.kind_value orelse return self.target_layout.default_integer_bits;
    if (kind_value <= 0) return self.target_layout.default_integer_bits;
    if (kind_value <= 16) return kind_value * 8;
    return @min(kind_value, 64);
}

fn realStorageBits(kind_value: ?i64) ?i64 {
    const value = kind_value orelse return 32;
    if (value <= 0) return 32;
    if (value <= 16) return value * 8;
    return value;
}

fn complexStorageBits(kind_value: ?i64) ?i64 {
    const value = kind_value orelse return 64;
    if (value <= 0) return 64;
    if (value <= 16) return value * 8;
    return value;
}

fn characterStorageBytes(kind_value: ?i64) usize {
    const value = kind_value orelse return 1;
    if (value <= 1) return 1;
    return std.math.cast(usize, value) orelse 1;
}

fn isIsoCBindingHandleType(spec: symbols.TypeSpec) bool {
    if (spec.lowered_kind != .derived) return false;
    const name = spec.derived_type_name orelse return false;
    return std.ascii.eqlIgnoreCase(name, "c_ptr") or std.ascii.eqlIgnoreCase(name, "c_funptr");
}

fn bitsToBytes(bits: i64) ?i64 {
    if (bits <= 0 or @mod(bits, 8) != 0) return null;
    return @divExact(bits, 8);
}

fn descriptorStorageBytes(rank: usize) i64 {
    if (rank == 0) return @sizeOf(usize);
    return @sizeOf(usize) + @as(i64, @intCast(rank * 3 * @sizeOf(i64)));
}

fn alignmentForTypeSpec(self: *context.Context, spec: symbols.TypeSpec) ?usize {
    return switch (spec.lowered_kind) {
        .integer, .logical => bitsAlignment(integerStorageBitsForTypeSpec(self, spec)),
        .real => bitsAlignment(realStorageBits(spec.kind_value) orelse return null),
        .double_precision => 8,
        .complex => switch (complexStorageBits(spec.kind_value) orelse return null) {
            64 => 4,
            128 => 8,
            else => null,
        },
        .complex_double => 8,
        .character => 1,
        .derived => blk: {
            if (spec.polymorphic and spec.derived_type_name == null) break :blk @alignOf(usize);
            const name = spec.derived_type_name orelse break :blk null;
            break :blk derivedTypeAlignment(self, name);
        },
    };
}

fn bitsAlignment(bits: i64) ?usize {
    const bytes = bitsToBytes(bits) orelse return null;
    return std.math.cast(usize, bytes) orelse null;
}

fn alignForward(value: usize, alignment: usize) usize {
    if (alignment <= 1) return value;
    return (value + alignment - 1) & ~(alignment - 1);
}

fn evalDimExtent(self: *context.Context, expr: *ast.Expr) ?i64 {
    return switch (expr.*) {
        .dim_range => |range| blk: {
            if (range.stride != null) break :blk null;
            const upper_val = evalConstInt(self, range.upper) orelse break :blk null;
            const lower_val = if (range.lower) |lower_expr| evalConstInt(self, lower_expr) orelse break :blk null else 1;
            if (upper_val < lower_val) break :blk 0;
            const diff = std.math.sub(i64, upper_val, lower_val) catch break :blk null;
            break :blk std.math.add(i64, diff, 1) catch null;
        },
        else => evalConstInt(self, expr),
    };
}

fn evalDimLower(self: *context.Context, expr: *ast.Expr) ?i64 {
    return switch (expr.*) {
        .dim_range => |range| if (range.lower) |lower_expr| evalConstInt(self, lower_expr) else 1,
        else => 1,
    };
}

fn evalConstInt(self: *context.Context, expr: *ast.Expr) ?i64 {
    const value = evalConst(self, expr) catch return null;
    return switch (value orelse return null) {
        .integer => |v| v,
        else => null,
    };
}

fn maybeBuiltinConstName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = std.ascii.toLower(name[0]);
    if (first != 'o' and first != 'i' and first != 'e') return false;
    // Current builtin constants are OUTPUT_UNIT / INPUT_UNIT / ERROR_UNIT.
    return name.len >= 8 and name.len <= 11;
}
