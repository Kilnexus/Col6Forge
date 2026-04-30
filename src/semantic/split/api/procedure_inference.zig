const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const context = @import("../../context.zig");
const evaluator = @import("../../evaluator.zig");
const symbols = @import("../../symbol/mod.zig");
const literal_expr = @import("../../literal_expr.zig");
const shape_signatures = @import("procedure_inference/shape_signatures.zig");
const type_kind_selector = @import("../../type_kind_selector.zig");

pub const shapeSignatureForDims = shape_signatures.shapeSignatureForDims;

pub fn inferProcedureArgSigs(arena: std.mem.Allocator, unit: ast.ProgramUnit) ![]const context.Context.ProcedureSig.ArgSig {
    return inferProcedureArgSigsWithKnown(arena, unit, null);
}

pub fn inferProcedureArgSigsWithKnown(
    arena: std.mem.Allocator,
    unit: ast.ProgramUnit,
    known_procedure_sigs: ?*const std.StringHashMap(context.Context.ProcedureSig),
) anyerror![]const context.Context.ProcedureSig.ArgSig {
    const out = try arena.alloc(context.Context.ProcedureSig.ArgSig, unit.args.len);
    for (unit.args, 0..) |arg_name, idx| {
        const decl_info = findDummyArgDeclInfo(unit, arg_name);
        const declarator_sig = try resolveProcedureDeclaratorKnownSig(
            arena,
            unit,
            known_procedure_sigs,
            decl_info.procedure_interface,
            null,
        );
        const inferred_proc_kind = if (dummyArgCanInferProcedureFromUsage(decl_info))
            inferDummyArgProcedureKind(unit, arg_name)
        else
            null;
        const declarator = decl_info.declarator;
        const type_spec = inferDummyArgTypeSpec(unit.decls, unit, arg_name, declarator);
        const dims = if (declarator) |item| item.dims else &.{};
        out[idx] = .{
            .name = arg_name,
            .type_spec = type_spec,
            .requires_descriptor = dummyArgRequiresDescriptor(dims),
            .rank = dims.len,
            .assumed_rank = dummyArgIsAssumedRank(dims),
            .shape_signature = try shapeSignatureForDims(arena, dims),
            .pointer = decl_info.pointer,
            .allocatable = decl_info.allocatable,
            .optional = decl_info.optional,
            .intent = decl_info.intent,
            .asynchronous = decl_info.asynchronous,
            .contiguous = decl_info.contiguous,
            .value_attr = decl_info.value_attr,
            .volatile_attr = decl_info.volatile_attr,
            .no_arg_check = declarator != null and declarator.?.no_arg_check,
            .is_procedure = decl_info.interface_procedure != null or declarator_sig != null or decl_info.external or inferred_proc_kind != null,
            .procedure_kind = if (decl_info.interface_procedure) |proc|
                proc.kind
            else if (declarator_sig) |sig|
                sig.kind
            else if (inferred_proc_kind) |kind|
                kind
            else if (decl_info.external and decl_info.explicit_type)
                .function
            else
                null,
            .procedure_has_explicit_interface = decl_info.interface_procedure != null or declarator_sig != null,
            .procedure_pure = if (decl_info.interface_procedure) |proc| proc.pure else if (declarator_sig) |sig| sig.pure else false,
            .procedure_arg_count = if (decl_info.interface_procedure) |proc| proc.args.len else if (declarator_sig) |sig| sig.arg_count else 0,
            .procedure_alt_return_count = if (decl_info.interface_procedure) |proc| proc.alt_return_dummy_count else if (declarator_sig) |sig| sig.alt_return_count else 0,
            .procedure_result_type_spec = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultTypeSpec(unit, proc)
            else if (declarator_sig) |sig|
                sig.result_type_spec
            else if (inferred_proc_kind == .function and decl_info.explicit_type)
                type_spec
            else if (decl_info.external and decl_info.explicit_type)
                type_spec
            else
                null,
            .procedure_result_rank = if (decl_info.interface_procedure) |proc| interfaceProcedureResultRank(proc) else if (declarator_sig) |sig| sig.result_rank else 0,
            .procedure_result_shape_signature = if (decl_info.interface_procedure) |proc|
                try interfaceProcedureResultShapeSignature(arena, proc)
            else if (declarator_sig) |sig|
                sig.result_shape_signature
            else
                &.{},
            .procedure_result_pointer = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultAttrs(proc).pointer
            else if (declarator_sig) |sig|
                sig.is_pointer
            else
                false,
            .procedure_result_allocatable = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultAttrs(proc).allocatable
            else if (declarator_sig) |sig|
                sig.result_allocatable
            else
                false,
            .procedure_result_contiguous = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultAttrs(proc).contiguous
            else if (declarator_sig) |sig|
                sig.result_contiguous
            else
                false,
            .procedure_result_procedure_pointer = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultAttrs(proc).procedure_pointer
            else if (declarator_sig) |sig|
                sig.result_procedure_pointer
            else
                false,
            .procedure_dummy_sigs = if (decl_info.interface_procedure) |proc|
                try inferInterfaceProcedureArgSigs(arena, unit, proc)
            else if (declarator_sig) |sig|
                sig.args
            else
                &.{},
        };
    }
    return out;
}

