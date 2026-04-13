const model = @import("../model.zig");

pub const file_rules = [_]model.AuditRule{
    .{
        .id = "AR-TXT-002",
        .title = "legacy formatted entry call",
        .kind = .forbidden_function_call,
        .symbol_name = "emitWriteFormatted",
    },
    .{
        .id = "AR-TXT-003",
        .title = "legacy formatted entry call",
        .kind = .forbidden_function_call,
        .symbol_name = "emitReadFormatted",
    },
    .{
        .id = "AR-TXT-004",
        .title = "legacy formatted entry call",
        .kind = .forbidden_function_call,
        .symbol_name = "emitSpecialFormattedWrite",
    },
    .{
        .id = "AR-TXT-005",
        .title = "legacy formatted entry call",
        .kind = .forbidden_function_call,
        .symbol_name = "emitWriteDynamicFormat",
    },
    .{
        .id = "AR-TXT-006",
        .title = "legacy formatted entry call",
        .kind = .forbidden_function_call,
        .symbol_name = "emitReadDynamicFormat",
    },
    .{
        .id = "AR-TXT-007",
        .title = "legacy formatted entry call",
        .kind = .forbidden_function_call,
        .symbol_name = "streamFormatSource",
    },
    .{
        .id = "AR-TXT-008",
        .title = "legacy formatted entry call",
        .kind = .forbidden_function_call,
        .symbol_name = "emitWriteFormattedStreamPrepared",
    },
    .{
        .id = "AR-TXT-009",
        .title = "legacy formatted entry call",
        .kind = .forbidden_function_call,
        .symbol_name = "emitReadFormattedStreamPrepared",
    },
    .{
        .id = "AR-TXT-023",
        .title = "driver must not publish compat diagnostics",
        .kind = .forbidden_function_call,
        .scope = .{ .domain = .driver },
        .symbol_name = "publishCompatFromBag",
    },
    .{
        .id = "AR-TXT-024",
        .title = "tools must not publish compat diagnostics",
        .kind = .forbidden_function_call,
        .scope = .{ .domain = .tools },
        .symbol_name = "publishCompatFromBag",
    },
    .{
        .id = "AR-TXT-025",
        .title = "frontend parser must not publish compat diagnostics",
        .kind = .forbidden_function_call,
        .scope = .{ .prefix = "src/frontend/parser/" },
        .symbol_name = "publishCompatFromBag",
    },
};
