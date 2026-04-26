const ast = @import("../ast/nodes.zig");

pub fn unaryName(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .plus => "plus",
        .minus => "minus",
        .not => "not",
    };
}

pub fn binaryName(op: ast.BinaryOp) []const u8 {
    return binaryNameByMode(op, .plain);
}

pub fn unaryDefinedName(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .plus => "operator(+)",
        .minus => "operator(-)",
        .not => "operator(.not.)",
    };
}

pub fn binaryDefinedName(op: ast.BinaryOp) []const u8 {
    return binaryNameByMode(op, .defined);
}

const BinaryNameMode = enum {
    plain,
    defined,
};

fn binaryNameByMode(op: ast.BinaryOp, comptime mode: BinaryNameMode) []const u8 {
    return switch (op) {
        .add => if (mode == .plain) "add" else "operator(+)",
        .sub => if (mode == .plain) "sub" else "operator(-)",
        .mul => if (mode == .plain) "mul" else "operator(*)",
        .div => if (mode == .plain) "div" else "operator(/)",
        .concat => if (mode == .plain) "concat" else "operator(//)",
        .power => if (mode == .plain) "power" else "operator(**)",
        .eq => if (mode == .plain) "eq" else "operator(==)",
        .ne => if (mode == .plain) "ne" else "operator(/=)",
        .lt => if (mode == .plain) "lt" else "operator(<)",
        .le => if (mode == .plain) "le" else "operator(<=)",
        .gt => if (mode == .plain) "gt" else "operator(>)",
        .ge => if (mode == .plain) "ge" else "operator(>=)",
        .and_ => if (mode == .plain) "and" else "operator(.and.)",
        .or_ => if (mode == .plain) "or" else "operator(.or.)",
        .eqv => if (mode == .plain) "eqv" else "operator(.eqv.)",
        .neqv => if (mode == .plain) "neqv" else "operator(.neqv.)",
    };
}