const DummyArgDeclInfo = struct {
    declarator: ?ast.Declarator = null,
    pointer: bool = false,
    allocatable: bool = false,
    optional: bool = false,
    intent: ?ast.IntentKind = null,
    external: bool = false,
    explicit_type: bool = false,
    asynchronous: bool = false,
    contiguous: bool = false,
    value_attr: bool = false,
    volatile_attr: bool = false,
    interface_procedure: ?ast.InterfaceProcedure = null,
    procedure_interface: ast.ProcedureInterface = .none,
};

fn dummyArgCanInferProcedureFromUsage(info: DummyArgDeclInfo) bool {
    if (info.interface_procedure != null or info.external) return false;
    if (info.procedure_interface != .none) return false;
    if (info.declarator) |decl| {
        if (decl.dims.len != 0) return false;
    }
    return true;
}

fn findDummyArgDeclInfo(unit: ast.ProgramUnit, name: []const u8) DummyArgDeclInfo {
    return findDummyArgDeclInfoInDecls(unit.decls, name);
}

fn findDummyArgDeclInfoInDecls(decls: []const ast.Decl, name: []const u8) DummyArgDeclInfo {
    var dims_only: ?ast.Declarator = null;
    var info: DummyArgDeclInfo = .{};
    for (decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
                    info.declarator = item;
                    info.pointer = type_decl.pointer;
                    info.allocatable = type_decl.allocatable;
                    info.optional = type_decl.optional;
                    info.intent = type_decl.intent;
                    info.external = type_decl.external;
                    info.asynchronous = type_decl.asynchronous;
                    info.contiguous = type_decl.contiguous;
                    info.value_attr = type_decl.value_attr;
                    info.volatile_attr = type_decl.volatile_attr;
                    info.explicit_type = true;
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
                    info.declarator = item;
                    info.optional = procedure_decl.optional;
                    info.external = true;
                    info.procedure_interface = procedure_decl.interface;
                    info.explicit_type = procedure_decl.interface == .type_spec;
                }
            },
            .intent => |intent_decl| {
                for (intent_decl.names) |intent_name| {
                    if (!std.ascii.eqlIgnoreCase(intent_name, name)) continue;
                    info.intent = intent_decl.kind;
                }
            },
            .optional => |optional_decl| {
                for (optional_decl.names) |optional_name| {
                    if (!std.ascii.eqlIgnoreCase(optional_name, name)) continue;
                    info.optional = true;
                }
            },
            .value => |value_decl| {
                for (value_decl.names) |value_name| {
                    if (!std.ascii.eqlIgnoreCase(value_name, name)) continue;
                    info.value_attr = true;
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
                    dims_only = item;
                    info.pointer = dimension_decl.pointer;
                    info.allocatable = dimension_decl.allocatable;
                }
            },
            .external => |ext_decl| {
                for (ext_decl.names) |ext_name| {
                    if (!std.ascii.eqlIgnoreCase(ext_name, name)) continue;
                    info.external = true;
                }
            },
            .interface_block => |interface_block| {
                for (interface_block.procedure_headers) |proc_header| {
                    if (!std.ascii.eqlIgnoreCase(proc_header.name, name)) continue;
                    info.interface_procedure = proc_header;
                }
            },
            else => {},
        }
    }
    if (dims_only) |dims_decl| {
        if (info.declarator) |decl_item| {
            if (decl_item.dims.len == 0 and dims_decl.dims.len != 0) {
                var merged = decl_item;
                merged.dims = dims_decl.dims;
                info.declarator = merged;
            }
        } else {
            info.declarator = dims_decl;
        }
    }
    return info;
}

