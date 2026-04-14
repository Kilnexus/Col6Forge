const std = @import("std");
const ast = @import("../../../ast/nodes.zig");
const catalog = @import("../../../common/error_catalog.zig");
const case_insensitive = @import("../../../common/case_insensitive.zig");
const context = @import("../token_stream.zig");
const parse_diag = @import("../diagnostic.zig");
const stmt = @import("../stmt/mod.zig");

const Decl = ast.Decl;
const DeclSource = ast.DeclSource;
const ProgramUnit = ast.ProgramUnit;
const LineParser = context.LineParser;

pub const ModulePrelude = struct {
    decls: []const Decl,
    decl_sources: []const DeclSource,
};

const CaseInsensitiveStringContext = case_insensitive.StringContext;

fn CaseInsensitiveStringHashMap(comptime V: type) type {
    return case_insensitive.HashMap(V);
}

pub const ModulePreludeMap = CaseInsensitiveStringHashMap(ModulePrelude);

pub const ImportedPreludeDecls = struct {
    decls: []const Decl,
    decl_sources: []const DeclSource,
};

pub fn lookupPreludeOrBuiltin(
    arena: std.mem.Allocator,
    module_name: []const u8,
    preludes: *const ModulePreludeMap,
) !?ModulePrelude {
    if (preludes.get(module_name)) |prelude| return prelude;
    return try builtinModulePrelude(arena, module_name);
}

pub fn importPreludeDecls(
    arena: std.mem.Allocator,
    decls: []const Decl,
    decl_sources: []const DeclSource,
    module_uses: []const ast.UseStmt,
    preludes: *const ModulePreludeMap,
    diag_bag: *parse_diag.Bag,
) !ImportedPreludeDecls {
    var imported_decls = decls;
    var imported_sources = decl_sources;
    var seen_full_imports = CaseInsensitiveStringHashMap(void).initContext(arena, .{});
    for (module_uses) |module_use| {
        const prelude = try lookupPreludeOrBuiltin(arena, module_use.module_name, preludes) orelse continue;
        if (!module_use.has_only and module_use.only_items.len == 0) {
            if (seen_full_imports.contains(module_use.module_name)) continue;
        }
        const selected = if (!module_use.has_only and module_use.only_items.len == 0)
            ImportedPreludeDecls{
                .decls = prelude.decls,
                .decl_sources = prelude.decl_sources,
            }
        else if (!module_use.has_only)
            try renameFullPreludeDecls(arena, prelude, module_use)
        else
            try selectPreludeDecls(arena, prelude, module_use, diag_bag);
        var filtered_selected = std.array_list.Managed(Decl).init(arena);
        defer filtered_selected.deinit();
        var filtered_sources = std.array_list.Managed(DeclSource).init(arena);
        defer filtered_sources.deinit();
        for (selected.decls, 0..) |selected_decl, idx| {
            const selected_source = if (idx < selected.decl_sources.len) selected.decl_sources[idx] else DeclSource{};
            if (declSliceHasEquivalentImportedDecl(imported_decls, imported_sources, selected_decl, selected_source)) continue;
            try filtered_selected.append(selected_decl);
            try filtered_sources.append(selected_source);
        }
        if (filtered_selected.items.len == 0) {
            if (!module_use.has_only and module_use.only_items.len == 0) {
                try seen_full_imports.put(module_use.module_name, {});
            }
            continue;
        }

        const combined_decls = try arena.alloc(Decl, filtered_selected.items.len + imported_decls.len);
        @memcpy(combined_decls[0..filtered_selected.items.len], filtered_selected.items);
        @memcpy(combined_decls[filtered_selected.items.len..], imported_decls);
        imported_decls = combined_decls;

        const combined_sources = try arena.alloc(DeclSource, filtered_sources.items.len + imported_sources.len);
        @memcpy(combined_sources[0..filtered_sources.items.len], filtered_sources.items);
        @memcpy(combined_sources[filtered_sources.items.len..], imported_sources);
        imported_sources = combined_sources;
        if (!module_use.has_only and module_use.only_items.len == 0) {
            try seen_full_imports.put(module_use.module_name, {});
        }
    }
    return .{ .decls = imported_decls, .decl_sources = imported_sources };
}

