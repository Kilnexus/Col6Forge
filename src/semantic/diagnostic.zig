const std = @import("std");
const common_diag = @import("../common/diagnostic.zig");
const compat = @import("../common/compat_diagnostic_storage.zig");
const catalog = @import("../common/error_catalog.zig");
const owned_diag = @import("../common/owned_diagnostic_bag.zig");

pub const SemanticDiagnostic = struct {
    line: usize,
    column: usize,
    code: []const u8,
    message: []const u8,
    line_text: []const u8,
    severity: common_diag.DiagnosticSeverity = .@"error",
    primary_label: []const u8 = "",
    notes: []const common_diag.DiagnosticMessage = &.{},
    helps: []const common_diag.DiagnosticMessage = &.{},
    secondary_spans: []const common_diag.DiagnosticSpan = &.{},
};

pub const FallbackSource = owned_diag.FallbackSource;
pub const Bag = owned_diag.Bag(SemanticDiagnostic, .{
    .refine_code_fn = refineSemanticCode,
    .dedupe_latest = true,
    .normalize_secondary_spans = true,
});

const CompatStorage = struct {
    line: usize = 1,
    column: usize = 1,
    code: ?[]u8 = null,
    message: ?[]u8 = null,
    line_text: ?[]u8 = null,
    severity: common_diag.DiagnosticSeverity = .@"error",
    primary_label: ?[]u8 = null,
    notes: []common_diag.DiagnosticMessage = &.{},
    helps: []common_diag.DiagnosticMessage = &.{},
    secondary_spans: []common_diag.DiagnosticSpan = &.{},

    fn clear(self: *CompatStorage) void {
        if (self.code) |buf| compat.allocator.free(buf);
        if (self.message) |buf| compat.allocator.free(buf);
        if (self.line_text) |buf| compat.allocator.free(buf);
        if (self.primary_label) |buf| compat.allocator.free(buf);
        owned_diag.freeMessages(compat.allocator, self.notes);
        owned_diag.freeMessages(compat.allocator, self.helps);
        owned_diag.freeSpans(compat.allocator, self.secondary_spans);
        self.* = .{};
    }
};

fn makeCompatStorage(
    line: usize,
    column: usize,
    code: []const u8,
    message: []const u8,
    line_text: []const u8,
    severity: common_diag.DiagnosticSeverity,
    primary_label: []const u8,
    notes: []const common_diag.DiagnosticMessage,
    helps: []const common_diag.DiagnosticMessage,
    secondary_spans: []const common_diag.DiagnosticSpan,
) !CompatStorage {
    var next: CompatStorage = .{
        .line = if (line == 0) 1 else line,
        .column = if (column == 0) 1 else column,
        .severity = severity,
    };
    errdefer next.clear();
    next.code = try compat.allocator.dupe(u8, code);
    next.message = try compat.allocator.dupe(u8, message);
    next.line_text = try compat.allocator.dupe(u8, line_text);
    next.primary_label = try compat.allocator.dupe(u8, primary_label);
    next.notes = try owned_diag.dupeMessages(compat.allocator, notes);
    next.helps = try owned_diag.dupeMessages(compat.allocator, helps);
    next.secondary_spans = try owned_diag.dupeSpans(compat.allocator, secondary_spans, true);
    return next;
}

threadlocal var storage: CompatStorage = .{};
threadlocal var has_diag: bool = false;
threadlocal var fallback_storage: compat.Storage = .{};
threadlocal var has_fallback: bool = false;

pub fn clear() void {
    has_diag = false;
    has_fallback = false;
    storage.clear();
    fallback_storage.clear();
}

pub fn has() bool {
    return has_diag;
}

pub fn set(line: usize, column: usize, code: []const u8, message: []const u8, line_text: []const u8) void {
    setDetailed(line, column, code, message, line_text, &.{}, &.{});
}