pub fn inferInterfaceProcedureArgSigs(
    arena: std.mem.Allocator,
    unit: ast.ProgramUnit,
    proc_header: ast.InterfaceProcedure,
) anyerror![]const context.Context.ProcedureSig.ArgSig {
    const out = try arena.alloc(context.Context.ProcedureSig.ArgSig, proc_header.args.len);
    for (proc_header.args, 0..) |arg_name, idx| {
        const active_decls = if (proc_header.decls.len != 0) proc_header.decls else unit.decls;
        const decl_info = findDummyArgDeclInfoInDecls(active_decls, arg_name);
        const declarator_sig = try resolveProcedureDeclaratorKnownSig(
            arena,
            unit,
            null,
            decl_info.procedure_interface,
            proc_header.name,
        );
        const inferred_proc_kind = if (dummyArgCanInferProcedureFromUsage(decl_info))
            inferDummyArgProcedureKindInStmts(unit.stmts, arg_name)
        else
            null;
        const declarator = decl_info.declarator;
        const type_spec = inferDummyArgTypeSpec(active_decls, unit, arg_name, declarator);
        const dims = if (declarator) |item| item.dims else &.{};
        out[idx] = .{
            .name = arg_name,
            .type_spec = type_spec,
            .requires_descriptor = dummyArgRequiresDescriptor(dims),
            .rank = dims.len,
            .assumed_rank = dummyArgIsAssumedRank(dims),
            .shape_signature = try shapeSignatureForDims(arena, dims),
            .pointer = decl_info.pointer,
            .allocatable = decl_info.allocatable,
            .optional = decl_info.optional,
            .intent = decl_info.intent,
            .asynchronous = decl_info.asynchronous,
            .contiguous = decl_info.contiguous,
            .value_attr = decl_info.value_attr,
            .volatile_attr = decl_info.volatile_attr,
            .no_arg_check = declarator != null and declarator.?.no_arg_check,
            .is_procedure = decl_info.interface_procedure != null or declarator_sig != null or decl_info.external or inferred_proc_kind != null,
            .procedure_kind = if (decl_info.interface_procedure) |proc|
                proc.kind
            else if (declarator_sig) |sig|
                sig.kind
            else if (inferred_proc_kind) |kind|
                kind
            else if (decl_info.external and decl_info.explicit_type)
                .function
            else
                null,
            .procedure_has_explicit_interface = decl_info.interface_procedure != null or declarator_sig != null,
            .procedure_pure = if (decl_info.interface_procedure) |proc| proc.pure else if (declarator_sig) |sig| sig.pure else false,
            .procedure_arg_count = if (decl_info.interface_procedure) |proc| proc.args.len else if (declarator_sig) |sig| sig.arg_count else 0,
            .procedure_alt_return_count = if (decl_info.interface_procedure) |proc| proc.alt_return_dummy_count else if (declarator_sig) |sig| sig.alt_return_count else 0,
            .procedure_result_type_spec = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultTypeSpec(unit, proc)
            else if (declarator_sig) |sig|
                sig.result_type_spec
            else if (inferred_proc_kind == .function and decl_info.explicit_type)
                type_spec
            else if (decl_info.external and decl_info.explicit_type)
                type_spec
            else
                null,
            .procedure_result_rank = if (decl_info.interface_procedure) |proc| interfaceProcedureResultRank(proc) else if (declarator_sig) |sig| sig.result_rank else 0,
            .procedure_result_shape_signature = if (decl_info.interface_procedure) |proc|
                try interfaceProcedureResultShapeSignature(arena, proc)
            else if (declarator_sig) |sig|
                sig.result_shape_signature
            else
                &.{},
            .procedure_result_pointer = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultAttrs(proc).pointer
            else if (declarator_sig) |sig|
                sig.is_pointer
            else
                false,
            .procedure_result_allocatable = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultAttrs(proc).allocatable
            else if (declarator_sig) |sig|
                sig.result_allocatable
            else
                false,
            .procedure_result_contiguous = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultAttrs(proc).contiguous
            else if (declarator_sig) |sig|
                sig.result_contiguous
            else
                false,
            .procedure_result_procedure_pointer = if (decl_info.interface_procedure) |proc|
                interfaceProcedureResultAttrs(proc).procedure_pointer
            else if (declarator_sig) |sig|
                sig.result_procedure_pointer
            else
                false,
            .procedure_dummy_sigs = if (decl_info.interface_procedure) |proc|
                try inferInterfaceProcedureArgSigs(arena, unit, proc)
            else if (declarator_sig) |sig|
                sig.args
            else
                &.{},
        };
    }
    return out;
}

fn resolveProcedureDeclaratorKnownSig(
    arena: std.mem.Allocator,
    unit: ast.ProgramUnit,
    known_procedure_sigs: ?*const std.StringHashMap(context.Context.ProcedureSig),
    procedure_interface: ast.ProcedureInterface,
    active_interface_name: ?[]const u8,
) anyerror!?context.Context.ProcedureSig {
    return switch (procedure_interface) {
        .name => |name| (if (known_procedure_sigs) |known|
            lookupKnownProcedureSigCaseInsensitive(known, name)
        else
            null) orelse
            (try localInterfaceProcedureSig(arena, unit, name, active_interface_name)),
        else => null,
    };
}

