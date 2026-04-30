const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const symbols = @import("../../symbol/mod.zig");
const evaluator = @import("../../evaluator.zig");
const literal_utils = @import("../../evaluator/literals.zig");
const context = @import("../context.zig");
const symbols_mod = @import("../resolve_symbols.zig");
const constants = @import("../resolve_const.zig");
const type_kind_selector = @import("../../type_kind_selector.zig");

pub fn resolveArrayConstructorTypeSpec(
    self: *context.Context,
    type_spec: ast.ArrayConstructorTypeSpec,
) anyerror!symbols.TypeSpec {
    if (type_spec.type_kind == .derived) {
        if (type_spec.derived_type_name) |derived_name| {
            if (!symbols_mod.hasDerivedType(self, derived_name)) return error.UnexpectedTypeDecl;
            return symbols.TypeSpec.fromDerived(derived_name).withPolymorphic(type_spec.polymorphic).withAssumedType(type_spec.assumed_type);
        }
        return symbols.TypeSpec.fromKind(.derived).withPolymorphic(type_spec.polymorphic).withAssumedType(type_spec.assumed_type);
    }
    const selector_value = if (type_spec.kind_selector) |selector| blk: {
        const const_value = (try constants.evalConst(self, selector)) orelse {
            emitArrayConstructorKindSelectorDiagnostic(self, selector);
            return error.InvalidCharLen;
        };
        switch (const_value) {
            .integer => {},
            else => {
                emitArrayConstructorKindSelectorDiagnostic(self, selector);
                return error.InvalidCharLen;
            },
        }
        break :blk const_value;
    } else null;
    return type_kind_selector.resolveSpecWithConst(type_spec.type_kind, type_spec.kind_selector, selector_value)
        .withPolymorphic(type_spec.polymorphic)
        .withAssumedType(type_spec.assumed_type);
}

fn emitArrayConstructorKindSelectorDiagnostic(self: *context.Context, selector: *ast.Expr) void {
    const source = self.sourceForExpr(selector) orelse self.current_source orelse ast.SourceRef{};
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_char_len.code,
        "Scalar INTEGER expression",
        source.text,
    );
}

pub fn mergeArrayConstructorItemTypeSpec(first: symbols.TypeSpec, next: symbols.TypeSpec) symbols.TypeSpec {
    if (first.lowered_kind == next.lowered_kind) {
        if (first.lowered_kind == .character) {
            if (first.char_len_kind == .deferred) return first;
            if (next.char_len_kind == .deferred) return next;
            const first_len = first.char_len orelse return first;
            const next_len = next.char_len orelse return next;
            return if (next_len > first_len) next else first;
        }
        return first;
    }
    const promoted = promoteNumericType(first.lowered_kind, next.lowered_kind);
    return symbols.TypeSpec.fromResolvedKind(promoted, promoted, null);
}

pub fn promoteNumericType(left: ast.TypeKind, right: ast.TypeKind) ast.TypeKind {
    if (!isNumericType(left) or !isNumericType(right)) return .integer;
    if (left == .complex_double or right == .complex_double) return .complex_double;
    if (left == .complex or right == .complex) {
        if (left == .double_precision or right == .double_precision) return .complex_double;
        return .complex;
    }
    if (left == .double_precision or right == .double_precision) return .double_precision;
    if (left == .real or right == .real) return .real;
    return .integer;
}

pub fn isPowerOperandSupported(kind: ast.TypeKind) bool {
    return switch (kind) {
        .integer, .real, .double_precision, .complex, .complex_double => true,
        else => false,
    };
}

