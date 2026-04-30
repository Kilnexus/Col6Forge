const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const context = @import("context.zig");
const constants = @import("resolve_const.zig");
const decl_diag = @import("resolve_decls_diag_helpers.zig");
const decl_scan = @import("decl_scan.zig");
const resolve_expr = @import("resolve_expr.zig");
const symbols_mod = @import("resolve_symbols.zig");
pub fn validateDeclaratorDimensionExprs(self: *context.Context, dims: []*ast.Expr) !void {
    for (dims) |dim_expr| {
        try validateRestrictedSpecExpr(self, dim_expr);
        try validateDimensionExprType(self, dim_expr);
        try validateNonAutomaticProgramUnitDimension(self, dim_expr);
    }
}

fn validateNonAutomaticProgramUnitDimension(self: *context.Context, expr: *ast.Expr) !void {
    if (self.unit.kind != .module and self.unit.kind != .program) return;
    if (dimensionAllowsDeferredShape(expr)) return;
    if (try dimensionHasConstantBounds(self, expr)) return;
    emitNonconstantBoundsDiagnostic(self, expr);
    return error.InvalidArgumentCount;
}

fn dimensionHasConstantBounds(self: *context.Context, expr: *ast.Expr) !bool {
    return switch (expr.*) {
        .dim_range => |range| {
            if (range.assumed_shape) return true;
            if (range.lower) |lower| {
                if (!try exprIsConstantBound(self, lower)) return false;
            }
            if (!dimensionAllowsAssumedSize(range.upper) and !try exprIsConstantBound(self, range.upper)) return false;
            if (range.stride) |stride| {
                if (!try exprIsConstantBound(self, stride)) return false;
            }
            return true;
        },
        .literal => |lit| lit.kind == .assumed_size or try exprIsConstantBound(self, expr),
        else => try exprIsConstantBound(self, expr),
    };
}

fn exprIsConstantBound(self: *context.Context, expr: *ast.Expr) !bool {
    _ = (try constants.evalConst(self, expr)) orelse {
        if (expr.* == .identifier and symbolIsParameter(self, expr.identifier)) return true;
        return false;
    };
    return true;
}

fn symbolIsParameter(self: *context.Context, name: []const u8) bool {
    if (symbols_mod.findSymbolIndex(self, name)) |idx| {
        return self.symbols.items[idx].kind == .parameter;
    }
    return false;
}

fn dimensionAllowsAssumedSize(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .literal => |lit| lit.kind == .assumed_size,
        else => false,
    };
}

fn emitNonconstantBoundsDiagnostic(self: *context.Context, expr: *ast.Expr) void {
    const source = self.sourceForExpr(expr) orelse blk: {
        if (self.current_decl_source) |decl_source| {
            break :blk ast.SourceRef{ .line = decl_source.line, .column = decl_source.column, .text = decl_source.text };
        }
        break :blk ast.SourceRef{};
    };
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "array with nonconstant bounds",
        source.text,
    );
}

fn dimensionAllowsDeferredShape(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .dim_range => |range| range.assumed_shape or dimensionAllowsAssumedSize(range.upper),
        .literal => |lit| lit.kind == .assumed_size,
        else => false,
    };
}

fn validateDimensionExprType(self: *context.Context, expr: *ast.Expr) !void {
    switch (expr.*) {
        .dim_range => |range| {
            if (range.lower) |lower| try validateDimensionExprType(self, lower);
            try validateDimensionExprType(self, range.upper);
            if (range.stride) |stride| try validateDimensionExprType(self, stride);
        },
        .literal => |lit| {
            if (lit.kind == .assumed_size) return;
            const spec = try resolve_expr.exprTypeSpec(self, expr);
            if (spec.lowered_kind == .integer) return;
            emitDimensionIntegerTypeDiagnostic(self, expr);
            return error.InvalidArgumentCount;
        },
        else => {
            const spec = try resolve_expr.exprTypeSpec(self, expr);
            if (spec.lowered_kind == .integer) return;
            emitDimensionIntegerTypeDiagnostic(self, expr);
            return error.InvalidArgumentCount;
        },
    }
}

