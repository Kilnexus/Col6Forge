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
test "runPipelineWithOptionsAndDiagnostics keeps diagnostics in explicit bag" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "      SUBROUTINE S\n" ++
        "      CHARACTER*(*) A\n" ++
        "      END\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "explicit_semantic_diag.f", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    try testing.expectError(
        error.InvalidCharLen,
        runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag),
    );
    const diag_info = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag_info);
    try testing.expectEqual(@as(usize, 2), diag_info.line);
    try testing.expectEqual(@as(usize, 7), diag_info.column);
    try testing.expectEqualStrings(catalog.semantic.invalid_char_len.code, diag_info.code);
    try testing.expectEqualStrings("      CHARACTER*(*) A", diag_info.line_text);
    try testing.expectEqual(@as(usize, 1), diag_info.notes.len);
    try testing.expectEqual(@as(usize, 1), diag_info.helps.len);
}

test "runPipelineWithOptionsAndDiagnostics accepts slash array constructor assignment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "subroutine foo(x)\n" ++
        "  integer :: x(4)\n" ++
        "  x(:) = (/ 3, 1, 4, 1 /)\n" ++
        "end subroutine\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "slash_array_constructor_pipeline.f90", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    const result = try runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag);
    defer allocator.free(result.output);
    try testing.expect(!diag_bag.has());
}

test "runPipelineWithOptionsAndDiagnostics expands same-directory INCLUDE statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const included =
        "subroutine from_include(x)\n" ++
        "  integer :: x\n" ++
        "  x = 7\n" ++
        "end subroutine\n";
    var include_file = try tmp.dir.createFile("included_body.inc", .{ .truncate = true });
    try include_file.writeAll(included);
    include_file.close();

    const source =
        "include \"included_body.inc\"\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "include_driver.f90", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    const result = try runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag);
    defer allocator.free(result.output);
    try testing.expect(!diag_bag.has());
    try testing.expect(std.mem.indexOf(u8, result.output, "from_include") != null);
}

test "runPipeline rejects real DO by default but accepts it under f77 dialect lowering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "      PROGRAM P\n" ++
        "      REAL X\n" ++
        "      DO 10 X = 0.5, 1.5, 0.5\n" ++
        "         PRINT *, X\n" ++
        "10    CONTINUE\n" ++
        "      END\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "legacy_real_do.f", source);
    defer allocator.free(file_path);

    try testing.expectError(error.AssignmentTypeMismatch, runPipelineWithOptions(allocator, file_path, .llvm, .{}));

    const result = try runPipelineWithOptions(allocator, file_path, .llvm, .{ .dialect = .f77_legacy });
    defer allocator.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "do_while_test") != null);
}

test "runPipeline accepts integer DO with real bounds under f77 dialect lowering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "      PROGRAM P\n" ++
        "      INTEGER I, ACC\n" ++
        "      ACC = 0\n" ++
        "      DO 10 I = 6.7, 9.325D0\n" ++
        "         ACC = ACC + I\n" ++
        "10    CONTINUE\n" ++
        "      END\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "legacy_integer_do_real_bounds.f", source);
    defer allocator.free(file_path);

    try testing.expectError(error.AssignmentTypeMismatch, runPipelineWithOptions(allocator, file_path, .llvm, .{}));

    const result = try runPipelineWithOptions(allocator, file_path, .llvm, .{ .dialect = .f77_legacy });
    defer allocator.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "do_while_test") != null);
}

test "runPipelineWithOptionsAndDiagnostics accepts fixed-shape entry-expanded array functions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "! { dg-do compile }\n" ++
        "! Test the fix for the fourth problem in PR40011, where the\n" ++
        "! entries were not resolved, resulting in a segfault.\n" ++
        "!\n" ++
        "! Contributed by Dominique d'Humieres <dominiq@lps.ens.fr>\n" ++
        "!\n" ++
        "program test\n" ++
        "interface\n" ++
        "  function bad_stuff(n)\n" ++
        "    integer :: bad_stuff (2)\n" ++
        "    integer :: n(2)\n" ++
        "  end function bad_stuff\n" ++
        "   recursive function rec_stuff(n) result (tmp)\n" ++
        "    integer :: n(2), tmp(2)\n" ++
        "  end function rec_stuff\n" ++
        "end interface\n" ++
        "   integer :: res(2)\n" ++
        "  res = bad_stuff((/-19,-30/))\n" ++
        "\n" ++
        "end program test\n" ++
        "\n" ++
        "  recursive function bad_stuff(n)\n" ++
        "    integer :: bad_stuff (2)\n" ++
        "    integer :: n(2), tmp(2), ent = 0, sent = 0\n" ++
        "    save ent, sent\n" ++
        "    ent = -1\n" ++
        "   entry rec_stuff(n) result (tmp)\n" ++
        "    if (ent == -1) then\n" ++
        "      sent = ent\n" ++
        "      ent = 0\n" ++
        "    end if\n" ++
        "    ent = ent + 1\n" ++
        "    tmp = 1\n" ++
        "    if(maxval (n) < 5) then\n" ++
        "      tmp = tmp + rec_stuff (n+1)\n" ++
        "      ent = ent - 1\n" ++
        "    endif\n" ++
        "    if (ent == 1) then\n" ++
        "      if (sent == -1) then\n" ++
        "        bad_stuff = tmp + bad_stuff (1)\n" ++
        "      end if\n" ++
        "      ent = 0\n" ++
        "      sent = 0\n" ++
        "    end if\n" ++
        "  end function bad_stuff\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "entry_array_function_pipeline.f90", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    const result = try runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag);
    defer allocator.free(result.output);
    try testing.expect(!diag_bag.has());
}

