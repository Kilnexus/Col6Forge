const std = @import("std");
const ast = @import("../../../input.zig");
const llvm_types = @import("../../types.zig");
const context = @import("../../codegen/context/mod.zig");
const common = @import("../../codegen/common.zig");
const pure_helpers = @import("../../codegen/context/support/pure_helpers.zig");
const expression = @import("../../codegen/expression/mod.zig");
const saved_state = @import("saved_state.zig");

const Context = context.Context;
const ValueRef = context.ValueRef;

const EmitError = anyerror;

pub const LocalInstallOptions = struct {
    return_symbol_name: []const u8,
    uses_explicit_result_name: bool,
    uses_hidden_result_ptr: bool,
    is_character_function: bool,
    is_complex_sret_function: bool,
};

pub fn installFunctionLocals(
    ctx: *Context,
    builder: anytype,
    save_info: *const saved_state.SaveInfo,
    options: LocalInstallOptions,
) EmitError!void {
    for (ctx.sem.symbols) |sym| {
        if (sym.storage != .local) continue;
        const is_function_name_symbol = ctx.unit.kind == .function and
            sym.kind == .function and
            std.ascii.eqlIgnoreCase(sym.name, ctx.unit.name);
        const is_return_symbol = ctx.unit.kind == .function and
            std.ascii.eqlIgnoreCase(sym.name, options.return_symbol_name);
        if (options.uses_explicit_result_name and is_function_name_symbol) continue;
        if (sym.is_external) continue;
        if (sym.is_intrinsic) continue;
        if (sym.kind == .parameter and !shouldMaterializeParameterArrayLocal(sym)) continue;
        if (sym.kind == .subroutine and !sym.is_pointer) continue;
        if (sym.kind == .function and !sym.is_pointer and !is_return_symbol and ctx.unit.kind != .function) continue;
        if (is_return_symbol and options.uses_hidden_result_ptr) continue;
        if (ctx.locals.contains(sym.name)) continue;
        if (saved_state.isSaved(save_info, sym.name) and !is_return_symbol) continue;
        if (sym.is_alias) continue;
        if (sym.is_pointer) {
            const slot_name = try ctx.nextTemp();
            try builder.alloca(slot_name, .ptr);
            const slot_ptr = ValueRef{ .name = slot_name, .ty = .ptr, .is_ptr = true };
            try builder.store(.{ .name = "null", .ty = .ptr, .is_ptr = false }, slot_ptr);
            try ctx.locals.put(sym.name, slot_ptr);
            if (symbolHasDeferredDims(sym)) {
                try installDeferredArrayDescriptor(ctx, builder, sym);
            }
            continue;
        }
        if (sym.is_allocatable and sym.dims.len == 0) {
            try ctx.locals.put(sym.name, .{ .name = "null", .ty = .ptr, .is_ptr = true });
            if (sym.isCharacter()) {
                try ctx.char_arg_lens.put(sym.name, .{ .name = try ctx.intLiteral(0), .ty = .i32, .is_ptr = false });
            }
            continue;
        }
        if (symbolHasDeferredDims(sym)) {
            if (is_return_symbol and ctx.unit.kind == .function and !options.is_character_function and !options.is_complex_sret_function) {
                const ty = common.symbolStorageIRType(sym, ctx.options.target_layout);
                const alloca_name = try ctx.nextTemp();
                try builder.alloca(alloca_name, ty);
                try ctx.locals.put(sym.name, .{ .name = alloca_name, .ty = .ptr, .is_ptr = true });
                continue;
            }
            try ctx.locals.put(sym.name, .{ .name = "null", .ty = .ptr, .is_ptr = true });
            try installDeferredArrayDescriptor(ctx, builder, sym);
            if (sym.isCharacter()) {
                try ctx.char_arg_lens.put(sym.name, .{ .name = try ctx.intLiteral(0), .ty = .i32, .is_ptr = false });
            }
            continue;
        }
        if (sym.loweredKind() == .derived and sym.dims.len == 0) {
            const type_name = sym.type_spec.derived_type_name orelse return error.UnknownSymbol;
            const layout = ctx.findDerivedTypeLayout(type_name) orelse return error.UnknownSymbol;
            const slot_name = try ctx.nextTemp();
            try builder.alloca(slot_name, .ptr);
            const object_name = try ctx.nextTemp();
            if (layout.size <= 1) {
                try builder.alloca(object_name, .i8);
            } else {
                try builder.allocaArray(object_name, .i8, layout.size);
            }
            try builder.store(.{ .name = object_name, .ty = .ptr, .is_ptr = true }, .{ .name = slot_name, .ty = .ptr, .is_ptr = true });
            try ctx.locals.put(sym.name, .{ .name = slot_name, .ty = .ptr, .is_ptr = true });
            continue;
        }
        if (sym.isCharacter()) {
            if (sym.effectiveCharLenKind() == .deferred) {
                const len_i32 = try emitDeferredCharacterLocalLen(ctx, builder, sym);
                try ctx.char_arg_lens.put(sym.name, len_i32);

                const len_i64 = if (len_i32.ty == .i64)
                    len_i32
                else
                    try expression.coerce(ctx, builder, len_i32, .i64);
                const alloca_name = try ctx.nextTemp();
                if (sym.dims.len > 0) {
                    const elem_count = ctx.arrayElemCountForSymbol(sym) catch |err| switch (err) {
                        error.ArrayDimNotConstant => null,
                        else => return err,
                    };
                    const total = if (elem_count) |count|
                        try expression.emitMul(ctx, builder, len_i64, constI64(ctx, @intCast(count)))
                    else blk: {
                        const dyn_count = try emitDynamicElemCount(ctx, builder, sym);
                        const dyn_count_i64 = if (dyn_count.ty == .i64)
                            dyn_count
                        else
                            try expression.coerce(ctx, builder, dyn_count, .i64);
                        break :blk try expression.emitMul(ctx, builder, len_i64, dyn_count_i64);
                    };
                    try builder.allocaArrayValue(alloca_name, .i8, total);
                } else {
                    try builder.allocaArrayValue(alloca_name, .i8, len_i64);
                }
                try ctx.locals.put(sym.name, .{ .name = alloca_name, .ty = .ptr, .is_ptr = true });
                continue;
            }
            const char_len = try common.requireConstantCharacterLen(sym);
            const alloca_name = try ctx.nextTemp();
            if (sym.dims.len > 0) {
                const elem_count = ctx.arrayElemCountForSymbol(sym) catch |err| switch (err) {
                    error.ArrayDimNotConstant => null,
                    else => return err,
                };
                if (elem_count) |count| {
                    const total = count * char_len;
                    if (total == 1) {
                        try builder.alloca(alloca_name, .i8);
                    } else {
                        try builder.allocaArray(alloca_name, .i8, total);
                    }
                } else {
                    var dyn_total = try emitDynamicElemCount(ctx, builder, sym);
                    if (char_len != 1) {
                        dyn_total = try expression.emitMul(ctx, builder, dyn_total, constI64(ctx, @intCast(char_len)));
                    }
                    try builder.allocaArrayValue(alloca_name, .i8, dyn_total);
                }
            } else if (char_len == 1) {
                try builder.alloca(alloca_name, .i8);
            } else {
                try builder.allocaArray(alloca_name, .i8, char_len);
            }
            try ctx.locals.put(sym.name, .{ .name = alloca_name, .ty = .ptr, .is_ptr = true });
            continue;
        }
        const ty = common.symbolStorageIRType(sym, ctx.options.target_layout);
        if (sym.dims.len > 0) {
            if (sym.is_generated_temp) {
                const elem_count = ctx.arrayElemCountForSymbol(sym) catch |err| switch (err) {
                    error.ArrayDimNotConstant => null,
                    else => return err,
                };
                const count_val = if (elem_count) |count|
                    constI64(ctx, @intCast(count))
                else
                    try emitDynamicElemCount(ctx, builder, sym);
                const elem_size = constI64(ctx, @intCast(pure_helpers.sizeAlignForIRType(ty).size));
                const total_bytes = try expression.emitMul(ctx, builder, count_val, elem_size);
                const malloc_name = try ctx.ensureDeclRaw("malloc", .ptr, &[_]llvm_types.IRType{.i64}, false);
                const heap_ptr_name = try ctx.nextTemp();
                try builder.callTyped(heap_ptr_name, .ptr, malloc_name, &.{total_bytes});
                const heap_ptr = ValueRef{ .name = heap_ptr_name, .ty = .ptr, .is_ptr = true };
                try ctx.locals.put(sym.name, heap_ptr);
                try ctx.registerHeapTempToFree(heap_ptr);
                continue;
            }
            const alloca_name = try ctx.nextTemp();
            const elem_count = ctx.arrayElemCountForSymbol(sym) catch |err| switch (err) {
                error.ArrayDimNotConstant => null,
                else => return err,
            };
            if (elem_count) |count| {
                try builder.allocaArray(alloca_name, ty, count);
            } else {
                const dyn_count = try emitDynamicElemCount(ctx, builder, sym);
                try builder.allocaArrayValue(alloca_name, ty, dyn_count);
            }
            try ctx.locals.put(sym.name, .{ .name = alloca_name, .ty = .ptr, .is_ptr = true });
            continue;
        }
        const alloca_name = try ctx.nextTemp();
        try builder.alloca(alloca_name, ty);
        try ctx.locals.put(sym.name, .{ .name = alloca_name, .ty = .ptr, .is_ptr = true });
    }

    if (options.uses_explicit_result_name) {
        const result_ptr = ctx.locals.get(options.return_symbol_name) orelse return error.UnknownSymbol;
        try ctx.locals.put(ctx.unit.name, result_ptr);
    }
}

