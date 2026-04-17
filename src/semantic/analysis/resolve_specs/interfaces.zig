const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const common_diag = @import("../../../common/diagnostic.zig");
const type_specs = @import("../../../common/type_specs.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const symbols = @import("../../symbol/mod.zig");
const symbols_mod = @import("../resolve_symbols.zig");
const decls = @import("../resolve_decls.zig");
const diagnostics = @import("interfaces/diagnostics.zig");
const procedure_interfaces = @import("../check_statements/procedure_interfaces.zig");
const split_api = @import("../../split/api/mod.zig");
const helpers = @import("helpers.zig");
const generic_interface_ambiguity = @import("../generic_interface_ambiguity.zig");

const setAttributeConflictDiagnostic = helpers.setAttributeConflictDiagnostic;
const setSourceDiagnostic = helpers.setSourceDiagnostic;
const resolvedDeclTypeSpec = helpers.resolvedDeclTypeSpec;
const typeKindName = helpers.typeKindName;
const constValueKindName = helpers.constValueKindName;
const GenericSpecificSource = diagnostics.GenericSpecificSource;
const appendUniqueDeclSource = diagnostics.appendUniqueDeclSource;
const appendUniqueGenericSpecificSource = diagnostics.appendUniqueGenericSpecificSource;
const declSourceSame = diagnostics.declSourceSame;
const genericSpecificDeclSource = diagnostics.genericSpecificDeclSource;
const genericSpecificSourceSame = diagnostics.genericSpecificSourceSame;
const setAbstractInterfaceNamedDiagnostic = diagnostics.setAbstractInterfaceNamedDiagnostic;
const setAmbiguousGenericSpecificDiagnostic = diagnostics.setAmbiguousGenericSpecificDiagnostic;
const setKindSelectorMustBeIntrinsicDiagnostic = diagnostics.setKindSelectorMustBeIntrinsicDiagnostic;
const setKnownProcedureCompatibilityDiagnostic = diagnostics.setKnownProcedureCompatibilityDiagnostic;
const setMixedGenericSpecificKindDiagnostic = diagnostics.setMixedGenericSpecificKindDiagnostic;
const setNonProcedureSpecificDiagnostic = diagnostics.setNonProcedureSpecificDiagnostic;
const setSingleNoteHelpSourceDiagnostic = diagnostics.setSingleNoteHelpSourceDiagnostic;
const setStructuredSourceDiagnostic = diagnostics.setStructuredSourceDiagnostic;
const setUnknownSpecificProcedureDiagnostic = diagnostics.setUnknownSpecificProcedureDiagnostic;

pub fn validateExplicitInterfaceBlock(self: *context.Context, interface_block: ast.InterfaceBlock) !void {
    const imported_prelude_decl = if (self.current_decl_index) |decl_idx|
        decl_idx < self.unit.prelude_decl_count
    else
        false;
    if (interface_block.abstract and interface_block.name != null) {
        setAbstractInterfaceNamedDiagnostic(self);
        return error.UnexpectedToken;
    }
    if (interface_block.abstract and interface_block.module_procedures.len != 0) {
        const source = interface_block.module_procedure_sources[0];
        setAbstractInterfaceModuleProcedureDiagnostic(self, source);
        return error.DuplicateDeclaration;
    }
    var first_error: ?anyerror = null;
    for (interface_block.procedure_headers) |proc_header| {
        if (!imported_prelude_decl and self.unit.owner_name == null and self.unit.kind != .module and std.ascii.eqlIgnoreCase(proc_header.name, self.unit.name)) {
            setEnclosingProcedureDiagnostic(self, proc_header.source);
            if (first_error == null) first_error = error.DuplicateDeclaration;
            continue;
        }
        if (interface_block.abstract) {
            if (symbols_mod.findSymbolIndex(self, proc_header.name)) |idx| {
                const sym = self.symbols.items[idx];
                if (sym.is_pointer) {
                    self.setDiagnosticDetailed(
                        if (proc_header.source.line == 0) 1 else proc_header.source.line,
                        if (proc_header.source.column == 0) 1 else proc_header.source.column,
                        catalog.semantic.duplicate_declaration.code,
                        "PROCEDURE POINTER attribute conflicts with ABSTRACT attribute",
                        proc_header.source.text,
                        &.{.{ .text = "An ABSTRACT interface procedure name cannot reuse a visible POINTER object declaration of the same name." }},
                        &.{.{ .text = "Rename the POINTER object or the ABSTRACT interface procedure." }},
                    );
                    if (first_error == null) first_error = error.DuplicateDeclaration;
                    continue;
                }
            }
        }
        if (interface_block.abstract and proc_header.bind_name != null) {
            setAbstractInterfaceBindNameDiagnostic(self, proc_header);
            if (first_error == null) first_error = error.DuplicateDeclaration;
            continue;
        }
        if (interfaceBlockProcedureUsesIntrinsicTypeName(proc_header)) {
            setIntrinsicTypeNameConflictDiagnostic(self, proc_header.source);
            if (first_error == null) first_error = error.DuplicateDeclaration;
            continue;
        }
        if (!imported_prelude_decl) {
            if (validateInterfaceProcedureDerivedTypes(self, proc_header)) |err| {
                if (!self.usesExplicitDiagnosticBag()) return err;
                if (first_error == null) first_error = err;
                continue;
            }
        }
        if (!imported_prelude_decl and self.unit.kind != .module) {
            if (!interfaceProcedureDeclaresCurrentDummy(self, proc_header.name)) {
                if (validateKnownProcedureCompatibility(self, proc_header)) |err| {
                    if (!self.usesExplicitDiagnosticBag()) return err;
                    if (first_error == null) first_error = err;
                    continue;
                }
            }
        }
        if (proc_header.kind != .function) continue;
        if (symbols_mod.findSymbolIndex(self, proc_header.name)) |idx| {
            const sym = self.symbols.items[idx];
            if (sym.dims.len != 0 or sym.is_allocatable) {
                setFunctionResultDeclaredOutsideInterfaceDiagnostic(self, proc_header.source);
                if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
                if (first_error == null) first_error = error.DuplicateDeclaration;
                continue;
            }
        }
        const attrs = interfaceProcedureResultAttrs(proc_header);
        if (attrs.has_deferred_shape and !attrs.allocatable and !attrs.pointer) {
            setFunctionResultDeferredShapeDiagnostic(self, proc_header.source);
            if (!self.usesExplicitDiagnosticBag()) return error.DuplicateDeclaration;
            if (first_error == null) first_error = error.DuplicateDeclaration;
        }
    }
    if (validateGenericInterfaceProcedures(self, interface_block)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }
    if (validateVisiblePreludeGenericSpecificReuse(self, interface_block)) |err| {
        if (!self.usesExplicitDiagnosticBag()) return err;
        if (first_error == null) first_error = err;
    }
    if (first_error) |err| return err;
}

fn interfaceProcedureDeclaresCurrentDummy(self: *context.Context, name: []const u8) bool {
    for (self.unit.args) |arg_name| {
        if (std.ascii.eqlIgnoreCase(arg_name, name)) return true;
    }
    return false;
}

fn setAbstractInterfaceModuleProcedureDiagnostic(self: *context.Context, source: ast.DeclSource) void {
    setSingleNoteHelpSourceDiagnostic(
        self,
        source,
        catalog.semantic.duplicate_declaration.code,
        "must be in a generic module interface",
        "invalid MODULE PROCEDURE here",
        "MODULE PROCEDURE is only valid inside a named generic interface, not inside ABSTRACT INTERFACE",
        "change this block to a concrete generic INTERFACE, or remove MODULE PROCEDURE from the ABSTRACT INTERFACE",
    );
}

fn setEnclosingProcedureDiagnostic(self: *context.Context, source: ast.DeclSource) void {
    setSingleNoteHelpSourceDiagnostic(
        self,
        source,
        catalog.semantic.duplicate_declaration.code,
        "enclosing procedure",
        "conflicts with enclosing procedure here",
        "a local explicit INTERFACE body may not declare a procedure with the same name as its enclosing procedure",
        "rename the explicit interface procedure, or move the interface to a scope where the enclosing procedure name does not conflict",
    );
}

fn setIntrinsicTypeNameConflictDiagnostic(self: *context.Context, source: ast.DeclSource) void {
    setSingleNoteHelpSourceDiagnostic(
        self,
        source,
        catalog.semantic.duplicate_declaration.code,
        "cannot be the same as an intrinsic type",
        "intrinsic type-name conflict here",
        "an explicit INTERFACE procedure name may not shadow an intrinsic type keyword",
        "rename the procedure so it no longer collides with the intrinsic type name",
    );
}

fn setFunctionResultDeclaredOutsideInterfaceDiagnostic(self: *context.Context, source: ast.DeclSource) void {
    setSingleNoteHelpSourceDiagnostic(
        self,
        source,
        catalog.semantic.duplicate_declaration.code,
        "function result declared outside its INTERFACE body",
        "outer result declaration conflicts here",
        "the function result symbol must be fully characterized inside the INTERFACE body itself",
        "move the function result declaration into the INTERFACE body, or remove the conflicting outer declaration",
    );
}

fn setFunctionResultDeferredShapeDiagnostic(self: *context.Context, source: ast.DeclSource) void {
    setSingleNoteHelpSourceDiagnostic(
        self,
        source,
        catalog.semantic.duplicate_declaration.code,
        "function result cannot have a deferred shape",
        "invalid deferred-shape result here",
        "an explicit interface function result may not have deferred shape unless it is POINTER or ALLOCATABLE",
        "remove the deferred-shape result, or mark the result POINTER/ALLOCATABLE if that is the intended interface",
    );
}

fn validateVisiblePreludeGenericSpecificReuse(self: *context.Context, interface_block: ast.InterfaceBlock) ?anyerror {
    const imported_prelude_decl = if (self.current_decl_index) |decl_idx|
        decl_idx < self.unit.prelude_decl_count
    else
        false;
    if (imported_prelude_decl) return null;
    if (interface_block.name == null) return null;

    for (interface_block.procedure_headers) |proc_header| {
        if (interfaceProcedureDeclaresCurrentDummy(self, proc_header.name)) continue;
        var conflicting = std.array_list.Managed(ast.DeclSource).init(self.arena);
        appendPreludeInterfaceProcedureSources(self, &conflicting, proc_header.name) catch return error.OutOfMemory;
        if (conflicting.items.len == 0) continue;
        setVisiblePreludeGenericSpecificReuseDiagnostic(self, proc_header.source, conflicting.items);
        return error.DuplicateDeclaration;
    }
    for (interface_block.specific_procedures, 0..) |procedure_name, idx| {
        if (interfaceProcedureDeclaresCurrentDummy(self, procedure_name)) continue;
        var conflicting = std.array_list.Managed(ast.DeclSource).init(self.arena);
        appendPreludeInterfaceProcedureSources(self, &conflicting, procedure_name) catch return error.OutOfMemory;
        if (conflicting.items.len == 0) continue;
        setVisiblePreludeGenericSpecificReuseDiagnostic(self, interface_block.specific_procedure_sources[idx], conflicting.items);
        return error.DuplicateDeclaration;
    }
    for (interface_block.module_procedures, 0..) |procedure_name, idx| {
        if (interfaceProcedureDeclaresCurrentDummy(self, procedure_name)) continue;
        var conflicting = std.array_list.Managed(ast.DeclSource).init(self.arena);
        appendPreludeInterfaceProcedureSources(self, &conflicting, procedure_name) catch return error.OutOfMemory;
        if (conflicting.items.len == 0) continue;
        setVisiblePreludeGenericSpecificReuseDiagnostic(self, interface_block.module_procedure_sources[idx], conflicting.items);
        return error.DuplicateDeclaration;
    }
    for (interface_block.procedures, 0..) |procedure_name, idx| {
        if (interfaceProcedureDeclaresCurrentDummy(self, procedure_name)) continue;
        var conflicting = std.array_list.Managed(ast.DeclSource).init(self.arena);
        appendPreludeInterfaceProcedureSources(self, &conflicting, procedure_name) catch return error.OutOfMemory;
        if (conflicting.items.len == 0) continue;
        setVisiblePreludeGenericSpecificReuseDiagnostic(self, interface_block.procedure_sources[idx], conflicting.items);
        return error.DuplicateDeclaration;
    }
    return null;
}

fn appendPreludeInterfaceProcedureSources(
    self: *context.Context,
    out: *std.array_list.Managed(ast.DeclSource),
    procedure_name: []const u8,
) !void {
    var decl_idx: usize = 0;
    while (decl_idx < self.unit.prelude_decl_count and decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        const decl = self.unit.decls[decl_idx];
        if (decl != .interface_block) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (!std.ascii.eqlIgnoreCase(proc_header.name, procedure_name)) continue;
            try appendUniqueDeclSource(out, proc_header.source);
        }
        for (decl.interface_block.specific_procedures, 0..) |proc_name, idx| {
            if (!std.ascii.eqlIgnoreCase(proc_name, procedure_name)) continue;
            try appendUniqueDeclSource(out, decl.interface_block.specific_procedure_sources[idx]);
        }
        for (decl.interface_block.module_procedures, 0..) |proc_name, idx| {
            if (!std.ascii.eqlIgnoreCase(proc_name, procedure_name)) continue;
            try appendUniqueDeclSource(out, decl.interface_block.module_procedure_sources[idx]);
        }
        for (decl.interface_block.procedures, 0..) |proc_name, idx| {
            if (!std.ascii.eqlIgnoreCase(proc_name, procedure_name)) continue;
            try appendUniqueDeclSource(out, decl.interface_block.procedure_sources[idx]);
        }
    }
}

