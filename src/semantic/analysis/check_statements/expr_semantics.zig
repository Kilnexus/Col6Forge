const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const symbols = @import("../../symbol/mod.zig");
const context = @import("../context.zig");
const constants = @import("../resolve_const.zig");
const resolve_expr = @import("../resolve_expr.zig");
const type_helpers = @import("../resolve_expr/type_helpers.zig");
const resolve_calls = @import("../resolve_expr/calls.zig");
const resolve_symbols = @import("../resolve_symbols.zig");
const literal_utils = @import("../../evaluator/literals.zig");
const leaf_helpers = @import("leaf_helpers.zig");
const literal_substring = @import("literal_substring.zig");
const static_shapes = @import("static_shapes.zig");
const procedure_interfaces = @import("procedure_interfaces.zig");
const procedure_calls = @import("procedure_calls.zig");
const type_bound_generics = @import("../type_bound_generics.zig");
const assumed_size = @import("../assumed_size.zig");
const array_constructor_items = @import("array_constructor_items.zig");
const expr_attributes = @import("../expr_attributes.zig");
const expr_diagnostics = @import("../expr_diagnostics.zig");
const max_min_conformance = @import("max_min_conformance.zig");
const boz_intrinsic_constraints = @import("boz_intrinsic_constraints.zig");
const constant_expr = @import("constant_expr.zig");
const dim_intrinsics = @import("dim_intrinsics.zig");
const source_shape = @import("source_shape.zig");
const ResolvedRefKind = symbols.ResolvedRefKind;
pub const CheckError = anyerror;

pub fn checkExpr(self: *context.Context, expr: *ast.Expr, comptime deps: anytype) CheckError!void {
    _ = try checkExprType(self, expr, deps);
}

pub fn checkLogicalConditionExpr(self: *context.Context, expr: *ast.Expr, comptime deps: anytype) CheckError!void {
    const ty = try checkExprType(self, expr, deps);
    if (ty != .logical) {
        self.setCurrentSource(self.sourceForExpr(expr));
        return error.InvalidConditionType;
    }
}

pub fn checkSpecialCallConstraints(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    if (!std.ascii.eqlIgnoreCase(name, "move_alloc")) return;
    if (args.len == 0) return;
    if (!exprIsAllocatableEntity(self, args[0])) {
        return emitExprConstraintDiagnostic(self, args[0], "must be ALLOCATABLE");
    }
    if (args.len > 1 and !exprIsAllocatableEntity(self, args[1])) {
        return emitExprConstraintDiagnostic(self, args[1], "must be ALLOCATABLE");
    }
}

pub fn checkSpecialExprCallConstraints(
    self: *context.Context,
    call_expr: *ast.Expr,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    try checkInquiryDimArg(self, name, args);
    try dim_intrinsics.checkMaxMinDimArgs(self, name, args);
    try checkAssumedSizeInquiryArrayArg(self, name, args);
    try checkStaticMatmulConformance(self, call_expr, name, args);
    try max_min_conformance.checkStaticMaxMinConformance(self, name, args);
    try boz_intrinsic_constraints.checkExprCall(self, name, args);
    try checkLegacyWidecharExprCallConstraints(self, name, args);
    if (intrinsicRequiresDoublePrecisionArgs(name)) {
        for (args) |arg| {
            const spec = try resolve_expr.exprTypeSpec(self, arg);
            if (spec.lowered_kind != .double_precision) {
                return emitExprConstraintDiagnostic(self, arg, "must be double precision");
            }
        }
    }
    if (std.ascii.eqlIgnoreCase(name, "dprod")) {
        for (args) |arg| {
            const spec = try resolve_expr.exprTypeSpec(self, arg);
            if (spec.lowered_kind != .real) {
                return emitExprConstraintDiagnostic(self, arg, "must be default real");
            }
        }
    }
    if (std.ascii.eqlIgnoreCase(name, "parity") or std.ascii.eqlIgnoreCase(name, "norm2")) {
        if (args.len > 1 and resolve_expr.exprRank(self, args[1]) != 0) {
            return emitExprConstraintDiagnostic(self, args[1], "must be a scalar");
        }
    }
    if (std.ascii.eqlIgnoreCase(name, "allocated")) {
        if (args.len > 0 and !exprIsAllocatableEntity(self, args[0])) {
            return emitExprConstraintDiagnostic(self, args[0], "must be ALLOCATABLE");
        }
        if (args.len == 1) {
            if (inferFirstKeywordFromCallSource(self, call_expr, name)) |keyword| {
                if (std.ascii.eqlIgnoreCase(keyword, "scalar") and resolve_expr.exprRank(self, args[0]) != 0) {
                    return emitExprConstraintDiagnostic(self, args[0], "Scalar entity required");
                }
                if (std.ascii.eqlIgnoreCase(keyword, "array") and resolve_expr.exprRank(self, args[0]) == 0) {
                    return emitExprConstraintDiagnostic(self, args[0], "Array entity required");
                }
            }
        }
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "associated")) {
        if (args.len > 0 and !exprIsPointerEntity(self, args[0])) {
            return emitExprConstraintDiagnostic(self, args[0], "must be a POINTER");
        }
    }
    if (std.ascii.eqlIgnoreCase(name, "c_associated")) {
        if (args.len < 2) return;
        const first_spec = try resolve_expr.exprTypeSpec(self, args[0]);
        const second_spec = try resolve_expr.exprTypeSpec(self, args[1]);
        const first_family = isoCBindingHandleFamily(first_spec);
        const second_family = isoCBindingHandleFamily(second_spec);
        if (first_family == null or second_family == null or first_family.? == second_family.?) return;

        const expected_name = first_spec.derived_type_name orelse "c_ptr";
        const actual_name = second_spec.derived_type_name orelse "c_funptr";
        const message = std.fmt.allocPrint(
            self.arena,
            "Argument C_PTR_2 at (1) to C_ASSOCIATED shall have the same type as C_PTR_1, found TYPE({s}) instead of TYPE({s}).",
            .{ actual_name, expected_name },
        ) catch "Argument C_PTR_2 to C_ASSOCIATED shall have the same type as C_PTR_1.";
        return emitExprConstraintDiagnostic(self, args[1], message);
    }
}