pub fn installIncomingArrayDescriptor(
    ctx: *Context,
    builder: anytype,
    sym: ast.sema.Symbol,
    extent_base: ValueRef,
    multiplier_base: ValueRef,
) EmitError!void {
    if (sym.dims.len == 0) return;
    var lower_slots = try ctx.allocator.alloc(ValueRef, sym.dims.len);
    errdefer ctx.allocator.free(lower_slots);
    var extent_slots = try ctx.allocator.alloc(ValueRef, sym.dims.len);
    errdefer ctx.allocator.free(extent_slots);
    var multiplier_slots = try ctx.allocator.alloc(ValueRef, sym.dims.len);
    errdefer ctx.allocator.free(multiplier_slots);

    for (sym.dims, 0..) |_, idx| {
        const offset = constI64(ctx, @intCast(idx));

        const lower_name = try ctx.nextTemp();
        try builder.alloca(lower_name, .i64);
        lower_slots[idx] = .{ .name = lower_name, .ty = .ptr, .is_ptr = true };
        try builder.store(try expression.emitSymbolDimLower(ctx, builder, sym, idx), lower_slots[idx]);

        const extent_name = try ctx.nextTemp();
        try builder.gep(extent_name, .i64, extent_base, offset);
        extent_slots[idx] = .{ .name = extent_name, .ty = .ptr, .is_ptr = true };

        const multiplier_name = try ctx.nextTemp();
        try builder.gep(multiplier_name, .i64, multiplier_base, offset);
        multiplier_slots[idx] = .{ .name = multiplier_name, .ty = .ptr, .is_ptr = true };
    }

    try ctx.setRuntimeArrayDescriptor(sym.name, lower_slots, extent_slots, multiplier_slots);
}

