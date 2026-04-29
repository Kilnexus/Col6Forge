const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const decl_queries = @import("../../ast/decl_queries.zig");
const case_insensitive = @import("../../common/case_insensitive.zig");
const catalog = @import("../../common/error_catalog.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");
const constants = @import("resolve_const.zig");
const decls = @import("resolve_decls.zig");
const common_entity_queries = @import("common_entity_queries.zig");
const select_type_char_clause = @import("select_type_char_clause.zig");
const expressions = @import("resolve_expr.zig");
const symbols_mod = @import("resolve_symbols.zig");
const procedure_interfaces = @import("check_statements/procedure_interfaces.zig");

const ResolveError = expressions.ResolveError;

pub fn preinstallUseImports(self: *context.Context) ResolveError!void {
    if (self.use_imports_preinstalled) return;
    for (self.unit.stmts) |stmt| {
        if (stmt.node != .use_stmt) continue;
        try installUseImports(self, stmt.node.use_stmt);
    }
    self.use_imports_preinstalled = true;
}

pub fn resolveStmt(self: *context.Context, stmt: ast.Stmt) ResolveError!void {
    const prev_stmt = self.current_stmt;
    const prev_source = self.current_source;
    self.setCurrentStmt(stmt);
    defer self.current_stmt = prev_stmt;
    defer self.current_source = prev_source;
    return resolveStmtNode(self, stmt.node);
}

