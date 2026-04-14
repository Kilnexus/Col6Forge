const std = @import("std");
const ast = @import("nodes.zig");

pub fn printProgram(writer: anytype, program: ast.Program) !void {
    try writer.print("; AST units: {d}\n", .{program.units.len});
    for (program.units) |unit| {
        const kind_text = switch (unit.kind) {
            .module => "module",
            .program => "program",
            .subroutine => "subroutine",
            .function => "function",
            .block_data => "block_data",
        };
        try writer.print("; unit {s} {s}\n", .{ kind_text, unit.name });
        try writer.print(";  args({d})\n", .{unit.args.len});
        for (unit.args) |arg| {
            try writer.print(";   arg {s}\n", .{arg});
        }
        try writer.print(";  decls({d})\n", .{unit.decls.len});
        for (unit.decls) |decl| {
            try printDecl(writer, decl);
        }
        try writer.print(";  stmts({d})\n", .{unit.stmts.len});
        for (unit.stmts) |stmt| {
            try printStmt(writer, stmt);
        }
    }
}

fn printDecl(writer: anytype, decl: ast.Decl) !void {
    switch (decl) {
        .implicit => |imp| {
            try writer.print(";   decl implicit rules({d})\n", .{imp.rules.len});
        },
        .type_decl => |td| {
            try writer.print(";   decl type {s} items({d})\n", .{ typeKindName(td.type_kind), td.items.len });
        },
        .bind_entity => |bind_entity_decl| {
            try writer.print(";   decl bind-entity names({d})\n", .{bind_entity_decl.names.len});
        },
        .procedure => |proc_decl| {
            const mode = if (proc_decl.pointer) "pointer" else "plain";
            try writer.print(";   decl procedure {s} items({d})\n", .{ mode, proc_decl.items.len });
        },
        .derived_type_def => |derived| {
            try writer.print(";   decl derived-type {s}\n", .{derived.name});
        },
        .interface_block => |interface_block| {
            const mode = if (interface_block.abstract) "abstract" else "plain";
            try writer.print(";   decl interface-block {s}", .{mode});
            if (interface_block.name) |name| {
                try writer.print(" {s}", .{name});
            }
            if (interface_block.module_procedures.len != 0) {
                try writer.print(" module-procedures=", .{});
                for (interface_block.module_procedures, 0..) |proc_name, idx| {
                    if (idx != 0) try writer.print(",", .{});
                    try writer.print("{s}", .{proc_name});
                }
            }
            if (interface_block.specific_procedures.len != 0) {
                try writer.print(" specific-procedures=", .{});
                for (interface_block.specific_procedures, 0..) |proc_name, idx| {
                    if (idx != 0) try writer.print(",", .{});
                    try writer.print("{s}", .{proc_name});
                }
            }
            if (interface_block.procedures.len != 0) {
                try writer.print(" procedures=", .{});
                for (interface_block.procedures, 0..) |proc_name, idx| {
                    if (idx != 0) try writer.print(",", .{});
                    try writer.print("{s}", .{proc_name});
                }
            }
            if (interface_block.procedure_headers.len != 0) {
                try writer.print(" headers=", .{});
                for (interface_block.procedure_headers, 0..) |proc_header, idx| {
                    if (idx != 0) try writer.print(",", .{});
                    try writer.print("{s}/{s}/{d}", .{
                        proc_header.name,
                        @tagName(proc_header.kind),
                        proc_header.args.len,
                    });
                }
            }
            try writer.print("\n", .{});
        },
        .import => |import_decl| {
            try writer.print(";   decl import names({d})\n", .{import_decl.names.len});
        },
        .intent => |intent_decl| {
            try writer.print(";   decl intent {s} names({d})\n", .{ @tagName(intent_decl.kind), intent_decl.names.len });
        },
        .optional => |optional_decl| {
            try writer.print(";   decl optional names({d})\n", .{optional_decl.names.len});
        },
        .dimension => |dim| {
            try writer.print(";   decl dimension items({d})\n", .{dim.items.len});
        },
        .parameter => |param| {
            try writer.print(";   decl parameter assigns({d})\n", .{param.assigns.len});
        },
        .common => |common| {
            try writer.print(";   decl common blocks({d})\n", .{common.blocks.len});
        },
        .equivalence => |eqv| {
            try writer.print(";   decl equivalence groups({d})\n", .{eqv.groups.len});
        },
        .external => |ext| {
            try writer.print(";   decl external names({d})\n", .{ext.names.len});
        },
        .intrinsic => |intr| {
            try writer.print(";   decl intrinsic names({d})\n", .{intr.names.len});
        },
        .save => |save| {
            const count = save.items.len;
            const mode = if (save.save_all) "all" else "list";
            try writer.print(";   decl save {s} items({d})\n", .{ mode, count });
        },
    }
}

