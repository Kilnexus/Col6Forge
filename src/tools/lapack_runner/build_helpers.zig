const common = @import("common.zig");
const std = common.std;
const builtin = common.builtin;
const Col6Forge = common.Col6Forge;
const zig_api = Col6Forge.zig_api;
const fallback_policy = common.fallback_policy;
const RuntimeBackend = common.RuntimeBackend;
const CACHE_SCHEMA_VERSION = common.CACHE_SCHEMA_VERSION;
const HOST_CACHE_TAG = common.HOST_CACHE_TAG;
const MAX_RUN_INPUT_BYTES = common.MAX_RUN_INPUT_BYTES;
const MAX_RUN_OUTPUT_BYTES = common.MAX_RUN_OUTPUT_BYTES;
const INSTALL_EXTRAS = common.INSTALL_EXTRAS;
const LapackCase = common.LapackCase;
const SupportLibs = common.SupportLibs;
const io_compare = @import("io_compare.zig");
const file_ops = Col6Forge.file_ops;
const cache_keys = @import("../cache_keys.zig");
const pipeline_output = @import("../pipeline_output.zig");
const FORTRAN_FALLBACK = common.FORTRAN_FALLBACK;
const runProcessCaptureWithInput = io_compare.runProcessCaptureWithInput;
const fileExists = io_compare.fileExists;
const trimCr = io_compare.trimCr;
const ProcessResult = io_compare.ProcessResult;
const ProcessRedirectResult = io_compare.ProcessRedirectResult;
const runProcessCaptureWithInputPath = io_compare.runProcessCaptureWithInputPath;
const runProcessStreamToFilesWithInputPath = io_compare.runProcessStreamToFilesWithInputPath;
const isZeroExit = io_compare.isZeroExit;
const exitCode = io_compare.exitCode;
const buildRunArtifactPath = io_compare.buildRunArtifactPath;
const retryStdoutComparisonWithCapturedRuns = io_compare.retryStdoutComparisonWithCapturedRuns;
const readFileLimitedAbsolute = io_compare.readFileLimitedAbsolute;

pub const RuntimeArtifacts = struct {
    zig_object: ?[]const u8 = null,

    pub fn deinit(self: *RuntimeArtifacts, allocator: std.mem.Allocator) void {
        if (self.zig_object) |obj| {
            allocator.free(obj);
            self.zig_object = null;
        }
    }

    pub fn appendToArgs(self: *const RuntimeArtifacts, allocator: std.mem.Allocator, args: *std.ArrayList([]const u8)) !void {
        if (self.zig_object) |obj| {
            try args.append(allocator, obj);
        }
    }
};