fn checkAssumedSizeInquiryArrayArg(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    if (args.len == 0) return;
    if (std.ascii.eqlIgnoreCase(name, "shape")) {
        if (assumed_size.exprNeedsExplicitLastUpperBound(self, args[0])) {
            return assumed_size.emitExprDiagnostic(self, args[0], assumed_size.shapeAssumedSizeMessage(self, args[0]));
        }
        return;
    }
    if (!(std.ascii.eqlIgnoreCase(name, "size") or std.ascii.eqlIgnoreCase(name, "ubound"))) return;
    if (!assumed_size.exprNeedsExplicitLastUpperBound(self, args[0])) return;

    if (args.len < 2) {
        return assumed_size.emitExprDiagnostic(self, args[0], "upper bound in the last dimension");
    }
    const dim_value = (try constants.evalConst(self, args[1])) orelse {
        return emitExprConstraintDiagnostic(self, args[1], "Cannot simplify expression");
    };
    const dim_int = switch (dim_value) {
        .integer => |value| value,
        else => return,
    };
    const array_rank = assumed_size.exprAssumedSizeRank(self, args[0]) orelse resolve_expr.exprRank(self, args[0]);
    if (dim_int == @as(i64, @intCast(array_rank))) {
        return emitExprConstraintDiagnostic(self, args[1], "is not a valid dimension index");
    }
}

fn checkInquiryDimArg(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    const needs_dim_check =
        std.ascii.eqlIgnoreCase(name, "size") or
        std.ascii.eqlIgnoreCase(name, "lbound") or
        std.ascii.eqlIgnoreCase(name, "ubound");
    if (!needs_dim_check or args.len < 2) return;
    if (resolve_expr.exprRank(self, args[1]) != 0) {
        return emitExprConstraintDiagnostic(self, args[1], "must be a scalar");
    }
    const dim_spec = try resolve_expr.exprTypeSpec(self, args[1]);
    if (dim_spec.lowered_kind != .integer) {
        return emitExprConstraintDiagnostic(self, args[1], "must be INTEGER");
    }
    const dim_value = (try constants.evalConst(self, args[1])) orelse return;
    const dim_int = switch (dim_value) {
        .integer => |value| value,
        else => return,
    };
    const array_rank = resolve_expr.exprRank(self, args[0]);
    if (dim_int < 1 or dim_int > array_rank) {
        return emitExprConstraintDiagnostic(self, args[1], "is not a valid dimension index");
    }
}

fn checkStaticMatmulConformance(
    self: *context.Context,
    call_expr: *ast.Expr,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    if (!std.ascii.eqlIgnoreCase(name, "matmul")) return;
    if (args.len != 2) return;

    const lhs_rank = resolve_expr.exprRank(self, args[0]);
    const rhs_rank = resolve_expr.exprRank(self, args[1]);
    if (!((lhs_rank == 1 or lhs_rank == 2) and (rhs_rank == 1 or rhs_rank == 2))) return;

    const lhs_shape = static_shapes.staticShapeForExpr(self, args[0]) orelse return;
    const rhs_shape = static_shapes.staticShapeForExpr(self, args[1]) orelse return;

    const lhs_inner = if (lhs_rank == 1) lhs_shape[0] else lhs_shape[1];
    const rhs_inner = rhs_shape[0];
    if (lhs_inner != rhs_inner) {
        return emitExprConstraintDiagnostic(self, call_expr, "Different shape");
    }
}

fn checkStaticElementalBinaryConformance(
    self: *context.Context,
    expr_node: *ast.Expr,
    bin: ast.BinaryExpr,
) CheckError!void {
    const left_shape = static_shapes.staticShapeForExpr(self, bin.left) orelse return;
    const right_shape = static_shapes.staticShapeForExpr(self, bin.right) orelse return;
    if (left_shape.len != right_shape.len) {
        return emitExprConstraintDiagnostic(self, expr_node, "not conformable");
    }
    for (left_shape, right_shape) |lhs, rhs| {
        if (lhs != rhs) return emitExprConstraintDiagnostic(self, expr_node, "not conformable");
    }
}

