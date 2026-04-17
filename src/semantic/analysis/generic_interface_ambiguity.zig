const std = @import("std");
const context = @import("context.zig");

pub fn genericSpecificAmbiguous(a: context.Context.ProcedureSig, b: context.Context.ProcedureSig) bool {
    if (a.kind != b.kind) return false;
    if (genericSpecificRequiredArgCount(a) != genericSpecificRequiredArgCount(b)) return false;

    var a_idx: usize = 0;
    var b_idx: usize = 0;
    while (true) {
        while (a_idx < a.args.len and a.args[a_idx].optional) : (a_idx += 1) {}
        while (b_idx < b.args.len and b.args[b_idx].optional) : (b_idx += 1) {}
        if (a_idx >= a.args.len or b_idx >= b.args.len) return a_idx >= a.args.len and b_idx >= b.args.len;

        if (!genericSpecificArgEquivalent(a.args[a_idx], b.args[b_idx])) return false;
        a_idx += 1;
        b_idx += 1;
    }
}

fn genericSpecificRequiredArgCount(sig: context.Context.ProcedureSig) usize {
    var count: usize = 0;
    for (sig.args) |arg| {
        if (!arg.optional) count += 1;
    }
    return count;
}

fn genericSpecificArgEquivalent(a: context.Context.ProcedureSig.ArgSig, b: context.Context.ProcedureSig.ArgSig) bool {
    if (a.is_procedure or b.is_procedure) return a.is_procedure and b.is_procedure;
    if (a.rank != b.rank) return false;
    if (a.pointer != b.pointer) return false;
    if (a.allocatable != b.allocatable) return false;
    if (a.type_spec.lowered_kind != b.type_spec.lowered_kind) return false;
    if (a.type_spec.lowered_kind == .derived) {
        if (a.type_spec.derived_type_name == null or b.type_spec.derived_type_name == null) {
            return a.type_spec.derived_type_name == null and b.type_spec.derived_type_name == null;
        }
        return std.ascii.eqlIgnoreCase(a.type_spec.derived_type_name.?, b.type_spec.derived_type_name.?);
    }
    return true;
}
