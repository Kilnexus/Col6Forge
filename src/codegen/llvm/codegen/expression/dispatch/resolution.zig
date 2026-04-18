const std = @import("std");
const ast = @import("../../../../input.zig");
const ir = @import("../../../../ir.zig");
const llvm_types = @import("../../../types.zig");
const context = @import("../../context/mod.zig");
const utils = @import("../../utils.zig");
const procedure_pass = @import("../../../../../common/procedure_pass.zig");
const procedure_name_resolution = @import("../procedure_name_resolution.zig");
const type_specs = @import("../../../../../common/type_specs.zig");
const type_kind_selector = @import("../../../../../semantic/type_kind_selector.zig");
const ast_nodes = @import("../../../../../ast/nodes.zig");
const character = @import("character.zig");

const Context = context.Context;
const Expr = ast.Expr;

pub fn roughExprKind(ctx: *Context, expr: *Expr) ast.TypeKind {
    if (character.isCharacterExpr(ctx, expr)) return .character;
    return switch (expr.*) {
        .identifier => |name| {
            const sym = ctx.findSymbol(name) orelse return .integer;
            return sym.loweredKind();
        },
        .array_constructor => |ctor| {
            if (ctor.type_spec) |type_spec| {
                return type_spec.type_kind;
            }
            if (ctor.items.len == 0) return .integer;
            return roughExprKind(ctx, ctor.items[0]);
        },
        .literal => |lit| return switch (lit.kind) {
            .integer => .integer,
            .real => if (utils.realLiteralType(lit.text) == .f64) .double_precision else .real,
            .logical => .logical,
            .string, .hollerith => .character,
            .assumed_size => .integer,
        },
        .complex_literal => |lit| {
            const real_kind = roughExprKind(ctx, lit.real);
            const imag_kind = roughExprKind(ctx, lit.imag);
            return if (real_kind == .double_precision or imag_kind == .double_precision) .complex_double else .complex;
        },
        .component => |comp| blk: {
            if (!comp.has_parens and comp.args.len == 0) {
                if (std.ascii.eqlIgnoreCase(comp.name, "len") or std.ascii.eqlIgnoreCase(comp.name, "kind")) {
                    break :blk .integer;
                }
                if (std.ascii.eqlIgnoreCase(comp.name, "re") or std.ascii.eqlIgnoreCase(comp.name, "im")) {
                    const base_kind = roughExprKind(ctx, comp.base);
                    break :blk switch (base_kind) {
                        .complex_double => .double_precision,
                        .complex => .real,
                        else => .integer,
                    };
                }
            }
            const base_name = ctx.derivedTypeNameForExpr(comp.base) orelse break :blk .integer;
            const component = ctx.lookupDerivedComponentLayout(base_name, comp.name) orelse break :blk .integer;
            break :blk component.type_spec.lowered_kind;
        },
        .call_or_subscript => |call_or_sub| {
            const sym = ctx.findSymbol(call_or_sub.name) orelse return .integer;
            return sym.loweredKind();
        },
        .unary => |un| {
            if (un.op == .not and resolveSingleTargetGenericProcedureName(ctx, "operator(.not.)") != null and roughExprKind(ctx, un.expr) != .logical) {
                return .derived;
            }
            return roughExprKind(ctx, un.expr);
        },
        .binary => |bin| return switch (bin.op) {
            .eq, .ne, .lt, .le, .gt, .ge, .and_, .or_, .eqv, .neqv => .logical,
            .concat => .character,
            else => blk: {
                const left_kind = roughExprKind(ctx, bin.left);
                const right_kind = roughExprKind(ctx, bin.right);
                break :blk switch (promoteNumericKind(left_kind, right_kind)) {
                    .integer => .integer,
                    .real => .real,
                    .double_precision => .double_precision,
                    .complex => .complex,
                    .complex_double => .complex_double,
                    else => .integer,
                };
            },
        },
        .substring => .character,
        .dim_range => .integer,
        .implied_do => .integer,
    };
}

pub fn isNumericKind(kind: ast.TypeKind) bool {
    return switch (kind) {
        .integer, .real, .double_precision, .complex, .complex_double => true,
        else => false,
    };
}

pub fn unaryDefinedOperatorName(op: ast.UnaryOp) ?[]const u8 {
    return switch (op) {
        .not => "operator(.not.)",
        else => null,
    };
}

pub fn binaryDefinedOperatorName(op: ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .eq => "operator(==)",
        .ne => "operator(/=)",
        .lt => "operator(<)",
        .le => "operator(<=)",
        .gt => "operator(>)",
        .ge => "operator(>=)",
        else => null,
    };
}

