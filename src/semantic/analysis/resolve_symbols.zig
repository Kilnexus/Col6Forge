const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const case_insensitive = @import("../../common/case_insensitive.zig");
const catalog = @import("../../common/error_catalog.zig");
const symbols = @import("../symbol/mod.zig");
const context = @import("context.zig");
const intrinsics = @import("intrinsics.zig");

const SymbolKind = symbols.SymbolKind;
const Symbol = symbols.Symbol;
const CharacterLengthKind = symbols.CharacterLengthKind;
const TypeSpec = symbols.TypeSpec;
const ResolvedRefKind = symbols.ResolvedRefKind;
const MAX_IDENT_LEN: usize = 64;
const lowerDup = case_insensitive.lowerDup;

pub const AliasAttrs = struct {
    is_pointer: bool = false,
    is_target: bool = false,
};

pub fn initImplicitDefaults(self: *context.Context) !void {
    try self.implicit.append(symbols.ImplicitRule.init('I', 'N', TypeSpec.fromResolvedKind(.integer, .integer, null)));
    try self.implicit.append(symbols.ImplicitRule.init('A', 'H', TypeSpec.fromResolvedKind(.real, .real, null)));
    try self.implicit.append(symbols.ImplicitRule.init('O', 'Z', TypeSpec.fromResolvedKind(.real, .real, null)));
}

pub fn installBuiltinConstants(self: *context.Context) !void {
    if (self.builtin_constants.count() != 0) return;
    const integer_spec = TypeSpec.fromResolvedKind(.integer, .integer, null);
    try putBuiltinConstant(self, "iso_fortran_env", "output_unit", integer_spec, .{ .integer = 6 });
    try putBuiltinConstant(self, "iso_fortran_env", "input_unit", integer_spec, .{ .integer = 5 });
    try putBuiltinConstant(self, "iso_fortran_env", "error_unit", integer_spec, .{ .integer = 0 });
    try putBuiltinConstant(self, "iso_fortran_env", "int8", integer_spec, .{ .integer = 1 });
    try putBuiltinConstant(self, "iso_fortran_env", "int16", integer_spec, .{ .integer = 2 });
    try putBuiltinConstant(self, "iso_fortran_env", "int32", integer_spec, .{ .integer = 4 });
    try putBuiltinConstant(self, "iso_fortran_env", "int64", integer_spec, .{ .integer = 8 });
    try putBuiltinConstant(self, "iso_fortran_env", "real32", integer_spec, .{ .integer = 4 });
    try putBuiltinConstant(self, "iso_fortran_env", "real64", integer_spec, .{ .integer = 8 });
}

pub fn registerDerivedType(self: *context.Context, info: context.Context.DerivedTypeInfo) !void {
    if (getLowercaseMapValue(context.Context.DerivedTypeInfo, &self.derived_types, info.name)) |existing| {
        if (sameDerivedTypeRegistration(existing, info)) return;
        emitDuplicateDerivedTypeDiagnostic(self, existing, info);
        return error.DuplicateDeclaration;
    }
    const key = try lowerDup(self.arena, info.name);
    try self.derived_types.put(key, info);
}

fn sameDerivedTypeRegistration(
    existing: context.Context.DerivedTypeInfo,
    incoming: context.Context.DerivedTypeInfo,
) bool {
    if (!std.ascii.eqlIgnoreCase(existing.name, incoming.name)) return false;
    if (sameDerivedTypeOrigin(existing.source, incoming.source)) return true;
    if (existing.source.line != 0 or incoming.source.line != 0) return false;
    if (existing.bind_c != incoming.bind_c) return false;
    if (existing.bind_c) return true;
    return ownerNamesEqual(existing.source.owner_name, incoming.source.owner_name);
}

fn ownerNamesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.ascii.eqlIgnoreCase(left.?, right.?);
}