pub fn resolveStmtNode(self: *context.Context, node: ast.StmtNode) ResolveError!void {
    switch (node) {
        .assignment => |assign| {
            try expressions.resolveExpr(self, assign.target);
            try expressions.resolveExpr(self, assign.value);
        },
        .pointer_assignment => |assign| {
            if (!pointerAssignmentTargetUsesAbstractInterfaceName(self, assign.target)) {
                try expressions.resolveExpr(self, assign.target);
            }
            try expressions.resolveExpr(self, assign.value);
        },
        .nullify => |nullify| {
            for (nullify.items) |item| {
                try expressions.resolveExpr(self, item);
            }
        },
        .associate_block => |associate| {
            try resolveAssociateBlock(self, associate);
        },
        .select_type_block => |select_type| {
            try resolveSelectTypeBlock(self, select_type);
        },
        .orphan_select_type_clause => {},
        .assign_label => |assign| {
            _ = try symbols_mod.ensureSymbol(self, assign.target);
        },
        .use_stmt => |use_stmt| {
            if (!self.use_imports_preinstalled) {
                try installUseImports(self, use_stmt);
            }
        },
        .call => |call| {
            self.setCurrentSource(if (call.source.line != 0) call.source else null);
            if (call.binding_base) |base| {
                try expressions.resolveExpr(self, base);
                for (call.args) |arg| {
                    switch (arg) {
                        .expr => |actual| try expressions.resolveExpr(self, actual.value),
                        .alt_return => {},
                    }
                }
                return;
            }
            if (common_entity_queries.currentUnitDeclaresCommonEntity(self.unit, call.name)) {
                const source = if (call.source.line != 0) call.source else ast.SourceRef{};
                self.setDiagnosticStructured(
                    if (source.line == 0) 1 else source.line,
                    if (source.column == 0) 1 else source.column,
                    catalog.semantic.duplicate_declaration.code,
                    "PROCEDURE attribute conflicts with COMMON attribute",
                    source.text,
                    "invalid procedure reference here",
                    &.{.{ .text = "A COMMON block entity cannot be referenced as a procedure." }},
                    &.{.{ .text = "Rename the COMMON entity or stop using it as a procedure target." }},
                    &.{},
                );
                return error.DuplicateDeclaration;
            }
            const idx = try symbols_mod.ensureSymbol(self, call.name);
            if (shouldMarkCallTargetAsExternal(self.symbols.items[idx])) {
                self.symbols.items[idx].is_external = true;
            }
            for (call.args) |arg| {
                switch (arg) {
                    .expr => |actual| try expressions.resolveExpr(self, actual.value),
                    .alt_return => {},
                }
            }
        },
        .write => |write| {
            try expressions.resolveExpr(self, write.unit);
            try resolveFormatSpecExpr(self, write.format);
            if (write.rec) |rec| {
                try expressions.resolveExpr(self, rec);
            }
            for (write.args) |arg| {
                try expressions.resolveExpr(self, arg);
            }
        },
        .read => |read| {
            try expressions.resolveExpr(self, read.unit);
            try resolveFormatSpecExpr(self, read.format);
            if (read.rec) |rec| {
                try expressions.resolveExpr(self, rec);
            }
            for (read.args) |arg| {
                try expressions.resolveExpr(self, arg);
            }
        },
        .rewind => |rewind| {
            try expressions.resolveExpr(self, rewind.unit);
        },
        .backspace => |backspace| {
            try expressions.resolveExpr(self, backspace.unit);
        },
        .endfile => |endfile| {
            try expressions.resolveExpr(self, endfile.unit);
        },
        .open => |open_stmt| {
            try expressions.resolveExpr(self, open_stmt.unit);
            if (open_stmt.recl) |recl| {
                try expressions.resolveExpr(self, recl);
            }
            if (open_stmt.file) |file_expr| {
                try expressions.resolveExpr(self, file_expr);
            }
            if (open_stmt.access) |access| {
                try expressions.resolveExpr(self, access);
            }
            if (open_stmt.form) |form| {
                try expressions.resolveExpr(self, form);
            }
            if (open_stmt.blank) |blank| {
                try expressions.resolveExpr(self, blank);
            }
            if (open_stmt.status) |status| {
                try expressions.resolveExpr(self, status);
            }
        },
        .inquire => |inq| {
            for (inq.controls) |ctrl| {
                self.setCurrentSource(if (ctrl.source.line != 0) ctrl.source else self.sourceForExpr(ctrl.value));
                try expressions.resolveExpr(self, ctrl.value);
            }
        },
        .close => |cls| {
            for (cls.controls) |ctrl| {
                self.setCurrentSource(if (ctrl.source.line != 0) ctrl.source else self.sourceForExpr(ctrl.value));
                try expressions.resolveExpr(self, ctrl.value);
            }
        },
        .allocate => |allocate| {
            if (allocate.type_spec) |type_spec| {
                if (type_spec.kind_selector) |kind_selector| {
                    try expressions.resolveExpr(self, kind_selector);
                }
                if (type_spec.char_len) |char_len| {
                    try expressions.resolveExpr(self, char_len);
                }
            }
            for (allocate.items) |item| {
                self.setCurrentSource(if (item.source.line != 0) item.source else null);
                try expressions.resolveExpr(self, item.target);
                for (item.dims) |dim| {
                    try expressions.resolveExpr(self, dim);
                }
            }
            for (allocate.options) |option| {
                self.setCurrentSource(if (option.source.line != 0) option.source else self.sourceForExpr(option.value));
                try expressions.resolveExpr(self, option.value);
            }
        },
        .deallocate => |deallocate| {
            for (deallocate.items) |item| {
                self.setCurrentSource(if (item.source.line != 0) item.source else self.sourceForExpr(item.target));
                try expressions.resolveExpr(self, item.target);
            }
            for (deallocate.options) |option| {
                self.setCurrentSource(if (option.source.line != 0) option.source else self.sourceForExpr(option.value));
                try expressions.resolveExpr(self, option.value);
            }
        },
        .data => |data| {
            for (data.inits) |data_init| {
                try expressions.resolveExpr(self, data_init.target);
                try expressions.resolveExpr(self, data_init.value);
            }
        },
        .format => {},
        .arith_if => |arith| {
            try expressions.resolveExpr(self, arith.condition);
        },
        .pause => {},
        .stop => {},
        .do_loop => |loop| {
            _ = try symbols_mod.ensureSymbol(self, loop.var_name);
            try expressions.resolveExpr(self, loop.start);
            try expressions.resolveExpr(self, loop.end);
            if (loop.step) |step| try expressions.resolveExpr(self, step);
        },
        .do_while => |loop| {
            try expressions.resolveExpr(self, loop.condition);
        },
        .do_infinite => {},
        .goto => {},
        .computed_goto => |gt| {
            try expressions.resolveExpr(self, gt.selector);
        },
        .assigned_goto => |gt| {
            _ = try symbols_mod.ensureSymbol(self, gt.var_name);
        },
        .if_single => |ifs| {
            try expressions.resolveExpr(self, ifs.condition);
            try resolveStmtNode(self, ifs.stmt.*);
        },
        .if_block => |ifb| {
            try expressions.resolveExpr(self, ifb.condition);
            for (ifb.then_stmts) |inner| try resolveStmt(self, inner);
            for (ifb.else_stmts) |inner| try resolveStmt(self, inner);
        },
        .where_stmt => |where| {
            try expressions.resolveExpr(self, where.mask);
            try expressions.resolveExpr(self, where.target);
            try expressions.resolveExpr(self, where.value);
        },
        .ret => |ret| {
            if (ret.value) |value| {
                try expressions.resolveExpr(self, value);
            }
        },
        .cont => {},
        .entry => |entry| {
            const entry_idx = try symbols_mod.ensureSymbol(self, entry.name);
            self.symbols.items[entry_idx].kind = switch (self.unit.kind) {
                .module => .subroutine,
                .subroutine => .subroutine,
                .function => .function,
                else => .subroutine,
            };
            for (entry.args) |arg_name| {
                const arg_idx = try symbols_mod.ensureSymbol(self, arg_name);
                self.symbols.items[arg_idx].storage = .dummy;
            }
        },
    }
}

