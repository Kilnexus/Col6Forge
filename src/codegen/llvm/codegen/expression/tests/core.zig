const h = @import("harness.zig");
const std = h.std;
const ast = h.ast;
const sema = h.sema;
const codegen_diag = @import("../../../../diagnostic.zig");
const context = h.context;
const builder_mod = h.builder_mod;
const IRType = h.IRType;
const Builder = h.Builder;
const Context = h.Context;
const ValueRef = h.ValueRef;
const Expr = h.Expr;
const CallOrSubscript = h.CallOrSubscript;
const TestHarness = h.TestHarness;
const emitExpr = h.emitExpr;
const emitLValue = h.emitLValue;
const emitCharacterLenValue = h.emitCharacterLenValue;
const emitCharacterLenValueOrOne = h.emitCharacterLenValueOrOne;
const emitCharacterSymbolLenValue = h.emitCharacterSymbolLenValue;
const emitCharacterSymbolLenValueI64 = h.emitCharacterSymbolLenValueI64;
const emitBinary = h.emitBinary;
const emitAdd = h.emitAdd;
const emitSub = h.emitSub;
const emitMul = h.emitMul;
const emitCond = h.emitCond;
const emitLiteral = h.emitLiteral;
const emitConstTyped = h.emitConstTyped;
const coerce = h.coerce;
const coerceCheckedI32 = h.coerceCheckedI32;
const exprType = h.exprType;
const emitSubscriptPtr = h.emitSubscriptPtr;
const emitLinearSubscriptPtr = h.emitLinearSubscriptPtr;
const emitDimValue = h.emitDimValue;
const emitSymbolDimExtent = h.emitSymbolDimExtent;
const emitSymbolDimLower = h.emitSymbolDimLower;
const emitSymbolDimMultiplier = h.emitSymbolDimMultiplier;
const emitIndex = h.emitIndex;
const loadValue = h.loadValue;
const loadI32 = h.loadI32;
const emitCall = h.emitCall;
const emitIndirectCall = h.emitIndirectCall;
const emitArgPointer = h.emitArgPointer;
const makeTestSymbol = h.makeTestSymbol;
const makeLiteral = h.makeLiteral;
const makeIdent = h.makeIdent;

test "emitLiteral and emitConstTyped produce expected IR types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const lit_int = try emitLiteral(&harness.ctx, &builder, .{ .kind = .integer, .text = "42" });
    try testing.expectEqual(IRType.i32, lit_int.ty);
    try testing.expectEqualStrings("42", lit_int.name);

    const lit_real = try emitLiteral(&harness.ctx, &builder, .{ .kind = .real, .text = "1.0D0" });
    try testing.expectEqual(IRType.f64, lit_real.ty);
    try testing.expectEqualStrings("1.0e0", lit_real.name);

    const lit_real_wp = try emitLiteral(&harness.ctx, &builder, .{ .kind = .real, .text = "1.0_wp" });
    try testing.expectEqual(IRType.f64, lit_real_wp.ty);
    try testing.expectEqualStrings("1.0", lit_real_wp.name);

    const lit_logical_true = try emitLiteral(&harness.ctx, &builder, .{ .kind = .logical, .text = "1_TF" });
    try testing.expectEqual(IRType.i1, lit_logical_true.ty);
    try testing.expectEqualStrings("1", lit_logical_true.name);

    const lit_logical_false = try emitLiteral(&harness.ctx, &builder, .{ .kind = .logical, .text = "0_8" });
    try testing.expectEqual(IRType.i1, lit_logical_false.ty);
    try testing.expectEqualStrings("0", lit_logical_false.name);

    const const_val = emitConstTyped(&harness.ctx, &builder, .{ .integer = 7 }, .real);
    try testing.expectEqual(IRType.f32, const_val.ty);
}

test "emitExpr loads identifiers and emitLValue resolves pointers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const ident = try makeIdent(harness.arena.allocator(), "A");
    const ptr = try emitLValue(&harness.ctx, &builder, ident);
    try testing.expectEqual(IRType.ptr, ptr.ty);

    const value = try emitExpr(&harness.ctx, &builder, ident);
    try testing.expectEqual(IRType.i32, value.ty);
    try testing.expectEqualStrings("%t0", value.name);
}

test "emitBinary and emitAdd/Sub/Mul emit arithmetic ops" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const lhs = ValueRef{ .name = "1", .ty = .i32, .is_ptr = false };
    const rhs = ValueRef{ .name = "2", .ty = .i32, .is_ptr = false };
    const bin = try emitBinary(&harness.ctx, &builder, .add, lhs, rhs);
    try testing.expectEqual(IRType.i32, bin.ty);

    const sum = try emitAdd(&harness.ctx, &builder, lhs, rhs);
    try testing.expectEqual(IRType.i32, sum.ty);
    const diff = try emitSub(&harness.ctx, &builder, lhs, rhs);
    try testing.expectEqual(IRType.i32, diff.ty);
    const prod = try emitMul(&harness.ctx, &builder, lhs, rhs);
    try testing.expectEqual(IRType.i32, prod.ty);
}