fn emitDimensionIntegerTypeDiagnostic(self: *context.Context, expr: *ast.Expr) void {
    const source = self.sourceForExpr(expr) orelse blk: {
        if (self.current_decl_source) |decl_source| {
            break :blk ast.SourceRef{
                .line = decl_source.line,
                .column = decl_source.column,
                .text = decl_source.text,
            };
        }
        break :blk ast.SourceRef{};
    };
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "must be of INTEGER type",
        source.text,
    );
}

pub fn validateRestrictedSpecExpr(self: *context.Context, expr: *ast.Expr) !void {
    switch (expr.*) {
        .identifier => |name| {
            if (symbols_mod.findSymbolIndex(self, name)) |idx| {
                const sym = self.symbols.items[idx];
                if (sym.storage == .dummy and isOptionalDummy(self, name)) {
                    decl_diag.emitOptionalSpecExprDiagnostic(self, name);
                    return error.InvalidArgumentCount;
                }
                if (sym.kind == .parameter or sym.storage == .dummy or sym.storage == .common) return;
                decl_diag.emitRestrictedSpecExprDiagnostic(self, name);
                return error.InvalidArgumentCount;
            }
            if (!decl_scan.declaresNameLaterInCurrentUnit(self, name)) return;
            if (implicitTypingDisabled(self)) {
                if (currentDeclDeclaresFunctionResult(self)) {
                    decl_diag.emitCurrentFunctionNoImplicitDiagnostic(self);
                }
                decl_diag.emitUsedBeforeTypedDiagnostic(self);
            } else {
                decl_diag.emitRestrictedSpecExprDiagnostic(self, name);
            }
            return error.InvalidArgumentCount;
        },
        .unary => |un| try validateRestrictedSpecExpr(self, un.expr),
        .binary => |bin| {
            try validateRestrictedSpecExpr(self, bin.left);
            try validateRestrictedSpecExpr(self, bin.right);
        },
        .call_or_subscript => |call| {
            for (call.args) |arg| {
                try validateRestrictedSpecExpr(self, arg);
            }
            try validateRestrictedSpecProcedureCall(self, call);
        },
        .component => |comp| {
            try validateRestrictedSpecExpr(self, comp.base);
            for (comp.args) |arg| {
                try validateRestrictedSpecExpr(self, arg);
            }
            try validateRestrictedSpecProcedureComponent(self, comp);
        },
        .substring => |sub| {
            for (sub.args) |arg| {
                try validateRestrictedSpecExpr(self, arg);
            }
            if (sub.start) |start| try validateRestrictedSpecExpr(self, start);
            if (sub.end) |end| try validateRestrictedSpecExpr(self, end);
        },
        .dim_range => |range| {
            if (range.lower) |lower| try validateRestrictedSpecExpr(self, lower);
            try validateRestrictedSpecExpr(self, range.upper);
            if (range.stride) |stride| try validateRestrictedSpecExpr(self, stride);
        },
        .array_constructor => |ctor| {
            for (ctor.items) |item| {
                try validateRestrictedSpecExpr(self, item);
            }
        },
        .complex_literal => |lit| {
            try validateRestrictedSpecExpr(self, lit.real);
            try validateRestrictedSpecExpr(self, lit.imag);
        },
        .implied_do => |ido| {
            for (ido.items) |item| {
                try validateRestrictedSpecExpr(self, item);
            }
            try validateRestrictedSpecExpr(self, ido.start);
            try validateRestrictedSpecExpr(self, ido.end);
            if (ido.step) |step| try validateRestrictedSpecExpr(self, step);
        },
        else => {},
    }
}

fn implicitTypingDisabled(self: *context.Context) bool {
    const limit = if (self.current_decl_index) |idx| idx else self.unit.decls.len;
    var decl_idx: usize = 0;
    while (decl_idx < limit and decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        const decl = self.unit.decls[decl_idx];
        if (decl != .implicit) continue;
        return decl.implicit.rules.len == 0;
    }
    return false;
}