fn builtinModulePrelude(arena: std.mem.Allocator, module_name: []const u8) !?ModulePrelude {
    if (std.ascii.eqlIgnoreCase(module_name, "iso_c_binding")) {
        return try isoCBindingPrelude(arena);
    }
    return null;
}

fn isoCBindingPrelude(arena: std.mem.Allocator) !ModulePrelude {
    var decls = std.array_list.Managed(Decl).init(arena);
    var decl_sources = std.array_list.Managed(DeclSource).init(arena);

    try appendBuiltinDerivedType(&decls, &decl_sources, "iso_c_binding", "c_ptr");
    try appendBuiltinDerivedType(&decls, &decl_sources, "iso_c_binding", "c_funptr");
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_int", 4);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_short", 2);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_long", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_long_long", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_int8_t", 1);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_int16_t", 2);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_int32_t", 4);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_int64_t", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_intmax_t", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_intptr_t", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_size_t", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_ptrdiff_t", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_signed_char", 1);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_char", 1);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_bool", 1);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_float", 4);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_double", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_long_double", 16);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_float_complex", 4);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_double_complex", 8);
    try appendBuiltinIntegerConstant(&decls, &decl_sources, "iso_c_binding", "c_long_double_complex", 16);
    try appendBuiltinCharacterConstant(&decls, &decl_sources, "iso_c_binding", "c_null_char", "\x00");
    try appendBuiltinDerivedObject(&decls, &decl_sources, "iso_c_binding", "c_ptr", "c_null_ptr");
    try appendBuiltinDerivedObject(&decls, &decl_sources, "iso_c_binding", "c_funptr", "c_null_funptr");

    return .{
        .decls = try decls.toOwnedSlice(),
        .decl_sources = try decl_sources.toOwnedSlice(),
    };
}

fn appendBuiltinDerivedType(
    decls: *std.array_list.Managed(Decl),
    decl_sources: *std.array_list.Managed(DeclSource),
    module_name: []const u8,
    name: []const u8,
) !void {
    try decls.append(.{
        .derived_type_def = .{
            .name = name,
            .bind_c = true,
        },
    });
    try decl_sources.append(builtinDeclSource(module_name));
}

fn appendBuiltinIntegerConstant(
    decls: *std.array_list.Managed(Decl),
    decl_sources: *std.array_list.Managed(DeclSource),
    module_name: []const u8,
    name: []const u8,
    value: i64,
) !void {
    const expr = try integerLiteralExpr(decls.allocator, value);
    const items = try decls.allocator.alloc(ast.Declarator, 1);
    items[0] = .{
        .name = name,
        .dims = &.{},
        .char_len = null,
        .init = expr,
    };
    try decls.append(.{
        .type_decl = .{
            .type_kind = .integer,
            .items = items,
            .parameter = true,
        },
    });
    try decl_sources.append(builtinDeclSource(module_name));
}

fn appendBuiltinCharacterConstant(
    decls: *std.array_list.Managed(Decl),
    decl_sources: *std.array_list.Managed(DeclSource),
    module_name: []const u8,
    name: []const u8,
    value: []const u8,
) !void {
    const init_expr = try stringLiteralExpr(decls.allocator, value);
    const char_len = try integerLiteralExpr(decls.allocator, 1);
    const items = try decls.allocator.alloc(ast.Declarator, 1);
    items[0] = .{
        .name = name,
        .dims = &.{},
        .char_len = char_len,
        .init = init_expr,
    };
    try decls.append(.{
        .type_decl = .{
            .type_kind = .character,
            .items = items,
            .parameter = true,
        },
    });
    try decl_sources.append(builtinDeclSource(module_name));
}