test "emitBinary floating ne uses unordered comparison" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const lhs = ValueRef{ .name = "1.0", .ty = .f32, .is_ptr = false };
    const rhs = ValueRef{ .name = "2.0", .ty = .f32, .is_ptr = false };
    const cmp = try emitBinary(&harness.ctx, &builder, .ne, lhs, rhs);
    try testing.expectEqual(IRType.i1, cmp.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "fcmp une float") != null);
}

test "emitExpr prefers component subscripting over type-bound call when component exists" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dim_two = try makeLiteral(a, .integer, "2");
    const symbols = try a.alloc(sema.Symbol, 1);
    symbols[0] = makeTestSymbol("F", sema.TypeSpec.fromDerived("fld"), &.{}, .variable, .local);

    const sem_unit = sema.SemanticUnit{
        .name = "UNIT",
        .kind = .subroutine,
        .symbols = symbols,
        .implicit_rules = try a.alloc(sema.ImplicitRule, 0),
        .resolved_refs = try a.alloc(sema.ResolvedRef, 0),
    };
    const unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "UNIT",
        .args = &[_][]const u8{},
        .decls = try a.alloc(ast.Decl, 0),
        .stmts = try a.alloc(ast.Stmt, 0),
    };

    var decls = std.StringHashMap(context.IRDecl).init(a);
    defer decls.deinit();
    var defined = std.StringHashMap(void).init(a);
    defer defined.deinit();
    var formats = std.StringHashMap(context.FormatInfo).init(a);
    defer formats.deinit();
    var inline_formats = std.AutoHashMap(usize, context.FormatInfo).init(a);
    defer inline_formats.deinit();
    var string_pool = context.StringPool.init(a);
    defer string_pool.deinit();
    var intrinsic_wrappers = std.StringHashMap(context.IntrinsicWrapperKind).init(a);
    defer intrinsic_wrappers.deinit();
    var known_procedure_sigs = context.CaseInsensitiveStringHashMap(ast.sema.KnownProcedureSig).initContext(a, .{});
    defer known_procedure_sigs.deinit();
    var diag_bag = codegen_diag.Bag.init(a);
    defer diag_bag.deinit();

    var ctx = try Context.init(a, "test.f", unit, &sem_unit, &decls, &defined, &formats, &inline_formats, &string_pool, &intrinsic_wrappers, &known_procedure_sigs, .{}, &diag_bag);
    defer ctx.deinit();

    try ctx.locals.put("F", .{ .name = "%fslot", .ty = .ptr, .is_ptr = true });
    try ctx.derived_type_layouts.put("fld", .{
        .name = "fld",
        .parent_name = null,
        .components = &.{.{
            .name = "size",
            .type_spec = sema.TypeSpec.fromResolvedKind(.integer, .integer, null),
            .dims = &.{dim_two},
            .pointer = false,
            .allocatable = false,
            .offset = 0,
            .elem_size = 4,
            .size = 8,
            .alignment = 4,
        }},
        .size = 8,
        .alignment = 4,
    });

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const base = try makeIdent(a, "F");
    const idx = try makeLiteral(a, .integer, "1");
    const expr_node = try a.create(Expr);
    expr_node.* = .{ .component = .{
        .base = base,
        .name = "size",
        .args = &.{idx},
        .has_parens = true,
    } };

    const value = try emitExpr(&ctx, &builder, expr_node);
    try testing.expectEqual(IRType.i32, value.ty);
}