fn setVisiblePreludeGenericSpecificReuseDiagnostic(
    self: *context.Context,
    current_source: ast.DeclSource,
    conflicting: []const ast.DeclSource,
) void {
    const notes = [_]common_diag.DiagnosticMessage{
        .{ .text = "a specific already made visible through USE is being introduced again in this INTERFACE block" },
    };
    const helps = [_]common_diag.DiagnosticMessage{
        .{ .text = "remove the duplicate specific from the local INTERFACE block or rename the visible imported entry" },
    };
    const secondary_spans = self.arena.alloc(common_diag.DiagnosticSpan, conflicting.len) catch return;
    for (conflicting, 0..) |source, idx| {
        secondary_spans[idx] = .{
            .file_path = "",
            .line = if (source.line == 0) 1 else source.line,
            .column = if (source.column == 0) 1 else source.column,
            .line_text = source.text,
            .label = "visible prelude specific here",
        };
    }
    self.setCurrentDeclSource(current_source);
    self.setDiagnosticStructured(
        if (current_source.line == 0) 1 else current_source.line,
        if (current_source.column == 0) 1 else current_source.column,
        catalog.semantic.duplicate_declaration.code,
        "is already present in the interface",
        current_source.text,
        "duplicate specific here",
        notes[0..],
        helps[0..],
        secondary_spans,
    );
}

