const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const symbols = @import("../../symbol/mod.zig");
const context = @import("../context.zig");
const resolve_expr = @import("../resolve_expr.zig");
const resolve_symbols = @import("../resolve_symbols.zig");
const procedure_inference = @import("../../split/api/procedure_inference.zig");

pub fn callHasDerivedActuals(self: *context.Context, args: []const ast.CallArg) bool {
    for (args) |arg| {
        switch (arg) {
            .expr => |actual| {
                const spec = resolve_expr.exprTypeSpec(self, actual.value) catch continue;
                if (spec.lowered_kind == .derived) return true;
            },
            .alt_return => {},
        }
    }
    return false;
}

pub fn appendGenericInterfaceSigs(
    self: *context.Context,
    out: *std.array_list.Managed(context.Context.ProcedureSig),
    interface_block: ast.InterfaceBlock,
) !void {
    for (interface_block.procedure_headers) |proc_header| {
        const sig = lookupGenericSpecificSig(self, proc_header.name, proc_header.source) orelse continue;
        try out.append(sig);
    }
    for (interface_block.specific_procedures, 0..) |proc_name, idx| {
        if (idx >= interface_block.specific_procedure_sources.len) continue;
        const sig = lookupGenericSpecificSig(self, proc_name, interface_block.specific_procedure_sources[idx]) orelse continue;
        try out.append(sig);
    }
    for (interface_block.module_procedures, 0..) |proc_name, idx| {
        if (idx >= interface_block.module_procedure_sources.len) continue;
        const sig = lookupGenericSpecificSig(self, proc_name, interface_block.module_procedure_sources[idx]) orelse continue;
        try out.append(sig);
    }
    for (interface_block.procedures, 0..) |proc_name, idx| {
        if (interfaceBlockHasProcedureHeader(interface_block, proc_name)) continue;
        if (idx >= interface_block.procedure_sources.len) continue;
        const sig = lookupGenericSpecificSig(self, proc_name, interface_block.procedure_sources[idx]) orelse continue;
        try out.append(sig);
    }
}

const VisibleGenericSpecific = struct {
    source: ast.DeclSource,
    sig: context.Context.ProcedureSig,
};

pub fn appendGenericInterfaceSpecifics(
    self: *context.Context,
    out: *std.array_list.Managed(VisibleGenericSpecific),
    interface_block: ast.InterfaceBlock,
) !void {
    for (interface_block.procedure_headers) |proc_header| {
        const sig = lookupGenericSpecificSig(self, proc_header.name, proc_header.source) orelse continue;
        try out.append(.{ .source = proc_header.source, .sig = sig });
    }
    for (interface_block.specific_procedures, 0..) |proc_name, idx| {
        if (idx >= interface_block.specific_procedure_sources.len) continue;
        const sig = lookupGenericSpecificSig(self, proc_name, interface_block.specific_procedure_sources[idx]) orelse continue;
        try out.append(.{ .source = interface_block.specific_procedure_sources[idx], .sig = sig });
    }
    for (interface_block.module_procedures, 0..) |proc_name, idx| {
        if (idx >= interface_block.module_procedure_sources.len) continue;
        const sig = lookupGenericSpecificSig(self, proc_name, interface_block.module_procedure_sources[idx]) orelse continue;
        try out.append(.{ .source = interface_block.module_procedure_sources[idx], .sig = sig });
    }
    for (interface_block.procedures, 0..) |proc_name, idx| {
        if (interfaceBlockHasProcedureHeader(interface_block, proc_name)) continue;
        if (idx >= interface_block.procedure_sources.len) continue;
        const sig = lookupGenericSpecificSig(self, proc_name, interface_block.procedure_sources[idx]) orelse continue;
        try out.append(.{ .source = interface_block.procedure_sources[idx], .sig = sig });
    }
}

pub fn visibleSingleTargetGenericSig(self: *context.Context, name: []const u8) ?context.Context.ProcedureSig {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, name)) continue;
        return singleTargetGenericInterfaceSig(self, decl.interface_block);
    }
    return null;
}