fn emitDuplicateDerivedTypeDiagnostic(
    self: *context.Context,
    existing: context.Context.DerivedTypeInfo,
    incoming: context.Context.DerivedTypeInfo,
) void {
    const source = incoming.source;
    const line = if (source.line == 0) 1 else source.line;
    const column = if (source.column == 0) 1 else source.column;
    const message = if (derivedTypeImportsAreAmbiguous(existing, incoming))
        std.fmt.allocPrint(self.arena, "Type name '{s}' at .1. is ambiguous", .{incoming.name}) catch "Type name is ambiguous"
    else
        std.fmt.allocPrint(self.arena, "Derived type definition of '{s}' at .1. has already been defined", .{incoming.name}) catch "Derived type definition has already been defined";
    self.setDiagnosticStructured(
        line,
        column,
        catalog.semantic.duplicate_declaration.code,
        message,
        source.text,
        "conflicting derived type here",
        &.{.{ .text = "A derived type name must identify a single accessible type in the current scope." }},
        &.{.{ .text = "Rename the local type or restrict the USE imports with ONLY or renaming." }},
        &.{},
    );
}

fn derivedTypeImportsAreAmbiguous(
    existing: context.Context.DerivedTypeInfo,
    incoming: context.Context.DerivedTypeInfo,
) bool {
    const existing_owner = existing.source.owner_name orelse return false;
    const incoming_owner = incoming.source.owner_name orelse return false;
    return !std.ascii.eqlIgnoreCase(existing_owner, incoming_owner);
}

pub fn hasDerivedType(self: *const context.Context, name: []const u8) bool {
    return getLowercaseMapValue(context.Context.DerivedTypeInfo, &self.derived_types, name) != null or
        getLowercaseMapValue(context.Context.DerivedTypeInfo, self.known_host_derived_types, name) != null;
}

pub fn hasKnownHostDerivedType(self: *const context.Context, name: []const u8) bool {
    return getLowercaseMapValue(context.Context.DerivedTypeInfo, self.known_host_derived_types, name) != null;
}

pub fn hasLocalDerivedType(self: *const context.Context, name: []const u8) bool {
    return getLowercaseMapValue(context.Context.DerivedTypeInfo, &self.derived_types, name) != null;
}

pub fn lookupDerivedType(self: *const context.Context, name: []const u8) ?context.Context.DerivedTypeInfo {
    return getLowercaseMapValue(context.Context.DerivedTypeInfo, &self.derived_types, name) orelse
        getLowercaseMapValue(context.Context.DerivedTypeInfo, self.known_host_derived_types, name);
}

pub fn lookupDerivedComponent(
    self: *const context.Context,
    type_name: []const u8,
    component_name: []const u8,
) ?context.Context.DerivedTypeInfo.ComponentInfo {
    var current = lookupDerivedType(self, type_name) orelse return null;
    while (true) {
        for (current.components) |component| {
            if (std.ascii.eqlIgnoreCase(component.name, component_name)) return component;
        }
        const parent = current.parent_name orelse return null;
        if (std.ascii.eqlIgnoreCase(parent, component_name)) {
            return .{
                .name = parent,
                .type_spec = TypeSpec.fromDerived(parent),
            };
        }
        current = lookupDerivedType(self, parent) orelse return null;
    }
}

pub fn lookupDerivedBinding(
    self: *const context.Context,
    type_name: []const u8,
    binding_name: []const u8,
) ?context.Context.DerivedTypeInfo.BindingInfo {
    const current = lookupDerivedType(self, type_name) orelse return null;
    while (true) {
        for (current.bindings) |binding| {
            if (std.ascii.eqlIgnoreCase(binding.name, binding_name)) return binding;
        }
        const parent = current.parent_name orelse return null;
        const inherited = lookupDerivedBinding(self, parent, binding_name) orelse return null;
        if (lookupOverrideBinding(current.bindings, inherited)) |override| return override;
        return inherited;
    }
}

fn lookupOverrideBinding(
    bindings: []const context.Context.DerivedTypeInfo.BindingInfo,
    inherited: context.Context.DerivedTypeInfo.BindingInfo,
) ?context.Context.DerivedTypeInfo.BindingInfo {
    const inherited_target = inherited.implementation_name orelse inherited.name;
    for (bindings) |binding| {
        if (std.ascii.eqlIgnoreCase(binding.name, inherited_target)) return binding;
        if (binding.implementation_name) |impl_name| {
            if (std.ascii.eqlIgnoreCase(impl_name, inherited_target)) return binding;
        }
    }
    return null;
}