pub fn setStructured(
    line: usize,
    column: usize,
    code: []const u8,
    message: []const u8,
    line_text: []const u8,
    primary_label: []const u8,
    notes: []const common_diag.DiagnosticMessage,
    helps: []const common_diag.DiagnosticMessage,
    secondary_spans: []const common_diag.DiagnosticSpan,
) void {
    setStructuredWithSeverity(line, column, code, message, line_text, .@"error", primary_label, notes, helps, secondary_spans);
}

pub fn setStructuredWithSeverity(
    line: usize,
    column: usize,
    code: []const u8,
    message: []const u8,
    line_text: []const u8,
    severity: common_diag.DiagnosticSeverity,
    primary_label: []const u8,
    notes: []const common_diag.DiagnosticMessage,
    helps: []const common_diag.DiagnosticMessage,
    secondary_spans: []const common_diag.DiagnosticSpan,
) void {
    const refined_code = refineSemanticCode(code, message, line_text);
    const next = makeCompatStorage(line, column, refined_code, message, line_text, severity, primary_label, notes, helps, secondary_spans) catch return;
    storage.clear();
    storage = next;
    has_diag = true;
}

pub fn setDetailed(
    line: usize,
    column: usize,
    code: []const u8,
    message: []const u8,
    line_text: []const u8,
    notes: []const common_diag.DiagnosticMessage,
    helps: []const common_diag.DiagnosticMessage,
) void {
    setDetailedWithSeverity(line, column, code, message, line_text, .@"error", notes, helps);
}

pub fn setDetailedWithSeverity(
    line: usize,
    column: usize,
    code: []const u8,
    message: []const u8,
    line_text: []const u8,
    severity: common_diag.DiagnosticSeverity,
    notes: []const common_diag.DiagnosticMessage,
    helps: []const common_diag.DiagnosticMessage,
) void {
    setStructuredWithSeverity(line, column, code, message, line_text, severity, "", notes, helps, &.{});
}

pub fn take() ?SemanticDiagnostic {
    if (!has_diag) return null;
    has_diag = false;
    return .{
        .line = storage.line,
        .column = storage.column,
        .code = storage.code orelse "",
        .message = storage.message orelse "",
        .line_text = storage.line_text orelse "",
        .severity = storage.severity,
        .primary_label = storage.primary_label orelse "",
        .notes = storage.notes,
        .helps = storage.helps,
        .secondary_spans = storage.secondary_spans,
    };
}

pub fn releaseTaken(_: SemanticDiagnostic) void {
    storage.clear();
}

pub fn noteFallbackSource(line: usize, column: usize, line_text: []const u8) void {
    const next = compat.makeFallbackStorage(line, column, line_text) catch return;
    fallback_storage.clear();
    fallback_storage = next;
    has_fallback = true;
}

pub fn fallbackSource() ?FallbackSource {
    if (!has_fallback) return null;
    return .{
        .line = fallback_storage.line,
        .column = fallback_storage.column,
        .line_text = fallback_storage.line_text orelse "",
    };
}

fn refineSemanticCode(code: []const u8, message: []const u8, line_text: []const u8) []const u8 {
    if (std.mem.eql(u8, code, catalog.semantic.invalid_argument_count.code)) {
        return refineInvalidArgumentCode(message);
    }
    if (std.mem.eql(u8, code, catalog.semantic.invalid_subscript.code)) {
        return refineInvalidSubscriptCode(message, line_text);
    }
    if (std.mem.eql(u8, code, catalog.semantic.assignment_type_mismatch.code)) {
        return refineAssignmentMismatchCode(message, line_text);
    }
    if (std.mem.eql(u8, code, catalog.semantic.parameter_not_constant.code)) {
        return refineParameterNotConstantCode(message, line_text);
    }
    return code;
}

