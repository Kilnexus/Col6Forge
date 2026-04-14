const std = @import("std");
const ir = @import("../../ir.zig");
const ast = @import("../../../ast/nodes.zig");

pub const IRType = ir.IRType;

pub const ValueRef = struct {
    name: []const u8,
    ty: IRType,
    is_ptr: bool,
};

pub fn formatTempName(allocator: std.mem.Allocator, prefix: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "%{s}{d}", .{ prefix, index });
}

pub fn mangleName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    for (name) |ch| {
        try buffer.append(std.ascii.toLower(ch));
    }
    try buffer.append('_');
    return buffer.toOwnedSlice();
}

pub fn mangleProcedureUnitName(allocator: std.mem.Allocator, unit: ast.ProgramUnit) ![]const u8 {
    if (unit.bind_name) |bind_name| {
        if (bind_name.len == 0) return mangleName(allocator, unit.name);
        return lowerName(allocator, bind_name);
    }
    if (unit.owner_name) |owner_name| {
        const owner_prefix = switch (unit.owner_kind orelse .procedure) {
            .procedure => "proc",
            .module => "mod",
        };
        const owner_mangled = try lowerName(allocator, owner_name);
        const name_mangled = try lowerName(allocator, unit.name);
        return std.fmt.allocPrint(allocator, "{s}_{s}__{s}_", .{ owner_prefix, owner_mangled, name_mangled });
    }
    return mangleName(allocator, unit.name);
}

pub fn lowerName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    for (name) |ch| {
        try buffer.append(std.ascii.toLower(ch));
    }
    return buffer.toOwnedSlice();
}

pub fn canonicalNumericLabel(label: []const u8) []const u8 {
    if (label.len == 0) return label;
    for (label) |ch| {
        if (!std.ascii.isDigit(ch)) return label;
    }
    var start: usize = 0;
    while (start + 1 < label.len and label[start] == '0') : (start += 1) {}
    return label[start..];
}

pub fn savedGlobalName(allocator: std.mem.Allocator, unit: ast.ProgramUnit, symbol_name: []const u8) ![]const u8 {
    const unit_mangled = try mangleProcedureUnitName(allocator, unit);
    const sym_lower = try lowerName(allocator, symbol_name);
    return std.fmt.allocPrint(allocator, "save_{s}{s}", .{ unit_mangled, sym_lower });
}

pub fn hostAssocGlobalName(allocator: std.mem.Allocator, owner_name: []const u8, symbol_name: []const u8) ![]const u8 {
    const owner_mangled = try mangleName(allocator, owner_name);
    const sym_lower = try lowerName(allocator, symbol_name);
    return std.fmt.allocPrint(allocator, "host_{s}{s}", .{ owner_mangled, sym_lower });
}

pub fn normalizeFloatLiteral(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const kind_start = kindUnderscoreIndex(text) orelse text.len;
    var core = std.array_list.Managed(u8).init(allocator);
    defer core.deinit();
    for (text[0..kind_start]) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        try core.append(ch);
    }

    var buffer = std.array_list.Managed(u8).init(allocator);
    var start: usize = 0;
    if (core.items.len >= 1 and core.items[0] == '.') {
        try buffer.append('0');
    } else if (core.items.len >= 2 and (core.items[0] == '+' or core.items[0] == '-') and core.items[1] == '.') {
        try buffer.append(core.items[0]);
        try buffer.append('0');
        start = 1;
    }
    for (core.items[start..]) |ch| {
        const out = if (ch == 'D' or ch == 'd') 'E' else ch;
        try buffer.append(out);
    }
    if (buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '.') {
        try buffer.append('0');
    }
    return buffer.toOwnedSlice();
}

pub fn hasDExponent(text: []const u8) bool {
    const end = kindUnderscoreIndex(text) orelse text.len;
    return std.mem.indexOfAny(u8, text[0..end], "Dd") != null;
}

pub fn literalKindSuffix(text: []const u8) ?[]const u8 {
    const kind_start = kindUnderscoreIndex(text) orelse return null;
    var i = kind_start + 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
    return text[kind_start + 1 .. i];
}