fn inferFirstKeywordFromCallSource(self: *context.Context, call_expr: *ast.Expr, callee_name: []const u8) ?[]const u8 {
    const source = self.sourceForExpr(call_expr) orelse return null;
    const line = source.text;
    const name_pos = std.ascii.indexOfIgnoreCase(line, callee_name) orelse return null;
    var pos = name_pos + callee_name.len;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos >= line.len or line[pos] != '(') return null;
    pos += 1;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    const start = pos;
    while (pos < line.len and isIdentifierChar(line[pos])) : (pos += 1) {}
    if (start == pos) return null;
    const keyword = line[start..pos];
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos >= line.len or line[pos] != '=') return null;
    return keyword;
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_';
}

fn checkLegacyWidecharExprCallConstraints(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    const conversion_style =
        std.ascii.eqlIgnoreCase(name, "getcwd") or
        std.ascii.eqlIgnoreCase(name, "system");
    const char_positions: ?[]const usize = blk: {
        if (std.ascii.eqlIgnoreCase(name, "access")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "chdir")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "chmod")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "fget")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "fgetc")) break :blk &.{1};
        if (std.ascii.eqlIgnoreCase(name, "fput")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "fputc")) break :blk &.{1};
        if (std.ascii.eqlIgnoreCase(name, "getcwd")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "hostnm")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "link")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "lstat")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "stat")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "rename")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "symlnk")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "system")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "unlink")) break :blk &.{0};
        break :blk null;
    };
    if (char_positions) |positions| {
        for (positions) |pos| {
            if (pos >= args.len) continue;
            if (!exprIsScalarCharacterKindOne(self, args[pos])) {
                return emitWidecharExprDiagnostic(self, args[pos], conversion_style);
            }
        }
    }
}

fn exprIsScalarCharacterKindOne(self: *context.Context, expr_node: *ast.Expr) bool {
    if (resolve_expr.exprRank(self, expr_node) != 0) return false;
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return false;
    if (spec.lowered_kind != .character) return false;
    return spec.kind_value == null or spec.kind_value.? == 1;
}

fn typeStringForCharacterActual(self: *context.Context, expr_node: *ast.Expr) []const u8 {
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return "CHARACTER(*)";
    if (spec.lowered_kind != .character) return "CHARACTER(*)";
    const len_text = if (spec.char_len) |len|
        std.fmt.allocPrint(self.arena, "{d}", .{len}) catch "*"
    else
        "*";
    const kind_value = spec.kind_value orelse 1;
    return std.fmt.allocPrint(self.arena, "CHARACTER({s},{d})", .{ len_text, kind_value }) catch "CHARACTER(*)";
}

fn emitWidecharExprDiagnostic(self: *context.Context, expr_node: *ast.Expr, use_conversion_text: bool) CheckError {
    const message = if (use_conversion_text)
        std.fmt.allocPrint(self.arena, "'{s}' to 'CHARACTER(*)'", .{typeStringForCharacterActual(self, expr_node)}) catch "character kind mismatch"
    else
        "must be of kind 1";
    return emitExprConstraintDiagnostic(self, expr_node, message);
}

fn validateCharacterLiteralRepresentability(
    self: *context.Context,
    expr_node: *ast.Expr,
    lit: ast.Literal,
) CheckError!void {
    if (!self.fbackslash or lit.kind != .string) return;
    const spec = try resolve_expr.exprTypeSpec(self, expr_node);
    if (spec.lowered_kind != .character) return;
    const kind_value = spec.kind_value orelse 1;
    const cp = literal_utils.firstBackslashEscapeExceedingCharacterKind(lit.text, kind_value) orelse return;
    const source = self.sourceForExpr(expr_node) orelse ast.SourceRef{};
    const message = std.fmt.allocPrint(
        self.arena,
        "Unicode character U+{X} is not representable in character kind {d}",
        .{ cp, kind_value },
    ) catch "is not representable";
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        source.text,
    );
    return error.AssignmentTypeMismatch;
}

fn validateLogicalLiteralKind(
    self: *context.Context,
    expr_node: *ast.Expr,
    lit: ast.Literal,
) CheckError!void {
    if (lit.kind != .logical) return;
    const kind_value = type_helpers.integerLiteralKindValue(lit.text) orelse return;
    if (kind_value == 1 or kind_value == 2 or kind_value == 4 or kind_value == 8) return;
    return emitExprConstraintDiagnostic(self, expr_node, "kind for logical constant is not supported");
}

fn intrinsicRequiresDoublePrecisionArgs(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "dabs") or
        std.ascii.eqlIgnoreCase(name, "dacos") or
        std.ascii.eqlIgnoreCase(name, "dacosh") or
        std.ascii.eqlIgnoreCase(name, "dasin") or
        std.ascii.eqlIgnoreCase(name, "dasinh") or
        std.ascii.eqlIgnoreCase(name, "datan") or
        std.ascii.eqlIgnoreCase(name, "datan2") or
        std.ascii.eqlIgnoreCase(name, "datanh") or
        std.ascii.eqlIgnoreCase(name, "dbesj0") or
        std.ascii.eqlIgnoreCase(name, "dbesj1") or
        std.ascii.eqlIgnoreCase(name, "dbesy0") or
        std.ascii.eqlIgnoreCase(name, "dbesy1") or
        std.ascii.eqlIgnoreCase(name, "dcos") or
        std.ascii.eqlIgnoreCase(name, "dcosh") or
        std.ascii.eqlIgnoreCase(name, "ddim") or
        std.ascii.eqlIgnoreCase(name, "derf") or
        std.ascii.eqlIgnoreCase(name, "derfc") or
        std.ascii.eqlIgnoreCase(name, "dexp") or
        std.ascii.eqlIgnoreCase(name, "dgamma") or
        std.ascii.eqlIgnoreCase(name, "dlgama") or
        std.ascii.eqlIgnoreCase(name, "dlog") or
        std.ascii.eqlIgnoreCase(name, "dlog10") or
        std.ascii.eqlIgnoreCase(name, "dmod") or
        std.ascii.eqlIgnoreCase(name, "dsign") or
        std.ascii.eqlIgnoreCase(name, "dsin") or
        std.ascii.eqlIgnoreCase(name, "dsinh") or
        std.ascii.eqlIgnoreCase(name, "dsqrt") or
        std.ascii.eqlIgnoreCase(name, "dtan") or
        std.ascii.eqlIgnoreCase(name, "dtanh");
}

