const std = @import("std");
const context = @import("../context/mod.zig");
const llvm_types = @import("../../types.zig");

pub fn emitIntrinsicWrappers(
    builder: anytype,
    wrappers: *const std.StringHashMap(context.IntrinsicWrapperKind),
    options: context.CodegenOptions,
) !void {
    var it = wrappers.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .iabs => try emitIabsWrapper(builder, entry.key_ptr.*, options),
            .sin => try emitUnaryFloatWrapper(builder, entry.key_ptr.*, .f32, "sinf", options),
            .dcos => try emitUnaryFloatWrapper(builder, entry.key_ptr.*, .f64, "cos", options),
            .dcosh => try emitUnaryFloatWrapper(builder, entry.key_ptr.*, .f64, "cosh", options),
            .dexp => try emitUnaryFloatWrapper(builder, entry.key_ptr.*, .f64, "exp", options),
            .conjg => try emitConjgWrapper(builder, entry.key_ptr.*, options),
        }
    }
}

fn emitIabsWrapper(builder: anytype, name: []const u8, options: context.CodegenOptions) !void {
    const int_ty = llvm_types.defaultIntegerType(options.target_layout);
    try builder.defineStartWithRet(int_ty, name);
    try builder.defineArgPtr("%arg0", true);
    try builder.defineEnd();
    try builder.entryLabel();
    const arg_ptr = context.ValueRef{ .name = "%arg0", .ty = .ptr, .is_ptr = true };
    try builder.load("%t0", int_ty, arg_ptr);
    const value = context.ValueRef{ .name = "%t0", .ty = int_ty, .is_ptr = false };
    const zero = context.ValueRef{ .name = "0", .ty = int_ty, .is_ptr = false };
    try builder.compare("%t1", "icmp", "slt", int_ty, value, zero);
    const cond = context.ValueRef{ .name = "%t1", .ty = .i1, .is_ptr = false };
    try builder.binary("%t2", "sub", int_ty, zero, value);
    const neg = context.ValueRef{ .name = "%t2", .ty = int_ty, .is_ptr = false };
    try builder.select("%t3", int_ty, cond, neg, value);
    try builder.retValue(int_ty, "%t3");
    try builder.functionEnd();
}

fn emitUnaryFloatWrapper(
    builder: anytype,
    name: []const u8,
    float_ty: llvm_types.IRType,
    callee_name: []const u8,
    options: context.CodegenOptions,
) !void {
    _ = options;
    try builder.defineStartWithRet(float_ty, name);
    try builder.defineArgPtr("%arg0", true);
    try builder.defineEnd();
    try builder.entryLabel();
    const arg_ptr = context.ValueRef{ .name = "%arg0", .ty = .ptr, .is_ptr = true };
    try builder.load("%t0", float_ty, arg_ptr);
    const arg = context.ValueRef{ .name = "%t0", .ty = float_ty, .is_ptr = false };
    try builder.callTyped("%t1", float_ty, callee_name, &.{arg});
    try builder.retValue(float_ty, "%t1");
    try builder.functionEnd();
}

fn emitConjgWrapper(builder: anytype, name: []const u8, options: context.CodegenOptions) !void {
    _ = options;
    try builder.defineStartWithRet(.complex_f32, name);
    try builder.defineArgPtr("%arg0", true);
    try builder.defineEnd();
    try builder.entryLabel();
    const arg_ptr = context.ValueRef{ .name = "%arg0", .ty = .ptr, .is_ptr = true };
    try builder.load("%t0", .complex_f32, arg_ptr);
    const value = context.ValueRef{ .name = "%t0", .ty = .complex_f32, .is_ptr = false };
    try builder.extractValue("%t1", .complex_f32, value, 0);
    try builder.extractValue("%t2", .complex_f32, value, 1);
    const imag = context.ValueRef{ .name = "%t2", .ty = .f32, .is_ptr = false };
    const zero = context.ValueRef{ .name = "0.0", .ty = .f32, .is_ptr = false };
    try builder.binary("%t3", "fsub", .f32, zero, imag);
    const undef = context.ValueRef{ .name = "undef", .ty = .complex_f32, .is_ptr = false };
    const real = context.ValueRef{ .name = "%t1", .ty = .f32, .is_ptr = false };
    const neg_imag = context.ValueRef{ .name = "%t3", .ty = .f32, .is_ptr = false };
    try builder.insertValue("%t4", .complex_f32, undef, .f32, real, 0);
    try builder.insertValue("%t5", .complex_f32, .{ .name = "%t4", .ty = .complex_f32, .is_ptr = false }, .f32, neg_imag, 1);
    try builder.retValue(.complex_f32, "%t5");
    try builder.functionEnd();
}