fn pointerAssignmentTargetUsesAbstractInterfaceName(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| procedure_interfaces.abstractInterfaceNameBlocksVariableUse(self, name),
        else => false,
    };
}

fn resolveFormatSpecExpr(self: *context.Context, format_spec: ast.FormatSpec) ResolveError!void {
    switch (format_spec) {
        .expr => |fmt_expr| try expressions.resolveExpr(self, fmt_expr),
        else => {},
    }
}

fn resolveAssociateBlock(self: *context.Context, associate: ast.AssociateBlock) ResolveError!void {
    var first_err: ?anyerror = null;
    const binding_ok = try self.arena.alloc(bool, associate.bindings.len);
    for (associate.bindings, 0..) |binding, idx| {
        var ok = true;
        expressions.resolveExpr(self, binding.selector) catch |err| {
            ok = false;
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            self.recordSemanticError(err);
        };
        binding_ok[idx] = ok;
    }
    _ = try self.pushScope(.block);
    defer self.popScope();
    for (associate.bindings, 0..) |binding, idx| {
        const spec = expressions.exprTypeSpec(self, binding.selector) catch |err| blk: {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            self.recordSemanticError(err);
            break :blk symbols.TypeSpec.fromResolvedKind(.integer, .integer, null);
        };
        const rank = expressions.exprRank(self, binding.selector);
        _ = symbols_mod.installAliasSymbol(
            self,
            binding.name,
            spec,
            if (rank >= syntacticSectionRank(binding.selector)) rank else syntacticSectionRank(binding.selector),
            binding_ok[idx] and associateSelectorMayBeVariable(binding.selector),
            symbols_mod.aliasAttrsForSelector(self, binding.selector),
        ) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            self.recordSemanticError(err);
            continue;
        };
    }
    for (associate.stmts) |inner| {
        resolveStmt(self, inner) catch |err| {
            if (!self.usesExplicitDiagnosticBag()) return err;
            if (first_err == null) first_err = err;
            self.recordSemanticError(err);
        };
    }
    if (first_err) |err| return err;
}

fn associateSelectorMayBeVariable(selector: *ast.Expr) bool {
    return switch (selector.*) {
        .identifier, .component, .substring, .call_or_subscript => true,
        else => false,
    };
}

fn syntacticSectionRank(expr: *ast.Expr) usize {
    return switch (expr.*) {
        .component => |comp| syntacticSectionRank(comp.base) + sectionRankFromArgs(comp.args),
        .call_or_subscript => |call| sectionRankFromArgs(call.args),
        else => 0,
    };
}

fn sectionRankFromArgs(args: []const *ast.Expr) usize {
    var rank: usize = 0;
    for (args) |arg| {
        if (arg.* == .dim_range) rank += 1;
    }
    return rank;
}