pub fn derivedTypeHasImpureFinalizer(self: *const context.Context, type_name: []const u8) bool {
    var current = lookupDerivedType(self, type_name) orelse return false;
    while (true) {
        for (current.final_subroutines) |final_name| {
            const sig = lookupQualifiedProcedureSig(self, current.source.owner_name, final_name) orelse
                getLowercaseMapValue(context.Context.ProcedureSig, self.known_procedure_sigs, final_name) orelse
                return true;
            if (!sig.pure) return true;
        }
        const parent_name = current.parent_name orelse return false;
        current = lookupDerivedType(self, parent_name) orelse return false;
    }
}

pub fn lookupQualifiedProcedureSig(
    self: *const context.Context,
    owner_name: ?[]const u8,
    proc_name: []const u8,
) ?context.Context.ProcedureSig {
    const owner = owner_name orelse return null;
    const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner, proc_name }) catch return null;
    return getLowercaseMapValue(context.Context.ProcedureSig, self.known_procedure_sigs, qualified);
}

pub fn isSameOrExtension(self: *const context.Context, candidate: []const u8, base: []const u8) bool {
    var current = lookupDerivedType(self, candidate) orelse return false;
    while (true) {
        if (std.ascii.eqlIgnoreCase(current.name, base)) return true;
        const parent = current.parent_name orelse return false;
        current = lookupDerivedType(self, parent) orelse return false;
    }
}

pub fn areConcreteDerivedTypesCompatible(self: *const context.Context, left_name: []const u8, right_name: []const u8) bool {
    var visited = std.array_list.Managed(DerivedTypePair).init(self.arena);
    return areConcreteDerivedTypesCompatibleInner(self, left_name, right_name, &visited) catch false;
}

const DerivedTypePair = struct {
    left: []const u8,
    right: []const u8,
};

fn areConcreteDerivedTypesCompatibleInner(
    self: *const context.Context,
    left_name: []const u8,
    right_name: []const u8,
    visited: *std.array_list.Managed(DerivedTypePair),
) !bool {
    for (visited.items) |pair| {
        if (std.ascii.eqlIgnoreCase(pair.left, left_name) and std.ascii.eqlIgnoreCase(pair.right, right_name)) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(pair.left, right_name) and std.ascii.eqlIgnoreCase(pair.right, left_name)) {
            return true;
        }
    }
    try visited.append(.{ .left = left_name, .right = right_name });

    const left = lookupDerivedType(self, left_name) orelse return false;
    const right = lookupDerivedType(self, right_name) orelse return false;

    if (sameDerivedTypeOrigin(left.source, right.source)) return true;
    if (!(left.sequence and right.sequence) and !(left.bind_c and right.bind_c)) return false;
    return areDerivedComponentListsEquivalent(self, left.components, right.components, visited);
}

fn sameDerivedTypeOrigin(left: ast.DeclSource, right: ast.DeclSource) bool {
    if (left.line == 0 or right.line == 0) return false;
    if (left.line != right.line or left.column != right.column) return false;
    if (left.text.len == 0 or right.text.len == 0) return false;
    return std.mem.eql(u8, left.text, right.text);
}

fn areDerivedComponentListsEquivalent(
    self: *const context.Context,
    left: []const context.Context.DerivedTypeInfo.ComponentInfo,
    right: []const context.Context.DerivedTypeInfo.ComponentInfo,
    visited: *std.array_list.Managed(DerivedTypePair),
) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_component, right_component| {
        if (left_component.dims.len != right_component.dims.len) return false;
        if (left_component.pointer != right_component.pointer) return false;
        if (left_component.allocatable != right_component.allocatable) return false;
        if (left_component.procedure != right_component.procedure) return false;
        if (!areTypeSpecsEquivalentForDerivedCompatibility(self, left_component.type_spec, right_component.type_spec, visited)) return false;
    }
    return true;
}

