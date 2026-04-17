const std = @import("std");
const diag = @import("../../common/diagnostic.zig");
const logical_line = @import("../../frontend/logical_line.zig");
const parser = @import("../../frontend/parser/mod.zig");
const semantic = @import("../../semantic/mod.zig");
const codegen = @import("../../codegen/mod.zig");
const profile_mod = @import("profile.zig");
const diagnostics = @import("diagnostics.zig");
const omp_declare_variant = @import("omp_declare_variant.zig");
const omp_minimal_directives = @import("omp_minimal_directives.zig");
const types = @import("types.zig");

pub fn emitLlvmModule(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    contents: []const u8,
    logical_lines: []logical_line.LogicalLine,
    options: types.PipelineOptions,
    diag_bag: *diag.Bag,
    profile: ?*profile_mod.PipelineProfile,
) ![]const u8 {
    if (logical_lines.len == 0) {
        const codegen_start = profile_mod.nowNs();
        var codegen_diag_bag = codegen.diagnostic.Bag.init(allocator);
        defer codegen_diag_bag.deinit();
        const output = codegen.emitModuleWithOptionsAndDiagnostics(
            allocator,
            .{ .units = &.{} },
            .{ .units = &.{} },
            input_path,
            .{
                .bounds_check = options.bounds_check,
                .pause_mode = options.pause_mode,
                .target = options.target,
                .target_layout = options.semantic_target_layout,
                .known_procedure_sigs = options.known_procedure_sigs,
            },
            &codegen_diag_bag,
        ) catch |err| {
            if (profile) |p| {
                p.codegen_ns = profile_mod.elapsedNs(codegen_start);
                profile_mod.applyCodegenBreakdown(p);
                p.markFailure(.codegen);
            }
            diagnostics.setCodegenDiagnostic(diag_bag, &codegen_diag_bag, input_path, contents, err);
            return err;
        };
        if (profile) |p| {
            p.codegen_ns = profile_mod.elapsedNs(codegen_start);
            profile_mod.applyCodegenBreakdown(p);
        }
        return output;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parse_diag_bag = parser.diagnostic.Bag.init(arena.allocator());
    defer parse_diag_bag.deinit();
    const parse_start = profile_mod.nowNs();
    const program = parser.parseProgramWithDiagnostics(arena.allocator(), logical_lines, &parse_diag_bag) catch |err| {
        if (profile) |p| {
            p.parse_ns = profile_mod.elapsedNs(parse_start);
            p.markFailure(.parse);
        }
        diagnostics.setParseDiagnostic(diag_bag, &parse_diag_bag, input_path, contents, logical_lines, err);
        return err;
    };
    if (profile) |p| p.parse_ns = profile_mod.elapsedNs(parse_start);
    const parse_had_diagnostics = diagnostics.appendParserDiagnostics(diag_bag, &parse_diag_bag, input_path, contents, logical_lines, error.UnexpectedToken);
    if (parse_had_diagnostics) {
        if (profile) |p| p.markFailure(.parse);
    }

    const declare_variant_adjust_args = try omp_declare_variant.collectDeclareVariantAdjustArgs(
        arena.allocator(),
        program,
        contents,
    );

    var semantic_diag_bag = semantic.diagnostic.Bag.init(arena.allocator());
    defer semantic_diag_bag.deinit();
    const semantic_start = profile_mod.nowNs();
    const sem = semantic.analyzeProgramWithKnownAndOptionsAndDiagnostics(
        arena.allocator(),
        program,
        options.known_function_types,
        options.known_procedure_sigs,
        .{
            .target_layout = options.semantic_target_layout,
            .range_check = options.range_check,
            .fbackslash = options.fbackslash,
            .allow_argument_mismatch = options.allow_argument_mismatch,
            .dialect = options.dialect,
            .declare_variant_adjust_args = declare_variant_adjust_args,
        },
        &semantic_diag_bag,
    ) catch |err| {
        if (profile) |p| {
            p.semantic_ns = profile_mod.elapsedNs(semantic_start);
            p.markFailure(.semantic);
        }
        diagnostics.setSemanticDiagnostic(diag_bag, &semantic_diag_bag, input_path, contents, err);
        return err;
    };
    if (profile) |p| p.semantic_ns = profile_mod.elapsedNs(semantic_start);
    _ = diagnostics.appendSemanticDiagnostics(diag_bag, &semantic_diag_bag, input_path, contents);
    omp_declare_variant.validateDeclareVariantCompatibility(arena.allocator(), program, input_path, contents, diag_bag) catch |err| {
        if (profile) |p| p.markFailure(.semantic);
        return err;
    };
    omp_minimal_directives.validateMinimalDirectiveCompatibility(arena.allocator(), program, sem, input_path, contents, diag_bag) catch |err| {
        if (profile) |p| p.markFailure(.semantic);
        return err;
    };
    if (parse_had_diagnostics) {
        return error.UnexpectedToken;
    }

    var codegen_diag_bag = codegen.diagnostic.Bag.init(allocator);
    defer codegen_diag_bag.deinit();
    const codegen_start = profile_mod.nowNs();
    const output = codegen.emitModuleWithOptionsAndDiagnostics(
        allocator,
        program,
        sem,
        input_path,
        .{
            .bounds_check = options.bounds_check,
            .pause_mode = options.pause_mode,
            .target = options.target,
            .target_layout = options.semantic_target_layout,
            .known_procedure_sigs = options.known_procedure_sigs,
        },
        &codegen_diag_bag,
    ) catch |err| {
        if (profile) |p| {
            p.codegen_ns = profile_mod.elapsedNs(codegen_start);
            profile_mod.applyCodegenBreakdown(p);
            p.markFailure(.codegen);
        }
        diagnostics.setCodegenDiagnostic(diag_bag, &codegen_diag_bag, input_path, contents, err);
        return err;
    };
    if (profile) |p| {
        p.codegen_ns = profile_mod.elapsedNs(codegen_start);
        profile_mod.applyCodegenBreakdown(p);
    }
    return output;
}

pub fn emitLlvmModuleToWriter(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    contents: []const u8,
    logical_lines: []logical_line.LogicalLine,
    writer: anytype,
    options: types.PipelineOptions,
    diag_bag: *diag.Bag,
    profile: ?*profile_mod.PipelineProfile,
) !void {
    if (logical_lines.len == 0) {
        const codegen_start = profile_mod.nowNs();
        var codegen_diag_bag = codegen.diagnostic.Bag.init(allocator);
        defer codegen_diag_bag.deinit();
        codegen.emitModuleToWriterWithOptionsAndDiagnostics(
            writer,
            allocator,
            .{ .units = &.{} },
            .{ .units = &.{} },
            input_path,
            .{
                .bounds_check = options.bounds_check,
                .pause_mode = options.pause_mode,
                .target = options.target,
                .target_layout = options.semantic_target_layout,
                .known_procedure_sigs = options.known_procedure_sigs,
            },
            &codegen_diag_bag,
        ) catch |err| {
            if (profile) |p| {
                p.codegen_ns = profile_mod.elapsedNs(codegen_start);
                profile_mod.applyCodegenBreakdown(p);
                p.markFailure(.codegen);
            }
            diagnostics.setCodegenDiagnostic(diag_bag, &codegen_diag_bag, input_path, contents, err);
            return err;
        };
        if (profile) |p| {
            p.codegen_ns = profile_mod.elapsedNs(codegen_start);
            profile_mod.applyCodegenBreakdown(p);
        }
        return;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parse_diag_bag = parser.diagnostic.Bag.init(arena.allocator());
    defer parse_diag_bag.deinit();
    const parse_start = profile_mod.nowNs();
    const program = parser.parseProgramWithDiagnostics(arena.allocator(), logical_lines, &parse_diag_bag) catch |err| {
        if (profile) |p| {
            p.parse_ns = profile_mod.elapsedNs(parse_start);
            p.markFailure(.parse);
        }
        diagnostics.setParseDiagnostic(diag_bag, &parse_diag_bag, input_path, contents, logical_lines, err);
        return err;
    };
    if (profile) |p| p.parse_ns = profile_mod.elapsedNs(parse_start);
    const parse_had_diagnostics = diagnostics.appendParserDiagnostics(diag_bag, &parse_diag_bag, input_path, contents, logical_lines, error.UnexpectedToken);
    if (parse_had_diagnostics) {
        if (profile) |p| p.markFailure(.parse);
    }

    var semantic_diag_bag = semantic.diagnostic.Bag.init(arena.allocator());
    defer semantic_diag_bag.deinit();
    const semantic_start = profile_mod.nowNs();
    const declare_variant_adjust_args = try omp_declare_variant.collectDeclareVariantAdjustArgs(
        arena.allocator(),
        program,
        contents,
    );

    const sem = semantic.analyzeProgramWithKnownAndOptionsAndDiagnostics(
        arena.allocator(),
        program,
        options.known_function_types,
        options.known_procedure_sigs,
        .{
            .target_layout = options.semantic_target_layout,
            .range_check = options.range_check,
            .fbackslash = options.fbackslash,
            .allow_argument_mismatch = options.allow_argument_mismatch,
            .dialect = options.dialect,
            .declare_variant_adjust_args = declare_variant_adjust_args,
        },
        &semantic_diag_bag,
    ) catch |err| {
        if (profile) |p| {
            p.semantic_ns = profile_mod.elapsedNs(semantic_start);
            p.markFailure(.semantic);
        }
        diagnostics.setSemanticDiagnostic(diag_bag, &semantic_diag_bag, input_path, contents, err);
        return err;
    };
    if (profile) |p| p.semantic_ns = profile_mod.elapsedNs(semantic_start);
    _ = diagnostics.appendSemanticDiagnostics(diag_bag, &semantic_diag_bag, input_path, contents);
    omp_declare_variant.validateDeclareVariantCompatibility(arena.allocator(), program, input_path, contents, diag_bag) catch |err| {
        if (profile) |p| p.markFailure(.semantic);
        return err;
    };
    omp_minimal_directives.validateMinimalDirectiveCompatibility(arena.allocator(), program, sem, input_path, contents, diag_bag) catch |err| {
        if (profile) |p| p.markFailure(.semantic);
        return err;
    };
    if (parse_had_diagnostics) {
        return error.UnexpectedToken;
    }

    var codegen_diag_bag = codegen.diagnostic.Bag.init(allocator);
    defer codegen_diag_bag.deinit();
    const codegen_start = profile_mod.nowNs();
    codegen.emitModuleToWriterWithOptionsAndDiagnostics(
        writer,
        allocator,
        program,
        sem,
        input_path,
        .{
            .bounds_check = options.bounds_check,
            .pause_mode = options.pause_mode,
            .target = options.target,
            .target_layout = options.semantic_target_layout,
            .known_procedure_sigs = options.known_procedure_sigs,
        },
        &codegen_diag_bag,
    ) catch |err| {
        if (profile) |p| {
            p.codegen_ns = profile_mod.elapsedNs(codegen_start);
            profile_mod.applyCodegenBreakdown(p);
            p.markFailure(.codegen);
        }
        diagnostics.setCodegenDiagnostic(diag_bag, &codegen_diag_bag, input_path, contents, err);
        return err;
    };
    if (profile) |p| {
        p.codegen_ns = profile_mod.elapsedNs(codegen_start);
        profile_mod.applyCodegenBreakdown(p);
    }
    return;
}