fn resolveSelectTypeBlock(self: *context.Context, select_type: ast.SelectTypeBlock) ResolveError!void {
    try expressions.resolveExpr(self, select_type.selector);
    const selector_spec = try expressions.exprTypeSpec(self, select_type.selector);
    const selector_rank = expressions.exprRank(self, select_type.selector);
    for (select_type.leading_stmts) |inner| try resolveStmt(self, inner);
    for (select_type.clauses) |clause| {
        {
            _ = try self.pushScope(.block);
            defer self.popScope();
            if (selectTypeAliasName(select_type)) |alias_name| {
                const alias_spec = selectTypeClauseAliasSpec(self, selector_spec, clause) catch |err| blk: {
                    if (!self.usesExplicitDiagnosticBag()) return err;
                    break :blk selector_spec;
                };
                _ = try symbols_mod.installAliasSymbol(
                    self,
                    alias_name,
                    alias_spec,
                    selector_rank,
                    true,
                    symbols_mod.aliasAttrsForSelector(self, select_type.selector),
                );
            }
            for (clause.stmts) |inner| try resolveStmt(self, inner);
        }
    }
}

fn selectTypeAliasName(select_type: ast.SelectTypeBlock) ?[]const u8 {
    if (select_type.associate_name) |name| return name;
    return switch (select_type.selector.*) {
        .identifier => |name| name,
        else => null,
    };
}

fn selectTypeClauseAliasSpec(
    self: *context.Context,
    selector_spec: symbols.TypeSpec,
    clause: ast.SelectTypeClause,
) ResolveError!symbols.TypeSpec {
    switch (clause.kind) {
        .class_default => return selector_spec,
        .type_is => return try selectTypeClauseResolvedSpec(self, clause, false),
        .class_is => return (try selectTypeClauseResolvedSpec(self, clause, true)).withPolymorphic(true),
    }
}

fn selectTypeClauseResolvedSpec(
    self: *context.Context,
    clause: ast.SelectTypeClause,
    polymorphic: bool,
) ResolveError!symbols.TypeSpec {
    const kind = clause.type_kind orelse return error.UnexpectedTypeDecl;
    if (kind == .derived) {
        const name = clause.derived_type_name orelse return error.UnexpectedTypeDecl;
        if (!symbols_mod.hasDerivedType(self, name)) return error.UnexpectedTypeDecl;
        return symbols.TypeSpec.fromDerived(name).withPolymorphic(polymorphic);
    }
    const spec = try decls.resolvedDeclTypeSpec(
        self,
        kind,
        clause.derived_type_name,
        clause.kind_selector,
        polymorphic,
        false,
    );
    if (kind != .character) return spec;
    return try select_type_char_clause.applySelectTypeCharacterClauseLength(self, spec, clause);
}

fn installUseImports(self: *context.Context, use_stmt: ast.UseStmt) ResolveError!void {
    if (isIsoCBindingModule(use_stmt.module_name)) {
        try installIsoCBindingImports(self, use_stmt);
        if (use_stmt.has_only) return;
    }

    if (use_stmt.has_only and use_stmt.only_items.len == 0) return;

    if (!use_stmt.has_only and use_stmt.only_items.len == 0) {
        try bindKnownModuleUseImports(self, use_stmt.module_name);
        return;
    }

    const may_have_builtin_consts = isIsoFortranEnvModule(use_stmt.module_name);
    for (use_stmt.only_items) |item| {
        if (item.generic_spec) continue;
        if (useImportConflictsWithCurrentUnit(self, item.local_name)) {
            emitUseImportConflictDiagnostic(self, use_stmt, item.local_name);
            continue;
        }
        if (may_have_builtin_consts) {
            if (symbols_mod.findBuiltinModuleConstant(self, use_stmt.module_name, item.remote_name)) |builtin| {
                try bindBuiltinUseImport(self, item.local_name, builtin);
                continue;
            }
        }
        try bindKnownUseImportFromModule(self, use_stmt.module_name, item.local_name, item.remote_name);
    }
}

