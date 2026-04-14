const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const context = @import("../context.zig");

pub fn validateBindCInterfaceProcedure(self: *context.Context, proc_header: ast.InterfaceProcedure) !void {
    if (!proc_header.bind_c and proc_header.bind_name == null) return;
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
                    out.length_is_one = characterDeclaratorHasLengthOne(item);
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

fn characterDeclaratorHasLengthOne(item: ast.Declarator) bool {
    const len_expr = item.char_len orelse return true;
    return switch (len_expr.*) {
        .literal => |lit| lit.kind == .integer and std.mem.eql(u8, lit.text, "1"),
        else => false,
    };
}
