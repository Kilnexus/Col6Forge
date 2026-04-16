const std = @import("std");
const ast = @import("../../../../input.zig");
const ir = @import("../../../../ir.zig");
const llvm_types = @import("../../../types.zig");
const common = @import("../../common.zig");
const context = @import("../../context/mod.zig");
const utils = @import("../../utils.zig");
const procedure_pass = @import("../../../../../common/procedure_pass.zig");

const binary = @import("../binary.zig");
const call = @import("../call/mod.zig");
const casting = @import("../casting.zig");
const complex = @import("../complex.zig");
const intrinsics = @import("../intrinsics/mod.zig");
const memory = @import("../memory.zig");

const character = @import("character.zig");
const defined_operators = @import("defined_operators.zig");
const int_eval = @import("int_eval.zig");
const resolution = @import("resolution.zig");
const shared = @import("shared.zig");

const Expr = shared.Expr;
const Context = shared.Context;
const ValueRef = shared.ValueRef;
const EmitError = shared.EmitError;

pub fn emitLValue(ctx: *Context, builder: anytype, expr: *Expr) !ValueRef {
    const prev_source = ctx.current_source;
    ctx.setCurrentSource(ctx.sourceForExpr(expr));
    defer ctx.setCurrentSource(prev_source);
    switch (expr.*) {
        .identifier => |name| {
            return ctx.getPointer(name);
        },
        .array_constructor => return error.InvalidAssignmentTarget,
        .call_or_subscript => |call_or_sub| {
            var kind = ctx.ref_kinds.get(@as(usize, @intFromPtr(expr))) orelse .unknown;
            if (kind == .unknown) {
                if (ctx.findSymbol(call_or_sub.name)) |sym| {
                    if (sym.dims.len > 0) {
                        kind = .subscript;
                    } else if (sym.is_external or sym.is_intrinsic or sym.kind == .function) {
                        kind = .call;
                    }
                }
            }
            if (kind == .subscript) {
                return memory.emitSubscriptPtr(ctx, builder, call_or_sub);
            }
            return error.InvalidAssignmentTarget;
        },
        .substring => |_| {
            const plan = (try character.emitCharacterValuePlan(ctx, builder, expr)) orelse return error.UnsupportedSubstring;
            return plan.ptr;
        },
        .component => |comp| {
            return memory.emitComponentPtr(ctx, builder, comp);
        },
        .implied_do => return error.InvalidAssignmentTarget,
        else => return error.InvalidAssignmentTarget,
    }
}

pub fn emitExpr(ctx: *Context, builder: anytype, expr: *Expr) EmitError!ValueRef {
    return emitExprImpl(ctx, builder, expr, ctx.stmt_func_stack.items.len);
}

fn canFallbackToIntrinsicCall(sym: ast.sema.Symbol) bool {
    return sym.dims.len == 0 and
        !sym.is_external and
        !sym.is_intrinsic and
        sym.kind == .variable;
}