fn areTypeSpecsEquivalentForDerivedCompatibility(
    self: *const context.Context,
    left: TypeSpec,
    right: TypeSpec,
    visited: *std.array_list.Managed(DerivedTypePair),
) bool {
    if (left.lowered_kind != right.lowered_kind) return false;
    if (left.polymorphic != right.polymorphic) return false;
    if (left.kind_value != right.kind_value) return false;
    if (left.char_len != right.char_len) return false;
    if (left.char_len_kind != right.char_len_kind) return false;
    if (left.lowered_kind != .derived) return true;

    const left_name = left.derived_type_name orelse return false;
    const right_name = right.derived_type_name orelse return false;
    return areConcreteDerivedTypesCompatibleInner(self, left_name, right_name, visited) catch false;
}

pub fn findBuiltinConstant(self: *context.Context, name: []const u8) ?context.Context.BuiltinConstant {
    return getLowercaseMapValue(context.Context.BuiltinConstant, &self.builtin_constants, name);
}

pub fn findBuiltinModuleConstant(
    self: *context.Context,
    module_name: []const u8,
    name: []const u8,
) ?context.Context.BuiltinConstant {
    const constant = findBuiltinConstant(self, name) orelse return null;
    if (!moduleNameMatches(module_name, constant.module_name)) return null;
    return constant;
}

fn moduleNameMatches(module_name: []const u8, normalized: []const u8) bool {
    if (module_name.len != normalized.len) return false;
    var key_buf: [MAX_IDENT_LEN]u8 = undefined;
    if (module_name.len <= key_buf.len) {
        const lowered = toLowerInBuffer(module_name, &key_buf);
        return std.mem.eql(u8, lowered, normalized);
    }
    return std.ascii.eqlIgnoreCase(module_name, normalized);
}

pub fn installUnitSymbol(self: *context.Context) !void {
    if (self.unit.kind == .module) return;
    const kind: SymbolKind = switch (self.unit.kind) {
        .module => unreachable,
        .program => .subroutine,
        .subroutine => .subroutine,
        .function => .function,
        .block_data => .subroutine,
    };
    const info = if (self.unit.kind == .function)
        ImplicitInfo{
            .type_spec = if (lookupKnownFunctionTypeSpec(self, self.unit.name)) |known_spec|
                known_spec
            else
                implicitInfo(self, self.unit.name).type_spec,
        }
    else
        implicitInfo(self, self.unit.name);
    const symbol = Symbol.init(self.unit.name, info.type_spec, &.{}, kind, .local);
    _ = try internSymbol(self, symbol);
    if (self.unit.kind == .function) {
        const result_name = self.unit.result_name orelse self.unit.name;
        if (!std.ascii.eqlIgnoreCase(result_name, self.unit.name)) {
            const result_symbol = Symbol.init(result_name, info.type_spec, &.{}, .variable, .local);
            _ = try internSymbol(self, result_symbol);
        }
    }
}

pub fn installDummyArgs(self: *context.Context) !void {
    if (self.current_scope == null) return error.MissingScope;
    const unit_sig = lookupKnownProcedureSig(self, self.unit.name);
    for (self.unit.args, 0..) |arg, arg_idx| {
        const info = implicitInfo(self, arg);
        var symbol = Symbol.init(arg, info.type_spec, &.{}, .variable, .dummy);
        if (unit_sig) |sig| {
            if (unitDeclaresEntity(self, arg)) {
                _ = try internSymbol(self, symbol);
                continue;
            }
            if (dummyArgSigForUnitArg(sig, arg, arg_idx)) |arg_sig| {
                symbol.applyTypeSpec(arg_sig.type_spec);
                symbol.type_explicit = true;
                symbol.dims = try syntheticRankDims(self, arg_sig.rank);
                symbol.is_pointer = arg_sig.pointer;
                symbol.is_allocatable = arg_sig.allocatable;
                symbol.contiguous = arg_sig.contiguous;
                symbol.no_arg_check = arg_sig.no_arg_check;
                if (arg_sig.is_procedure) {
                    if (arg_sig.procedure_kind == .function) {
                        symbol.kind = .function;
                    } else if (arg_sig.procedure_kind == .subroutine) {
                        symbol.kind = .subroutine;
                    }
                }
            }
        }
        _ = try internSymbol(self, symbol);
    }
}

