const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");
const symbols_mod = @import("resolve_symbols.zig");
const constants = @import("resolve_const.zig");
const resolve_expr = @import("resolve_expr.zig");

pub fn validateDeclaratorInitializer(self: *context.Context, init_expr: ?*ast.Expr) !void {
    const expr = init_expr orelse return;
    if (findDisallowedInitializationIntrinsic(expr)) |intrinsic_name| {
        const decl_source = self.current_decl_source orelse ast.DeclSource{};
        const line = if (decl_source.line == 0) 1 else decl_source.line;
        const column = if (decl_source.column == 0) 1 else decl_source.column;
        const message = std.fmt.allocPrint(
            self.arena,
            "Intrinsic function '{s}' is not permitted in an initialization expression",
            .{intrinsic_name},
        ) catch "Intrinsic function is not permitted in an initialization expression";
        self.setDiagnostic(
            line,
            column,
            catalog.semantic.parameter_not_constant.code,
            message,
            decl_source.text,
        );
        return error.ParameterNotConstant;
    }
    try validateInvalidDerivedArrayConstructorInitializer(self, expr);
    try validateRestrictedInitializationInquiry(self, expr);
}

pub fn validateCharacterArrayConstructorInitializer(
    self: *context.Context,
    sym: symbols.Symbol,
    init_expr: ?*ast.Expr,
) !void {
    const expr = init_expr orelse return;
    if (!sym.isCharacter() or sym.dims.len == 0) return;
    const ctor = switch (expr.*) {
        .array_constructor => |ctor| ctor,
        else => return,
    };
    var expected_len: ?usize = null;
    for (ctor.items) |item| {
        const item_len = characterExprLogicalLen(self, item) orelse return;
        if (expected_len == null) {
            expected_len = item_len;
            continue;
        }
        if (expected_len.? != item_len) {
            const decl_source = self.current_decl_source orelse ast.DeclSource{};
            self.setDiagnostic(
                if (decl_source.line == 0) 1 else decl_source.line,
                if (decl_source.column == 0) 1 else decl_source.column,
                catalog.semantic.invalid_argument_count.code,
                "Different CHARACTER lengths in array constructor",
                decl_source.text,
            );
            return error.InvalidArgumentCount;
        }
    }
}

pub fn isoCBindingCharacterKindShorthandType(
    self: *context.Context,
    char_len_expr: ?*ast.Expr,
) !?symbols.TypeSpec {
    const expr_node = char_len_expr orelse return null;
    const name = switch (expr_node.*) {
        .identifier => |ident| ident,
        else => return null,
    };
    if (!std.ascii.eqlIgnoreCase(name, "c_char")) return null;
    const builtin = symbols_mod.findBuiltinModuleConstant(self, "iso_c_binding", name) orelse return null;
    if (builtin.type_spec.lowered_kind != .integer) return null;
    return symbols.TypeSpec.fromResolvedKind(.character, .character, builtin.value.integer).withCharacterLength(.constant, 1);
}

pub fn characterExprLogicalLen(self: *context.Context, expr: *ast.Expr) ?usize {
    return switch (expr.*) {
        .literal => |lit| switch (lit.kind) {
            .string, .hollerith => @import("../evaluator/literals.zig").literalByteLen(lit),
            else => null,
        },
        else => blk: {
            const spec = resolve_expr.exprTypeSpec(self, expr) catch break :blk null;
            if (spec.lowered_kind != .character) break :blk null;
            break :blk switch (spec.char_len_kind) {
                .constant => spec.char_len,
                .none => spec.char_len orelse 1,
                .assumed, .deferred => null,
            };
        },
    };
}

