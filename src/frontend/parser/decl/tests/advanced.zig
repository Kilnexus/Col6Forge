const std = @import("std");
const ast = @import("../../../../ast/nodes.zig");
const decl_mod = @import("../mod.zig");
const context = @import("../../token_stream.zig");
const fixed_form = @import("../../../fixed_form.zig");
const free_form = @import("../../../free_form.zig");
const lexer = @import("../../../lexer.zig");

const LineParser = context.LineParser;
const TypeKind = ast.TypeKind;
const parseDecl = decl_mod.parseDecl;
const tryParseAllocateTypeSpec = decl_mod.tryParseAllocateTypeSpec;

test "tryParseAllocateTypeSpec keeps legacy REAL star selector metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      ALLOCATE(REAL*8 :: X)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const type_spec = (try tryParseAllocateTypeSpec(&lp, arena.allocator())) orelse return error.UnexpectedToken;
    try testing.expect(type_spec.legacy_star_kind);
    try testing.expectEqual(TypeKind.real, type_spec.type_kind);
}

test "parseDecl handles parameterized derived type declarator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      TYPE(T(:)), ALLOCATABLE :: X\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.derived, td.type_kind);
            try testing.expectEqualStrings("T", td.derived_type_name.?);
            try testing.expect(td.allocatable);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("X", td.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles COMPLEX kind selector in parentheses" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      COMPLEX(WP) :: X(*)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.complex, td.type_kind);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("X", td.items[0].name);
            try testing.expectEqual(@as(usize, 1), td.items[0].dims.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles COMPLEX KIND=16 selector" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      COMPLEX(KIND=16) :: Z\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.complex, td.type_kind);
            try testing.expect(td.kind_selector != null);
            switch (td.kind_selector.?.*) {
                .literal => |lit| try testing.expectEqualStrings("16", lit.text),
                else => return error.UnexpectedToken,
            }
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("Z", td.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl treats standalone ALLOCATABLE array declarations as deferred-shape dimensions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      ALLOCATABLE :: SUM(:), WORK(:,:)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .dimension => |dim| {
            try testing.expectEqual(@as(usize, 2), dim.items.len);
            try testing.expect(dim.allocatable);
            try testing.expectEqualStrings("SUM", dim.items[0].name);
            try testing.expectEqual(@as(usize, 1), dim.items[0].dims.len);
            try testing.expectEqualStrings("WORK", dim.items[1].name);
            try testing.expectEqual(@as(usize, 2), dim.items[1].dims.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl preserves deferred CHARACTER length for allocatable declarations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      CHARACTER(LEN=:), ALLOCATABLE :: S(:)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.character, td.type_kind);
            try testing.expect(td.allocatable);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expect(td.items[0].char_len == null);
            try testing.expect(td.items[0].char_len_deferred);
            try testing.expectEqual(@as(usize, 1), td.items[0].dims.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl preserves OPTIONAL declaration attribute" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      INTEGER, OPTIONAL :: A\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expect(td.optional);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("A", td.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles assumed type declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      TYPE(*) :: X\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.derived, td.type_kind);
            try testing.expect(!td.polymorphic);
            try testing.expect(td.assumed_type);
            try testing.expect(td.derived_type_name == null);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("X", td.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles SAVE with double colon" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      SAVE :: X\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .save => |save_decl| {
            try testing.expect(!save_decl.save_all);
            try testing.expectEqual(@as(usize, 1), save_decl.items.len);
            try testing.expect(save_decl.items[0] == .name);
            try testing.expectEqualStrings("X", save_decl.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl preserves asynchronous and volatile attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      REAL, ASYNCHRONOUS, VOLATILE :: A\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expect(td.asynchronous);
            try testing.expect(td.volatile_attr);
            try testing.expect(!td.contiguous);
            try testing.expect(!td.value_attr);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl preserves contiguous and value attributes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "real, contiguous, value :: a(:)\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expect(td.contiguous);
            try testing.expect(td.value_attr);
            try testing.expectEqual(@as(usize, 1), td.items[0].dims.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl preserves target attribute" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "real, target :: a\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expect(td.target);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("A", td.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles bare OPTIONAL declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      OPTIONAL :: J1\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .optional => |optional_decl| {
            try testing.expectEqual(@as(usize, 1), optional_decl.names.len);
            try testing.expectEqualStrings("J1", optional_decl.names[0]);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles bare VALUE declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      VALUE :: B\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .value => |value_decl| {
            try testing.expectEqual(@as(usize, 1), value_decl.names.len);
            try testing.expectEqualStrings("B", value_decl.names[0]);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles complex parameter declaration initializer with slash array constructor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      COMPLEX(KIND=DP), PARAMETER :: RI(2) = (/(1,0),(0,1)/)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.complex, td.type_kind);
            try testing.expect(td.parameter);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expect(td.items[0].init != null);
            try testing.expect(td.items[0].init.?.* == .array_constructor);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles free-form complex parameter declaration initializer with slash array constructor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "complex(kind=dp), parameter :: ri(2) = (/(1,0),(0,1)/)\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.complex, td.type_kind);
            try testing.expect(td.parameter);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expect(td.items[0].init != null);
            try testing.expect(td.items[0].init.?.* == .array_constructor);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles derived TYPE declaration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      TYPE(A), ALLOCATABLE :: B(:)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.derived, td.type_kind);
            try testing.expectEqualStrings("A", td.derived_type_name.?);
            try testing.expect(td.allocatable);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("B", td.items[0].name);
            try testing.expectEqual(@as(usize, 1), td.items[0].dims.len);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl handles fixed-form derived TYPE declaration without double colon" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      TYPE(SEQ)          UDS0L\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.derived, td.type_kind);
            try testing.expectEqualStrings("SEQ", td.derived_type_name.?);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("UDS0L", td.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl accepts POINTER declarator initialization with null intrinsic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "real(kind(1.d0)), pointer :: x(:) => null()\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expect(td.pointer);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expect(td.items[0].init != null);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl accepts free-form POINTER declarator initialization with null intrinsic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "real(kind(1.d0)), pointer :: x(:) => null()\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expect(td.pointer);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expect(td.items[0].init != null);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl accepts fixed-form legacy Cray POINTER pair syntax" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "      POINTER(PTR_X, X)\n";
    const lines = try fixed_form.normalizeFixedForm(allocator, source);
    defer fixed_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.integer, td.type_kind);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("PTR_X", td.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl accepts free-form legacy Cray POINTER pair list syntax" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "pointer(ptr1, x1), (ptr2, x2)\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.integer, td.type_kind);
            try testing.expectEqual(@as(usize, 2), td.items.len);
            try testing.expectEqualStrings("ptr1", td.items[0].name);
            try testing.expectEqualStrings("ptr2", td.items[1].name);
        },
        else => return error.UnexpectedToken,
    }
}

test "parseDecl accepts CODIMENSION attribute syntax and continues to declarator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const source = "character(*), dimension(*), codimension[*] :: x\n";
    const lines = try free_form.normalizeFreeForm(allocator, source);
    defer free_form.freeLogicalLines(allocator, lines);
    const tokens = try lexer.lexLogicalLine(allocator, lines[0]);
    defer allocator.free(tokens);
    var lp = LineParser.init(lines[0], tokens);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decl_node = try parseDecl(&lp, arena.allocator());

    switch (decl_node) {
        .type_decl => |td| {
            try testing.expectEqual(TypeKind.character, td.type_kind);
            try testing.expectEqual(@as(usize, 1), td.items.len);
            try testing.expectEqualStrings("x", td.items[0].name);
        },
        else => return error.UnexpectedToken,
    }
}