fn installIsoCBindingImports(self: *context.Context, use_stmt: ast.UseStmt) ResolveError!void {
    const c_ptr_local = localIsoCBindingName(use_stmt, "c_ptr");
    const c_funptr_local = localIsoCBindingName(use_stmt, "c_funptr");

    if (use_stmt.has_only) {
        for (use_stmt.only_items) |item| {
            if (item.generic_spec) continue;
            if (unitAlreadyHasImportedUseDecl(self, use_stmt.module_name, item.local_name)) continue;
            if (try bindIsoCBindingBuiltin(self, item.local_name, item.remote_name, c_ptr_local, c_funptr_local)) continue;
            try bindKnownUseImport(self, item.local_name, item.remote_name);
        }
        return;
    }

    for (isoCBindingDerivedTypeNames()) |remote_name| {
        if (isRenamedUseImport(use_stmt, remote_name)) continue;
        if (unitAlreadyHasImportedUseDecl(self, use_stmt.module_name, remote_name)) continue;
        _ = try bindIsoCBindingBuiltin(self, remote_name, remote_name, c_ptr_local, c_funptr_local);
    }
    for (isoCBindingConstantNames()) |remote_name| {
        if (isRenamedUseImport(use_stmt, remote_name)) continue;
        if (unitAlreadyHasImportedUseDecl(self, use_stmt.module_name, remote_name)) continue;
        _ = try bindIsoCBindingBuiltin(self, remote_name, remote_name, c_ptr_local, c_funptr_local);
    }
    for (use_stmt.only_items) |item| {
        if (item.generic_spec) continue;
        if (unitAlreadyHasImportedUseDecl(self, use_stmt.module_name, item.local_name)) continue;
        if (try bindIsoCBindingBuiltin(self, item.local_name, item.remote_name, c_ptr_local, c_funptr_local)) continue;
        try bindKnownUseImport(self, item.local_name, item.remote_name);
    }
}

fn bindIsoCBindingBuiltin(
    self: *context.Context,
    local_name: []const u8,
    remote_name: []const u8,
    c_ptr_local: []const u8,
    c_funptr_local: []const u8,
) ResolveError!bool {
    if (std.ascii.eqlIgnoreCase(remote_name, "c_ptr")) {
        try bindIsoCBindingDerivedType(self, local_name);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_funptr")) {
        try bindIsoCBindingDerivedType(self, local_name);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_null_ptr")) {
        try bindIsoCBindingNamedConstant(self, local_name, symbols.TypeSpec.fromDerived(c_ptr_local), try zeroHandleConstValue(self));
        return true;
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_null_funptr")) {
        try bindIsoCBindingNamedConstant(self, local_name, symbols.TypeSpec.fromDerived(c_funptr_local), try zeroHandleConstValue(self));
        return true;
    }
    if (isoCBindingBuiltinConstant(remote_name, c_ptr_local, c_funptr_local)) |builtin| {
        try bindBuiltinUseImport(self, local_name, builtin);
        return true;
    }
    return false;
}

fn bindIsoCBindingDerivedType(self: *context.Context, local_name: []const u8) ResolveError!void {
    try symbols_mod.registerDerivedType(self, .{
        .name = local_name,
        .bind_c = true,
    });
}

fn bindIsoCBindingNamedConstant(
    self: *context.Context,
    local_name: []const u8,
    type_spec: symbols.TypeSpec,
    const_value: ?symbols.ConstValue,
) ResolveError!void {
    const idx = try symbols_mod.ensureSymbol(self, local_name);
    const sym = &self.symbols.items[idx];
    sym.name = local_name;
    sym.applyTypeSpec(type_spec);
    sym.dims = &.{};
    sym.kind = .parameter;
    sym.storage = .local;
    sym.const_value = const_value;
    sym.type_explicit = true;
}

fn zeroHandleConstValue(self: *context.Context) !symbols.ConstValue {
    const bytes = try self.arena.alloc(u8, @sizeOf(usize));
    @memset(bytes, 0);
    return .{ .string = bytes };
}