pub fn hasVisibleProcedureReference(self: *context.Context, name: []const u8) bool {
    if (resolve_symbols.lookupKnownProcedureSig(self, name) != null) return true;
    if (visibleSingleTargetGenericSig(self, name) != null) return true;
    if (findVisibleProcedureSource(self, name) != null) return true;
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (std.ascii.eqlIgnoreCase(interface_name, name)) return true;
    }
    return false;
}

pub fn visibleSpecificInterfaceSig(self: *context.Context, name: []const u8) ?context.Context.ProcedureSig {
    var matched: ?context.Context.ProcedureSig = null;
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_block = decl.interface_block;
        if (interface_block.name != null) continue;

        for (interface_block.procedure_headers) |proc_header| {
            if (!std.ascii.eqlIgnoreCase(proc_header.name, name)) continue;
            const sig = interfaceProcedureSig(self, proc_header) orelse return null;
            if (matched != null) return null;
            matched = sig;
        }
    }
    return matched;
}

pub fn matchedVisibleGenericSigForExprArgs(
    self: *context.Context,
    name: []const u8,
    args: []*ast.Expr,
) ?context.Context.ProcedureSig {
    var saw_local_interface = false;
    var local_match: ?context.Context.ProcedureSig = null;
    var local_match_count: usize = 0;
    for (self.unit.decls, 0..) |decl, decl_idx| {
        if (decl_idx < self.unit.prelude_decl_count) continue;
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, name)) continue;
        saw_local_interface = true;

        var specifics = std.array_list.Managed(VisibleGenericSpecific).init(self.arena);
        appendGenericInterfaceSpecifics(self, &specifics, decl.interface_block) catch return null;
        for (specifics.items) |specific| {
            if (!exprArgsMatchGenericSig(self, specific.sig, args)) continue;
            local_match_count += 1;
            if (local_match_count == 1) local_match = specific.sig;
        }
    }
    if (saw_local_interface) {
        if (local_match_count == 1) return local_match;
        return null;
    }

    var direct_match: ?context.Context.ProcedureSig = null;
    var direct_match_count: usize = 0;
    var fallback_match: ?context.Context.ProcedureSig = null;
    var fallback_match_count: usize = 0;
    var decl_idx: usize = self.unit.decls.len;
    while (decl_idx > 0) {
        decl_idx -= 1;
        if (decl_idx >= self.unit.prelude_decl_count) continue;
        const decl = self.unit.decls[decl_idx];
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, name)) continue;
        const from_direct_use = preludeInterfaceDeclFromDirectUse(self, decl_idx);

        var specifics = std.array_list.Managed(VisibleGenericSpecific).init(self.arena);
        appendGenericInterfaceSpecifics(self, &specifics, decl.interface_block) catch return null;
        for (specifics.items) |specific| {
            if (!exprArgsMatchGenericSig(self, specific.sig, args)) continue;
            if (from_direct_use) {
                direct_match_count += 1;
                if (direct_match_count == 1) direct_match = specific.sig;
            } else {
                fallback_match_count += 1;
                if (fallback_match_count == 1) fallback_match = specific.sig;
            }
        }
    }
    if (direct_match_count != 0) return if (direct_match_count == 1) direct_match else null;
    return if (fallback_match_count == 1) fallback_match else null;
}