pub fn resolveSingleTargetGenericProcedureName(ctx: *Context, generic_name: []const u8) ?[]const u8 {
    const resolved = resolveSingleTargetGenericProcedure(ctx, generic_name) orelse return null;
    return resolved.procedure_name;
}

pub const ResolvedGenericProcedure = struct {
    procedure_name: []const u8,
    lookup_name: []const u8,
    ir_name: []const u8,
    sig: ast.sema.KnownProcedureSig,
};

pub fn resolveSingleTargetGenericProcedure(ctx: *Context, generic_name: []const u8) ?ResolvedGenericProcedure {
    for (ctx.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, generic_name)) continue;
        return singleTargetInterfaceProcedure(ctx, decl.interface_block);
    }
    return null;
}

pub fn definedUnaryOperatorResultType(ctx: *Context, expr: *Expr, proc_name: []const u8) ir.IRType {
    _ = expr;
    if (ctx.findSymbol(proc_name)) |sym| {
        return ctx.typeFromKind(sym.loweredKind());
    }
    return .ptr;
}

pub fn buildTypeBoundProcedureActuals(
    ctx: *Context,
    comp: ast.ComponentExpr,
    binding: context.DerivedBindingInfo,
) ![]*Expr {
    const proc_name = binding.implementation_name orelse binding.interface_name orelse binding.name;
    const lookup_name = try boundProcedureLookupName(ctx, binding, proc_name);
    const proc_sig = ctx.lookupKnownProcedureSig(lookup_name) orelse ctx.lookupKnownProcedureSig(proc_name);
    const pass_idx = if (binding.nopass or proc_sig == null) null else procedure_pass.procedurePassArgIndex(proc_sig.?.args, binding.pass_name);
    const extra: usize = if (binding.nopass) 0 else 1;
    const actuals = try ctx.allocator.alloc(*Expr, comp.args.len + extra);
    const fallback_pass_idx: ?usize = if (!binding.nopass and pass_idx == null and actuals.len > comp.args.len) 0 else pass_idx;
    var actual_idx: usize = 0;
    var comp_idx: usize = 0;
    while (actual_idx < actuals.len) : (actual_idx += 1) {
        if (fallback_pass_idx != null and actual_idx == fallback_pass_idx.?) {
            actuals[actual_idx] = comp.base;
            continue;
        }
        actuals[actual_idx] = comp.args[comp_idx];
        comp_idx += 1;
    }
    return actuals;
}

pub fn boundProcedureResultSpec(
    ctx: *Context,
    binding: context.DerivedBindingInfo,
    proc_sig: ast.sema.KnownProcedureSig,
) ?ast.TypeSpec {
    if (proc_sig.result_type_spec) |type_spec| return type_spec;
    const proc_name = binding.implementation_name orelse binding.interface_name orelse binding.name;
    if (ctx.findSymbol(proc_name)) |sym| {
        return sym.type_spec;
    }
    if (binding.interface_name) |iface_name| {
        if (ctx.findSymbol(iface_name)) |sym| return sym.type_spec;
    }
    for (ctx.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (!std.ascii.eqlIgnoreCase(proc_header.name, proc_name)) continue;
            return interfaceProcedureResultTypeSpec(ctx.unit, proc_header);
        }
    }
    return null;
}

pub fn interfaceProcedureResultTypeSpec(
    unit: ast.ProgramUnit,
    proc_header: ast_nodes.InterfaceProcedure,
) ?ast.TypeSpec {
    if (proc_header.kind != .function) return null;
    if (findInterfaceProcedureDeclaredResultTypeSpec(unit, proc_header)) |type_spec| return type_spec;
    if (proc_header.type_spec) |type_spec| return type_specs.typeSpecFromProcedureType(type_spec);
    return implicitTypeSpecForName(unit, proc_header.name);
}

pub fn boundProcedureLookupName(
    ctx: *Context,
    binding: context.DerivedBindingInfo,
    proc_name: []const u8,
) ![]const u8 {
    if (binding.owner_name) |owner_name| {
        return std.fmt.allocPrint(ctx.allocator, "{s}::{s}", .{ owner_name, proc_name });
    }
    return proc_name;
}

pub fn boundProcedureIRName(
    ctx: *Context,
    binding: context.DerivedBindingInfo,
    proc_name: []const u8,
) ![]const u8 {
    if (binding.owner_name) |owner_name| {
        if (binding.owner_kind) |owner_kind| {
            return utils.mangleProcedureUnitName(ctx.allocator, .{
                .kind = .subroutine,
                .name = proc_name,
                .owner_name = owner_name,
                .owner_kind = owner_kind,
                .args = &.{},
                .decls = &.{},
                .stmts = &.{},
            });
        }
    }
    return ctx.mangleName(proc_name);
}

