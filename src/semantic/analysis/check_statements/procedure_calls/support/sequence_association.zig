const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const common_diag = @import("../../../../../common/diagnostic.zig");
const catalog = @import("../../../../../common/error_catalog.zig");
const procedure_pass = @import("../../../../../common/procedure_pass.zig");
const free_form = @import("../../../../../frontend/free_form.zig");
const parser = @import("../../../../../frontend/parser/mod.zig");
const symbols = @import("../../../../symbol/mod.zig");
const procedure_inference = @import("../../../../split/api/procedure_inference.zig");
const context = @import("../../../context.zig");
const constants = @import("../../../resolve_const.zig");
const resolve_expr = @import("../../../resolve_expr.zig");
const resolve_symbols = @import("../../../resolve_symbols.zig");
const abstract_expr_use = @import("../../abstract_expr_use.zig");
const leaf_helpers = @import("../../leaf_helpers.zig");
const procedure_call_actual_traits = @import("../../procedure_call_actual_traits.zig");
const procedure_call_diagnostics = @import("../../procedure_call_diagnostics.zig");
const procedure_interfaces = @import("../../procedure_interfaces.zig");

pub const CheckError = anyerror;
const DiagnosticSource = procedure_call_diagnostics.DiagnosticSource;
const Advice = procedure_call_diagnostics.Advice;
const invalidArgumentAdvice = procedure_call_diagnostics.invalidArgumentAdvice;
const appendUniqueDeclSource = procedure_call_diagnostics.appendUniqueDeclSource;
const emitStructuredProcedureDiagnostic = procedure_call_diagnostics.emitStructuredProcedureDiagnostic;
const emitProcedureActualDiagnostic = procedure_call_diagnostics.emitProcedureActualDiagnostic;
const emitProcedureActualCallDiagnostic = procedure_call_diagnostics.emitProcedureActualCallDiagnostic;
const emitProcedureActualCallWarning = procedure_call_diagnostics.emitProcedureActualCallWarning;
const emitVariableDefinitionContextDiagnostic = procedure_call_diagnostics.emitVariableDefinitionContextDiagnostic;
const exprIsVariableDefinitionActual = procedure_call_diagnostics.exprIsVariableDefinitionActual;
const abstractPassedObjectTypeName = procedure_call_actual_traits.abstractPassedObjectTypeName;
const emitAbstractPassedObjectDiagnostic = procedure_call_actual_traits.emitAbstractPassedObjectDiagnostic;
const hasProcedureActualCallArg = procedure_call_actual_traits.hasProcedureActualCallArg;
const hasProcedureActualExprArg = procedure_call_actual_traits.hasProcedureActualExprArg;
const hasExplicitInterfaceSensitiveCallArg = procedure_call_actual_traits.hasExplicitInterfaceSensitiveCallArg;
const hasExplicitInterfaceSensitiveExprArg = procedure_call_actual_traits.hasExplicitInterfaceSensitiveExprArg;
const hasKeywordActualCallArg = procedure_call_actual_traits.hasKeywordActualCallArg;

const SectionClass = enum {
    scalar,
    full,
    nonfull_unit,
    strided_nonunit,
    unknown,
};


pub fn checkExplicitShapeElementSufficiency(
    self: *context.Context,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
) CheckError!void {
    const required = formalRequiredElementCount(formal) orelse return;
    const available = actualWholeArrayElementCount(self, actual_expr) orelse return;
    if (available < required) {
        return emitTooFewActualElementsDiagnostic(self, actual_expr, formal.name);
    }
}

pub fn formalRequiredElementCount(formal: context.Context.ProcedureSig.ArgSig) ?usize {
    if (formal.requires_descriptor or formal.shape_signature.len == 0) return null;
    if (formal.type_spec.lowered_kind == .character and formal.type_spec.char_len_kind == .assumed) return null;
    var total: usize = 1;
    for (formal.shape_signature) |extent_text| {
        const trimmed = std.mem.trim(u8, extent_text, " \t");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ":")) return null;
        const extent = std.fmt.parseInt(usize, trimmed, 10) catch return null;
        total = std.math.mul(usize, total, extent) catch return null;
    }
    return total;
}

fn actualWholeArrayElementCount(self: *context.Context, expr: *ast.Expr) ?usize {
    switch (expr.*) {
        .identifier => |name| {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse return null;
            return arrayElementCountForDims(self, self.symbols.items[idx].dims);
        },
        .component => |comp| {
            const component = componentInfoForExpr(self, comp) orelse return null;
            return arrayElementCountForDims(self, component.dims);
        },
        else => return null,
    }
}