test "runPipelineToWriterWithOptionsAndDiagnostics accepts fixed-shape entry-expanded array functions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "! { dg-do compile }\n" ++
        "! Test the fix for the fourth problem in PR40011, where the\n" ++
        "! entries were not resolved, resulting in a segfault.\n" ++
        "!\n" ++
        "! Contributed by Dominique d'Humieres <dominiq@lps.ens.fr>\n" ++
        "!\n" ++
        "program test\n" ++
        "interface\n" ++
        "  function bad_stuff(n)\n" ++
        "    integer :: bad_stuff (2)\n" ++
        "    integer :: n(2)\n" ++
        "  end function bad_stuff\n" ++
        "   recursive function rec_stuff(n) result (tmp)\n" ++
        "    integer :: n(2), tmp(2)\n" ++
        "  end function rec_stuff\n" ++
        "end interface\n" ++
        "   integer :: res(2)\n" ++
        "  res = bad_stuff((/-19,-30/))\n" ++
        "\n" ++
        "end program test\n" ++
        "\n" ++
        "  recursive function bad_stuff(n)\n" ++
        "    integer :: bad_stuff (2)\n" ++
        "    integer :: n(2), tmp(2), ent = 0, sent = 0\n" ++
        "    save ent, sent\n" ++
        "    ent = -1\n" ++
        "   entry rec_stuff(n) result (tmp)\n" ++
        "    if (ent == -1) then\n" ++
        "      sent = ent\n" ++
        "      ent = 0\n" ++
        "    end if\n" ++
        "    ent = ent + 1\n" ++
        "    tmp = 1\n" ++
        "    if(maxval (n) < 5) then\n" ++
        "      tmp = tmp + rec_stuff (n+1)\n" ++
        "      ent = ent - 1\n" ++
        "    endif\n" ++
        "    if (ent == 1) then\n" ++
        "      if (sent == -1) then\n" ++
        "        bad_stuff = tmp + bad_stuff (1)\n" ++
        "      end if\n" ++
        "      ent = 0\n" ++
        "      sent = 0\n" ++
        "    end if\n" ++
        "  end function bad_stuff\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "entry_array_function_writer.f90", source);
    defer allocator.free(file_path);

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    var writer = output.writer();

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    try runPipelineToWriterWithOptionsAndDiagnostics(allocator, file_path, .llvm, &writer, .{}, &diag_bag);
    try testing.expect(!diag_bag.has());
    try testing.expect(output.items.len != 0);
}

test "runPipelineToWriterWithOptionsAndDiagnostics accepts fixed-shape entry-expanded array functions with GPA allocator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "! { dg-do compile }\n" ++
        "! Test the fix for the fourth problem in PR40011, where the\n" ++
        "! entries were not resolved, resulting in a segfault.\n" ++
        "!\n" ++
        "! Contributed by Dominique d'Humieres <dominiq@lps.ens.fr>\n" ++
        "!\n" ++
        "program test\n" ++
        "interface\n" ++
        "  function bad_stuff(n)\n" ++
        "    integer :: bad_stuff (2)\n" ++
        "    integer :: n(2)\n" ++
        "  end function bad_stuff\n" ++
        "   recursive function rec_stuff(n) result (tmp)\n" ++
        "    integer :: n(2), tmp(2)\n" ++
        "  end function rec_stuff\n" ++
        "end interface\n" ++
        "   integer :: res(2)\n" ++
        "  res = bad_stuff((/-19,-30/))\n" ++
        "\n" ++
        "end program test\n" ++
        "\n" ++
        "  recursive function bad_stuff(n)\n" ++
        "    integer :: bad_stuff (2)\n" ++
        "    integer :: n(2), tmp(2), ent = 0, sent = 0\n" ++
        "    save ent, sent\n" ++
        "    ent = -1\n" ++
        "   entry rec_stuff(n) result (tmp)\n" ++
        "    if (ent == -1) then\n" ++
        "      sent = ent\n" ++
        "      ent = 0\n" ++
        "    end if\n" ++
        "    ent = ent + 1\n" ++
        "    tmp = 1\n" ++
        "    if(maxval (n) < 5) then\n" ++
        "      tmp = tmp + rec_stuff (n+1)\n" ++
        "      ent = ent - 1\n" ++
        "    endif\n" ++
        "    if (ent == 1) then\n" ++
        "      if (sent == -1) then\n" ++
        "        bad_stuff = tmp + bad_stuff (1)\n" ++
        "      end if\n" ++
        "      ent = 0\n" ++
        "      sent = 0\n" ++
        "    end if\n" ++
        "  end function bad_stuff\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "entry_array_function_writer_gpa.f90", source);
    defer allocator.free(file_path);

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    var writer = output.writer();

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    try runPipelineToWriterWithOptionsAndDiagnostics(allocator, file_path, .llvm, &writer, .{}, &diag_bag);
    try std.testing.expect(!diag_bag.has());
    try std.testing.expect(output.items.len != 0);
}