fn emitExprImpl(ctx: *Context, builder: anytype, expr: *Expr, subst_depth: usize) EmitError!ValueRef {
    const prev_source = ctx.current_source;
    ctx.setCurrentSource(ctx.sourceForExpr(expr));
    defer ctx.setCurrentSource(prev_source);
    switch (expr.*) {
        .identifier => |name| {
            if (subst_depth > 0) {
                var depth = subst_depth;
                while (depth > 0) {
                    depth -= 1;
                    const subst = ctx.stmt_func_stack.items[depth];
                    if (shared.findParamIndex(subst.params, name)) |idx| {
                        return emitExprImpl(ctx, builder, subst.actuals[idx], depth);
                    }
                }
            }
            const sym = ctx.findSymbol(name) orelse {
                if (common.isIsoCNullPointerName(name) or common.isIsoCNullFunPointerName(name)) {
                    return .{ .name = "null", .ty = .ptr, .is_ptr = false };
                }
                return error.UnknownSymbol;
            };
            if (sym.kind == .parameter) {
                if (sym.const_value) |cv| return casting.emitConstTyped(ctx, builder, cv, sym.loweredKind());
            }
            if (!ctx.locals.contains(name) and common.isIsoCNullPointerNamedConstant(sym, name)) {
                return .{ .name = "null", .ty = .ptr, .is_ptr = false };
            }
            if (sym.is_pointer) {
                const ptr = try ctx.getPointer(name);
                const tmp = try ctx.nextTemp();
                try builder.load(tmp, .ptr, ptr);
                return .{ .name = tmp, .ty = .ptr, .is_ptr = false };
            }
            if (sym.isCharacter()) {
                const ptr = try ctx.getPointer(name);
                return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
            }
            const ptr = try ctx.getPointer(name);
            if (sym.loweredKind() == .derived) {
                if (sym.storage == .dummy) {
                    return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
                }
                const tmp = try ctx.nextTemp();
                try builder.load(tmp, .ptr, ptr);
                return .{ .name = tmp, .ty = .ptr, .is_ptr = false };
            }
            const ty = ctx.typeFromKind(sym.loweredKind());
            const load_ty = common.symbolStorageIRType(sym, ctx.options.target_layout);
            const tmp = try ctx.nextTemp();
            try builder.load(tmp, load_ty, ptr);
            var value = ValueRef{ .name = tmp, .ty = load_ty, .is_ptr = false };
            if (sym.loweredKind() == .logical) {
                value = try casting.coerce(ctx, builder, value, ty);
            }
            return value;
        },
        .array_constructor => return error.UnsupportedArrayConstructor,
        .literal => |lit| {
            return casting.emitLiteral(ctx, builder, lit);
        },
        .component => |comp| {
            if (emitPseudoComponentExpr(ctx, builder, comp, subst_depth)) |value| {
                return value;
            } else |err| switch (err) {
                error.NotPseudoComponent => {},
                else => return err,
            }
            const base_type_name = ctx.derivedTypeNameForExpr(comp.base) orelse return error.UnknownSymbol;
            if (ctx.lookupDerivedComponentLayout(base_type_name, comp.name)) |component| {
                if (component.procedure) {
                    if (comp.has_parens) return emitProcedureComponentCall(ctx, builder, comp, component);
                    if (comp.args.len != 0) return error.InvalidSubscript;
                    const ptr = try memory.emitComponentStoragePtr(ctx, builder, comp);
                    const tmp = try ctx.nextTemp();
                    try builder.load(tmp, .ptr, ptr);
                    return .{ .name = tmp, .ty = .ptr, .is_ptr = false };
                }
                const ptr = try memory.emitComponentPtr(ctx, builder, comp);
                const ty = try ctx.componentIRType(comp);
                if (component.pointer) {
                    if (component.dims.len == 0 and component.type_spec.lowered_kind != .character and component.type_spec.lowered_kind != .derived) {
                        const data_ptr = try memory.emitLoadedComponentDataPtr(ctx, builder, comp);
                        const pointee_ty = ctx.typeFromKind(component.type_spec.lowered_kind);
                        const load_ty = if (component.type_spec.lowered_kind == .logical)
                            llvm_types.defaultIntegerType(ctx.options.target_layout)
                        else
                            llvm_types.typeFromKindWithLayout(component.type_spec.lowered_kind, ctx.options.target_layout);
                        const tmp = try ctx.nextTemp();
                        try builder.load(tmp, load_ty, data_ptr);
                        var value = ValueRef{ .name = tmp, .ty = load_ty, .is_ptr = false };
                        if (component.type_spec.lowered_kind == .logical) {
                            value = try casting.coerce(ctx, builder, value, pointee_ty);
                        }
                        return value;
                    }
                    const tmp = try ctx.nextTemp();
                    try builder.load(tmp, .ptr, ptr);
                    return .{ .name = tmp, .ty = .ptr, .is_ptr = false };
                }
                if (ty == .ptr) return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
                const tmp = try ctx.nextTemp();
                try builder.load(tmp, ty, ptr);
                return .{ .name = tmp, .ty = ty, .is_ptr = false };
            }
            if (comp.has_parens) {
                return emitTypeBoundProcedureCall(ctx, builder, comp);
            }
            return error.UnknownSymbol;
        },
        .complex_literal => |lit| {
            var real_val = try emitExprImpl(ctx, builder, lit.real, subst_depth);
            var imag_val = try emitExprImpl(ctx, builder, lit.imag, subst_depth);
            const elem_ty: ir.IRType = if (real_val.ty == .f64 or imag_val.ty == .f64) .f64 else .f32;
            if (real_val.ty != elem_ty) real_val = try casting.coerce(ctx, builder, real_val, elem_ty);
            if (imag_val.ty != elem_ty) imag_val = try casting.coerce(ctx, builder, imag_val, elem_ty);
            const complex_ty: ir.IRType = if (elem_ty == .f64) .complex_f64 else .complex_f32;
            return complex.buildComplex(ctx, builder, real_val, imag_val, complex_ty);
        },
        .unary => |un| {
            if (un.op == .not) {
                if (try defined_operators.emitDefinedUnaryOperatorExprCall(ctx, builder, expr, un)) |value| {
                    return value;
                }
            }
            const inner = try emitExprImpl(ctx, builder, un.expr, subst_depth);
            switch (un.op) {
                .plus => return inner,
                .minus => {
                    if (complex.isComplexType(inner.ty)) {
                        return complex.emitComplexNegate(ctx, builder, inner);
                    }
                    const zero = utils.zeroValue(inner.ty);
                    return binary.emitBinary(ctx, builder, .sub, zero, inner);
                },
                .not => {
                    if (inner.ty != .i1) return error.UnsupportedLogicalOp;
                    const tmp = try ctx.nextTemp();
                    try builder.xorI1(tmp, inner);
                    return .{ .name = tmp, .ty = .i1, .is_ptr = false };
                },
            }
        },
        .binary => |bin| {
            if (try defined_operators.emitDefinedBinaryOperatorExprCall(ctx, builder, bin)) |value| {
                return value;
            }
            if (bin.op == .eq or bin.op == .ne or bin.op == .lt or bin.op == .le or bin.op == .gt or bin.op == .ge) {
                if (try character.emitCharacterValuePlanImpl(ctx, builder, bin.left, subst_depth)) |lhs_char| {
                    if (try character.emitCharacterValuePlanImpl(ctx, builder, bin.right, subst_depth)) |rhs_char| {
                        return character.emitCharCompare(ctx, builder, bin.op, lhs_char, rhs_char);
                    }
                }
            }
            if (bin.op == .concat) {
                const plan = (try character.emitCharacterValuePlanImpl(ctx, builder, expr, subst_depth)) orelse return error.UnsupportedConcat;
                return .{ .name = plan.ptr.name, .ty = .ptr, .is_ptr = false };
            }
            const lhs = try emitExprImpl(ctx, builder, bin.left, subst_depth);
            const rhs = try emitExprImpl(ctx, builder, bin.right, subst_depth);
            return binary.emitBinary(ctx, builder, bin.op, lhs, rhs);
        },
        .call_or_subscript => |call_or_sub| {
            const sym = ctx.findSymbol(call_or_sub.name) orelse {
                if (ctx.lookupKnownProcedureSig(call_or_sub.name) == null and ctx.findDerivedTypeLayout(call_or_sub.name) != null) {
                    return emitStructureConstructorByTypeName(ctx, builder, call_or_sub, call_or_sub.name);
                }
                return intrinsics.emitIntrinsicCall(ctx, builder, call_or_sub.name, call_or_sub.args) catch |err| switch (err) {
                    error.UnknownIntrinsic => error.UnknownSymbol,
                    else => err,
                };
            };
            if (sym.kind == .parameter) {
                if (sym.const_value) |cv| {
                    return casting.emitConstTyped(ctx, builder, cv, sym.loweredKind());
                }
            }
            var kind = ctx.ref_kinds.get(@as(usize, @intFromPtr(expr))) orelse .unknown;
            if (kind == .unknown) {
                if (sym.dims.len > 0) {
                    kind = .subscript;
                } else if (sym.is_external or sym.is_intrinsic or sym.kind == .function) {
                    kind = .call;
                }
            }
            if (kind == .subscript) {
                const ptr = try memory.emitSubscriptPtr(ctx, builder, call_or_sub);
                if (sym.isCharacter()) {
                    return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
                }
                const ty = ctx.typeFromKind(sym.loweredKind());
                const load_ty = common.symbolElementIRType(sym, ctx.options.target_layout);
                const tmp = try ctx.nextTemp();
                try builder.load(tmp, load_ty, ptr);
                var value = ValueRef{ .name = tmp, .ty = load_ty, .is_ptr = false };
                if (sym.loweredKind() == .logical) {
                    value = try casting.coerce(ctx, builder, value, ty);
                }
                return value;
            }
            if (kind == .unknown and canFallbackToIntrinsicCall(sym)) {
                if (intrinsics.emitIntrinsicCall(ctx, builder, call_or_sub.name, call_or_sub.args)) |value| {
                    return value;
                } else |err| switch (err) {
                    error.UnknownIntrinsic => {},
                    else => return err,
                }
            }
            if (kind != .call) return error.AmbiguousCallOrSubscript;
            const known_proc_sig = ctx.lookupKnownProcedureSig(call_or_sub.name);
            if (known_proc_sig) |proc_sig| {
                if (proc_sig.result_rank != 0) return error.UnsupportedArrayActual;
            }
            if (isStructureConstructorCall(ctx, sym, call_or_sub)) {
                return emitStructureConstructor(ctx, builder, call_or_sub, sym);
            }
            if (ctx.getStatementFunction(call_or_sub.name)) |def| {
                return emitStatementFunctionCall(ctx, builder, call_or_sub.name, def, call_or_sub.args);
            }
            if (!sym.is_intrinsic) {
                if (resolution.resolveSingleTargetGenericProcedure(ctx, call_or_sub.name)) |resolved_generic| {
                    const result_spec = resolved_generic.sig.result_type_spec;
                    const ret_ty: ir.IRType = if (resolved_generic.sig.is_pointer)
                        .ptr
                    else if (result_spec) |spec|
                        (if (spec.lowered_kind == .derived or spec.lowered_kind == .character) .ptr else ctx.typeFromKind(spec.lowered_kind))
                    else
                        ctx.typeFromKind(sym.loweredKind());
                    if (result_spec != null and result_spec.?.lowered_kind == .character) {
                        const result_len = result_spec.?.char_len orelse 1;
                        const fn_name = try resolution.ensureExternalDeclForResolvedCall(ctx, resolved_generic.lookup_name, resolved_generic.ir_name, .void, call_or_sub.args, true);
                        const ptr = try call.emitCharacterCall(ctx, builder, fn_name, result_len, call_or_sub.args);
                        return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
                    }
                    const fn_name = try resolution.ensureExternalDeclForResolvedCall(ctx, resolved_generic.lookup_name, resolved_generic.ir_name, ret_ty, call_or_sub.args, false);
                    return call.emitCall(ctx, builder, fn_name, ret_ty, call_or_sub.args, false);
                }
            }
            if (sym.is_intrinsic) {
                return intrinsics.emitIntrinsicCall(ctx, builder, call_or_sub.name, call_or_sub.args);
            }
            const ret_ty: ir.IRType = if (known_proc_sig) |proc_sig|
                switch (proc_sig.kind) {
                    .function => blk: {
                        if (proc_sig.is_pointer or proc_sig.result_rank != 0 or proc_sig.result_allocatable) break :blk .ptr;
                        if (proc_sig.result_type_spec) |spec| {
                            break :blk if (spec.lowered_kind == .derived or spec.lowered_kind == .character) .ptr else ctx.typeFromKind(spec.lowered_kind);
                        }
                        break :blk ctx.typeFromKind(sym.loweredKind());
                    },
                    else => .void,
                }
            else if (sym.kind == .function and sym.is_pointer)
                .ptr
            else
                ctx.typeFromKind(sym.loweredKind());
            const is_character_function = if (known_proc_sig) |proc_sig|
                proc_sig.kind == .function and proc_sig.result_type_spec != null and proc_sig.result_type_spec.?.lowered_kind == .character
            else
                sym.kind == .function and sym.isCharacter();
            if (is_character_function) {
                const plan = (try character.emitCharacterValuePlanImpl(ctx, builder, expr, subst_depth)) orelse return error.NonConstantCharacterLength;
                return .{ .name = plan.ptr.name, .ty = .ptr, .is_ptr = false };
            }
            if (try call.callableProcedurePointer(ctx, builder, call_or_sub.name, sym)) |fn_ptr| {
                return call.emitIndirectCall(ctx, builder, fn_ptr, ret_ty, call_or_sub.args, false);
            }
            const fn_name = try resolution.ensureExternalDeclForCall(ctx, call_or_sub.name, ret_ty, call_or_sub.args, false);
            return call.emitCall(ctx, builder, fn_name, ret_ty, call_or_sub.args, false);
        },
        .substring => |_| {
            const plan = (try character.emitCharacterValuePlanImpl(ctx, builder, expr, subst_depth)) orelse return error.UnsupportedSubstring;
            return .{ .name = plan.ptr.name, .ty = .ptr, .is_ptr = false };
        },
        .dim_range => return error.InvalidExpression,
        .implied_do => return error.UnsupportedImpliedDo,
    }
}