const unknown_sequence_association_elements = std.math.maxInt(usize);

pub fn sequenceAssociationAvailableElements(self: *context.Context, expr: *ast.Expr) CheckError!?usize {
    switch (expr.*) {
        .identifier => |name| {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse return null;
            const dims = self.symbols.items[idx].dims;
            if (dims.len == 0) return scalarCharacterSequenceElementCount(self, expr);
            return arrayElementCountForDims(self, dims) orelse unknown_sequence_association_elements;
        },
        .call_or_subscript => |call| {
            const idx = resolve_symbols.findSymbolIndex(self, call.name) orelse return null;
            const sym = self.symbols.items[idx];
            if (sym.dims.len == 0) return null;
            const kind = self.ref_kind_index.get(@intFromPtr(expr)) orelse
                (if (sym.dims.len > 0) symbols.ResolvedRefKind.subscript else symbols.ResolvedRefKind.call);
            if (kind != .subscript or call.args.len != sym.dims.len) return null;
            if (sectionHasArraySelection(self, call.args)) {
                if (sectionIsDefinitelyNoncontiguous(self, sym.dims, call.args)) return null;
                return sectionElementCount(self, sym.dims, call.args) orelse unknown_sequence_association_elements;
            }
            const total = arrayElementCountForDims(self, sym.dims) orelse return unknown_sequence_association_elements;
            const offset = linearSubscriptOffset(self, sym.dims, call.args) orelse return unknown_sequence_association_elements;
            return total -% offset;
        },
        .component => |comp| {
            const component = componentInfoForExpr(self, comp) orelse return null;
            if (component.dims.len == 0) return null;
            if (comp.args.len == 0) {
                return arrayElementCountForDims(self, component.dims) orelse unknown_sequence_association_elements;
            }
            if (comp.args.len != component.dims.len) return null;
            if (sectionHasArraySelection(self, comp.args)) {
                if (sectionIsDefinitelyNoncontiguous(self, component.dims, comp.args)) return null;
                return sectionElementCount(self, component.dims, comp.args) orelse unknown_sequence_association_elements;
            }
            const total = arrayElementCountForDims(self, component.dims) orelse return unknown_sequence_association_elements;
            const offset = linearSubscriptOffset(self, component.dims, comp.args) orelse return unknown_sequence_association_elements;
            return total -% offset;
        },
        else => return scalarCharacterSequenceElementCount(self, expr),
    }
}

fn scalarCharacterSequenceElementCount(self: *context.Context, expr: *ast.Expr) ?usize {
    resolve_expr.resolveExpr(self, expr) catch return null;
    if (resolve_expr.exprRank(self, expr) != 0) return null;
    const spec = resolve_expr.exprTypeSpec(self, expr) catch return null;
    if (spec.lowered_kind != .character) return null;

    return switch (spec.char_len_kind) {
        .constant => spec.char_len orelse 1,
        .none => spec.char_len orelse 1,
        .assumed, .deferred => blk: {
            const value = constants.evalConst(self, expr) catch break :blk null;
            break :blk switch (value orelse break :blk null) {
                .string => |bytes| std.unicode.utf8CountCodepoints(bytes) catch bytes.len,
                else => null,
            };
        },
    };
}

pub fn componentInfoForExpr(
    self: *context.Context,
    comp: ast.ComponentExpr,
) ?context.Context.DerivedTypeInfo.ComponentInfo {
    const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch return null;
    if (base_spec.lowered_kind != .derived) return null;
    const derived_name = base_spec.derived_type_name orelse return null;
    return resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name);
}

pub fn componentActualTypeCompatibleViaMetadata(
    self: *context.Context,
    formal_spec: symbols.TypeSpec,
    actual_expr: *ast.Expr,
    comptime deps: anytype,
) bool {
    const comp = switch (actual_expr.*) {
        .component => |comp_expr| comp_expr,
        else => return false,
    };
    const info = componentInfoForExpr(self, comp) orelse return false;
    return deps.dummyArgTypeCompatible(self, formal_spec, info.type_spec);
}

