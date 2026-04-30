const std = @import("std");
const ast = @import("../../../../../ast/nodes.zig");
const common_diag = @import("../../../../../common/diagnostic.zig");
const catalog = @import("../../../../../common/error_catalog.zig");
const procedure_pass = @import("../../../../../common/procedure_pass.zig");
const free_form = @import("../../../../../frontend/free_form.zig");
const parser = @import("../../../../../frontend/parser/mod.zig");
const symbols = @import("../../../../symbol/mod.zig");
const literal_utils = @import("../../../../evaluator/literals.zig");
const procedure_inference = @import("../../../../split/api/procedure_inference.zig");
const context = @import("../../../context.zig");
const constants = @import("../../../resolve_const.zig");
const resolve_expr = @import("../../../resolve_expr.zig");
const resolve_symbols = @import("../../../resolve_symbols.zig");
const assumed_size = @import("../../../assumed_size.zig");
const expr_attributes = @import("../../../expr_attributes.zig");
const expr_diagnostics = @import("../../../expr_diagnostics.zig");
const abstract_expr_use = @import("../../abstract_expr_use.zig");
const leaf_helpers = @import("../../leaf_helpers.zig");
const procedure_call_diagnostics = @import("../../procedure_call_diagnostics.zig");
const c_funloc = @import("c_funloc.zig");
const procedure_size = @import("procedure_size.zig");
const shift_intrinsics = @import("shift_intrinsics.zig");
const coarray_intrinsics = @import("coarray_intrinsics.zig");
pub const CheckError = anyerror;
const exprIsVariableDefinitionActual = procedure_call_diagnostics.exprIsVariableDefinitionActual;
pub fn checkIntrinsicCallConstraintsForCallArgs(
    self: *context.Context,
    name: []const u8,
    args: []const ast.CallArg,
) CheckError!void {
    if (std.ascii.eqlIgnoreCase(name, "random_init")) {
        try checkRandomInitCallConstraints(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "random_seed")) {
        try checkRandomSeedCallConstraints(self, args);
        return;
    }
    if (leaf_helpers.lookupIntrinsicArity(self, name) == null) return;
    try checkIntrinsicSpecialActualRestrictionsForCallArgs(self, name, args);
    if (std.ascii.eqlIgnoreCase(name, "move_alloc")) {
        try checkMoveAllocCallConstraints(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "date_and_time")) {
        try checkDateAndTimeCallConstraints(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "get_command")) {
        try checkGetCommandCallConstraints(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "get_command_argument")) {
        try checkGetCommandArgumentCallConstraints(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "get_environment_variable")) {
        try checkGetEnvironmentVariableCallConstraints(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "mvbits")) {
        try checkMvbitsCallConstraints(self, args);
        return;
    }
    try checkLegacyWidecharCallConstraints(self, name, args);
    if (std.ascii.eqlIgnoreCase(name, "c_f_pointer")) {
        try checkCFPointerCallConstraints(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "c_f_procpointer")) {
        try checkCFProcPointerCallConstraints(self, args);
    }
}
pub fn checkIntrinsicCallConstraintsForExprArgs(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    if (leaf_helpers.lookupIntrinsicArity(self, name) == null) return;
    try checkIntrinsicSpecialActualRestrictionsForExprArgs(self, name, args);
    if (std.ascii.eqlIgnoreCase(name, "selected_char_kind")) {
        try checkSelectedCharKindExprArgs(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "selected_real_kind")) {
        try checkSelectedRealKindExprArgs(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "selected_int_kind")) {
        try checkSelectedIntKindExprArgs(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "achar") or std.ascii.eqlIgnoreCase(name, "char")) {
        try checkAcharExprArgs(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "transfer")) {
        try checkTransferExprArgs(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "storage_size")) {
        try checkStorageSizeExprArgs(self, args);
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "c_associated")) {
        if (args.len >= 1 and resolve_expr.exprRank(self, args[0]) != 0) return emitIntrinsicArgDiagnostic(self, args[0], "argument of 'c_associated' intrinsic at (1) must be a scalar");
        if (args.len >= 2 and resolve_expr.exprRank(self, args[1]) != 0) return emitIntrinsicArgDiagnostic(self, args[1], "argument of 'c_associated' intrinsic at (1) must be a scalar");
    }
    try coarray_intrinsics.checkExprArgs(self, name, args);
    try shift_intrinsics.checkExprArgs(self, name, args);
    try checkBitExprIntrinsicConstraints(self, name, args);
    try checkRepeatExprArgs(self, name, args);
}

fn checkIntrinsicSpecialActualRestrictionsForCallArgs(
    self: *context.Context,
    name: []const u8,
    args: []const ast.CallArg,
) CheckError!void {
    var actual_idx: usize = 0;
    for (args) |arg| {
        if (arg != .expr) continue;
        try checkIntrinsicSpecialActualRestriction(self, name, arg.expr.value, actual_idx);
        actual_idx += 1;
    }
}

fn checkIntrinsicSpecialActualRestrictionsForExprArgs(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    for (args, 0..) |arg, actual_idx| {
        try checkIntrinsicSpecialActualRestriction(self, name, arg, actual_idx);
    }
}