fn printStmt(writer: anytype, stmt: ast.Stmt) !void {
    const label_text = if (stmt.label) |l| l else "-";
    switch (stmt.node) {
        .assignment => |assign| {
            try writer.print(";   stmt label={s} assignment\n", .{label_text});
            try printAssignmentDetails(writer, assign, 2);
        },
        .pointer_assignment => |assign| {
            try writer.print(";   stmt label={s} pointer-assignment\n", .{label_text});
            try printPointerAssignmentDetails(writer, assign, 2);
        },
        .nullify => |nullify| {
            try writer.print(";   stmt label={s} nullify items({d})\n", .{ label_text, nullify.items.len });
        },
        .associate_block => |associate| {
            try writer.print(";   stmt label={s} associate bindings({d}) stmts({d})\n", .{ label_text, associate.bindings.len, associate.stmts.len });
        },
        .assign_label => |assign| {
            try writer.print(";   stmt label={s} assign {s} to {s}\n", .{ label_text, assign.label, assign.target });
        },
        .use_stmt => |use_stmt| {
            try writer.print(";   stmt label={s} use {s} has_only={} items({d})\n", .{ label_text, use_stmt.module_name, use_stmt.has_only, use_stmt.only_items.len });
        },
        .call => |call| {
            try writer.print(";   stmt label={s} call {s}({d})\n", .{ label_text, call.name, call.args.len });
            for (call.args) |arg| {
                switch (arg) {
                    .expr => |actual| {
                        if (actual.keyword) |keyword| {
                            try writer.print(";     actual keyword {s}\n", .{keyword});
                        }
                    },
                    .alt_return => {},
                }
            }
        },
        .write => |write| {
            try writer.print(";   stmt label={s} write args={d}\n", .{ label_text, write.args.len });
            try printIoDetails(writer, write.unit, write.format, write.rec, write.args, write.err_label, null, write.iostat, 2);
        },
        .read => |read| {
            try writer.print(";   stmt label={s} read args={d}\n", .{ label_text, read.args.len });
            try printIoDetails(writer, read.unit, read.format, read.rec, read.args, read.err_label, read.end_label, read.iostat, 2);
        },
        .rewind => |rw| {
            try writer.print(";   stmt label={s} rewind\n", .{label_text});
            try printIndent(writer, 2);
            try writer.writeAll("unit:\n");
            try printExpr(writer, rw.unit, 3);
            if (rw.err_label) |label| {
                try printIndent(writer, 2);
                try writer.print("err-label: {s}\n", .{label});
            }
            if (rw.iostat) |io_expr| {
                try printIndent(writer, 2);
                try writer.writeAll("iostat:\n");
                try printExpr(writer, io_expr, 3);
            }
        },
        .backspace => |bs| {
            try writer.print(";   stmt label={s} backspace\n", .{label_text});
            try printIndent(writer, 2);
            try writer.writeAll("unit:\n");
            try printExpr(writer, bs.unit, 3);
            if (bs.err_label) |label| {
                try printIndent(writer, 2);
                try writer.print("err-label: {s}\n", .{label});
            }
            if (bs.iostat) |io_expr| {
                try printIndent(writer, 2);
                try writer.writeAll("iostat:\n");
                try printExpr(writer, io_expr, 3);
            }
        },
        .endfile => |ef| {
            try writer.print(";   stmt label={s} endfile\n", .{label_text});
            try printIndent(writer, 2);
            try writer.writeAll("unit:\n");
            try printExpr(writer, ef.unit, 3);
            if (ef.err_label) |label| {
                try printIndent(writer, 2);
                try writer.print("err-label: {s}\n", .{label});
            }
            if (ef.iostat) |io_expr| {
                try printIndent(writer, 2);
                try writer.writeAll("iostat:\n");
                try printExpr(writer, io_expr, 3);
            }
        },
        .open => |opn| {
            try writer.print(";   stmt label={s} open\n", .{label_text});
            try printIndent(writer, 2);
            try writer.writeAll("unit:\n");
            try printExpr(writer, opn.unit, 3);
            if (opn.recl) |recl| {
                try printIndent(writer, 2);
                try writer.writeAll("recl:\n");
                try printExpr(writer, recl, 3);
            }
            if (opn.file) |file| {
                try printIndent(writer, 2);
                try writer.writeAll("file:\n");
                try printExpr(writer, file, 3);
            }
            if (opn.access) |access| {
                try printIndent(writer, 2);
                try writer.writeAll("access:\n");
                try printExpr(writer, access, 3);
            }
            if (opn.form) |form| {
                try printIndent(writer, 2);
                try writer.writeAll("form:\n");
                try printExpr(writer, form, 3);
            }
            if (opn.blank) |blank| {
                try printIndent(writer, 2);
                try writer.writeAll("blank:\n");
                try printExpr(writer, blank, 3);
            }
            if (opn.status) |status| {
                try printIndent(writer, 2);
                try writer.writeAll("status:\n");
                try printExpr(writer, status, 3);
            }
            if (opn.err_label) |label| {
                try printIndent(writer, 2);
                try writer.print("err-label: {s}\n", .{label});
            }
            if (opn.iostat) |io_expr| {
                try printIndent(writer, 2);
                try writer.writeAll("iostat:\n");
                try printExpr(writer, io_expr, 3);
            }
        },
        .inquire => |inq| {
            try writer.print(";   stmt label={s} inquire controls({d})\n", .{ label_text, inq.controls.len });
        },
        .close => |cls| {
            try writer.print(";   stmt label={s} close controls({d})\n", .{ label_text, cls.controls.len });
        },
        .allocate => |allocate| {
            try writer.print(";   stmt label={s} allocate items({d}) options({d})\n", .{ label_text, allocate.items.len, allocate.options.len });
        },
        .deallocate => |deallocate| {
            try writer.print(";   stmt label={s} deallocate items({d}) options({d})\n", .{ label_text, deallocate.items.len, deallocate.options.len });
        },
        .data => |data| {
            try writer.print(";   stmt label={s} data inits({d})\n", .{ label_text, data.inits.len });
        },
        .format => |format| {
            try writer.print(";   stmt label={s} format items={d}\n", .{ label_text, format.items.len });
            try printFormatItems(writer, format.items, 2);
        },
        .arith_if => |node| {
            try writer.print(
                ";   stmt label={s} arith-if {s},{s},{s}\n",
                .{ label_text, node.neg_label, node.zero_label, node.pos_label },
            );
        },
        .pause => |pause_stmt| {
            if (pause_stmt.value != null) {
                try writer.print(";   stmt label={s} pause value\n", .{label_text});
            } else {
                try writer.print(";   stmt label={s} pause\n", .{label_text});
            }
        },
        .stop => {
            try writer.print(";   stmt label={s} stop\n", .{label_text});
        },
        .goto => |gt| {
            try writer.print(";   stmt label={s} goto {s}\n", .{ label_text, gt.label });
        },
        .computed_goto => |gt| {
            try writer.print(";   stmt label={s} computed-goto labels({d})\n", .{ label_text, gt.labels.len });
        },
        .assigned_goto => |gt| {
            try writer.print(";   stmt label={s} assigned-goto var={s} labels({d})\n", .{ label_text, gt.var_name, gt.labels.len });
        },
        .do_loop => |loop| {
            const step_text = if (loop.step) |_| "yes" else "no";
            try writer.print(";   stmt label={s} do end={s} var={s} step={s}\n", .{ label_text, loop.end_label, loop.var_name, step_text });
        },
        .do_while => |loop| {
            try writer.print(";   stmt label={s} do-while end={s}\n", .{ label_text, loop.end_label });
        },
        .do_infinite => |loop| {
            try writer.print(";   stmt label={s} do-infinite end={s}\n", .{ label_text, loop.end_label });
        },
        .ret => |ret| {
            const mode = if (ret.value == null) "plain" else "value";
            try writer.print(";   stmt label={s} return {s}\n", .{ label_text, mode });
        },
        .cont => {
            try writer.print(";   stmt label={s} continue\n", .{label_text});
        },
        .entry => |entry| {
            try writer.print(";   stmt label={s} entry {s}({d})\n", .{ label_text, entry.name, entry.args.len });
        },
        .if_single => |ifs| {
            try writer.print(";   stmt label={s} if-single\n", .{label_text});
            try printIfSingleDetails(writer, ifs, 2);
        },
        .if_block => |ifb| {
            try writer.print(";   stmt label={s} if-block then({d}) else({d})\n", .{ label_text, ifb.then_stmts.len, ifb.else_stmts.len });
        },
        .where_stmt => |where| {
            try writer.print(";   stmt label={s} where\n", .{label_text});
            try printIndent(writer, 2);
            try writer.writeAll("mask:\n");
            try printExpr(writer, where.mask, 3);
            try printIndent(writer, 2);
            try writer.writeAll("target:\n");
            try printExpr(writer, where.target, 3);
            try printIndent(writer, 2);
            try writer.writeAll("value:\n");
            try printExpr(writer, where.value, 3);
        },
    }
}