fn isoCBindingHandleFamily(spec: symbols.TypeSpec) ?enum { c_ptr, c_funptr } {
    if (spec.lowered_kind != .derived) return null;
    const name = spec.derived_type_name orelse return null;
    var lower_buf: [128]u8 = undefined;
    if (name.len > lower_buf.len) return null;
    for (name, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const lower = lower_buf[0..name.len];
    if (std.mem.indexOf(u8, lower, "c_funptr") != null) return .c_funptr;
    if (std.mem.indexOf(u8, lower, "c_ptr") != null) return .c_ptr;
    return null;
}

pub fn checkExprType(self: *context.Context, expr: *ast.Expr, comptime deps: anytype) CheckError!ast.TypeKind {
    switch (expr.*) {
        .identifier => return try resolve_expr.exprType(self, expr),
        .literal => |lit| {
            try validateCharacterLiteralRepresentability(self, expr, lit);
            try validateLogicalLiteralKind(self, expr, lit);
            return try resolve_expr.exprType(self, expr);
        },
        .array_constructor => |ctor| {
            for (ctor.items) |item| _ = try checkExprType(self, item, deps);
            try array_constructor_items.checkAbstractItems(self, expr, ctor.items);
            try array_constructor_items.checkTypedItems(self, expr, ctor, deps);
            return try resolve_expr.exprType(self, expr);
        },
        .unary => |un| {
            _ = try checkExprType(self, un.expr, deps);
            return try resolve_expr.exprType(self, expr);
        },
        .binary => |bin| {
            _ = try checkExprType(self, bin.left, deps);
            _ = try checkExprType(self, bin.right, deps);
            try constant_expr.rejectDivisionByZero(self, expr, bin, deps);
            try checkStaticElementalBinaryConformance(self, expr, bin);
            return try resolve_expr.exprType(self, expr);
        },
        .complex_literal => |lit| {
            _ = try checkExprType(self, lit.real, deps);
            _ = try checkExprType(self, lit.imag, deps);
            return try resolve_expr.exprType(self, expr);
        },
        .dim_range => |range| {
            if (range.lower) |lower| {
                const lower_ty = try checkExprType(self, lower, deps);
                if (!procedure_calls.isIntegerLike(lower_ty)) {
                    self.setCurrentSource(self.sourceForExpr(lower));
                    return error.InvalidSubscript;
                }
            }
            const upper_ty = try checkExprType(self, range.upper, deps);
            if (!procedure_calls.isIntegerLike(upper_ty)) {
                self.setCurrentSource(self.sourceForExpr(range.upper));
                return error.InvalidSubscript;
            }
            if (range.stride) |stride| {
                const stride_ty = try checkExprType(self, stride, deps);
                if (!procedure_calls.isIntegerLike(stride_ty)) {
                    self.setCurrentSource(self.sourceForExpr(stride));
                    return error.InvalidSubscript;
                }
                try constant_expr.rejectZeroStride(self, stride);
            }
            return .integer;
        },
        .substring => |sub| {
            const resolved_ty = try resolve_expr.exprType(self, expr);
            if (resolved_ty != .character) {
                if (sub.args.len != 0) {
                    self.setCurrentSource(self.sourceForExpr(expr));
                    return error.InvalidSubscript;
                }
                if (sub.start) |start_expr| {
                    const start_ty = try checkExprType(self, start_expr, deps);
                    if (!procedure_calls.isIntegerLike(start_ty)) {
                        self.setCurrentSource(self.sourceForExpr(start_expr));
                        return error.InvalidSubscript;
                    }
                }
                if (sub.end) |end_expr| {
                    const end_ty = try checkExprType(self, end_expr, deps);
                    if (!procedure_calls.isIntegerLike(end_ty)) {
                        self.setCurrentSource(self.sourceForExpr(end_expr));
                        return error.InvalidSubscript;
                    }
                }
                return resolved_ty;
            }
            for (sub.args) |arg| _ = try checkExprType(self, arg, deps);
            if (sub.start) |start| {
                const start_ty = try checkExprType(self, start, deps);
                if (!procedure_calls.isIntegerLike(start_ty)) {
                    self.setCurrentSource(self.sourceForExpr(start));
                    return error.InvalidSubscript;
                }
            }
            if (sub.end) |end_expr| {
                const end_ty = try checkExprType(self, end_expr, deps);
                if (!procedure_calls.isIntegerLike(end_ty)) {
                    self.setCurrentSource(self.sourceForExpr(end_expr));
                    return error.InvalidSubscript;
                }
            }
            return .character;
        },
        .component => |comp| {
            _ = try checkExprType(self, comp.base, deps);
            const base_spec = try resolve_expr.exprTypeSpec(self, comp.base);
            if (resolve_calls.pseudoComponentInfo(base_spec, comp.name) != null) {
                if (comp.has_parens or comp.args.len != 0) {
                    self.setCurrentSource(self.sourceForExpr(expr));
                    return error.InvalidSubscript;
                }
                return try resolve_expr.exprType(self, expr);
            }
            if (base_spec.lowered_kind != .derived) {
                self.setCurrentSource(self.sourceForExpr(comp.base));
                return error.InvalidSubscript;
            }
            const derived_name = base_spec.derived_type_name orelse return error.InvalidSubscript;
            if (resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name)) |component| {
                if (component.procedure) {
                    if (!comp.has_parens) return try resolve_expr.exprType(self, expr);
                    try procedure_calls.checkProcedureComponent(self, comp.base, component, comp.args, false, .{
                        .dummyArgTypeCompatible = deps.dummyArgTypeCompatible,
                    });
                    return try resolve_expr.exprType(self, expr);
                }
                if (resolve_calls.isCharacterComponentSubstringRef(component, comp)) {
                    try resolve_calls.validateCharacterComponentSubstringArgs(self, expr, component.dims, comp.args, .{
                        .resolvedExprType = resolve_expr.exprType,
                    });
                    return .character;
                }
                if (component.dims.len == 0 and comp.args.len != 0) {
                    self.setCurrentSource(self.sourceForExpr(expr));
                    return error.InvalidSubscript;
                }
                if (component.dims.len != 0 and comp.args.len != 0 and comp.args.len != component.dims.len) {
                    self.setCurrentSource(self.sourceForExpr(expr));
                    return error.InvalidSubscript;
                }
                for (comp.args) |arg| {
                    switch (arg.*) {
                        .dim_range => |range| {
                            if (range.lower) |lower| {
                                const lower_ty = try checkExprType(self, lower, deps);
                                if (!procedure_calls.isIntegerLike(lower_ty)) {
                                    self.setCurrentSource(self.sourceForExpr(lower));
                                    return error.InvalidSubscript;
                                }
                            }
                            if (!(range.upper.* == .literal and range.upper.literal.kind == .assumed_size)) {
                                const upper_ty = try checkExprType(self, range.upper, deps);
                                if (!procedure_calls.isIntegerLike(upper_ty)) {
                                    self.setCurrentSource(self.sourceForExpr(range.upper));
                                    return error.InvalidSubscript;
                                }
                            }
                            if (range.stride) |stride| {
                                const stride_ty = try checkExprType(self, stride, deps);
                                if (!procedure_calls.isIntegerLike(stride_ty)) {
                                    self.setCurrentSource(self.sourceForExpr(stride));
                                    return error.InvalidSubscript;
                                }
                            }
                        },
                        else => {
                            const arg_ty = try checkExprType(self, arg, deps);
                            if (!procedure_calls.isIntegerLike(arg_ty)) {
                                self.setCurrentSource(self.sourceForExpr(arg));
                                return error.InvalidSubscript;
                            }
                        },
                    }
                }
            } else if (resolve_symbols.lookupDerivedBinding(self, derived_name, comp.name)) |binding| {
                if (!comp.has_parens) {
                    self.setCurrentSource(self.sourceForExpr(expr));
                    return error.InvalidSubscript;
                }
                try procedure_calls.checkTypeBoundProcedureComponent(self, comp.base, binding, comp.args, false, .{
                    .dummyArgTypeCompatible = deps.dummyArgTypeCompatible,
                });
            } else {
                return error.InvalidSubscript;
            }
            return try resolve_expr.exprType(self, expr);
        },
        .call_or_subscript => |call| {
            if (literal_substring.isLiteralSubstringCall(call.name)) {
                try literal_substring.checkBounds(self, call.args);
                return try resolve_expr.exprType(self, expr);
            }
            if (procedure_calls.hasAmbiguousVisibleGenericInterface(self, call.name) and
                procedure_interfaces.matchedVisibleGenericSigForExprArgs(self, call.name, call.args) == null)
            {
                return procedure_calls.emitAmbiguousVisibleGenericDiagnostic(self, call.name, error.DuplicateDeclaration);
            }
            if (procedure_calls.preludeSpecificInterfaceProcedureCount(self, call.name) > 1) {
                procedure_calls.emitAmbiguousReferenceDiagnostic(self, call.name);
                return error.DuplicateDeclaration;
            }
            const idx = symbolIndexForResolvedCall(self, expr) orelse
                (resolve_symbols.findSymbolIndex(self, call.name) orelse return error.MissingScope);
            const sym = self.symbols.items[idx];
            const kind: ResolvedRefKind = resolvedKindFor(self, expr) orelse
                (if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call);
            if (kind == .call and sym.is_alias and sym.dims.len == 0) {
                if (call.args.len != 0) return try resolve_expr.exprType(self, expr);
                const source = self.sourceForExpr(expr) orelse ast.SourceRef{};
                self.setDiagnostic(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.assignment_type_mismatch.code,
                    "Expected array subscript",
                    source.text,
                );
                return error.AssignmentTypeMismatch;
            }
            if (kind == .subscript) {
                if (sym.dims.len == 0) {
                    self.setCurrentSource(self.sourceForExpr(expr));
                    return error.InvalidSubscript;
                }
                if (call.args.len != sym.dims.len) {
                    self.setCurrentSource(self.sourceForExpr(expr));
                    return error.InvalidSubscript;
                }
                for (call.args) |arg| {
                    const arg_ty = try checkExprType(self, arg, deps);
                    if (!procedure_calls.isIntegerLike(arg_ty)) {
                        self.setCurrentSource(self.sourceForExpr(arg));
                        return error.InvalidSubscript;
                    }
                }
            } else {
                const check_homogeneous = sym.is_intrinsic and leaf_helpers.isHomogeneousMaxMinIntrinsic(call.name);
                if (procedure_interfaces.isAbstractInterfaceProcedure(self, call.name)) {
                    return procedure_calls.emitNamedProcedureDiagnostic(self, call.name, error.InvalidArgumentCount, "must not be referenced");
                }
                var first_ty: ?ast.TypeKind = null;
                for (call.args) |arg| {
                    const arg_ty = try checkExprType(self, arg, deps);
                    if (check_homogeneous) {
                        if (first_ty == null) {
                            if (!procedure_calls.isNumeric(arg_ty) or arg_ty == .complex or arg_ty == .complex_double) {
                                self.setCurrentSource(self.sourceForExpr(arg));
                                return error.InvalidArithmeticOperands;
                            }
                            first_ty = arg_ty;
                        } else if (arg_ty != first_ty.?) {
                            self.setCurrentSource(self.sourceForExpr(arg));
                            return error.InvalidArithmeticOperands;
                        }
                    }
                }
                if (structureConstructorTypeName(self, call.name, sym)) |type_name| {
                    try checkStructureConstructorProcedureComponentActuals(self, type_name, call.args, deps);
                    return try resolve_expr.exprType(self, expr);
                }
                if (resolve_symbols.lookupKnownProcedureSig(self, call.name) == null and
                    procedure_interfaces.matchedVisibleGenericSigForExprArgs(self, call.name, call.args) == null and
                    procedure_interfaces.visibleSingleTargetGenericSig(self, call.name) == null and
                    resolve_symbols.lookupKnownFunctionResolvedSpec(self, call.name) == null and
                    procedure_calls.hasVisibleGenericInterface(self, call.name))
                {
                    return procedure_calls.emitNamedProcedureDiagnostic(self, call.name, error.InvalidArgumentCount, "no specific function");
                }
                try checkSpecialExprCallConstraints(self, expr, call.name, call.args);
                try procedure_calls.checkIntrinsicCallConstraintsForExprArgs(self, call.name, call.args);
                try procedure_calls.checkExplicitInterfaceRequirementForExprArgs(self, call.name, call.args, idx);
                try procedure_calls.checkKnownProcedureCallArity(self, call.name, call.args.len, 0, false, idx);
                try procedure_calls.checkProcedureActualArgsForExprCall(self, call.name, call.args, .{
                    .dummyArgTypeCompatible = deps.dummyArgTypeCompatible,
                });
                try rejectElementalExprCallRankMismatch(self, call.name, call.args);
            }
            return try resolve_expr.exprType(self, expr);
        },
        .implied_do => |implied| {
            _ = try checkExprType(self, implied.start, deps);
            _ = try checkExprType(self, implied.end, deps);
            if (implied.step) |step| _ = try checkExprType(self, step, deps);
            for (implied.items) |item| _ = try checkExprType(self, item, deps);
            return try resolve_expr.exprType(self, expr);
        },
    }
}

