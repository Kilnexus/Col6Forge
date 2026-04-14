const ast = @import("../../../ast/nodes.zig");
const context = @import("../token_stream.zig");

pub const LineParser = context.LineParser;
pub const TypeKind = ast.TypeKind;
pub const Decl = ast.Decl;
pub const BindEntityDecl = ast.BindEntityDecl;
pub const ParamAssign = ast.ParamAssign;
pub const CommonBlock = ast.CommonBlock;
pub const EquivalenceGroup = ast.EquivalenceGroup;
pub const ImplicitRule = ast.ImplicitRule;
pub const Declarator = ast.Declarator;

pub const ImplicitTypeSpec = struct {
    type_kind: TypeKind,
    kind_selector: ?*ast.Expr,
    char_len: ?*ast.Expr,
    derived_type_name: ?[]const u8 = null,
    polymorphic: bool = false,
};

pub const ParsedTypeSpec = struct {
    type_kind: TypeKind,
    kind_selector: ?*ast.Expr = null,
    char_len: ?*ast.Expr = null,
    char_len_deferred: bool = false,
    derived_type_name: ?[]const u8 = null,
    polymorphic: bool = false,
    assumed_type: bool = false,
    legacy_star_kind: bool = false,
    invalid_bare_double: bool = false,
};

pub const ParsedCharacterLen = struct {
    expr: ?*ast.Expr = null,
    deferred: bool = false,
    kind_selector: ?*ast.Expr = null,
};

pub const DeclAttributes = struct {
    parameter: bool = false,
    dimension: ?[]*ast.Expr = null,
    save: bool = false,
    allocatable: bool = false,
    pointer: bool = false,
    optional: bool = false,
    nopass: bool = false,
    pass_name: ?[]const u8 = null,
    private: bool = false,
    intent: ?ast.IntentKind = null,
    external: bool = false,
    asynchronous: bool = false,
    contiguous: bool = false,
    value_attr: bool = false,
    volatile_attr: bool = false,
    bind_c: bool = false,
    bind_name_expr: ?*ast.Expr = null,
};

pub const LegacyStarSplit = struct {
    selector_end: usize,
    suffix_start: usize,
};
