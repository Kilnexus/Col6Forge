const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const catalog = @import("../../../../common/error_catalog.zig");
const symbols = @import("../../../symbol/mod.zig");
const context = @import("../../context.zig");
const constants = @import("../../resolve_const.zig");
const resolve_expr = @import("../../resolve_expr.zig");
const resolve_symbols = @import("../../resolve_symbols.zig");
const type_kind_selector = @import("../../../type_kind_selector.zig");
const options = @import("options.zig");
const targets = @import("targets.zig");

pub const CheckError = anyerror;

const CharacterAllocateLenKind = enum {
    omitted,
    assumed,
    explicit,
};

const DeclaredCharacterLengthInfo = struct {
    expr: ?*ast.Expr = null,
    deferred: bool = false,
    assumed: bool = false,
};

pub fn checkAllocateTypeSpecCompatibility(
    self: *context.Context,
    allocate: ast.AllocateStmt,
    type_spec: ast.AllocateTypeSpec,
    comptime deps: anytype,
) CheckError!void {
    if (type_spec.invalid_bare_double) {
        return emitAllocateTypeSpecDiagnostic(self, type_spec.source, "Error in type-spec at ALLOCATE", error.InvalidAllocateTypeSpec);
    }
    if (type_spec.legacy_star_kind) {
        return emitAllocateTypeSpecDiagnostic(self, type_spec.source, "Invalid type-spec at ALLOCATE", error.InvalidAllocateTypeSpec);
    }
    if (type_spec.type_kind == .character) return checkAllocateCharacterTypeSpecCompatibility(self, allocate, type_spec, deps);
    if (type_spec.type_kind != .derived) return checkAllocateIntrinsicTypeSpecCompatibility(self, allocate, type_spec);

    const type_name = type_spec.derived_type_name orelse return error.InvalidAllocateTypeSpec;
    const spec_info = resolve_symbols.lookupDerivedType(self, type_name) orelse return error.InvalidAllocateTypeSpec;
    if (spec_info.abstract) return error.AbstractAllocateType;

    for (allocate.items) |item| {
        const target_info = try targets.resolveAllocateTargetInfo(self, item.target);
        if (!target_info.allocatable and !target_info.pointer) continue;
        const target_spec = try targets.allocateTargetTypeSpec(self, item.target);
        if (target_spec.lowered_kind != .derived) return error.AllocateTypeIncompatible;
        const declared_name = target_spec.derived_type_name orelse return error.AllocateTypeIncompatible;
        const compatible = if (target_spec.polymorphic)
            resolve_symbols.isSameOrExtension(self, type_name, declared_name)
        else
            std.ascii.eqlIgnoreCase(type_name, declared_name);
        if (!compatible) {
            self.setCurrentSource(if (item.source.line != 0) item.source else null);
            return error.AllocateTypeIncompatible;
        }
    }
}

pub fn checkAllocateRequiresTypeSpecOrSource(self: *context.Context, allocate: ast.AllocateStmt) CheckError!void {
    if (allocate.type_spec != null or allocateHasSourceOrMold(allocate.options)) return;
    for (allocate.items) |item| {
        const target_info = try targets.resolveAllocateTargetInfo(self, item.target);
        if (!target_info.allocatable and !target_info.pointer) continue;
        const target_spec = try targets.allocateTargetTypeSpec(self, item.target);
        if (target_spec.lowered_kind != .derived or !target_spec.polymorphic) continue;
        const type_name = target_spec.derived_type_name orelse continue;
        const derived_info = resolve_symbols.lookupDerivedType(self, type_name) orelse continue;
        if (!derived_info.abstract) continue;
        self.setDiagnostic(
            if (item.source.line == 0) 1 else item.source.line,
            if (item.source.column == 0) 1 else item.source.column,
            catalog.semantic.abstract_allocate_type.code,
            "requires a type-spec or source-expr",
            item.source.text,
        );
        return error.AbstractAllocateType;
    }
}

