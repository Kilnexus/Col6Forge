const std = @import("std");
const input = @import("../../../input.zig");
const ir = @import("../../../ir.zig");
const utils = @import("../utils.zig");
const case_insensitive = @import("../../../../common/case_insensitive.zig");

const IRType = ir.IRType;
const FormatItem = input.FormatItem;

pub const CaseInsensitiveStringContext = case_insensitive.StringContext;

pub fn CaseInsensitiveStringHashMap(comptime V: type) type {
    return case_insensitive.HashMap(V);
}

pub const IRDecl = struct {
    ret_type: IRType,
    sig: []const u8,
    varargs: bool,
};

pub const CodegenOptions = struct {
    pub const PauseMode = enum(u8) {
        auto = 0,
        continue_ = 1,
        stop = 2,
    };

    bounds_check: bool = false,
    pause_mode: PauseMode = .auto,
    target: ?[]const u8 = null,
    target_layout: input.sema.TargetLayout = .{},
    known_procedure_sigs: []const input.sema.KnownProcedureSig = &.{},
};

pub const FormatInfo = struct {
    items: []const FormatItem,
    global_name: []const u8,
    string_len: usize,
};

pub const ValueRef = utils.ValueRef;

pub const StatementFunction = struct {
    params: []const []const u8,
    expr: *input.Expr,
};

pub const StatementFunctionSubst = struct {
    params: []const []const u8,
    actuals: []*input.Expr,
};

pub const BranchTarget = struct {
    index: i64,
    target_block: []const u8,
};

pub const BranchWorkspace = struct {
    unique_targets: std.array_list.Managed(BranchTarget),
    destination_blocks: std.array_list.Managed([]const u8),
    seen_values: std.AutoHashMap(i64, void),
    seen_blocks: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) BranchWorkspace {
        return .{
            .unique_targets = std.array_list.Managed(BranchTarget).init(allocator),
            .destination_blocks = std.array_list.Managed([]const u8).init(allocator),
            .seen_values = std.AutoHashMap(i64, void).init(allocator),
            .seen_blocks = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *BranchWorkspace) void {
        self.unique_targets.deinit();
        self.destination_blocks.deinit();
        self.seen_values.deinit();
        self.seen_blocks.deinit();
    }

    pub fn reset(self: *BranchWorkspace) void {
        self.unique_targets.clearRetainingCapacity();
        self.destination_blocks.clearRetainingCapacity();
        self.seen_values.clearRetainingCapacity();
        self.seen_blocks.clearRetainingCapacity();
    }
};

pub const RuntimeArrayDescriptor = struct {
    rank: usize,
    lower_slots: []ValueRef,
    extent_slots: []ValueRef,
    multiplier_slots: []ValueRef,
};

pub const DerivedComponentLayout = struct {
    name: []const u8,
    type_spec: input.TypeSpec,
    dims: []*input.Expr = &.{},
    pointer: bool = false,
    allocatable: bool = false,
    procedure: bool = false,
    procedure_sig: ?input.sema.KnownProcedureSig = null,
    procedure_nopass: bool = false,
    procedure_pass_name: ?[]const u8 = null,
    offset: usize,
    elem_size: usize,
    size: usize,
    alignment: usize,
};

pub const DerivedTypeLayout = struct {
    name: []const u8,
    parent_name: ?[]const u8 = null,
    components: []const DerivedComponentLayout,
    size: usize,
    alignment: usize,
};

pub const DerivedBindingInfo = struct {
    name: []const u8,
    owner_name: ?[]const u8 = null,
    owner_kind: ?input.LexicalOwnerKind = null,
    interface_name: ?[]const u8 = null,
    implementation_name: ?[]const u8 = null,
    deferred: bool = false,
    nopass: bool = false,
    pass_name: ?[]const u8 = null,
    non_overridable: bool = false,
};

pub const IntrinsicWrapperKind = enum {
    iabs,
    sin,
    dcos,
    dcosh,
    dexp,
    conjg,
};

pub const StringPool = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    names: std.StringHashMap([]const u8),
    items: std.array_list.Managed(StringEntry),
    counter: usize,

    const StringEntry = struct {
        name: []const u8,
        bytes: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) StringPool {
        var pool: StringPool = undefined;
        pool.allocator = allocator;
        pool.arena = std.heap.ArenaAllocator.init(allocator);
        pool.names = std.StringHashMap([]const u8).init(allocator);
        pool.items = std.array_list.Managed(StringEntry).init(allocator);
        pool.counter = 0;
        return pool;
    }

    pub fn deinit(self: *StringPool) void {
        self.names.deinit();
        self.items.deinit();
        self.arena.deinit();
    }

    pub fn intern(self: *StringPool, bytes: []const u8) ![]const u8 {
        if (self.names.get(bytes)) |name| return name;
        const pool_allocator = self.arena.allocator();
        const key = try pool_allocator.dupe(u8, bytes);
        const name = try std.fmt.allocPrint(pool_allocator, "str{d}", .{self.counter});
        self.counter += 1;
        try self.names.put(key, name);
        try self.items.append(.{ .name = name, .bytes = key });
        return name;
    }
};
