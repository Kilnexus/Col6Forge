const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");
const bind_c_shared = @import("bind_c_shared.zig");

pub fn validateBindCInterfaceProcedure(self: *context.Context, proc_header: ast.InterfaceProcedure) !void {
    if (!proc_header.bind_c and proc_header.bind_name == null) return;
    try validateBindCInterfaceDummies(self, proc_header);
    if (proc_header.kind != .function) return;

    const result = findCharacterResult(proc_header) orelse return;
    if (result.has_array) {
        self.setDiagnosticDetailed(
            if (proc_header.source.line == 0) 1 else proc_header.source.line,
            if (proc_header.source.column == 0) 1 else proc_header.source.column,
            catalog.semantic.invalid_char_len.code,
            "BIND(C) character function result cannot be an array",
            proc_header.source.text,
            &.{.{ .text = "Interoperable BIND(C) CHARACTER function results must be scalar." }},
            &.{.{ .text = "Make the function result scalar, or remove BIND(C) from the interface." }},
        );
        return error.InvalidCharLen;
    }
    if (!result.length_is_one) {
        self.setDiagnosticDetailed(
            if (proc_header.source.line == 0) 1 else proc_header.source.line,
            if (proc_header.source.column == 0) 1 else proc_header.source.column,
            catalog.semantic.invalid_char_len.code,
            "BIND(C) character function result must have length 1",
            proc_header.source.text,
            &.{.{ .text = "Interoperable BIND(C) CHARACTER function results must have CHARACTER length one." }},
            &.{.{ .text = "Use CHARACTER(LEN=1), or remove BIND(C) from the function interface." }},
        );
        return error.InvalidCharLen;
    }
}

fn validateBindCInterfaceDummies(self: *context.Context, proc_header: ast.InterfaceProcedure) !void {
    for (proc_header.decls, 0..) |decl, decl_idx| {
        if (decl != .type_decl) continue;
        const type_decl = decl.type_decl;
        const source = if (decl_idx < proc_header.decl_sources.len) proc_header.decl_sources[decl_idx] else proc_header.source;
        for (type_decl.items) |item| {
            if (!nameInList(proc_header.args, item.name)) continue;
            if (type_decl.optional and type_decl.value_attr) {
                return emitInterfaceBindCDummyDiagnostic(self, source, "BIND(C) dummy argument cannot have both OPTIONAL and VALUE attributes");
            }
            if (type_decl.polymorphic) {
                return emitInterfaceBindCDummyDiagnostic(self, source, "BIND(C) dummy argument is not C interoperable");
            }
            if (type_decl.type_kind == .character and (type_decl.allocatable or type_decl.pointer) and !item.char_len_deferred) {
                return emitInterfaceBindCDummyDiagnostic(self, source, "BIND(C) character dummy argument must have deferred length");
            }
        }
    }
}

fn emitInterfaceBindCDummyDiagnostic(self: *context.Context, source: ast.DeclSource, message: []const u8) !void {
    self.setDiagnosticDetailed(
        if (source.line == 0) 1 else source.line,
        if (source.column == 0) 1 else source.column,
        catalog.semantic.invalid_char_len.code,
        message,
        source.text,
        &.{.{ .text = "BIND(C) interface dummy arguments must satisfy C interoperability constraints." }},
        &.{.{ .text = "Adjust the dummy declaration or remove BIND(C) from the interface procedure." }},
    );
    return error.InvalidCharLen;
}

fn nameInList(names: []const []const u8, target: []const u8) bool {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, target)) return true;
    }
    return false;
}

const CharacterResultInfo = struct {
    has_array: bool = false,
    length_is_one: bool = true,
};

fn findCharacterResult(proc_header: ast.InterfaceProcedure) ?CharacterResultInfo {
    const result_name = proc_header.result_name orelse proc_header.name;
    var info: ?CharacterResultInfo = if (proc_header.type_spec) |type_spec|
        if (type_spec.type_kind == .character) CharacterResultInfo{} else null
    else
        null;

    for (proc_header.decls) |decl| {
        switch (decl) {
            .type_decl => |type_decl| {
                if (type_decl.type_kind != .character) continue;
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    var out: CharacterResultInfo = .{};
                    out.has_array = item.dims.len != 0;
                    out.length_is_one = bind_c_shared.characterDeclaratorHasLengthOne(item);
                    info = out;
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, result_name)) continue;
                    if (info == null) info = .{};
                    info.?.has_array = info.?.has_array or item.dims.len != 0;
                }
            },
            else => {},
        }
    }

    return info;
}