fn localInterfaceProcedureSig(
    arena: std.mem.Allocator,
    unit: ast.ProgramUnit,
    name: []const u8,
    active_interface_name: ?[]const u8,
) anyerror!?context.Context.ProcedureSig {
    const proc_header = findLocalInterfaceProcedure(unit.decls, name) orelse return null;
    const args = if (active_interface_name != null and std.ascii.eqlIgnoreCase(active_interface_name.?, name))
        &.{}
    else
        try inferInterfaceProcedureArgSigs(arena, unit, proc_header);
    return .{
        .kind = proc_header.kind,
        .arg_count = proc_header.args.len,
        .alt_return_count = proc_header.alt_return_dummy_count,
        .args = args,
        .pure = proc_header.pure,
        .elemental = proc_header.elemental,
        .result_rank = if (proc_header.kind == .function) interfaceProcedureResultRank(proc_header) else 0,
        .result_type_spec = if (proc_header.kind == .function) interfaceProcedureResultTypeSpec(unit, proc_header) else null,
        .result_shape_signature = if (proc_header.kind == .function) try interfaceProcedureResultShapeSignature(arena, proc_header) else &.{},
        .result_allocatable = if (proc_header.kind == .function) interfaceProcedureResultAttrs(proc_header).allocatable else false,
        .result_contiguous = if (proc_header.kind == .function) interfaceProcedureResultAttrs(proc_header).contiguous else false,
        .result_procedure_pointer = if (proc_header.kind == .function) interfaceProcedureResultAttrs(proc_header).procedure_pointer else false,
    };
}

fn findLocalInterfaceProcedure(decls: []const ast.Decl, name: []const u8) ?ast.InterfaceProcedure {
    for (decls) |decl| {
        if (decl != .interface_block) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return proc_header;
        }
    }
    return null;
}

fn lookupKnownProcedureSigCaseInsensitive(
    known_procedure_sigs: *const std.StringHashMap(context.Context.ProcedureSig),
    name: []const u8,
) ?context.Context.ProcedureSig {
    var qualified_match: ?context.Context.ProcedureSig = null;
    var it = known_procedure_sigs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.ascii.eqlIgnoreCase(key, name)) return entry.value_ptr.*;
        const sep = std.mem.lastIndexOf(u8, key, "::") orelse continue;
        if (!std.ascii.eqlIgnoreCase(key[sep + 2 ..], name)) continue;
        if (qualified_match != null) return null;
        qualified_match = entry.value_ptr.*;
    }
    return qualified_match;
}

pub fn interfaceProcedureResultTypeSpec(unit: ast.ProgramUnit, proc_header: ast.InterfaceProcedure) ?symbols.TypeSpec {
    if (proc_header.kind != .function) return null;
    if (findInterfaceProcedureDeclaredResultTypeSpec(unit, proc_header)) |type_spec| return type_spec;
    if (proc_header.type_spec) |type_spec| return procedureTypeSpecWithDecls(proc_header.decls, type_spec);
    return implicitTypeSpecForName(unit, proc_header.name);
}

pub fn interfaceProcedureResultRank(proc_header: ast.InterfaceProcedure) usize {
    const result_name = proc_header.result_name orelse proc_header.name;
    for (proc_header.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, result_name)) return item.dims.len;
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, result_name)) return item.dims.len;
                }
            },
            else => {},
        }
    }
    return 0;
}

pub const InterfaceProcedureResultAttrs = struct {
    pointer: bool = false,
    allocatable: bool = false,
    contiguous: bool = false,
    procedure_pointer: bool = false,
};

pub fn interfaceProcedureResultAttrs(proc_header: ast.InterfaceProcedure) InterfaceProcedureResultAttrs {
    var attrs: InterfaceProcedureResultAttrs = .{};
    const result_name = proc_header.result_name orelse proc_header.name;
    for (proc_header.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    attrs.pointer = type_decl.pointer;
                    attrs.allocatable = type_decl.allocatable;
                    attrs.contiguous = type_decl.contiguous;
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    attrs.pointer = procedure_decl.pointer;
                    attrs.procedure_pointer = procedure_decl.pointer;
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    attrs.pointer = attrs.pointer or dimension_decl.pointer;
                    attrs.allocatable = attrs.allocatable or dimension_decl.allocatable;
                }
            },
            else => {},
        }
    }
    return attrs;
}

pub fn interfaceProcedureResultShapeSignature(arena: std.mem.Allocator, proc_header: ast.InterfaceProcedure) ![]const []const u8 {
    const result_name = proc_header.result_name orelse proc_header.name;
    for (proc_header.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return shapeSignatureForDims(arena, item.dims);
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return shapeSignatureForDims(arena, item.dims);
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return shapeSignatureForDims(arena, item.dims);
                }
            },
            else => {},
        }
    }
    return &.{};
}