fn appendBuiltinDerivedObject(
    decls: *std.array_list.Managed(Decl),
    decl_sources: *std.array_list.Managed(DeclSource),
    module_name: []const u8,
    derived_type_name: []const u8,
    name: []const u8,
) !void {
    const items = try decls.allocator.alloc(ast.Declarator, 1);
    items[0] = .{
        .name = name,
        .dims = &.{},
        .char_len = null,
        .init = null,
    };
    try decls.append(.{
        .type_decl = .{
            .type_kind = .derived,
            .derived_type_name = derived_type_name,
            .items = items,
        },
    });
    try decl_sources.append(builtinDeclSource(module_name));
}

fn builtinDeclSource(module_name: []const u8) DeclSource {
    return .{
        .owner_name = module_name,
    };
}

fn integerLiteralExpr(arena: std.mem.Allocator, value: i64) !*ast.Expr {
    const text = try std.fmt.allocPrint(arena, "{d}", .{value});
    const expr = try arena.create(ast.Expr);
    expr.* = .{
        .literal = .{
            .kind = .integer,
            .text = text,
        },
    };
    return expr;
}

fn stringLiteralExpr(arena: std.mem.Allocator, value: []const u8) !*ast.Expr {
    const text = try std.fmt.allocPrint(arena, "'{s}'", .{value});
    const expr = try arena.create(ast.Expr);
    expr.* = .{
        .literal = .{
            .kind = .string,
            .text = text,
        },
    };
    return expr;
}

fn renameFullPreludeDecls(
    arena: std.mem.Allocator,
    prelude: ModulePrelude,
    use_stmt: ast.UseStmt,
) !ImportedPreludeDecls {
    var renamed_decls = std.array_list.Managed(Decl).init(arena);
    var renamed_sources = std.array_list.Managed(DeclSource).init(arena);

    for (prelude.decls, 0..) |decl_node, idx| {
        const local_name = if (preludeDeclExportedName(decl_node)) |exported_name|
            renamePreludeTypeName(exported_name, use_stmt.only_items)
        else
            null;
        try renamed_decls.append(try renamePreludeDecl(arena, decl_node, local_name, use_stmt.only_items));
        if (idx < prelude.decl_sources.len) {
            try renamed_sources.append(prelude.decl_sources[idx]);
        }
    }

    return .{
        .decls = try renamed_decls.toOwnedSlice(),
        .decl_sources = try renamed_sources.toOwnedSlice(),
    };
}

pub fn tryParsePreludeUseImport(lp: *LineParser, arena: std.mem.Allocator) !?ast.UseStmt {
    if (!lp.isKeywordSplit("USE")) return null;
    const stmt_node = try stmt.action_stmt.parseUseStatement(arena, lp);
    return stmt_node.use_stmt;
}

pub fn selectPreludeDecls(
    arena: std.mem.Allocator,
    prelude: ModulePrelude,
    use_stmt: ast.UseStmt,
    diag_bag: *parse_diag.Bag,
) !ImportedPreludeDecls {
    var selected_decls = std.array_list.Managed(Decl).init(arena);
    var selected_sources = std.array_list.Managed(DeclSource).init(arena);
    var seen = CaseInsensitiveStringHashMap(void).initContext(arena, .{});
    var missing_generic = false;

    for (use_stmt.only_items) |item| {
        if (item.generic_spec and !preludeHasDeclExport(prelude, item.remote_name)) {
            noteMissingGenericUseImport(diag_bag, use_stmt, item);
            missing_generic = true;
            continue;
        }
        try appendPreludeDeclByName(
            arena,
            prelude,
            item.remote_name,
            item.local_name,
            use_stmt.only_items,
            &selected_decls,
            &selected_sources,
            &seen,
        );
    }

    if (missing_generic) return error.UnexpectedToken;

    return .{
        .decls = try selected_decls.toOwnedSlice(),
        .decl_sources = try selected_sources.toOwnedSlice(),
    };
}

fn preludeHasDeclExport(prelude: ModulePrelude, remote_name: []const u8) bool {
    for (prelude.decls) |decl_node| {
        const exported_name = preludeDeclExportedName(decl_node) orelse continue;
        if (std.ascii.eqlIgnoreCase(exported_name, remote_name)) return true;
    }
    return false;
}