fn emitPseudoComponentExpr(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    subst_depth: usize,
) EmitError!ValueRef {
    if (comp.has_parens or comp.args.len != 0) return error.NotPseudoComponent;

    if (std.ascii.eqlIgnoreCase(comp.name, "re") or std.ascii.eqlIgnoreCase(comp.name, "im")) {
        const base_val = try emitExprImpl(ctx, builder, comp.base, subst_depth);
        if (!complex.isComplexType(base_val.ty)) return error.InvalidSubscript;
        const index: usize = if (std.ascii.eqlIgnoreCase(comp.name, "im")) 1 else 0;
        return complex.extractComplex(ctx, builder, base_val, index);
    }

    if (std.ascii.eqlIgnoreCase(comp.name, "len")) {
        var len_val = (try character.emitCharacterLenValue(ctx, builder, comp.base)) orelse return error.NonConstantCharacterLength;
        const target_ty = ctx.defaultIntegerIRType();
        if (len_val.ty != target_ty) {
            len_val = try casting.coerce(ctx, builder, len_val, target_ty);
        }
        return len_val;
    }

    if (std.ascii.eqlIgnoreCase(comp.name, "kind")) {
        const kind_value = try pseudoComponentKindValue(ctx, builder, comp.base, subst_depth);
        return ctx.constDefaultInteger(kind_value);
    }

    return error.NotPseudoComponent;
}