pub fn validateBinaryOperands(op: ast.BinaryOp, left_kind: ast.TypeKind, right_kind: ast.TypeKind) !void {
    switch (op) {
        .add, .sub, .mul, .div => {
            if (!isNumericType(left_kind) or !isNumericType(right_kind)) return error.InvalidArithmeticOperands;
        },
        .power => {
            if (!isNumericType(left_kind) or !isNumericType(right_kind)) return error.InvalidArithmeticOperands;
            if ((left_kind == .complex or left_kind == .complex_double) and right_kind == .integer) return;
            if (!isPowerOperandSupported(left_kind) or !isPowerOperandSupported(right_kind)) return error.PowerUnsupported;
        },
        .and_, .or_, .eqv, .neqv => {
            if (!isLogicalType(left_kind) or !isLogicalType(right_kind)) return error.InvalidArithmeticOperands;
        },
        .eq, .ne => {
            if ((isNumericType(left_kind) and isNumericType(right_kind)) or
                (isCharacterType(left_kind) and isCharacterType(right_kind))) return;
            return error.InvalidArithmeticOperands;
        },
        .lt, .le, .gt, .ge => {
            if ((isNumericType(left_kind) and isNumericType(right_kind)) or
                (isCharacterType(left_kind) and isCharacterType(right_kind))) return;
            return error.InvalidArithmeticOperands;
        },
        .concat => {
            if (!isCharacterType(left_kind) or !isCharacterType(right_kind)) return error.InvalidArithmeticOperands;
        },
    }
}

pub fn literalTypeSpec(lit: ast.Literal) symbols.TypeSpec {
    return switch (lit.kind) {
        .integer => symbols.TypeSpec.fromResolvedKind(.integer, .integer, integerLiteralKindValue(lit.text)),
        .real => realLiteralTypeSpec(lit.text),
        .logical => symbols.TypeSpec.fromResolvedKind(.logical, .logical, integerLiteralKindValue(lit.text)),
        .string, .hollerith => symbols.TypeSpec.fromResolvedKind(.character, .character, null).withCharacterLength(.constant, literal_utils.literalByteLen(lit) orelse lit.text.len),
        .assumed_size => symbols.TypeSpec.fromResolvedKind(.integer, .integer, null),
    };
}

pub fn literalTypeSpecWithContext(self: *context.Context, lit: ast.Literal) symbols.TypeSpec {
    if (lit.kind != .string) return literalTypeSpec(lit);
    const kind_value = characterLiteralKindValue(self, lit.text);
    return symbols.TypeSpec.fromResolvedKind(.character, .character, kind_value)
        .withCharacterLength(.constant, literal_utils.literalByteLen(lit) orelse lit.text.len);
}

pub fn realLiteralTypeKind(text: []const u8) ast.TypeKind {
    return if (evaluator.realLiteralHasDoublePrecisionHint(text)) .double_precision else .real;
}

pub fn realLiteralTypeSpec(text: []const u8) symbols.TypeSpec {
    const kind = realLiteralTypeKind(text);
    return symbols.TypeSpec.fromResolvedKind(
        .real,
        kind,
        if (kind == .double_precision) 8 else realLiteralKindSuffix(text),
    );
}

pub fn realLiteralKindSuffix(text: []const u8) ?i64 {
    const underscore = std.mem.lastIndexOfScalar(u8, text, '_') orelse return null;
    if (underscore + 1 >= text.len) return null;
    return std.fmt.parseInt(i64, text[underscore + 1 ..], 10) catch null;
}

pub fn integerLiteralKindValue(text: []const u8) ?i64 {
    const underscore = std.mem.lastIndexOfScalar(u8, text, '_') orelse return null;
    if (underscore + 1 >= text.len) return null;
    return std.fmt.parseInt(i64, text[underscore + 1 ..], 10) catch null;
}

fn isNumericType(kind: ast.TypeKind) bool {
    return switch (kind) {
        .integer, .real, .double_precision, .complex, .complex_double => true,
        else => false,
    };
}

fn isLogicalType(kind: ast.TypeKind) bool {
    return kind == .logical;
}

fn isCharacterType(kind: ast.TypeKind) bool {
    return kind == .character;
}

fn characterLiteralKindValue(self: *context.Context, text: []const u8) ?i64 {
    const prefix = literal_utils.characterLiteralKindPrefix(text) orelse return null;
    var all_digits = prefix.len != 0;
    for (prefix) |ch| {
        if (!std.ascii.isDigit(ch)) {
            all_digits = false;
            break;
        }
    }
    if (all_digits) return std.fmt.parseInt(i64, prefix, 10) catch null;
    if (symbols_mod.findSymbolIndex(self, prefix)) |idx| {
        return switch (self.symbols.items[idx].const_value orelse return null) {
            .integer => |value| value,
            else => null,
        };
    }
    if (self.known_host_parameters.get(prefix)) |sym| {
        return switch (sym.const_value orelse return null) {
            .integer => |value| value,
            else => null,
        };
    }
    return null;
}