fn noteMissingGenericUseImport(diag_bag: *parse_diag.Bag, use_stmt: ast.UseStmt, item: ast.UseOnlyItem) void {
    const message = if (std.mem.startsWith(u8, item.remote_name, "operator("))
        std.fmt.allocPrint(diag_bag.allocator, "operator {s} referenced in USE, ONLY list not found in module '{s}'", .{ item.generic_display_name, use_stmt.module_name }) catch return
    else
        std.fmt.allocPrint(diag_bag.allocator, "generic {s} referenced in USE, ONLY list not found in module '{s}'", .{ item.remote_name, use_stmt.module_name }) catch return;
    defer diag_bag.allocator.free(message);
    diag_bag.set(
        if (use_stmt.source.line == 0) 1 else use_stmt.source.line,
        if (use_stmt.source.column == 0) 1 else use_stmt.source.column,
        catalog.parser.generic.code,
        message,
        use_stmt.source.text,
    );
}

fn appendPreludeDeclByName(
    arena: std.mem.Allocator,
    prelude: ModulePrelude,
    remote_name: []const u8,
    local_name: []const u8,
    only_items: []const ast.UseOnlyItem,
    out_decls: *std.array_list.Managed(Decl),
    out_sources: *std.array_list.Managed(DeclSource),
    seen: *CaseInsensitiveStringHashMap(void),
) anyerror!void {
    const seen_key = try preludeImportSeenKey(arena, remote_name, local_name);
    if (seen.contains(seen_key)) return;
    for (prelude.decls, 0..) |decl_node, decl_idx| {
        const exported_name = preludeDeclExportedName(decl_node) orelse continue;
        if (!std.ascii.eqlIgnoreCase(exported_name, remote_name)) continue;
        try seen.put(seen_key, {});
        try appendPreludeDeclDependencies(arena, prelude, decl_node, only_items, out_decls, out_sources, seen);
        try out_decls.append(try renamePreludeDecl(arena, decl_node, local_name, only_items));
        if (decl_idx < prelude.decl_sources.len) {
            try out_sources.append(prelude.decl_sources[decl_idx]);
        }
        return;
    }
}

fn appendPreludeDeclDependencies(
    arena: std.mem.Allocator,
    prelude: ModulePrelude,
    decl_node: Decl,
    only_items: []const ast.UseOnlyItem,
    out_decls: *std.array_list.Managed(Decl),
    out_sources: *std.array_list.Managed(DeclSource),
    seen: *CaseInsensitiveStringHashMap(void),
) anyerror!void {
    switch (decl_node) {
        .derived_type_def => |derived| {
            if (derived.parent_name) |parent_name| {
                try appendPreludeDerivedTypeDependency(arena, prelude, parent_name, only_items, out_decls, out_sources, seen);
            }
            for (derived.components) |component| {
                if (component.derived_type_name) |type_name| {
                    try appendPreludeDerivedTypeDependency(arena, prelude, type_name, only_items, out_decls, out_sources, seen);
                }
            }
            for (derived.procedure_components) |procedure_decl| {
                try appendPreludeProcedureDeclDependencies(arena, prelude, procedure_decl, only_items, out_decls, out_sources, seen);
            }
        },
        .type_decl => |type_decl| {
            if (type_decl.derived_type_name) |type_name| {
                try appendPreludeDerivedTypeDependency(arena, prelude, type_name, only_items, out_decls, out_sources, seen);
            }
        },
        .procedure => |procedure_decl| {
            try appendPreludeProcedureDeclDependencies(arena, prelude, procedure_decl, only_items, out_decls, out_sources, seen);
        },
        .interface_block => |interface_block| {
            for (interface_block.procedure_headers) |proc_header| {
                if (proc_header.type_spec) |type_spec| {
                    try appendPreludeProcedureTypeSpecDependencies(arena, prelude, type_spec, only_items, out_decls, out_sources, seen);
                }
                for (proc_header.decls) |proc_decl_node| {
                    try appendPreludeDeclDependencies(arena, prelude, proc_decl_node, only_items, out_decls, out_sources, seen);
                }
            }
        },
        else => {},
    }
}