test "runPipelineWithOptionsAndDiagnostics rejects abstract type array constructor items across module use" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "module my_module\n" ++
        "  implicit none\n" ++
        "  private\n" ++
        "  type, abstract, public :: a\n" ++
        "  end type\n" ++
        "  type, extends(a), public :: b\n" ++
        "  end type\n" ++
        "end\n" ++
        "\n" ++
        "program main\n" ++
        "  use my_module\n" ++
        "  implicit none\n" ++
        "  type(b) :: b_instance\n" ++
        "  class(a), allocatable :: a_array(:)\n" ++
        "  class(b), allocatable :: b_array(:)\n" ++
        "  a_array = [b_instance]\n" ++
        "  b_array = [b_instance]\n" ++
        "  a_array = [a_array]\n" ++
        "end program\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "abstract_array_ctor_pipeline.f90", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    try testing.expectError(
        error.AssignmentTypeMismatch,
        runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag),
    );
    const diag_info = diag_bag.take() orelse return error.TestExpectedEqual;
    defer diag_bag.release(diag_info);
    try testing.expect(std.mem.indexOf(u8, diag_info.message, "is of the ABSTRACT type") != null);
}

test "runPipelineWithOptionsAndDiagnostics accepts parent abstract component data access" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "module m\n" ++
        "  implicit none\n" ++
        "  type, abstract :: abstract_t\n" ++
        "    integer :: i\n" ++
        "  end type abstract_t\n" ++
        "  type, extends(abstract_t) :: concrete_t\n" ++
        "  end type concrete_t\n" ++
        "contains\n" ++
        "  subroutine test()\n" ++
        "    type(concrete_t) :: obj\n" ++
        "    obj%abstract_t%i = 42\n" ++
        "  end subroutine test\n" ++
        "end module m\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "abstract_parent_component_pipeline.f90", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    const result = try runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag);
    defer allocator.free(result.output);
    try testing.expect(!diag_bag.has());
}

test "runPipelineWithOptionsAndDiagnostics accepts projected PDT component array assignment and reduction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "module input_output_pair_m\n" ++
        "  implicit none\n" ++
        "  type input_output_pair_t(k)\n" ++
        "    integer, kind :: k\n" ++
        "    integer :: a, b\n" ++
        "  end type\n" ++
        "  type mini_batch_t(k)\n" ++
        "    integer, kind :: k = kind(1.)\n" ++
        "    type(input_output_pair_t(k)), allocatable :: input_output_pairs_(:)\n" ++
        "  end type\n" ++
        "  interface\n" ++
        "    module function default_real_construct()\n" ++
        "      implicit none\n" ++
        "      type(mini_batch_t) default_real_construct\n" ++
        "    end function\n" ++
        "  end interface\n" ++
        "end module\n" ++
        "submodule(input_output_pair_m) input_output_pair_smod\n" ++
        "contains\n" ++
        "  function default_real_construct()\n" ++
        "    type(mini_batch_t) default_real_construct\n" ++
        "    allocate(default_real_construct%input_output_pairs_(2))\n" ++
        "    default_real_construct%input_output_pairs_%a = [42,43]\n" ++
        "    default_real_construct%input_output_pairs_%b = [420,421]\n" ++
        "  end function\n" ++
        "end submodule\n" ++
        "program test\n" ++
        "  use input_output_pair_m\n" ++
        "  type(mini_batch_t), allocatable :: res\n" ++
        "  res = default_real_construct()\n" ++
        "  if (any(res%input_output_pairs_%a /= [42,43])) stop 1\n" ++
        "  if (any(res%input_output_pairs_%b /= [420,421])) stop 2\n" ++
        "end program\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "projected_pdt_component_pipeline.f90", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    const result = try runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag);
    defer allocator.free(result.output);
    try testing.expect(!diag_bag.has());
}