fn pseudoComponentKindValue(
    ctx: *Context,
    builder: anytype,
    base_expr: *Expr,
    subst_depth: usize,
) EmitError!i64 {
    if (character.isCharacterExpr(ctx, base_expr)) return 1;
    const base_val = try emitExprImpl(ctx, builder, base_expr, subst_depth);
    return switch (base_val.ty) {
        .i1, .i32 => 4,
        .i64 => 8,
        .f32 => 4,
        .f64 => 8,
        .complex_f32 => 8,
        .complex_f64 => 16,
        else => error.InvalidSubscript,
    };
}

fn emitTypeBoundProcedureCall(ctx: *Context, builder: anytype, comp: ast.ComponentExpr) !ValueRef {
    const base_type_name = ctx.derivedTypeNameForExpr(comp.base) orelse return error.UnknownSymbol;
    const binding = ctx.lookupDerivedBinding(base_type_name, comp.name) orelse return error.UnknownSymbol;
    const proc_name = binding.implementation_name orelse binding.interface_name orelse binding.name;
    const lookup_name = try resolution.boundProcedureLookupName(ctx, binding, proc_name);
    const ir_name = try resolution.boundProcedureIRName(ctx, binding, proc_name);
    const proc_sig = ctx.lookupKnownProcedureSig(lookup_name) orelse ctx.lookupKnownProcedureSig(proc_name) orelse return error.UnknownSymbol;

    const actuals = try resolution.buildTypeBoundProcedureActuals(ctx, comp, binding);
    defer ctx.allocator.free(actuals);

    if (proc_sig.kind != .function) return error.InvalidExpression;

    const result_spec = resolution.boundProcedureResultSpec(ctx, binding, proc_sig);
    const ret_ty: ir.IRType = if (proc_sig.is_pointer)
        .ptr
    else if (result_spec) |spec|
        (if (spec.lowered_kind == .derived or spec.lowered_kind == .character) .ptr else ctx.typeFromKind(spec.lowered_kind))
    else
        return error.UnknownSymbol;

    if (result_spec != null and result_spec.?.lowered_kind == .character) {
        const result_len = result_spec.?.char_len orelse 1;
        const fn_name = try resolution.ensureExternalDeclForResolvedCall(ctx, lookup_name, ir_name, .void, actuals, true);
        const ptr = try call.emitCharacterCall(ctx, builder, fn_name, result_len, actuals);
        return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
    }

    const fn_name = try resolution.ensureExternalDeclForResolvedCall(ctx, lookup_name, ir_name, ret_ty, actuals, false);
    return call.emitCall(ctx, builder, fn_name, ret_ty, actuals, false);
}

fn emitProcedureComponentCall(
    ctx: *Context,
    builder: anytype,
    comp: ast.ComponentExpr,
    component: context.DerivedComponentLayout,
) !ValueRef {
    const proc_sig = component.procedure_sig orelse return error.UnknownSymbol;
    if (proc_sig.kind != .function) return error.InvalidExpression;

    const actuals = try buildProcedureComponentActuals(ctx, comp, component, proc_sig);
    defer ctx.allocator.free(actuals);

    const slot_ptr = try memory.emitComponentStoragePtr(ctx, builder, .{
        .base = comp.base,
        .name = comp.name,
        .args = &.{},
        .has_parens = false,
    });
    const fn_ptr_name = try ctx.nextTemp();
    try builder.load(fn_ptr_name, .ptr, slot_ptr);
    const fn_ptr = ValueRef{ .name = fn_ptr_name, .ty = .ptr, .is_ptr = false };

    const result_spec = component.procedure_sig.?.result_type_spec orelse component.type_spec;
    if (result_spec.lowered_kind == .character) {
        const result_len = result_spec.char_len orelse return error.NonConstantCharacterLength;
        const ptr = try call.emitIndirectCharacterCall(ctx, builder, fn_ptr, result_len, actuals);
        return .{ .name = ptr.name, .ty = .ptr, .is_ptr = false };
    }

    const ret_ty: ir.IRType = if (proc_sig.is_pointer or proc_sig.result_rank != 0 or proc_sig.result_allocatable)
        .ptr
    else if (result_spec.lowered_kind == .derived)
        .ptr
    else
        ctx.typeFromKind(result_spec.lowered_kind);
    return call.emitIndirectCall(ctx, builder, fn_ptr, ret_ty, actuals, false);
}