pub fn matchedVisibleGenericSigForCallArgs(
    self: *context.Context,
    name: []const u8,
    args: []const ast.CallArg,
) ?context.Context.ProcedureSig {
    var saw_local_interface = false;
    var local_match: ?context.Context.ProcedureSig = null;
    var local_match_count: usize = 0;
    for (self.unit.decls, 0..) |decl, decl_idx| {
        if (decl_idx < self.unit.prelude_decl_count) continue;
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, name)) continue;
        saw_local_interface = true;

        var specifics = std.array_list.Managed(VisibleGenericSpecific).init(self.arena);
        appendGenericInterfaceSpecifics(self, &specifics, decl.interface_block) catch return null;
        for (specifics.items) |specific| {
            if (!callArgsMatchGenericSig(self, specific.sig, args)) continue;
            local_match_count += 1;
            if (local_match_count == 1) local_match = specific.sig;
        }
    }
    if (saw_local_interface) {
        if (local_match_count == 1) return local_match;
        return null;
    }

    var direct_match: ?context.Context.ProcedureSig = null;
    var direct_match_count: usize = 0;
    var fallback_match: ?context.Context.ProcedureSig = null;
    var fallback_match_count: usize = 0;
    var decl_idx: usize = self.unit.decls.len;
    while (decl_idx > 0) {
        decl_idx -= 1;
        if (decl_idx >= self.unit.prelude_decl_count) continue;
        const decl = self.unit.decls[decl_idx];
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, name)) continue;
        const from_direct_use = preludeInterfaceDeclFromDirectUse(self, decl_idx);

        var specifics = std.array_list.Managed(VisibleGenericSpecific).init(self.arena);
        appendGenericInterfaceSpecifics(self, &specifics, decl.interface_block) catch return null;
        for (specifics.items) |specific| {
            if (!callArgsMatchGenericSig(self, specific.sig, args)) continue;
            if (from_direct_use) {
                direct_match_count += 1;
                if (direct_match_count == 1) direct_match = specific.sig;
            } else {
                fallback_match_count += 1;
                if (fallback_match_count == 1) fallback_match = specific.sig;
            }
        }
    }
    if (direct_match_count != 0) return if (direct_match_count == 1) direct_match else null;
    return if (fallback_match_count == 1) fallback_match else null;
}

fn preludeInterfaceDeclFromDirectUse(self: *context.Context, decl_idx: usize) bool {
    if (decl_idx >= self.unit.decl_sources.len) return false;
    const owner_name = self.unit.decl_sources[decl_idx].owner_name orelse return false;
    for (self.unit.stmts) |stmt_node| {
        if (stmt_node.node != .use_stmt) continue;
        if (std.ascii.eqlIgnoreCase(stmt_node.node.use_stmt.module_name, owner_name)) return true;
    }
    return false;
}

pub fn findAmbiguousVisibleGenericSpecificSource(self: *context.Context, name: []const u8) ?ast.DeclSource {
    var sources = std.array_list.Managed(ast.DeclSource).init(self.arena);
    appendAmbiguousVisibleGenericSpecificSources(self, &sources, name) catch return null;
    return if (sources.items.len != 0) sources.items[0] else null;
}

pub fn appendAmbiguousVisibleGenericSpecificSources(
    self: *context.Context,
    out: *std.array_list.Managed(ast.DeclSource),
    name: []const u8,
) !void {
    var specifics = std.array_list.Managed(VisibleGenericSpecific).init(self.arena);
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_name = decl.interface_block.name orelse continue;
        if (!std.ascii.eqlIgnoreCase(interface_name, name)) continue;
        try appendGenericInterfaceSpecifics(self, &specifics, decl.interface_block);
    }
    var i: usize = 0;
    while (i < specifics.items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < specifics.items.len) : (j += 1) {
            if (genericProcedureSigAmbiguous(specifics.items[i].sig, specifics.items[j].sig)) {
                try appendUniqueSource(out, specifics.items[i].source);
                try appendUniqueSource(out, specifics.items[j].source);
            }
        }
    }
}

pub fn genericProcedureSigAmbiguous(a: context.Context.ProcedureSig, b: context.Context.ProcedureSig) bool {
    if (a.kind != b.kind) return false;
    if (genericRequiredArgCount(a) != genericRequiredArgCount(b)) return false;
    if (genericSigHasDerivedOrProcedureRequiredArg(a) or genericSigHasDerivedOrProcedureRequiredArg(b)) return false;

    var a_idx: usize = 0;
    var b_idx: usize = 0;
    while (true) {
        while (a_idx < a.args.len and a.args[a_idx].optional) : (a_idx += 1) {}
        while (b_idx < b.args.len and b.args[b_idx].optional) : (b_idx += 1) {}
        if (a_idx >= a.args.len or b_idx >= b.args.len) return a_idx >= a.args.len and b_idx >= b.args.len;
        if (!genericArgEquivalent(a.args[a_idx], b.args[b_idx])) return false;
        a_idx += 1;
        b_idx += 1;
    }
}