pub fn prepareRuntimeArtifacts(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    output_dir: []const u8,
    backend: RuntimeBackend,
    timeout_ms: u64,
    runtime_cache_key: []const u8,
    incremental: bool,
) !RuntimeArtifacts {
    return switch (backend) {
        .c, .zig => blk: {
            const runtime_src = try std.fs.path.join(allocator, &.{ root_path, "src", "runtime", "col6forge_rt.zig" });
            defer allocator.free(runtime_src);
            const runtime_obj_name = if (incremental)
                try std.fmt.allocPrint(
                    allocator,
                    "col6forge_rt_v{d}_{s}_{s}.o",
                    .{ CACHE_SCHEMA_VERSION, runtimeBackendTag(backend), runtime_cache_key },
                )
            else
                try allocator.dupe(u8, "col6forge_rt.o");
            defer allocator.free(runtime_obj_name);
            const runtime_obj = try std.fs.path.join(allocator, &.{ output_dir, runtime_obj_name });
            errdefer allocator.free(runtime_obj);
            if (incremental and fileExistsAbsolute(runtime_obj)) {
                break :blk .{ .zig_object = runtime_obj };
            }
            const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{runtime_obj});
            defer allocator.free(emit_arg);
            const cmd = [_][]const u8{ "zig", "build-obj", "-ODebug", "-fPIC", emit_arg, runtime_src };
            const build = try runProcessCaptureWithInput(allocator, &cmd, null, null, timeout_ms);
            defer build.deinit(allocator);
            if (build.timed_out) return error.RuntimeBackendBuildTimeout;
            if (!isZeroExit(build.term)) {
                std.log.err("zig runtime backend build failed\n{s}\n", .{build.stderr});
                return error.RuntimeBackendBuildFailed;
            }
            break :blk .{
                .zig_object = runtime_obj,
            };
        },
    };
}
pub fn buildSupportLibs(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    work_dir: []const u8,
    gfortran_cmd: []const u8,
    timeout_ms: u64,
    lapack_src_dir: []const u8,
    blas_src_dir: []const u8,
    matgen_dir: []const u8,
    install_dir: []const u8,
) !SupportLibs {
    const lib_dir = try std.fs.path.join(allocator, &.{ work_dir, "libs" });
    defer allocator.free(lib_dir);
    try zig_api.cwd().makePath(lib_dir);

    const blas_lib = try std.fs.path.join(allocator, &.{ lib_dir, "blas_ref.a" });
    const lapack_lib = try std.fs.path.join(allocator, &.{ lib_dir, "lapack_ref.a" });
    const tmg_lib = try std.fs.path.join(allocator, &.{ lib_dir, "tmg_ref.a" });
    errdefer allocator.free(blas_lib);
    errdefer allocator.free(lapack_lib);
    errdefer allocator.free(tmg_lib);

    const have_blas = fileExists(blas_lib);
    const have_lapack = fileExists(lapack_lib);
    const have_tmg = fileExists(tmg_lib);
    if (have_blas and have_lapack and have_tmg) {
        return .{ .blas_lib = blas_lib, .lapack_lib = lapack_lib, .tmg_lib = tmg_lib };
    }

    const obj_root = try std.fs.path.join(allocator, &.{ work_dir, "obj-libs" });
    defer allocator.free(obj_root);
    try zig_api.cwd().makePath(obj_root);

    const blas_sources = try collectFortranSources(allocator, root_path, blas_src_dir);
    defer {
        for (blas_sources) |p| allocator.free(p);
        allocator.free(blas_sources);
    }
    const lapack_sources = try collectFortranSources(allocator, root_path, lapack_src_dir);
    defer {
        for (lapack_sources) |p| allocator.free(p);
        allocator.free(lapack_sources);
    }
    const tmg_sources = try collectFortranSources(allocator, root_path, matgen_dir);
    defer {
        for (tmg_sources) |p| allocator.free(p);
        allocator.free(tmg_sources);
    }

    var lapack_all: std.ArrayList([]const u8) = .empty;
    defer lapack_all.deinit(allocator);
    try lapack_all.appendSlice(allocator, lapack_sources);
    for (INSTALL_EXTRAS) |name| {
        const rel = try std.fs.path.join(allocator, &.{ install_dir, name });
        defer allocator.free(rel);
        const abs = try absolutizePath(allocator, root_path, rel);
        try lapack_all.append(allocator, abs);
    }
    defer {
        var i: usize = lapack_sources.len;
        while (i < lapack_all.items.len) : (i += 1) allocator.free(lapack_all.items[i]);
    }

    const blas_obj = try std.fs.path.join(allocator, &.{ obj_root, "blas" });
    defer allocator.free(blas_obj);
    try buildStaticLib(allocator, gfortran_cmd, blas_lib, blas_obj, blas_sources, timeout_ms, work_dir, "BLAS");

    const lapack_obj = try std.fs.path.join(allocator, &.{ obj_root, "lapack" });
    defer allocator.free(lapack_obj);
    try buildStaticLib(allocator, gfortran_cmd, lapack_lib, lapack_obj, lapack_all.items, timeout_ms, work_dir, "LAPACK");

    const tmg_obj = try std.fs.path.join(allocator, &.{ obj_root, "tmg" });
    defer allocator.free(tmg_obj);
    try buildStaticLib(allocator, gfortran_cmd, tmg_lib, tmg_obj, tmg_sources, timeout_ms, work_dir, "TMG");

    return .{ .blas_lib = blas_lib, .lapack_lib = lapack_lib, .tmg_lib = tmg_lib };
}

