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

pub fn validateDataPointerInitializer(
    self: *context.Context,
    decl: ast.TypeDecl,
    target_spec: symbols.TypeSpec,
    item: ast.Declarator,
) !void {
    if (!decl.pointer) return;
    const init_expr = item.init orelse return;
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    if (std.mem.indexOf(u8, decl_source.text, "=>") == null) return;
    if (std.ascii.indexOfIgnoreCase(decl_source.text, "null(") != null) return;

    const target = pointerInitializerTargetInfo(self, init_expr) orelse {
        emitDeclInitializerDiagnostic(self, "Error in pointer initialization");
        return error.AssignmentTypeMismatch;
    };
    if (!target.exists) {
        emitDeclInitializerDiagnostic(self, "has no IMPLICIT type");
        return error.UnknownSymbol;
    }
    if (target.allocatable) {
        emitDeclInitializerDiagnostic(self, "must not be ALLOCATABLE");
        return error.AssignmentTypeMismatch;
    }
    if (!target.target or target.pointer) {
        emitDeclInitializerDiagnostic(self, "Pointer assignment target in initialization expression does not have the TARGET attribute");
        return error.AssignmentTypeMismatch;
    }
    if (pointerInitializerNeedsSave(self, target.name)) {
        emitDeclInitializerDiagnostic(self, "Pointer initialization target must have the SAVE attribute");
        return error.AssignmentTypeMismatch;
    }
    if (target.rank != item.dims.len) {
        emitDeclInitializerDiagnostic(self, "Different ranks in pointer assignment");
        return error.AssignmentTypeMismatch;
    }
    if (target.type_spec.lowered_kind != target_spec.lowered_kind) {
        emitDeclInitializerDiagnostic(self, "Different types in pointer assignment");
        return error.AssignmentTypeMismatch;
    }
}

pub fn validateProcedurePointerInitializer(
    self: *context.Context,
    decl: ast.ProcedureDecl,
    item: ast.Declarator,
) !void {
    if (!decl.pointer) return;
    const init_expr = item.init orelse return;
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    if (std.mem.indexOf(u8, decl_source.text, "=>") == null) return;
    if (std.ascii.indexOfIgnoreCase(decl_source.text, "null(") != null) return;

    if (init_expr.* == .identifier) {
        const name = init_expr.identifier;
        if (symbols_mod.findSymbolIndex(self, name)) |idx| {
            if (self.symbols.items[idx].is_pointer) {
                emitDeclInitializerDiagnostic(self, "may not be a procedure pointer");
                return error.AssignmentTypeMismatch;
            }
        }
    }
    if (self.unit.kind == .subroutine or self.unit.kind == .function) {
        emitDeclInitializerDiagnostic(self, "invalid in procedure pointer initialization");
        return error.AssignmentTypeMismatch;
    }
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
    if (ctor.type_spec != null) return;
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

const PointerInitializerTargetInfo = struct {
    name: []const u8,
    exists: bool = true,
    type_spec: symbols.TypeSpec = symbols.TypeSpec.fromKind(.real),
    rank: usize = 0,
    target: bool = false,
    pointer: bool = false,
    allocatable: bool = false,
};

fn pointerInitializerTargetInfo(self: *context.Context, expr: *ast.Expr) ?PointerInitializerTargetInfo {
    return switch (expr.*) {
        .identifier => |name| identifierPointerTargetInfo(self, name),
        .component => |comp| componentPointerTargetInfo(self, comp),
        else => null,
    };
}

fn identifierPointerTargetInfo(self: *context.Context, name: []const u8) PointerInitializerTargetInfo {
    const idx = symbols_mod.findSymbolIndex(self, name) orelse return .{ .name = name, .exists = false };
    const sym = self.symbols.items[idx];
    return .{
        .name = name,
        .type_spec = sym.type_spec,
        .rank = sym.dims.len,
        .target = sym.is_target,
        .pointer = sym.is_pointer,
        .allocatable = sym.is_allocatable,
    };
}

fn componentPointerTargetInfo(self: *context.Context, comp: ast.ComponentExpr) ?PointerInitializerTargetInfo {
    const base_name = switch (comp.base.*) {
        .identifier => |name| name,
        else => return null,
    };
    const base_idx = symbols_mod.findSymbolIndex(self, base_name) orelse return .{ .name = base_name, .exists = false };
    const base_sym = self.symbols.items[base_idx];
    const derived_name = base_sym.type_spec.derived_type_name orelse return null;
    const component = symbols_mod.lookupDerivedComponent(self, derived_name, comp.name) orelse return null;
    return .{
        .name = base_name,
        .type_spec = component.type_spec,
        .rank = component.dims.len,
        .target = base_sym.is_target and !component.pointer,
        .pointer = component.pointer,
        .allocatable = base_sym.is_allocatable or component.allocatable,
    };
}

fn pointerInitializerNeedsSave(self: *context.Context, name: []const u8) bool {
    if (self.unit.kind == .module or self.unit.kind == .program) return false;
    if (declarationHasSaveAttribute(self.unit, name)) return false;
    return true;
}

fn declarationHasSaveAttribute(unit: ast.ProgramUnit, name: []const u8) bool {
    for (unit.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                if (!type_decl.save) continue;
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .save => |save_decl| {
                if (save_decl.save_all) return true;
                for (save_decl.items) |save_item| {
                    switch (save_item) {
                        .name => |save_name| if (std.ascii.eqlIgnoreCase(save_name, name)) return true,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn emitDeclInitializerDiagnostic(self: *context.Context, message: []const u8) void {
    const decl_source = self.current_decl_source orelse ast.DeclSource{};
    self.setDiagnostic(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.assignment_type_mismatch.code,
        message,
        decl_source.text,
    );
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
    const after = std.mem.trimStart(u8, text[dbl_colon + 2 ..], " \t");
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