pub fn calleeHasVisibleExplicitInterface(self: *context.Context, name: []const u8) bool {
    if (resolve_symbols.findSymbolIndex(self, name)) |idx| {
        const sym = self.symbols.items[idx];
        if ((sym.kind == .function or sym.kind == .subroutine) and !sym.is_external) return true;
    }
    if (resolve_symbols.lookupKnownProcedureSig(self, name)) |sig| {
        if (sig.actual_requires_explicit_interface) return true;
    }
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_block = decl.interface_block;
        if (interface_block.name) |interface_name| {
            if (std.ascii.eqlIgnoreCase(interface_name, name)) return true;
        }
        for (interface_block.procedure_headers) |proc_header| {
            if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return true;
        }
    }
    var it = self.known_host_interface_sources.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return true;
    }
    return false;
}

pub fn findVisibleProcedureSource(self: *context.Context, name: []const u8) ?ast.DeclSource {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_block = decl.interface_block;
        for (interface_block.procedure_headers) |proc_header| {
            if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return proc_header.source;
        }
        for (interface_block.specific_procedures, 0..) |proc_name, idx| {
            if (!std.ascii.eqlIgnoreCase(proc_name, name)) continue;
            if (idx < interface_block.specific_procedure_sources.len) return interface_block.specific_procedure_sources[idx];
            break;
        }
        for (interface_block.module_procedures, 0..) |proc_name, idx| {
            if (!std.ascii.eqlIgnoreCase(proc_name, name)) continue;
            if (idx < interface_block.module_procedure_sources.len) return interface_block.module_procedure_sources[idx];
            break;
        }
        for (interface_block.procedures, 0..) |proc_name, idx| {
            if (!std.ascii.eqlIgnoreCase(proc_name, name)) continue;
            if (idx < interface_block.procedure_sources.len) return interface_block.procedure_sources[idx];
            break;
        }
    }
    var it = self.known_host_interface_sources.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

pub fn findVisibleProcedureFormalSource(
    self: *context.Context,
    procedure_name: []const u8,
    formal_name: []const u8,
) ?ast.DeclSource {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        const interface_block = decl.interface_block;
        for (interface_block.procedure_headers) |proc_header| {
            if (!std.ascii.eqlIgnoreCase(proc_header.name, procedure_name)) continue;
            return findInterfaceProcedureDeclSource(proc_header, formal_name);
        }
    }
    return null;
}

pub fn calleeRequiresExplicitInterface(self: *context.Context, name: []const u8) bool {
    const sig = resolve_symbols.lookupKnownProcedureSig(self, name) orelse return false;
    return procedureSigRequiresExplicitInterface(sig);
}

pub fn requiresExplicitInterfaceForActual(self: *context.Context, expr: *ast.Expr) bool {
    if (explicitInterfaceRestrictionMessageForActual(self, expr) != null) return true;
    const spec = resolve_expr.exprTypeSpec(self, expr) catch return false;
    return spec.lowered_kind == .derived and spec.polymorphic and !spec.assumed_type;
}

pub fn explicitInterfaceRestrictionMessageForActual(self: *context.Context, expr: *ast.Expr) ?[]const u8 {
    if (actualExprIsAssumedRank(self, expr)) return "Assumed-rank argument";
    if (actualExprIsNullWithMold(expr)) return "NULL(MOLD) actual requires an explicit interface";
    const spec = resolve_expr.exprTypeSpec(self, expr) catch return null;
    if (spec.assumed_type) return "Assumed-type argument";
    return null;
}

pub fn isProcedureActualExpr(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            if (resolve_symbols.lookupKnownProcedureSig(self, name)) |sig| {
                break :blk sig.actual_requires_explicit_interface;
            }
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            const sym = self.symbols.items[idx];
            break :blk (sym.kind == .function or sym.kind == .subroutine) and !sym.is_external;
        },
        .component => |comp| blk: {
            if (comp.has_parens) break :blk false;
            const base_spec = resolve_expr.exprTypeSpec(self, comp.base) catch break :blk false;
            if (base_spec.lowered_kind != .derived) break :blk false;
            const derived_name = base_spec.derived_type_name orelse break :blk false;
            const component = resolve_symbols.lookupDerivedComponent(self, derived_name, comp.name) orelse break :blk false;
            break :blk component.procedure;
        },
        else => false,
    };
}

