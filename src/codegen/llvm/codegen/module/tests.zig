const _diagnostics = @import("tests/diagnostics.zig");
const _module_lowering = @import("tests/module_lowering.zig");
const _array_intrinsics = @import("tests/array_intrinsics.zig");
const _abi_control_flow = @import("tests/abi_control_flow.zig");
const _control_where = @import("tests/control_where.zig");
const _io_streams = @import("tests/io_streams.zig");
const _formatted_io = @import("tests/formatted_io.zig");
const _interop_misc = @import("tests/interop_misc.zig");
const _procedure_pointer_lowering = @import("tests/procedure_pointer_lowering.zig");

test {
    _ = _diagnostics;
    _ = _module_lowering;
    _ = _array_intrinsics;
    _ = _abi_control_flow;
    _ = _control_where;
    _ = _io_streams;
    _ = _formatted_io;
    _ = _interop_misc;
    _ = _procedure_pointer_lowering;
}