fn findInterfaceProcedureDeclaredResultTypeSpec(
    unit: ast.ProgramUnit,
    proc_header: ast.InterfaceProcedure,
) ?symbols.TypeSpec {
    const result_name = proc_header.result_name orelse proc_header.name;
    const active_decls = if (proc_header.decls.len != 0) proc_header.decls else unit.decls;
    for (active_decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return applyDummyDeclaratorCharLen(typeDeclTypeSpecWithDecls(active_decls, type_decl), item);
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return switch (procedure_decl.interface) {
                        .type_spec => |proc_type| applyDummyDeclaratorCharLen(procedureTypeSpecWithDecls(active_decls, proc_type), item),
                        else => applyDummyDeclaratorCharLen(implicitTypeSpecForName(unit, result_name), item),
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn inferDummyArgProcedureKind(unit: ast.ProgramUnit, name: []const u8) ?ast.ProgramUnitKind {
    return inferDummyArgProcedureKindInStmts(unit.stmts, name);
}

fn inferDummyArgProcedureKindInStmts(stmts: []const ast.Stmt, name: []const u8) ?ast.ProgramUnitKind {
    var inferred: ?ast.ProgramUnitKind = null;
    for (stmts) |stmt| {
        const kind = inferDummyArgProcedureKindInStmt(stmt.node, name) orelse continue;
        if (inferred) |existing| {
            if (existing != kind) return null;
        } else {
            inferred = kind;
        }
    }
    return inferred;
}

fn inferDummyArgProcedureKindInStmt(node: ast.StmtNode, name: []const u8) ?ast.ProgramUnitKind {
    switch (node) {
        .call => |call| {
            if (std.ascii.eqlIgnoreCase(call.name, name)) return .subroutine;
            for (call.args) |arg| {
                if (arg != .expr) continue;
                if (inferDummyArgProcedureKindInExpr(arg.expr.value, name)) |kind| return kind;
            }
            return null;
        },
        .assignment => |assign| {
            return inferDummyArgProcedureKindInExpr(assign.target, name) orelse
                inferDummyArgProcedureKindInExpr(assign.value, name);
        },
        .pointer_assignment => |assign| {
            return inferDummyArgProcedureKindInExpr(assign.target, name) orelse
                inferDummyArgProcedureKindInExpr(assign.value, name);
        },
        .if_single => |ifs| {
            return inferDummyArgProcedureKindInExpr(ifs.condition, name) orelse
                inferDummyArgProcedureKindInStmt(ifs.stmt.*, name);
        },
        .if_block => |ifb| {
            if (inferDummyArgProcedureKindInExpr(ifb.condition, name)) |kind| return kind;
            for (ifb.then_stmts) |stmt| {
                if (inferDummyArgProcedureKindInStmt(stmt.node, name)) |kind| return kind;
            }
            for (ifb.else_stmts) |stmt| {
                if (inferDummyArgProcedureKindInStmt(stmt.node, name)) |kind| return kind;
            }
            return null;
        },
        .where_stmt => |where| {
            return inferDummyArgProcedureKindInExpr(where.mask, name) orelse
                inferDummyArgProcedureKindInExpr(where.target, name) orelse
                inferDummyArgProcedureKindInExpr(where.value, name);
        },
        .write => |write| {
            if (inferDummyArgProcedureKindInExpr(write.unit, name)) |kind| return kind;
            if (write.rec) |rec| {
                if (inferDummyArgProcedureKindInExpr(rec, name)) |kind| return kind;
            }
            for (write.args) |arg| {
                if (inferDummyArgProcedureKindInExpr(arg, name)) |kind| return kind;
            }
            if (write.iostat) |expr| return inferDummyArgProcedureKindInExpr(expr, name);
            return null;
        },
        .read => |read| {
            if (inferDummyArgProcedureKindInExpr(read.unit, name)) |kind| return kind;
            if (read.rec) |rec| {
                if (inferDummyArgProcedureKindInExpr(rec, name)) |kind| return kind;
            }
            for (read.args) |arg| {
                if (inferDummyArgProcedureKindInExpr(arg, name)) |kind| return kind;
            }
            if (read.iostat) |expr| return inferDummyArgProcedureKindInExpr(expr, name);
            return null;
        },
        .open => |open_stmt| {
            if (inferDummyArgProcedureKindInExpr(open_stmt.unit, name)) |kind| return kind;
            if (open_stmt.recl) |expr| {
                if (inferDummyArgProcedureKindInExpr(expr, name)) |kind| return kind;
            }
            if (open_stmt.file) |expr| {
                if (inferDummyArgProcedureKindInExpr(expr, name)) |kind| return kind;
            }
            if (open_stmt.access) |expr| {
                if (inferDummyArgProcedureKindInExpr(expr, name)) |kind| return kind;
            }
            if (open_stmt.form) |expr| {
                if (inferDummyArgProcedureKindInExpr(expr, name)) |kind| return kind;
            }
            if (open_stmt.blank) |expr| {
                if (inferDummyArgProcedureKindInExpr(expr, name)) |kind| return kind;
            }
            if (open_stmt.status) |expr| return inferDummyArgProcedureKindInExpr(expr, name);
            return null;
        },
        .close => |close_stmt| {
            for (close_stmt.controls) |ctrl| {
                if (inferDummyArgProcedureKindInExpr(ctrl.value, name)) |kind| return kind;
            }
            return null;
        },
        .inquire => |inq| {
            for (inq.controls) |ctrl| {
                if (inferDummyArgProcedureKindInExpr(ctrl.value, name)) |kind| return kind;
            }
            return null;
        },
        .allocate => |allocate| {
            if (allocate.type_spec) |type_spec| {
                if (type_spec.kind_selector) |expr| {
                    if (inferDummyArgProcedureKindInExpr(expr, name)) |kind| return kind;
                }
                if (type_spec.char_len) |expr| {
                    if (inferDummyArgProcedureKindInExpr(expr, name)) |kind| return kind;
                }
            }
            for (allocate.items) |item| {
                if (inferDummyArgProcedureKindInExpr(item.target, name)) |kind| return kind;
                for (item.dims) |dim| {
                    if (inferDummyArgProcedureKindInExpr(dim, name)) |kind| return kind;
                }
            }
            for (allocate.options) |option| {
                if (inferDummyArgProcedureKindInExpr(option.value, name)) |kind| return kind;
            }
            return null;
        },
        .deallocate => |deallocate| {
            for (deallocate.options) |option| {
                if (inferDummyArgProcedureKindInExpr(option.value, name)) |kind| return kind;
            }
            return null;
        },
        .data => |data_stmt| {
            for (data_stmt.inits) |init| {
                if (inferDummyArgProcedureKindInExpr(init.target, name)) |kind| return kind;
                if (inferDummyArgProcedureKindInExpr(init.value, name)) |kind| return kind;
            }
            return null;
        },
        .arith_if => |arith| return inferDummyArgProcedureKindInExpr(arith.condition, name),
        .do_loop => |loop| {
            return inferDummyArgProcedureKindInExpr(loop.start, name) orelse
                inferDummyArgProcedureKindInExpr(loop.end, name) orelse
                (if (loop.step) |expr| inferDummyArgProcedureKindInExpr(expr, name) else null);
        },
        .do_while => |loop| return inferDummyArgProcedureKindInExpr(loop.condition, name),
        .computed_goto => |gt| return inferDummyArgProcedureKindInExpr(gt.selector, name),
        .ret => |ret| return if (ret.value) |expr| inferDummyArgProcedureKindInExpr(expr, name) else null,
        else => return null,
    }
}

fn inferDummyArgProcedureKindInExpr(expr: *ast.Expr, name: []const u8) ?ast.ProgramUnitKind {
    switch (expr.*) {
        .array_constructor => |ctor| {
            for (ctor.items) |item| {
                if (inferDummyArgProcedureKindInExpr(item, name)) |kind| return kind;
            }
            return null;
        },
        .call_or_subscript => |call| {
            if (std.ascii.eqlIgnoreCase(call.name, name)) return .function;
            for (call.args) |arg| {
                if (inferDummyArgProcedureKindInExpr(arg, name)) |kind| return kind;
            }
            return null;
        },
        .substring => |sub| {
            for (sub.args) |arg| {
                if (inferDummyArgProcedureKindInExpr(arg, name)) |kind| return kind;
            }
            if (sub.start) |start| {
                if (inferDummyArgProcedureKindInExpr(start, name)) |kind| return kind;
            }
            if (sub.end) |end_expr| return inferDummyArgProcedureKindInExpr(end_expr, name);
            return null;
        },
        .component => |comp| {
            if (inferDummyArgProcedureKindInExpr(comp.base, name)) |kind| return kind;
            for (comp.args) |arg| {
                if (inferDummyArgProcedureKindInExpr(arg, name)) |kind| return kind;
            }
            return null;
        },
        .unary => |un| return inferDummyArgProcedureKindInExpr(un.expr, name),
        .binary => |bin| {
            return inferDummyArgProcedureKindInExpr(bin.left, name) orelse
                inferDummyArgProcedureKindInExpr(bin.right, name);
        },
        .complex_literal => |lit| {
            return inferDummyArgProcedureKindInExpr(lit.real, name) orelse
                inferDummyArgProcedureKindInExpr(lit.imag, name);
        },
        .dim_range => |range| {
            if (range.lower) |lower| {
                if (inferDummyArgProcedureKindInExpr(lower, name)) |kind| return kind;
            }
            if (inferDummyArgProcedureKindInExpr(range.upper, name)) |kind| return kind;
            if (range.stride) |stride| return inferDummyArgProcedureKindInExpr(stride, name);
            return null;
        },
        .implied_do => |implied| {
            if (inferDummyArgProcedureKindInExpr(implied.start, name)) |kind| return kind;
            if (inferDummyArgProcedureKindInExpr(implied.end, name)) |kind| return kind;
            if (implied.step) |step| {
                if (inferDummyArgProcedureKindInExpr(step, name)) |kind| return kind;
            }
            for (implied.items) |item| {
                if (inferDummyArgProcedureKindInExpr(item, name)) |kind| return kind;
            }
            return null;
        },
        else => return null,
    }
}

fn inferDummyArgTypeSpec(
    decls: []const ast.Decl,
    unit: ast.ProgramUnit,
    name: []const u8,
    declarator: ?ast.Declarator,
) symbols.TypeSpec {
    var decl_idx = decls.len;
    while (decl_idx > 0) {
        decl_idx -= 1;
        const decl = decls[decl_idx];
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
                    return applyDummyDeclaratorCharLen(typeDeclTypeSpecWithDecls(decls, type_decl), item);
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
                    switch (procedure_decl.interface) {
                        .type_spec => |proc_type| {
                            return applyDummyDeclaratorCharLen(
                                procedureTypeSpecWithDecls(decls, proc_type),
                                item,
                            );
                        },
                        else => {
                            return if (declarator) |decl_item|
                                applyDummyDeclaratorCharLen(implicitTypeSpecForName(unit, name), decl_item)
                            else
                                applyDummyCharLen(implicitTypeSpecForName(unit, name), null);
                        },
                    }
                }
            },
            else => {},
        }
    }
    if (decls.ptr != unit.decls.ptr) {
        return inferDummyArgTypeSpec(unit.decls, unit, name, declarator);
    }
    return if (declarator) |item|
        applyDummyDeclaratorCharLen(implicitTypeSpecForName(unit, name), item)
    else
        applyDummyCharLen(implicitTypeSpecForName(unit, name), null);
}