fn appendPreludeProcedureDeclDependencies(
    arena: std.mem.Allocator,
    prelude: ModulePrelude,
    procedure_decl: ast.ProcedureDecl,
    only_items: []const ast.UseOnlyItem,
    out_decls: *std.array_list.Managed(Decl),
    out_sources: *std.array_list.Managed(DeclSource),
    seen: *CaseInsensitiveStringHashMap(void),
) anyerror!void {
    switch (procedure_decl.interface) {
        .type_spec => |type_spec| {
            try appendPreludeProcedureTypeSpecDependencies(arena, prelude, type_spec, only_items, out_decls, out_sources, seen);
        },
        else => {},
    }
}

fn appendPreludeProcedureTypeSpecDependencies(
    arena: std.mem.Allocator,
    prelude: ModulePrelude,
    type_spec: ast.ProcedureTypeSpec,
    only_items: []const ast.UseOnlyItem,
    out_decls: *std.array_list.Managed(Decl),
    out_sources: *std.array_list.Managed(DeclSource),
    seen: *CaseInsensitiveStringHashMap(void),
) anyerror!void {
    if (type_spec.derived_type_name) |type_name| {
        try appendPreludeDerivedTypeDependency(arena, prelude, type_name, only_items, out_decls, out_sources, seen);
    }
}

fn appendPreludeDerivedTypeDependency(
    arena: std.mem.Allocator,
    prelude: ModulePrelude,
    type_name: []const u8,
    only_items: []const ast.UseOnlyItem,
    out_decls: *std.array_list.Managed(Decl),
    out_sources: *std.array_list.Managed(DeclSource),
    seen: *CaseInsensitiveStringHashMap(void),
) anyerror!void {
    const renamed_type = renamePreludeTypeName(type_name, only_items);
    try appendPreludeDeclByName(arena, prelude, type_name, renamed_type, only_items, out_decls, out_sources, seen);
}

fn preludeImportSeenKey(
    arena: std.mem.Allocator,
    remote_name: []const u8,
    local_name: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\x1f{s}", .{ remote_name, local_name });
}

fn preludeDeclExportedName(decl_node: Decl) ?[]const u8 {
    return switch (decl_node) {
        .derived_type_def => |derived| derived.name,
        .interface_block => |interface_block| interface_block.name,
        .type_decl => |type_decl| if (type_decl.items.len == 1) type_decl.items[0].name else null,
        .procedure => |procedure_decl| if (procedure_decl.items.len == 1) procedure_decl.items[0].name else null,
        .parameter => |parameter_decl| if (parameter_decl.assigns.len == 1) parameter_decl.assigns[0].name else null,
        else => null,
    };
}

fn renamePreludeDecl(
    arena: std.mem.Allocator,
    decl_node: Decl,
    local_name: ?[]const u8,
    only_items: []const ast.UseOnlyItem,
) !Decl {
    return switch (decl_node) {
        .derived_type_def => |derived| .{ .derived_type_def = try renameDerivedTypeDef(arena, derived, local_name, only_items) },
        .interface_block => |interface_block| .{ .interface_block = try renameInterfaceBlock(arena, interface_block, local_name, only_items) },
        .type_decl => |type_decl| .{ .type_decl = try renameTypeDecl(arena, type_decl, local_name, only_items) },
        .procedure => |procedure_decl| .{ .procedure = try renameProcedureDecl(arena, procedure_decl, local_name, only_items) },
        else => decl_node,
    };
}