fn refineInvalidArgumentCode(message: []const u8) []const u8 {
    if (std.mem.indexOf(u8, message, "too few elements for dummy argument") != null) return catalog.semantic.invalid_actual_element_count.code;
    if (std.mem.indexOf(u8, message, "Missing actual argument") != null) return catalog.semantic.missing_actual_argument.code;
    if (std.mem.indexOf(u8, message, "wrong number of arguments") != null or
        std.mem.indexOf(u8, message, "too many") != null or
        std.mem.indexOf(u8, message, "too few") != null)
    {
        return catalog.semantic.invalid_argument_arity.code;
    }
    if (std.mem.indexOf(u8, message, "Rank mismatch in argument") != null) return catalog.semantic.invalid_argument_rank.code;
    if (std.mem.indexOf(u8, message, "Type mismatch in function result") != null) return catalog.semantic.invalid_function_result_type.code;
    if (std.mem.indexOf(u8, message, "Rank mismatch in function result") != null) return catalog.semantic.invalid_function_result_rank.code;
    if (std.mem.indexOf(u8, message, "Shape mismatch in function result") != null) return catalog.semantic.function_result_shape_mismatch.code;
    if (std.mem.indexOf(u8, message, "PROCEDURE POINTER mismatch in function result") != null) return catalog.semantic.function_result_procedure_pointer_mismatch.code;
    if (std.mem.indexOf(u8, message, "POINTER attribute mismatch in function result") != null) return catalog.semantic.function_result_pointer_attr_mismatch.code;
    if (std.mem.indexOf(u8, message, "ALLOCATABLE attribute mismatch in function result") != null) return catalog.semantic.function_result_allocatable_attr_mismatch.code;
    if (std.mem.indexOf(u8, message, "CONTIGUOUS attribute mismatch in function result") != null) return catalog.semantic.function_result_contiguous_attr_mismatch.code;
    if (std.mem.indexOf(u8, message, "function result") != null and
        (std.mem.indexOf(u8, message, "Character length mismatch") != null or
            std.mem.indexOf(u8, message, "Shape mismatch") != null or
            std.mem.indexOf(u8, message, "POINTER attribute mismatch") != null or
            std.mem.indexOf(u8, message, "ALLOCATABLE attribute mismatch") != null or
            std.mem.indexOf(u8, message, "CONTIGUOUS attribute mismatch") != null or
            std.mem.indexOf(u8, message, "PROCEDURE POINTER mismatch") != null))
    {
        return catalog.semantic.invalid_function_result_characteristic.code;
    }
    if (std.mem.indexOf(u8, message, "actual argument is not a function") != null or
        std.mem.indexOf(u8, message, "should be a FUNCTION") != null)
    {
        return catalog.semantic.actual_argument_not_function.code;
    }
    if (std.mem.indexOf(u8, message, "actual argument is not a subroutine") != null or
        std.mem.indexOf(u8, message, "should be a SUBROUTINE") != null)
    {
        return catalog.semantic.actual_argument_not_subroutine.code;
    }
    if (std.mem.indexOf(u8, message, "Passing global function") != null) return catalog.semantic.passing_global_function.code;
    if (std.mem.indexOf(u8, message, "Passing global subroutine") != null) return catalog.semantic.passing_global_subroutine.code;
    if (std.mem.indexOf(u8, message, "actual argument is not a") != null or
        std.mem.indexOf(u8, message, "wrong procedure kind") != null or
        std.mem.indexOf(u8, message, "Passing global") != null)
    {
        return catalog.semantic.invalid_argument_procedure_kind.code;
    }
    if (std.mem.indexOf(u8, message, "no specific function") != null or
        std.mem.indexOf(u8, message, "no specific subroutine") != null)
    {
        return catalog.semantic.no_specific_procedure_match.code;
    }
    if (std.mem.indexOf(u8, message, "Return type mismatch of function") != null or
        std.mem.indexOf(u8, message, "Return type mismatch") != null)
    {
        return catalog.semantic.function_reference_return_mismatch.code;
    }
    if (std.mem.indexOf(u8, message, "Interface mismatch in procedure pointer assignment") != null) return catalog.semantic.procedure_pointer_assignment_interface_mismatch.code;
    if (std.mem.indexOf(u8, message, "Interface mismatch in dummy procedure") != null) return catalog.semantic.invalid_dummy_procedure_interface_explicit.code;
    if (std.mem.indexOf(u8, message, "OPTIONAL mismatch") != null) return catalog.semantic.invalid_dummy_optional.code;
    if (std.mem.indexOf(u8, message, "INTENT mismatch") != null) return catalog.semantic.invalid_dummy_intent.code;
    if (std.mem.indexOf(u8, message, "ASYNCHRONOUS mismatch") != null) return catalog.semantic.invalid_dummy_asynchronous.code;
    if (std.mem.indexOf(u8, message, "CONTIGUOUS mismatch") != null) return catalog.semantic.invalid_dummy_contiguous.code;
    if (std.mem.indexOf(u8, message, "VALUE mismatch") != null) return catalog.semantic.invalid_dummy_value.code;
    if (std.mem.indexOf(u8, message, "VOLATILE mismatch") != null) return catalog.semantic.invalid_dummy_volatile.code;
    if (std.mem.indexOf(u8, message, "Shape mismatch in dimension") != null) return catalog.semantic.invalid_dummy_shape_signature.code;
    if (std.mem.indexOf(u8, message, "keyword") != null) return catalog.semantic.invalid_intrinsic_keyword_argument.code;
    if (std.mem.indexOf(u8, message, "Character length mismatch") != null) return catalog.semantic.invalid_argument_char_len.code;
    if (std.mem.indexOf(u8, message, "Descriptor mismatch in argument") != null) return catalog.semantic.invalid_argument_descriptor.code;
    if (std.mem.indexOf(u8, message, "POINTER attribute mismatch in argument") != null) return catalog.semantic.invalid_argument_pointer_attr.code;
    if (std.mem.indexOf(u8, message, "ALLOCATABLE attribute mismatch in argument") != null) return catalog.semantic.invalid_argument_allocatable_attr.code;
    if (std.mem.indexOf(u8, message, "Polymorphic mismatch in argument") != null) return catalog.semantic.invalid_argument_polymorphic.code;
    if (std.mem.indexOf(u8, message, "Derived type mismatch in argument") != null) return catalog.semantic.invalid_argument_derived_type.code;
    if (std.mem.indexOf(u8, message, "Type mismatch in argument") != null) return catalog.semantic.invalid_argument_type.code;
    if (std.mem.startsWith(u8, message, "passed ") and std.mem.indexOf(u8, message, " to ") != null) {
        return catalog.semantic.invalid_argument_type.code;
    }
    return codeForFallback(catalog.semantic.invalid_argument_count.code);
}