test "runPipelineWithOptionsAndDiagnostics accepts repository array_constructor_14 contents" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "! { dg-do compile }\n" ++
        "! { dg-options \"-O2 -fdump-tree-original\" }\n" ++
        "\n" ++
        "subroutine foo(x)\n" ++
        "  integer :: x(4)\n" ++
        "  x(:) = (/ 3, 1, 4, 1 /)\n" ++
        "end subroutine\n" ++
        "\n" ++
        "subroutine bar(x)\n" ++
        "  integer :: x(4)\n" ++
        "  x = (/ 3, 1, 4, 1 /)\n" ++
        "end subroutine\n" ++
        "\n" ++
        "! { dg-final { scan-tree-dump-times \"data\" 0 \"original\" } }\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "array_constructor_14_like.f90", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    const result = try runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag);
    defer allocator.free(result.output);
    try testing.expect(!diag_bag.has());
}

test "runPipelineWithOptionsAndDiagnostics accepts repository array_constructor_14 file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    const result = try runPipelineWithOptionsAndDiagnostics(
        allocator,
        "tests/gcc-tests/gfortran.dg/array_constructor_14.f90",
        .llvm,
        .{},
        &diag_bag,
    );
    defer allocator.free(result.output);
    try testing.expect(!diag_bag.has());
}

test "runPipelineWithOptions accepts repository array_constructor_14 file" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try runPipelineWithOptions(
        allocator,
        "tests/gcc-tests/gfortran.dg/array_constructor_14.f90",
        .llvm,
        .{},
    );
    defer allocator.free(result.output);
    try testing.expect(result.output.len != 0);
}

test "runPipelineWithOptions accepts repository array_constructor_14 file with GPA allocator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try runPipelineWithOptions(
        allocator,
        "tests/gcc-tests/gfortran.dg/array_constructor_14.f90",
        .llvm,
        .{},
    );
    defer allocator.free(result.output);
    try std.testing.expect(result.output.len != 0);
}

test "runPipelineWithOptionsAndDiagnostics accepts defined assignment declared with procedure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        "! { dg-do compile }\r\n" ++
        "!\r\n" ++
        "! PR 40743: [4.5 Regression] ICE when compiling iso_varying_string.f95 at revision 149591\r\n" ++
        "!\r\n" ++
        "! Reduced from http://www.fortran.com/iso_varying_string.f95\r\n" ++
        "! Contributed by Janus Weil <janus@gcc.gnu.org>\r\n" ++
        "\r\n" ++
        "  implicit none\r\n" ++
        "\r\n" ++
        "  type :: varying_string\r\n" ++
        "  end type\r\n" ++
        "\r\n" ++
        "  interface assignment(=)\r\n" ++
        "     procedure op_assign_VS_CH\r\n" ++
        "  end interface\r\n" ++
        "\r\n" ++
        "contains\r\n" ++
        "\r\n" ++
        "  subroutine op_assign_VS_CH (var, exp)\r\n" ++
        "    type(varying_string), intent(out) :: var\r\n" ++
        "    character(LEN=*), intent(in)      :: exp\r\n" ++
        "  end subroutine\r\n" ++
        "\r\n" ++
        "  subroutine split_VS\r\n" ++
        "    type(varying_string) :: string\r\n" ++
        "    call split_CH(string)\r\n" ++
        "  end subroutine\r\n" ++
        "\r\n" ++
        "  subroutine split_CH (string)\r\n" ++
        "    type(varying_string) :: string\r\n" ++
        "    string = \"\"\r\n" ++
        "  end subroutine\r\n" ++
        "\r\n" ++
        "end\r\n";
    const file_path = try writeTempSourceFile(&tmp, allocator, "defined_assignment_pipeline.f90", source);
    defer allocator.free(file_path);

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    _ = try runPipelineWithOptionsAndDiagnostics(allocator, file_path, .llvm, .{}, &diag_bag);
    try testing.expect(diag_bag.take() == null);
}

test "runPipelineWithOptionsAndDiagnostics accepts repository interface_assignment_4 case" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diag_bag = diag.Bag.init(allocator);
    defer diag_bag.deinit();

    _ = try runPipelineWithOptionsAndDiagnostics(
        allocator,
        "tests/gcc-tests/gfortran.dg/interface_assignment_4.f90",
        .llvm,
        .{},
        &diag_bag,
    );
    try testing.expect(diag_bag.take() == null);
}

