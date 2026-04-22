const std = @import("std");
const ast = @import("../../ast/nodes.zig");
const catalog = @import("../../common/error_catalog.zig");
const context = @import("context.zig");
const interface_bind_c = @import("resolve_specs/interfaces_bind_c.zig");
const symbols_mod = @import("resolve_symbols.zig");

pub fn validateBindCCharacters(ctx: *context.Context) !void {
    if (!ctx.unit.bind_c) return;
    if (ctx.unit.kind != .subroutine and ctx.unit.kind != .function) return;

    for (ctx.unit.args) |arg_name| {
        const info = findCharacterDummyDeclInfo(ctx, arg_name) orelse continue;

        if (info.allocatable or info.pointer) {
            if (info.char_len_deferred) continue;
            setBindCCharacterDummyDiagnostic(
                ctx,
                info.source orelse continue,
                if (info.allocatable) "Allocatable" else "Pointer",
                arg_name,
                std.fmt.allocPrint(
                    ctx.arena,
                    "{s} character dummy argument '{s}' at .1. must have deferred length as procedure '{s}' is BIND(C)",
                    .{ if (info.allocatable) "Allocatable" else "Pointer", arg_name, ctx.unit.name },
                ) catch return error.OutOfMemory,
            );
            return error.InvalidCharLen;
        }

        if (info.value_attr) {
            if (characterLengthForm(info) == .const_one) continue;
            setBindCCharacterDummyDiagnostic(
                ctx,
                info.source orelse continue,
                "Character",
                arg_name,
                std.fmt.allocPrint(
                    ctx.arena,
                    "Character dummy argument '{s}' at .1. must be of length 1 as it has the VALUE attribute",
                    .{arg_name},
                ) catch return error.OutOfMemory,
            );
            return error.InvalidCharLen;
        }

        if (isAssumedRank(info.dims) or isAssumedShape(info.dims)) continue;
        switch (characterLengthForm(info)) {
            .const_one, .assumed => continue,
            .deferred, .other => {},
        }

        setBindCCharacterDummyDiagnostic(
            ctx,
            info.source orelse continue,
            "Character",
            arg_name,
            std.fmt.allocPrint(
                ctx.arena,
                "Character dummy argument '{s}' at .1. must be of constant length of one or assumed length, unless it has assumed shape or assumed rank, as procedure '{s}' has the BIND(C) attribute",
                .{ arg_name, ctx.unit.name },
            ) catch return error.OutOfMemory,
        );
        return error.InvalidCharLen;
    }
}

pub fn validateBindCFunctionResult(ctx: *context.Context) !void {
    if (!ctx.unit.bind_c or ctx.unit.kind != .function) return;
    const result = findFunctionResult(ctx) orelse return;
    const source = ctx.unit.source;
    const line = if (source.line == 0) 1 else source.line;
    const column = if (source.column == 0) 1 else source.column;

    if (result.not_c_interoperable) {
        ctx.setDiagnosticDetailed(
            line,
            column,
            catalog.semantic.invalid_char_len.code,
            "BIND(C) function result is not C interoperable",
            source.text,
            &.{.{ .text = "Interoperable BIND(C) function results may not be polymorphic, POINTER, or ALLOCATABLE entities." }},
            &.{.{ .text = "Use an interoperable scalar result type, or remove BIND(C) from the function." }},
        );
        return error.InvalidCharLen;
    }

    if (result.has_array) {
        ctx.setDiagnosticDetailed(
            line,
            column,
            catalog.semantic.invalid_char_len.code,
            "BIND(C) function result cannot be an array",
            source.text,
            &.{.{ .text = "Interoperable BIND(C) function results must be scalar." }},
            &.{.{ .text = "Make the function result scalar, or remove BIND(C) from the function." }},
        );
        return error.InvalidCharLen;
    }
    if (!result.is_character) return;
    if (result.length_is_one) return;

    ctx.setDiagnosticDetailed(
        line,
        column,
        catalog.semantic.invalid_char_len.code,
        "BIND(C) character function result must have length 1",
        source.text,
        &.{.{ .text = "Interoperable BIND(C) CHARACTER function results must have CHARACTER length one." }},
        &.{.{ .text = "Use CHARACTER(LEN=1), or remove BIND(C) from the function." }},
    );
    return error.InvalidCharLen;
}

pub fn validateBindCDummyInteroperability(ctx: *context.Context) !void {
    if (!ctx.unit.bind_c) return;
    if (ctx.unit.kind != .subroutine and ctx.unit.kind != .function) return;

    for (ctx.unit.args) |arg_name| {
        const info = findDummyDeclInfo(ctx, arg_name) orelse continue;
        if (!info.polymorphic) continue;

        const source = info.source orelse continue;
        ctx.setDiagnosticDetailed(
            if (source.line == 0) 1 else source.line,
            if (source.column == 0) 1 else source.column,
            catalog.semantic.invalid_char_len.code,
            std.fmt.allocPrint(ctx.arena, "'{s}' is not C interoperable", .{arg_name}) catch "is not C interoperable",
            source.text,
            &.{.{ .text = "A BIND(C) dummy argument may not be a polymorphic CLASS entity." }},
            &.{.{ .text = "Use an interoperable TYPE dummy argument, or remove BIND(C) from the procedure." }},
        );
        return error.InvalidCharLen;
    }
}

pub fn validateBindCInterfaceBlocks(ctx: *context.Context) !void {
    var first_error: ?anyerror = null;
    for (ctx.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            interface_bind_c.validateBindCInterfaceProcedure(ctx, proc_header) catch |err| {
                if (!ctx.usesExplicitDiagnosticBag()) return err;
                if (first_error == null) first_error = err;
                continue;
            };
        }
    }
    if (first_error) |err| return err;
}