fn refineInvalidSubscriptCode(message: []const u8, line_text: []const u8) []const u8 {
    if (std.mem.eql(u8, message, catalog.semantic.invalid_subscript.message)) {
        if (containsOneOf(line_text, &.{ "ALLOCATE", "allocate", "DEALLOCATE", "deallocate" })) return catalog.semantic.invalid_allocate_designator_subscript.code;
        if (containsOneOf(line_text, &.{ "ASSOCIATE", "associate" })) return catalog.semantic.invalid_associate_selector_subscript.code;
        if (std.mem.indexOf(u8, line_text, "=>") != null) return catalog.semantic.invalid_pointer_designator_subscript.code;
        if (containsOneOf(line_text, &.{ "DATA ", "data " })) return catalog.semantic.invalid_data_stmt_reference.code;
        if (std.mem.indexOf(u8, line_text, "%") != null) return catalog.semantic.invalid_component_data_reference.code;
        if (containsFunctionLikeDesignator(line_text)) return catalog.semantic.invalid_function_like_data_reference.code;
        return catalog.semantic.invalid_data_reference_subscript.code;
    }
    if (std.mem.indexOf(u8, message, "count") != null) return catalog.semantic.invalid_subscript_count.code;
    if (std.mem.indexOf(u8, message, "integer") != null or std.mem.indexOf(u8, message, "INTEGER") != null) return catalog.semantic.invalid_subscript_type.code;
    if (std.mem.indexOf(u8, message, "triplet") != null or std.mem.indexOf(u8, message, "section") != null) return catalog.semantic.invalid_subscript_section.code;
    if (std.mem.indexOf(u8, message, "FUNCTION") != null or
        std.mem.indexOf(u8, message, "function") != null or
        std.mem.indexOf(u8, message, "impure function") != null)
    {
        return catalog.semantic.ambiguous_subscript_or_component_call.code;
    }
    if (std.mem.indexOf(u8, message, "not a member of the") != null or
        std.mem.indexOf(u8, message, "component or binding") != null)
    {
        return catalog.semantic.invalid_component_reference.code;
    }
    if (std.mem.indexOf(u8, message, "subscriptable") != null) return catalog.semantic.invalid_subscript_target.code;
    return codeForFallback(catalog.semantic.invalid_subscript.code);
}

