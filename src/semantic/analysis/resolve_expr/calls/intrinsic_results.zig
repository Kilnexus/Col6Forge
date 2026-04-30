const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const symbols = @import("../../../symbol/mod.zig");
const intrinsic_signature = @import("../../../intrinsic_signature.zig");
const context = @import("../../context.zig");
const constants = @import("../../resolve_const.zig");

pub fn intrinsicReturnType(
    self: *context.Context,
    name: []const u8,
    current: symbols.TypeSpec,
    args: []*ast.Expr,
    comptime deps: anytype,
) anyerror!symbols.TypeSpec {
    if (characterIntrinsicKind(self, name, args)) |kind_value| {
        return symbols.TypeSpec.fromResolvedKind(.character, .character, kind_value).withCharacterLength(.constant, 1);
    }

    var arg_types_buf: [8]symbols.TypeSpec = undefined;
    if (args.len <= arg_types_buf.len) {
        var arg_types = arg_types_buf[0..args.len];
        for (args, 0..) |arg, idx| {
            arg_types[idx] = try deps.exprTypeSpecCached(self, arg);
        }
        return intrinsic_signature.inferResultType(name, current, arg_types);
    }
    var dynamic_args = try self.arena.alloc(symbols.TypeSpec, args.len);
    for (args, 0..) |arg, idx| {
        dynamic_args[idx] = try deps.exprTypeSpecCached(self, arg);
    }
    return intrinsic_signature.inferResultType(name, current, dynamic_args);
}

fn characterIntrinsicKind(self: *context.Context, name: []const u8, args: []*ast.Expr) ?i64 {
    if (!std.ascii.eqlIgnoreCase(name, "CHAR") and !std.ascii.eqlIgnoreCase(name, "ACHAR")) return null;
    if (args.len < 2) return 1;
    const value = (constants.evalConst(self, args[1]) catch null) orelse return 1;
    return switch (value) {
        .integer => |kind_value| kind_value,
        else => 1,
    };
}