pub fn buildStaticLib(
    allocator: std.mem.Allocator,
    gfortran_cmd: []const u8,
    lib_path: []const u8,
    obj_dir: []const u8,
    sources: []const []const u8,
    timeout_ms: u64,
    cwd: []const u8,
    label: []const u8,
) !void {
    _ = cwd;
    cleanupWorkDir(obj_dir);
    try zig_api.cwd().makePath(obj_dir);
    zig_api.cwd().deleteFile(lib_path) catch {};

    for (sources, 0..) |src, idx| {
        const obj_name = try std.fmt.allocPrint(allocator, "{d}.o", .{idx});
        defer allocator.free(obj_name);
        const obj_path = try std.fs.path.join(allocator, &.{ obj_dir, obj_name });
        defer allocator.free(obj_path);

        const compile_cmd = [_][]const u8{ gfortran_cmd, "-std=legacy", "-O0", "-c", "-o", obj_path, src };
        const c_res = runProcessCaptureWithInput(allocator, &compile_cmd, null, null, timeout_ms) catch |err| {
            std.log.err("gfortran invoke error ({s}): {s}\n", .{ label, @errorName(err) });
            return error.CompileFailed;
        };
        defer c_res.deinit(allocator);
        if (c_res.timed_out) {
            std.log.warn("timeout: compile {s} object {d}\n", .{ label, idx });
            return error.CompileFailed;
        }
        if (!isZeroExit(c_res.term)) {
            std.log.err("=== GFORTRAN {s} STDERR ({s}) ===\n{s}\n", .{ label, src, c_res.stderr });
            return error.CompileFailed;
        }

        const ar_cmd = if (idx == 0)
            [_][]const u8{ "zig", "ar", "rcs", lib_path, obj_path }
        else
            [_][]const u8{ "zig", "ar", "r", lib_path, obj_path };
        const a_res = runProcessCaptureWithInput(allocator, &ar_cmd, null, null, timeout_ms) catch |err| {
            std.log.err("archive invoke error ({s}): {s}\n", .{ label, @errorName(err) });
            return error.ArchiveFailed;
        };
        defer a_res.deinit(allocator);
        if (a_res.timed_out or !isZeroExit(a_res.term)) {
            std.log.err("archive failed ({s})\n{s}\n", .{ label, a_res.stderr });
            return error.ArchiveFailed;
        }
    }
}

pub fn buildSourcePaths(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    case_dir: []const u8,
    names: []const []const u8,
) ![][]const u8 {
    var out = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |name, i| {
        const rel = try std.fs.path.join(allocator, &.{ case_dir, name });
        defer allocator.free(rel);
        out[i] = try absolutizePath(allocator, root_path, rel);
    }
    return out;
}

pub fn resolveCaseSourcesFromMakefile(
    allocator: std.mem.Allocator,
    suite_dir: []const u8,
    vars: []const []const u8,
) ![]const []const u8 {
    const makefile_path = try std.fs.path.join(allocator, &.{ suite_dir, "Makefile" });
    defer allocator.free(makefile_path);
    const makefile_text = try zig_api.cwd().readFileAlloc(allocator, makefile_path, 8 * 1024 * 1024);
    defer allocator.free(makefile_text);

    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();

    for (vars) |var_name| {
        const var_sources = try extractMakeVarSources(allocator, makefile_text, var_name);
        defer allocator.free(var_sources);

        for (var_sources) |src| {
            if (seen.contains(src)) {
                allocator.free(src);
                continue;
            }
            try seen.put(src, {});
            try out.append(allocator, src);
        }
    }

    if (out.items.len == 0) return error.NoSourcesResolved;
    return out.toOwnedSlice(allocator);
}

pub fn extractMakeVarSources(
    allocator: std.mem.Allocator,
    makefile_text: []const u8,
    var_name: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var found = false;
    var in_var = false;

    var lines = std.mem.splitScalar(u8, makefile_text, '\n');
    while (lines.next()) |line_raw| {
        const line_no_cr = trimCr(line_raw);
        const line = std.mem.trim(u8, line_no_cr, " \t");
        if (line.len == 0) continue;

        if (!in_var) {
            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const lhs = std.mem.trim(u8, line[0..eq_idx], " \t");
            if (!std.mem.eql(u8, lhs, var_name)) continue;

            found = true;
            const rhs = line[eq_idx + 1 ..];
            const cont = try appendObjectTokensFromLine(allocator, &out, rhs);
            in_var = cont;
        } else {
            const cont = try appendObjectTokensFromLine(allocator, &out, line);
            in_var = cont;
            if (!in_var) break;
        }
    }

    if (!found) return error.MakeVariableNotFound;
    return out.toOwnedSlice(allocator);
}