fn refineAssignmentMismatchCode(message: []const u8, line_text: []const u8) []const u8 {
    if (std.mem.eql(u8, message, catalog.semantic.assignment_type_mismatch.message)) {
        if (std.mem.indexOf(u8, line_text, "=>") != null) return catalog.semantic.assignment_pointer_designator_mismatch.code;
        if (containsOneOf(line_text, &.{ "c_loc(", "C_LOC(", "c_funloc(", "C_FUNLOC(", "c_null_ptr", "C_NULL_PTR", "c_null_funptr", "C_NULL_FUNPTR" })) {
            return catalog.semantic.assignment_c_interop_pointer_mismatch.code;
        }
        if (containsOneOf(line_text, &.{ "repeat(", "REPEAT(" })) return catalog.semantic.assignment_repeat_result_mismatch.code;
        if (containsOneOf(line_text, &.{ "pack(", "PACK(", "eoshift(", "EOSHIFT(", "cshift(", "CSHIFT(", "matmul(", "MATMUL(", "transfer(", "TRANSFER(", "char(", "CHAR(" })) {
            return catalog.semantic.assignment_intrinsic_result_mismatch.code;
        }
        return codeForFallback(catalog.semantic.assignment_type_mismatch.code);
    }
    if (std.mem.indexOf(u8, message, "must be ALLOCATABLE or a POINTER") != null) return catalog.semantic.assignment_requires_allocatable_or_pointer.code;
    if (std.mem.indexOf(u8, message, "Non-POINTER in pointer association context") != null) return catalog.semantic.pointer_assignment_requires_pointer.code;
    if (std.mem.indexOf(u8, message, "Selector shall be polymorphic") != null) return catalog.semantic.select_type_requires_polymorphic.code;
    if (std.mem.indexOf(u8, message, "variable definition context") != null) return catalog.semantic.invalid_variable_definition_context.code;
    if (std.mem.indexOf(u8, message, "DO variable must be a scalar INTEGER") != null) return catalog.semantic.do_variable_requires_scalar_integer.code;
    if (std.mem.indexOf(u8, message, "must be a POINTER") != null) return catalog.semantic.assignment_requires_pointer.code;
    if (std.mem.indexOf(u8, message, "must be double precision") != null) return catalog.semantic.double_precision_required.code;
    if (std.mem.indexOf(u8, message, "error in CLASS IS specification") != null) return catalog.semantic.invalid_class_is_specification.code;
    if (std.mem.indexOf(u8, message, "must be ALLOCATABLE") != null) return catalog.semantic.assignment_requires_allocatable.code;
    return codeForFallback(catalog.semantic.assignment_type_mismatch.code);
}