fn validateRestrictedInitializationInquiry(self: *context.Context, init_expr: ?*ast.Expr) !void {
    const expr = init_expr orelse return;
    const intrinsic_name = findNonReducingInitializationInquiry(self, expr) orelse return;
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    const line = if (decl_source.line == 0) 1 else decl_source.line;
    const column = if (decl_source.column == 0) 1 else decl_source.column;
    const message = std.fmt.allocPrint(
        self.arena,
        "Intrinsic inquiry '{s}' does not reduce to a constant expression in this initialization expression",
        .{intrinsic_name},
    ) catch "Initialization expression does not reduce to a constant expression";
    self.setDiagnostic(
        line,
        column,
        catalog.semantic.parameter_not_constant.code,
        message,
        decl_source.text,
    );
    return error.ParameterNotConstant;
}

fn findNonReducingInitializationInquiry(self: *context.Context, expr: *ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .call_or_subscript => |call| {
            if (isRestrictedInitializationInquiry(call.name) and call.args.len >= 1 and
                inquirySubjectNeedsRuntimeBounds(self, call.args[0]))
            {
                return call.name;
            }
            for (call.args) |arg| {
                if (findNonReducingInitializationInquiry(self, arg)) |name| return name;
            }
            return null;
        },
        .unary => |un| findNonReducingInitializationInquiry(self, un.expr),
        .binary => |bin| findNonReducingInitializationInquiry(self, bin.left) orelse findNonReducingInitializationInquiry(self, bin.right),
        .component => |comp| findNonReducingInitializationInquiry(self, comp.base),
        .substring => |sub| blk: {
            for (sub.args) |arg| {
                if (findNonReducingInitializationInquiry(self, arg)) |name| break :blk name;
            }
            if (sub.start) |start| {
                if (findNonReducingInitializationInquiry(self, start)) |name| break :blk name;
            }
            if (sub.end) |end| {
                if (findNonReducingInitializationInquiry(self, end)) |name| break :blk name;
            }
            break :blk null;
        },
        .dim_range => |range| blk: {
            if (range.lower) |lower| {
                if (findNonReducingInitializationInquiry(self, lower)) |name| break :blk name;
            }
            if (findNonReducingInitializationInquiry(self, range.upper)) |name| break :blk name;
            if (range.stride) |stride| {
                if (findNonReducingInitializationInquiry(self, stride)) |name| break :blk name;
            }
            break :blk null;
        },
        .array_constructor => |ctor| blk: {
            for (ctor.items) |item| {
                if (findNonReducingInitializationInquiry(self, item)) |name| break :blk name;
            }
            break :blk null;
        },
        .complex_literal => |lit| findNonReducingInitializationInquiry(self, lit.real) orelse findNonReducingInitializationInquiry(self, lit.imag),
        .implied_do => |ido| blk: {
            for (ido.items) |item| {
                if (findNonReducingInitializationInquiry(self, item)) |name| break :blk name;
            }
            if (findNonReducingInitializationInquiry(self, ido.start)) |name| break :blk name;
            if (findNonReducingInitializationInquiry(self, ido.end)) |name| break :blk name;
            if (ido.step) |step| {
                if (findNonReducingInitializationInquiry(self, step)) |name| break :blk name;
            }
            break :blk null;
        },
        else => null,
    };
}

fn isRestrictedInitializationInquiry(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "lbound") or
        std.ascii.eqlIgnoreCase(name, "ubound") or
        std.ascii.eqlIgnoreCase(name, "shape") or
        std.ascii.eqlIgnoreCase(name, "size");
}

fn inquirySubjectNeedsRuntimeBounds(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = symbols_mod.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk sym.is_allocatable or sym.is_pointer;
        },
        else => false,
    };
}

fn validateInvalidDerivedArrayConstructorInitializer(self: *context.Context, expr: *ast.Expr) !void {
    const decl_source = self.current_decl_source orelse return;
    if (expr.* != .array_constructor) return;

    const target_name = declarationTargetNameFromSource(decl_source.text) orelse return;
    const idx = symbols_mod.findSymbolIndex(self, target_name) orelse return;
    const sym = self.symbols.items[idx];
    if (sym.dims.len == 0) return;
    if (sym.type_spec.lowered_kind != .derived) return;
    const derived_name = sym.type_spec.derived_type_name orelse return;
    if (!derivedTypeHasNonConstantCharacterComponentLen(self, derived_name)) return;

    self.setDiagnostic(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.parser.unexpected_token.code,
        "Syntax error in array constructor",
        decl_source.text,
    );
    return error.UnexpectedToken;
}

