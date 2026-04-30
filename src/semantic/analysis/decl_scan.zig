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
        active = decl.implicit.rules.len == 0;
    }
    return active;
}

pub fn implicitNoneExternalActive(self: *const context.Context) bool {
    for (self.unit.decls, 0..) |decl, idx| {
        if (decl != .implicit) continue;
        const source = if (idx < self.unit.decl_sources.len) self.unit.decl_sources[idx] else continue;
        if (implicitNoneSourceMentionsExternal(source.text)) return true;
    }
    return false;
}

pub fn currentImplicitNoneExternalIsDuplicate(self: *const context.Context) bool {
    const current_idx = self.current_decl_index orelse return false;
    const current_source = self.current_decl_source orelse return false;
    if (!implicitNoneSourceMentionsExternal(current_source.text)) return false;
    var idx: usize = 0;
    while (idx < current_idx and idx < self.unit.decls.len) : (idx += 1) {
        if (self.unit.decls[idx] != .implicit) continue;
        const source = if (idx < self.unit.decl_sources.len) self.unit.decl_sources[idx] else continue;
        if (implicitNoneSourceMentionsExternal(source.text)) return true;
    }
    return false;
}

fn implicitNoneSourceMentionsExternal(text: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, "implicit") != null and
        std.ascii.indexOfIgnoreCase(text, "none") != null and
        std.ascii.indexOfIgnoreCase(text, "external") != null;
}