fn isoCBindingBuiltinConstant(
    remote_name: []const u8,
    _: []const u8,
    _: []const u8,
) ?context.Context.BuiltinConstant {
    const integer_spec = symbols.TypeSpec.fromResolvedKind(.integer, .integer, null);
    const c_char_spec = symbols.TypeSpec.fromResolvedKind(.integer, .integer, null);
    const c_null_char_spec = symbols.TypeSpec.fromResolvedKind(.character, .character, 1).withCharacterLength(.constant, 1);

    if (std.ascii.eqlIgnoreCase(remote_name, "c_int")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 4 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_short")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 2 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_long")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_long_long")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_int8_t")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 1 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_int16_t")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 2 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_int32_t")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 4 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_int64_t")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_intmax_t")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_intptr_t")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_size_t")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_ptrdiff_t")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_signed_char")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 1 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_char")) {
        return .{ .module_name = "iso_c_binding", .type_spec = c_char_spec, .value = .{ .integer = 1 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_bool")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 1 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_float")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 4 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_double")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_long_double")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 16 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_float_complex")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 4 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_double_complex")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 8 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_long_double_complex")) {
        return .{ .module_name = "iso_c_binding", .type_spec = integer_spec, .value = .{ .integer = 16 } };
    }
    if (std.ascii.eqlIgnoreCase(remote_name, "c_null_char")) {
        return .{ .module_name = "iso_c_binding", .type_spec = c_null_char_spec, .value = .{ .string = "\x00" } };
    }
    return null;
}

fn localIsoCBindingName(use_stmt: ast.UseStmt, remote_name: []const u8) []const u8 {
    for (use_stmt.only_items) |item| {
        if (item.generic_spec) continue;
        if (std.ascii.eqlIgnoreCase(item.remote_name, remote_name)) return item.local_name;
    }
    return remote_name;
}

fn isRenamedUseImport(use_stmt: ast.UseStmt, remote_name: []const u8) bool {
    for (use_stmt.only_items) |item| {
        if (item.generic_spec) continue;
        if (!std.ascii.eqlIgnoreCase(item.remote_name, remote_name)) continue;
        return !std.ascii.eqlIgnoreCase(item.local_name, remote_name);
    }
    return false;
}

fn isoCBindingDerivedTypeNames() []const []const u8 {
    return &.{ "c_ptr", "c_funptr" };
}

fn isoCBindingConstantNames() []const []const u8 {
    return &.{
        "c_int",
        "c_short",
        "c_long",
        "c_long_long",
        "c_int8_t",
        "c_int16_t",
        "c_int32_t",
        "c_int64_t",
        "c_intmax_t",
        "c_intptr_t",
        "c_size_t",
        "c_ptrdiff_t",
        "c_signed_char",
        "c_char",
        "c_bool",
        "c_float",
        "c_double",
        "c_long_double",
        "c_float_complex",
        "c_double_complex",
        "c_long_double_complex",
        "c_null_char",
        "c_null_ptr",
        "c_null_funptr",
    };
}

fn shouldMarkCallTargetAsExternal(sym: symbols.Symbol) bool {
    if (sym.is_external or sym.is_intrinsic) return false;
    if (sym.is_pointer) return false;
    if (sym.storage == .dummy) return false;
    if (sym.storage == .common) return false;
    if (sym.kind == .function or sym.kind == .subroutine) return false;
    return true;
}

fn unitAlreadyHasImportedUseDecl(self: *context.Context, module_name: []const u8, local_name: []const u8) bool {
    for (self.unit.decls, 0..) |decl_node, idx| {
        const decl_source = if (idx < self.unit.decl_sources.len) self.unit.decl_sources[idx] else ast.DeclSource{};
        const owner_name = decl_source.owner_name orelse continue;
        if (!std.ascii.eqlIgnoreCase(owner_name, module_name)) continue;
        const exported_name = decl_queries.exportedName(decl_node) orelse continue;
        if (std.ascii.eqlIgnoreCase(exported_name, local_name)) return true;
    }
    return false;
}