fn printFormatSpec(writer: anytype, spec: ast.FormatSpec, depth: usize) !void {
    switch (spec) {
        .none => {
            try printIndent(writer, depth);
            try writer.writeAll("format: none\n");
        },
        .list_directed => {
            try printIndent(writer, depth);
            try writer.writeAll("format: *\n");
        },
        .label => |label| {
            try printIndent(writer, depth);
            try writer.print("format: label {s}\n", .{label});
        },
        .inline_items => |items| {
            try printIndent(writer, depth);
            try writer.print("format: inline items({d})\n", .{items.len});
            try printFormatItems(writer, items, depth + 1);
        },
        .expr => |expr_node| {
            try printIndent(writer, depth);
            try writer.writeAll("format: expr\n");
            try printExpr(writer, expr_node, depth + 1);
        },
    }
}

fn printFormatItems(writer: anytype, items: []const ast.FormatItem, depth: usize) !void {
    for (items, 0..) |item, idx| {
        try printIndent(writer, depth);
        try writer.print("item[{d}]:\n", .{idx});
        try printFormatItem(writer, item, depth + 1);
    }
}

fn printFormatItem(writer: anytype, item: ast.FormatItem, depth: usize) !void {
    switch (item) {
        .literal => |text| {
            try printIndent(writer, depth);
            try writer.print("fmt literal `{s}`\n", .{text});
        },
        .spaces => |count| {
            try printIndent(writer, depth);
            try writer.print("fmt spaces {d}\n", .{count});
        },
        .tab => |tab| {
            try printIndent(writer, depth);
            try writer.print("fmt tab {s} {d}\n", .{ tabControlName(tab.kind), tab.count });
        },
        .repeat_group => |group| {
            try printIndent(writer, depth);
            try writer.print("fmt repeat-group count={d} items({d})\n", .{ group.count, group.items.len });
            try printFormatItems(writer, group.items, depth + 1);
        },
        .int => |int_fmt| {
            try printIndent(writer, depth);
            try writer.print("fmt int w={d} m={d}\n", .{ int_fmt.width, int_fmt.min_digits });
        },
        .real => |real_fmt| {
            try printIndent(writer, depth);
            try writer.print(
                "fmt real kind={s} w={d} p={d} e={d}\n",
                .{ realFormatKindName(real_fmt.kind), real_fmt.width, real_fmt.precision, real_fmt.exp_width },
            );
        },
        .real_fixed => |real_fmt| {
            try printIndent(writer, depth);
            try writer.print(
                "fmt real-fixed kind={s} w={d} p={d} e={d}\n",
                .{ realFormatKindName(real_fmt.kind), real_fmt.width, real_fmt.precision, real_fmt.exp_width },
            );
        },
        .char => |char_fmt| {
            try printIndent(writer, depth);
            try writer.print("fmt char w={d}\n", .{char_fmt.width});
        },
        .logical => |logical_fmt| {
            try printIndent(writer, depth);
            try writer.print("fmt logical w={d}\n", .{logical_fmt.width});
        },
        .colon => {
            try printIndent(writer, depth);
            try writer.writeAll("fmt colon\n");
        },
        .scale => |scale| {
            try printIndent(writer, depth);
            try writer.print("fmt scale {d}\n", .{scale});
        },
        .blank_control => |blank| {
            try printIndent(writer, depth);
            try writer.print("fmt blank-control {s}\n", .{blankControlName(blank)});
        },
        .sign_control => |sign| {
            try printIndent(writer, depth);
            try writer.print("fmt sign-control {s}\n", .{signControlName(sign)});
        },
        .reversion_offset => |offset| {
            try printIndent(writer, depth);
            try writer.print("fmt reversion-offset {d}\n", .{offset});
        },
        .reversion_anchor => {
            try printIndent(writer, depth);
            try writer.writeAll("fmt reversion-anchor\n");
        },
    }
}