fn setAbstractInterfaceBindNameDiagnostic(
    self: *context.Context,
    proc_header: ast.InterfaceProcedure,
) void {
    const notes = [_]common_diag.DiagnosticMessage{
        .{ .text = "ABSTRACT INTERFACE procedure headers may use BIND(C), but they may not specify an explicit NAME= binding label" },
        .{ .text = "Expecting END INTERFACE statement" },
    };
    const helps = [_]common_diag.DiagnosticMessage{
        .{ .text = "remove NAME= from the ABSTRACT INTERFACE header, or make this a concrete interface if a binding label is required" },
    };
    const secondary_spans = [_]common_diag.DiagnosticSpan{.{
        .file_path = "",
        .line = if (proc_header.end_source.line == 0) 1 else proc_header.end_source.line,
        .column = if (proc_header.end_source.column == 0) 1 else proc_header.end_source.column,
        .line_text = proc_header.end_source.text,
        .label = "END INTERFACE expected here",
    }};
    self.setCurrentDeclSource(proc_header.source);
    self.setDiagnosticStructured(
        if (proc_header.source.line == 0) 1 else proc_header.source.line,
        if (proc_header.source.column == 0) 1 else proc_header.source.column,
        catalog.semantic.duplicate_declaration.code,
        "NAME not allowed on BIND.C. for ABSTRACT INTERFACE",
        proc_header.source.text,
        "invalid BIND(C) NAME here",
        notes[0..],
        helps[0..],
        secondary_spans[0..],
    );
}

