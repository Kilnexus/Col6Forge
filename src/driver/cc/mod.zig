const std = @import("std");
const Col6Forge = @import("Col6Forge");

const types = @import("types.zig");
const args_mod = @import("args.zig");
const paths = @import("paths.zig");
const pipeline = @import("pipeline.zig");
const process = @import("process.zig");
const runtime_cache = @import("runtime_cache.zig");
const zig_api = Col6Forge.zig_api;

pub fn runOrExit(allocator: std.mem.Allocator, args: []const []const u8) noreturn {
    run(allocator, args) catch |err| {
        switch (err) {
            error.InvalidArguments => std.process.exit(2),
            else => {
                std.debug.print("internal error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            },
        }
    };
    std.process.exit(0);
}

fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var parsed = switch (args_mod.parseArgs(allocator, args)) {
        .success => |value| value,
        .failure => |parse_err| {
            try printUsage(zig_api.File.stderr());
            try printParseArgError(zig_api.File.stderr(), parse_err);
            return error.InvalidArguments;
        },
    };
    defer parsed.deinit(allocator);

    if (parsed.show_help) {
        try printUsage(zig_api.File.stdout());
        return;
    }

    if (parsed.fortran_inputs.len == 0 and parsed.other_inputs.len == 0 and parsed.forward_args.len != 0) {
        var passthrough_argv: std.ArrayList([]const u8) = .empty;
        defer passthrough_argv.deinit(allocator);
        try passthrough_argv.appendSlice(allocator, &.{ "zig", "cc" });
        try passthrough_argv.appendSlice(allocator, parsed.forward_args);
        try process.runPassthroughCommand(allocator, passthrough_argv.items);
        return;
    }

    const runtime_cfg = args_mod.extractRuntimeBuildConfig(parsed.forward_args);

    var known_symbols = try pipeline.collectFortranKnownSymbols(allocator, parsed.fortran_inputs);
    defer known_symbols.deinit(allocator);

    const work_rel = try paths.makeWorkDir(allocator);
    defer allocator.free(work_rel);

    var translated = try pipeline.translateFortranInputs(
        allocator,
        work_rel,
        parsed.fortran_inputs,
        parsed.bounds_check,
        parsed.dialect,
        parsed.pause_mode,
        runtime_cfg.target,
        parsed.time_report,
        known_symbols.function_types,
        known_symbols.procedure_sigs,
    );
    defer translated.deinit(allocator);

    if (parsed.compile_only) {
        var compile_units: std.ArrayList([]const u8) = .empty;
        defer compile_units.deinit(allocator);
        try compile_units.appendSlice(allocator, translated.ll_paths);

        var has_link_only_inputs = false;
        for (parsed.other_inputs) |input| {
            if (paths.isCcCompilableSource(input)) {
                try compile_units.append(allocator, input);
            } else {
                has_link_only_inputs = true;
            }
        }

        if (compile_units.items.len == 0) {
            try writeLine(zig_api.File.stderr(), "error: no compile inputs provided\n");
            return error.InvalidArguments;
        }
        if (has_link_only_inputs) {
            try writeLine(
                zig_api.File.stderr(),
                "error: -c mode does not accept link-only inputs (.o/.obj/.a/.lib/.so/.dll)\n",
            );
            return error.InvalidArguments;
        }
        if (parsed.output_path != null and compile_units.items.len != 1) {
            try writeLine(
                zig_api.File.stderr(),
                "error: -o is only valid with exactly one compile input in -c mode\n",
            );
            return error.InvalidArguments;
        }

        if (compile_units.items.len == 1) {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(allocator);
            try argv.appendSlice(allocator, &.{ "zig", "cc", "-c" });
            if (parsed.output_path) |path| {
                try paths.ensureParentDir(path);
                try argv.appendSlice(allocator, &.{ "-o", path });
            }
            try argv.append(allocator, compile_units.items[0]);
            try argv.appendSlice(allocator, parsed.forward_args);
            try process.runCheckedCommand(allocator, argv.items, "zig cc compile");
            return;
        }

        for (compile_units.items) |unit| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(allocator);
            try argv.appendSlice(allocator, &.{ "zig", "cc", "-c", unit });
            try argv.appendSlice(allocator, parsed.forward_args);
            try process.runCheckedCommand(allocator, argv.items, "zig cc compile");
        }
        return;
    }

    const output_path = if (parsed.output_path) |path|
        path
    else if (parsed.fortran_inputs.len != 0)
        try paths.defaultExeOutputPath(allocator, parsed.fortran_inputs[0])
    else if (parsed.other_inputs.len != 0)
        try paths.defaultExeOutputPath(allocator, parsed.other_inputs[0])
    else {
        try writeLine(zig_api.File.stderr(), "error: missing input files\n");
        return error.InvalidArguments;
    };
    defer if (parsed.output_path == null) allocator.free(output_path);
    try paths.ensureParentDir(output_path);

    var link_argv: std.ArrayList([]const u8) = .empty;
    defer link_argv.deinit(allocator);
    try link_argv.appendSlice(allocator, &.{ "zig", "cc", "-o", output_path });
    try link_argv.appendSlice(allocator, translated.ll_paths);
    try link_argv.appendSlice(allocator, parsed.other_inputs);

    var runtime_obj_path: ?[]const u8 = null;
    defer if (runtime_obj_path) |path| allocator.free(path);
    if (parsed.fortran_inputs.len != 0) {
        runtime_obj_path = try runtime_cache.prepareRuntimeObjectCached(allocator, runtime_cfg);
        try link_argv.append(allocator, runtime_obj_path.?);
    }

    try link_argv.appendSlice(allocator, parsed.forward_args);
    try process.runCheckedCommand(allocator, link_argv.items, "zig cc link");
}