fn printInlineStmtNode(writer: anytype, node: ast.StmtNode, depth: usize) !void {
    switch (node) {
        .assignment => |assign| {
            try printIndent(writer, depth);
            try writer.writeAll("stmt assignment\n");
            try printAssignmentDetails(writer, assign, depth + 1);
        },
        .pointer_assignment => |assign| {
            try printIndent(writer, depth);
            try writer.writeAll("stmt pointer-assignment\n");
            try printPointerAssignmentDetails(writer, assign, depth + 1);
        },
        .nullify => |nullify| {
            try printIndent(writer, depth);
            try writer.print("stmt nullify items({d})\n", .{nullify.items.len});
        },
        .associate_block => |associate| {
            try printIndent(writer, depth);
            try writer.print("stmt associate bindings({d}) stmts({d})\n", .{ associate.bindings.len, associate.stmts.len });
        },
        .call => |call| {
            try printIndent(writer, depth);
            try writer.print("stmt call {s}({d})\n", .{ call.name, call.args.len });
        },
        .goto => |gt| {
            try printIndent(writer, depth);
            try writer.print("stmt goto {s}\n", .{gt.label});
        },
        .ret => |ret| {
            try printIndent(writer, depth);
            if (ret.value) |value| {
                try writer.writeAll("stmt return value\n");
                try printExpr(writer, value, depth + 1);
            } else {
                try writer.writeAll("stmt return\n");
            }
        },
        .if_single => |ifs| {
            try printIndent(writer, depth);
            try writer.writeAll("stmt if-single\n");
            try printIfSingleDetails(writer, ifs, depth + 1);
        },
        else => {
            try printIndent(writer, depth);
            try writer.print("stmt {s}\n", .{stmtNodeName(node)});
        },
    }
}