fn declarationTargetNameFromSource(text: []const u8) ?[]const u8 {
    const dbl_colon = std.mem.indexOf(u8, text, "::") orelse return null;
    const after = std.mem.trimLeft(u8, text[dbl_colon + 2 ..], " \t");
    if (after.len == 0) return null;
    var end: usize = 0;
    while (end < after.len) : (end += 1) {
        const ch = after[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
    }
    if (end == 0) return null;
    return after[0..end];
}

fn derivedTypeHasNonConstantCharacterComponentLen(self: *context.Context, derived_name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .derived_type_def) continue;
        if (!std.ascii.eqlIgnoreCase(decl.derived_type_def.name, derived_name)) continue;
        for (decl.derived_type_def.components) |type_decl| {
            if (type_decl.type_kind != .character) continue;
            for (type_decl.items) |item| {
                if (item.char_len_deferred) return true;
                const len_expr = item.char_len orelse continue;
                const value = constants.evalConst(self, len_expr) catch return true;
                switch (value orelse return true) {
                    .integer => {},
                    else => return true,
                }
            }
        }
        return false;
    }
    return false;
}

fn findDisallowedInitializationIntrinsic(expr: *ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .call_or_subscript => |call| {
            if (std.ascii.eqlIgnoreCase(call.name, "c_loc") or std.ascii.eqlIgnoreCase(call.name, "c_funloc")) {
                return call.name;
            }
            for (call.args) |arg| {
                if (findDisallowedInitializationIntrinsic(arg)) |name| return name;
            }
            return null;
        },
        .unary => |un| findDisallowedInitializationIntrinsic(un.expr),
        .binary => |bin| findDisallowedInitializationIntrinsic(bin.left) orelse findDisallowedInitializationIntrinsic(bin.right),
        .component => |comp| findDisallowedInitializationIntrinsic(comp.base),
        .substring => |sub| blk: {
            for (sub.args) |arg| {
                if (findDisallowedInitializationIntrinsic(arg)) |name| break :blk name;
            }
            if (sub.start) |start| {
                if (findDisallowedInitializationIntrinsic(start)) |name| break :blk name;
            }
            if (sub.end) |end| {
                if (findDisallowedInitializationIntrinsic(end)) |name| break :blk name;
            }
            break :blk null;
        },
        .dim_range => |range| blk: {
            if (range.lower) |lower| {
                if (findDisallowedInitializationIntrinsic(lower)) |name| break :blk name;
            }
            if (findDisallowedInitializationIntrinsic(range.upper)) |name| break :blk name;
            if (range.stride) |stride| {
                if (findDisallowedInitializationIntrinsic(stride)) |name| break :blk name;
            }
            break :blk null;
        },
        .array_constructor => |ctor| blk: {
            for (ctor.items) |item| {
                if (findDisallowedInitializationIntrinsic(item)) |name| break :blk name;
            }
            break :blk null;
        },
        .complex_literal => |lit| findDisallowedInitializationIntrinsic(lit.real) orelse findDisallowedInitializationIntrinsic(lit.imag),
        .implied_do => |ido| blk: {
            for (ido.items) |item| {
                if (findDisallowedInitializationIntrinsic(item)) |name| break :blk name;
            }
            if (findDisallowedInitializationIntrinsic(ido.start)) |name| break :blk name;
            if (findDisallowedInitializationIntrinsic(ido.end)) |name| break :blk name;
            if (ido.step) |step| {
                if (findDisallowedInitializationIntrinsic(step)) |name| break :blk name;
            }
            break :blk null;
        },
        else => null,
    };
}