fn dummyArgSigForUnitArg(
    sig: context.Context.ProcedureSig,
    arg_name: []const u8,
    arg_idx: usize,
) ?context.Context.ProcedureSig.ArgSig {
    for (sig.args) |arg_sig| {
        if (arg_sig.name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(arg_sig.name, arg_name)) return arg_sig;
    }
    if (arg_idx < sig.args.len) return sig.args[arg_idx];
    return null;
}

fn syntheticRankDims(self: *context.Context, rank: usize) ![]*ast.Expr {
    if (rank == 0) return &.{};
    const out = try self.arena.alloc(*ast.Expr, rank);
    var idx: usize = 0;
    while (idx < rank) : (idx += 1) {
        const dim_expr = try self.arena.create(ast.Expr);
        dim_expr.* = .{ .literal = .{ .kind = .integer, .text = "1" } };
        out[idx] = dim_expr;
    }
    return out;
}

fn unitDeclaresEntity(self: *const context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .dimension => |dim_decl| {
                for (dim_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .common => |common_decl| {
                for (common_decl.blocks) |block| {
                    for (block.items) |item| {
                        if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

pub fn ensureSymbol(self: *context.Context, name: []const u8) !usize {
    if (findSymbolIndex(self, name)) |idx| {
        return idx;
    }
    if (findKnownHostParameter(self, name)) |host_sym| {
        var imported = host_sym;
        imported.name = name;
        imported.is_host_associated = true;
        imported.host_owner_name = self.known_host_owner;
        return internSymbol(self, imported);
    }
    if (lookupKnownProcedureSig(self, name)) |sig| {
        const proc_kind: SymbolKind = switch (sig.kind) {
            .function => .function,
            else => .subroutine,
        };
        const proc_spec = if (proc_kind == .function)
            implicitInfo(self, name).type_spec
        else
            TypeSpec.fromResolvedKind(.real, .real, null);
        var symbol = Symbol.init(name, proc_spec, &.{}, proc_kind, .local);
        symbol.is_external = true;
        symbol.is_pointer = sig.is_pointer;
        return internSymbol(self, symbol);
    }
    const known_fn_spec = lookupKnownFunctionResolvedSpec(self, name);
    const info = if (known_fn_spec) |known_spec|
        ImplicitInfo{
            .type_spec = known_spec,
        }
    else
        implicitInfo(self, name);
    var symbol = Symbol.init(name, info.type_spec, &.{}, if (known_fn_spec != null) .function else .variable, .local);
    // Known function type is a hint from another unit, not a local explicit declaration.
    symbol.type_explicit = false;
    return internSymbol(self, symbol);
}

// ensureDeclaredSymbol is for declaration targets (type/dimension/parameter/external/intrinsic/save names).
// It intentionally ignores host-associated symbols so local declarations can shadow host names.
pub fn ensureDeclaredSymbol(self: *context.Context, name: []const u8) !usize {
    if (self.current_scope == null) return error.MissingScope;
    if (findCurrentScopeSymbolIndex(self, name)) |idx| {
        return idx;
    }

    const info = implicitInfo(self, name);
    const symbol = Symbol.init(name, info.type_spec, &.{}, .variable, .local);
    return internSymbol(self, symbol);
}

pub fn installAliasSymbol(
    self: *context.Context,
    name: []const u8,
    spec: TypeSpec,
    rank: usize,
    alias_definable: bool,
    attrs: AliasAttrs,
) !usize {
    const dims: []*ast.Expr = if (rank == 0) &.{} else blk: {
        const out = try self.arena.alloc(*ast.Expr, rank);
        var idx: usize = 0;
        while (idx < rank) : (idx += 1) {
            const dim_expr = try self.arena.create(ast.Expr);
            dim_expr.* = .{ .literal = .{ .kind = .integer, .text = "1" } };
            out[idx] = dim_expr;
        }
        break :blk out;
    };
    var symbol = Symbol.init(name, spec, dims, .variable, .local);
    symbol.type_explicit = true;
    symbol.is_alias = true;
    symbol.alias_definable = alias_definable;
    symbol.is_pointer = attrs.is_pointer;
    symbol.is_target = attrs.is_target;
    return internSymbol(self, symbol);
}

pub fn aliasAttrsForSelector(self: *context.Context, expr: *ast.Expr) AliasAttrs {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = findSymbolIndex(self, name) orelse break :blk .{};
            const sym = self.symbols.items[idx];
            break :blk .{
                .is_pointer = sym.is_pointer,
                .is_target = sym.is_target,
            };
        },
        .component => |comp| aliasAttrsForSelector(self, comp.base),
        .substring => |sub| blk: {
            const idx = findSymbolIndex(self, sub.name) orelse break :blk .{};
            const sym = self.symbols.items[idx];
            break :blk .{
                .is_pointer = sym.is_pointer,
                .is_target = sym.is_target,
            };
        },
        .call_or_subscript => |call| blk: {
            const idx = findSymbolIndex(self, call.name) orelse break :blk .{};
            const sym = self.symbols.items[idx];
            const kind = self.ref_kind_index.get(@intFromPtr(expr)) orelse
                (if (sym.dims.len > 0) ResolvedRefKind.subscript else ResolvedRefKind.call);
            if (kind != .subscript) break :blk .{};
            break :blk .{
                .is_pointer = sym.is_pointer,
                .is_target = sym.is_target,
            };
        },
        else => .{},
    };
}

pub fn internSymbol(self: *context.Context, symbol: Symbol) !usize {
    if (self.current_scope == null) return error.MissingScope;
    const scope_id = self.current_scope.?;
    const normalized = symbol.normalized();
    var key_owned: ?[]const u8 = null;
    var key_buf: [MAX_IDENT_LEN]u8 = undefined;
    if (normalized.name.len <= key_buf.len) {
        const key = toLowerInBuffer(normalized.name, &key_buf);
        if (self.scopes.items[scope_id.index].symbols.contains(key)) {
            return error.DuplicateDeclaration;
        }
    } else {
        const lookup_key = try lowerDup(self.arena, normalized.name);
        key_owned = lookup_key;
        if (self.scopes.items[scope_id.index].symbols.contains(lookup_key)) {
            return error.DuplicateDeclaration;
        }
    }
    const key = key_owned orelse try lowerDup(self.arena, normalized.name);
    const idx = self.symbols.items.len;
    try self.symbols.append(normalized);
    try self.scopes.items[scope_id.index].symbols.put(key, idx);
    self.invalidateSymbolLookupCache();
    return idx;
}

pub fn findSymbolIndex(self: *context.Context, name: []const u8) ?usize {
    if (self.current_scope == null) return null;
    if (self.symbol_lookup_cache_scope == null or self.symbol_lookup_cache_scope.?.index != self.current_scope.?.index) {
        self.symbol_lookup_cache.clearRetainingCapacity();
        self.symbol_lookup_cache_scope = self.current_scope;
    }
    if (getLowercaseMapValue(?usize, &self.symbol_lookup_cache, name)) |cached| {
        return cached;
    }
    const resolved = findSymbolIndexNoCache(self, name);
    putSymbolLookupCache(self, name, resolved);
    return resolved;
}

fn putSymbolLookupCache(self: *context.Context, name: []const u8, resolved: ?usize) void {
    // Fortran identifiers are typically short; avoid arena churn for rare long keys.
    if (name.len > MAX_IDENT_LEN) return;
    var key_buf: [MAX_IDENT_LEN]u8 = undefined;
    const key = toLowerInBuffer(name, &key_buf);
    if (self.symbol_lookup_cache.contains(key)) return;
    const owned_key = self.arena.dupe(u8, key) catch return;
    self.symbol_lookup_cache.put(owned_key, resolved) catch {};
}

fn findSymbolIndexNoCache(self: *context.Context, name: []const u8) ?usize {
    var scope_id = self.current_scope;
    while (scope_id) |id| {
        if (getLowercaseMapValue(usize, &self.scopes.items[id.index].symbols, name)) |idx| return idx;
        scope_id = self.scopes.items[id.index].parent;
    }
    return null;
}

fn findCurrentScopeSymbolIndex(self: *context.Context, name: []const u8) ?usize {
    const scope_id = self.current_scope orelse return null;
    return getLowercaseMapValue(usize, &self.scopes.items[scope_id.index].symbols, name);
}

const ImplicitInfo = struct {
    type_spec: TypeSpec,
};

fn implicitInfo(self: *context.Context, name: []const u8) ImplicitInfo {
    if (name.len == 0) return .{
        .type_spec = TypeSpec.fromResolvedKind(.real, .real, null),
    };
    const first = std.ascii.toUpper(name[0]);
    var idx = self.implicit.items.len;
    while (idx > 0) {
        idx -= 1;
        const rule = self.implicit.items[idx];
        if (first >= rule.start and first <= rule.end) return .{ .type_spec = rule.type_spec };
    }
    return .{
        .type_spec = TypeSpec.fromResolvedKind(.real, .real, null),
    };
}

pub fn implicitType(self: *context.Context, name: []const u8) ast.TypeKind {
    return implicitInfo(self, name).type_spec.lowered_kind;
}

pub fn implicitTypeSpec(self: *context.Context, name: []const u8) TypeSpec {
    return implicitInfo(self, name).type_spec;
}

pub fn implicitCharLen(self: *context.Context, name: []const u8) ?usize {
    return implicitInfo(self, name).type_spec.char_len;
}

pub fn isIntrinsicName(name: []const u8) bool {
    return intrinsics.isIntrinsicName(name);
}

fn findKnownHostParameter(self: *context.Context, name: []const u8) ?Symbol {
    return getLowercaseMapValue(Symbol, self.known_host_parameters, name);
}

pub fn lookupHostAssociatedParameter(self: *context.Context, name: []const u8) ?Symbol {
    return findKnownHostParameter(self, name);
}

fn putBuiltinConstant(
    self: *context.Context,
    module_name: []const u8,
    name: []const u8,
    type_spec: TypeSpec,
    value: symbols.ConstValue,
) !void {
    const key = try case_insensitive.lowerDup(self.arena, name);
    try self.builtin_constants.put(key, .{
        .module_name = module_name,
        .type_spec = type_spec,
        .value = value,
    });
}

pub fn lookupKnownFunctionResolvedSpec(self: *context.Context, name: []const u8) ?TypeSpec {
    return lookupKnownFunctionTypeSpec(self, name);
}

pub fn lookupKnownFunctionTypeSpec(self: *context.Context, name: []const u8) ?TypeSpec {
    if (getLowercaseMapValue(?TypeSpec, &self.known_function_type_spec_cache, name)) |cached| {
        return cached;
    }
    const resolved = lookupQualifiedKnownFunctionTypeSpec(self, name) orelse
        getLowercaseMapValue(TypeSpec, self.known_function_type_specs, name) orelse
        lookupVisibleQualifiedKnownFunctionTypeSpec(self, name);
    putKnownFunctionTypeSpecCache(self, name, resolved);
    return resolved;
}

pub fn lookupKnownProcedureSig(self: *context.Context, name: []const u8) ?context.Context.ProcedureSig {
    if (getLowercaseMapValue(?context.Context.ProcedureSig, &self.known_procedure_sig_cache, name)) |cached| {
        return cached;
    }
    const prefer_unqualified = self.unit.is_module_procedure and std.ascii.eqlIgnoreCase(name, self.unit.name);
    const resolved = if (prefer_unqualified)
        (getLowercaseMapValue(context.Context.ProcedureSig, self.known_procedure_sigs, name) orelse
            lookupQualifiedKnownProcedureSig(self, name) orelse
            lookupVisibleQualifiedKnownProcedureSig(self, name))
    else
        (lookupQualifiedKnownProcedureSig(self, name) orelse
            getLowercaseMapValue(context.Context.ProcedureSig, self.known_procedure_sigs, name) orelse
            lookupVisibleQualifiedKnownProcedureSig(self, name));
    putKnownProcedureSigCache(self, name, resolved);
    return resolved;
}

pub fn lookupKnownFunctionTypeSpecInOwner(
    self: *context.Context,
    owner_name: []const u8,
    name: []const u8,
) ?TypeSpec {
    const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, name }) catch return null;
    return getLowercaseMapValue(TypeSpec, self.known_function_type_specs, qualified);
}

pub fn lookupKnownProcedureSigInOwner(
    self: *context.Context,
    owner_name: []const u8,
    name: []const u8,
) ?context.Context.ProcedureSig {
    const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, name }) catch return null;
    return getLowercaseMapValue(context.Context.ProcedureSig, self.known_procedure_sigs, qualified);
}

