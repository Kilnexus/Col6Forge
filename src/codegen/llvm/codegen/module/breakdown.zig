const std = @import("std");
const zig_api = @import("../../../../compat/zig_api.zig");

pub const CodegenSubStage = enum {
    none,
    prelude,
    common_layouts,
    format_maps,
    unit_emit,
    intrinsic_wrappers,
    string_globals,
    entry_main,
    decls,
};

pub const CodegenBreakdownSample = struct {
    prelude_ns: u64 = 0,
    common_layouts_ns: u64 = 0,
    format_maps_ns: u64 = 0,
    unit_emit_ns: u64 = 0,
    intrinsic_wrappers_ns: u64 = 0,
    string_globals_ns: u64 = 0,
    entry_main_ns: u64 = 0,
    decls_ns: u64 = 0,
    total_ns: u64 = 0,
    failed_stage: CodegenSubStage = .none,
};

threadlocal var codegen_breakdown_storage: CodegenBreakdownSample = .{};
threadlocal var has_codegen_breakdown: bool = false;

pub fn clearLastBreakdownSample() void {
    has_codegen_breakdown = false;
    codegen_breakdown_storage = .{};
}

pub fn storeLastBreakdownSample(sample: CodegenBreakdownSample) void {
    codegen_breakdown_storage = sample;
    has_codegen_breakdown = true;
}

pub fn takeLastBreakdownSample() ?CodegenBreakdownSample {
    if (!has_codegen_breakdown) return null;
    has_codegen_breakdown = false;
    return codegen_breakdown_storage;
}

pub fn nowNs() i128 {
    return zig_api.nowNs();
}

pub fn elapsedNs(start: i128) u64 {
    const end = zig_api.nowNs();
    if (end <= start) return 0;
    return @intCast(end - start);
}

pub fn markFailure(sample: *CodegenBreakdownSample, stage: CodegenSubStage) void {
    if (sample.failed_stage == .none) sample.failed_stage = stage;
}
