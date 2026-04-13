const expr_nodes = @import("expr.zig");
const format_nodes = @import("format.zig");

const Expr = expr_nodes.Expr;
const FormatItem = format_nodes.FormatItem;
const FormatSpec = format_nodes.FormatSpec;
const SourceRef = expr_nodes.SourceRef;

pub const Stmt = struct {
    label: ?[]const u8,
    node: StmtNode,
    source_line: usize = 0,
    source_column: usize = 0,
    source_text: []const u8 = "",
};

pub const StmtNode = union(enum) {
    assignment: Assignment,
    pointer_assignment: PointerAssignment,
    nullify: NullifyStmt,
    associate_block: AssociateBlock,
    select_type_block: SelectTypeBlock,
    orphan_select_type_clause: SelectTypeClause,
    assign_label: AssignLabelStmt,
    use_stmt: UseStmt,
    call: CallStmt,
    goto: GotoStmt,
    computed_goto: ComputedGotoStmt,
    assigned_goto: AssignedGotoStmt,
    write: WriteStmt,
    read: ReadStmt,
    rewind: RewindStmt,
    backspace: BackspaceStmt,
    endfile: EndfileStmt,
    open: OpenStmt,
    inquire: InquireStmt,
    close: CloseStmt,
    allocate: AllocateStmt,
    deallocate: DeallocateStmt,
    data: DataStmt,
    format: FormatStmt,
    arith_if: ArithIfStmt,
    pause: PauseStmt,
    stop: void,
    do_loop: DoLoopStmt,
    do_while: DoWhileStmt,
    do_infinite: DoInfiniteStmt,
    ret: ReturnStmt,
    cont: void,
    entry: EntryStmt,
    if_single: IfSingle,
    if_block: IfBlock,
    where_stmt: WhereStmt,
};

pub const Assignment = struct {
    target: *Expr,
    value: *Expr,
};

pub const PointerAssignment = struct {
    target: *Expr,
    value: *Expr,
};

pub const NullifyStmt = struct {
    items: []*Expr,
};

pub const AssociateBinding = struct {
    name: []const u8,
    selector: *Expr,
};

pub const AssociateBlock = struct {
    bindings: []AssociateBinding,
    stmts: []Stmt,
    select_rank: ?SelectRankInfo = null,
};

pub const SelectRankClauseKind = enum {
    rank_value,
    rank_star,
    rank_default,
};

pub const SelectRankClause = struct {
    kind: SelectRankClauseKind,
    rank_expr: ?*Expr = null,
    stmts: []Stmt = &.{},
    source: SourceRef = .{},
};

pub const SelectRankInfo = struct {
    construct_name: ?[]const u8 = null,
    clauses: []const SelectRankClause = &.{},
    end_source: SourceRef = .{},
};

pub const SelectTypeClauseKind = enum {
    type_is,
    class_is,
    class_default,
};

pub const SelectTypeClause = struct {
    kind: SelectTypeClauseKind,
    type_kind: ?@import("decl.zig").TypeKind = null,
    kind_selector: ?*Expr = null,
    char_len: ?*Expr = null,
    char_len_deferred: bool = false,
    derived_type_name: ?[]const u8 = null,
    stmts: []Stmt,
    source: SourceRef = .{},
    trailing_name: ?[]const u8 = null,
    has_trailing_tokens: bool = false,
};

pub const SelectTypeBlock = struct {
    selector: *Expr,
    associate_name: ?[]const u8 = null,
    construct_name: ?[]const u8 = null,
    leading_stmts: []Stmt = &.{},
    clauses: []SelectTypeClause,
    end_source: SourceRef = .{},
};

pub const AssignLabelStmt = struct {
    label: []const u8,
    target: []const u8,
};

pub const UseStmt = struct {
    module_name: []const u8,
    has_only: bool = false,
    only_items: []const UseOnlyItem,
    source: SourceRef = .{},
};

pub const UseOnlyItem = struct {
    local_name: []const u8,
    remote_name: []const u8,
    generic_spec: bool = false,
    generic_display_name: []const u8 = "",
};

pub const CallStmt = struct {
    name: []const u8,
    args: []CallArg,
    binding_base: ?*Expr = null,
    source: SourceRef = .{},
};

pub const ActualArgExpr = struct {
    keyword: ?[]const u8 = null,
    value: *Expr,
};

pub const CallArg = union(enum) {
    expr: ActualArgExpr,
    alt_return: []const u8,
};

pub const ReturnStmt = struct {
    value: ?*Expr,
};