fn printAssignmentDetails(writer: anytype, assign: ast.Assignment, depth: usize) !void {
    try printIndent(writer, depth);
    try writer.writeAll("target:\n");
    try printExpr(writer, assign.target, depth + 1);
    try printIndent(writer, depth);
    try writer.writeAll("value:\n");
    try printExpr(writer, assign.value, depth + 1);
}

fn printPointerAssignmentDetails(writer: anytype, assign: ast.PointerAssignment, depth: usize) !void {
    try printIndent(writer, depth);
    try writer.writeAll("target:\n");
    try printExpr(writer, assign.target, depth + 1);
    try printIndent(writer, depth);
    try writer.writeAll("value:\n");
    try printExpr(writer, assign.value, depth + 1);
}

fn printIfSingleDetails(writer: anytype, ifs: ast.IfSingle, depth: usize) !void {
    try printIndent(writer, depth);
    try writer.writeAll("condition:\n");
    try printExpr(writer, ifs.condition, depth + 1);
    try printIndent(writer, depth);
    try writer.writeAll("then-stmt:\n");
    try printInlineStmtNode(writer, ifs.stmt.*, depth + 1);
}

fn printIoDetails(
    writer: anytype,
    unit: *ast.Expr,
    format: ast.FormatSpec,
    rec: ?*ast.Expr,
    args: []*ast.Expr,
    err_label: ?[]const u8,
    end_label: ?[]const u8,
    iostat: ?*ast.Expr,
    depth: usize,
) !void {
    try printIndent(writer, depth);
    try writer.writeAll("unit:\n");
    try printExpr(writer, unit, depth + 1);
    try printFormatSpec(writer, format, depth);
    if (rec) |rec_expr| {
        try printIndent(writer, depth);
        try writer.writeAll("rec:\n");
        try printExpr(writer, rec_expr, depth + 1);
    }
    if (err_label) |label| {
        try printIndent(writer, depth);
        try writer.print("err-label: {s}\n", .{label});
    }
    if (end_label) |label| {
        try printIndent(writer, depth);
        try writer.print("end-label: {s}\n", .{label});
    }
    if (iostat) |io_expr| {
        try printIndent(writer, depth);
        try writer.writeAll("iostat:\n");
        try printExpr(writer, io_expr, depth + 1);
    }
    for (args, 0..) |arg, idx| {
        try printIndent(writer, depth);
        try writer.print("arg[{d}]:\n", .{idx});
        try printExpr(writer, arg, depth + 1);
    }
}

