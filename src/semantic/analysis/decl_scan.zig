const std = @import("std");
const context = @import("context.zig");

pub fn declaresNameLaterInCurrentUnit(self: *const context.Context, name: []const u8) bool {
    const start_idx = if (self.current_decl_index) |idx| idx + 1 else 0;
    var decl_idx = start_idx;
    while (decl_idx < self.unit.decls.len) : (decl_idx += 1) {
        const decl = self.unit.decls[decl_idx];
        switch (decl) {
            .type_decl => |type_decl| {
                for (type_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .procedure => |procedure_decl| {
                for (procedure_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            .dimension => |dimension_decl| {
                for (dimension_decl.items) |item| {
                    if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

pub fn implicitNoneActive(self: *const context.Context) bool {
    var active = false;
    for (self.unit.decls) |decl| {
        if (decl != .implicit) continue;
        active = decl.implicit.none_type or (decl.implicit.rules.len == 0 and !decl.implicit.none_external);
    }
    return active;
}

pub fn implicitExternalNoneActive(self: *const context.Context) bool {
    var active = false;
    for (self.unit.decls) |decl| {
        if (decl != .implicit) continue;
        active = decl.implicit.none_external;
    }
    return active;
}