fn checkIntrinsicSpecialActualRestriction(
    self: *context.Context,
    name: []const u8,
    expr_node: *ast.Expr,
    actual_idx: usize,
) CheckError!void {
    if (exprIsNoArgCheck(self, expr_node) and !intrinsicAllowsNoArgCheck(name)) {
        return emitIntrinsicArgDiagnostic(self, expr_node, "Variable with NO_ARG_CHECK attribute at (1) is only permitted as argument to the intrinsic functions C_LOC and PRESENT");
    }
    if (std.ascii.eqlIgnoreCase(name, "c_loc") and actual_idx == 0 and !expr_attributes.isCAddressableDataTarget(self, expr_node)) return emitIntrinsicArgDiagnostic(self, expr_node, "Argument X at (1) to C_LOC shall have either the POINTER or the TARGET attribute");
    if (std.ascii.eqlIgnoreCase(name, "c_funloc") and actual_idx == 0) {
        return c_funloc.checkActual(self, expr_node, emitIntrinsicArgDiagnostic);
    }
    if ((std.ascii.eqlIgnoreCase(name, "c_sizeof") or std.ascii.eqlIgnoreCase(name, "sizeof")) and actual_idx == 0) {
        return procedure_size.checkActual(self, name, expr_node, emitIntrinsicArgDiagnostic);
    }
    if (exprIsBozLiteral(expr_node)) {
        if (std.ascii.eqlIgnoreCase(name, "c_sizeof")) {
            return emitIntrinsicArgDiagnostic(self, expr_node, "cannot appear");
        }
        if (std.ascii.eqlIgnoreCase(name, "sizeof") or
            std.ascii.eqlIgnoreCase(name, "storage_size") or
            std.ascii.eqlIgnoreCase(name, "transfer"))
        {
            return emitIntrinsicArgDiagnostic(self, expr_node, "cannot be an actual argument");
        }
    }
    if (exprIsAssumedRank(self, expr_node)) {
        if (intrinsicAllowsAssumedRank(name, actual_idx)) return;
        if (std.ascii.eqlIgnoreCase(name, "ubound")) {
            return emitIntrinsicArgDiagnostic(self, expr_node, "Assumed-rank argument at (1) is only permitted as first actual argument to the intrinsic inquiry function ubound");
        }
        return emitIntrinsicArgDiagnostic(self, expr_node, "Assumed-rank argument at (1) is only permitted as actual argument to intrinsic inquiry functions");
    }
    if (exprIsAssumedType(self, expr_node)) {
        if (intrinsicAllowsAssumedType(name, actual_idx)) return;
        if (std.ascii.eqlIgnoreCase(name, "ubound")) {
            return emitIntrinsicArgDiagnostic(self, expr_node, "Assumed-type argument at (1) is only permitted as first actual argument to the intrinsic ubound");
        }
        if (std.ascii.eqlIgnoreCase(name, "transfer")) {
            return emitIntrinsicArgDiagnostic(self, expr_node, "Assumed-type argument at (1) is not permitted as actual argument to the intrinsic transfer");
        }
        return emitIntrinsicArgDiagnostic(self, expr_node, "Assumed-type argument at (1) is only permitted as actual argument to intrinsic inquiry functions");
    }
    if (assumed_size.exprHasAssumedSizeArray(self, expr_node)) {
        if (actual_idx == 0 and std.ascii.eqlIgnoreCase(name, "lbound")) return;
        if (actual_idx == 0 and std.ascii.eqlIgnoreCase(name, "loc")) return;
        if (actual_idx == 0 and std.ascii.eqlIgnoreCase(name, "shape")) {
            if (assumed_size.exprNeedsExplicitLastUpperBound(self, expr_node)) {
                return emitIntrinsicArgDiagnostic(self, expr_node, assumed_size.shapeAssumedSizeMessage(self, expr_node));
            }
            return;
        }
        if (actual_idx == 0 and
            (std.ascii.eqlIgnoreCase(name, "size") or std.ascii.eqlIgnoreCase(name, "ubound")))
        {
            return;
        }
        if (assumed_size.exprNeedsExplicitLastUpperBound(self, expr_node)) {
            return emitIntrinsicArgDiagnostic(self, expr_node, "upper bound in the last dimension");
        }
    }
}

fn exprIsBozLiteral(expr_node: *ast.Expr) bool {
    if (expr_node.* != .literal or expr_node.literal.kind != .string) return false;
    return literal_utils.parseBozInt(expr_node.literal.text) catch null != null;
}

fn checkTransferExprArgs(self: *context.Context, args: []*ast.Expr) CheckError!void {
    if (args.len < 2) return;
    if (resolve_expr.exprRank(self, args[1]) == 0) return;
    const mold_storage_bits = constants.exprMeasure(self, args[1], .storage_size_bits) orelse return;
    if (mold_storage_bits != 0) return;
    return emitIntrinsicArgDiagnostic(self, args[1], "MOLD argument at (1) to TRANSFER shall not have storage size 0");
}

fn checkStorageSizeExprArgs(self: *context.Context, args: []*ast.Expr) CheckError!void {
    if (args.len == 0) return;
    if (exprIsNullPointerIntrinsic(args[0])) {
        return emitIntrinsicArgDiagnostic(self, args[0], "cannot be an actual argument to STORAGE_SIZE");
    }
    if (args.len < 2) return;
    const kind_arg = args[1];
    if (resolve_expr.exprRank(self, kind_arg) != 0) {
        return emitIntrinsicArgDiagnostic(self, kind_arg, "must be a scalar");
    }
    const kind_spec = try resolve_expr.exprTypeSpec(self, kind_arg);
    if (kind_spec.lowered_kind != .integer) {
        return emitIntrinsicArgDiagnostic(self, kind_arg, "must be INTEGER");
    }
    _ = constants.evalConst(self, kind_arg) catch null orelse {
        return emitIntrinsicArgDiagnostic(self, kind_arg, "must be a constant");
    };
}

fn exprIsNullPointerIntrinsic(expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .call_or_subscript => |call| std.ascii.eqlIgnoreCase(call.name, "null"),
        else => false,
    };
}

fn checkAcharExprArgs(self: *context.Context, args: []*ast.Expr) CheckError!void {
    if (args.len == 0 or args.len > 2) return;
    const scalar_value = try constIntegerValue(self, args[0]) orelse return;
    if (scalar_value < 0) {
        return emitIntrinsicArgDiagnostic(self, args[0], "negative");
    }
    const max_value = try acharMaxValue(self, args);
    if (scalar_value > max_value) {
        return emitIntrinsicArgDiagnostic(self, args[0], "too large for the collating sequence");
    }
}