pub fn bindCallActualsToFormals(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    args: []const ast.CallArg,
) ![]?ast.ActualArgExpr {
    const bound = try self.arena.alloc(?ast.ActualArgExpr, sig.args.len);
    @memset(bound, null);

    var next_formal: usize = 0;
    for (args) |arg| {
        if (arg != .expr) continue;
        const actual = arg.expr;
        if (actual.keyword != null) continue;
        while (next_formal < sig.args.len and bound[next_formal] != null) : (next_formal += 1) {}
        if (next_formal >= sig.args.len) break;
        bound[next_formal] = actual;
        next_formal += 1;
    }

    for (args) |arg| {
        if (arg != .expr) continue;
        const actual = arg.expr;
        const keyword = actual.keyword orelse continue;
        for (sig.args, 0..) |formal, idx| {
            if (!std.ascii.eqlIgnoreCase(formal.name, keyword)) continue;
            bound[idx] = actual;
            break;
        }
    }

    return bound;
}

fn arrayElementCountForDims(self: *context.Context, dims: []const *ast.Expr) ?usize {
    if (dims.len == 0) return null;
    var total: usize = 1;
    for (dims) |dim| {
        const extent_i64 = dimensionExtent(self, dim) orelse return null;
        if (extent_i64 < 0) return null;
        const extent: usize = @intCast(extent_i64);
        total = std.math.mul(usize, total, extent) catch return null;
    }
    return total;
}

fn dimensionExtent(self: *context.Context, dim: *ast.Expr) ?i64 {
    return switch (dim.*) {
        .dim_range => |range| blk: {
            if (range.upper.* == .literal and range.upper.literal.kind == .assumed_size) break :blk null;
            const upper = constIntValue(self, range.upper) orelse break :blk null;
            const lower = if (range.lower) |lower_expr| constIntValue(self, lower_expr) orelse break :blk null else 1;
            const stride = if (range.stride) |stride_expr| constIntValue(self, stride_expr) orelse break :blk null else 1;
            break :blk tripletExtent(lower, upper, stride);
        },
        else => constIntValue(self, dim),
    };
}

pub fn dimensionLowerBound(self: *context.Context, dim: *ast.Expr) ?i64 {
    return switch (dim.*) {
        .dim_range => |range| if (range.lower) |lower_expr| constIntValue(self, lower_expr) else 1,
        else => 1,
    };
}

fn linearSubscriptOffset(self: *context.Context, dims: []const *ast.Expr, args: []const *ast.Expr) ?usize {
    if (args.len == 0 or args.len != dims.len) return null;
    var offset: usize = 0;
    var stride: usize = 1;
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        if (args[idx].* == .dim_range) return null;
        const index_value = constIntValue(self, args[idx]) orelse return null;
        const lower = dimensionLowerBound(self, dims[idx]) orelse return null;
        const extent_i64 = dimensionExtent(self, dims[idx]) orelse return null;
        if (extent_i64 <= 0) return null;
        const extent: usize = @intCast(extent_i64);
        const relative = index_value - lower;
        if (relative < 0) return null;
        const rel_usize: usize = @intCast(relative);
        if (rel_usize >= extent) return null;
        offset = std.math.add(usize, offset, std.math.mul(usize, rel_usize, stride) catch return null) catch return null;
        if (idx + 1 < args.len) {
            stride = std.math.mul(usize, stride, extent) catch return null;
        }
    }
    return offset;
}

fn sectionHasArraySelection(self: *context.Context, args: []const *ast.Expr) bool {
    for (args) |arg| {
        if (arg.* == .dim_range) return true;
        if (resolve_expr.exprRank(self, arg) != 0) return true;
    }
    return false;
}

fn sectionElementCount(self: *context.Context, dims: []const *ast.Expr, args: []const *ast.Expr) ?usize {
    if (args.len == 0 or args.len != dims.len) return null;
    var total: usize = 1;
    for (args, 0..) |arg, idx| {
        const extent_i64 = switch (arg.*) {
            .dim_range => |range| rangeExtent(self, dims[idx], range) orelse return null,
            else => if (resolve_expr.exprRank(self, arg) == 0) 1 else return null,
        };
        if (extent_i64 < 0) return null;
        const extent: usize = @intCast(extent_i64);
        total = std.math.mul(usize, total, extent) catch return null;
    }
    return total;
}

pub fn constIntValue(self: *context.Context, expr: *ast.Expr) ?i64 {
    resolve_expr.resolveExpr(self, expr) catch return null;
    const value = constants.evalConst(self, expr) catch return null;
    return switch (value orelse return null) {
        .integer => |int_value| int_value,
        else => null,
    };
}

fn tripletExtent(lower: i64, upper: i64, stride: i64) ?i64 {
    if (stride == 0) return null;
    if (stride > 0) {
        if (upper < lower) return 0;
        return @divTrunc(upper - lower, stride) + 1;
    }
    if (upper > lower) return 0;
    return @divTrunc(lower - upper, -stride) + 1;
}