fn checkAllocateIntrinsicTypeSpecCompatibility(
    self: *context.Context,
    allocate: ast.AllocateStmt,
    type_spec: ast.AllocateTypeSpec,
) CheckError!void {
    const selector_value = if (type_spec.kind_selector) |selector| try constants.evalConst(self, selector) else null;
    const resolved_spec = type_kind_selector.resolveSpecWithConst(type_spec.type_kind, type_spec.kind_selector, selector_value)
        .withPolymorphic(type_spec.polymorphic);

    for (allocate.items) |item| {
        const target_info = try targets.resolveAllocateTargetInfo(self, item.target);
        if (!target_info.allocatable and !target_info.pointer) continue;
        const target_spec = try targets.allocateTargetTypeSpec(self, item.target);
        if (target_spec.lowered_kind == .character or target_spec.lowered_kind == .derived) {
            self.setCurrentSource(if (item.source.line != 0) item.source else type_spec.source);
            return error.AllocateTypeIncompatible;
        }
        if (target_spec.declared_kind == resolved_spec.declared_kind and
            target_spec.kind_value != null and resolved_spec.kind_value != null and
            target_spec.kind_value.? != resolved_spec.kind_value.?)
        {
            self.setDiagnostic(
                if (type_spec.source.line == 0) 1 else type_spec.source.line,
                if (type_spec.source.column == 0) 1 else type_spec.source.column,
                catalog.semantic.assignment_type_mismatch.code,
                "differs from the kind type parameter",
                type_spec.source.text,
            );
            return error.AssignmentTypeMismatch;
        }
        if (target_spec.lowered_kind != resolved_spec.lowered_kind) {
            self.setCurrentSource(if (item.source.line != 0) item.source else type_spec.source);
            return error.AllocateTypeIncompatible;
        }
    }
}

fn checkAllocateCharacterTypeSpecCompatibility(
    self: *context.Context,
    allocate: ast.AllocateStmt,
    type_spec: ast.AllocateTypeSpec,
    comptime deps: anytype,
) CheckError!void {
    if (type_spec.char_len_deferred) {
        return emitAllocateTypeSpecDiagnostic(self, type_spec.source, "cannot contain a deferred type parameter", error.InvalidAllocateTypeSpec);
    }

    const supplied_len_kind = try allocateCharacterLenKind(self, type_spec, deps);
    const supplied_const_len = if (supplied_len_kind == .explicit) try allocateCharacterConstLen(self, type_spec.char_len.?) else null;

    for (allocate.items) |item| {
        const target_info = try targets.resolveAllocateTargetInfo(self, item.target);
        if (!target_info.allocatable and !target_info.pointer) continue;

        const target_spec = try targets.allocateTargetTypeSpec(self, item.target);
        if (target_spec.lowered_kind != .character) {
            self.setCurrentSource(if (item.source.line != 0) item.source else type_spec.source);
            return error.AllocateTypeIncompatible;
        }

        if (supplied_len_kind == .assumed) {
            if (target_spec.char_len_kind != .assumed or targets.dummyIntentForExpr(self, item.target) != .out) {
                self.setDiagnostic(
                    if (type_spec.source.line == 0) 1 else type_spec.source.line,
                    if (type_spec.source.column == 0) 1 else type_spec.source.column,
                    catalog.semantic.allocate_type_incompatible.code,
                    "Incompatible allocate-object",
                    type_spec.source.text,
                );
                return error.AllocateTypeIncompatible;
            }
            continue;
        }

        if (target_spec.char_len_kind == .assumed) {
            self.setDiagnostic(
                if (type_spec.source.line == 0) 1 else type_spec.source.line,
                if (type_spec.source.column == 0) 1 else type_spec.source.column,
                catalog.semantic.invalid_char_len.code,
                "shall be an asterisk",
                type_spec.source.text,
            );
            return error.InvalidCharLen;
        }

        if (target_spec.char_len_kind == .constant) {
            const target_len = target_spec.char_len orelse 1;
            const matches_default_len = supplied_len_kind == .omitted and target_len == 1;
            if (!matches_default_len and (supplied_const_len == null or supplied_const_len.? != target_len)) {
                self.setDiagnostic(
                    if (type_spec.source.line == 0) 1 else type_spec.source.line,
                    if (type_spec.source.column == 0) 1 else type_spec.source.column,
                    catalog.semantic.invalid_char_len.code,
                    "with type-spec requires the same character-length parameter",
                    type_spec.source.text,
                );
                return error.InvalidCharLen;
            }
            continue;
        }

        if (declaredCharacterLengthInfoForAllocateTarget(self, item.target)) |declared_info| {
            if (declared_info.assumed) {
                self.setDiagnostic(
                    if (type_spec.source.line == 0) 1 else type_spec.source.line,
                    if (type_spec.source.column == 0) 1 else type_spec.source.column,
                    catalog.semantic.invalid_char_len.code,
                    "shall be an asterisk",
                    type_spec.source.text,
                );
                return error.InvalidCharLen;
            }
            if (!declared_info.deferred and declared_info.expr != null and !targets.sameObjectSelectorExpr(declared_info.expr.?, type_spec.char_len.?)) {
                if (target_info.allocatable or target_info.pointer) continue;
                self.setDiagnostic(
                    if (type_spec.source.line == 0) 1 else type_spec.source.line,
                    if (type_spec.source.column == 0) 1 else type_spec.source.column,
                    catalog.semantic.invalid_char_len.code,
                    "type-spec requires the same character-length parameter",
                    type_spec.source.text,
                );
                return error.InvalidCharLen;
            }
        }
    }
}