fn acharMaxValue(self: *context.Context, args: []*ast.Expr) CheckError!i64 {
    if (args.len < 2) return 255;
    const kind_value = try constIntegerValue(self, args[1]) orelse return 255;
    if (kind_value == 4) return std.math.maxInt(u21);
    return 255;
}

fn constIntegerValue(self: *context.Context, expr_node: *ast.Expr) CheckError!?i64 {
    const value = (try constants.evalConst(self, expr_node)) orelse return null;
    return switch (value) {
        .integer => |int_value| int_value,
        else => null,
    };
}

fn constIntegerScalarOrSingleElement(self: *context.Context, expr_node: *ast.Expr) CheckError!?i64 {
    if (expr_node.* == .array_constructor and expr_node.array_constructor.items.len == 1) {
        return constIntegerValue(self, expr_node.array_constructor.items[0]);
    }
    if (exprIsBozLiteral(expr_node)) return literal_utils.parseBozInt(expr_node.literal.text) catch null;
    return constIntegerValue(self, expr_node);
}

fn integerStorageBits(self: *context.Context, expr_node: *ast.Expr) CheckError!?i64 {
    if (exprIsBozLiteral(expr_node)) return self.target_layout.default_integer_bits;
    const spec = try resolve_expr.exprTypeSpec(self, expr_node);
    if (spec.lowered_kind != .integer) return null;
    const kind_bytes = spec.kind_value orelse @divTrunc(@as(i64, self.target_layout.default_integer_bits), 8);
    return kind_bytes * 8;
}

fn checkBitExprIntrinsicConstraints(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) CheckError!void {
    if (std.ascii.eqlIgnoreCase(name, "ibclr") or std.ascii.eqlIgnoreCase(name, "ibset")) {
        if (args.len < 2) return;
        const pos = try constIntegerScalarOrSingleElement(self, args[1]) orelse return;
        if (pos < 0) return emitIntrinsicArgDiagnostic(self, args[1], "must be nonnegative");
        const bits = try integerStorageBits(self, args[0]) orelse return;
        if (pos >= bits) return emitIntrinsicArgDiagnostic(self, args[1], "must be less than");
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "ibits")) {
        if (args.len < 3) return;
        const pos = try constIntegerScalarOrSingleElement(self, args[1]) orelse return;
        const len = try constIntegerScalarOrSingleElement(self, args[2]) orelse return;
        if (pos < 0) return emitIntrinsicArgDiagnostic(self, args[1], "must be nonnegative");
        if (len < 0) return emitIntrinsicArgDiagnostic(self, args[2], "must be nonnegative");
        const bits = try integerStorageBits(self, args[0]) orelse return;
        if (pos + len > bits) return emitIntrinsicArgDiagnostic(self, args[2], "must be less than");
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "ishft") or std.ascii.eqlIgnoreCase(name, "ishftc")) {
        if (args.len < 2) return;
        const shift = try constIntegerScalarOrSingleElement(self, args[1]) orelse return;
        const size = if (args.len >= 3)
            try constIntegerScalarOrSingleElement(self, args[2]) orelse return
        else
            try integerStorageBits(self, args[0]) orelse return;
        if (size <= 0) return emitIntrinsicArgDiagnostic(self, args[2], "must be positive");
        if (@abs(shift) > size) return emitIntrinsicArgDiagnostic(self, args[1], "absolute value of SHIFT");
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "dshiftl") or std.ascii.eqlIgnoreCase(name, "dshiftr")) {
        if (args.len < 3) return;
        if (exprIsBozLiteral(args[0]) and exprIsBozLiteral(args[1])) {
            return emitIntrinsicArgDiagnostic(self, args[1], "cannot both be");
        }
        if (!exprIsBozLiteral(args[0]) and !exprIsBozLiteral(args[1])) {
            const left_spec = try resolve_expr.exprTypeSpec(self, args[0]);
            const right_spec = try resolve_expr.exprTypeSpec(self, args[1]);
            if (left_spec.lowered_kind != right_spec.lowered_kind or left_spec.kind_value != right_spec.kind_value) {
                return emitIntrinsicArgDiagnostic(self, args[1], "must be the same type and kind");
            }
        }
        const shift = try constIntegerScalarOrSingleElement(self, args[2]) orelse return;
        if (shift < 0) return emitIntrinsicArgDiagnostic(self, args[2], "must be nonnegative");
        const bits = try integerStorageBits(self, args[0]) orelse try integerStorageBits(self, args[1]) orelse return;
        if (shift > bits) return emitIntrinsicArgDiagnostic(self, args[2], "must be less than or equal");
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "maskl") or std.ascii.eqlIgnoreCase(name, "maskr")) {
        if (args.len < 1) return;
        const bits = try constIntegerScalarOrSingleElement(self, args[0]) orelse return;
        if (bits < 0) return emitIntrinsicArgDiagnostic(self, args[0], "must be nonnegative");
        const kind_bits: i64 = if (args.len >= 2)
            (try constIntegerScalarOrSingleElement(self, args[1]) orelse 4) * 8
        else
            self.target_layout.default_integer_bits;
        if (bits > kind_bits) return emitIntrinsicArgDiagnostic(self, args[0], "must be less than or equal");
    }
}