fn printExpr(writer: anytype, expr: *ast.Expr, depth: usize) !void {
    switch (expr.*) {
        .identifier => |name| {
            try printIndent(writer, depth);
            try writer.print("expr identifier {s}\n", .{name});
        },
        .literal => |lit| {
            try printIndent(writer, depth);
            try writer.print("expr literal {s} `{s}`\n", .{ literalKindName(lit.kind), lit.text });
        },
        .array_constructor => |ctor| {
            try printIndent(writer, depth);
            try writer.print("expr array-constructor typed={s} items({d})\n", .{ if (ctor.type_spec != null) "yes" else "no", ctor.items.len });
            for (ctor.items, 0..) |item, idx| {
                try printIndent(writer, depth + 1);
                try writer.print("item[{d}]:\n", .{idx});
                try printExpr(writer, item, depth + 2);
            }
        },
        .call_or_subscript => |call| {
            try printIndent(writer, depth);
            try writer.print("expr call-or-subscript {s} args({d})\n", .{ call.name, call.args.len });
            for (call.args, 0..) |arg, idx| {
                try printIndent(writer, depth + 1);
                try writer.print("arg[{d}]:\n", .{idx});
                try printExpr(writer, arg, depth + 2);
            }
        },
        .substring => |sub| {
            try printIndent(writer, depth);
            try writer.print("expr substring {s} args({d})\n", .{ sub.name, sub.args.len });
            for (sub.args, 0..) |arg, idx| {
                try printIndent(writer, depth + 1);
                try writer.print("arg[{d}]:\n", .{idx});
                try printExpr(writer, arg, depth + 2);
            }
            if (sub.start) |start| {
                try printIndent(writer, depth + 1);
                try writer.writeAll("start:\n");
                try printExpr(writer, start, depth + 2);
            }
            if (sub.end) |end| {
                try printIndent(writer, depth + 1);
                try writer.writeAll("end:\n");
                try printExpr(writer, end, depth + 2);
            }
        },
        .component => |comp| {
            try printIndent(writer, depth);
            try writer.print("expr component {s} args({d})\n", .{ comp.name, comp.args.len });
            try printIndent(writer, depth + 1);
            try writer.writeAll("base:\n");
            try printExpr(writer, comp.base, depth + 2);
            for (comp.args, 0..) |arg, idx| {
                try printIndent(writer, depth + 1);
                try writer.print("arg[{d}]:\n", .{idx});
                try printExpr(writer, arg, depth + 2);
            }
        },
        .dim_range => |range| {
            try printIndent(writer, depth);
            try writer.writeAll("expr dim-range\n");
            if (range.lower) |lower| {
                try printIndent(writer, depth + 1);
                try writer.writeAll("lower:\n");
                try printExpr(writer, lower, depth + 2);
            }
            try printIndent(writer, depth + 1);
            try writer.writeAll("upper:\n");
            try printExpr(writer, range.upper, depth + 2);
            if (range.stride) |stride| {
                try printIndent(writer, depth + 1);
                try writer.writeAll("stride:\n");
                try printExpr(writer, stride, depth + 2);
            }
        },
        .unary => |un| {
            try printIndent(writer, depth);
            try writer.print("expr unary {s}\n", .{unaryOpName(un.op)});
            try printExpr(writer, un.expr, depth + 1);
        },
        .binary => |bin| {
            try printIndent(writer, depth);
            try writer.print("expr binary {s}\n", .{binaryOpName(bin.op)});
            try printIndent(writer, depth + 1);
            try writer.writeAll("left:\n");
            try printExpr(writer, bin.left, depth + 2);
            try printIndent(writer, depth + 1);
            try writer.writeAll("right:\n");
            try printExpr(writer, bin.right, depth + 2);
        },
        .complex_literal => |complex| {
            try printIndent(writer, depth);
            try writer.writeAll("expr complex-literal\n");
            try printIndent(writer, depth + 1);
            try writer.writeAll("real:\n");
            try printExpr(writer, complex.real, depth + 2);
            try printIndent(writer, depth + 1);
            try writer.writeAll("imag:\n");
            try printExpr(writer, complex.imag, depth + 2);
        },
        .implied_do => |imp| {
            const step_text = if (imp.step != null) "yes" else "no";
            try printIndent(writer, depth);
            try writer.print("expr implied-do var={s} items({d}) step={s}\n", .{ imp.var_name, imp.items.len, step_text });
            try printIndent(writer, depth + 1);
            try writer.writeAll("start:\n");
            try printExpr(writer, imp.start, depth + 2);
            try printIndent(writer, depth + 1);
            try writer.writeAll("end:\n");
            try printExpr(writer, imp.end, depth + 2);
            if (imp.step) |step| {
                try printIndent(writer, depth + 1);
                try writer.writeAll("step:\n");
                try printExpr(writer, step, depth + 2);
            }
            for (imp.items, 0..) |item, idx| {
                try printIndent(writer, depth + 1);
                try writer.print("item[{d}]:\n", .{idx});
                try printExpr(writer, item, depth + 2);
            }
        },
    }
}

