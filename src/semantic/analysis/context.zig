const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const common_diag = @import("../../common/diagnostic.zig");
const catalog = @import("../../common/error_catalog.zig");
const diag = @import("../diagnostic.zig");
const symbols = @import("../symbol/mod.zig");
const scope = @import("../scope.zig");
const intrinsics = @import("intrinsics.zig");

pub const Context = struct {
    pub const Dialect = enum {
        default,
        f77_legacy,
    };

    pub const DerivedTypeInfo = struct {
        pub const ComponentInfo = struct {
            name: []const u8,
            source: ast.DeclSource = .{},
            type_spec: symbols.TypeSpec,
            dims: []*ast.Expr = &.{},
            pointer: bool = false,
            allocatable: bool = false,
            procedure: bool = false,
            procedure_sig: ?ProcedureSig = null,
            procedure_kind: ?ast.ProgramUnitKind = null,
            procedure_has_explicit_interface: bool = false,
            procedure_nopass: bool = false,
            procedure_pass_name: ?[]const u8 = null,
            interface_name: ?[]const u8 = null,
        };

        pub const BindingInfo = struct {
            name: []const u8,
            source: ast.DeclSource = .{},
            owner_name: ?[]const u8 = null,
            owner_kind: ?ast.LexicalOwnerKind = null,
            is_generic: bool = false,
            interface_name: ?[]const u8 = null,
            implementation_name: ?[]const u8 = null,
            deferred: bool = false,
            nopass: bool = false,
            pass_name: ?[]const u8 = null,
            private: bool = false,
            non_overridable: bool = false,
        };

        name: []const u8,
        source: ast.DeclSource = .{},
        parent_name: ?[]const u8 = null,
        abstract: bool = false,
        sequence: bool = false,
        bind_c: bool = false,
        components: []const ComponentInfo = &.{},
        bindings: []const BindingInfo = &.{},
        final_subroutines: []const []const u8 = &.{},
    };

    pub const IntegerBounds = struct {
        min: i64,
        max: i64,
    };

    pub const TargetLayout = struct {
        default_integer_bits: u16 = 32,

        pub fn integerBounds(self: TargetLayout, target: ast.TypeKind) IntegerBounds {
            return switch (target) {
                .integer => signedIntegerBounds(self.default_integer_bits),
                else => .{
                    .min = std.math.minInt(i64),
                    .max = std.math.maxInt(i64),
                },
            };
        }

        fn signedIntegerBounds(bits: u16) IntegerBounds {
            const normalized: u16 = if (bits == 0) 32 else @min(bits, 64);
            if (normalized >= 64) {
                return .{
                    .min = std.math.minInt(i64),
                    .max = std.math.maxInt(i64),
                };
            }
            const shift_amt: u7 = @intCast(normalized - 1);
            const limit: i128 = @as(i128, 1) << shift_amt;
            return .{
                .min = @intCast(-limit),
                .max = @intCast(limit - 1),
            };
        }
    };

    pub const ProcedureSig = struct {
        pub const ArgSig = struct {
            name: []const u8 = "",
            type_spec: symbols.TypeSpec = symbols.TypeSpec.fromResolvedKind(.real, .real, null),
            requires_descriptor: bool = false,
            rank: usize = 0,
            assumed_rank: bool = false,
            shape_signature: []const []const u8 = &.{},
            pointer: bool = false,
            allocatable: bool = false,
            optional: bool = false,
            intent: ?ast.IntentKind = null,
            asynchronous: bool = false,
            contiguous: bool = false,
            value_attr: bool = false,
            volatile_attr: bool = false,
            no_arg_check: bool = false,
            is_procedure: bool = false,
            procedure_kind: ?ast.ProgramUnitKind = null,
            procedure_pure: bool = false,
            procedure_has_explicit_interface: bool = false,
            procedure_arg_count: usize = 0,
            procedure_alt_return_count: usize = 0,
            procedure_result_type_spec: ?symbols.TypeSpec = null,
            procedure_result_rank: usize = 0,
            procedure_result_shape_signature: []const []const u8 = &.{},
            procedure_result_pointer: bool = false,
            procedure_result_allocatable: bool = false,
            procedure_result_contiguous: bool = false,
            procedure_result_procedure_pointer: bool = false,
            procedure_dummy_sigs: []const ArgSig = &.{},
        };

        kind: ast.ProgramUnitKind,
        arg_count: usize,
        alt_return_count: usize = 0,
        args: []const ArgSig = &.{},
        pure: bool = false,
        elemental: bool = false,
        is_pointer: bool = false,
        result_rank: usize = 0,
        result_type_spec: ?symbols.TypeSpec = null,
        result_shape_signature: []const []const u8 = &.{},
        result_allocatable: bool = false,
        result_contiguous: bool = false,
        result_procedure_pointer: bool = false,
        actual_requires_explicit_interface: bool = false,
        definition_known_from_current_program: bool = false,
    };

    pub const ImplicitActualClass = enum {
        scalar,
        sequence,
    };

    pub const ImplicitCallArgSig = struct {
        type_spec: symbols.TypeSpec,
        actual_class: ImplicitActualClass,
        can_sequence_associate: bool = false,
        source: ast.SourceRef = .{},
        mismatch_reported: bool = false,
    };

    pub const ImplicitCallSig = struct {
        args: []ImplicitCallArgSig,
        call_source: ast.SourceRef = .{},
    };

    pub const DeclareVariantAdjustArgKind = enum {
        nothing,
        need_device_ptr,
        need_device_addr,
    };

    pub const DeclareVariantAdjustArg = struct {
        procedure_name: []const u8,
        arg_name: []const u8,
        kind: DeclareVariantAdjustArgKind,
    };

    pub const ActiveDoControl = struct {
        name: []const u8,
        end_label: []const u8,
        source: ast.SourceRef = .{},
    };

    pub const BuiltinConstant = struct {
        module_name: []const u8,
        type_spec: symbols.TypeSpec,
        value: symbols.ConstValue,
    };

    arena: std.mem.Allocator,
    unit: ast.ProgramUnit,
    unit_backing: ?*ast.ProgramUnit,
    current_unit: ?*const ast.ProgramUnit,
    symbols: std.array_list.Managed(symbols.Symbol),
    implicit: std.array_list.Managed(symbols.ImplicitRule),
    refs: std.array_list.Managed(symbols.ResolvedRef),
    ref_kind_index: std.AutoHashMap(usize, symbols.ResolvedRefKind),
    ref_symbol_index: std.AutoHashMap(usize, usize),
    symbol_lookup_cache: std.StringHashMap(?usize),
    symbol_lookup_cache_scope: ?scope.ScopeId,
    known_function_type_spec_cache: std.StringHashMap(?symbols.TypeSpec),
    known_procedure_sig_cache: std.StringHashMap(?ProcedureSig),
    intrinsic_arity_cache: std.StringHashMap(?intrinsics.Arity),
    implicit_call_sigs: std.StringHashMap(ImplicitCallSig),
    builtin_constants: std.StringHashMap(BuiltinConstant),
    derived_types: std.StringHashMap(DerivedTypeInfo),
    const_string_pool: std.StringHashMap([]const u8),
    const_eval_cache: std.AutoHashMap(usize, ?symbols.ConstValue),
    expr_type_cache: std.AutoHashMap(usize, ast.TypeKind),
    expr_type_spec_cache: std.AutoHashMap(usize, symbols.TypeSpec),
    expr_source_index: std.AutoHashMap(usize, ast.SourceRef),
    initialized_symbols: std.StringHashMap(ast.DeclSource),
    common_block_names: std.StringHashMap(void),
    common_blocks_indexed: bool,
    equivalence_nodes: std.StringHashMap(usize),
    equivalence_parent: std.array_list.Managed(usize),
    equivalence_delta: std.array_list.Managed(i64),
    equivalence_rank: std.array_list.Managed(u8),
    scopes: std.array_list.Managed(scope.Scope),
    current_scope: ?scope.ScopeId,
    current_owner: ?Owner,
    current_decl_index: ?usize,
    current_decl_source: ?ast.DeclSource,
    current_source: ?ast.SourceRef,
    current_stmt: ?ast.Stmt,
    active_do_controls: std.array_list.Managed(ActiveDoControl),
    diag_bag: ?*diag.Bag,
    known_function_type_specs: *const std.StringHashMap(symbols.TypeSpec),
    known_procedure_sigs: *const std.StringHashMap(ProcedureSig),
    known_host_parameters: *const std.StringHashMap(symbols.Symbol),
    known_host_derived_types: *const std.StringHashMap(DerivedTypeInfo),
    known_host_interface_sources: *const std.StringHashMap(ast.DeclSource),
    known_host_abstract_interfaces: *const std.StringHashMap(void),
    known_host_owner: ?[]const u8,
    known_host_implicit_call_sigs: ?*std.StringHashMap(ImplicitCallSig),
    known_program_implicit_call_sigs: ?*std.StringHashMap(ImplicitCallSig),
    target_layout: TargetLayout,
    range_check: bool,
    fbackslash: bool,
    allow_argument_mismatch: bool,
    dialect: Dialect,
    use_imports_preinstalled: bool,
    declare_variant_adjust_args: []const DeclareVariantAdjustArg = &.{},

    pub const Owner = struct {
        name: []const u8,
        kind: ast.ProgramUnitKind,
    };

    pub fn init(
        arena: std.mem.Allocator,
        unit: ast.ProgramUnit,
        known_function_type_specs: *const std.StringHashMap(symbols.TypeSpec),
        known_procedure_sigs: *const std.StringHashMap(ProcedureSig),
        known_host_parameters: *const std.StringHashMap(symbols.Symbol),
        known_host_derived_types: *const std.StringHashMap(DerivedTypeInfo),
        known_host_interface_sources: *const std.StringHashMap(ast.DeclSource),
        known_host_abstract_interfaces: *const std.StringHashMap(void),
        known_host_owner: ?[]const u8,
        target_layout: TargetLayout,
        range_check: bool,
    ) Context {
        return initWithDiagnostics(
            arena,
            unit,
            known_function_type_specs,
            known_procedure_sigs,
            known_host_parameters,
            known_host_derived_types,
            known_host_interface_sources,
            known_host_abstract_interfaces,
            known_host_owner,
            target_layout,
            range_check,
            null,
        );
    }

    pub fn initWithDiagnostics(
        arena: std.mem.Allocator,
        unit: ast.ProgramUnit,
        known_function_type_specs: *const std.StringHashMap(symbols.TypeSpec),
        known_procedure_sigs: *const std.StringHashMap(ProcedureSig),
        known_host_parameters: *const std.StringHashMap(symbols.Symbol),
        known_host_derived_types: *const std.StringHashMap(DerivedTypeInfo),
        known_host_interface_sources: *const std.StringHashMap(ast.DeclSource),
        known_host_abstract_interfaces: *const std.StringHashMap(void),
        known_host_owner: ?[]const u8,
        target_layout: TargetLayout,
        range_check: bool,
        diag_bag: ?*diag.Bag,
    ) Context {
        var ctx = Context{
            .arena = arena,
            .unit = unit,
            .unit_backing = null,
            .current_unit = null,
            .symbols = std.array_list.Managed(symbols.Symbol).init(arena),
            .implicit = std.array_list.Managed(symbols.ImplicitRule).init(arena),
            .refs = std.array_list.Managed(symbols.ResolvedRef).init(arena),
            .ref_kind_index = std.AutoHashMap(usize, symbols.ResolvedRefKind).init(arena),
            .ref_symbol_index = std.AutoHashMap(usize, usize).init(arena),
            .symbol_lookup_cache = std.StringHashMap(?usize).init(arena),
            .symbol_lookup_cache_scope = null,
            .known_function_type_spec_cache = std.StringHashMap(?symbols.TypeSpec).init(arena),
            .known_procedure_sig_cache = std.StringHashMap(?ProcedureSig).init(arena),
            .intrinsic_arity_cache = std.StringHashMap(?intrinsics.Arity).init(arena),
            .implicit_call_sigs = std.StringHashMap(ImplicitCallSig).init(arena),
            .builtin_constants = std.StringHashMap(BuiltinConstant).init(arena),
            .derived_types = std.StringHashMap(DerivedTypeInfo).init(arena),
            .const_string_pool = std.StringHashMap([]const u8).init(arena),
            .const_eval_cache = std.AutoHashMap(usize, ?symbols.ConstValue).init(arena),
            .expr_type_cache = std.AutoHashMap(usize, ast.TypeKind).init(arena),
            .expr_type_spec_cache = std.AutoHashMap(usize, symbols.TypeSpec).init(arena),
            .expr_source_index = std.AutoHashMap(usize, ast.SourceRef).init(arena),
            .initialized_symbols = std.StringHashMap(ast.DeclSource).init(arena),
            .common_block_names = std.StringHashMap(void).init(arena),
            .common_blocks_indexed = false,
            .equivalence_nodes = std.StringHashMap(usize).init(arena),
            .equivalence_parent = std.array_list.Managed(usize).init(arena),
            .equivalence_delta = std.array_list.Managed(i64).init(arena),
            .equivalence_rank = std.array_list.Managed(u8).init(arena),
            .scopes = std.array_list.Managed(scope.Scope).init(arena),
            .current_scope = null,
            .current_owner = null,
            .current_decl_index = null,
            .current_decl_source = null,
            .current_source = null,
            .current_stmt = null,
            .active_do_controls = std.array_list.Managed(ActiveDoControl).init(arena),
            .diag_bag = diag_bag,
            .known_function_type_specs = known_function_type_specs,
            .known_procedure_sigs = known_procedure_sigs,
            .known_host_parameters = known_host_parameters,
            .known_host_derived_types = known_host_derived_types,
            .known_host_interface_sources = known_host_interface_sources,
            .known_host_abstract_interfaces = known_host_abstract_interfaces,
            .known_host_owner = known_host_owner,
            .known_host_implicit_call_sigs = null,
            .known_program_implicit_call_sigs = null,
            .target_layout = target_layout,
            .range_check = range_check,
            .fbackslash = false,
            .allow_argument_mismatch = false,
            .dialect = .default,
            .use_imports_preinstalled = false,
        };
        ctx.current_unit = &ctx.unit;
        for (ctx.unit.expr_sources) |expr_source| {
            ctx.expr_source_index.put(@intFromPtr(expr_source.expr), expr_source.source) catch {};
        }
        return ctx;
    }

    pub fn hasDiagnostic(self: *const Context) bool {
        if (self.diag_bag) |bag| return bag.has();
        return diag.has();
    }

    pub fn usesExplicitDiagnosticBag(self: *const Context) bool {
        return self.diag_bag != null;
    }

    pub fn diagnosticCount(self: *const Context) usize {
        if (self.diag_bag) |bag| return bag.count();
        return if (diag.has()) 1 else 0;
    }

    pub fn setDiagnostic(self: *Context, line: usize, column: usize, code: []const u8, message: []const u8, line_text: []const u8) void {
        self.setDiagnosticDetailed(line, column, code, message, line_text, &.{}, &.{});
    }

    pub fn setDiagnosticDetailed(
        self: *Context,
        line: usize,
        column: usize,
        code: []const u8,
        message: []const u8,
        line_text: []const u8,
        notes: []const common_diag.DiagnosticMessage,
        helps: []const common_diag.DiagnosticMessage,
    ) void {
        self.setDiagnosticStructuredWithSeverity(line, column, code, message, line_text, .@"error", "", notes, helps, &.{});
    }

    pub fn setDiagnosticStructured(
        self: *Context,
        line: usize,
        column: usize,
        code: []const u8,
        message: []const u8,
        line_text: []const u8,
        primary_label: []const u8,
        notes: []const common_diag.DiagnosticMessage,
        helps: []const common_diag.DiagnosticMessage,
        secondary_spans: []const common_diag.DiagnosticSpan,
    ) void {
        self.setDiagnosticStructuredWithSeverity(line, column, code, message, line_text, .@"error", primary_label, notes, helps, secondary_spans);
    }

    pub fn setDiagnosticDetailedWithSeverity(
        self: *Context,
        line: usize,
        column: usize,
        code: []const u8,
        message: []const u8,
        line_text: []const u8,
        severity: common_diag.DiagnosticSeverity,
        notes: []const common_diag.DiagnosticMessage,
        helps: []const common_diag.DiagnosticMessage,
    ) void {
        self.setDiagnosticStructuredWithSeverity(line, column, code, message, line_text, severity, "", notes, helps, &.{});
    }

    pub fn setDiagnosticStructuredWithSeverity(
        self: *Context,
        line: usize,
        column: usize,
        code: []const u8,
        message: []const u8,
        line_text: []const u8,
        severity: common_diag.DiagnosticSeverity,
        primary_label: []const u8,
        notes: []const common_diag.DiagnosticMessage,
        helps: []const common_diag.DiagnosticMessage,
        secondary_spans: []const common_diag.DiagnosticSpan,
    ) void {
        if (self.diag_bag) |bag| {
            bag.setStructuredWithSeverity(line, column, code, message, line_text, severity, primary_label, notes, helps, secondary_spans);
            return;
        }
        diag.setStructuredWithSeverity(line, column, code, message, line_text, severity, primary_label, notes, helps, secondary_spans);
    }

    pub fn noteFallbackSource(self: *Context, line: usize, column: usize, line_text: []const u8) void {
        if (self.diag_bag) |bag| {
            bag.noteFallbackSource(line, column, line_text);
            return;
        }
        diag.noteFallbackSource(line, column, line_text);
    }

    pub fn fallbackSource(self: *const Context) ?diag.FallbackSource {
        if (self.diag_bag) |bag| return bag.fallbackSource();
        return diag.fallbackSource();
    }

    pub fn recordSemanticError(self: *Context, err: anyerror) void {
        if (self.usesExplicitDiagnosticBag() and latestDiagnosticMatchesActiveSource(self)) return;
        if (!self.usesExplicitDiagnosticBag() and self.hasDiagnostic()) return;

        const info = catalog.semanticInfoFor(err);
        const advice = semanticAdviceFor(err);
        if (self.current_source) |source| {
            const line = if (source.line == 0) 1 else source.line;
            const col = if (source.column == 0) 1 else source.column;
            self.setDiagnosticDetailed(line, col, info.code, info.message, source.text, advice.notes, advice.helps);
            return;
        }
        if (self.current_decl_source) |decl_src| {
            const line = if (decl_src.line == 0) 1 else decl_src.line;
            const col = if (decl_src.column == 0) 1 else decl_src.column;
            self.setDiagnosticDetailed(line, col, info.code, info.message, decl_src.text, advice.notes, advice.helps);
            return;
        }
        if (self.current_stmt) |stmt| {
            const line = if (stmt.source_line == 0) 1 else stmt.source_line;
            const col = if (stmt.source_column == 0) 1 else stmt.source_column;
            self.setDiagnosticDetailed(line, col, info.code, info.message, stmt.source_text, advice.notes, advice.helps);
            return;
        }
        if (self.fallbackSource()) |source| {
            self.setDiagnosticDetailed(source.line, source.column, info.code, info.message, source.line_text, advice.notes, advice.helps);
        }
    }

    const Advice = struct {
        notes: []const common_diag.DiagnosticMessage = &.{},
        helps: []const common_diag.DiagnosticMessage = &.{},
    };

    fn semanticAdviceFor(err: anyerror) Advice {
        return switch (err) {
            error.InvalidCharLen => .{
                .notes = &.{.{ .text = "CHARACTER length must be constant unless the entity is a dummy argument, function result, POINTER, or ALLOCATABLE." }},
                .helps = &.{.{ .text = "Use a positive constant length here, or move the assumed/deferred length onto a supported entity kind." }},
            },
            error.InvalidArithmeticOperands => .{
                .notes = &.{.{ .text = "Arithmetic operators require operands from compatible intrinsic categories." }},
                .helps = &.{.{ .text = "Convert CHARACTER or LOGICAL operands before using arithmetic operators." }},
            },
            error.InvalidArgumentCount => .{
                .notes = &.{.{ .text = "The semantic call checker matched this against one visible procedure shape or explicit interface." }},
                .helps = &.{.{ .text = "Check the callee's interface and the actual argument list together." }},
            },
            else => .{},
        };
    }

    fn latestDiagnosticMatchesActiveSource(self: *const Context) bool {
        const bag = self.diag_bag orelse return false;
        const latest = bag.latest() orelse return false;
        if (self.current_source) |source| {
            return latest.line == (if (source.line == 0) 1 else source.line) and
                latest.column == (if (source.column == 0) 1 else source.column);
        }
        if (self.current_decl_source) |decl_src| {
            return latest.line == (if (decl_src.line == 0) 1 else decl_src.line) and
                latest.column == (if (decl_src.column == 0) 1 else decl_src.column);
        }
        if (self.current_stmt) |stmt| {
            return latest.line == (if (stmt.source_line == 0) 1 else stmt.source_line) and
                latest.column == (if (stmt.source_column == 0) 1 else stmt.source_column);
        }
        return false;
    }

    pub fn internConstString(self: *Context, text: []const u8) ![]const u8 {
        if (self.const_string_pool.get(text)) |existing| return existing;
        const owned = try self.arena.dupe(u8, text);
        try self.const_string_pool.put(owned, owned);
        return owned;
    }

    pub fn bindUnitBacking(self: *Context, unit_ptr: *ast.ProgramUnit) void {
        self.unit_backing = unit_ptr;
        self.current_unit = unit_ptr;
    }

    pub fn replaceUnitStmts(self: *Context, stmts: []ast.Stmt) void {
        self.unit.stmts = stmts;
        if (self.unit_backing) |unit_ptr| {
            unit_ptr.stmts = stmts;
        }
    }

    pub fn initScopeTree(self: *Context) !void {
        if (self.current_scope != null) return;
        const id = scope.ScopeId{ .index = 0 };
        try self.scopes.append(.{
            .id = id,
            .parent = null,
            .kind = .global,
            .symbols = std.StringHashMap(usize).init(self.arena),
            .owner_name = null,
            .owner_kind = null,
        });
        self.current_scope = id;
        self.invalidateSymbolLookupCache();
        self.updateCurrentOwner();
    }

    pub fn pushScope(self: *Context, kind: scope.ScopeKind) !scope.ScopeId {
        return self.pushScopeWithOwner(kind, null, null);
    }

    pub fn pushScopeWithOwner(
        self: *Context,
        kind: scope.ScopeKind,
        owner_name: ?[]const u8,
        owner_kind: ?ast.ProgramUnitKind,
    ) !scope.ScopeId {
        const parent = self.current_scope;
        const id = scope.ScopeId{ .index = @intCast(self.scopes.items.len) };
        try self.scopes.append(.{
            .id = id,
            .parent = parent,
            .kind = kind,
            .symbols = std.StringHashMap(usize).init(self.arena),
            .owner_name = owner_name,
            .owner_kind = owner_kind,
        });
        self.current_scope = id;
        self.invalidateSymbolLookupCache();
        self.updateCurrentOwner();
        return id;
    }

    pub fn popScope(self: *Context) void {
        if (self.current_scope == null) return;
        const current = self.scopes.items[self.current_scope.?.index];
        self.current_scope = current.parent;
        self.invalidateSymbolLookupCache();
        self.updateCurrentOwner();
    }

    pub fn setCurrentScope(self: *Context, id: scope.ScopeId) void {
        self.current_scope = id;
        self.invalidateSymbolLookupCache();
        self.updateCurrentOwner();
    }

    pub fn findScopeByOwner(self: *Context, name: []const u8, kind: ast.ProgramUnitKind) ?scope.ScopeId {
        for (self.scopes.items) |scope_info| {
            if (scope_info.owner_name == null or scope_info.owner_kind == null) continue;
            if (!std.mem.eql(u8, scope_info.owner_name.?, name)) continue;
            if (scope_info.owner_kind.? != kind) continue;
            return scope_info.id;
        }
        return null;
    }

    pub fn enterUnitScope(self: *Context) bool {
        if (self.findScopeByOwner(self.unit.name, self.unit.kind)) |id| {
            self.setCurrentScope(id);
            return true;
        }
        return false;
    }

    fn updateCurrentOwner(self: *Context) void {
        var scope_id = self.current_scope;
        while (scope_id) |id| {
            const scope_info = self.scopes.items[id.index];
            if (scope_info.owner_name != null and scope_info.owner_kind != null) {
                self.current_owner = .{
                    .name = scope_info.owner_name.?,
                    .kind = scope_info.owner_kind.?,
                };
                return;
            }
            scope_id = scope_info.parent;
        }
        self.current_owner = null;
    }

    pub fn setCurrentStmt(self: *Context, stmt: ast.Stmt) void {
        self.current_stmt = stmt;
        self.noteFallbackSource(
            if (stmt.source_line == 0) 1 else stmt.source_line,
            if (stmt.source_column == 0) 1 else stmt.source_column,
            stmt.source_text,
        );
    }

    pub fn clearCurrentStmt(self: *Context) void {
        self.current_stmt = null;
    }

    pub fn setCurrentDeclSource(self: *Context, source: ?ast.DeclSource) void {
        self.current_decl_source = source;
        if (source) |decl_source| {
            self.noteFallbackSource(
                if (decl_source.line == 0) 1 else decl_source.line,
                if (decl_source.column == 0) 1 else decl_source.column,
                decl_source.text,
            );
        }
    }

    pub fn setCurrentDeclIndex(self: *Context, decl_idx: ?usize) void {
        self.current_decl_index = decl_idx;
    }

    pub fn setCurrentSource(self: *Context, source: ?ast.SourceRef) void {
        self.current_source = source;
        if (source) |src| {
            self.noteFallbackSource(
                if (src.line == 0) 1 else src.line,
                if (src.column == 0) 1 else src.column,
                src.text,
            );
        }
    }

    pub fn sourceForExpr(self: *const Context, expr_node: *ast.Expr) ?ast.SourceRef {
        return self.expr_source_index.get(@intFromPtr(expr_node));
    }

    pub fn invalidateSymbolLookupCache(self: *Context) void {
        self.symbol_lookup_cache_scope = null;
        self.symbol_lookup_cache.clearRetainingCapacity();
    }
};