pub fn symbolHasDeferredDims(sym: ast.sema.Symbol) bool {
    if (sym.dims.len == 0) return false;
    if (sym.is_pointer or sym.is_allocatable) return true;
    for (sym.dims) |dim| {
        switch (dim.*) {
            .dim_range => |range| if (range.assumed_shape) return true,
            else => {},
        }
    }
    return false;
}

pub fn installAssignedGotoSlots(ctx: *Context, builder: anytype) EmitError!void {
    var seen = context.CaseInsensitiveStringHashMap(void).initContext(ctx.allocator, .{});
    defer seen.deinit();
    var names = std.array_list.Managed([]const u8).init(ctx.allocator);
    defer names.deinit();

    try collectAssignedGotoVars(ctx.unit.stmts, &seen, &names);
    for (names.items) |name| {
        if (ctx.assigned_goto_slots.contains(name)) continue;
        const slot_name = try ctx.nextTemp();
        try builder.alloca(slot_name, .ptr);
        const slot_ptr = ValueRef{ .name = slot_name, .ty = .ptr, .is_ptr = true };
        try builder.store(.{ .name = "null", .ty = .ptr, .is_ptr = false }, slot_ptr);
        try ctx.assigned_goto_slots.put(name, slot_ptr);
    }
}

fn shouldMaterializeParameterArrayLocal(sym: ast.sema.Symbol) bool {
    return sym.kind == .parameter and sym.dims.len != 0;
}

fn emitDynamicElemCount(ctx: *Context, builder: anytype, sym: ast.sema.Symbol) EmitError!ValueRef {
    var total = constI64(ctx, 1);
    for (sym.dims, 0..) |dim, dim_idx| {
        var extent = expression.emitSymbolDimExtent(ctx, builder, sym, dim_idx) catch |err| switch (err) {
            error.UnknownSymbol => expression.emitDimValue(ctx, builder, dim) catch |inner| switch (inner) {
                error.UnknownSymbol => constI64(ctx, 1),
                else => return inner,
            },
            else => return err,
        };
        if (extent.ty != .i64) {
            extent = try expression.coerce(ctx, builder, extent, .i64);
        }
        total = try expression.emitMul(ctx, builder, total, extent);
    }
    return total;
}