fn validateInterfaceProcedureDerivedTypes(self: *context.Context, proc_header: ast.InterfaceProcedure) ?anyerror {
    if (self.unit.kind == .module) return null;
    if (proc_header.type_spec) |type_spec| {
        if (type_spec.type_kind == .derived) {
            const derived_name = type_spec.derived_type_name orelse return error.UnexpectedTypeDecl;
            if (!interfaceProcedureCanUseDerivedType(self, proc_header, derived_name)) {
                setInterfaceProcedureDerivedTypeDiagnostic(self, proc_header, derived_name);
                return error.UnexpectedTypeDecl;
            }
        }
    }
    for (proc_header.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                if (type_decl.type_kind != .derived) continue;
                const derived_name = type_decl.derived_type_name orelse return error.UnexpectedTypeDecl;
                if (interfaceProcedureCanUseDerivedType(self, proc_header, derived_name)) continue;
                setInterfaceProcedureDerivedTypeDiagnostic(self, proc_header, derived_name);
                return error.UnexpectedTypeDecl;
            },
            .procedure => |procedure_decl| {
                switch (procedure_decl.interface) {
                    .type_spec => |proc_type| {
                        if (proc_type.type_kind != .derived) continue;
                        const derived_name = proc_type.derived_type_name orelse return error.UnexpectedTypeDecl;
                        if (interfaceProcedureCanUseDerivedType(self, proc_header, derived_name)) continue;
                        setInterfaceProcedureDerivedTypeDiagnostic(self, proc_header, derived_name);
                        return error.UnexpectedTypeDecl;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    return null;
}

fn setInterfaceProcedureDerivedTypeDiagnostic(
    self: *context.Context,
    proc_header: ast.InterfaceProcedure,
    derived_name: []const u8,
) void {
    var note_buf: [256]u8 = undefined;
    const note_text = std.fmt.bufPrint(
        &note_buf,
        "derived type '{s}' is referenced from the INTERFACE body before it becomes visible there",
        .{derived_name},
    ) catch "derived type is referenced from the INTERFACE body before it becomes visible there";
    const helps = [_]common_diag.DiagnosticMessage{
        .{ .text = "define the derived type before the host INTERFACE uses it, or import a type that is already visible" },
    };
    if (findUnitDerivedTypeDeclSource(self, derived_name)) |decl_source| {
        if (!declSourceSame(decl_source, proc_header.source)) {
            const secondary_spans = [_]common_diag.DiagnosticSpan{.{
                .file_path = "",
                .line = if (decl_source.line == 0) 1 else decl_source.line,
                .column = if (decl_source.column == 0) 1 else decl_source.column,
                .line_text = decl_source.text,
                .label = "derived type declared later here",
            }};
            const notes = [_]common_diag.DiagnosticMessage{.{ .text = note_text }};
            self.setCurrentDeclSource(proc_header.source);
            self.setDiagnosticStructured(
                if (proc_header.source.line == 0) 1 else proc_header.source.line,
                if (proc_header.source.column == 0) 1 else proc_header.source.column,
                catalog.semantic.duplicate_declaration.code,
                "is being used before it is defined",
                proc_header.source.text,
                "uses derived type before definition here",
                notes[0..],
                helps[0..],
                secondary_spans[0..],
            );
            return;
        }
    }
    const notes = [_]common_diag.DiagnosticMessage{.{ .text = note_text }};
    self.setCurrentDeclSource(proc_header.source);
    self.setDiagnosticStructured(
        if (proc_header.source.line == 0) 1 else proc_header.source.line,
        if (proc_header.source.column == 0) 1 else proc_header.source.column,
        catalog.semantic.duplicate_declaration.code,
        "is being used before it is defined",
        proc_header.source.text,
        "uses derived type before definition here",
        notes[0..],
        helps[0..],
        &.{},
    );
}

fn interfaceProcedureCanUseDerivedType(
    self: *context.Context,
    proc_header: ast.InterfaceProcedure,
    target_name: []const u8,
) bool {
    if (interfaceProcedureDefinesDerivedType(proc_header, target_name)) return true;
    if (!interfaceProcedureImportsName(proc_header, target_name)) return false;
    return symbols_mod.hasDerivedType(self, target_name);
}

fn interfaceProcedureDefinesDerivedType(proc_header: ast.InterfaceProcedure, target_name: []const u8) bool {
    for (proc_header.decls) |decl| {
        if (decl != .derived_type_def) continue;
        if (std.ascii.eqlIgnoreCase(decl.derived_type_def.name, target_name)) return true;
    }
    return false;
}

fn interfaceProcedureImportsName(proc_header: ast.InterfaceProcedure, target_name: []const u8) bool {
    for (proc_header.decls) |decl| {
        if (decl != .import) continue;
        if (decl.import.names.len == 0) return true;
        for (decl.import.names) |name| {
            if (std.ascii.eqlIgnoreCase(name, target_name)) return true;
        }
    }
    return false;
}

const GenericInterfaceKind = enum { subroutine, function };
const GenericSpecific = struct {
    source: GenericSpecificSource,
    sig: context.Context.ProcedureSig,
};

fn validateGenericInterfaceProcedures(self: *context.Context, interface_block: ast.InterfaceBlock) ?anyerror {
    if (interface_block.name == null) return null;

    var generic_kind: ?GenericInterfaceKind = null;
    var generic_kind_source: ?GenericSpecificSource = null;
    var specifics = std.array_list.Managed(GenericSpecific).init(self.arena);

    for (interface_block.procedure_headers) |proc_header| {
        const sig = symbols_mod.lookupKnownProcedureSig(self, proc_header.name) orelse continue;
        const kind: GenericInterfaceKind = switch (proc_header.kind) {
            .subroutine => .subroutine,
            .function => .function,
            else => continue,
        };
        const current_source: GenericSpecificSource = .{ .header = proc_header };
        specifics.append(.{ .source = current_source, .sig = sig }) catch return error.OutOfMemory;
        if (generic_kind == null) {
            generic_kind = kind;
            generic_kind_source = current_source;
            continue;
        }
        if (generic_kind.? != kind) {
            setMixedGenericSpecificKindDiagnostic(self, current_source, generic_kind_source.?);
            return error.DuplicateDeclaration;
        }
    }

    for (interface_block.specific_procedures, 0..) |procedure_name, idx| {
        const sig = symbols_mod.lookupKnownProcedureSig(self, procedure_name) orelse {
            if (!setNonProcedureSpecificDiagnostic(self, interface_block.specific_procedure_sources[idx], procedure_name)) {
                setUnknownSpecificProcedureDiagnostic(self, interface_block.specific_procedure_sources[idx]);
            }
            return error.UnknownSymbol;
        };
        const kind: GenericInterfaceKind = switch (sig.kind) {
            .subroutine => .subroutine,
            .function => .function,
            else => {
                if (!setNonProcedureSpecificDiagnostic(self, interface_block.specific_procedure_sources[idx], procedure_name)) {
                    setUnknownSpecificProcedureDiagnostic(self, interface_block.specific_procedure_sources[idx]);
                }
                return error.UnknownSymbol;
            },
        };
        const current_source: GenericSpecificSource = .{ .source = interface_block.specific_procedure_sources[idx] };
        specifics.append(.{ .source = current_source, .sig = sig }) catch return error.OutOfMemory;
        if (generic_kind == null) {
            generic_kind = kind;
            generic_kind_source = current_source;
            continue;
        }
        if (generic_kind.? != kind) {
            setMixedGenericSpecificKindDiagnostic(self, current_source, generic_kind_source.?);
            return error.DuplicateDeclaration;
        }
    }

    for (interface_block.module_procedures, 0..) |procedure_name, idx| {
        const sig = symbols_mod.lookupKnownProcedureSig(self, procedure_name) orelse continue;
        const kind: GenericInterfaceKind = switch (sig.kind) {
            .subroutine => .subroutine,
            .function => .function,
            else => continue,
        };
        const current_source: GenericSpecificSource = .{ .source = interface_block.module_procedure_sources[idx] };
        specifics.append(.{ .source = current_source, .sig = sig }) catch return error.OutOfMemory;
        if (generic_kind == null) {
            generic_kind = kind;
            generic_kind_source = current_source;
            continue;
        }
        if (generic_kind.? != kind) {
            setMixedGenericSpecificKindDiagnostic(self, current_source, generic_kind_source.?);
            return error.DuplicateDeclaration;
        }
    }

    for (interface_block.procedures, 0..) |procedure_name, idx| {
        const sig = symbols_mod.lookupKnownProcedureSig(self, procedure_name) orelse {
            if (!setNonProcedureSpecificDiagnostic(self, interface_block.procedure_sources[idx], procedure_name)) {
                setUnknownSpecificProcedureDiagnostic(self, interface_block.procedure_sources[idx]);
            }
            return error.UnknownSymbol;
        };
        const kind: GenericInterfaceKind = switch (sig.kind) {
            .subroutine => .subroutine,
            .function => .function,
            else => {
                if (!setNonProcedureSpecificDiagnostic(self, interface_block.procedure_sources[idx], procedure_name)) {
                    setUnknownSpecificProcedureDiagnostic(self, interface_block.procedure_sources[idx]);
                }
                return error.UnknownSymbol;
            },
        };
        const current_source: GenericSpecificSource = .{ .source = interface_block.procedure_sources[idx] };
        specifics.append(.{ .source = current_source, .sig = sig }) catch return error.OutOfMemory;
        if (generic_kind == null) {
            generic_kind = kind;
            generic_kind_source = current_source;
            continue;
        }
        if (generic_kind.? != kind) {
            setMixedGenericSpecificKindDiagnostic(self, current_source, generic_kind_source.?);
            return error.DuplicateDeclaration;
        }
    }

    var best_current: ?GenericSpecificSource = null;
    var best_conflicting: []const GenericSpecificSource = &.{};

    var current_idx: usize = 0;
    while (current_idx < specifics.items.len) : (current_idx += 1) {
        var conflicting = std.array_list.Managed(GenericSpecificSource).init(self.arena);
        var previous_idx: usize = 0;
        while (previous_idx < current_idx) : (previous_idx += 1) {
            if (genericSpecificSourceSame(specifics.items[previous_idx].source, specifics.items[current_idx].source)) continue;
            if (!generic_interface_ambiguity.genericSpecificAmbiguous(specifics.items[previous_idx].sig, specifics.items[current_idx].sig)) continue;
            appendUniqueGenericSpecificSource(&conflicting, specifics.items[previous_idx].source) catch return error.OutOfMemory;
        }
        if (conflicting.items.len == 0) continue;
        if (best_current == null or conflicting.items.len >= best_conflicting.len) {
            best_current = specifics.items[current_idx].source;
            best_conflicting = self.arena.dupe(GenericSpecificSource, conflicting.items) catch return error.OutOfMemory;
        }
    }

    if (best_current) |current| {
        setAmbiguousGenericSpecificDiagnostic(self, current, best_conflicting);
        return error.DuplicateDeclaration;
    }

    return null;
}

fn findUnitDerivedTypeDeclSource(self: *context.Context, target_name: []const u8) ?ast.DeclSource {
    for (self.unit.decls, 0..) |decl, decl_idx| {
        if (decl != .derived_type_def) continue;
        if (!std.ascii.eqlIgnoreCase(decl.derived_type_def.name, target_name)) continue;
        if (decl_idx < self.unit.decl_sources.len) return self.unit.decl_sources[decl_idx];
        return null;
    }
    return null;
}

fn interfaceBlockProcedureUsesIntrinsicTypeName(proc_header: ast.InterfaceProcedure) bool {
    return std.ascii.eqlIgnoreCase(proc_header.name, "real") or
        std.ascii.eqlIgnoreCase(proc_header.name, "integer") or
        std.ascii.eqlIgnoreCase(proc_header.name, "logical") or
        std.ascii.eqlIgnoreCase(proc_header.name, "complex") or
        std.ascii.eqlIgnoreCase(proc_header.name, "character") or
        std.ascii.eqlIgnoreCase(proc_header.name, "doubleprecision");
}

fn kindSelectorMustBeIntrinsic(self: *context.Context, kind_selector: ?*ast.Expr) !void {
    const selector = kind_selector orelse return;
    switch (selector.*) {
        .call_or_subscript => |call| {
            if (symbols_mod.isIntrinsicName(call.name)) return;
            if (procedure_interfaces.hasVisibleProcedureReference(self, call.name)) {
                setKindSelectorMustBeIntrinsicDiagnostic(self, call.name);
                return error.UnexpectedTypeDecl;
            }
        },
        else => {},
    }
}

fn validateKnownProcedureCompatibility(self: *context.Context, proc_header: ast.InterfaceProcedure) ?anyerror {
    const known_sig = lookupKnownProcedureSigForInterfaceValidation(self, proc_header.name) orelse return null;
    if (known_sig.kind != proc_header.kind) {
        setKnownProcedureCompatibilityDiagnostic(
            self,
            proc_header,
            "Interface mismatch in dummy procedure",
            "explicit interface kind conflicts here",
            "the explicit INTERFACE body disagrees with the visible known procedure kind",
            "match the INTERFACE header to the visible procedure kind, or rename one of the procedures",
        );
        return error.InvalidArgumentCount;
    }
    const expected_args = split_api.inferInterfaceProcedureArgSigs(self.arena, self.unit, proc_header) catch return error.OutOfMemory;
    if (expected_args.len != known_sig.args.len or proc_header.alt_return_dummy_count != known_sig.alt_return_count) {
        setKnownProcedureCompatibilityDiagnostic(
            self,
            proc_header,
            "Interface mismatch in dummy procedure",
            "explicit interface dummy list conflicts here",
            "the explicit INTERFACE body disagrees with the visible known procedure dummy argument list",
            "match the dummy argument list between the INTERFACE body and the visible procedure",
        );
        return error.InvalidArgumentCount;
    }
    for (expected_args, known_sig.args) |expected_arg, known_arg| {
        if (knownProcedureDummyArgCompatible(expected_arg, known_arg)) continue;
        const message = std.fmt.allocPrint(
            self.arena,
            "Interface mismatch in dummy procedure ({s}/{s})",
            .{ formatProcedureDummyArgSig(self, expected_arg), formatProcedureDummyArgSig(self, known_arg) },
        ) catch "Interface mismatch in dummy procedure";
        setKnownProcedureCompatibilityDiagnostic(
            self,
            proc_header,
            message,
            "explicit interface dummy declaration conflicts here",
            "the explicit INTERFACE body disagrees with the visible known procedure dummy argument type",
            "match the dummy argument type between the INTERFACE body and the visible procedure",
        );
        return error.InvalidArgumentCount;
    }
    if (proc_header.kind != .function) return null;

    const expected_rank = split_api.interfaceProcedureResultRank(proc_header);
    if (known_sig.result_rank != expected_rank) {
        setKnownProcedureCompatibilityDiagnostic(
            self,
            proc_header,
            "Rank mismatch in function result",
            "function result rank conflicts here",
            "the explicit INTERFACE body disagrees with the visible known function result rank",
            "match the function result rank between the INTERFACE body and the visible procedure",
        );
        return error.InvalidArgumentCount;
    }

    const expected_type = interfaceProcedureResultTypeSpecForValidation(self, proc_header) orelse return null;
    const actual_type = known_sig.result_type_spec orelse symbols_mod.lookupKnownFunctionResolvedSpec(self, proc_header.name) orelse return null;
    if (expected_type.lowered_kind != actual_type.lowered_kind) {
        setKnownProcedureCompatibilityDiagnostic(
            self,
            proc_header,
            "Type mismatch in function result",
            "function result type conflicts here",
            "the explicit INTERFACE body disagrees with the visible known function result type",
            "match the function result type between the INTERFACE body and the visible procedure",
        );
        return error.InvalidArgumentCount;
    }
    if (expected_type.lowered_kind == .derived) {
        if (expected_type.derived_type_name != null and actual_type.derived_type_name != null and
            !std.ascii.eqlIgnoreCase(expected_type.derived_type_name.?, actual_type.derived_type_name.?))
        {
            setKnownProcedureCompatibilityDiagnostic(
                self,
                proc_header,
                "Type mismatch in function result",
                "function result type conflicts here",
                "the explicit INTERFACE body disagrees with the visible known function result type",
                "match the function result type between the INTERFACE body and the visible procedure",
            );
            return error.InvalidArgumentCount;
        }
    }
    return null;
}

fn lookupKnownProcedureSigForInterfaceValidation(
    self: *context.Context,
    name: []const u8,
) ?context.Context.ProcedureSig {
    if (visiblePreludeInterfaceProcedureSig(self, name)) |sig| return sig;

    var match: ?context.Context.ProcedureSig = null;
    var it = self.known_procedure_sigs.iterator();
    while (it.next()) |entry| {
        const sig = entry.value_ptr.*;
        if (!sig.definition_known_from_current_program) continue;
        const key = entry.key_ptr.*;
        const base_name = if (std.mem.lastIndexOf(u8, key, "::")) |sep| key[sep + 2 ..] else key;
        if (!std.ascii.eqlIgnoreCase(base_name, name)) continue;
        if (match != null) return null;
        match = sig;
    }
    return match orelse symbols_mod.lookupKnownProcedureSig(self, name);
}

fn visiblePreludeInterfaceProcedureSig(
    self: *context.Context,
    name: []const u8,
) ?context.Context.ProcedureSig {
    var decl_idx: usize = 0;
    while (decl_idx < self.unit.prelude_decl_count and decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        const decl = self.unit.decls[decl_idx];
        if (decl != .interface_block) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (!std.ascii.eqlIgnoreCase(proc_header.name, name)) continue;
            return .{
                .kind = proc_header.kind,
                .arg_count = proc_header.args.len,
                .alt_return_count = proc_header.alt_return_dummy_count,
                .args = split_api.inferInterfaceProcedureArgSigs(self.arena, self.unit, proc_header) catch return null,
                .pure = proc_header.pure,
                .elemental = proc_header.elemental,
                .is_pointer = false,
                .result_rank = split_api.interfaceProcedureResultRank(proc_header),
                .result_type_spec = if (proc_header.kind == .function)
                    interfaceProcedureResultTypeSpecForValidation(self, proc_header)
                else
                    null,
                .result_shape_signature = &.{},
                .result_allocatable = if (proc_header.kind == .function) interfaceProcedureResultAttrs(proc_header).allocatable else false,
                .result_contiguous = false,
                .result_procedure_pointer = false,
                .actual_requires_explicit_interface = true,
                .definition_known_from_current_program = false,
            };
        }
    }
    return null;
}

fn knownProcedureDummyArgCompatible(
    expected: context.Context.ProcedureSig.ArgSig,
    known: context.Context.ProcedureSig.ArgSig,
) bool {
    if (expected.is_procedure != known.is_procedure) return false;
    if (expected.is_procedure) {
        return expected.procedure_kind == known.procedure_kind and
            expected.procedure_arg_count == known.procedure_arg_count and
            expected.procedure_alt_return_count == known.procedure_alt_return_count;
    }
    if (expected.rank != known.rank) return false;
    if (expected.assumed_rank != known.assumed_rank) return false;
    if (expected.pointer != known.pointer) return false;
    if (expected.allocatable != known.allocatable) return false;
    return typeSpecsMatchForKnownProcedure(expected.type_spec, known.type_spec);
}

fn typeSpecsMatchForKnownProcedure(a: symbols.TypeSpec, b: symbols.TypeSpec) bool {
    if (a.lowered_kind != b.lowered_kind) return false;
    if (a.kind_value != null and b.kind_value != null and a.kind_value.? != b.kind_value.?) return false;
    if (a.lowered_kind == .character) {
        if (a.char_len_kind != b.char_len_kind) return false;
        if (a.char_len != b.char_len) return false;
    }
    if (a.lowered_kind == .derived) {
        if (a.polymorphic != b.polymorphic) return false;
        if (a.assumed_type != b.assumed_type) return false;
        if (a.derived_type_name == null or b.derived_type_name == null) {
            return a.derived_type_name == null and b.derived_type_name == null;
        }
        if (!std.ascii.eqlIgnoreCase(a.derived_type_name.?, b.derived_type_name.?)) return false;
    }
    return true;
}

fn formatProcedureDummyArgSig(self: *context.Context, arg: context.Context.ProcedureSig.ArgSig) []const u8 {
    if (arg.is_procedure) {
        return switch (arg.procedure_kind orelse .subroutine) {
            .function => "FUNCTION",
            .subroutine => "SUBROUTINE",
            else => "PROCEDURE",
        };
    }
    return formatTypeSpecForKnownProcedure(self, arg.type_spec);
}

fn formatTypeSpecForKnownProcedure(self: *context.Context, type_spec: symbols.TypeSpec) []const u8 {
    return switch (type_spec.lowered_kind) {
        .integer => std.fmt.allocPrint(self.arena, "INTEGER({d})", .{type_spec.kind_value orelse self.target_layout.default_integer_bits}) catch "INTEGER(4)",
        .real => std.fmt.allocPrint(self.arena, "REAL({d})", .{type_spec.kind_value orelse 4}) catch "REAL(4)",
        .double_precision => std.fmt.allocPrint(self.arena, "REAL({d})", .{type_spec.kind_value orelse 8}) catch "REAL(8)",
        .complex => std.fmt.allocPrint(self.arena, "COMPLEX({d})", .{type_spec.kind_value orelse 4}) catch "COMPLEX(4)",
        .complex_double => std.fmt.allocPrint(self.arena, "COMPLEX({d})", .{type_spec.kind_value orelse 8}) catch "COMPLEX(8)",
        .logical => std.fmt.allocPrint(self.arena, "LOGICAL({d})", .{type_spec.kind_value orelse self.target_layout.default_integer_bits}) catch "LOGICAL(4)",
        .character => blk: {
            const len_text = switch (type_spec.char_len_kind) {
                .assumed, .deferred => "*",
                .constant => std.fmt.allocPrint(self.arena, "{d}", .{type_spec.char_len orelse 1}) catch "1",
                .none => "1",
            };
            const kind_value = type_spec.kind_value orelse 1;
            break :blk if (kind_value == 1)
                std.fmt.allocPrint(self.arena, "CHARACTER({s})", .{len_text}) catch "CHARACTER(*)"
            else
                std.fmt.allocPrint(self.arena, "CHARACTER({s},{d})", .{ len_text, kind_value }) catch "CHARACTER(*)";
        },
        .derived => blk: {
            if (type_spec.assumed_type) break :blk "TYPE(*)";
            if (type_spec.polymorphic) {
                if (type_spec.derived_type_name) |name| {
                    break :blk std.fmt.allocPrint(self.arena, "CLASS({s})", .{name}) catch "CLASS(*)";
                }
                break :blk "CLASS(*)";
            }
            if (type_spec.derived_type_name) |name| {
                break :blk std.fmt.allocPrint(self.arena, "TYPE({s})", .{name}) catch "TYPE(*)";
            }
            break :blk "TYPE(*)";
        },
    };
}

fn interfaceProcedureResultTypeSpecForValidation(
    self: *context.Context,
    proc_header: ast.InterfaceProcedure,
) ?symbols.TypeSpec {
    if (proc_header.kind != .function) return null;
    const result_name = proc_header.result_name orelse proc_header.name;
    for (proc_header.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    return applyInterfaceResultDeclaratorCharLen(type_specs.typeSpecFromTypeDecl(type_decl), item);
                }
            },
            else => {},
        }
    }
    if (proc_header.type_spec) |type_spec| {
        return type_specs.typeSpecFromProcedureType(type_spec);
    }
    return symbols_mod.implicitTypeSpec(self, proc_header.name);
}