fn buildProcedureComponentActuals(
    ctx: *Context,
    comp: ast.ComponentExpr,
    component: context.DerivedComponentLayout,
    proc_sig: ast.sema.KnownProcedureSig,
) ![]*Expr {
    const extra: usize = if (component.procedure_nopass) 0 else 1;
    const actuals = try ctx.allocator.alloc(*Expr, comp.args.len + extra);
    const pass_idx = if (component.procedure_nopass) null else procedure_pass.procedurePassArgIndex(proc_sig.args, component.procedure_pass_name);
    var actual_idx: usize = 0;
    var comp_idx: usize = 0;
    while (actual_idx < actuals.len) : (actual_idx += 1) {
        if (pass_idx != null and actual_idx == pass_idx.?) {
            actuals[actual_idx] = comp.base;
            continue;
        }
        actuals[actual_idx] = comp.args[comp_idx];
        comp_idx += 1;
    }
    return actuals;
}

fn isStructureConstructorCall(ctx: *Context, sym: ast.sema.Symbol, ctor_call: ast.CallOrSubscript) bool {
    if (sym.is_intrinsic or sym.is_external) return false;
    if (sym.loweredKind() != .derived) return false;
    const type_name = sym.type_spec.derived_type_name orelse return false;
    if (!std.ascii.eqlIgnoreCase(type_name, ctor_call.name)) return false;
    if (ctx.lookupKnownProcedureSig(ctor_call.name) != null) return false;
    return ctx.findDerivedTypeLayout(type_name) != null;
}

fn emitStructureConstructor(
    ctx: *Context,
    builder: anytype,
    call_or_sub: ast.CallOrSubscript,
    sym: ast.sema.Symbol,
) EmitError!ValueRef {
    const type_name = sym.type_spec.derived_type_name orelse return error.UnknownSymbol;
    return emitStructureConstructorByTypeName(ctx, builder, call_or_sub, type_name);
}

fn emitStructureConstructorByTypeName(
    ctx: *Context,
    builder: anytype,
    call_or_sub: ast.CallOrSubscript,
    type_name: []const u8,
) EmitError!ValueRef {
    const layout = ctx.findDerivedTypeLayout(type_name) orelse return error.UnknownSymbol;
    const object_name = try ctx.nextTemp();
    if (layout.size <= 1) {
        try builder.alloca(object_name, .i8);
    } else {
        try builder.allocaArray(object_name, .i8, layout.size);
    }
    const object_ptr = ValueRef{ .name = object_name, .ty = .ptr, .is_ptr = true };
    if (call_or_sub.args.len != layout.components.len) return error.InvalidArgumentCount;

    var arg_idx: usize = 0;
    for (layout.components) |component| {
        var component_ptr = object_ptr;
        if (component.offset != 0) {
            const gep_name = try ctx.nextTemp();
            try builder.gep(gep_name, .i8, object_ptr, try ctx.constI64(@intCast(component.offset)));
            component_ptr = .{ .name = gep_name, .ty = .ptr, .is_ptr = true };
        }
        try emitStructureConstructorComponentStore(ctx, builder, component_ptr, component, call_or_sub.args[arg_idx]);
        arg_idx += 1;
    }
    return .{ .name = object_ptr.name, .ty = .ptr, .is_ptr = false };
}

fn emitStructureConstructorComponentStore(
    ctx: *Context,
    builder: anytype,
    component_ptr: ValueRef,
    component: context.DerivedComponentLayout,
    value_expr: *Expr,
) EmitError!void {
    if (component.procedure) {
        const proc_ptr = try call.emitArgPointer(ctx, builder, value_expr);
        try builder.store(proc_ptr, component_ptr);
        return;
    }

    if (component.dims.len != 0 and !component.pointer and !component.allocatable) {
        const items = try flattenStructureConstructorArrayItems(ctx, value_expr) orelse return error.UnsupportedArrayConstructor;
        const expected_count = common.arrayElementCount(ctx.sem, component.dims) catch return error.UnsupportedArrayConstructor;
        if (items.len != expected_count) return error.InvalidArgumentCount;

        const scalar_component = context.DerivedComponentLayout{
            .name = component.name,
            .type_spec = component.type_spec,
            .dims = &.{},
            .pointer = false,
            .allocatable = false,
            .offset = 0,
            .elem_size = component.elem_size,
            .size = component.elem_size,
            .alignment = component.alignment,
        };

        for (items, 0..) |item, idx| {
            var elem_ptr = component_ptr;
            if (idx != 0) {
                const gep_name = try ctx.nextTemp();
                try builder.gep(gep_name, .i8, component_ptr, try ctx.constI64(@intCast(idx * component.elem_size)));
                elem_ptr = .{ .name = gep_name, .ty = .ptr, .is_ptr = true };
            }
            try emitStructureConstructorComponentStore(ctx, builder, elem_ptr, scalar_component, item);
        }
        return;
    }

    if (component.allocatable and component.dims.len != 0 and component.type_spec.lowered_kind != .character and component.type_spec.lowered_kind != .derived) {
        try emitStructureConstructorAllocatableArrayComponentStore(ctx, builder, component_ptr, component, value_expr);
        return;
    }

    if (component.type_spec.lowered_kind == .character) {
        if (component.allocatable and component.type_spec.char_len == null) {
            if (component.dims.len != 0) return error.UnsupportedCharacterArgumentLength;
            try emitStructureConstructorDeferredCharacterAllocatableStore(ctx, builder, component_ptr, value_expr);
            return;
        }
        const plan = (try character.emitCharacterValuePlan(ctx, builder, value_expr)) orelse return error.UnsupportedCharacterArgumentLength;
        const src_len = plan.logical_len_const orelse return error.UnsupportedCharacterArgumentLength;
        try character.copyCharacterBytesFromPlan(ctx, builder, component_ptr, plan, 0);
        var idx: usize = src_len;
        while (idx < component.elem_size) : (idx += 1) {
            const offset = try ctx.constI32(@intCast(idx));
            const gep_name = try ctx.nextTemp();
            try builder.gep(gep_name, .i8, component_ptr, offset);
            try builder.store(.{ .name = try ctx.intLiteral(' '), .ty = .i8, .is_ptr = false }, .{ .name = gep_name, .ty = .ptr, .is_ptr = true });
        }
        return;
    }

    const value = try emitExpr(ctx, builder, value_expr);
    if (component.type_spec.lowered_kind == .derived or component.pointer) {
        try builder.store(value, component_ptr);
        return;
    }
    const target_ty = llvm_types.typeFromKindWithLayout(component.type_spec.lowered_kind, ctx.options.target_layout);
    const coerced = if (value.ty == target_ty) value else try casting.coerce(ctx, builder, value, target_ty);
    try builder.store(coerced, component_ptr);
}