fn typeDeclTypeSpecWithDecls(decls: []const ast.Decl, type_decl: ast.TypeDecl) symbols.TypeSpec {
    if (type_decl.type_kind != .derived) {
        return type_kind_selector.resolveSpecWithConst(
            type_decl.type_kind,
            type_decl.kind_selector,
            resolveKindSelectorConstValue(decls, type_decl.kind_selector),
        )
            .withPolymorphic(type_decl.polymorphic)
            .withAssumedType(type_decl.assumed_type);
    }
    const base = if (type_decl.derived_type_name) |derived_name|
        symbols.TypeSpec.fromDerived(derived_name)
    else
        symbols.TypeSpec.fromKind(.derived);
    return base.withPolymorphic(type_decl.polymorphic).withAssumedType(type_decl.assumed_type);
}

fn typeDeclTypeSpec(type_decl: ast.TypeDecl) symbols.TypeSpec {
    return typeDeclTypeSpecWithDecls(&.{}, type_decl);
}

pub fn procedureTypeSpecWithDecls(decls: []const ast.Decl, proc_type: ast.ProcedureTypeSpec) symbols.TypeSpec {
    if (proc_type.type_kind != .derived) {
        return type_kind_selector.resolveSpecWithConst(
            proc_type.type_kind,
            proc_type.kind_selector,
            resolveKindSelectorConstValue(decls, proc_type.kind_selector),
        )
            .withPolymorphic(proc_type.polymorphic)
            .withAssumedType(proc_type.assumed_type);
    }
    const base = if (proc_type.derived_type_name) |derived_name|
        symbols.TypeSpec.fromDerived(derived_name)
    else
        symbols.TypeSpec.fromKind(.derived);
    return base.withPolymorphic(proc_type.polymorphic).withAssumedType(proc_type.assumed_type);
}