fn structureConstructorTypeName(
    self: *context.Context,
    name: []const u8,
    sym: symbols.Symbol,
) ?[]const u8 {
    const info = resolve_symbols.lookupDerivedType(self, name) orelse return null;
    const local_derived_shadow = sym.is_host_associated and resolve_symbols.hasLocalDerivedType(self, name);
    if (sym.is_intrinsic or (!local_derived_shadow and sym.is_external) or sym.dims.len != 0) return null;
    if (resolve_symbols.lookupKnownProcedureSig(self, name) != null) return null;
    if (!local_derived_shadow and sym.type_explicit and sym.loweredKind() != .derived) return null;
    return info.name;
}

fn rejectElementalExprCallRankMismatch(
    self: *context.Context,
    call_name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    const sig = resolve_symbols.lookupKnownProcedureSig(self, call_name) orelse return;
    if (!sig.elemental) return;

    var expected_rank: ?usize = null;
    for (args, 0..) |arg, idx| {
        if (idx >= sig.args.len or sig.args[idx].rank != 0) continue;
        const actual_rank = resolve_expr.exprRank(self, arg);
        if (actual_rank == 0) continue;
        if (expected_rank == null) {
            expected_rank = actual_rank;
            continue;
        }
        if (expected_rank.? != actual_rank) {
            const source = self.sourceForExpr(arg) orelse ast.SourceRef{};
            self.setDiagnostic(
                if (source.line == 0) 1 else source.line,
                if (source.column == 0) 1 else source.column,
                catalog.semantic.assignment_type_mismatch.code,
                "Incompatible ranks in elemental procedure",
                source.text,
            );
            return error.AssignmentTypeMismatch;
        }
    }
}