fn checkRepeatExprArgs(self: *context.Context, name: []const u8, args: []*ast.Expr) CheckError!void {
    if (!std.ascii.eqlIgnoreCase(name, "repeat") or args.len < 2) return;
    const copies = try constIntegerScalarOrSingleElement(self, args[1]) orelse return;
    if (copies < 0) return emitIntrinsicArgDiagnostic(self, args[1], "Argument NCOPIES of REPEAT intrinsic is negative");
    const spec = try resolve_expr.exprTypeSpec(self, args[0]);
    const char_len = spec.char_len orelse return;
    if (char_len > 0 and copies > @divTrunc(std.math.maxInt(i64), @as(i64, @intCast(char_len)))) {
        return emitIntrinsicArgDiagnostic(self, args[1], "Argument NCOPIES of REPEAT intrinsic is too large");
    }
}

fn checkSelectedCharKindExprArgs(self: *context.Context, args: []*ast.Expr) CheckError!void {
    try checkSelectedKindScalarArg(self, args, true, "must be CHARACTER");
}

fn checkSelectedRealKindExprArgs(self: *context.Context, args: []*ast.Expr) CheckError!void {
    for (args) |arg| {
        if (resolve_expr.exprRank(self, arg) != 0) {
            return emitIntrinsicArgDiagnostic(self, arg, "must be a scalar");
        }
        const arg_spec = try resolve_expr.exprTypeSpec(self, arg);
        if (arg_spec.lowered_kind != .integer) {
            return emitIntrinsicArgDiagnostic(self, arg, "must be INTEGER");
        }
    }
}

fn checkSelectedIntKindExprArgs(self: *context.Context, args: []*ast.Expr) CheckError!void {
    try checkSelectedKindScalarArg(self, args, false, "must be INTEGER");
}

fn checkSelectedKindScalarArg(
    self: *context.Context,
    args: []*ast.Expr,
    expect_character: bool,
    expected_message: []const u8,
) CheckError!void {
    if (args.len != 1) return;
    const arg = args[0];
    if (resolve_expr.exprRank(self, arg) != 0) {
        return emitIntrinsicArgDiagnostic(self, arg, "must be a scalar");
    }
    const arg_spec = try resolve_expr.exprTypeSpec(self, arg);
    const is_match = if (expect_character)
        arg_spec.lowered_kind == .character
    else
        arg_spec.lowered_kind == .integer;
    if (!is_match) {
        return emitIntrinsicArgDiagnostic(self, arg, expected_message);
    }
}

fn intrinsicAllowsNoArgCheck(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "c_loc") or std.ascii.eqlIgnoreCase(name, "present");
}

fn intrinsicAllowsAssumedRank(name: []const u8, actual_idx: usize) bool {
    if (std.ascii.eqlIgnoreCase(name, "c_loc") or
        std.ascii.eqlIgnoreCase(name, "present") or
        std.ascii.eqlIgnoreCase(name, "c_sizeof") or
        std.ascii.eqlIgnoreCase(name, "sizeof"))
    {
        return actual_idx == 0;
    }
    return intrinsicAllowsInquiryArrayActual(name, actual_idx);
}

fn intrinsicAllowsAssumedType(name: []const u8, actual_idx: usize) bool {
    if (std.ascii.eqlIgnoreCase(name, "c_loc") or
        std.ascii.eqlIgnoreCase(name, "present") or
        std.ascii.eqlIgnoreCase(name, "c_sizeof") or
        std.ascii.eqlIgnoreCase(name, "sizeof"))
    {
        return actual_idx == 0;
    }
    return intrinsicAllowsInquiryArrayActual(name, actual_idx);
}

fn intrinsicAllowsInquiryArrayActual(name: []const u8, actual_idx: usize) bool {
    if (actual_idx != 0) return false;
    return std.ascii.eqlIgnoreCase(name, "associated") or
        std.ascii.eqlIgnoreCase(name, "lbound") or
        std.ascii.eqlIgnoreCase(name, "ubound") or
        std.ascii.eqlIgnoreCase(name, "shape") or
        std.ascii.eqlIgnoreCase(name, "size") or
        std.ascii.eqlIgnoreCase(name, "rank") or
        std.ascii.eqlIgnoreCase(name, "storage_size") or
        std.ascii.eqlIgnoreCase(name, "is_contiguous");
}

fn exprIsAssumedType(self: *context.Context, expr_node: *ast.Expr) bool {
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return false;
    return spec.assumed_type;
}

fn exprIsAssumedRank(self: *context.Context, expr_node: *ast.Expr) bool {
    const idx = rootActualSymbolIndex(self, expr_node) orelse return false;
    return symbolIsAssumedRank(self, self.symbols.items[idx]);
}

fn exprIsNoArgCheck(self: *context.Context, expr_node: *ast.Expr) bool {
    const idx = rootActualSymbolIndex(self, expr_node) orelse return false;
    return self.symbols.items[idx].no_arg_check;
}

fn rootActualSymbolIndex(self: *context.Context, expr_node: *ast.Expr) ?usize {
    return switch (expr_node.*) {
        .identifier => |name| self.ref_symbol_index.get(@intFromPtr(expr_node)) orelse resolve_symbols.findSymbolIndex(self, name),
        .call_or_subscript => |call| self.ref_symbol_index.get(@intFromPtr(expr_node)) orelse resolve_symbols.findSymbolIndex(self, call.name),
        .substring => |sub| resolve_symbols.findSymbolIndex(self, sub.name),
        .component => |comp| rootActualSymbolIndex(self, comp.base),
        else => null,
    };
}

fn symbolIsAssumedRank(_: *context.Context, sym: symbols.Symbol) bool {
    if (sym.dims.len != 1) return false;
    const dim = sym.dims[0];
    return switch (dim.*) {
        .dim_range => |range| range.from_dotdot,
        else => false,
    };
}

const IntrinsicCallActual = struct {
    keyword: ?[]const u8 = null,
    value: *ast.Expr,
};

