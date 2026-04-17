const common = @import("common.zig");
const std = common.std;
const diag = common.diag;
const catalog = common.catalog;
const pipeline = common.pipeline;
const runPipelineWithOptions = common.runPipelineWithOptions;
const runPipelineWithOptionsAndDiagnostics = common.runPipelineWithOptionsAndDiagnostics;
const runPipelineToWriterWithOptionsAndDiagnostics = common.runPipelineToWriterWithOptionsAndDiagnostics;
const PipelineDiagCapture = common.PipelineDiagCapture;
const writeTempSourceFile = common.writeTempSourceFile;
test "runPipeline reports continuation-related secondary span for missing identifier" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "      PROGRAM P\n" ++
        "      INTEGER A,\n" ++
        "     1 )\n" ++
        "      END\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "continued_missing_name.f", source);
    defer allocator.free(file_path);

    var diag_capture = PipelineDiagCapture.init(allocator);
    defer diag_capture.deinit();
    const diag_info = try diag_capture.expectError(allocator, file_path, .llvm, .{}, error.MissingName);
    defer diag_capture.release(diag_info);
    try testing.expectEqualStrings(catalog.parser.missing_name.code, diag_info.code);
    try testing.expectEqualStrings("identifier required here", diag_info.primary_label);
    try testing.expectEqual(@as(usize, 1), diag_info.secondary_spans.len);
    try testing.expectEqual(@as(usize, 2), diag_info.secondary_spans[0].line);
    try testing.expectEqualStrings("continuation started here", diag_info.secondary_spans[0].label);
}

test "repository semantic decl char len golden input keeps explicit notes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diag_capture = PipelineDiagCapture.init(allocator);
    defer diag_capture.deinit();
    const diag_info = try diag_capture.expectError(
        allocator,
        "tests/diagnostic_golden/semantic_decl_char_len.f",
        .llvm,
        .{ .target = "x86_64-linux-gnu" },
        error.InvalidCharLen,
    );
    defer diag_capture.release(diag_info);
    try testing.expectEqual(@as(usize, 1), diag_info.notes.len);
    try testing.expectEqual(@as(usize, 1), diag_info.helps.len);
}

test "repository fixed parse continuation golden input keeps explicit parse diagnostic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    try testing.expectError(
        error.MissingName,
        runPipelineWithOptionsAndDiagnostics(
            allocator,
            "tests/diagnostic_golden/fixed_parse_continuation.f",
            .llvm,
            .{ .target = "x86_64-linux-gnu" },
            &diag_bag,
        ),
    );
    const diag_info = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag_info);
    try testing.expectEqualStrings(catalog.parser.missing_name.code, diag_info.code);
    try testing.expectEqualStrings("identifier required here", diag_info.primary_label);
}

test "runPipelineWithOptionsAndDiagnostics compiles ENTRY function alternate result body without leaking into primary unit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "      FUNCTION RF513(RVD001)\n" ++
        "      RF513 = RVD001**2\n" ++
        "      RETURN\n" ++
        "      ENTRY EF852(RVD002)\n" ++
        "      EF852 = 3*RVD002\n" ++
        "      RETURN\n" ++
        "      END\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "entry_function_pipeline.f", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    const result = try runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag);
    defer allocator.free(result.output);
    try testing.expect(!diag_bag.has());
    try testing.expect(std.mem.indexOf(u8, result.output, "@rf513_") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "@ef852_") != null);
}

test "runPipelineWithOptionsAndDiagnostics rejects bind(c) interface character array result in implicit main" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    try testing.expectError(
        error.InvalidCharLen,
        runPipelineWithOptionsAndDiagnostics(
            allocator,
            "tests/gcc-tests/gfortran.dg/bind_c_18.f90",
            .llvm,
            .{},
            &diag_bag,
        ),
    );
    const diag_info = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag_info);
    try testing.expect(std.mem.indexOf(u8, diag_info.message, "cannot be an array") != null);
}

test "runPipelineWithOptionsAndDiagnostics rejects procedure pointer in minimal omp clauses" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diag_capture = PipelineDiagCapture.init(allocator);
    defer diag_capture.deinit();
    const diag_info = try diag_capture.expectError(
        allocator,
        "tests/gcc-tests/gfortran.dg/gomp/proc_ptr_2.f90",
        .llvm,
        .{},
        error.InvalidArgumentType,
    );
    defer diag_capture.release(diag_info);
    try testing.expect(std.mem.indexOf(u8, diag_info.message, "Procedure pointer") != null);
}