fn checkStructureConstructorProcedureComponentActuals(
    self: *context.Context,
    type_name: []const u8,
    args: []*ast.Expr,
    comptime deps: anytype,
) CheckError!void {
    var actual_idx: usize = 0;
    try checkStructureConstructorProcedureComponentActualsForType(self, type_name, args, &actual_idx, deps);
}

fn checkStructureConstructorProcedureComponentActualsForType(
    self: *context.Context,
    type_name: []const u8,
    args: []*ast.Expr,
    actual_idx: *usize,
    comptime deps: anytype,
) CheckError!void {
    const derived = resolve_symbols.lookupDerivedType(self, type_name) orelse return;
    if (derived.parent_name) |parent_name| {
        try checkStructureConstructorProcedureComponentActualsForType(self, parent_name, args, actual_idx, deps);
    }
    for (derived.components) |component| {
        if (actual_idx.* >= args.len) return;
        if (component.procedure) {
            try procedure_calls.checkStructureConstructorProcedureComponentActual(self, component, args[actual_idx.*], deps);
        }
        actual_idx.* += 1;
    }
}

pub fn resolvedKindFor(self: *const context.Context, expr: *ast.Expr) ?ResolvedRefKind {
    return self.ref_kind_index.get(@intFromPtr(expr));
}