fn printIndent(writer: anytype, depth: usize) !void {
    try writer.writeAll("; ");
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }
}

fn stmtNodeName(node: ast.StmtNode) []const u8 {
    return switch (node) {
        .assignment => "assignment",
        .pointer_assignment => "pointer-assignment",
        .nullify => "nullify",
        .associate_block => "associate-block",
        .assign_label => "assign-label",
        .use_stmt => "use",
        .call => "call",
        .goto => "goto",
        .computed_goto => "computed-goto",
        .assigned_goto => "assigned-goto",
        .write => "write",
        .read => "read",
        .rewind => "rewind",
        .backspace => "backspace",
        .endfile => "endfile",
        .open => "open",
        .inquire => "inquire",
        .close => "close",
        .allocate => "allocate",
        .deallocate => "deallocate",
        .data => "data",
        .format => "format",
        .arith_if => "arith-if",
        .pause => "pause",
        .stop => "stop",
        .do_loop => "do-loop",
        .do_while => "do-while",
        .do_infinite => "do-infinite",
        .ret => "return",
        .cont => "continue",
        .entry => "entry",
        .if_single => "if-single",
        .if_block => "if-block",
        .where_stmt => "where",
    };
}

fn literalKindName(kind: ast.LiteralKind) []const u8 {
    return switch (kind) {
        .integer => "integer",
        .real => "real",
        .string => "string",
        .hollerith => "hollerith",
        .logical => "logical",
        .assumed_size => "assumed-size",
    };
}

