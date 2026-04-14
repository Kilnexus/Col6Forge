const expr_nodes = @import("expr.zig");

const Expr = expr_nodes.Expr;

pub const TypeKind = enum {
    integer,
    real,
    double_precision,
    complex,
    complex_double,
    logical,
    character,
    derived,
};

pub const Decl = union(enum) {
    implicit: ImplicitDecl,
    type_decl: TypeDecl,
    bind_entity: BindEntityDecl,
    procedure: ProcedureDecl,
    derived_type_def: DerivedTypeDef,
    interface_block: InterfaceBlock,
    import: NameListDecl,
    intent: IntentDecl,
    optional: NameListDecl,
    dimension: DimensionDecl,
    parameter: ParameterDecl,
    common: CommonDecl,
    equivalence: EquivalenceDecl,
    external: NameListDecl,
    intrinsic: NameListDecl,
    save: SaveDecl,
};

pub const TypeDecl = struct {
    type_kind: TypeKind,
    kind_selector: ?*Expr = null,
    derived_type_name: ?[]const u8 = null,
    polymorphic: bool = false,
    assumed_type: bool = false,
    items: []Declarator,
    parameter: bool = false,
    save: bool = false,
    allocatable: bool = false,
    pointer: bool = false,
    optional: bool = false,
    intent: ?IntentKind = null,
    external: bool = false,
    asynchronous: bool = false,
    contiguous: bool = false,
    value_attr: bool = false,
    volatile_attr: bool = false,
    bind_c: bool = false,
    bind_name_expr: ?*Expr = null,
};

pub const BindEntityDecl = struct {
    names: []const []const u8,
    common_blocks: []const []const u8 = &.{},
    bind_name_expr: ?*Expr = null,
};

pub const ProcedureTypeSpec = struct {
    type_kind: TypeKind,
    kind_selector: ?*Expr = null,
    derived_type_name: ?[]const u8 = null,
    polymorphic: bool = false,
    assumed_type: bool = false,
};

pub const ProcedureInterface = union(enum) {
    none,
    name: []const u8,
    type_spec: ProcedureTypeSpec,
};

pub const ProcedureDecl = struct {
    interface: ProcedureInterface = .none,
    items: []Declarator,
    pointer: bool = false,
    optional: bool = false,
    save: bool = false,
    nopass: bool = false,
    pass_name: ?[]const u8 = null,
    private: bool = false,
};

pub const InterfaceProcedure = struct {
    kind: @import("program.zig").ProgramUnitKind,
    name: []const u8,
    source: @import("program.zig").DeclSource = .{},
    end_source: @import("program.zig").DeclSource = .{},
    pure: bool = false,
    elemental: bool = false,
    recursive: bool = false,
    bind_c: bool = false,
    bind_name: ?[]const u8 = null,
    result_name: ?[]const u8 = null,
    args: []const []const u8,
    alt_return_dummy_count: usize = 0,
    type_spec: ?ProcedureTypeSpec = null,
    decls: []const Decl = &.{},
    decl_sources: []const @import("program.zig").DeclSource = &.{},
};

pub const DerivedTypeDef = struct {
    name: []const u8,
    parent_name: ?[]const u8 = null,
    abstract: bool = false,
    sequence: bool = false,
    bind_c: bool = false,
    components: []const TypeDecl = &.{},
    component_sources: []const @import("program.zig").DeclSource = &.{},
    procedure_components: []const ProcedureDecl = &.{},
    procedure_component_sources: []const @import("program.zig").DeclSource = &.{},
    bindings: []const TypeBoundProcedureBinding = &.{},
};

pub const TypeBoundProcedureBinding = struct {
    name: []const u8,
    owner_name: ?[]const u8 = null,
    owner_kind: ?@import("program.zig").LexicalOwnerKind = null,
    source: @import("program.zig").DeclSource = .{},
    is_generic: bool = false,
    interface_name: ?[]const u8 = null,
    implementation_name: ?[]const u8 = null,
    deferred: bool = false,
    nopass: bool = false,
    pass_name: ?[]const u8 = null,
    private: bool = false,
    non_overridable: bool = false,
    syntax_error_message: ?[]const u8 = null,
};

pub const InterfaceBlock = struct {
    abstract: bool = false,
    name: ?[]const u8 = null,
    module_procedures: []const []const u8 = &.{},
    module_procedure_sources: []const @import("program.zig").DeclSource = &.{},
    specific_procedures: []const []const u8 = &.{},
    specific_procedure_sources: []const @import("program.zig").DeclSource = &.{},
    procedures: []const []const u8 = &.{},
    procedure_sources: []const @import("program.zig").DeclSource = &.{},
    procedure_headers: []const InterfaceProcedure = &.{},
};

pub const DimensionDecl = struct {
    items: []Declarator,
    allocatable: bool = false,
    pointer: bool = false,
};

pub const ParameterDecl = struct {
    assigns: []ParamAssign,
};

pub const ParamAssign = struct {
    name: []const u8,
    value: *Expr,
};

pub const CommonDecl = struct {
    blocks: []CommonBlock,
};

pub const CommonBlock = struct {
    name: ?[]const u8,
    items: []Declarator,
};

pub const EquivalenceDecl = struct {
    groups: []EquivalenceGroup,
};

pub const EquivalenceGroup = struct {
    items: []*Expr,
};

pub const ImplicitDecl = struct {
    rules: []ImplicitRule,
};

pub const ImplicitRule = struct {
    start: u8,
    end: u8,
    type_kind: TypeKind,
    kind_selector: ?*Expr = null,
    char_len: ?*Expr,
    derived_type_name: ?[]const u8 = null,
    polymorphic: bool = false,
};

pub const NameListDecl = struct {
    names: []const []const u8,
};

pub const IntentKind = enum {
    in,
    out,
    inout,
};

pub const IntentDecl = struct {
    kind: IntentKind,
    names: []const []const u8,
};

pub const SaveItem = union(enum) {
    name: []const u8,
    common: ?[]const u8,
};

pub const SaveDecl = struct {
    items: []SaveItem,
    save_all: bool,
};

pub const Declarator = struct {
    name: []const u8,
    dims: []*Expr,
    char_len: ?*Expr,
    char_len_deferred: bool = false,
    no_arg_check: bool = false,
    init: ?*Expr = null,
};