fn renameDerivedTypeDef(
    arena: std.mem.Allocator,
    derived: ast.DerivedTypeDef,
    local_name: ?[]const u8,
    only_items: []const ast.UseOnlyItem,
) !ast.DerivedTypeDef {
    const components = try arena.alloc(ast.TypeDecl, derived.components.len);
    for (derived.components, 0..) |component, idx| {
        components[idx] = try renameTypeDecl(arena, component, null, only_items);
    }
    const procedure_components = try arena.alloc(ast.ProcedureDecl, derived.procedure_components.len);
    for (derived.procedure_components, 0..) |procedure_component, idx| {
        procedure_components[idx] = try renameProcedureDecl(arena, procedure_component, null, only_items);
    }
    const bindings = try arena.dupe(ast.TypeBoundProcedureBinding, derived.bindings);
    return .{
        .name = local_name orelse derived.name,
        .parent_name = if (derived.parent_name) |parent| renamePreludeTypeName(parent, only_items) else null,
        .abstract = derived.abstract,
        .sequence = derived.sequence,
        .bind_c = derived.bind_c,
        .components = components,
        .component_sources = derived.component_sources,
        .procedure_components = procedure_components,
        .procedure_component_sources = derived.procedure_component_sources,
        .bindings = bindings,
    };
}

fn renameInterfaceBlock(
    arena: std.mem.Allocator,
    interface_block: ast.InterfaceBlock,
    local_name: ?[]const u8,
    only_items: []const ast.UseOnlyItem,
) !ast.InterfaceBlock {
    const module_procedures = try renameNameList(arena, interface_block.module_procedures, only_items);
    const specific_procedures = try renameNameList(arena, interface_block.specific_procedures, only_items);
    const procedures = try renameNameList(arena, interface_block.procedures, only_items);
    const procedure_headers = try arena.alloc(ast.InterfaceProcedure, interface_block.procedure_headers.len);
    for (interface_block.procedure_headers, 0..) |proc_header, idx| {
        procedure_headers[idx] = renameInterfaceProcedure(proc_header, only_items);
    }
    var renamed = interface_block;
    renamed.name = local_name orelse interface_block.name;
    renamed.module_procedures = module_procedures;
    renamed.specific_procedures = specific_procedures;
    renamed.procedures = procedures;
    renamed.procedure_headers = procedure_headers;
    return renamed;
}

fn renameInterfaceProcedure(
    proc_header: ast.InterfaceProcedure,
    only_items: []const ast.UseOnlyItem,
) ast.InterfaceProcedure {
    var renamed = proc_header;
    renamed.name = renamePreludeTypeName(proc_header.name, only_items);
    if (proc_header.type_spec) |type_spec| {
        renamed.type_spec = renameProcedureTypeSpec(type_spec, only_items);
    }
    if (proc_header.decls.len == 0) return renamed;
    return renamed;
}

fn renameNameList(
    arena: std.mem.Allocator,
    names: []const []const u8,
    only_items: []const ast.UseOnlyItem,
) ![]const []const u8 {
    const renamed = try arena.alloc([]const u8, names.len);
    for (names, 0..) |name, idx| {
        renamed[idx] = renamePreludeTypeName(name, only_items);
    }
    return renamed;
}

fn renameTypeDecl(
    arena: std.mem.Allocator,
    type_decl: ast.TypeDecl,
    local_name: ?[]const u8,
    only_items: []const ast.UseOnlyItem,
) !ast.TypeDecl {
    var renamed = type_decl;
    if (type_decl.derived_type_name) |type_name| {
        renamed.derived_type_name = renamePreludeTypeName(type_name, only_items);
    }
    if (type_decl.items.len == 0) return renamed;
    const items = try arena.alloc(ast.Declarator, type_decl.items.len);
    for (type_decl.items, 0..) |item, idx| {
        items[idx] = item;
        items[idx].name = if (idx == 0 and local_name != null and type_decl.items.len == 1)
            local_name.?
        else
            renamePreludeTypeName(item.name, only_items);
    }
    renamed.items = items;
    return renamed;
}