fn duplicateKeywordActual(args: []const ast.CallArg, keyword_name: []const u8) ?IntrinsicCallActual {
    var seen = false;
    for (args) |arg| {
        if (arg != .expr) continue;
        const actual = arg.expr;
        const keyword = actual.keyword orelse continue;
        if (!std.ascii.eqlIgnoreCase(keyword, keyword_name)) continue;
        if (seen) return .{ .keyword = keyword, .value = actual.value };
        seen = true;
    }
    return null;
}

fn nthOrKeywordActual(args: []const ast.CallArg, position: usize, keyword_name: ?[]const u8) ?IntrinsicCallActual {
    if (keyword_name) |keyword| {
        for (args) |arg| {
            if (arg != .expr) continue;
            const actual = arg.expr;
            if (actual.keyword) |kw| {
                if (std.ascii.eqlIgnoreCase(kw, keyword)) return .{ .keyword = kw, .value = actual.value };
            }
        }
    }
    var positional_idx: usize = 0;
    for (args) |arg| {
        if (arg != .expr) continue;
        const actual = arg.expr;
        if (actual.keyword != null) continue;
        if (positional_idx == position) return .{ .keyword = null, .value = actual.value };
        positional_idx += 1;
    }
    return null;
}

fn emitDuplicateIntrinsicKeywordDiagnostic(
    self: *context.Context,
    actual: IntrinsicCallActual,
    keyword_name: []const u8,
) CheckError {
    return emitIntrinsicArgDiagnostic(
        self,
        actual.value,
        std.fmt.allocPrint(self.arena, "Keyword '{s}' at (1) has already appeared in the current argument list", .{keyword_name}) catch "duplicate keyword in intrinsic call",
    );
}

fn exprIsScalarIntegerVariableAtLeastKind(self: *context.Context, expr_node: *ast.Expr, min_kind: i64) bool {
    if (!exprIsVariableDefinitionActual(self, expr_node)) return false;
    if (resolve_expr.exprRank(self, expr_node) != 0) return false;
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return false;
    if (spec.lowered_kind != .integer) return false;
    return spec.kind_value == null or spec.kind_value.? >= min_kind;
}

fn exprIsScalarCharacterVariableKindOne(self: *context.Context, expr_node: *ast.Expr) bool {
    if (!exprIsVariableDefinitionActual(self, expr_node)) return false;
    if (resolve_expr.exprRank(self, expr_node) != 0) return false;
    const spec = resolve_expr.exprTypeSpec(self, expr_node) catch return false;
    if (spec.lowered_kind != .character) return false;
    return spec.kind_value == null or spec.kind_value.? == 1;
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

fn typeStringForProcedureTypeSpec(self: *context.Context, type_spec: symbols.TypeSpec) []const u8 {
    return switch (type_spec.lowered_kind) {
        .integer => std.fmt.allocPrint(self.arena, "INTEGER({d})", .{type_spec.kind_value orelse self.target_layout.default_integer_bits}) catch "INTEGER(4)",
        .real => std.fmt.allocPrint(self.arena, "REAL({d})", .{type_spec.kind_value orelse 4}) catch "REAL(4)",
        .double_precision => std.fmt.allocPrint(self.arena, "REAL({d})", .{type_spec.kind_value orelse 8}) catch "REAL(8)",
        .complex => std.fmt.allocPrint(self.arena, "COMPLEX({d})", .{type_spec.kind_value orelse 4}) catch "COMPLEX(4)",
        .complex_double => std.fmt.allocPrint(self.arena, "COMPLEX({d})", .{type_spec.kind_value orelse 8}) catch "COMPLEX(8)",
        .logical => std.fmt.allocPrint(self.arena, "LOGICAL({d})", .{type_spec.kind_value orelse self.target_layout.default_integer_bits}) catch "LOGICAL(4)",
        .character => blk: {
            const len_text = switch (type_spec.char_len_kind) {
                .assumed, .deferred => "*",
                .constant => std.fmt.allocPrint(self.arena, "{d}", .{type_spec.char_len orelse 1}) catch "1",
                .none => "1",
            };
            const kind_value = type_spec.kind_value orelse 1;
            break :blk if (kind_value == 1)
                std.fmt.allocPrint(self.arena, "CHARACTER({s})", .{len_text}) catch "CHARACTER(*)"
            else
                std.fmt.allocPrint(self.arena, "CHARACTER({s},{d})", .{ len_text, kind_value }) catch "CHARACTER(*)";
        },
        .derived => blk: {
            if (type_spec.assumed_type) break :blk "TYPE(*)";
            if (type_spec.polymorphic) {
                if (type_spec.derived_type_name) |name| {
                    break :blk std.fmt.allocPrint(self.arena, "CLASS({s})", .{name}) catch "CLASS(*)";
                }
                break :blk "CLASS(*)";
            }
            if (type_spec.derived_type_name) |name| {
                break :blk std.fmt.allocPrint(self.arena, "TYPE({s})", .{name}) catch "TYPE(*)";
            }
            break :blk "TYPE(*)";
        },
    };
}

pub fn typeMismatchArgumentMessage(self: *context.Context, actual: symbols.TypeSpec, formal: symbols.TypeSpec) []const u8 {
    return std.fmt.allocPrint(
        self.arena,
        "passed {s} to {s}",
        .{ typeStringForProcedureTypeSpec(self, actual), typeStringForProcedureTypeSpec(self, formal) },
    ) catch "Type mismatch in argument";
}

fn emitCharacterKindOneIntrinsicDiagnostic(
    self: *context.Context,
    expr_node: *ast.Expr,
    use_conversion_text: bool,
) CheckError {
    const message = if (use_conversion_text)
        std.fmt.allocPrint(self.arena, "'{s}' to 'CHARACTER(*)'", .{typeStringForCharacterActual(self, expr_node)}) catch "character kind mismatch"
    else
        "must be of kind 1";
    return emitIntrinsicArgDiagnostic(self, expr_node, message);
}

fn checkMoveAllocCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    if (duplicateKeywordActual(args, "stat")) |dup| return emitDuplicateIntrinsicKeywordDiagnostic(self, dup, "stat");
    if (duplicateKeywordActual(args, "errmsg")) |dup| return emitDuplicateIntrinsicKeywordDiagnostic(self, dup, "errmsg");

    const from_actual = nthOrKeywordActual(args, 0, "from");
    const to_actual = nthOrKeywordActual(args, 1, "to");

    if (from_actual) |actual| {
        if (moveAllocViolatesIntentIn(self, actual.value)) {
            return emitIntrinsicArgDiagnostic(self, actual.value, "cannot be INTENT(IN)");
        }
    }
    if (to_actual) |actual| {
        if (moveAllocViolatesIntentIn(self, actual.value)) {
            return emitIntrinsicArgDiagnostic(self, actual.value, "cannot be INTENT(IN)");
        }
    }
    if (from_actual != null and to_actual != null) {
        if (moveAllocDesignatorsConflict(from_actual.?.value, to_actual.?.value)) {
            return emitIntrinsicArgDiagnostic(self, to_actual.?.value, "violates aliasing restrictions");
        }
        const from_spec = resolve_expr.exprTypeSpec(self, from_actual.?.value) catch null;
        const to_spec = resolve_expr.exprTypeSpec(self, to_actual.?.value) catch null;
        if (from_spec != null and to_spec != null and from_spec.?.polymorphic and !to_spec.?.polymorphic) {
            return emitIntrinsicArgDiagnostic(self, to_actual.?.value, "must be polymorphic if FROM is polymorphic");
        }
    }

    if (nthOrKeywordActual(args, 2, "stat")) |actual| {
        if (!exprIsScalarIntegerVariableAtLeastKind(self, actual.value, 2)) {
            return emitIntrinsicArgDiagnostic(self, actual.value, "STAT= argument at (1) must be a scalar INTEGER variable of at least kind 2");
        }
    }
    if (nthOrKeywordActual(args, 3, "errmsg")) |actual| {
        if (!exprIsScalarCharacterVariableKindOne(self, actual.value)) {
            return emitIntrinsicArgDiagnostic(self, actual.value, "ERRMSG= argument at (1) must be a scalar CHARACTER variable of at least kind 1");
        }
    }
}