fn emitStructureConstructorAllocatableArrayComponentStore(
    ctx: *Context,
    builder: anytype,
    component_ptr: ValueRef,
    component: context.DerivedComponentLayout,
    value_expr: *Expr,
) EmitError!void {
    if (component.dims.len != 1) return error.UnsupportedArrayConstructor;

    if (value_expr.* == .call_or_subscript and std.ascii.eqlIgnoreCase(value_expr.call_or_subscript.name, "null")) {
        try builder.store(.{ .name = "null", .ty = .ptr, .is_ptr = true }, component_ptr);
        try storeStructureConstructorDescriptorSlot(ctx, builder, component_ptr, component, .lower, 0, constI64(ctx, 1));
        try storeStructureConstructorDescriptorSlot(ctx, builder, component_ptr, component, .extent, 0, constI64(ctx, 0));
        try storeStructureConstructorDescriptorSlot(ctx, builder, component_ptr, component, .multiplier, 0, constI64(ctx, 1));
        return;
    }

    const items = try flattenStructureConstructorArrayItems(ctx, value_expr) orelse return error.UnsupportedArrayConstructor;
    const elem_ty = llvm_types.typeFromKindWithLayout(component.type_spec.lowered_kind, ctx.options.target_layout);
    const count = constI64(ctx, @intCast(items.len));
    const alloc_count = if (items.len == 0) constI64(ctx, 1) else count;
    const total_bytes = try binary.emitMul(ctx, builder, alloc_count, constI64(ctx, @intCast(component.elem_size)));

    const malloc_name = try ctx.ensureDeclRaw("malloc", .ptr, &.{.i64}, false);
    const data_ptr_name = try ctx.nextTemp();
    try builder.callTyped(data_ptr_name, .ptr, malloc_name, &.{total_bytes});
    const data_ptr = ValueRef{ .name = data_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(data_ptr, component_ptr);

    try storeStructureConstructorDescriptorSlot(ctx, builder, component_ptr, component, .lower, 0, constI64(ctx, 1));
    try storeStructureConstructorDescriptorSlot(ctx, builder, component_ptr, component, .extent, 0, count);
    try storeStructureConstructorDescriptorSlot(ctx, builder, component_ptr, component, .multiplier, 0, constI64(ctx, 1));

    for (items, 0..) |item, idx| {
        const elem_ptr_name = try ctx.nextTemp();
        try builder.gep(elem_ptr_name, elem_ty, data_ptr, constI64(ctx, @intCast(idx)));
        const value = try emitExpr(ctx, builder, item);
        const coerced = if (value.ty == elem_ty) value else try casting.coerce(ctx, builder, value, elem_ty);
        try builder.store(coerced, .{ .name = elem_ptr_name, .ty = .ptr, .is_ptr = true });
    }
}

fn storeStructureConstructorDescriptorSlot(
    ctx: *Context,
    builder: anytype,
    component_ptr: ValueRef,
    component: context.DerivedComponentLayout,
    comptime kind: memory.DescriptorSlotKind,
    dim_index: usize,
    value: ValueRef,
) EmitError!void {
    const ptr_size = @sizeOf(usize);
    const char_len_slot_size: usize = if (component.type_spec.lowered_kind == .character and component.type_spec.char_len == null)
        @sizeOf(i64)
    else
        0;
    const dim_span = component.dims.len * @sizeOf(i64);
    const base_offset: usize = switch (kind) {
        .lower => ptr_size + char_len_slot_size + dim_index * @sizeOf(i64),
        .extent => ptr_size + char_len_slot_size + dim_span + dim_index * @sizeOf(i64),
        .multiplier => ptr_size + char_len_slot_size + dim_span * 2 + dim_index * @sizeOf(i64),
    };
    const slot_name = try ctx.nextTemp();
    try builder.gep(slot_name, .i8, component_ptr, constI64(ctx, @intCast(base_offset)));
    try builder.store(value, .{ .name = slot_name, .ty = .ptr, .is_ptr = true });
}

fn emitStructureConstructorDeferredCharacterAllocatableStore(
    ctx: *Context,
    builder: anytype,
    component_ptr: ValueRef,
    value_expr: *Expr,
) EmitError!void {
    const plan = (try character.emitCharacterValuePlan(ctx, builder, value_expr)) orelse return error.UnsupportedCharacterArgumentLength;
    var len_i64 = plan.logical_len;
    if (len_i64.ty != .i64) len_i64 = try casting.coerce(ctx, builder, len_i64, .i64);

    const is_zero_name = try ctx.nextTemp();
    try builder.compare(is_zero_name, "icmp", "eq", .i64, len_i64, .{ .name = "0", .ty = .i64, .is_ptr = false });
    const alloc_bytes_name = try ctx.nextTemp();
    try builder.select(
        alloc_bytes_name,
        .i64,
        .{ .name = is_zero_name, .ty = .i1, .is_ptr = false },
        .{ .name = "1", .ty = .i64, .is_ptr = false },
        len_i64,
    );
    const alloc_bytes = ValueRef{ .name = alloc_bytes_name, .ty = .i64, .is_ptr = false };

    const malloc_name = try ctx.ensureDeclRaw("malloc", .ptr, &[_]ir.IRType{.i64}, false);
    const data_ptr_name = try ctx.nextTemp();
    try builder.callTyped(data_ptr_name, .ptr, malloc_name, &.{alloc_bytes});
    const data_ptr = ValueRef{ .name = data_ptr_name, .ty = .ptr, .is_ptr = true };
    try builder.store(data_ptr, component_ptr);

    const memcpy_name = try ctx.ensureDeclRaw("llvm.memcpy.p0.p0.i64", .void, &[_]ir.IRType{ .ptr, .ptr, .i64, .i1 }, false);
    try builder.callTyped(null, .void, memcpy_name, &.{ data_ptr, plan.ptr, len_i64, .{ .name = "false", .ty = .i1, .is_ptr = false } });

    const len_slot_name = try ctx.nextTemp();
    try builder.gep(len_slot_name, .i8, component_ptr, try ctx.constI64(@intCast(@sizeOf(usize))));
    try builder.store(len_i64, .{ .name = len_slot_name, .ty = .ptr, .is_ptr = true });
}

fn constI64(ctx: *Context, value: i64) ValueRef {
    return .{ .name = ctx.intLiteral(value) catch unreachable, .ty = .i64, .is_ptr = false };
}

fn flattenStructureConstructorArrayItems(ctx: *Context, expr_node: *Expr) EmitError!?[]const *Expr {
    var items = std.array_list.Managed(*Expr).init(ctx.allocator);
    if (!(try appendFlattenedStructureConstructorArrayExpr(ctx, &items, expr_node))) return null;
    return try items.toOwnedSlice();
}

fn appendFlattenedStructureConstructorArrayExpr(
    ctx: *Context,
    out: *std.array_list.Managed(*Expr),
    expr_node: *Expr,
) EmitError!bool {
    switch (expr_node.*) {
        .array_constructor => |ctor| {
            for (ctor.items) |item| {
                if (try appendFlattenedStructureConstructorArrayExpr(ctx, out, item)) continue;
                try out.append(item);
            }
            return true;
        },
        .implied_do => |implied| {
            const items = try expandStaticStructureConstructorImpliedDo(ctx, implied) orelse return false;
            for (items) |item| {
                if (try appendFlattenedStructureConstructorArrayExpr(ctx, out, item)) continue;
                try out.append(item);
            }
            return true;
        },
        .call_or_subscript => |call_expr| {
            if (!std.ascii.eqlIgnoreCase(call_expr.name, "reshape") or call_expr.args.len != 2) return false;
            const source_items = try flattenStructureConstructorArrayItems(ctx, call_expr.args[0]) orelse return false;
            const expected_count = structureConstructorShapeProduct(call_expr.args[1]) orelse return false;
            if (source_items.len != expected_count) return false;
            for (source_items) |item| {
                try out.append(item);
            }
            return true;
        },
        else => return false,
    }
}

fn expandStaticStructureConstructorImpliedDo(ctx: *Context, implied: ast.ImpliedDo) EmitError!?[]const *Expr {
    const start_val = int_eval.intLiteralValue(implied.start) orelse return null;
    const end_val = int_eval.intLiteralValue(implied.end) orelse return null;
    const step_val = if (implied.step) |step_expr|
        int_eval.intLiteralValue(step_expr) orelse return null
    else
        1;
    if (step_val == 0) return null;

    var result = std.array_list.Managed(*Expr).init(ctx.allocator);
    errdefer result.deinit();

    var idx = start_val;
    if (step_val > 0) {
        while (idx <= end_val) : (idx += step_val) {
            const iter_expr = try makeStructureConstructorIntLiteral(ctx, idx);
            for (implied.items) |item| {
                try result.append(try cloneStructureConstructorExprWithSubst(ctx, item, implied.var_name, iter_expr));
            }
        }
    } else {
        while (idx >= end_val) : (idx += step_val) {
            const iter_expr = try makeStructureConstructorIntLiteral(ctx, idx);
            for (implied.items) |item| {
                try result.append(try cloneStructureConstructorExprWithSubst(ctx, item, implied.var_name, iter_expr));
            }
        }
    }
    return try result.toOwnedSlice();
}

fn makeStructureConstructorIntLiteral(ctx: *Context, value: i64) EmitError!*Expr {
    const node = try ctx.allocator.create(Expr);
    node.* = .{ .literal = .{
        .kind = .integer,
        .text = try ctx.intLiteral(value),
    } };
    return node;
}

fn cloneStructureConstructorExprWithSubst(
    ctx: *Context,
    node: *Expr,
    name: []const u8,
    replacement: *Expr,
) EmitError!*Expr {
    const cloned = try ctx.allocator.create(Expr);
    switch (node.*) {
        .identifier => |ident| {
            if (std.ascii.eqlIgnoreCase(ident, name)) {
                cloned.* = replacement.*;
                return cloned;
            }
            cloned.* = .{ .identifier = ident };
        },
        .array_constructor => |ctor| {
            const items = try ctx.allocator.alloc(*Expr, ctor.items.len);
            for (ctor.items, 0..) |item, idx| {
                items[idx] = try cloneStructureConstructorExprWithSubst(ctx, item, name, replacement);
            }
            cloned.* = .{ .array_constructor = .{ .type_spec = ctor.type_spec, .items = items } };
        },
        .literal => |lit| cloned.* = .{ .literal = lit },
        .unary => |un| {
            cloned.* = .{ .unary = .{
                .op = un.op,
                .expr = try cloneStructureConstructorExprWithSubst(ctx, un.expr, name, replacement),
            } };
        },
        .binary => |bin| {
            cloned.* = .{ .binary = .{
                .op = bin.op,
                .left = try cloneStructureConstructorExprWithSubst(ctx, bin.left, name, replacement),
                .right = try cloneStructureConstructorExprWithSubst(ctx, bin.right, name, replacement),
            } };
        },
        .complex_literal => |lit| {
            cloned.* = .{ .complex_literal = .{
                .real = try cloneStructureConstructorExprWithSubst(ctx, lit.real, name, replacement),
                .imag = try cloneStructureConstructorExprWithSubst(ctx, lit.imag, name, replacement),
            } };
        },
        .call_or_subscript => |call_or_sub| {
            const args = try ctx.allocator.alloc(*Expr, call_or_sub.args.len);
            for (call_or_sub.args, 0..) |arg, idx| {
                args[idx] = try cloneStructureConstructorExprWithSubst(ctx, arg, name, replacement);
            }
            cloned.* = .{ .call_or_subscript = .{
                .name = call_or_sub.name,
                .args = args,
            } };
            if (ctx.ref_kinds.get(@as(usize, @intFromPtr(node)))) |kind| {
                try ctx.ref_kinds.put(@as(usize, @intFromPtr(cloned)), kind);
            }
        },
        .substring => |sub| {
            const args = try ctx.allocator.alloc(*Expr, sub.args.len);
            for (sub.args, 0..) |arg, idx| {
                args[idx] = try cloneStructureConstructorExprWithSubst(ctx, arg, name, replacement);
            }
            cloned.* = .{ .substring = .{
                .name = sub.name,
                .args = args,
                .start = if (sub.start) |start_expr| try cloneStructureConstructorExprWithSubst(ctx, start_expr, name, replacement) else null,
                .end = if (sub.end) |end_expr| try cloneStructureConstructorExprWithSubst(ctx, end_expr, name, replacement) else null,
            } };
        },
        .component => |comp| {
            const args = try ctx.allocator.alloc(*Expr, comp.args.len);
            for (comp.args, 0..) |arg, idx| {
                args[idx] = try cloneStructureConstructorExprWithSubst(ctx, arg, name, replacement);
            }
            cloned.* = .{ .component = .{
                .base = try cloneStructureConstructorExprWithSubst(ctx, comp.base, name, replacement),
                .name = comp.name,
                .args = args,
                .has_parens = comp.has_parens,
            } };
        },
        .dim_range => |range| {
            cloned.* = .{ .dim_range = .{
                .lower = if (range.lower) |lower| try cloneStructureConstructorExprWithSubst(ctx, lower, name, replacement) else null,
                .upper = try cloneStructureConstructorExprWithSubst(ctx, range.upper, name, replacement),
                .stride = if (range.stride) |stride_expr| try cloneStructureConstructorExprWithSubst(ctx, stride_expr, name, replacement) else null,
                .assumed_shape = range.assumed_shape,
            } };
        },
        .implied_do => |implied| {
            if (std.ascii.eqlIgnoreCase(implied.var_name, name)) {
                cloned.* = .{ .implied_do = implied };
            } else {
                const items = try ctx.allocator.alloc(*Expr, implied.items.len);
                for (implied.items, 0..) |item, idx| {
                    items[idx] = try cloneStructureConstructorExprWithSubst(ctx, item, name, replacement);
                }
                cloned.* = .{ .implied_do = .{
                    .items = items,
                    .var_name = implied.var_name,
                    .start = try cloneStructureConstructorExprWithSubst(ctx, implied.start, name, replacement),
                    .end = try cloneStructureConstructorExprWithSubst(ctx, implied.end, name, replacement),
                    .step = if (implied.step) |step_expr| try cloneStructureConstructorExprWithSubst(ctx, step_expr, name, replacement) else null,
                } };
            }
        },
    }
    return cloned;
}

fn structureConstructorShapeProduct(expr_node: *Expr) ?usize {
    return switch (expr_node.*) {
        .array_constructor => |ctor| blk: {
            if (ctor.items.len == 0) break :blk 0;
            var total: usize = 1;
            for (ctor.items) |item| {
                const value = switch (item.*) {
                    .literal => |lit| blk_lit: {
                        if (lit.kind != .integer) break :blk_lit null;
                        break :blk_lit std.fmt.parseInt(i64, lit.text, 10) catch null;
                    },
                    else => null,
                } orelse return null;
                if (value < 0) return null;
                const usize_value = std.math.cast(usize, value) orelse return null;
                total = std.math.mul(usize, total, usize_value) catch return null;
            }
            break :blk total;
        },
        else => null,
    };
}

fn emitStatementFunctionCall(
    ctx: *Context,
    builder: anytype,
    name: []const u8,
    def: context.StatementFunction,
    args: []*Expr,
) EmitError!ValueRef {
    if (def.params.len != args.len) return error.InvalidStatementFunctionCall;
    try ctx.stmt_func_stack.append(.{ .params = def.params, .actuals = args });
    defer _ = ctx.stmt_func_stack.pop();
    var value = try emitExprImpl(ctx, builder, def.expr, ctx.stmt_func_stack.items.len);
    if (ctx.findSymbol(name)) |sym| {
        const target_ty = ctx.typeFromKind(sym.loweredKind());
        value = try casting.coerce(ctx, builder, value, target_ty);
    }
    return value;
}