fn bindKnownUseImport(self: *context.Context, local_name: []const u8, remote_name: []const u8) ResolveError!void {
    if (symbols_mod.lookupKnownProcedureSig(self, remote_name)) |sig| {
        const idx = try symbols_mod.ensureSymbol(self, local_name);
        const sym = &self.symbols.items[idx];
        sym.name = local_name;
        sym.is_external = true;
        sym.is_pointer = sig.is_pointer;
        sym.kind = switch (sig.kind) {
            .module => sym.kind,
            .function => .function,
            .subroutine => .subroutine,
            else => sym.kind,
        };
        if (sig.kind == .function) {
            if (symbols_mod.lookupKnownFunctionResolvedSpec(self, remote_name)) |type_spec| {
                sym.applyTypeSpec(type_spec);
                sym.type_explicit = true;
            }
        }
        return;
    }

    if (symbols_mod.lookupKnownFunctionResolvedSpec(self, remote_name)) |type_spec| {
        const idx = try symbols_mod.ensureSymbol(self, local_name);
        const sym = &self.symbols.items[idx];
        sym.name = local_name;
        sym.is_external = true;
        sym.kind = .function;
        sym.applyTypeSpec(type_spec);
        sym.type_explicit = true;
        return;
    }
}

fn bindKnownUseImportFromModule(
    self: *context.Context,
    module_name: []const u8,
    local_name: []const u8,
    remote_name: []const u8,
) ResolveError!void {
    if (unitAlreadyHasImportedUseDecl(self, module_name, local_name)) return;

    if (symbols_mod.lookupKnownProcedureSigInOwner(self, module_name, remote_name)) |sig| {
        const idx = try symbols_mod.ensureSymbol(self, local_name);
        const sym = &self.symbols.items[idx];
        sym.name = local_name;
        sym.is_external = true;
        sym.is_pointer = sig.is_pointer;
        sym.kind = switch (sig.kind) {
            .module => sym.kind,
            .function => .function,
            .subroutine => .subroutine,
            else => sym.kind,
        };
        if (sig.kind == .function) {
            if (sig.result_type_spec) |type_spec| {
                sym.applyTypeSpec(type_spec);
                sym.type_explicit = true;
            } else if (symbols_mod.lookupKnownFunctionTypeSpecInOwner(self, module_name, remote_name)) |type_spec| {
                sym.applyTypeSpec(type_spec);
                sym.type_explicit = true;
            }
        }
        return;
    }

    if (symbols_mod.lookupKnownFunctionTypeSpecInOwner(self, module_name, remote_name)) |type_spec| {
        const idx = try symbols_mod.ensureSymbol(self, local_name);
        const sym = &self.symbols.items[idx];
        sym.name = local_name;
        sym.is_external = true;
        sym.kind = .function;
        sym.applyTypeSpec(type_spec);
        sym.type_explicit = true;
        return;
    }

    if (!isIsoCBindingModule(module_name)) {
        if (try bindKnownDataUseImportFromModule(self, module_name, local_name, remote_name)) return;
    }

    try bindKnownUseImport(self, local_name, remote_name);
}

