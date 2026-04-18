const unit_analyzer = @import("core/unit_analyzer.zig");

pub const UnitAnalyzer = unit_analyzer.UnitAnalyzer;

test {
    _ = @import("tests/diagnostics_and_iso_c.zig");
    _ = @import("tests/function_result_diagnostics.zig");
    _ = @import("tests/function_result_pointer_assignment.zig");
    _ = @import("tests/call_constraints.zig");
    _ = @import("tests/type_bindings.zig");
    _ = @import("tests/arrays_and_host_assoc.zig");
}