pub fn appendObjectTokensFromLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    line_raw: []const u8,
) !bool {
    var line = std.mem.trim(u8, line_raw, " \t");
    var continued = false;
    if (line.len > 0 and line[line.len - 1] == '\\') {
        line = std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t");
        continued = true;
    }

    var tok_it = std.mem.tokenizeAny(u8, line, " \t");
    while (tok_it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '#') break;
        if (!std.ascii.endsWithIgnoreCase(tok, ".o")) continue;
        const src = try objectTokenToFortranSource(allocator, tok);
        try out.append(allocator, src);
    }
    return continued;
}

pub fn objectTokenToFortranSource(allocator: std.mem.Allocator, obj_token: []const u8) ![]const u8 {
    const stem = obj_token[0 .. obj_token.len - 2];
    return std.fmt.allocPrint(allocator, "{s}.f", .{stem});
}

pub fn collectFortranSources(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    dir_path: []const u8,
) ![]const []const u8 {
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try zig_api.openDirAbsolute(dir_path, .{ .iterate = true })
    else
        try zig_api.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var list: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(zig_api.defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '\\') != null) continue;
        if (!isFortranFile(entry.path)) continue;
        const rel = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(rel);
        const abs = try absolutizePath(allocator, root_path, rel);
        try list.append(allocator, abs);
    }
    std.sort.heap([]const u8, list.items, {}, lessThanString);
    return list.toOwnedSlice(allocator);
}

pub fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn isFortranFile(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "._")) return false;
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".f") or std.ascii.eqlIgnoreCase(ext, ".f90");
}

pub fn compileReferenceCase(
    allocator: std.mem.Allocator,
    gfortran_cmd: []const u8,
    out_exe: []const u8,
    source_paths: []const []const u8,
    libs: SupportLibs,
    timeout_ms: u64,
    cwd: []const u8,
) !bool {
    const obj_dir = try std.fs.path.join(allocator, &.{ cwd, "obj-ref-case" });
    defer allocator.free(obj_dir);
    try zig_api.cwd().makePath(obj_dir);

    var objs: std.ArrayList([]const u8) = .empty;
    defer {
        for (objs.items) |obj| allocator.free(obj);
        objs.deinit(allocator);
    }

    for (source_paths, 0..) |src, idx| {
        const obj_name = try std.fmt.allocPrint(allocator, "{d}.o", .{idx});
        defer allocator.free(obj_name);
        const obj_path = try std.fs.path.join(allocator, &.{ obj_dir, obj_name });
        try objs.append(allocator, obj_path);

        const cmd = [_][]const u8{ gfortran_cmd, "-std=legacy", "-O0", "-c", "-o", obj_path, src };
        const res = runProcessCaptureWithInput(allocator, &cmd, null, null, timeout_ms) catch |err| {
            std.log.err("gfortran invoke error: {s}\n", .{@errorName(err)});
            return false;
        };
        defer res.deinit(allocator);
        if (res.timed_out or !isZeroExit(res.term)) {
            std.log.err("reference compile failed ({s})\n{s}\n", .{ src, res.stderr });
            return false;
        }
    }

    var link_args: std.ArrayList([]const u8) = .empty;
    defer link_args.deinit(allocator);
    try link_args.appendSlice(allocator, &.{ gfortran_cmd, "-O0", "-o", out_exe });
    try link_args.appendSlice(allocator, objs.items);
    try link_args.appendSlice(allocator, &.{ libs.tmg_lib, libs.lapack_lib, libs.blas_lib });

    const link_res = runProcessCaptureWithInput(allocator, link_args.items, null, null, timeout_ms) catch |err| {
        std.log.err("gfortran link invoke error: {s}\n", .{@errorName(err)});
        return false;
    };
    defer link_res.deinit(allocator);
    if (link_res.timed_out or !isZeroExit(link_res.term)) {
        std.log.err("reference link failed\n{s}\n", .{link_res.stderr});
        return false;
    }
    return true;
}