fn printParseArgError(file: zig_api.File, parse_err: types.ParseArgError) !void {
    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    switch (parse_err) {
        .missing_input_file => try writer.interface.writeAll("error: missing input files\n"),
        .missing_output_path => try writer.interface.writeAll("error: missing output path after -o\n"),
        .missing_std => try writer.interface.writeAll("error: missing standard after -std\n"),
        .missing_pause_mode => try writer.interface.writeAll("error: missing pause mode after -fpause-mode\n"),
        .invalid_std => |value| try writer.interface.print("error: invalid Fortran standard: {s}\n", .{value}),
        .invalid_pause_mode => |value| try writer.interface.print("error: invalid pause mode: {s}\n", .{value}),
    }
    try writer.interface.flush();
}

fn printUsage(file: zig_api.File) !void {
    try file.writeAll(
        \\Usage:
        \\  col6forge cc <inputs...> [options] [-- <zig-cc-flags...>]
        \\  col6forge-cc <inputs...> [options] [-- <zig-cc-flags...>]
        \\Inputs:
        \\  - One or more Fortran sources (.f/.for/.f77/.f90/.f95/.f03/.f08)
        \\  - Additional non-Fortran inputs are forwarded to `zig cc`
        \\Options:
        \\  -c                          Compile only (emit object files)
        \\  -o <path>                   Output object/executable path
        \\  -emit-llvm                  Emit LLVM IR internally (default)
        \\  -fbounds-check              Enable runtime array bounds checks in pipeline
        \\  -std <default|f77>          Fortran dialect gate for Col6Forge lowering (default: default)
        \\  -fpause-mode <auto|continue|stop>  PAUSE runtime policy (default: auto)
        \\  -ftime-report, --time-report  Print parse/sema/codegen timing report to stderr
        \\  -h, --help                  Show this help
        \\
        \\Notes:
        \\  - Unrecognized flags are forwarded to `zig cc`.
        \\  - Non-`-c` mode links Col6Forge runtime automatically when Fortran inputs exist.
        \\  - In `-c` mode, `-o` requires exactly one compile input.
        \\
    );
}

fn writeLine(file: zig_api.File, text: []const u8) !void {
    try file.writeAll(text);
}
