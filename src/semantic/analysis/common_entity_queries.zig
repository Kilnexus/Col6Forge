const std = @import("std");
const ast = @import("../../ast/nodes.zig");

pub fn currentUnitDeclaresCommonEntity(unit: ast.ProgramUnit, name: []const u8) bool {
    for (unit.decls) |decl| {
        if (decl != .common) continue;
        for (decl.common.blocks) |block| {
            for (block.items) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
            }
        }
    }
    return false;
}