fn refineParameterNotConstantCode(message: []const u8, line_text: []const u8) []const u8 {
    if (!isParameterNotConstantMessage(message)) return codeForFallback(catalog.semantic.parameter_not_constant.code);

    if (containsOneOf(line_text, &.{ "= c_", "=C_", "= omp_", "=OMP_" })) return catalog.semantic.parameter_named_constant_not_folded.code;
    if (containsOneOf(line_text, &.{ "lbound(", "LBOUND(", "ubound(", "UBOUND(", "shape(", "SHAPE(", "size(", "SIZE(" })) {
        return catalog.semantic.parameter_array_inquiry_not_folded.code;
    }
    if (containsOneOf(line_text, &.{ "reshape", "RESHAPE", "(/", "[/" })) return catalog.semantic.parameter_array_constructor_not_folded.code;
    if ((containsOneOf(line_text, &.{ "real(", "REAL(", "int(", "INT(", "cmplx(", "CMPLX(", "dble(", "DBLE(" })) and
        containsOneOf(line_text, &.{ "z'", "Z'", "b'", "B'", "o'", "O'" }))
    {
        return catalog.semantic.parameter_conversion_not_folded.code;
    }
    if (containsOneOf(line_text, &.{ "kind(", "KIND(", "bes", "BES", "trailz(", "TRAILZ(", "leadz(", "LEADZ(", "popcnt(", "POPCNT(", "poppar(", "POPPAR(" })) {
        return catalog.semantic.parameter_intrinsic_not_folded.code;
    }
    return codeForFallback(catalog.semantic.parameter_not_constant.code);
}

fn isParameterNotConstantMessage(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "PARAMETER '") and
        std.mem.endsWith(u8, message, "' value is not a constant expression");
}