pub fn literalKindSuggestsF64(text: []const u8) bool {
    const suffix = literalKindSuffix(text) orelse return false;
    if (suffix.len == 0) return false;

    var all_digits = true;
    for (suffix) |ch| {
        if (!std.ascii.isDigit(ch)) {
            all_digits = false;
            break;
        }
    }
    if (all_digits) {
        const kind_val = std.fmt.parseInt(i64, suffix, 10) catch return false;
        return kind_val >= 8;
    }

    return std.ascii.eqlIgnoreCase(suffix, "wp") or
        std.ascii.eqlIgnoreCase(suffix, "dp") or
        std.ascii.eqlIgnoreCase(suffix, "real64") or
        std.ascii.eqlIgnoreCase(suffix, "float64") or
        std.ascii.eqlIgnoreCase(suffix, "rk8") or
        std.ascii.eqlIgnoreCase(suffix, "k8");
}

pub fn realLiteralType(text: []const u8) IRType {
    if (hasDExponent(text) or literalKindSuggestsF64(text)) return .f64;
    return .f32;
}

pub fn normalizeIntLiteral(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const kind_start = kindUnderscoreIndex(text) orelse text.len;
    var buffer = std.array_list.Managed(u8).init(allocator);
    for (text[0..kind_start]) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        try buffer.append(ch);
    }
    return buffer.toOwnedSlice();
}

pub fn zeroValue(ty: IRType) ValueRef {
    return switch (ty) {
        .i1 => .{ .name = "0", .ty = .i1, .is_ptr = false },
        .i8 => .{ .name = "0", .ty = .i8, .is_ptr = false },
        .i32 => .{ .name = "0", .ty = .i32, .is_ptr = false },
        .i64 => .{ .name = "0", .ty = .i64, .is_ptr = false },
        .f32 => .{ .name = "0.0", .ty = .f32, .is_ptr = false },
        .f64 => .{ .name = "0.0", .ty = .f64, .is_ptr = false },
        .v2f32 => .{ .name = "zeroinitializer", .ty = .v2f32, .is_ptr = false },
        .complex_f32 => .{ .name = "zeroinitializer", .ty = .complex_f32, .is_ptr = false },
        .complex_f64 => .{ .name = "zeroinitializer", .ty = .complex_f64, .is_ptr = false },
        .ptr => .{ .name = "null", .ty = .ptr, .is_ptr = false },
        .void => .{ .name = "", .ty = .void, .is_ptr = false },
    };
}

pub fn oneValue() ValueRef {
    return .{ .name = "1", .ty = .i32, .is_ptr = false };
}

test "mangleProcedureUnitName namespaces owned procedures and honors bind names" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const module_unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "FUN",
        .owner_name = "MOD_A",
        .owner_kind = .module,
        .args = &.{},
        .decls = &.{},
        .stmts = &.{},
    };
    const internal_unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "INNER",
        .owner_name = "OUTER",
        .owner_kind = .procedure,
        .args = &.{},
        .decls = &.{},
        .stmts = &.{},
    };
    const bind_unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "FOO",
        .bind_name = "Bar",
        .args = &.{},
        .decls = &.{},
        .stmts = &.{},
    };
    const empty_bind_unit = ast.ProgramUnit{
        .kind = .subroutine,
        .name = "EMPTY",
        .bind_name = "",
        .args = &.{},
        .decls = &.{},
        .stmts = &.{},
    };

    const module_name = try mangleProcedureUnitName(allocator, module_unit);
    defer allocator.free(module_name);
    try testing.expectEqualStrings("mod_mod_a__fun_", module_name);

    const internal_name = try mangleProcedureUnitName(allocator, internal_unit);
    defer allocator.free(internal_name);
    try testing.expectEqualStrings("proc_outer__inner_", internal_name);

    const bind_name = try mangleProcedureUnitName(allocator, bind_unit);
    defer allocator.free(bind_name);
    try testing.expectEqualStrings("bar", bind_name);

    const empty_bind_name = try mangleProcedureUnitName(allocator, empty_bind_unit);
    defer allocator.free(empty_bind_name);
    try testing.expectEqualStrings("empty_", empty_bind_name);
}

pub fn formatInt(allocator: std.mem.Allocator, value: i64) []const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value}) catch "0";
}

pub fn formatReal(allocator: std.mem.Allocator, value: f64) []const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value}) catch "0.0";
}