pub fn symbolIndexForResolvedCall(self: *const context.Context, expr: *ast.Expr) ?usize {
    return self.ref_symbol_index.get(@intFromPtr(expr));
}

pub fn exprUsesNonDefinableAlias(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.is_alias and !sym.alias_definable;
        },
        .component => |comp| exprUsesNonDefinableAlias(self, comp.base),
        .substring => |sub| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, sub.name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.is_alias and !sym.alias_definable;
        },
        .call_or_subscript => |call| blk: {
            const idx = symbolIndexForResolvedCall(self, expr) orelse
                (resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false);
            const sym = self.symbols.items[idx];
            const kind: ResolvedRefKind = resolvedKindFor(self, expr) orelse
                (if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call);
            if (kind != .subscript) break :blk false;
            break :blk sym.is_alias and !sym.alias_definable;
        },
        else => false,
    };
}

pub fn exprRootIsIntentInNonpointerDummy(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| dummyArgIsIntentInNonpointer(self, name),
        .component => |comp| exprRootIsIntentInNonpointerDummy(self, comp.base),
        .substring => |sub| dummyArgIsIntentInNonpointer(self, sub.name),
        .call_or_subscript => |call| blk: {
            const idx = symbolIndexForResolvedCall(self, expr) orelse
                (resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false);
            const sym = self.symbols.items[idx];
            const kind: ResolvedRefKind = resolvedKindFor(self, expr) orelse
                (if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call);
            if (kind != .subscript) break :blk false;
            break :blk dummyArgIsIntentInNonpointer(self, call.name);
        },
        else => false,
    };
}

pub fn selectorIsDefinableAlias(self: *context.Context, selector: *ast.Expr) bool {
    if (exprUsesNonDefinableAlias(self, selector)) return false;
    if (exprRootIsIntentInNonpointerDummy(self, selector) and !isPointerValuedExpr(self, selector)) return false;
    return true;
}

fn dummyArgIsIntentInNonpointer(self: *context.Context, name: []const u8) bool {
    const sig = resolve_symbols.lookupKnownProcedureSig(self, self.unit.name) orelse return false;
    for (sig.args) |arg| {
        if (!std.ascii.eqlIgnoreCase(arg.name, name)) continue;
        return arg.intent == .in and !arg.pointer;
    }
    return false;
}

pub fn isAssignmentTarget(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk true;
            const sym = self.symbols.items[idx];
            if (sym.is_alias and !sym.alias_definable) {
                emitExprConstraintDiagnostic(self, expr, "cannot be used in a variable definition context") catch {};
                break :blk false;
            }
            break :blk true;
        },
        .substring => true,
        .component => true,
        .call_or_subscript => |call| blk: {
            const idx = symbolIndexForResolvedCall(self, expr) orelse
                (resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false);
            const sym = self.symbols.items[idx];
            const kind: ResolvedRefKind = resolvedKindFor(self, expr) orelse
                (if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call);
            if (kind == .call and sym.is_alias) {
                emitExprConstraintDiagnostic(self, expr, "array reference of a non-array") catch {};
                break :blk false;
            }
            break :blk kind == .subscript or kind == .call;
        },
        else => false,
    };
}

pub fn isPointerTarget(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const sym = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            break :blk self.symbols.items[sym].is_pointer;
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk procedure_calls.isTypeBoundProcedurePointerResult(self, comp);
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk false;
            if (base_spec.lowered_kind != .derived) break :blk false;
            const derived_name = base_spec.derived_type_name orelse break :blk false;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk false;
            break :blk component.pointer;
        },
        else => false,
    };
}