pub fn selectTranslatedSources(
    allocator: std.mem.Allocator,
    source_paths: []const []const u8,
    translate_sources: bool,
) ![]const []const u8 {
    if (!translate_sources) return allocator.alloc([]const u8, 0);
    var selected: std.ArrayList([]const u8) = .empty;
    for (source_paths) |src| {
        if (!shouldTranslate(src)) continue;
        try selected.append(allocator, src);
    }
    return selected.toOwnedSlice(allocator);
}

pub fn shouldTranslate(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (base.len == 0) return false;
    if (std.mem.startsWith(u8, base, "._")) return false;
    for (FORTRAN_FALLBACK) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return false;
    }
    const ext = std.fs.path.extension(base);
    return std.ascii.eqlIgnoreCase(ext, ".f") or std.ascii.eqlIgnoreCase(ext, ".f90");
}

pub const TranslateResult = struct {
    sources: []const []const u8,
    ll_paths: []const []const u8,
};

pub fn translateSources(
    allocator: std.mem.Allocator,
    ll_dir: []const u8,
    cache_dir: []const u8,
    compiler_cache_key: []const u8,
    source_paths: []const []const u8,
    emit: Col6Forge.EmitKind,
    strict_translate: bool,
    fallback_tracker: *fallback_policy.Tracker,
    incremental: bool,
) !TranslateResult {
    var ll_buf: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ll_buf.items) |p| allocator.free(p);
        ll_buf.deinit(allocator);
    }
    var src_buf: std.ArrayList([]const u8) = .empty;
    errdefer src_buf.deinit(allocator);

    for (source_paths, 0..) |src_path, idx| {
        const base = std.fs.path.basename(src_path);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        const stem = base[0..dot];
        const ll_name = try std.fmt.allocPrint(allocator, "{d}_{s}.ll", .{ idx, stem });
        defer allocator.free(ll_name);
        const ll_path = try std.fs.path.join(allocator, &.{ ll_dir, ll_name });

        if (incremental) {
            const source_hash = try hashFileXx64(src_path);
            const ll_cache_path = try buildSourceLlCachePath(allocator, cache_dir, compiler_cache_key, source_hash, emit);
            defer allocator.free(ll_cache_path);
            if (fileExistsAbsolute(ll_cache_path)) {
                try copyFileAbsolute(ll_cache_path, ll_path);
            } else {
                var diag_bag = Col6Forge.diag.Bag.init(allocator);
                defer diag_bag.deinit();
                emitPipelineToFile(allocator, src_path, emit, ll_path, &diag_bag) catch |err| {
                    allocator.free(ll_path);
                    if (strict_translate) {
                        printPipelineError(src_path, &diag_bag, err);
                        return err;
                    }
                    try recordFallback(fallback_tracker, .pipeline, src_path);
                    printPipelineError(src_path, &diag_bag, err);
                    continue;
                };
                try copyFileAbsolute(ll_path, ll_cache_path);
            }
        } else {
            var diag_bag = Col6Forge.diag.Bag.init(allocator);
            defer diag_bag.deinit();
            emitPipelineToFile(allocator, src_path, emit, ll_path, &diag_bag) catch |err| {
                allocator.free(ll_path);
                if (strict_translate) {
                    printPipelineError(src_path, &diag_bag, err);
                    return err;
                }
                try recordFallback(fallback_tracker, .pipeline, src_path);
                printPipelineError(src_path, &diag_bag, err);
                continue;
            };
        }

        try src_buf.append(allocator, src_path);
        try ll_buf.append(allocator, ll_path);
    }
    return .{
        .sources = try src_buf.toOwnedSlice(allocator),
        .ll_paths = try ll_buf.toOwnedSlice(allocator),
    };
}

pub fn sourceInList(list: []const []const u8, path: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, path)) return true;
    }
    return false;
}