fn checkMvbitsCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    const from = nthOrKeywordActual(args, 0, "from") orelse return;
    const frompos = nthOrKeywordActual(args, 1, "frompos") orelse return;
    const len = nthOrKeywordActual(args, 2, "len") orelse return;
    const to = nthOrKeywordActual(args, 3, "to") orelse return;
    const topos = nthOrKeywordActual(args, 4, "topos") orelse return;

    const from_pos_value = try constIntegerScalarOrSingleElement(self, frompos.value) orelse return;
    const len_value = try constIntegerScalarOrSingleElement(self, len.value) orelse return;
    const to_pos_value = try constIntegerScalarOrSingleElement(self, topos.value) orelse return;
    if (from_pos_value < 0) return emitIntrinsicArgDiagnostic(self, frompos.value, "must be nonnegative");
    if (len_value < 0) return emitIntrinsicArgDiagnostic(self, len.value, "must be nonnegative");
    if (to_pos_value < 0) return emitIntrinsicArgDiagnostic(self, topos.value, "must be nonnegative");
    const from_bits = try integerStorageBits(self, from.value) orelse return;
    const to_bits = try integerStorageBits(self, to.value) orelse return;
    if (from_pos_value + len_value > from_bits) return emitIntrinsicArgDiagnostic(self, frompos.value, "must be less than");
    if (to_pos_value + len_value > to_bits) return emitIntrinsicArgDiagnostic(self, topos.value, "must be less than");
}

fn checkRandomInitCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    const repeatable = nthOrKeywordActual(args, 0, "repeatable");
    const image_distinct = nthOrKeywordActual(args, 1, "image_distinct");
    if (repeatable) |actual| try checkRandomInitLogicalScalar(self, actual.value);
    if (image_distinct) |actual| try checkRandomInitLogicalScalar(self, actual.value);
}

fn checkRandomInitLogicalScalar(self: *context.Context, expr_node: *ast.Expr) CheckError!void {
    if (resolve_expr.exprRank(self, expr_node) != 0) {
        return emitIntrinsicArgDiagnostic(self, expr_node, "must be a scalar");
    }
    const spec = try resolve_expr.exprTypeSpec(self, expr_node);
    if (spec.lowered_kind != .logical) {
        return emitIntrinsicArgDiagnostic(self, expr_node, "must be LOGICAL");
    }
}

fn checkRandomSeedCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    const size_actual = nthOrKeywordActual(args, 0, "size");
    const put_actual = nthOrKeywordActual(args, 1, "put");
    const get_actual = nthOrKeywordActual(args, 2, "get");

    if (size_actual) |actual| {
        if (moveAllocViolatesIntentIn(self, actual.value)) {
            return emitIntrinsicArgDiagnostic(self, actual.value, "cannot be INTENT(IN)");
        }
    }

    var guaranteed_present: usize = 0;
    if (size_actual) |actual| {
        if (!exprIsOptionalDummy(self, actual.value)) guaranteed_present += 1;
    }
    if (put_actual) |actual| {
        if (!exprIsOptionalDummy(self, actual.value)) guaranteed_present += 1;
    }
    if (get_actual) |actual| {
        if (!exprIsOptionalDummy(self, actual.value)) guaranteed_present += 1;
    }
    if (guaranteed_present > 1) {
        const diagnostic_actual = get_actual orelse put_actual orelse size_actual orelse return;
        return emitIntrinsicArgDiagnostic(self, diagnostic_actual.value, "Too many arguments");
    }
}