fn unaryOpName(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .plus => "plus",
        .minus => "minus",
        .not => "not",
    };
}

fn binaryOpName(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .concat => "concat",
        .power => "power",
        .eq => "eq",
        .ne => "ne",
        .lt => "lt",
        .le => "le",
        .gt => "gt",
        .ge => "ge",
        .and_ => "and",
        .or_ => "or",
        .eqv => "eqv",
        .neqv => "neqv",
    };
}

fn tabControlName(kind: ast.TabControl) []const u8 {
    return switch (kind) {
        .absolute => "absolute",
        .relative_left => "relative-left",
        .relative_right => "relative-right",
    };
}

fn realFormatKindName(kind: ast.RealFormatKind) []const u8 {
    return switch (kind) {
        .e => "E",
        .d => "D",
        .g => "G",
    };
}

fn blankControlName(mode: ast.BlankControl) []const u8 {
    return switch (mode) {
        .nulls => "nulls",
        .zeros => "zeros",
    };
}

fn signControlName(mode: ast.SignControl) []const u8 {
    return switch (mode) {
        .default => "default",
        .plus => "plus",
        .suppress => "suppress",
    };
}

fn typeKindName(kind: ast.TypeKind) []const u8 {
    return switch (kind) {
        .integer => "INTEGER",
        .real => "REAL",
        .double_precision => "DOUBLE PRECISION",
        .complex => "COMPLEX",
        .complex_double => "COMPLEX*16",
        .logical => "LOGICAL",
        .character => "CHARACTER",
        .derived => "TYPE",
    };
}

test "printProgram prints open/read/write control details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unit_expr = try a.create(ast.Expr);
    unit_expr.* = .{ .literal = .{ .kind = .integer, .text = "10" } };

    const rec_expr = try a.create(ast.Expr);
    rec_expr.* = .{ .literal = .{ .kind = .integer, .text = "2" } };

    const value_expr = try a.create(ast.Expr);
    value_expr.* = .{ .identifier = "X" };

    const iostat_expr = try a.create(ast.Expr);
    iostat_expr.* = .{ .identifier = "IOS" };

    const file_expr = try a.create(ast.Expr);
    file_expr.* = .{ .literal = .{ .kind = .string, .text = "'out.dat'" } };

    const write_args = try a.alloc(*ast.Expr, 1);
    write_args[0] = value_expr;

    const read_args = try a.alloc(*ast.Expr, 1);
    read_args[0] = value_expr;

    const stmts = try a.alloc(ast.Stmt, 3);
    stmts[0] = .{
        .label = null,
        .node = .{
            .open = .{
                .unit = unit_expr,
                .recl = null,
                .file = file_expr,
                .access = null,
                .form = null,
                .blank = null,
                .status = null,
                .err_label = null,
                .iostat = null,
            },
        },
    };
    stmts[1] = .{
        .label = null,
        .node = .{
            .write = .{
                .unit = unit_expr,
                .format = .list_directed,
                .rec = rec_expr,
                .args = write_args,
                .err_label = "900",
                .iostat = iostat_expr,
            },
        },
    };
    stmts[2] = .{
        .label = null,
        .node = .{
            .read = .{
                .unit = unit_expr,
                .format = .list_directed,
                .rec = null,
                .args = read_args,
                .err_label = "901",
                .end_label = "902",
                .iostat = iostat_expr,
            },
        },
    };

    const units = try a.alloc(ast.ProgramUnit, 1);
    units[0] = .{
        .kind = .program,
        .name = "MAIN",
        .args = &.{},
        .decls = &.{},
        .stmts = stmts,
    };
    const program = ast.Program{ .units = units };

    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try printProgram(buf.writer(), program);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "stmt label=- open") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "err-label: 900") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "err-label: 901") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "end-label: 902") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "iostat:") != null);
}