pub fn procedureTypeSpec(proc_type: ast.ProcedureTypeSpec) symbols.TypeSpec {
    return procedureTypeSpecWithDecls(&.{}, proc_type);
}

const ParameterResolverCtx = struct {
    decls: []const ast.Decl,
    stack: std.array_list.Managed([]const u8),
};

fn resolveKindSelectorConstValue(decls: []const ast.Decl, selector: ?*ast.Expr) ?symbols.ConstValue {
    const selector_node = selector orelse return null;
    const allocator = std.heap.page_allocator;
    var stack = std.array_list.Managed([]const u8).init(allocator);
    defer stack.deinit();
    var ctx: ParameterResolverCtx = .{
        .decls = decls,
        .stack = stack,
    };
    const resolver = evaluator.ConstResolver{
        .ctx = @ptrCast(&ctx),
        .resolveFn = resolveParameterConstValue,
    };
    return evaluator.evalConst(selector_node, resolver) catch null;
}

fn resolveParameterConstValue(raw_ctx: *anyopaque, name: []const u8) ?symbols.ConstValue {
    const ctx: *ParameterResolverCtx = @ptrCast(@alignCast(raw_ctx));
    if (builtinKindConstantValue(name)) |value| return value;
    for (ctx.stack.items) |active_name| {
        if (std.ascii.eqlIgnoreCase(active_name, name)) return null;
    }
    ctx.stack.append(name) catch return null;
    defer _ = ctx.stack.pop();
    return lookupParameterConstValue(ctx, name);
}