fn actualExprIsAssumedRank(self: *context.Context, expr: *ast.Expr) bool {
    return switch (expr.*) {
        .identifier => |name| blk: {
            const idx = resolve_symbols.findSymbolIndex(self, name) orelse break :blk false;
            break :blk dimsRepresentAssumedRank(self.symbols.items[idx].dims);
        },
        else => false,
    };
}

fn actualExprIsNullWithMold(expr: *ast.Expr) bool {
    return switch (expr.*) {
        .call_or_subscript => |call| std.ascii.eqlIgnoreCase(call.name, "null") and call.args.len > 0,
        else => false,
    };
}

fn dimsRepresentAssumedRank(dims: []const *ast.Expr) bool {
    if (dims.len != 1) return false;
    return switch (dims[0].*) {
        .dim_range => |range| range.from_dotdot,
        else => false,
    };
}

pub fn isAbstractInterfaceProcedure(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        if (!decl.interface_block.abstract) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return true;
        }
    }
    var it = self.known_host_abstract_interfaces.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return true;
    }
    return false;
}

pub fn interfaceBlockHasProcedureHeader(interface_block: ast.InterfaceBlock, name: []const u8) bool {
    for (interface_block.procedure_headers) |proc_header| {
        if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return true;
    }
    return false;
}

pub fn abstractInterfaceNameBlocksVariableUse(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        switch (decl) {
            .interface_block => |interface_block| {
                if (!interface_block.abstract) continue;
                for (interface_block.procedure_headers) |proc_header| {
                    if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return true;
                }
            },
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return false;
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return false;
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return false;
                }
            },
            .parameter => |parameter_decl| {
                for (parameter_decl.assigns) |assign| {
                    if (std.ascii.eqlIgnoreCase(assign.name, name)) return false;
                }
            },
            .common => |common_decl| {
                for (common_decl.blocks) |block| {
                    for (block.items) |item| {
                        if (std.ascii.eqlIgnoreCase(item.name, name)) return false;
                    }
                }
            },
            .bind_entity => |bind_decl| {
                for (bind_decl.names) |bind_name| {
                    if (std.ascii.eqlIgnoreCase(bind_name, name)) return false;
                }
            },
            else => {},
        }
    }
    if (!isAbstractInterfaceProcedure(self, name)) return false;
    return resolve_symbols.findSymbolIndex(self, name) == null;
}

fn lookupGenericSpecificSig(
    self: *context.Context,
    proc_name: []const u8,
    source: ast.DeclSource,
) ?context.Context.ProcedureSig {
    if (resolve_symbols.lookupKnownProcedureSig(self, proc_name)) |sig| return sig;
    if (source.owner_name) |owner_name| {
        const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, proc_name }) catch return null;
        if (resolve_symbols.lookupKnownProcedureSig(self, qualified)) |sig| return sig;
    }
    return lookupQualifiedProcedureSigBySuffix(self, proc_name);
}

fn lookupQualifiedProcedureSigBySuffix(self: *context.Context, proc_name: []const u8) ?context.Context.ProcedureSig {
    const suffix = std.fmt.allocPrint(self.arena, "::{s}", .{proc_name}) catch return null;
    var matched: ?context.Context.ProcedureSig = null;
    var it = self.known_procedure_sigs.iterator();
    while (it.next()) |entry| {
        if (!std.ascii.endsWithIgnoreCase(entry.key_ptr.*, suffix)) continue;
        if (matched != null) return null;
        matched = entry.value_ptr.*;
    }
    return matched;
}

fn interfaceProcedureSig(
    self: *context.Context,
    proc_header: ast.InterfaceProcedure,
) ?context.Context.ProcedureSig {
    const args = procedure_inference.inferInterfaceProcedureArgSigs(self.arena, self.unit, proc_header) catch return null;
    return .{
        .kind = proc_header.kind,
        .arg_count = proc_header.args.len,
        .alt_return_count = proc_header.alt_return_dummy_count,
        .args = args,
        .pure = proc_header.pure,
        .elemental = proc_header.elemental,
        .is_pointer = if (proc_header.kind == .function) procedure_inference.interfaceProcedureResultAttrs(proc_header).pointer else false,
        .result_rank = if (proc_header.kind == .function) procedure_inference.interfaceProcedureResultRank(proc_header) else 0,
        .result_type_spec = if (proc_header.kind == .function) procedure_inference.interfaceProcedureResultTypeSpec(self.unit, proc_header) else null,
        .result_shape_signature = if (proc_header.kind == .function) procedure_inference.interfaceProcedureResultShapeSignature(self.arena, proc_header) catch return null else &.{},
        .result_allocatable = if (proc_header.kind == .function) procedure_inference.interfaceProcedureResultAttrs(proc_header).allocatable else false,
        .result_contiguous = if (proc_header.kind == .function) procedure_inference.interfaceProcedureResultAttrs(proc_header).contiguous else false,
        .result_procedure_pointer = if (proc_header.kind == .function) procedure_inference.interfaceProcedureResultAttrs(proc_header).procedure_pointer else false,
        .actual_requires_explicit_interface = true,
        .definition_known_from_current_program = false,
    };
}