pub fn isPointerValuedExpr(self: *context.Context, expr: *ast.Expr) bool {
    if (source_shape.wrapsIdentifierInParens(self, expr)) return false;
    return switch (expr.*) {
        .identifier, .component => isPointerTarget(self, expr),
        .call_or_subscript => |call| blk: {
            if (std.ascii.eqlIgnoreCase(call.name, "null")) break :blk true;
            const idx = symbolIndexForResolvedCall(self, expr) orelse
                (resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false);
            const sym = self.symbols.items[idx];
            const kind: ResolvedRefKind = resolvedKindFor(self, expr) orelse
                (if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call);
            if (kind != .call) break :blk false;
            if (sym.is_pointer) break :blk true;
            if (procedure_interfaces.visibleSingleTargetGenericSig(self, call.name)) |sig| {
                break :blk sig.is_pointer;
            }
            if (resolve_symbols.lookupKnownProcedureSig(self, call.name)) |sig| {
                break :blk sig.is_pointer;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn isAddressableDataTargetExpr(self: *context.Context, expr: *ast.Expr) bool {
    if (source_shape.wrapsIdentifierInParens(self, expr)) return false;
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.is_target or sym.is_pointer;
        },
        .component => |comp| blk: {
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk false;
            if (base_spec.lowered_kind != .derived) break :blk false;
            const derived_name = base_spec.derived_type_name orelse break :blk false;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk false;
            if (component.procedure) break :blk false;
            if (component.pointer) break :blk true;
            if (!componentHasDataTargetBase(self, comp.base)) break :blk false;
            if (!comp.has_parens or resolvedKindFor(self, expr) == .subscript) break :blk true;
            break :blk hasTripletSectionArg(comp.args) or !component.procedure;
        },
        .call_or_subscript => |call| blk: {
            const idx = symbolIndexForResolvedCall(self, expr) orelse
                (resolve_symbols.findSymbolIndex(self, call.name) orelse break :blk false);
            const sym = self.symbols.items[idx];
            const kind: ResolvedRefKind = resolvedKindFor(self, expr) orelse
                (if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call);
            if (kind == .subscript) break :blk sym.is_target or sym.is_pointer;
            if (kind == .call and sym.is_alias and call.args.len != 0) break :blk sym.is_target or sym.is_pointer;
            break :blk hasTripletSectionArg(call.args) and (sym.is_target or sym.is_pointer);
        },
        .substring => |sub| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, sub.name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.kind == .variable and !sym.is_external and (sym.is_target or sym.is_pointer);
        },
        else => false,
    };
}

fn componentHasDataTargetBase(self: *context.Context, expr: *ast.Expr) bool {
    return isPointerValuedExpr(self, expr) or isAddressableDataTargetExpr(self, expr);
}

fn hasTripletSectionArg(args: []const *ast.Expr) bool {
    for (args) |arg| {
        if (arg.* == .dim_range) return true;
    }
    return false;
}

pub fn isAssignmentCompatible(target: ast.TypeKind, value: ast.TypeKind) bool {
    if (target == .derived or value == .derived) return target == .derived and value == .derived;
    if (target == .character or value == .character) return target == .character and value == .character;
    if (target == .logical or value == .logical) return target == .logical and value == .logical;
    return procedure_calls.isNumeric(target) and procedure_calls.isNumeric(value);
}

pub fn isDefinedAssignmentCompatible(
    self: *context.Context,
    target: *ast.Expr,
    value: *ast.Expr,
    comptime deps: anytype,
) bool {
    if (resolve_symbols.lookupKnownProcedureSig(self, "assignment(=)")) |sig| {
        if (sig.kind == .subroutine and sig.arg_count == 2 and sig.alt_return_count == 0 and
            procedure_calls.minimumRequiredProcedureArgs(sig) <= 2)
        {
            var actuals = [_]*ast.Expr{ target, value };
            if (procedureSigMatchesActuals(self, sig, &actuals, deps)) return true;
        }
    }

    var extra_actuals = [_]*ast.Expr{value};
    return (type_bound_generics.lookupTypeBoundGenericSig(
        self,
        "assignment(=)",
        target,
        &extra_actuals,
        .subroutine,
        .{ .dummyArgTypeCompatible = deps.dummyArgTypeCompatible },
    ) catch null) != null;
}

fn emitExprConstraintDiagnostic(
    self: *context.Context,
    expr_node: *ast.Expr,
    message: []const u8,
) CheckError {
    return expr_diagnostics.emitExprAssignmentMismatch(self, expr_node, message);
}

fn exprIsAllocatableEntity(self: *context.Context, expr_node: *ast.Expr) bool {
    return expr_attributes.isAllocatableEntity(self, expr_node);
}

fn exprIsPointerEntity(self: *context.Context, expr_node: *ast.Expr) bool {
    return expr_attributes.isPointerEntity(self, expr_node);
}

fn procedureSigMatchesActuals(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    actuals: []const *ast.Expr,
    comptime deps: anytype,
) bool {
    if (sig.args.len == 0) return sig.arg_count == actuals.len;
    if (actuals.len > sig.arg_count) return false;

    var actual_index: usize = 0;
    for (sig.args) |arg| {
        if (actual_index >= actuals.len) return arg.optional;
        const actual_spec = resolve_expr.exprTypeSpec(self, actuals[actual_index]) catch return false;
        if (!deps.dummyArgTypeCompatible(self, arg.type_spec, actual_spec)) return false;
        actual_index += 1;
    }
    return actual_index == actuals.len;
}