fn bindKnownDataUseImportFromModule(
    self: *context.Context,
    module_name: []const u8,
    local_name: []const u8,
    remote_name: []const u8,
) ResolveError!bool {
    for (self.unit.decls, 0..) |decl_node, decl_idx| {
        const decl_source = if (decl_idx < self.unit.decl_sources.len) self.unit.decl_sources[decl_idx] else ast.DeclSource{};
        const owner_name = decl_source.owner_name orelse continue;
        if (!std.ascii.eqlIgnoreCase(owner_name, module_name)) continue;
        switch (decl_node) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, remote_name)) continue;
                    const prev_decl_idx = self.current_decl_index;
                    const prev_decl_source = self.current_decl_source;
                    self.setCurrentDeclIndex(decl_idx);
                    self.setCurrentDeclSource(decl_source);
                    defer self.setCurrentDeclIndex(prev_decl_idx);
                    defer self.setCurrentDeclSource(prev_decl_source);

                    var local_item = item;
                    local_item.name = local_name;
                    const resolved_type = try decls.resolvedDeclTypeSpec(
                        self,
                        type_decl.type_kind,
                        type_decl.derived_type_name,
                        type_decl.kind_selector,
                        type_decl.polymorphic,
                        type_decl.assumed_type,
                    );
                    try decls.applyDeclarator(
                        self,
                        resolved_type,
                        local_item,
                        .local,
                        true,
                        type_decl.allocatable,
                        type_decl.pointer,
                        type_decl.target,
                        type_decl.contiguous,
                        false,
                    );
                    if (symbols_mod.findSymbolIndex(self, local_name)) |idx| {
                        self.symbols.items[idx].is_host_associated = true;
                        self.symbols.items[idx].host_owner_name = owner_name;
                    }
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn bindKnownModuleUseImports(self: *context.Context, module_name: []const u8) ResolveError!void {
    var seen = std.StringHashMap(void).init(self.arena);
    for (self.unit.decls, 0..) |decl_node, idx| {
        const decl_source = if (idx < self.unit.decl_sources.len) self.unit.decl_sources[idx] else ast.DeclSource{};
        const owner_name = decl_source.owner_name orelse continue;
        if (!std.ascii.eqlIgnoreCase(owner_name, module_name)) continue;
        const exported_name = decl_queries.exportedName(decl_node) orelse continue;
        const lowered = try case_insensitive.lowerDup(self.arena, exported_name);
        if (seen.contains(lowered)) continue;
        try seen.put(lowered, {});
        try bindKnownUseImportFromModule(self, module_name, exported_name, exported_name);
    }

    var proc_it = self.known_procedure_sigs.iterator();
    while (proc_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const sep = std.mem.lastIndexOf(u8, key, "::") orelse continue;
        if (!std.ascii.eqlIgnoreCase(key[0..sep], module_name)) continue;
        const remote_name = key[sep + 2 ..];
        const lowered = try case_insensitive.lowerDup(self.arena, remote_name);
        if (seen.contains(lowered)) continue;
        try seen.put(lowered, {});
        try bindKnownUseImportFromModule(self, module_name, remote_name, remote_name);
    }

    var fn_it = self.known_function_type_specs.iterator();
    while (fn_it.next()) |entry| {
        const key = entry.key_ptr.*;
        const sep = std.mem.lastIndexOf(u8, key, "::") orelse continue;
        if (!std.ascii.eqlIgnoreCase(key[0..sep], module_name)) continue;
        const remote_name = key[sep + 2 ..];
        const lowered = try case_insensitive.lowerDup(self.arena, remote_name);
        if (seen.contains(lowered)) continue;
        try seen.put(lowered, {});
        try bindKnownUseImportFromModule(self, module_name, remote_name, remote_name);
    }
}

fn bindBuiltinUseImport(
    self: *context.Context,
    local_name: []const u8,
    builtin: context.Context.BuiltinConstant,
) ResolveError!void {
    const idx = try symbols_mod.ensureSymbol(self, local_name);
    const sym = &self.symbols.items[idx];
    sym.name = local_name;
    sym.applyTypeSpec(builtin.type_spec);
    sym.dims = &.{};
    sym.kind = .parameter;
    sym.storage = .local;
    sym.const_value = builtin.value;
    sym.type_explicit = true;
}

fn isIsoFortranEnvModule(module_name: []const u8) bool {
    const target = "iso_fortran_env";
    if (module_name.len != target.len) return false;
    var buf: [32]u8 = undefined;
    for (module_name, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return std.mem.eql(u8, buf[0..module_name.len], target);
}

fn isIsoCBindingModule(module_name: []const u8) bool {
    const target = "iso_c_binding";
    if (module_name.len != target.len) return false;
    var buf: [32]u8 = undefined;
    for (module_name, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return std.mem.eql(u8, buf[0..module_name.len], target);
}

fn useImportConflictsWithCurrentUnit(self: *context.Context, local_name: []const u8) bool {
    if (self.unit.kind != .subroutine and self.unit.kind != .function) return false;
    if (std.ascii.eqlIgnoreCase(local_name, self.unit.name)) return true;
    if (self.unit.result_name) |result_name| {
        if (std.ascii.eqlIgnoreCase(local_name, result_name)) return true;
    }
    return false;
}

fn emitUseImportConflictDiagnostic(
    self: *context.Context,
    use_stmt: ast.UseStmt,
    local_name: []const u8,
) void {
    const source = use_stmt.source;
    const line = if (source.line == 0) 1 else source.line;
    const col = if (source.column == 0) 1 else source.column;
    const message = std.fmt.allocPrint(self.arena, "'{s}' conflicts with the current program unit", .{local_name}) catch "conflicts with the current program unit";
    self.setDiagnostic(
        line,
        col,
        catalog.semantic.duplicate_declaration.code,
        message,
        source.text,
    );
}
