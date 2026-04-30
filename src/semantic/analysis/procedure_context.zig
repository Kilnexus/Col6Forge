const std = @import("std");
const context = @import("context.zig");

pub fn shouldRejectNonRecursiveCurrentProcedureReference(self: *context.Context, name: []const u8) bool {
    if (self.unit.recursive) return false;
    if (self.unit.kind != .subroutine and self.unit.kind != .function) return false;
    if (std.ascii.eqlIgnoreCase(self.unit.name, name)) return true;
    return isSyntheticSiblingEntryProcedure(self, name);
}

fn isSyntheticSiblingEntryProcedure(self: *context.Context, name: []const u8) bool {
    for (self.unit.decls) |decl| {
        if (decl != .interface_block) continue;
        if (decl.interface_block.name != null) continue;
        for (decl.interface_block.procedure_headers) |proc_header| {
            if (proc_header.source.line != 0) continue;
            if (proc_header.recursive) continue;
            if (std.ascii.eqlIgnoreCase(proc_header.name, name)) return true;
        }
    }
    return false;
}
