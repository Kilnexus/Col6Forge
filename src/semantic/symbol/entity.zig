const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const type_spec = @import("../type_spec.zig");

pub const SymbolKind = enum {
    variable,
    parameter,
    function,
    subroutine,
};

pub const StorageClass = enum {
    local,
    common,
    dummy,
};

pub const CharacterLengthKind = type_spec.CharacterLengthKind;
pub const TypeSpec = type_spec.TypeSpec;

pub const Symbol = struct {
    pub const CompatMirrors = struct {
        type_kind: ast.TypeKind,
        char_len_kind: CharacterLengthKind = .none,
        char_len: ?usize = null,
    };

    name: []const u8,
    type_spec: TypeSpec = TypeSpec.fromKind(.real),
    dims: []*ast.Expr,
    // Compatibility mirrors for older callers and serialized fixtures.
    // Semantic/codegen behavior must read from `type_spec` through helpers.
    compat: CompatMirrors,
    kind: SymbolKind,
    storage: StorageClass,
    is_external: bool,
    is_intrinsic: bool,
    is_allocatable: bool = false,
    is_pointer: bool = false,
    is_target: bool = false,
    contiguous: bool = false,
    no_arg_check: bool = false,
    // Internal compiler-generated temporaries (e.g. intrinsic array-conversion buffers).
    // Backends may choose a dedicated storage strategy for these symbols.
    is_generated_temp: bool = false,
    // Compiler-synthesized ASSOCIATE/SELECT TYPE alias symbol.
    // These aliases may be rewritten away before codegen.
    is_alias: bool = false,
    // Whether an alias is definable in variable-definition contexts.
    // Only meaningful when `is_alias` is true.
    alias_definable: bool = true,
    const_value: ?ConstValue,
    type_explicit: bool,
    is_host_associated: bool = false,
    host_owner_name: ?[]const u8 = null,

    pub fn assertCompatInvariant(self: Symbol) void {
        std.debug.assert(self.compat.type_kind == self.type_spec.lowered_kind);
        if (self.type_spec.lowered_kind == .character) {
            std.debug.assert(self.compat.char_len_kind == self.type_spec.char_len_kind);
            std.debug.assert(self.compat.char_len == self.type_spec.char_len);
        } else {
            std.debug.assert(self.compat.char_len_kind == .none);
            std.debug.assert(self.compat.char_len == null);
        }
    }

    pub fn normalizeCompatMirrors(self: *Symbol) void {
        self.compat.type_kind = self.type_spec.lowered_kind;
        if (self.type_spec.lowered_kind == .character) {
            self.compat.char_len_kind = self.type_spec.char_len_kind;
            self.compat.char_len = self.type_spec.char_len;
        } else {
            self.compat.char_len_kind = .none;
            self.compat.char_len = null;
        }
        self.assertCompatInvariant();
    }

    pub fn normalized(self: Symbol) Symbol {
        var out = self;
        out.normalizeCompatMirrors();
        return out;
    }

    pub fn loweredKind(self: Symbol) ast.TypeKind {
        return self.type_spec.lowered_kind;
    }

    pub fn isCharacter(self: Symbol) bool {
        return self.type_spec.lowered_kind == .character;
    }

    pub fn effectiveCharLen(self: Symbol) ?usize {
        if (!self.isCharacter()) return null;
        return self.type_spec.char_len;
    }

    pub fn effectiveCharLenKind(self: Symbol) CharacterLengthKind {
        if (!self.isCharacter()) return .none;
        return self.type_spec.char_len_kind;
    }

    pub fn applyTypeSpec(self: *Symbol, spec: TypeSpec) void {
        self.type_spec = spec;
        self.normalizeCompatMirrors();
    }

    pub fn init(
        name: []const u8,
        spec: TypeSpec,
        dims: []*ast.Expr,
        kind: SymbolKind,
        storage: StorageClass,
    ) Symbol {
        var sym = Symbol{
            .name = name,
            .type_spec = spec,
            .dims = dims,
            .compat = .{ .type_kind = spec.lowered_kind },
            .kind = kind,
            .storage = storage,
            .is_external = false,
            .is_intrinsic = false,
            .is_allocatable = false,
            .is_pointer = false,
            .is_target = false,
            .is_alias = false,
            .alias_definable = true,
            .const_value = null,
            .type_explicit = false,
        };
        sym.applyTypeSpec(spec);
        sym.assertCompatInvariant();
        return sym;
    }
};

pub const EntityKind = enum {
    symbol,
    scope,
    unit,
    unknown,
};

pub const EntityPayload = union(EntityKind) {
    symbol: Symbol,
    scope: void,
    unit: void,
    unknown: void,
};

pub const RealConst = struct {
    value: f64,
    is_double: bool = false,
};

pub const ComplexConst = struct {
    real: f64,
    imag: f64,
    is_double: bool = false,
};

pub const ConstValue = union(enum) {
    integer: i64,
    real: RealConst,
    complex: ComplexConst,
    logical: bool,
    // Decoded character bytes (without quotes/Hollerith prefix).
    string: []const u8,
};

pub const ImplicitRule = struct {
    start: u8,
    end: u8,
    type_spec: TypeSpec = TypeSpec.fromKind(.real),

    pub fn init(start: u8, end: u8, spec: TypeSpec) ImplicitRule {
        return .{
            .start = start,
            .end = end,
            .type_spec = spec,
        };
    }
};

pub const ResolvedRefKind = enum {
    call,
    subscript,
    unknown,
};

pub const ResolvedRef = struct {
    expr: *ast.Expr,
    name: []const u8,
    kind: ResolvedRefKind,
};

pub const SemanticUnit = struct {
    name: []const u8,
    kind: ast.ProgramUnitKind,
    symbols: []Symbol,
    implicit_rules: []ImplicitRule,
    resolved_refs: []ResolvedRef,
};

pub const SemanticProgram = struct {
    units: []SemanticUnit,
};