fn currentDeclDeclaresFunctionResult(self: *context.Context) bool {
    if (self.unit.kind != .function) return false;
    const decl_idx = self.current_decl_index orelse return false;
    if (decl_idx >= self.unit.decls.len) return false;
    const result_name = self.unit.result_name orelse self.unit.name;
    const decl = self.unit.decls[decl_idx];
    switch (decl) {
        .type_decl => |type_decl| {
            for (type_decl.items) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, result_name)) return true;
            }
        },
        .procedure => |procedure_decl| {
            for (procedure_decl.items) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, result_name)) return true;
            }
        },
        .dimension => |dimension_decl| {
            for (dimension_decl.items) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, result_name)) return true;
            }
        },
        else => {},
    }
    return false;
}

fn validateRestrictedSpecProcedureCall(self: *context.Context, call: ast.CallOrSubscript) !void {
    if (symbols_mod.isIntrinsicName(call.name)) {
        try validateIntrinsicSpecCall(self, call);
        return;
    }

    if (symbols_mod.lookupKnownProcedureSig(self, call.name)) |sig| {
        if (sig.pure) return;
        decl_diag.emitPureSpecExprDiagnostic(self);
        return error.InvalidArgumentCount;
    }

    if (symbols_mod.findSymbolIndex(self, call.name)) |idx| {
        const sym = self.symbols.items[idx];
        if (sym.storage == .dummy and isOptionalDummy(self, call.name)) {
            decl_diag.emitOptionalSpecExprDiagnostic(self, call.name);
            return error.InvalidArgumentCount;
        }
        if (sym.dims.len != 0) return;
        decl_diag.emitPureSpecExprDiagnostic(self);
        return error.InvalidArgumentCount;
    }
}

fn validateIntrinsicSpecCall(self: *context.Context, call: ast.CallOrSubscript) !void {
    const needs_dim_check =
        std.ascii.eqlIgnoreCase(call.name, "size") or
        std.ascii.eqlIgnoreCase(call.name, "lbound") or
        std.ascii.eqlIgnoreCase(call.name, "ubound");
    if (!needs_dim_check or call.args.len < 2) return;
    const dim_value = (try constants.evalConst(self, call.args[1])) orelse return;
    const dim_int = switch (dim_value) {
        .integer => |value| value,
        else => return,
    };
    const array_rank = resolve_expr.exprRank(self, call.args[0]);
    if (dim_int >= 1 and dim_int <= array_rank) return;

    const source = self.sourceForExpr(call.args[1]) orelse blk: {
        if (self.current_decl_source) |decl_source| {
            break :blk ast.SourceRef{
                .line = decl_source.line,
                .column = decl_source.column,
                .text = decl_source.text,
            };
        }
        break :blk ast.SourceRef{};
    };
    self.setDiagnostic(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.assignment_type_mismatch.code,
        "is not a valid dimension index",
        source.text,
    );
    return error.InvalidArgumentCount;
}

fn validateRestrictedSpecProcedureComponent(self: *context.Context, comp: ast.ComponentExpr) !void {
    if (!comp.has_parens) return;
    const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch return;
    if (base_spec.lowered_kind != .derived) return;
    const derived_name = base_spec.derived_type_name orelse return;

    if (symbols_mod.lookupDerivedComponent(self, derived_name, comp.name)) |component| {
        if (!component.procedure) return;
        const sig = component.procedure_sig orelse
            (if (component.interface_name) |iface_name| symbols_mod.lookupKnownProcedureSig(self, iface_name) else null);
        if (sig) |proc_sig| {
            if (proc_sig.pure) return;
            decl_diag.emitPureSpecExprDiagnostic(self);
            return error.InvalidArgumentCount;
        }
        decl_diag.emitPureSpecExprDiagnostic(self);
        return error.InvalidArgumentCount;
    }

    const binding = symbols_mod.lookupDerivedBinding(self, derived_name, comp.name) orelse return;
    const impl_name = binding.implementation_name orelse binding.name;
    const sig = symbols_mod.lookupKnownProcedureSig(self, impl_name) orelse
        (if (binding.interface_name) |iface_name| symbols_mod.lookupKnownProcedureSig(self, iface_name) else null) orelse
        symbols_mod.lookupKnownProcedureSig(self, binding.name) orelse return;
    if (sig.pure) return;
    decl_diag.emitPureSpecExprDiagnostic(self);
    return error.InvalidArgumentCount;
}

fn isOptionalDummy(self: *context.Context, name: []const u8) bool {
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