test "emitExpr loads bare procedure component pointer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const symbols = try a.alloc(sema.Symbol, 1);
    symbols[0] = makeTestSymbol("OBJ", sema.TypeSpec.fromDerived("t"), &.{}, .variable, .local);

    const sem_unit = sema.SemanticUnit{
        .name = "UNIT",
        .kind = .subroutine,
        .symbols = symbols,
        .implicit_rules = try a.alloc(sema.ImplicitRule, 0),
        .resolved_refs = try a.alloc(sema.ResolvedRef, 0),
    };
    const unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "UNIT",
        .args = &[_][]const u8{},
        .decls = try a.alloc(ast.Decl, 0),
        .stmts = try a.alloc(ast.Stmt, 0),
    };

    var decls = std.StringHashMap(context.IRDecl).init(a);
    defer decls.deinit();
    var defined = std.StringHashMap(void).init(a);
    defer defined.deinit();
    var formats = std.StringHashMap(context.FormatInfo).init(a);
    defer formats.deinit();
    var inline_formats = std.AutoHashMap(usize, context.FormatInfo).init(a);
    defer inline_formats.deinit();
    var string_pool = context.StringPool.init(a);
    defer string_pool.deinit();
    var intrinsic_wrappers = std.StringHashMap(context.IntrinsicWrapperKind).init(a);
    defer intrinsic_wrappers.deinit();
    var known_procedure_sigs = context.CaseInsensitiveStringHashMap(ast.sema.KnownProcedureSig).initContext(a, .{});
    defer known_procedure_sigs.deinit();
    var diag_bag = codegen_diag.Bag.init(a);
    defer diag_bag.deinit();

    var ctx = try Context.init(a, "test.f", unit, &sem_unit, &decls, &defined, &formats, &inline_formats, &string_pool, &intrinsic_wrappers, &known_procedure_sigs, .{}, &diag_bag);
    defer ctx.deinit();

    try ctx.locals.put("OBJ", .{ .name = "%objslot", .ty = .ptr, .is_ptr = true });
    try ctx.derived_type_layouts.put("t", .{
        .name = "t",
        .parent_name = null,
        .components = &.{.{
            .name = "ppc",
            .type_spec = sema.TypeSpec.fromResolvedKind(.integer, .integer, null),
            .dims = &.{},
            .pointer = true,
            .allocatable = false,
            .procedure = true,
            .procedure_sig = .{
                .name = "ifc",
                .kind = .function,
                .arg_count = 0,
                .args = &.{},
                .result_type_spec = sema.TypeSpec.fromResolvedKind(.integer, .integer, null),
            },
            .procedure_nopass = true,
            .offset = 0,
            .elem_size = @sizeOf(usize),
            .size = @sizeOf(usize),
            .alignment = @alignOf(usize),
        }},
        .size = @sizeOf(usize),
        .alignment = @alignOf(usize),
    });

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const base = try makeIdent(a, "OBJ");
    const expr_node = try a.create(Expr);
    expr_node.* = .{ .component = .{
        .base = base,
        .name = "ppc",
        .args = &.{},
        .has_parens = false,
    } };

    const value = try emitExpr(&ctx, &builder, expr_node);
    try testing.expectEqual(IRType.ptr, value.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "load ptr") != null);
}

test "emitExpr calls procedure component indirectly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const symbols = try a.alloc(sema.Symbol, 1);
    symbols[0] = makeTestSymbol("OBJ", sema.TypeSpec.fromDerived("t"), &.{}, .variable, .local);

    const sem_unit = sema.SemanticUnit{
        .name = "UNIT",
        .kind = .subroutine,
        .symbols = symbols,
        .implicit_rules = try a.alloc(sema.ImplicitRule, 0),
        .resolved_refs = try a.alloc(sema.ResolvedRef, 0),
    };
    const unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "UNIT",
        .args = &[_][]const u8{},
        .decls = try a.alloc(ast.Decl, 0),
        .stmts = try a.alloc(ast.Stmt, 0),
    };

    var decls = std.StringHashMap(context.IRDecl).init(a);
    defer decls.deinit();
    var defined = std.StringHashMap(void).init(a);
    defer defined.deinit();
    var formats = std.StringHashMap(context.FormatInfo).init(a);
    defer formats.deinit();
    var inline_formats = std.AutoHashMap(usize, context.FormatInfo).init(a);
    defer inline_formats.deinit();
    var string_pool = context.StringPool.init(a);
    defer string_pool.deinit();
    var intrinsic_wrappers = std.StringHashMap(context.IntrinsicWrapperKind).init(a);
    defer intrinsic_wrappers.deinit();
    var known_procedure_sigs = context.CaseInsensitiveStringHashMap(ast.sema.KnownProcedureSig).initContext(a, .{});
    defer known_procedure_sigs.deinit();
    var diag_bag = codegen_diag.Bag.init(a);
    defer diag_bag.deinit();

    var ctx = try Context.init(a, "test.f", unit, &sem_unit, &decls, &defined, &formats, &inline_formats, &string_pool, &intrinsic_wrappers, &known_procedure_sigs, .{}, &diag_bag);
    defer ctx.deinit();

    try ctx.locals.put("OBJ", .{ .name = "%objslot", .ty = .ptr, .is_ptr = true });
    try ctx.derived_type_layouts.put("t", .{
        .name = "t",
        .parent_name = null,
        .components = &.{.{
            .name = "ppc",
            .type_spec = sema.TypeSpec.fromResolvedKind(.integer, .integer, null),
            .dims = &.{},
            .pointer = true,
            .allocatable = false,
            .procedure = true,
            .procedure_sig = .{
                .name = "ifc",
                .kind = .function,
                .arg_count = 0,
                .args = &.{},
                .result_type_spec = sema.TypeSpec.fromResolvedKind(.integer, .integer, null),
            },
            .procedure_nopass = true,
            .offset = 0,
            .elem_size = @sizeOf(usize),
            .size = @sizeOf(usize),
            .alignment = @alignOf(usize),
        }},
        .size = @sizeOf(usize),
        .alignment = @alignOf(usize),
    });

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const base = try makeIdent(a, "OBJ");
    const expr_node = try a.create(Expr);
    expr_node.* = .{ .component = .{
        .base = base,
        .name = "ppc",
        .args = &.{},
        .has_parens = true,
    } };

    const value = try emitExpr(&ctx, &builder, expr_node);
    try testing.expectEqual(IRType.i32, value.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "call i32 %") != null);
}

