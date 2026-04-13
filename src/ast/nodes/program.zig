const decl_nodes = @import("decl.zig");
const expr_nodes = @import("expr.zig");
const stmt_nodes = @import("stmt.zig");

pub const Program = struct {
    units: []ProgramUnit,
};

pub const ProgramUnitKind = enum {
    module,
    program,
    subroutine,
    function,
    block_data,
};

pub const LexicalOwnerKind = enum {
    procedure,
    module,
};

pub const ProgramUnit = struct {
    kind: ProgramUnitKind,
    name: []const u8,
    source: DeclSource = .{},
    owner_name: ?[]const u8 = null,
    owner_kind: ?LexicalOwnerKind = null,
    is_module_procedure: bool = false,
    pure: bool = false,
    elemental: bool = false,
    recursive: bool = false,
    prelude_decl_count: usize = 0,
    bind_name: ?[]const u8 = null,
    result_name: ?[]const u8 = null,
    args: []const []const u8,
    alt_return_dummy_count: usize = 0,
    decls: []decl_nodes.Decl,
    decl_sources: []DeclSource = &.{},
    stmts: []stmt_nodes.Stmt,
    expr_sources: []expr_nodes.ExprSource = &.{},
};

pub const DeclSource = struct {
    line: usize = 0,
    column: usize = 0,
    text: []const u8 = "",
    owner_name: ?[]const u8 = null,
};