fn renameProcedureDecl(
    arena: std.mem.Allocator,
    procedure_decl: ast.ProcedureDecl,
    local_name: ?[]const u8,
    only_items: []const ast.UseOnlyItem,
) !ast.ProcedureDecl {
    var renamed = procedure_decl;
    renamed.interface = switch (procedure_decl.interface) {
        .type_spec => |type_spec| .{ .type_spec = renameProcedureTypeSpec(type_spec, only_items) },
        else => procedure_decl.interface,
    };
    if (procedure_decl.items.len == 0) return renamed;
    const items = try arena.alloc(ast.Declarator, procedure_decl.items.len);
    for (procedure_decl.items, 0..) |item, idx| {
        items[idx] = item;
        items[idx].name = if (idx == 0 and local_name != null and procedure_decl.items.len == 1)
            local_name.?
        else
            renamePreludeTypeName(item.name, only_items);
    }
    renamed.items = items;
    return renamed;
}

fn renameProcedureTypeSpec(type_spec: ast.ProcedureTypeSpec, only_items: []const ast.UseOnlyItem) ast.ProcedureTypeSpec {
    var renamed = type_spec;
    if (type_spec.derived_type_name) |type_name| {
        renamed.derived_type_name = renamePreludeTypeName(type_name, only_items);
    }
    return renamed;
}

fn renamePreludeTypeName(name: []const u8, only_items: []const ast.UseOnlyItem) []const u8 {
    for (only_items) |item| {
        if (std.ascii.eqlIgnoreCase(item.remote_name, name)) return item.local_name;
    }
    return name;
}

pub fn prependDecls(
    allocator: std.mem.Allocator,
    unit: ProgramUnit,
    prelude_decls: []const Decl,
    prelude_sources: []const DeclSource,
) !ProgramUnit {
    if (prelude_decls.len == 0) return unit;

    var filtered_decls = std.array_list.Managed(Decl).init(allocator);
    defer filtered_decls.deinit();
    var filtered_sources = std.array_list.Managed(DeclSource).init(allocator);
    defer filtered_sources.deinit();

    for (prelude_decls, 0..) |prelude_decl, idx| {
        const prelude_source = if (idx < prelude_sources.len) prelude_sources[idx] else DeclSource{};
        if (hasEquivalentImportedDecl(unit, prelude_decl, prelude_source)) continue;
        try filtered_decls.append(prelude_decl);
        try filtered_sources.append(prelude_source);
    }
    if (filtered_decls.items.len == 0) return unit;

    const total_decls = filtered_decls.items.len + unit.decls.len;
    const decls = try allocator.alloc(Decl, total_decls);
    std.mem.copyForwards(Decl, decls[0..filtered_decls.items.len], filtered_decls.items);
    std.mem.copyForwards(Decl, decls[filtered_decls.items.len..], unit.decls);

    const total_sources = filtered_sources.items.len + unit.decl_sources.len;
    const decl_sources = try allocator.alloc(DeclSource, total_sources);
    std.mem.copyForwards(DeclSource, decl_sources[0..filtered_sources.items.len], filtered_sources.items);
    std.mem.copyForwards(DeclSource, decl_sources[filtered_sources.items.len..], unit.decl_sources);

    return .{
        .kind = unit.kind,
        .name = unit.name,
        .is_module_procedure = unit.is_module_procedure,
        .pure = unit.pure,
        .elemental = unit.elemental,
        .recursive = unit.recursive,
        .prelude_decl_count = unit.prelude_decl_count + filtered_decls.items.len,
        .owner_name = unit.owner_name,
        .owner_kind = unit.owner_kind,
        .bind_c = unit.bind_c,
        .bind_name = unit.bind_name,
        .result_name = unit.result_name,
        .alt_return_dummy_count = unit.alt_return_dummy_count,
        .args = unit.args,
        .decls = decls,
        .decl_sources = decl_sources,
        .stmts = unit.stmts,
        .expr_sources = unit.expr_sources,
    };
}

fn hasEquivalentImportedDecl(unit: ProgramUnit, candidate: Decl, candidate_source: DeclSource) bool {
    return declSliceHasEquivalentImportedDecl(unit.decls, unit.decl_sources, candidate, candidate_source);
}