pub fn compileTranslatedCase(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    gfortran_cmd: []const u8,
    out_exe: []const u8,
    source_paths: []const []const u8,
    translated_sources: []const []const u8,
    ll_paths: []const []const u8,
    cache_dir: []const u8,
    runtime_cache_key: []const u8,
    libs: SupportLibs,
    runtime_backend: RuntimeBackend,
    timeout_ms: u64,
    cwd: []const u8,
    strict_translate: bool,
    fallback_tracker: *fallback_policy.Tracker,
    incremental: bool,
) !bool {
    const obj_dir = try std.fs.path.join(allocator, &.{ cwd, "obj-test-case" });
    defer allocator.free(obj_dir);
    try zig_api.cwd().makePath(obj_dir);

    var fallback_objs: std.ArrayList([]const u8) = .empty;
    defer {
        for (fallback_objs.items) |obj| allocator.free(obj);
        fallback_objs.deinit(allocator);
    }
    for (source_paths, 0..) |src, idx| {
        if (sourceInList(translated_sources, src)) continue;
        const obj_name = try std.fmt.allocPrint(allocator, "f_{d}.o", .{idx});
        defer allocator.free(obj_name);
        const obj_path = try std.fs.path.join(allocator, &.{ obj_dir, obj_name });
        try fallback_objs.append(allocator, obj_path);

        const cmd = [_][]const u8{ gfortran_cmd, "-std=legacy", "-O0", "-c", "-o", obj_path, src };
        const res = runProcessCaptureWithInput(allocator, &cmd, null, null, timeout_ms) catch |err| {
            std.log.err("gfortran invoke error: {s}\n", .{@errorName(err)});
            return false;
        };
        defer res.deinit(allocator);
        if (res.timed_out or !isZeroExit(res.term)) {
            std.log.err("fallback compile failed ({s})\n{s}\n", .{ src, res.stderr });
            return false;
        }
    }

    var trans_objs: std.ArrayList([]const u8) = .empty;
    defer {
        for (trans_objs.items) |obj| allocator.free(obj);
        trans_objs.deinit(allocator);
    }
    for (ll_paths, 0..) |ll_path, idx| {
        if (incremental) {
            const cached = getOrBuildTranslatedObject(allocator, ll_path, cache_dir, cwd, timeout_ms) catch |err| {
                if (strict_translate) {
                    std.log.warn("translated object cache failed ({s}): {s}\n", .{ ll_path, @errorName(err) });
                    return false;
                }
                const src_path = translated_sources[idx];
                recordFallback(fallback_tracker, .translated_object, src_path) catch return false;
                const fb_name = try std.fmt.allocPrint(allocator, "tfb_{d}.o", .{idx});
                defer allocator.free(fb_name);
                const fb_obj = try std.fs.path.join(allocator, &.{ obj_dir, fb_name });
                const fb_cmd = [_][]const u8{ gfortran_cmd, "-std=legacy", "-O0", "-c", "-o", fb_obj, src_path };
                const fb_res = runProcessCaptureWithInput(allocator, &fb_cmd, null, null, timeout_ms) catch |fb_err| {
                    std.log.err("gfortran invoke error: {s}\n", .{@errorName(fb_err)});
                    allocator.free(fb_obj);
                    return false;
                };
                defer fb_res.deinit(allocator);
                if (fb_res.timed_out or !isZeroExit(fb_res.term)) {
                    std.log.err("translated fallback compile failed ({s})\n{s}\n", .{ src_path, fb_res.stderr });
                    allocator.free(fb_obj);
                    return false;
                }
                try fallback_objs.append(allocator, fb_obj);
                continue;
            };
            try trans_objs.append(allocator, cached);
            continue;
        }

        const obj_name = try std.fmt.allocPrint(allocator, "t_{d}.o", .{idx});
        defer allocator.free(obj_name);
        const obj_path = try std.fs.path.join(allocator, &.{ obj_dir, obj_name });
        const cmd = [_][]const u8{ "zig", "cc", "-O0", "-c", "-o", obj_path, ll_path };
        const res = runProcessCaptureWithInput(allocator, &cmd, null, null, timeout_ms) catch |err| {
            std.log.err("zig cc invoke error: {s}\n", .{@errorName(err)});
            allocator.free(obj_path);
            return false;
        };
        defer res.deinit(allocator);
        if (res.timed_out or !isZeroExit(res.term)) {
            if (strict_translate) {
                std.log.err("translated compile failed ({s})\n{s}\n", .{ ll_path, res.stderr });
                allocator.free(obj_path);
                return false;
            }
            const src_path = translated_sources[idx];
            recordFallback(fallback_tracker, .translated_compile, src_path) catch {
                allocator.free(obj_path);
                return false;
            };
            const fb_name = try std.fmt.allocPrint(allocator, "tfb_{d}.o", .{idx});
            defer allocator.free(fb_name);
            const fb_obj = try std.fs.path.join(allocator, &.{ obj_dir, fb_name });
            const fb_cmd = [_][]const u8{ gfortran_cmd, "-std=legacy", "-O0", "-c", "-o", fb_obj, src_path };
            const fb_res = runProcessCaptureWithInput(allocator, &fb_cmd, null, null, timeout_ms) catch |err| {
                std.log.err("gfortran invoke error: {s}\n", .{@errorName(err)});
                allocator.free(obj_path);
                allocator.free(fb_obj);
                return false;
            };
            defer fb_res.deinit(allocator);
            if (fb_res.timed_out or !isZeroExit(fb_res.term)) {
                std.log.err("translated fallback compile failed ({s})\n{s}\n", .{ src_path, fb_res.stderr });
                allocator.free(obj_path);
                allocator.free(fb_obj);
                return false;
            }
            allocator.free(obj_path);
            try fallback_objs.append(allocator, fb_obj);
            continue;
        }
        try trans_objs.append(allocator, obj_path);
    }

    const link_runtime = shouldLinkRuntimeArtifacts(trans_objs.items.len);
    var runtime_artifacts: ?RuntimeArtifacts = null;
    if (link_runtime) {
        const runtime_output_dir = if (incremental) cache_dir else cwd;
        runtime_artifacts = prepareRuntimeArtifacts(
            allocator,
            root_path,
            runtime_output_dir,
            runtime_backend,
            timeout_ms,
            runtime_cache_key,
            incremental,
        ) catch |err| {
            std.log.err("runtime backend prepare failed: {s}\n", .{@errorName(err)});
            return false;
        };
    }
    defer if (runtime_artifacts) |*artifacts| artifacts.deinit(allocator);

    var link_args: std.ArrayList([]const u8) = .empty;
    defer link_args.deinit(allocator);
    try link_args.appendSlice(allocator, &.{ gfortran_cmd, "-O0" });
    if (builtin.os.tag == .windows and trans_objs.items.len > 0) {
        try link_args.append(allocator, "-Wl,--stack,33554432");
    }
    try link_args.appendSlice(allocator, &.{ "-o", out_exe });
    try link_args.appendSlice(allocator, fallback_objs.items);
    try link_args.appendSlice(allocator, trans_objs.items);
    try link_args.appendSlice(allocator, &.{ libs.tmg_lib, libs.lapack_lib, libs.blas_lib });
    if (runtime_artifacts) |artifacts| {
        try artifacts.appendToArgs(allocator, &link_args);
        if (artifacts.zig_object != null and builtin.os.tag == .windows) {
            try link_args.append(allocator, "-lntdll");
        }
    }

    const link_res = runProcessCaptureWithInput(allocator, link_args.items, null, null, timeout_ms) catch |err| {
        std.log.err("gfortran link invoke error: {s}\n", .{@errorName(err)});
        return false;
    };
    defer link_res.deinit(allocator);
    if (link_res.timed_out or !isZeroExit(link_res.term)) {
        std.log.err("translated link failed\n{s}\n", .{link_res.stderr});
        return false;
    }
    return true;
}