fn setBindCCharacterDummyDiagnostic(
    ctx: *context.Context,
    decl_source: ast.DeclSource,
    entity_kind: []const u8,
    name: []const u8,
    message: []const u8,
) void {
    const notes = [_]@import("../../common/diagnostic.zig").DiagnosticMessage{
        .{ .text = "BIND(C) character interoperability is restricted to C-compatible lengths and descriptor forms." },
    };
    const helps = [_]@import("../../common/diagnostic.zig").DiagnosticMessage{
        .{ .text = std.fmt.allocPrint(ctx.arena, "Adjust {s} '{s}' to a C-compatible CHARACTER declaration.", .{ entity_kind, name }) catch "Adjust this CHARACTER dummy to a C-compatible declaration." },
    };
    ctx.setDiagnosticDetailed(
        if (decl_source.line == 0) 1 else decl_source.line,
        if (decl_source.column == 0) 1 else decl_source.column,
        catalog.semantic.invalid_char_len.code,
        message,
        decl_source.text,
        &notes,
        &helps,
    );
}

fn findTypeDeclSource(ctx: *context.Context, target_name: []const u8) ?ast.DeclSource {
    for (ctx.unit.decls, 0..) |decl, decl_idx| {
        if (decl != .type_decl) continue;
        for (decl.type_decl.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, target_name)) continue;
            if (decl_idx < ctx.unit.decl_sources.len) return ctx.unit.decl_sources[decl_idx];
            return null;
        }
    }
    return null;
}

const CharacterDummyDeclInfo = struct {
    source: ?ast.DeclSource = null,
    dims: []const *ast.Expr = &.{},
    char_len_expr: ?*ast.Expr = null,
    char_len_deferred: bool = false,
    allocatable: bool = false,
    pointer: bool = false,
    value_attr: bool = false,
};

const DummyDeclInfo = struct {
    source: ?ast.DeclSource = null,
    polymorphic: bool = false,
};

const CharacterLengthForm = enum {
    const_one,
    assumed,
    deferred,
    other,
};

const CharacterResultInfo = struct {
    is_character: bool = false,
    has_array: bool = false,
    length_is_one: bool = true,
    not_c_interoperable: bool = false,
};

fn findCharacterDummyDeclInfo(ctx: *context.Context, target_name: []const u8) ?CharacterDummyDeclInfo {
    var info: ?CharacterDummyDeclInfo = null;

    for (ctx.unit.decls, 0..) |decl, decl_idx| {
        switch (decl) {
            .type_decl => |type_decl| {
                if (type_decl.type_kind != .character) continue;
                for (type_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, target_name)) continue;
                    var current = info orelse CharacterDummyDeclInfo{};
                    if (decl_idx < ctx.unit.decl_sources.len) current.source = ctx.unit.decl_sources[decl_idx];
                    current.dims = item.dims;
                    current.char_len_expr = item.char_len;
                    current.char_len_deferred = item.char_len_deferred;
                    current.allocatable = type_decl.allocatable;
                    current.pointer = type_decl.pointer;
                    current.value_attr = type_decl.value_attr;
                    info = current;
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (!std.ascii.eqlIgnoreCase(item.name, target_name)) continue;
                    var current = info orelse CharacterDummyDeclInfo{};
                    current.dims = item.dims;
                    current.allocatable = current.allocatable or dimension_decl.allocatable;
                    current.pointer = current.pointer or dimension_decl.pointer;
                    info = current;
                }
            },
            .value => |value_decl| {
                for (value_decl.names) |value_name| {
                    if (!std.ascii.eqlIgnoreCase(value_name, target_name)) continue;
                    var current = info orelse CharacterDummyDeclInfo{};
                    current.value_attr = true;
                    info = current;
                }
            },
            else => {},
        }
    }

    return info;
}

fn findDummyDeclInfo(ctx: *context.Context, target_name: []const u8) ?DummyDeclInfo {
    for (ctx.unit.decls, 0..) |decl, decl_idx| {
        if (decl != .type_decl) continue;
        for (decl.type_decl.items) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, target_name)) continue;
            return .{
                .source = if (decl_idx < ctx.unit.decl_sources.len) ctx.unit.decl_sources[decl_idx] else null,
                .polymorphic = decl.type_decl.polymorphic,
            };
        }
    }
    return null;
}

fn characterLengthForm(info: CharacterDummyDeclInfo) CharacterLengthForm {
    if (info.char_len_deferred) return .deferred;
    const len_expr = info.char_len_expr orelse return .const_one;
    return switch (len_expr.*) {
        .literal => |lit| switch (lit.kind) {
            .integer => if (std.mem.eql(u8, lit.text, "1")) .const_one else .other,
            .assumed_size => .assumed,
            else => .other,
        },
        else => .other,
    };
}

fn findFunctionResult(ctx: *context.Context) ?CharacterResultInfo {
    const result_name = ctx.unit.result_name orelse ctx.unit.name;
    const idx = symbols_mod.findSymbolIndex(ctx, result_name) orelse return null;
    const sym = ctx.symbols.items[idx];
    return .{
        .is_character = sym.isCharacter(),
        .has_array = sym.dims.len != 0,
        .length_is_one = !sym.isCharacter() or
            (sym.effectiveCharLenKind() == .constant and (sym.effectiveCharLen() orelse 1) == 1),
        .not_c_interoperable = sym.type_spec.polymorphic or sym.is_allocatable or sym.is_pointer,
    };
}

fn isAssumedShape(dims: []const *ast.Expr) bool {
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

fn isAssumedRank(dims: []const *ast.Expr) bool {
    if (dims.len != 1) return false;
    return switch (dims[0].*) {
        .dim_range => |range| range.from_dotdot,
        else => false,
    };
}