fn declSliceHasEquivalentImportedDecl(
    decls: []const Decl,
    decl_sources: []const DeclSource,
    candidate: Decl,
    candidate_source: DeclSource,
) bool {
    const owner_name = candidate_source.owner_name orelse return false;
    for (decls, 0..) |existing_decl, idx| {
        const existing_source = if (idx < decl_sources.len) decl_sources[idx] else DeclSource{};
        const existing_owner = existing_source.owner_name orelse continue;
        if (!std.ascii.eqlIgnoreCase(owner_name, existing_owner)) continue;
        if (declsEquivalentForImport(candidate, existing_decl)) return true;
    }
    return false;
}

fn declsEquivalentForImport(a: Decl, b: Decl) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .type_decl => |type_decl| namesEqualDeclarators(type_decl.items, b.type_decl.items),
        .bind_entity => |bind_entity_decl| namesEqualStrings(bind_entity_decl.names, b.bind_entity.names) and
            namesEqualStrings(bind_entity_decl.common_blocks, b.bind_entity.common_blocks),
        .procedure => |procedure| namesEqualDeclarators(procedure.items, b.procedure.items),
        .derived_type_def => |derived| std.ascii.eqlIgnoreCase(derived.name, b.derived_type_def.name),
        .interface_block => |interface_block| blk: {
            if (interface_block.name == null or b.interface_block.name == null) break :blk false;
            break :blk std.ascii.eqlIgnoreCase(interface_block.name.?, b.interface_block.name.?);
        },
        .parameter => |parameter| namesEqualParamAssigns(parameter.assigns, b.parameter.assigns),
        .import, .external, .intrinsic, .optional => |list| namesEqualStrings(list.names, switch (b) {
            .import => |other| other.names,
            .external => |other| other.names,
            .intrinsic => |other| other.names,
            .optional => |other| other.names,
            else => unreachable,
        }),
        .intent => |intent_decl| namesEqualStrings(intent_decl.names, b.intent.names),
        .dimension => |dimension_decl| namesEqualDeclarators(dimension_decl.items, b.dimension.items),
        .save => |save_decl| saveItemsEqual(save_decl.items, b.save.items) and save_decl.save_all == b.save.save_all,
        .implicit, .common, .equivalence => false,
    };
}

fn namesEqualDeclarators(a: []const ast.Declarator, b: []const ast.Declarator) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |item, idx| {
        if (!std.ascii.eqlIgnoreCase(item.name, b[idx].name)) return false;
    }
    return true;
}

fn namesEqualParamAssigns(a: []const ast.ParamAssign, b: []const ast.ParamAssign) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |item, idx| {
        if (!std.ascii.eqlIgnoreCase(item.name, b[idx].name)) return false;
    }
    return true;
}

fn namesEqualStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |name, idx| {
        if (!std.ascii.eqlIgnoreCase(name, b[idx])) return false;
    }
    return true;
}

fn saveItemsEqual(a: []const ast.SaveItem, b: []const ast.SaveItem) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |item, idx| {
        switch (item) {
            .name => |name| switch (b[idx]) {
                .name => |other| if (!std.ascii.eqlIgnoreCase(name, other)) return false,
                else => return false,
            },
            .common => |name| switch (b[idx]) {
                .common => |other| {
                    if (name == null or other == null) {
                        if ((name == null) != (other == null)) return false;
                    } else if (!std.ascii.eqlIgnoreCase(name.?, other.?)) return false;
                },
                else => return false,
            },
        }
    }
    return true;
}

pub fn annotateDeclSourcesOwner(
    allocator: std.mem.Allocator,
    decl_sources: []const DeclSource,
    owner_name: []const u8,
) ![]const DeclSource {
    if (decl_sources.len == 0) return decl_sources;

    var needs_copy = false;
    for (decl_sources) |source| {
        if (source.owner_name == null) {
            needs_copy = true;
            break;
        }
    }
    if (!needs_copy) return decl_sources;

    const annotated = try allocator.alloc(DeclSource, decl_sources.len);
    for (decl_sources, 0..) |source, idx| {
        annotated[idx] = source;
        if (annotated[idx].owner_name == null) annotated[idx].owner_name = owner_name;
    }
    return annotated;
}