pub fn formatFloatValue(allocator: std.mem.Allocator, value: f64, ty: IRType) []const u8 {
    var fmt_value: f64 = switch (ty) {
        .f32 => @as(f64, @floatCast(@as(f32, @floatCast(value)))),
        .f64 => value,
        else => return "0.0",
    };
    if (std.math.isNan(fmt_value)) return "0.0";
    if (!std.math.isFinite(fmt_value)) {
        const finite_max: f64 = switch (ty) {
            .f32 => @as(f64, std.math.floatMax(f32)),
            .f64 => std.math.floatMax(f64),
            else => 0.0,
        };
        fmt_value = if (std.math.signbit(fmt_value)) -finite_max else finite_max;
    }
    if (fmt_value == 0.0) return "0.0";
    const raw = std.fmt.allocPrint(allocator, "{e}", .{fmt_value}) catch return "0.0";
    if (std.mem.indexOfScalar(u8, raw, '.') != null) return raw;
    const e_pos = std.mem.indexOfAny(u8, raw, "eE") orelse return raw;
    var buffer = std.array_list.Managed(u8).init(allocator);
    buffer.appendSlice(raw[0..e_pos]) catch return raw;
    buffer.appendSlice(".0") catch return raw;
    buffer.appendSlice(raw[e_pos..]) catch return raw;
    return buffer.toOwnedSlice() catch raw;
}

pub fn formatFloatLiteral(allocator: std.mem.Allocator, text: []const u8, ty: IRType) ![]const u8 {
    const normalized = try normalizeFloatLiteral(allocator, text);
    const value = std.fmt.parseFloat(f64, normalized) catch return error.InvalidFloatLiteral;
    return formatFloatValue(allocator, value, ty);
}

pub fn decodeStringLiteral(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const quote_start = quotedLiteralStart(text) orelse return allocator.dupe(u8, text);
    const quoted = text[quote_start..];
    if (quoted.len < 2) return allocator.dupe(u8, quoted);
    const quote = quoted[0];
    if ((quote != '\'' and quote != '"') or quoted[quoted.len - 1] != quote) {
        return allocator.dupe(u8, quoted);
    }
    var buffer = std.array_list.Managed(u8).init(allocator);
    var i: usize = 1;
    const end = quoted.len - 1;
    while (i < end) {
        const ch = quoted[i];
        if (ch == quote and i + 1 < end and quoted[i + 1] == quote) {
            try buffer.append(quote);
            i += 2;
            continue;
        }
        try buffer.append(ch);
        i += 1;
    }
    return buffer.toOwnedSlice();
}

pub fn decodedStringLen(text: []const u8) usize {
    const quote_start = quotedLiteralStart(text) orelse return text.len;
    const quoted = text[quote_start..];
    if (quoted.len < 2) return quoted.len;
    const quote = quoted[0];
    if ((quote != '\'' and quote != '"') or quoted[quoted.len - 1] != quote) return quoted.len;
    var len: usize = 0;
    var i: usize = 1;
    const end = quoted.len - 1;
    while (i < end) {
        if (quoted[i] == quote and i + 1 < end and quoted[i + 1] == quote) {
            len += 1;
            i += 2;
            continue;
        }
        len += 1;
        i += 1;
    }
    return len;
}

pub fn hollerithBytes(text: []const u8) ?[]const u8 {
    const idx = std.mem.indexOfScalar(u8, text, 'H') orelse std.mem.indexOfScalar(u8, text, 'h') orelse return null;
    if (idx + 1 > text.len) return null;
    return text[idx + 1 ..];
}

fn kindUnderscoreIndex(text: []const u8) ?usize {
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] != '_') continue;
        if (!std.ascii.isAlphanumeric(text[i + 1])) continue;
        return i;
    }
    return null;
}

fn quotedLiteralStart(text: []const u8) ?usize {
    if (text.len == 0) return null;
    if (text[0] == '\'' or text[0] == '"') return 0;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if ((text[i] == '\'' or text[i] == '"') and text[i - 1] == '_') return i;
    }
    return null;
}

test "normalizeFloatLiteral strips kind suffix" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const normalized = try normalizeFloatLiteral(allocator, "1.0e-1_wp");
    defer allocator.free(normalized);
    try testing.expectEqualStrings("1.0e-1", normalized);
}

test "realLiteralType detects D exponent and kind suffix" {
    const testing = std.testing;

    try testing.expectEqual(IRType.f64, realLiteralType("1.0D0"));
    try testing.expectEqual(IRType.f64, realLiteralType("1.0_wp"));
    try testing.expectEqual(IRType.f64, realLiteralType("1.0_8"));
    try testing.expectEqual(IRType.f32, realLiteralType("1.0_sp"));
}