fn lookupParameterConstValue(ctx: *ParameterResolverCtx, name: []const u8) ?symbols.ConstValue {
    for (ctx.decls) |decl| {
        switch (decl) {
            .parameter => |parameter_decl| {
                for (parameter_decl.assigns) |assign| {
                    if (!std.ascii.eqlIgnoreCase(assign.name, name)) continue;
                    const resolver = evaluator.ConstResolver{
                        .ctx = @ptrCast(ctx),
                        .resolveFn = resolveParameterConstValue,
                    };
                    return evaluator.evalConst(assign.value, resolver) catch null;
                }
            },
            .type_decl => |type_decl| {
                if (!type_decl.parameter) continue;
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
                    const init = item.init orelse return null;
                    const resolver = evaluator.ConstResolver{
                        .ctx = @ptrCast(ctx),
                        .resolveFn = resolveParameterConstValue,
                    };
                    return evaluator.evalConst(init, resolver) catch null;
                }
            },
            else => {},
        }
    }
    return null;
}

fn builtinKindConstantValue(name: []const u8) ?symbols.ConstValue {
    if (std.ascii.eqlIgnoreCase(name, "c_int")) return .{ .integer = 4 };
    if (std.ascii.eqlIgnoreCase(name, "c_short")) return .{ .integer = 2 };
    if (std.ascii.eqlIgnoreCase(name, "c_long")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_long_long")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_int8_t")) return .{ .integer = 1 };
    if (std.ascii.eqlIgnoreCase(name, "c_int16_t")) return .{ .integer = 2 };
    if (std.ascii.eqlIgnoreCase(name, "c_int32_t")) return .{ .integer = 4 };
    if (std.ascii.eqlIgnoreCase(name, "c_int64_t")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_intmax_t")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_intptr_t")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_size_t")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_ptrdiff_t")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_signed_char")) return .{ .integer = 1 };
    if (std.ascii.eqlIgnoreCase(name, "c_char")) return .{ .integer = 1 };
    if (std.ascii.eqlIgnoreCase(name, "c_bool")) return .{ .integer = 1 };
    if (std.ascii.eqlIgnoreCase(name, "c_float")) return .{ .integer = 4 };
    if (std.ascii.eqlIgnoreCase(name, "c_double")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_long_double")) return .{ .integer = 16 };
    if (std.ascii.eqlIgnoreCase(name, "c_float_complex")) return .{ .integer = 4 };
    if (std.ascii.eqlIgnoreCase(name, "c_double_complex")) return .{ .integer = 8 };
    if (std.ascii.eqlIgnoreCase(name, "c_long_double_complex")) return .{ .integer = 16 };
    return null;
}

fn implicitTypeSpecForName(unit: ast.ProgramUnit, name: []const u8) symbols.TypeSpec {
    if (name.len != 0) {
        const first = std.ascii.toUpper(name[0]);
        for (unit.decls) |decl| {
            if (decl != .implicit) continue;
            for (decl.implicit.rules) |rule| {
                if (first < rule.start or first > rule.end) continue;
                return applyDummyCharLen(type_kind_selector.resolveSpec(rule.type_kind, rule.kind_selector), rule.char_len);
            }
        }
        if (first >= 'I' and first <= 'N') return symbols.TypeSpec.fromResolvedKind(.integer, .integer, null);
    }
    return symbols.TypeSpec.fromResolvedKind(.real, .real, null);
}

fn applyDummyCharLen(type_spec: symbols.TypeSpec, char_len_expr: ?*ast.Expr) symbols.TypeSpec {
    if (type_spec.lowered_kind != .character) return type_spec.withCharacterLength(.none, null);
    const expr_node = char_len_expr orelse return type_spec.withCharacterLength(.constant, 1);
    if (expr_node.* == .literal and expr_node.literal.kind == .assumed_size) {
        return type_spec.withCharacterLength(.assumed, null);
    }
    const char_len = inferConstantCharLen(expr_node);
    return type_spec.withCharacterLength(
        if (char_len != null) .constant else .deferred,
        char_len,
    );
}

fn applyDummyDeclaratorCharLen(type_spec: symbols.TypeSpec, declarator: ast.Declarator) symbols.TypeSpec {
    if (declarator.char_len_deferred) return type_spec.withCharacterLength(.deferred, null);
    return applyDummyCharLen(type_spec, declarator.char_len);
}

fn inferConstantCharLen(expr_node: *ast.Expr) ?usize {
    return literal_expr.integer(usize, expr_node);
}

fn dummyArgRequiresDescriptor(dims: []const *ast.Expr) bool {
    if (dims.len == 0) return false;
    for (dims) |dim| {
        switch (dim.*) {
            .dim_range => |range| {
                if (range.assumed_shape) return true;
            },
            else => {},
        }
    }
    return false;
}

fn dummyArgIsAssumedRank(dims: []const *ast.Expr) bool {
    if (dims.len != 1) return false;
    return switch (dims[0].*) {
        .dim_range => |range| range.from_dotdot,
        else => false,
    };
}