fn emitDeferredCharacterLocalLen(ctx: *Context, builder: anytype, sym: ast.sema.Symbol) EmitError!ValueRef {
    if (findLocalCharacterLenExpr(ctx.unit, sym.name)) |len_expr| {
        var len_val = try expression.emitExpr(ctx, builder, len_expr);
        if (len_val.ty != .i32) len_val = try expression.coerce(ctx, builder, len_val, .i32);
        return len_val;
    }
    if (ctx.char_arg_lens.get(sym.name)) |len_val| {
        return if (len_val.ty == .i32) len_val else try expression.coerce(ctx, builder, len_val, .i32);
    }
    return try ctx.constI32(1);
}

fn findLocalCharacterLenExpr(unit: ast.ProgramUnit, name: []const u8) ?*ast.Expr {
    var decl_idx = unit.decls.len;
    while (decl_idx > 0) {
        decl_idx -= 1;
        const decl = unit.decls[decl_idx];
        if (decl != .type_decl or decl.type_decl.type_kind != .character) continue;
        var item_idx = decl.type_decl.items.len;
        while (item_idx > 0) {
            item_idx -= 1;
            const item = decl.type_decl.items[item_idx];
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.char_len;
        }
    }
    return null;
}

fn installDeferredArrayDescriptor(ctx: *Context, builder: anytype, sym: ast.sema.Symbol) EmitError!void {
    if (sym.dims.len == 0) return;
    var lower_slots = try ctx.allocator.alloc(ValueRef, sym.dims.len);
    errdefer ctx.allocator.free(lower_slots);
    var extent_slots = try ctx.allocator.alloc(ValueRef, sym.dims.len);
    errdefer ctx.allocator.free(extent_slots);
    var multiplier_slots = try ctx.allocator.alloc(ValueRef, sym.dims.len);
    errdefer ctx.allocator.free(multiplier_slots);

    for (sym.dims, 0..) |_, idx| {
        const lower_name = try ctx.nextTemp();
        try builder.alloca(lower_name, .i64);
        const lower_ptr = ValueRef{ .name = lower_name, .ty = .ptr, .is_ptr = true };
        try builder.store(constI64(ctx, 1), lower_ptr);
        lower_slots[idx] = lower_ptr;

        const extent_name = try ctx.nextTemp();
        try builder.alloca(extent_name, .i64);
        const extent_ptr = ValueRef{ .name = extent_name, .ty = .ptr, .is_ptr = true };
        try builder.store(constI64(ctx, 0), extent_ptr);
        extent_slots[idx] = extent_ptr;

        const multiplier_name = try ctx.nextTemp();
        try builder.alloca(multiplier_name, .i64);
        const multiplier_ptr = ValueRef{ .name = multiplier_name, .ty = .ptr, .is_ptr = true };
        try builder.store(constI64(ctx, if (idx == 0) 1 else 0), multiplier_ptr);
        multiplier_slots[idx] = multiplier_ptr;
    }

    try ctx.setRuntimeArrayDescriptor(sym.name, lower_slots, extent_slots, multiplier_slots);
}

fn constI64(ctx: *Context, value: i64) ValueRef {
    return .{ .name = ctx.intLiteral(value) catch unreachable, .ty = .i64, .is_ptr = false };
}

fn collectAssignedGotoVars(
    stmts: []const ast.Stmt,
    seen: *context.CaseInsensitiveStringHashMap(void),
    out_names: *std.array_list.Managed([]const u8),
) EmitError!void {
    for (stmts) |stmt| {
        try collectAssignedGotoVarsFromNode(stmt.node, seen, out_names);
    }
}

fn collectAssignedGotoVarsFromNode(
    node: ast.StmtNode,
    seen: *context.CaseInsensitiveStringHashMap(void),
    out_names: *std.array_list.Managed([]const u8),
) EmitError!void {
    switch (node) {
        .assign_label => {},
        .assigned_goto => |assigned| {
            if (assigned.labels.len == 0) {
                try addAssignedGotoVar(assigned.var_name, seen, out_names);
            }
        },
        .if_single => |ifs| try collectAssignedGotoVarsFromNode(ifs.stmt.*, seen, out_names),
        .if_block => |ifb| {
            try collectAssignedGotoVars(ifb.then_stmts, seen, out_names);
            try collectAssignedGotoVars(ifb.else_stmts, seen, out_names);
        },
        else => {},
    }
}

fn addAssignedGotoVar(
    name: []const u8,
    seen: *context.CaseInsensitiveStringHashMap(void),
    out_names: *std.array_list.Managed([]const u8),
) EmitError!void {
    if (seen.contains(name)) return;
    try seen.put(name, {});
    try out_names.append(name);
}