fn exprIsOptionalDummy(self: *context.Context, expr_node: *ast.Expr) bool {
    const name = switch (expr_node.*) {
        .identifier => |ident| ident,
        else => return false,
    };
    for (self.unit.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                if (!type_decl.optional) continue;
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .procedure => |procedure_decl| {
                if (!procedure_decl.optional) continue;
                for (procedure_decl.items) |item| {
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

fn moveAllocViolatesIntentIn(self: *context.Context, expr_node: *ast.Expr) bool {
    return switch (expr_node.*) {
        .identifier => |name| blk: {
            const sig = resolve_symbols.lookupKnownProcedureSig(self, self.unit.name) orelse break :blk false;
            for (sig.args) |arg| {
                if (!std.ascii.eqlIgnoreCase(arg.name, name)) continue;
                break :blk arg.intent == .in and !arg.pointer;
            }
            break :blk false;
        },
        .component => |comp| blk: {
            if (exprHasPointerAttribute(self, comp.base)) break :blk false;
            break :blk moveAllocViolatesIntentIn(self, comp.base);
        },
        else => false,
    };
}

fn moveAllocDesignatorsConflict(a: *ast.Expr, b: *ast.Expr) bool {
    return sameMoveAllocDesignator(a, b) or moveAllocAncestorOf(a, b) or moveAllocAncestorOf(b, a);
}

fn sameMoveAllocDesignator(a: *ast.Expr, b: *ast.Expr) bool {
    return switch (a.*) {
        .identifier => switch (b.*) {
            .identifier => std.ascii.eqlIgnoreCase(a.identifier, b.identifier),
            else => false,
        },
        .component => |a_comp| switch (b.*) {
            .component => |b_comp| !a_comp.has_parens and !b_comp.has_parens and std.ascii.eqlIgnoreCase(a_comp.name, b_comp.name) and sameMoveAllocDesignator(a_comp.base, b_comp.base),
            else => false,
        },
        else => false,
    };
}

fn moveAllocAncestorOf(ancestor: *ast.Expr, expr_node: *ast.Expr) bool {
    var current = moveAllocParentDesignator(expr_node);
    while (current) |parent| : (current = moveAllocParentDesignator(parent)) {
        if (sameMoveAllocDesignator(ancestor, parent)) return true;
    }
    return false;
}

fn moveAllocParentDesignator(expr_node: *ast.Expr) ?*ast.Expr {
    return switch (expr_node.*) {
        .component => |comp| comp.base,
        else => null,
    };
}

fn checkDateAndTimeCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    const date = nthOrKeywordActual(args, 0, "date");
    const time = nthOrKeywordActual(args, 1, "time");
    const zone = nthOrKeywordActual(args, 2, "zone");
    for ([_]?IntrinsicCallActual{ date, time, zone }) |actual_opt| {
        const actual = actual_opt orelse continue;
        if (!exprIsScalarCharacterVariableKindOne(self, actual.value)) {
            return emitCharacterKindOneIntrinsicDiagnostic(self, actual.value, false);
        }
    }
}

fn checkGetCommandCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    if (nthOrKeywordActual(args, 0, "command")) |actual| {
        if (!exprIsScalarCharacterVariableKindOne(self, actual.value)) {
            return emitCharacterKindOneIntrinsicDiagnostic(self, actual.value, true);
        }
    }
}

fn checkGetCommandArgumentCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    if (nthOrKeywordActual(args, 1, "value")) |actual| {
        if (!exprIsScalarCharacterVariableKindOne(self, actual.value)) {
            return emitCharacterKindOneIntrinsicDiagnostic(self, actual.value, true);
        }
    }
}

fn checkGetEnvironmentVariableCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    if (nthOrKeywordActual(args, 0, "name")) |actual| {
        if (!exprIsScalarCharacterKindOne(self, actual.value)) {
            return emitCharacterKindOneIntrinsicDiagnostic(self, actual.value, true);
        }
    }
    if (nthOrKeywordActual(args, 1, "value")) |actual| {
        if (!exprIsScalarCharacterVariableKindOne(self, actual.value)) {
            return emitCharacterKindOneIntrinsicDiagnostic(self, actual.value, true);
        }
    }
}

fn checkLegacyWidecharCallConstraints(self: *context.Context, name: []const u8, args: []const ast.CallArg) CheckError!void {
    const conversion_style =
        std.ascii.eqlIgnoreCase(name, "getenv") or
        std.ascii.eqlIgnoreCase(name, "system");
    const char_positions: ?[]const usize = blk: {
        if (std.ascii.eqlIgnoreCase(name, "ctime")) break :blk &.{1};
        if (std.ascii.eqlIgnoreCase(name, "chdir")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "chmod")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "fdate")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "gerror")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "getcwd")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "getenv")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "getarg")) break :blk &.{1};
        if (std.ascii.eqlIgnoreCase(name, "getlog")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "fgetc")) break :blk &.{1};
        if (std.ascii.eqlIgnoreCase(name, "fget")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "fputc")) break :blk &.{1};
        if (std.ascii.eqlIgnoreCase(name, "fput")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "hostnm")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "link")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "perror")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "rename")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "lstat")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "stat")) break :blk &.{0};
        if (std.ascii.eqlIgnoreCase(name, "symlnk")) break :blk &.{ 0, 1 };
        if (std.ascii.eqlIgnoreCase(name, "system")) break :blk &.{0};
        break :blk null;
    };
    if (char_positions) |positions| {
        for (positions) |pos| {
            if (nthOrKeywordActual(args, pos, null)) |actual| {
                if (!exprIsScalarCharacterVariableKindOne(self, actual.value)) {
                    return emitCharacterKindOneIntrinsicDiagnostic(self, actual.value, conversion_style);
                }
            }
        }
    }
}

const CFPointerActuals = struct {
    cptr: ?*ast.Expr = null,
    fptr: ?*ast.Expr = null,
    shape: ?*ast.Expr = null,
};