fn lookupQualifiedKnownFunctionTypeSpec(self: *context.Context, name: []const u8) ?TypeSpec {
    const owner_name = lexicalProcedureLookupOwner(self) orelse return null;
    const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, name }) catch return null;
    return getLowercaseMapValue(TypeSpec, self.known_function_type_specs, qualified);
}

fn lookupQualifiedKnownProcedureSig(self: *context.Context, name: []const u8) ?context.Context.ProcedureSig {
    const owner_name = lexicalProcedureLookupOwner(self) orelse return null;
    const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, name }) catch return null;
    return getLowercaseMapValue(context.Context.ProcedureSig, self.known_procedure_sigs, qualified);
}

fn lookupVisibleQualifiedKnownFunctionTypeSpec(self: *context.Context, name: []const u8) ?TypeSpec {
    var match: ?TypeSpec = null;
    var it = self.known_function_type_specs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const sep = std.mem.lastIndexOf(u8, key, "::") orelse continue;
        if (!std.ascii.eqlIgnoreCase(key[sep + 2 ..], name)) continue;
        if (match != null) return null;
        match = entry.value_ptr.*;
    }
    return match;
}

fn lookupVisibleQualifiedKnownProcedureSig(self: *context.Context, name: []const u8) ?context.Context.ProcedureSig {
    var match: ?context.Context.ProcedureSig = null;
    var it = self.known_procedure_sigs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const sep = std.mem.lastIndexOf(u8, key, "::") orelse continue;
        if (!std.ascii.eqlIgnoreCase(key[sep + 2 ..], name)) continue;
        if (match != null) return null;
        match = entry.value_ptr.*;
    }
    return match;
}