fn containsOneOf(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn containsFunctionLikeDesignator(line_text: []const u8) bool {
    const open = std.mem.indexOfScalar(u8, line_text, '(') orelse return false;
    if (open == 0) return false;
    const prefix = std.mem.trimEnd(u8, line_text[0..open], " \t");
    if (prefix.len == 0) return false;
    const last = prefix[prefix.len - 1];
    return std.ascii.isAlphabetic(last) or std.ascii.isDigit(last) or last == '_' or last == '%';
}

fn codeForFallback(code: []const u8) []const u8 {
    return code;
}

test "semantic diagnostic refines invalid argument rank mismatch" {
    const testing = std.testing;

    clear();
    setDetailed(12, 5, catalog.semantic.invalid_argument_count.code, "Rank mismatch in argument", "      call s(a)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_argument_rank.code, diag.code);
}

test "semantic diagnostic refines actual element count mismatch" {
    const testing = std.testing;

    clear();
    setDetailed(13, 5, catalog.semantic.invalid_argument_count.code, "Actual argument contains too few elements for dummy argument 'x'", "      call s(a)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_actual_element_count.code, diag.code);
}

test "semantic diagnostic keeps fallback code for generic invalid argument count" {
    const testing = std.testing;

    clear();
    set(8, 3, catalog.semantic.invalid_argument_count.code, catalog.semantic.invalid_argument_count.message, "      call s()");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_argument_count.code, diag.code);
}

test "semantic diagnostic refines character length mismatch in argument" {
    const testing = std.testing;

    clear();
    setDetailed(9, 3, catalog.semantic.invalid_argument_count.code, "Character length mismatch", "      call s(str)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_argument_char_len.code, diag.code);
}

test "semantic diagnostic refines dummy procedure optional mismatch" {
    const testing = std.testing;

    clear();
    setDetailed(10, 3, catalog.semantic.invalid_argument_count.code, "OPTIONAL mismatch in argument", "      call s(proc)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_dummy_optional.code, diag.code);
}

test "semantic diagnostic refines descriptor mismatch in argument" {
    const testing = std.testing;

    clear();
    setDetailed(11, 3, catalog.semantic.invalid_argument_count.code, "Descriptor mismatch in argument", "      call s(arr)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_argument_descriptor.code, diag.code);
}

test "semantic diagnostic refines no specific procedure match" {
    const testing = std.testing;

    clear();
    setDetailed(12, 3, catalog.semantic.invalid_argument_count.code, "no specific function", "      x = foo(a)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.no_specific_procedure_match.code, diag.code);
}

test "semantic diagnostic refines invalid component reference" {
    const testing = std.testing;

    clear();
    setDetailed(13, 3, catalog.semantic.invalid_subscript.code, "'x' is not a member of the 't' structure", "      obj%x = 1", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_component_reference.code, diag.code);
}

test "semantic diagnostic keeps fallback code for generic invalid subscript" {
    const testing = std.testing;

    clear();
    set(14, 3, catalog.semantic.invalid_subscript.code, catalog.semantic.invalid_subscript.message, "      call x(1)");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_data_reference_subscript.code, diag.code);
}

test "semantic diagnostic refines missing actual argument" {
    const testing = std.testing;

    clear();
    setDetailed(14, 3, catalog.semantic.invalid_argument_count.code, "Missing actual argument", "      call s()", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.missing_actual_argument.code, diag.code);
}

test "semantic diagnostic refines actual argument not function" {
    const testing = std.testing;

    clear();
    setDetailed(15, 3, catalog.semantic.invalid_argument_count.code, "actual argument is not a function", "      call s(x)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.actual_argument_not_function.code, diag.code);
}

test "semantic diagnostic refines function result shape mismatch" {
    const testing = std.testing;

    clear();
    setDetailed(16, 3, catalog.semantic.invalid_argument_count.code, "Shape mismatch in function result", "      call s(f)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.function_result_shape_mismatch.code, diag.code);
}

test "semantic diagnostic refines pointer association requirement" {
    const testing = std.testing;

    clear();
    setDetailed(17, 3, catalog.semantic.assignment_type_mismatch.code, "must be ALLOCATABLE or a POINTER", "      p => x", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.assignment_requires_allocatable_or_pointer.code, diag.code);
}

test "semantic diagnostic refines selector polymorphic requirement" {
    const testing = std.testing;

    clear();
    setDetailed(18, 3, catalog.semantic.assignment_type_mismatch.code, "Selector shall be polymorphic", "      select type (x)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.select_type_requires_polymorphic.code, diag.code);
}

test "semantic diagnostic keeps fallback code for generic assignment mismatch" {
    const testing = std.testing;

    clear();
    set(19, 3, catalog.semantic.assignment_type_mismatch.code, catalog.semantic.assignment_type_mismatch.message, "      x = y");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.assignment_type_mismatch.code, diag.code);
}

test "semantic diagnostic refines allocate designator subscript" {
    const testing = std.testing;

    clear();
    set(20, 3, catalog.semantic.invalid_subscript.code, catalog.semantic.invalid_subscript.message, "      allocate(a(i))");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_allocate_designator_subscript.code, diag.code);
}

test "semantic diagnostic refines associate selector subscript" {
    const testing = std.testing;

    clear();
    set(21, 3, catalog.semantic.invalid_subscript.code, catalog.semantic.invalid_subscript.message, "      associate(x => obj%state(i))");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_associate_selector_subscript.code, diag.code);
}

test "semantic diagnostic refines pointer designator subscript" {
    const testing = std.testing;

    clear();
    set(22, 3, catalog.semantic.invalid_subscript.code, catalog.semantic.invalid_subscript.message, "      p => a(i)");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_pointer_designator_subscript.code, diag.code);
}

test "semantic diagnostic refines named constant parameter folding" {
    const testing = std.testing;

    clear();
    set(23, 3, catalog.semantic.parameter_not_constant.code, "PARAMETER 'it' value is not a constant expression", "integer, parameter :: it = c_int");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.parameter_named_constant_not_folded.code, diag.code);
}

test "semantic diagnostic refines array inquiry parameter folding" {
    const testing = std.testing;

    clear();
    set(24, 3, catalog.semantic.parameter_not_constant.code, "PARAMETER 'i' value is not a constant expression", "integer, parameter :: i = lbound(arr,1)");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.parameter_array_inquiry_not_folded.code, diag.code);
}

test "semantic diagnostic refines array constructor parameter folding" {
    const testing = std.testing;

    clear();
    set(25, 3, catalog.semantic.parameter_not_constant.code, "PARAMETER 'a' value is not a constant expression", "real, parameter :: a = reshape((/(i, i = 1, 9)/), (/3, 3/))");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.parameter_array_constructor_not_folded.code, diag.code);
}

test "semantic diagnostic refines conversion parameter folding" {
    const testing = std.testing;

    clear();
    set(26, 3, catalog.semantic.parameter_not_constant.code, "PARAMETER 'inf' value is not a constant expression", "real, parameter :: inf = real(z'7F800000')");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.parameter_conversion_not_folded.code, diag.code);
}