fn findInterfaceProcedureDeclSource(
    proc_header: ast.InterfaceProcedure,
    formal_name: []const u8,
) ?ast.DeclSource {
    const count = @min(proc_header.decls.len, proc_header.decl_sources.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        if (!declMentionsName(proc_header.decls[idx], formal_name)) continue;
        return proc_header.decl_sources[idx];
    }
    return null;
}

fn declMentionsName(decl: ast.Decl, name: []const u8) bool {
    return switch (decl) {
        .type_decl => |type_decl| declaratorsContainName(type_decl.items, name),
        .procedure => |procedure_decl| declaratorsContainName(procedure_decl.items, name),
        .dimension => |dimension_decl| declaratorsContainName(dimension_decl.items, name),
        .intent => |intent_decl| namesContainName(intent_decl.names, name),
        .optional => |optional_decl| namesContainName(optional_decl.names, name),
        .external => |external_decl| namesContainName(external_decl.names, name),
        else => false,
    };
}

fn declaratorsContainName(items: []const ast.Declarator, name: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
    }
    return false;
}

fn namesContainName(names: []const []const u8, name: []const u8) bool {
    for (names) |item_name| {
        if (std.ascii.eqlIgnoreCase(item_name, name)) return true;
    }
    return false;
}

fn appendUniqueSource(out: *std.array_list.Managed(ast.DeclSource), source: ast.DeclSource) !void {
    for (out.items) |existing| {
        if (existing.line == source.line and
            existing.column == source.column and
            std.mem.eql(u8, existing.text, source.text))
        {
            return;
        }
    }
    try out.append(source);
}

fn singleTargetGenericInterfaceSig(
    self: *context.Context,
    interface_block: ast.InterfaceBlock,
) ?context.Context.ProcedureSig {
    const total = interface_block.module_procedures.len +
        interface_block.specific_procedures.len +
        interface_block.procedures.len +
        interface_block.procedure_headers.len;
    if (total != 1) return null;

    if (interface_block.procedure_headers.len == 1) {
        return resolve_symbols.lookupKnownProcedureSig(self, interface_block.procedure_headers[0].name);
    }
    if (interface_block.module_procedures.len == 1) {
        const proc_name = interface_block.module_procedures[0];
        if (resolve_symbols.lookupKnownProcedureSig(self, proc_name)) |sig| return sig;
        const source = interface_block.module_procedure_sources[0];
        if (source.owner_name) |owner_name| {
            const qualified = std.fmt.allocPrint(self.arena, "{s}::{s}", .{ owner_name, proc_name }) catch return null;
            return resolve_symbols.lookupKnownProcedureSig(self, qualified);
        }
        return null;
    }
    if (interface_block.specific_procedures.len == 1) {
        return resolve_symbols.lookupKnownProcedureSig(self, interface_block.specific_procedures[0]);
    }
    if (interface_block.procedures.len == 1) {
        return resolve_symbols.lookupKnownProcedureSig(self, interface_block.procedures[0]);
    }
    return null;
}

fn genericRequiredArgCount(sig: context.Context.ProcedureSig) usize {
    var count: usize = 0;
    for (sig.args) |arg| {
        if (!arg.optional) count += 1;
    }
    return count;
}

fn exprArgsMatchGenericSig(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    args: []*ast.Expr,
) bool {
    const min_count = genericRequiredArgCount(sig);
    if (args.len < min_count or args.len > sig.arg_count) return false;
    const count = @min(sig.args.len, args.len);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        if (!exprArgMatchesGenericFormal(self, sig, sig.args[idx], args[idx])) return false;
    }
    return true;
}