pub fn ensureExternalDeclForCall(
    ctx: *Context,
    name: []const u8,
    ret_ty: ir.IRType,
    args: []*Expr,
    has_character_result: bool,
) ![]const u8 {
    if (resolveVisibleProcedureCallTarget(ctx, name)) |resolved| {
        return ensureExternalDeclForResolvedCall(ctx, resolved.lookup_name, resolved.ir_name, ret_ty, args, has_character_result);
    }
    if (try procedure_name_resolution.uniqueProcedureIRNameBySuffix(ctx, name)) |resolved_ir| {
        return ensureExternalDeclForResolvedCall(ctx, name, resolved_ir, ret_ty, args, has_character_result);
    }
    const mangled = try ctx.mangleName(name);
    return ensureExternalDeclForResolvedCall(ctx, name, mangled, ret_ty, args, has_character_result);
}

pub fn ensureExternalDeclForResolvedCall(
    ctx: *Context,
    lookup_name: []const u8,
    mangled: []const u8,
    ret_ty: ir.IRType,
    args: []*Expr,
    has_character_result: bool,
) ![]const u8 {
    if (ctx.defined.contains(mangled)) return mangled;
    const proc_sig = ctx.lookupKnownProcedureSig(lookup_name);
    const decl_ret_ty = if (proc_sig != null and usesHiddenArrayResultAbi(proc_sig.?))
        ir.IRType.void
    else
        ctx.abiFunctionReturnType(ret_ty);

    if (ctx.decls.get(mangled)) |existing| {
        if (!existing.varargs) return mangled;
        const param_types = try buildAbiParamTypes(ctx, lookup_name, ret_ty, args, has_character_result);

        try ctx.decls.put(mangled, .{
            .ret_type = decl_ret_ty,
            .sig = try formatParamSig(ctx, param_types),
            .varargs = false,
        });
        return mangled;
    }

    const param_types = try buildAbiParamTypes(ctx, lookup_name, ret_ty, args, has_character_result);
    return ctx.ensureDeclRaw(
        mangled,
        decl_ret_ty,
        param_types,
        false,
    );
}

fn singleTargetInterfaceProcedureName(interface_block: anytype) ?[]const u8 {
    const module_count = interface_block.module_procedures.len;
    const specific_count = interface_block.specific_procedures.len;
    const procedure_count = interface_block.procedures.len;
    const header_count = interface_block.procedure_headers.len;
    const total = module_count + specific_count + procedure_count + header_count;
    if (total != 1) return null;
    if (module_count == 1) return interface_block.module_procedures[0];
    if (specific_count == 1) return interface_block.specific_procedures[0];
    if (procedure_count == 1) return interface_block.procedures[0];
    return interface_block.procedure_headers[0].name;
}

fn singleTargetInterfaceProcedure(ctx: *Context, interface_block: anytype) ?ResolvedGenericProcedure {
    const total = interface_block.module_procedures.len + interface_block.specific_procedures.len + interface_block.procedures.len + interface_block.procedure_headers.len;
    if (total != 1) return null;

    if (interface_block.module_procedures.len == 1) {
        const proc_name = interface_block.module_procedures[0];
        const source = interface_block.module_procedure_sources[0];
        const owner_name = source.owner_name;
        const sig = lookupInterfaceProcedureSig(ctx, proc_name, owner_name) orelse return null;
        const lookup_name = if (owner_name) |owner|
            std.fmt.allocPrint(ctx.allocator, "{s}::{s}", .{ owner, proc_name }) catch return null
        else
            proc_name;
        const ir_name = if (owner_name) |owner|
            utils.mangleProcedureUnitName(ctx.allocator, .{
                .kind = sig.kind,
                .name = proc_name,
                .owner_name = owner,
                .owner_kind = .module,
                .args = &.{},
                .decls = &.{},
                .stmts = &.{},
            }) catch return null
        else
            (ctx.mangleName(proc_name) catch return null);
        return .{
            .procedure_name = proc_name,
            .lookup_name = lookup_name,
            .ir_name = ir_name,
            .sig = sig,
        };
    }
    if (interface_block.specific_procedures.len == 1) {
        const proc_name = interface_block.specific_procedures[0];
        const sig = ctx.lookupKnownProcedureSig(proc_name) orelse return null;
        const ir_name = ctx.mangleName(proc_name) catch return null;
        return .{
            .procedure_name = proc_name,
            .lookup_name = proc_name,
            .ir_name = ir_name,
            .sig = sig,
        };
    }
    if (interface_block.procedures.len == 1) {
        const proc_name = interface_block.procedures[0];
        const sig = ctx.lookupKnownProcedureSig(proc_name) orelse return null;
        const ir_name = ctx.mangleName(proc_name) catch return null;
        return .{
            .procedure_name = proc_name,
            .lookup_name = proc_name,
            .ir_name = ir_name,
            .sig = sig,
        };
    }
    if (interface_block.procedure_headers.len == 1) {
        const proc_name = interface_block.procedure_headers[0].name;
        const sig = ctx.lookupKnownProcedureSig(proc_name) orelse return null;
        const ir_name = ctx.mangleName(proc_name) catch return null;
        return .{
            .procedure_name = proc_name,
            .lookup_name = proc_name,
            .ir_name = ir_name,
            .sig = sig,
        };
    }
    return null;
}