pub fn shouldLinkRuntimeArtifacts(translated_object_count: usize) bool {
    return translated_object_count > 0;
}

pub fn recordFallback(
    tracker: *fallback_policy.Tracker,
    kind: fallback_policy.Kind,
    src_path: []const u8,
) !void {
    try tracker.record(kind);
    std.log.warn("{s} fallback: {s}\n", .{ fallback_policy.kindEventLabel(kind), src_path });
}

pub fn formatFallbackSummary(buf: []u8, stats: fallback_policy.Stats) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try fallback_policy.writeSummary(&writer, stats);
    return writer.buffered();
}

pub fn formatFallbackBudgetExceeded(buf: []u8, stats: fallback_policy.Stats, max_fallbacks: usize) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try fallback_policy.writeBudgetExceeded(&writer, stats, max_fallbacks);
    return writer.buffered();
}

pub fn absolutizePath(allocator: std.mem.Allocator, root_path: []const u8, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ root_path, path });
}

pub fn buildExePath(allocator: std.mem.Allocator, dir: []const u8, base: []const u8) ![]const u8 {
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    const file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, ext });
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ dir, file_name });
}

pub fn writeFile(path: []const u8, contents: []const u8) !void {
    var file = try zig_api.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

pub fn emitPipelineToFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    emit: Col6Forge.EmitKind,
    output_path: []const u8,
    diag_bag: *Col6Forge.diag.Bag,
) !void {
    return pipeline_output.emitPipelineToFile(allocator, input_path, emit, output_path, diag_bag);
}