fn applyInterfaceResultDeclaratorCharLen(type_spec: symbols.TypeSpec, declarator: ast.Declarator) symbols.TypeSpec {
    if (declarator.char_len_deferred) return type_spec.withCharacterLength(.deferred, null);
    if (type_spec.lowered_kind != .character) return type_spec.withCharacterLength(.none, null);
    const char_len = switch ((declarator.char_len orelse return type_spec.withCharacterLength(.constant, 1)).*) {
        .literal => |lit| switch (lit.kind) {
            .integer => std.fmt.parseInt(usize, lit.text, 10) catch null,
            else => null,
        },
        else => null,
    };
    return type_spec.withCharacterLength(
        if (char_len != null) .constant else if (declarator.char_len != null) .deferred else .constant,
        char_len orelse if (declarator.char_len == null) 1 else null,
    );
}

const InterfaceProcedureResultAttrs = struct {
    has_deferred_shape: bool = false,
    pointer: bool = false,
    allocatable: bool = false,
};

fn interfaceProcedureResultAttrs(proc_header: ast.InterfaceProcedure) InterfaceProcedureResultAttrs {
    var attrs: InterfaceProcedureResultAttrs = .{};
    for (proc_header.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, proc_header.name)) continue;
                    if (hasDeferredShape(item.dims)) attrs.has_deferred_shape = true;
                    if (type_decl.pointer) attrs.pointer = true;
                    if (type_decl.allocatable) attrs.allocatable = true;
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, proc_header.name)) continue;
                    if (hasDeferredShape(item.dims)) attrs.has_deferred_shape = true;
                    if (procedure_decl.pointer) attrs.pointer = true;
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, proc_header.name)) continue;
                    if (hasDeferredShape(item.dims)) attrs.has_deferred_shape = true;
                    if (dimension_decl.pointer) attrs.pointer = true;
                    if (dimension_decl.allocatable) attrs.allocatable = true;
                }
            },
            else => {},
        }
    }
    return attrs;
}

fn hasDeferredShape(dims: []const *ast.Expr) bool {
    for (dims) |dim| {
        switch (dim.*) {
            .dim_range => |range| {
                if (range.assumed_shape and range.lower == null) return true;
            },
            else => {},
        }
    }
    return false;
}