fn lookupInterfaceProcedureSig(ctx: *Context, proc_name: []const u8, owner_name: ?[]const u8) ?ast.sema.KnownProcedureSig {
    if (owner_name) |owner| {
        const qualified = std.fmt.allocPrint(ctx.allocator, "{s}::{s}", .{ owner, proc_name }) catch return null;
        if (ctx.lookupKnownProcedureSig(qualified)) |sig| return sig;
    }
    return ctx.lookupKnownProcedureSig(proc_name);
}

const VisibleProcedureCallTarget = struct {
    lookup_name: []const u8,
    ir_name: []const u8,
};

fn resolveVisibleProcedureCallTarget(ctx: *Context, name: []const u8) ?VisibleProcedureCallTarget {
    const sym = ctx.findSymbol(name) orelse return null;
    const owner_name = sym.host_owner_name orelse return null;

    const qualified = std.fmt.allocPrint(ctx.allocator, "{s}::{s}", .{ owner_name, name }) catch return null;
    if (ctx.lookupKnownProcedureSig(qualified) == null) return null;

    const module_ir = utils.mangleProcedureUnitName(ctx.allocator, .{
        .kind = if (sym.kind == .function) .function else .subroutine,
        .name = name,
        .owner_name = owner_name,
        .owner_kind = .module,
        .args = &.{},
        .decls = &.{},
        .stmts = &.{},
    }) catch return null;
    if (ctx.defined.contains(module_ir) or ctx.decls.contains(module_ir)) {
        return .{ .lookup_name = qualified, .ir_name = module_ir };
    }

    const proc_ir = utils.mangleProcedureUnitName(ctx.allocator, .{
        .kind = if (sym.kind == .function) .function else .subroutine,
        .name = name,
        .owner_name = owner_name,
        .owner_kind = .procedure,
        .args = &.{},
        .decls = &.{},
        .stmts = &.{},
    }) catch return null;
    if (ctx.defined.contains(proc_ir) or ctx.decls.contains(proc_ir)) {
        return .{ .lookup_name = qualified, .ir_name = proc_ir };
    }

    return null;
}

fn promoteNumericKind(left: ast.TypeKind, right: ast.TypeKind) ast.TypeKind {
    if ((left == .complex_double) or (right == .complex_double)) return .complex_double;
    if ((left == .complex) or (right == .complex)) {
        if (left == .double_precision or right == .double_precision) return .complex_double;
        return .complex;
    }
    if (left == .double_precision or right == .double_precision) return .double_precision;
    if (left == .real or right == .real) return .real;
    return .integer;
}