pub const EntryStmt = struct {
    name: []const u8,
    args: []const []const u8,
    alt_return_dummy_count: usize = 0,
    result_name: ?[]const u8 = null,
};

pub const WriteStmt = struct {
    unit: *Expr,
    format: FormatSpec,
    rec: ?*Expr,
    args: []*Expr,
    err_label: ?[]const u8,
    iostat: ?*Expr,
};

pub const ReadStmt = struct {
    unit: *Expr,
    format: FormatSpec,
    rec: ?*Expr,
    args: []*Expr,
    err_label: ?[]const u8,
    end_label: ?[]const u8,
    iostat: ?*Expr,
};

pub const OpenStmt = struct {
    unit: *Expr,
    recl: ?*Expr,
    file: ?*Expr,
    access: ?*Expr,
    form: ?*Expr,
    blank: ?*Expr,
    status: ?*Expr,
    err_label: ?[]const u8,
    iostat: ?*Expr,
};

pub const InquireStmt = struct {
    controls: []ControlItem,
};

pub const CloseStmt = struct {
    controls: []ControlItem,
};

pub const AllocateTypeSpec = struct {
    type_kind: @import("decl.zig").TypeKind,
    kind_selector: ?*Expr = null,
    derived_type_name: ?[]const u8 = null,
    polymorphic: bool = false,
    char_len: ?*Expr = null,
    char_len_deferred: bool = false,
    source: SourceRef = .{},
    legacy_star_kind: bool = false,
    invalid_bare_double: bool = false,
};

pub const AllocationOptionKind = enum {
    stat,
    errmsg,
    source,
    mold,
};

pub const AllocationOption = struct {
    kind: AllocationOptionKind,
    value: *Expr,
    source: SourceRef = .{},
};

pub const AllocateStmt = struct {
    items: []AllocateItem,
    type_spec: ?AllocateTypeSpec = null,
    options: []AllocationOption = &.{},
};

pub const AllocateItem = struct {
    target: *Expr,
    dims: []*Expr,
    source: SourceRef = .{},
};

pub const DeallocateItem = struct {
    target: *Expr,
    source: SourceRef = .{},
};

pub const DeallocateStmt = struct {
    items: []DeallocateItem,
    options: []AllocationOption = &.{},
};

pub const ControlItem = struct {
    name: ?[]const u8,
    value: *Expr,
    source: SourceRef = .{},
};

pub const RewindStmt = struct {
    unit: *Expr,
    err_label: ?[]const u8,
    iostat: ?*Expr,
};

pub const BackspaceStmt = struct {
    unit: *Expr,
    err_label: ?[]const u8,
    iostat: ?*Expr,
};

pub const EndfileStmt = struct {
    unit: *Expr,
    err_label: ?[]const u8,
    iostat: ?*Expr,
};

pub const DataInit = struct {
    target: *Expr,
    value: *Expr,
    repeat_count: usize = 1,
};

pub const DataValueSpec = struct {
    value: *Expr,
    repeat: ?*Expr = null,
};

pub const DataGroup = struct {
    targets: []*Expr,
    values: []DataValueSpec,
};

pub const DataStmt = struct {
    inits: []DataInit = &.{},
    groups: []DataGroup = &.{},
};

pub const FormatStmt = struct {
    items: []FormatItem,
};

pub const IfSingle = struct {
    condition: *Expr,
    stmt: *StmtNode,
};

pub const IfBlock = struct {
    condition: *Expr,
    then_stmts: []Stmt,
    else_stmts: []Stmt,
};

pub const WhereStmt = struct {
    mask: *Expr,
    target: *Expr,
    value: *Expr,
};

pub const ArithIfStmt = struct {
    condition: *Expr,
    neg_label: []const u8,
    zero_label: []const u8,
    pos_label: []const u8,
};

pub const PauseStmt = struct {
    value: ?*Expr,
};

pub const GotoStmt = struct {
    label: []const u8,
};

pub const ComputedGotoStmt = struct {
    labels: []const []const u8,
    selector: *Expr,
};

pub const AssignedGotoStmt = struct {
    var_name: []const u8,
    labels: []const []const u8,
};

pub const DoLoopStmt = struct {
    end_label: []const u8,
    var_name: []const u8,
    start: *Expr,
    end: *Expr,
    step: ?*Expr,
};

pub const DoWhileStmt = struct {
    end_label: []const u8,
    condition: *Expr,
};

pub const DoInfiniteStmt = struct {
    end_label: []const u8,
};