test "emitBinary i64 arithmetic and comparisons use integer ops" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const lhs = ValueRef{ .name = "7", .ty = .i64, .is_ptr = false };
    const rhs = ValueRef{ .name = "3", .ty = .i64, .is_ptr = false };
    const sum = try emitBinary(&harness.ctx, &builder, .add, lhs, rhs);
    try testing.expectEqual(IRType.i64, sum.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "add i64") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "fadd i64") == null);

    const cmp = try emitBinary(&harness.ctx, &builder, .lt, lhs, rhs);
    try testing.expectEqual(IRType.i1, cmp.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "icmp slt i64") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "fcmp olt i64") == null);
}

test "emitBinary rejects mixed logical and numeric comparisons" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const logical = ValueRef{ .name = "1", .ty = .i1, .is_ptr = false };
    const integer = ValueRef{ .name = "1", .ty = .i32, .is_ptr = false };
    try testing.expectError(error.UnsupportedLogicalOp, emitBinary(&harness.ctx, &builder, .eq, logical, integer));
}

test "emitBinary real power with integer exponent uses llvm powi intrinsic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const lhs = ValueRef{ .name = "2.0", .ty = .f32, .is_ptr = false };
    const rhs = ValueRef{ .name = "2", .ty = .i32, .is_ptr = false };
    const pow = try emitBinary(&harness.ctx, &builder, .power, lhs, rhs);
    try testing.expectEqual(IRType.f32, pow.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "call float @llvm.powi.f32") != null);
}

test "coerceCheckedI32 traps on overflowing i64" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const value = ValueRef{ .name = "%wide", .ty = .i64, .is_ptr = false };
    const narrowed = try coerceCheckedI32(&harness.ctx, &builder, value);
    try testing.expectEqual(IRType.i32, narrowed.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "@llvm.trap") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "trunc i64 %wide to i32") != null);
}

test "emitBinary real power with i64 exponent narrows through checked trap path" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const lhs = ValueRef{ .name = "2.0", .ty = .f32, .is_ptr = false };
    const rhs = ValueRef{ .name = "%exp", .ty = .i64, .is_ptr = false };
    const pow = try emitBinary(&harness.ctx, &builder, .power, lhs, rhs);
    try testing.expectEqual(IRType.f32, pow.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "call float @llvm.powi.f32") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "@llvm.trap") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "trunc i64 %exp to i32") != null);
}

test "emitBinary integer power supports i64 and rejects negative constants" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const lhs = ValueRef{ .name = "2", .ty = .i64, .is_ptr = false };
    const rhs = ValueRef{ .name = "5", .ty = .i64, .is_ptr = false };
    const pow = try emitBinary(&harness.ctx, &builder, .power, lhs, rhs);
    try testing.expectEqual(IRType.i64, pow.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "mul i64") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "llvm.pow") == null);

    const neg_rhs = ValueRef{ .name = "-1", .ty = .i64, .is_ptr = false };
    try testing.expectError(error.PowerUnsupported, emitBinary(&harness.ctx, &builder, .power, lhs, neg_rhs));
}

test "emitBinary integer power with dynamic exponent calls runtime helper" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();
    var builder = builder_mod.Builder(@TypeOf(writer)).init(writer);

    const lhs = ValueRef{ .name = "2", .ty = .i64, .is_ptr = false };
    const rhs = ValueRef{ .name = "%exp", .ty = .i64, .is_ptr = false };
    const pow = try emitBinary(&harness.ctx, &builder, .power, lhs, rhs);
    try testing.expectEqual(IRType.i64, pow.ty);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "call i64 @col6forge_ipow_i64") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "ipow_header") == null);
}