fn callArgsMatchGenericSig(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    args: []const ast.CallArg,
) bool {
    var expr_count: usize = 0;
    for (args) |arg| {
        if (arg == .expr) expr_count += 1;
    }
    const min_count = genericRequiredArgCount(sig);
    if (expr_count < min_count or expr_count > sig.arg_count) return false;
    var formal_idx: usize = 0;
    for (args) |arg| {
        if (arg != .expr) continue;
        if (formal_idx >= sig.args.len) break;
        if (!exprArgMatchesGenericFormal(self, sig, sig.args[formal_idx], arg.expr.value)) return false;
        formal_idx += 1;
    }
    return true;
}

fn exprArgMatchesGenericFormal(
    self: *context.Context,
    sig: context.Context.ProcedureSig,
    formal: context.Context.ProcedureSig.ArgSig,
    actual_expr: *ast.Expr,
) bool {
    if (formal.is_procedure) return true;
    const actual_spec = resolve_expr.exprTypeSpec(self, actual_expr) catch return false;
    const actual_rank = resolve_expr.exprRank(self, actual_expr);
    if (!genericActualTypeCompatible(self, formal.type_spec, actual_spec)) return false;
    if (formal.assumed_rank) return true;
    if (formal.rank == 0 and actual_rank > 0 and sig.elemental) return true;
    return formal.rank == actual_rank;
}

fn genericActualTypeCompatible(
    self: *context.Context,
    expected: symbols.TypeSpec,
    actual: symbols.TypeSpec,
) bool {
    if (expected.assumed_type) return true;
    if (actual.assumed_type) return false;
    if (expected.polymorphic and expected.derived_type_name == null) return true;
    if (expected.lowered_kind != actual.lowered_kind) return false;
    if (expected.lowered_kind != .derived) return true;

    const expected_name = expected.derived_type_name orelse return false;
    const actual_name = actual.derived_type_name orelse return false;
    return if (expected.polymorphic)
        resolve_symbols.isSameOrExtension(self, actual_name, expected_name)
    else
        resolve_symbols.areConcreteDerivedTypesCompatible(self, expected_name, actual_name);
}

fn procedureSigRequiresExplicitInterface(sig: context.Context.ProcedureSig) bool {
    if (sig.result_rank != 0) return true;
    if (sig.is_pointer or sig.result_allocatable or sig.result_contiguous or sig.result_procedure_pointer) return true;
    for (sig.args) |arg| {
        if (arg.optional) return true;
        if (arg.requires_descriptor) return true;
        if (arg.pointer or arg.allocatable or arg.contiguous) return true;
        if (arg.asynchronous or arg.volatile_attr) return true;
        if (arg.type_spec.assumed_type) return true;
        if (arg.type_spec.polymorphic) return true;
    }
    return false;
}

fn genericSigHasDerivedOrProcedureRequiredArg(sig: context.Context.ProcedureSig) bool {
    for (sig.args) |arg| {
        if (arg.optional) continue;
        if (arg.is_procedure) return true;
        if (arg.type_spec.assumed_type) return true;
        if (arg.type_spec.lowered_kind == .derived) return true;
    }
    return false;
}

fn genericArgEquivalent(a: context.Context.ProcedureSig.ArgSig, b: context.Context.ProcedureSig.ArgSig) bool {
    if (a.is_procedure or b.is_procedure) return a.is_procedure and b.is_procedure;
    if (a.type_spec.assumed_type or b.type_spec.assumed_type) return a.type_spec.assumed_type and b.type_spec.assumed_type;
    if (a.rank != b.rank) return false;
    if (a.pointer != b.pointer) return false;
    if (a.allocatable != b.allocatable) return false;
    if (a.type_spec.lowered_kind != b.type_spec.lowered_kind) return false;
    if (a.type_spec.lowered_kind == .derived) {
        if (a.type_spec.derived_type_name == null or b.type_spec.derived_type_name == null) return false;
        return std.ascii.eqlIgnoreCase(a.type_spec.derived_type_name.?, b.type_spec.derived_type_name.?);
    }
    return true;
}