fn collectCFPointerActuals(args: []const ast.CallArg) CFPointerActuals {
    var actuals: CFPointerActuals = .{};
    var positional_idx: usize = 0;
    for (args) |arg| {
        switch (arg) {
            .alt_return => {},
            .expr => |actual| {
                if (actual.keyword) |keyword| {
                    if (std.ascii.eqlIgnoreCase(keyword, "cptr")) {
                        actuals.cptr = actual.value;
                    } else if (std.ascii.eqlIgnoreCase(keyword, "fptr")) {
                        actuals.fptr = actual.value;
                    } else if (std.ascii.eqlIgnoreCase(keyword, "shape")) {
                        actuals.shape = actual.value;
                    }
                    continue;
                }
                switch (positional_idx) {
                    0 => actuals.cptr = actual.value,
                    1 => actuals.fptr = actual.value,
                    2 => actuals.shape = actual.value,
                    else => {},
                }
                positional_idx += 1;
            },
        }
    }
    return actuals;
}

fn checkCFPointerCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    const actuals = collectCFPointerActuals(args);
    if (actuals.cptr) |cptr| {
        const spec = try resolve_expr.exprTypeSpec(self, cptr);
        if (!isIsoCBindingDerivedType(self, spec, "c_ptr")) {
            return emitIntrinsicArgDiagnostic(self, cptr, "Argument CPTR at (1) to C_F_POINTER shall have the type TYPE(C_PTR).");
        }
    }
    const fptr = actuals.fptr orelse return;
    if (!exprHasPointerAttribute(self, fptr)) {
        return emitIntrinsicArgDiagnostic(self, fptr, "Argument FPTR at (2) to C_F_POINTER must be a pointer");
    }
    const fptr_spec = try resolve_expr.exprTypeSpec(self, fptr);
    if (fptr_spec.polymorphic) {
        return emitIntrinsicArgDiagnostic(self, fptr, "Argument FPTR at (2) to C_F_POINTER shall not be polymorphic");
    }
    const fptr_rank = resolve_expr.exprRank(self, fptr);
    const shape = actuals.shape orelse {
        if (fptr_rank != 0) return emitIntrinsicArgDiagnostic(self, fptr, "Expected SHAPE argument to C_F_POINTER with array FPTR");
        return;
    };
    if (fptr_rank == 0) return emitIntrinsicArgDiagnostic(self, shape, "Unexpected SHAPE argument at (1) to C_F_POINTER with scalar FPTR");
    if (resolve_expr.exprRank(self, shape) != 1) return emitIntrinsicArgDiagnostic(self, shape, "SHAPE argument to C_F_POINTER must be of rank 1");
    const shape_spec = try resolve_expr.exprTypeSpec(self, shape);
    if (shape_spec.lowered_kind != .integer) return emitIntrinsicArgDiagnostic(self, shape, "SHAPE argument to C_F_POINTER must be INTEGER");
}

fn checkCFProcPointerCallConstraints(self: *context.Context, args: []const ast.CallArg) CheckError!void {
    const actuals = collectCFPointerActuals(args);
    const cptr = actuals.cptr orelse return;
    const spec = try resolve_expr.exprTypeSpec(self, cptr);
    if (isIsoCBindingDerivedType(self, spec, "c_funptr")) return;
    return emitIntrinsicArgDiagnostic(self, cptr, "Argument CPTR at (1) to C_F_PROCPOINTER shall have the type TYPE(C_FUNPTR).");
}

fn isIsoCBindingDerivedType(self: *context.Context, spec: symbols.TypeSpec, expected_name: []const u8) bool {
    if (spec.lowered_kind != .derived) return false;
    const actual_name = spec.derived_type_name orelse return false;
    if (std.ascii.eqlIgnoreCase(actual_name, expected_name)) return true;
    const strict_c_handle =
        std.ascii.eqlIgnoreCase(expected_name, "c_ptr") or
        std.ascii.eqlIgnoreCase(expected_name, "c_funptr");
    if (resolve_symbols.findSymbolIndex(self, actual_name)) |idx| {
        const alias_sym = self.symbols.items[idx];
        if (alias_sym.type_spec.lowered_kind == .derived) {
            if (alias_sym.type_spec.derived_type_name) |canonical_name| {
                if (std.ascii.eqlIgnoreCase(canonical_name, expected_name)) return true;
                if (!strict_c_handle and resolve_symbols.areConcreteDerivedTypesCompatible(self, expected_name, canonical_name)) return true;
            }
        }
    }
    if (isoCBindingAliasMatches(actual_name, expected_name)) return true;
    if (strict_c_handle) return false;
    return resolve_symbols.areConcreteDerivedTypesCompatible(self, expected_name, actual_name);
}

fn isoCBindingAliasMatches(actual_name: []const u8, expected_name: []const u8) bool {
    var actual_buf: [128]u8 = undefined;
    var expected_buf: [32]u8 = undefined;
    if (actual_name.len > actual_buf.len or expected_name.len > expected_buf.len) return false;
    for (actual_name, 0..) |ch, i| actual_buf[i] = std.ascii.toLower(ch);
    for (expected_name, 0..) |ch, i| expected_buf[i] = std.ascii.toLower(ch);
    const actual = actual_buf[0..actual_name.len];
    const expected = expected_buf[0..expected_name.len];
    return std.mem.indexOf(u8, actual, expected) != null;
}

fn emitIntrinsicArgDiagnostic(self: *context.Context, expr_node: *ast.Expr, message: []const u8) CheckError {
    return expr_diagnostics.emitExprInvalidArgument(self, expr_node, message);
}

fn exprHasPointerAttribute(self: *context.Context, expr_node: *ast.Expr) bool {
    return expr_attributes.isPointerEntity(self, expr_node);
}
