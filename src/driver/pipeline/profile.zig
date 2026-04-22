const std = @import("std");
const codegen = @import("../../codegen/mod.zig");
const zig_api = @import("../../compat/zig_api.zig");

pub const PipelineStage = enum {
    none,
    read,
    normalize,
    parse,
    semantic,
    codegen,
    pipeline,
};

pub const PipelineProfileSample = struct {
    read_ns: u64 = 0,
    normalize_ns: u64 = 0,
    parse_ns: u64 = 0,
    semantic_ns: u64 = 0,
    codegen_ns: u64 = 0,
    codegen_prelude_ns: u64 = 0,
    codegen_common_layouts_ns: u64 = 0,
    codegen_format_maps_ns: u64 = 0,
    codegen_unit_emit_ns: u64 = 0,
    codegen_intrinsic_wrappers_ns: u64 = 0,
    codegen_string_globals_ns: u64 = 0,
    codegen_entry_main_ns: u64 = 0,
    codegen_decls_ns: u64 = 0,
    total_ns: u64 = 0,
    failed_stage: PipelineStage = .none,
};

threadlocal var profile_storage: PipelineProfileSample = .{};
threadlocal var has_profile: bool = false;

pub const PipelineProfileMode = enum {
    buffer,
    writer,
};

pub const PipelineProfile = struct {
    time_report: bool,
    capture_profile: bool,
    input_path: []const u8,
    mode: PipelineProfileMode,
    failed_stage: PipelineStage = .none,
    read_ns: u64 = 0,
    normalize_ns: u64 = 0,
    parse_ns: u64 = 0,
    semantic_ns: u64 = 0,
    codegen_ns: u64 = 0,
    codegen_prelude_ns: u64 = 0,
    codegen_common_layouts_ns: u64 = 0,
    codegen_format_maps_ns: u64 = 0,
    codegen_unit_emit_ns: u64 = 0,
    codegen_intrinsic_wrappers_ns: u64 = 0,
    codegen_string_globals_ns: u64 = 0,
    codegen_entry_main_ns: u64 = 0,
    codegen_decls_ns: u64 = 0,
    total_ns: u64 = 0,

    pub fn markFailure(self: *PipelineProfile, stage: PipelineStage) void {
        if (self.failed_stage != .none) return;
        self.failed_stage = stage;
    }

    pub fn sample(self: *const PipelineProfile) PipelineProfileSample {
        return .{
            .read_ns = self.read_ns,
            .normalize_ns = self.normalize_ns,
            .parse_ns = self.parse_ns,
            .semantic_ns = self.semantic_ns,
            .codegen_ns = self.codegen_ns,
            .codegen_prelude_ns = self.codegen_prelude_ns,
            .codegen_common_layouts_ns = self.codegen_common_layouts_ns,
            .codegen_format_maps_ns = self.codegen_format_maps_ns,
            .codegen_unit_emit_ns = self.codegen_unit_emit_ns,
            .codegen_intrinsic_wrappers_ns = self.codegen_intrinsic_wrappers_ns,
            .codegen_string_globals_ns = self.codegen_string_globals_ns,
            .codegen_entry_main_ns = self.codegen_entry_main_ns,
            .codegen_decls_ns = self.codegen_decls_ns,
            .total_ns = self.total_ns,
            .failed_stage = self.failed_stage,
        };
    }

    pub fn emit(self: *const PipelineProfile) void {
        if (!self.time_report) return;

        var stderr = zig_api.File.stderr();
        var buffer: [768]u8 = undefined;
        var writer = stderr.writer(&buffer);
        const mode_text = switch (self.mode) {
            .buffer => "buffer",
            .writer => "writer",
        };
        const status_text = if (self.failed_stage == .none) "ok" else "error";
        const failed_stage = stageName(self.failed_stage);

        writer.interface.print(
            "profile: file={s} mode={s} status={s} fail_stage={s} total_ms={d:.3} read_ms={d:.3} normalize_ms={d:.3} parse_ms={d:.3} sema_ms={d:.3} codegen_ms={d:.3}\n",
            .{
                self.input_path,
                mode_text,
                status_text,
                failed_stage,
                nsToMs(self.total_ns),
                nsToMs(self.read_ns),
                nsToMs(self.normalize_ns),
                nsToMs(self.parse_ns),
                nsToMs(self.semantic_ns),
                nsToMs(self.codegen_ns),
            },
        ) catch return;
        writer.interface.flush() catch {};
    }
};

pub fn applyCodegenBreakdown(profile: *PipelineProfile) void {
    const sample = codegen.takeLastBreakdownSample() orelse return;
    profile.codegen_prelude_ns = sample.prelude_ns;
    profile.codegen_common_layouts_ns = sample.common_layouts_ns;
    profile.codegen_format_maps_ns = sample.format_maps_ns;
    profile.codegen_unit_emit_ns = sample.unit_emit_ns;
    profile.codegen_intrinsic_wrappers_ns = sample.intrinsic_wrappers_ns;
    profile.codegen_string_globals_ns = sample.string_globals_ns;
    profile.codegen_entry_main_ns = sample.entry_main_ns;
    profile.codegen_decls_ns = sample.decls_ns;
}

pub fn takeLastProfileSample() ?PipelineProfileSample {
    if (!has_profile) return null;
    has_profile = false;
    return profile_storage;
}

pub fn nowNs() i128 {
    return zig_api.nowNs();
}

pub fn elapsedNs(start_ns: i128) u64 {
    const end_ns = zig_api.nowNs();
    if (end_ns <= start_ns) return 0;
    return @intCast(end_ns - start_ns);
}

pub fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

pub fn stageName(stage: PipelineStage) []const u8 {
    return switch (stage) {
        .none => "-",
        .read => "read",
        .normalize => "normalize",
        .parse => "parse",
        .semantic => "semantic",
        .codegen => "codegen",
        .pipeline => "pipeline",
    };
}

pub fn clearLastProfile() void {
    has_profile = false;
}

pub fn storeLastProfileSample(profile: PipelineProfile) void {
    profile_storage = profile.sample();
    has_profile = true;
}