pub fn emitCacheTag(_: Col6Forge.EmitKind) []const u8 {
    return "llvm";
}

pub fn runtimeBackendTag(backend: RuntimeBackend) []const u8 {
    return switch (backend) {
        .c => "c",
        .zig => "zig",
    };
}

pub fn fileExistsAbsolute(path: []const u8) bool {
    return file_ops.pathExists(path);
}

pub fn hashFileXx64(path: []const u8) !u64 {
    return file_ops.hashFileXx64(path);
}

pub fn copyFileAbsolute(src_path: []const u8, dst_path: []const u8) !void {
    return file_ops.copyFile(src_path, dst_path);
}

pub fn buildSourceLlCachePath(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    compiler_cache_key: []const u8,
    source_hash: u64,
    emit: Col6Forge.EmitKind,
) ![]const u8 {
    const name = try std.fmt.allocPrint(
        allocator,
        "ll_v{d}_{s}_{s}_{x:0>16}.ll",
        .{ CACHE_SCHEMA_VERSION, emitCacheTag(emit), compiler_cache_key, source_hash },
    );
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache_dir, name });
}

pub fn buildTranslatedObjCachePath(allocator: std.mem.Allocator, cache_dir: []const u8, ll_hash: u64) ![]const u8 {
    const name = try std.fmt.allocPrint(allocator, "obj_v{d}_{x:0>16}.o", .{ CACHE_SCHEMA_VERSION, ll_hash });
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache_dir, name });
}

pub fn getOrBuildTranslatedObject(
    allocator: std.mem.Allocator,
    ll_path: []const u8,
    cache_dir: []const u8,
    cwd: []const u8,
    timeout_ms: u64,
) ![]const u8 {
    const ll_hash = try hashFileXx64(ll_path);
    const obj_cache_path = try buildTranslatedObjCachePath(allocator, cache_dir, ll_hash);
    errdefer allocator.free(obj_cache_path);
    if (fileExistsAbsolute(obj_cache_path)) return obj_cache_path;

    const cmd = [_][]const u8{ "zig", "cc", "-O0", "-c", "-o", obj_cache_path, ll_path };
    _ = cwd;
    const res = runProcessCaptureWithInput(allocator, &cmd, null, null, timeout_ms) catch |err| {
        std.log.err("zig cc invoke error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer res.deinit(allocator);
    if (res.timed_out) return error.TranslatedObjectCompileTimeout;
    if (!isZeroExit(res.term)) {
        std.log.err("translated compile failed ({s})\n{s}\n", .{ ll_path, res.stderr });
        return error.TranslatedObjectCompileFailed;
    }
    return obj_cache_path;
}

pub fn computeRuntimeCacheKey(allocator: std.mem.Allocator, root_path: []const u8) ![]const u8 {
    return cache_keys.computeRuntimeCacheKey(allocator, root_path);
}

pub fn computeCompilerCacheKey(allocator: std.mem.Allocator, root_path: []const u8) ![]const u8 {
    return cache_keys.computeCompilerCacheKey(allocator, root_path);
}

pub fn printPipelineError(path: []const u8, diag_bag: *const Col6Forge.diag.Bag, err: anyerror) void {
    pipeline_output.printPipelineError(path, diag_bag, err);
}

pub fn cleanupWorkDir(path: []const u8) void {
    zig_api.cwd().deleteTree(path) catch {};
}
