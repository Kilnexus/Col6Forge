const unit_analyzer = @import("core/unit_analyzer.zig");

pub const UnitAnalyzer = unit_analyzer.UnitAnalyzer;

test {
    _ = @import("tests/diagnostics_and_iso_c.zig");
    _ = @import("tests/function_result_diagnostics.zig");
    _ = @import("tests/function_result_pointer_assignment.zig");
    _ = @import("tests/polymorphic_decls_diagnostics.zig");
    _ = @import("tests/call_constraints.zig");
    _ = @import("tests/type_bindings.zig");
    _ = @import("tests/arrays_and_host_assoc.zig");
    _ = @import("tests/assumed_charlen_procedure_args.zig");
    _ = @import("tests/intrinsic_character_results.zig");
    _ = @import("tests/nested_array_constructor_shapes.zig");
    _ = @import("mod_proc_component_tests.zig");
}