fn lexicalProcedureLookupOwner(self: *context.Context) ?[]const u8 {
    return self.unit.owner_name orelse self.unit.name;
}

fn putKnownFunctionTypeSpecCache(self: *context.Context, name: []const u8, resolved: ?TypeSpec) void {
    if (name.len > MAX_IDENT_LEN) return;
    var key_buf: [MAX_IDENT_LEN]u8 = undefined;
    const key = toLowerInBuffer(name, &key_buf);
    if (self.known_function_type_spec_cache.contains(key)) return;
    const owned_key = self.arena.dupe(u8, key) catch return;
    self.known_function_type_spec_cache.put(owned_key, resolved) catch {};
}

fn putKnownProcedureSigCache(
    self: *context.Context,
    name: []const u8,
    resolved: ?context.Context.ProcedureSig,
) void {
    if (name.len > MAX_IDENT_LEN) return;
    var key_buf: [MAX_IDENT_LEN]u8 = undefined;
    const key = toLowerInBuffer(name, &key_buf);
    if (self.known_procedure_sig_cache.contains(key)) return;
    const owned_key = self.arena.dupe(u8, key) catch return;
    self.known_procedure_sig_cache.put(owned_key, resolved) catch {};
}

fn toLowerInBuffer(text: []const u8, buf: *[MAX_IDENT_LEN]u8) []const u8 {
    std.debug.assert(text.len <= buf.len);
    for (text, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..text.len];
}

fn getLowercaseMapValue(
    comptime T: type,
    map: *const std.StringHashMap(T),
    name: []const u8,
) ?T {
    var key_buf: [MAX_IDENT_LEN]u8 = undefined;
    if (name.len <= key_buf.len) {
        const key = toLowerInBuffer(name, &key_buf);
        return map.get(key);
    }

    // Long identifiers are rare; avoid arena allocation by scanning map keys.
    var it = map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len != name.len) continue;
        if (std.ascii.eqlIgnoreCase(key, name)) return entry.value_ptr.*;
    }
    return null;
}