fn allocateCharacterLenKind(self: *context.Context, type_spec: ast.AllocateTypeSpec, comptime deps: anytype) CheckError!CharacterAllocateLenKind {
    const len_expr = type_spec.char_len orelse return .omitted;
    if (len_expr.* == .literal and len_expr.literal.kind == .assumed_size) return .assumed;
    const len_ty = try deps.checkExprType(self, len_expr, .{
        .dummyArgTypeCompatible = deps.dummyArgTypeCompatible,
    });
    if (len_ty != .integer or options.exprRank(self, len_expr, deps) != 0) {
        self.setDiagnostic(
            if (type_spec.source.line == 0) 1 else type_spec.source.line,
            if (type_spec.source.column == 0) 1 else type_spec.source.column,
            catalog.semantic.invalid_char_len.code,
            "Scalar INTEGER expression",
            type_spec.source.text,
        );
        return error.InvalidCharLen;
    }
    return .explicit;
}

fn allocateCharacterConstLen(self: *context.Context, len_expr: *ast.Expr) CheckError!?usize {
    if (try constants.evalConst(self, len_expr)) |value| {
        return switch (value) {
            .integer => |int_val| if (int_val > 0) @as(?usize, @intCast(int_val)) else null,
            else => null,
        };
    }
    return null;
}

fn emitAllocateTypeSpecDiagnostic(self: *context.Context, source: ast.SourceRef, message: []const u8, err: anyerror) CheckError {
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_allocate_type_spec.code,
        message,
        source.text,
    );
    return err;
}

fn allocateHasSourceOrMold(options_list: []const ast.AllocationOption) bool {
    for (options_list) |option| {
        switch (option.kind) {
            .source, .mold => return true,
            else => {},
        }
    }
    return false;
}

fn declaredCharacterLengthInfoForAllocateTarget(self: *context.Context, expr: *ast.Expr) ?DeclaredCharacterLengthInfo {
    return switch (expr.*) {
        .identifier => |name| declaredCharacterLengthInfoForName(self.unit.decls, name),
        .component => |comp| blk: {
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk null;
            if (base_spec.lowered_kind != .derived) break :blk null;
            const derived_name = base_spec.derived_type_name orelse break :blk null;
            if (declaredCharacterLengthInfoForDerivedComponent(self.unit.decls, derived_name, comp.name)) |info| break :blk info;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk null;
            break :blk .{
                .expr = null,
                .deferred = component.type_spec.char_len_kind == .deferred,
                .assumed = component.type_spec.char_len_kind == .assumed,
            };
        },
        else => null,
    };
}

fn declaredCharacterLengthInfoForName(decls: []const ast.Decl, name: []const u8) ?DeclaredCharacterLengthInfo {
    for (decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                if (type_decl.type_kind != .character) continue;
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
                    return .{
                        .expr = item.char_len,
                        .deferred = item.char_len_deferred,
                        .assumed = item.char_len != null and item.char_len.?.* == .literal and item.char_len.?.literal.kind == .assumed_size,
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn declaredCharacterLengthInfoForDerivedComponent(
    decls: []const ast.Decl,
    derived_name: []const u8,
    component_name: []const u8,
) ?DeclaredCharacterLengthInfo {
    for (decls) |decl| {
        if (decl != .derived_type_def) continue;
        if (!std.ascii.eqlIgnoreCase(decl.derived_type_def.name, derived_name)) continue;
        for (decl.derived_type_def.components) |type_decl| {
            if (type_decl.type_kind != .character) continue;
            for (type_decl.items) |item| {
                if (!std.ascii.eqlIgnoreCase(item.name, component_name)) continue;
                return .{
                    .expr = item.char_len,
                    .deferred = item.char_len_deferred,
                    .assumed = item.char_len != null and item.char_len.?.* == .literal and item.char_len.?.literal.kind == .assumed_size,
                };
            }
        }
    }
    return null;
}