pub fn emitTooFewActualElementsDiagnostic(
    self: *context.Context,
    expr: *ast.Expr,
    formal_name: []const u8,
) CheckError {
    const message = std.fmt.allocPrint(
        self.arena,
        "Actual argument contains too few elements for dummy argument '{s}'",
        .{formal_name},
    ) catch "Actual argument contains too few elements for dummy argument";
    return emitProcedureActualDiagnostic(self, expr, error.InvalidArgumentCount, message);
}

pub fn getLowercaseMapPtr(
    comptime T: type,
    map: *std.StringHashMap(T),
    name: []const u8,
) ?*T {
    var key_buf: [128]u8 = undefined;
    if (name.len <= key_buf.len) {
        for (name, 0..) |ch, i| key_buf[i] = std.ascii.toLower(ch);
        return map.getPtr(key_buf[0..name.len]);
    }
    var it = map.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr;
    }
    return null;
}


pub fn sectionIsDefinitelyNoncontiguous(
    self: *context.Context,
    dims: []const *ast.Expr,
    args: []const *ast.Expr,
) bool {
    if (args.len == 0 or args.len != dims.len) return false;

    var saw_nonfull_idx: ?usize = null;
    for (args, 0..) |arg, idx| {
        const class = classifySectionArg(self, dims[idx], arg);
        switch (class) {
            .scalar, .full => {},
            .nonfull_unit => {
                if (saw_nonfull_idx != null) return true;
                saw_nonfull_idx = idx;
            },
            .strided_nonunit => return true,
            .unknown => return false,
        }
    }

    if (saw_nonfull_idx) |idx| {
        var later = idx + 1;
        while (later < args.len) : (later += 1) {
            const later_class = classifySectionArg(self, dims[later], args[later]);
            if (later_class != .scalar) return true;
        }
    }
    return false;
}

fn classifySectionArg(
    self: *context.Context,
    dim: *ast.Expr,
    arg: *ast.Expr,
) SectionClass {
    return switch (arg.*) {
        .dim_range => |range| classifyDimRangeSection(self, dim, range),
        else => if (resolve_expr.exprRank(self, arg) == 0) .scalar else .unknown,
    };
}

fn classifyDimRangeSection(
    self: *context.Context,
    dim: *ast.Expr,
    range: ast.DimRange,
) SectionClass {
    const extent = rangeExtent(self, dim, range) orelse return .unknown;
    if (extent <= 1) return .full;

    const stride = if (range.stride) |stride_expr| constIntValue(self, stride_expr) orelse return .unknown else 1;
    if (stride == 0) return .unknown;
    if (stride != 1) return .strided_nonunit;

    if (rangeMatchesWholeDimension(self, dim, range)) return .full;
    return .nonfull_unit;
}

fn rangeMatchesWholeDimension(
    self: *context.Context,
    dim: *ast.Expr,
    range: ast.DimRange,
) bool {
    const lower = if (range.lower) |lower_expr| constIntValue(self, lower_expr) orelse return false else 1;
    const dim_lower = dimensionLowerBound(self, dim) orelse return false;
    if (lower != dim_lower) return false;

    if (range.upper.* == .literal and range.upper.literal.kind == .assumed_size) return true;

    const upper = constIntValue(self, range.upper) orelse return false;
    const dim_extent = dimensionExtent(self, dim) orelse return false;
    if (dim_extent < 0) return false;
    const dim_upper = dim_lower + dim_extent - 1;
    return upper == dim_upper;
}

pub fn rangeExtent(self: *context.Context, dim: *ast.Expr, range: ast.DimRange) ?i64 {
    const upper = (blk: {
        if (range.upper.* == .literal and range.upper.literal.kind == .assumed_size) {
            const dim_lower = dimensionLowerBound(self, dim) orelse break :blk null;
            const dim_extent = dimensionExtent(self, dim) orelse break :blk null;
            if (dim_extent < 0) break :blk null;
            break :blk dim_lower + dim_extent - 1;
        }
        break :blk constIntValue(self, range.upper) orelse return null;
    }) orelse return null;
    const lower = if (range.lower) |lower_expr| constIntValue(self, lower_expr) orelse return null else 1;
    const stride = if (range.stride) |stride_expr| constIntValue(self, stride_expr) orelse return null else 1;
    return tripletExtent(lower, upper, stride);
}