test "semantic diagnostic refines intrinsic parameter folding" {
    const testing = std.testing;

    clear();
    set(27, 3, catalog.semantic.parameter_not_constant.code, "PARAMETER 'k2' value is not a constant expression", "integer, parameter :: k2 = kind(BESJ0(Qarg1))");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.parameter_intrinsic_not_folded.code, diag.code);
}

test "semantic diagnostic refines generic data statement subscript" {
    const testing = std.testing;

    clear();
    set(28, 3, catalog.semantic.invalid_subscript.code, catalog.semantic.invalid_subscript.message, "      data (hm(md)%re, md=1,2)/1.0, 2.0/");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_data_stmt_reference.code, diag.code);
}

test "semantic diagnostic refines generic component data reference" {
    const testing = std.testing;

    clear();
    set(29, 3, catalog.semantic.invalid_subscript.code, catalog.semantic.invalid_subscript.message, "      foo%bar = 1");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_component_data_reference.code, diag.code);
}

test "semantic diagnostic refines generic function-like data reference" {
    const testing = std.testing;

    clear();
    set(30, 3, catalog.semantic.invalid_subscript.code, catalog.semantic.invalid_subscript.message, "      x = d1mach(4)");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_function_like_data_reference.code, diag.code);
}

test "semantic diagnostic refines generic pointer assignment mismatch" {
    const testing = std.testing;

    clear();
    set(31, 3, catalog.semantic.assignment_type_mismatch.code, catalog.semantic.assignment_type_mismatch.message, "      p => x(:)");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.assignment_pointer_designator_mismatch.code, diag.code);
}

test "semantic diagnostic refines generic C interop assignment mismatch" {
    const testing = std.testing;

    clear();
    set(32, 3, catalog.semantic.assignment_type_mismatch.code, catalog.semantic.assignment_type_mismatch.message, "      file%gsl_file = c_loc(tgt)");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.assignment_c_interop_pointer_mismatch.code, diag.code);
}

test "semantic diagnostic refines generic repeat assignment mismatch" {
    const testing = std.testing;

    clear();
    set(33, 3, catalog.semantic.assignment_type_mismatch.code, catalog.semantic.assignment_type_mismatch.message, "      c = repeat('X', i08)");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.assignment_repeat_result_mismatch.code, diag.code);
}

test "semantic diagnostic refines generic intrinsic assignment mismatch" {
    const testing = std.testing;

    clear();
    set(34, 3, catalog.semantic.assignment_type_mismatch.code, catalog.semantic.assignment_type_mismatch.message, "      z = matmul(x, x)");
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.assignment_intrinsic_result_mismatch.code, diag.code);
}

test "semantic diagnostic refines passed actual/formal type mismatch text" {
    const testing = std.testing;

    clear();
    setDetailed(35, 3, catalog.semantic.invalid_argument_count.code, "passed REAL(4) to INTEGER(32)", "      call s(1.0)", &.{}, &.{});
    const diag = take() orelse return error.TestExpectedEqual;
    defer releaseTaken(diag);

    try testing.expectEqualStrings(catalog.semantic.invalid_argument_type.code, diag.code);
}