fn findInterfaceProcedureDeclaredResultTypeSpec(
    unit: ast.ProgramUnit,
    proc_header: ast_nodes.InterfaceProcedure,
) ?ast.TypeSpec {
    const result_name = proc_header.result_name orelse proc_header.name;
    for (proc_header.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return applyDeclaratorCharLen(type_specs.typeSpecFromTypeDecl(type_decl), item);
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return switch (procedure_decl.interface) {
                        .type_spec => |proc_type| applyDeclaratorCharLen(type_specs.typeSpecFromProcedureType(proc_type), item),
                        else => applyDeclaratorCharLen(implicitTypeSpecForName(unit, result_name), item),
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn implicitTypeSpecForName(unit: ast.ProgramUnit, name: []const u8) ast.TypeSpec {
    if (name.len != 0) {
        const first = std.ascii.toUpper(name[0]);
        for (unit.decls) |decl| {
            if (decl != .implicit) continue;
            for (decl.implicit.rules) |rule| {
                if (first < rule.start or first > rule.end) continue;
                return applyCharacterLength(type_kind_selector.resolveSpec(rule.type_kind, rule.kind_selector), rule.char_len);
            }
        }
        if (first >= 'I' and first <= 'N') return ast.TypeSpec.fromResolvedKind(.integer, .integer, null);
    }
    return ast.TypeSpec.fromResolvedKind(.real, .real, null);
}

fn applyDeclaratorCharLen(type_spec: ast.TypeSpec, declarator: ast.Declarator) ast.TypeSpec {
    if (declarator.char_len_deferred) return type_spec.withCharacterLength(.deferred, null);
    return applyCharacterLength(type_spec, declarator.char_len);
}

fn applyCharacterLength(type_spec: ast.TypeSpec, char_len_expr: ?*Expr) ast.TypeSpec {
    if (type_spec.lowered_kind != .character) return type_spec.withCharacterLength(.none, null);
    const char_len = inferConstantCharLen(char_len_expr);
    return type_spec.withCharacterLength(
        if (char_len != null) .constant else if (char_len_expr != null) .deferred else .constant,
        char_len orelse if (char_len_expr == null) 1 else null,
    );
}

fn inferConstantCharLen(len_expr: ?*Expr) ?usize {
    const expr_node = len_expr orelse return null;
    return switch (expr_node.*) {
        .literal => |lit| switch (lit.kind) {
            .integer => std.fmt.parseInt(usize, lit.text, 10) catch null,
            else => null,
        },
        else => null,
    };
}

fn buildAbiParamTypes(
    ctx: *Context,
    name: []const u8,
    ret_ty: ir.IRType,
    args: []*Expr,
    has_character_result: bool,
) ![]const llvm_types.IRType {
    var tys = std.array_list.Managed(llvm_types.IRType).init(ctx.allocator);
    defer tys.deinit();

    const proc_sig = ctx.lookupKnownProcedureSig(name);
    const has_hidden_result_ptr = has_character_result or
        ctx.abiUsesHiddenResultPtr(ret_ty) or
        (proc_sig != null and usesHiddenArrayResultAbi(proc_sig.?));
    if (has_hidden_result_ptr) {
        try tys.append(.ptr);
        if (proc_sig) |sig| {
            if (sig.result_rank != 0 and (sig.is_pointer or sig.result_allocatable)) {
                try tys.append(.ptr);
                try tys.append(.ptr);
            }
        }
    }
    for (args, 0..) |_, idx| {
        try tys.append(.ptr);
        if (proc_sig) |sig| {
            if (idx < sig.args.len and sig.args[idx].requires_descriptor) {
                try tys.append(.ptr);
                try tys.append(.ptr);
            }
        }
    }
    if (has_character_result) {
        try tys.append(ctx.abiCharacterLenType());
    }
    for (args) |arg| {
        if (isCharacterAbiActual(ctx, arg)) {
            try tys.append(ctx.abiCharacterLenType());
        }
    }
    return tys.toOwnedSlice();
}

fn usesHiddenArrayResultAbi(sig: ast.sema.KnownProcedureSig) bool {
    return sig.result_rank != 0;
}

fn formatParamSig(ctx: *Context, param_types: []const llvm_types.IRType) ![]const u8 {
    if (param_types.len == 0) return "";

    var text = std.array_list.Managed(u8).init(ctx.allocator);
    defer text.deinit();
    for (param_types, 0..) |param_ty, idx| {
        if (idx != 0) try text.appendSlice(", ");
        try text.appendSlice(llvm_types.irTypeText(param_ty));
    }
    return text.toOwnedSlice();
}

fn isCharacterAbiActual(ctx: *Context, expr: *Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const sym = ctx.findSymbol(name) orelse break :blk false;
            break :blk sym.isCharacter();
        },
        .array_constructor => |ctor| blk: {
            if (ctor.type_spec) |type_spec| {
                if (type_spec.type_kind == .character) break :blk true;
            }
            if (ctor.items.len == 0) break :blk false;
            break :blk isCharacterAbiActual(ctx, ctor.items[0]);
        },
        .call_or_subscript => |call_or_sub| blk: {
            const sym = ctx.findSymbol(call_or_sub.name) orelse break :blk false;
            break :blk sym.isCharacter();
        },
        .substring => true,
        .literal => |lit| lit.kind == .string or lit.kind == .hollerith,
        .binary => |bin| bin.op == .concat,
        .implied_do => |implied| implied.items.len != 0 and isCharacterAbiActual(ctx, implied.items[0]),
        else => false,
    };
}
