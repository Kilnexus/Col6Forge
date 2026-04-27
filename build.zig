const std = @import("std");

const FallbackGate = struct {
    fail_on_fallback: bool = false,
    max_fallbacks: ?usize = null,
};

fn addFallbackGateArgs(run: *std.Build.Step.Run, gate: FallbackGate) void {
    if (gate.fail_on_fallback) {
        run.addArgs(&.{ "--fallback-policy", "strict" });
        return;
    }
    if (gate.max_fallbacks) |max_fallbacks| {
        run.addArgs(&.{ "--fallback-policy", "budget" });
        run.addArg("--max-fallbacks");
        run.addArg(run.step.owner.fmt("{d}", .{max_fallbacks}));
    }
}

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const tools_optimize = b.option(
        std.builtin.OptimizeMode,
        "tools_optimize",
        "Optimization mode for build tools (golden/verify/gcc-dg/blas/lapack/test-harness/perf tools)",
    ) orelse .Debug;
    const run_from_install = b.option(
        bool,
        "run_from_install",
        "Run `zig build run` from zig-out/bin via install step (default: false, runs from cache artifact)",
    ) orelse false;
    const driver_build_options = b.addOptions();
    driver_build_options.addOption([]const u8, "project_root", b.pathFromRoot("."));
    const constraints_devtools = b.addModule("constraints_devtools", .{
        .root_source_file = b.path("devtools/constraints/mod.zig"),
        .target = target,
    });
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("Col6Forge", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "col6forge",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "Col6Forge" is the name you will use in your source code to
                // import this module (e.g. `@import("Col6Forge")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });
    exe.root_module.addOptions("build_options", driver_build_options);

    // Standalone cc-like driver tool:
    // dependency("Col6Forge").artifact("col6forge-cc")
    const cc_exe = b.addExecutable(.{
        .name = "col6forge-cc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });
    cc_exe.root_module.addOptions("build_options", driver_build_options);

    // Runtime artifact for ecosystem consumers:
    // dependency("Col6Forge").artifact("col6forge_rt")
    const runtime_lib = b.addLibrary(.{
        .name = "col6forge_rt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/col6forge_rt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const golden_runner = b.addExecutable(.{
        .name = "golden_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/golden_runner.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const diagnostic_golden_runner = b.addExecutable(.{
        .name = "diagnostic_golden_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/diagnostic_golden_runner.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const verify_runner = b.addExecutable(.{
        .name = "verify_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/verify_runner.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const gcc_dg_runner = b.addExecutable(.{
        .name = "gcc_dg_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/gcc_dg_runner.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const blas_runner = b.addExecutable(.{
        .name = "blas_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/blas_runner.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const lapack_runner = b.addExecutable(.{
        .name = "lapack_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/lapack_runner.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const test_harness = b.addExecutable(.{
        .name = "test_harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/test_harness.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const perf_bench = b.addExecutable(.{
        .name = "perf_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/perf_bench.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const perf_compare = b.addExecutable(.{
        .name = "perf_compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/perf_compare.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const perf_dashboard = b.addExecutable(.{
        .name = "perf_dashboard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/perf_dashboard.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const error_catalog_docgen = b.addExecutable(.{
        .name = "error_catalog_docgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/error_catalog_docgen.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
            },
        }),
    });

    const constraints_check = b.addExecutable(.{
        .name = "constraints_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("devtools/constraints/constraints_check.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "constraints_devtools", .module = constraints_devtools },
            },
        }),
    });

    const constraints_docgen = b.addExecutable(.{
        .name = "constraints_docgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("devtools/constraints/constraints_docgen.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "constraints_devtools", .module = constraints_devtools },
            },
        }),
    });

    const architecture_audit = b.addExecutable(.{
        .name = "architecture_audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("devtools/constraints/architecture_audit.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
                .{ .name = "constraints_devtools", .module = constraints_devtools },
            },
        }),
    });

    const duplicate_candidates = b.addExecutable(.{
        .name = "duplicate_candidates",
        .root_module = b.createModule(.{
            .root_source_file = b.path("devtools/constraints/duplicate_candidates.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "constraints_devtools", .module = constraints_devtools },
            },
        }),
    });

    const duplicate_baseline_write = b.addExecutable(.{
        .name = "duplicate_baseline_write",
        .root_module = b.createModule(.{
            .root_source_file = b.path("devtools/constraints/duplicate_baseline_write.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "Col6Forge", .module = mod },
                .{ .name = "constraints_devtools", .module = constraints_devtools },
            },
        }),
    });

    const duplicate_check = b.addExecutable(.{
        .name = "duplicate_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("devtools/constraints/duplicate_check.zig"),
            .target = target,
            .optimize = tools_optimize,
            .imports = &.{
                .{ .name = "constraints_devtools", .module = constraints_devtools },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);
    b.installArtifact(cc_exe);
    b.installArtifact(runtime_lib);

    // Stable paths for dependent packages:
    // dependency("Col6Forge").namedLazyPath("col6forge_rt_src")
    b.addNamedLazyPath("col6forge_rt_src", b.path("src/runtime/col6forge_rt.zig"));
    b.addNamedLazyPath("col6forge_rt_dir", b.path("src/runtime"));
    b.addNamedLazyPath("col6forge_src_dir", b.path("src"));
    b.addNamedLazyPath("constraints_devtools_dir", b.path("devtools/constraints"));

    const install_golden_runner = b.addInstallArtifact(golden_runner, .{});
    const install_diagnostic_golden_runner = b.addInstallArtifact(diagnostic_golden_runner, .{});
    const install_verify_runner = b.addInstallArtifact(verify_runner, .{});
    const install_gcc_dg_runner = b.addInstallArtifact(gcc_dg_runner, .{});
    const install_blas_runner = b.addInstallArtifact(blas_runner, .{});
    const install_lapack_runner = b.addInstallArtifact(lapack_runner, .{});
    const install_test_harness = b.addInstallArtifact(test_harness, .{});
    const install_perf_bench = b.addInstallArtifact(perf_bench, .{});
    const install_perf_compare = b.addInstallArtifact(perf_compare, .{});
    const install_perf_dashboard = b.addInstallArtifact(perf_dashboard, .{});
    const install_error_catalog_docgen = b.addInstallArtifact(error_catalog_docgen, .{});
    const install_constraints_check = b.addInstallArtifact(constraints_check, .{});
    const install_constraints_docgen = b.addInstallArtifact(constraints_docgen, .{});
    const install_architecture_audit = b.addInstallArtifact(architecture_audit, .{});
    const install_duplicate_candidates = b.addInstallArtifact(duplicate_candidates, .{});
    const install_duplicate_baseline_write = b.addInstallArtifact(duplicate_baseline_write, .{});
    const install_duplicate_check = b.addInstallArtifact(duplicate_check, .{});

    const tools_step = b.step("tools", "Install all developer runner tools");
    tools_step.dependOn(&install_golden_runner.step);
    tools_step.dependOn(&install_diagnostic_golden_runner.step);
    tools_step.dependOn(&install_verify_runner.step);
    tools_step.dependOn(&install_gcc_dg_runner.step);
    tools_step.dependOn(&install_blas_runner.step);
    tools_step.dependOn(&install_lapack_runner.step);
    tools_step.dependOn(&install_test_harness.step);
    tools_step.dependOn(&install_perf_bench.step);
    tools_step.dependOn(&install_perf_compare.step);
    tools_step.dependOn(&install_perf_dashboard.step);
    tools_step.dependOn(&install_error_catalog_docgen.step);
    tools_step.dependOn(&install_constraints_check.step);
    tools_step.dependOn(&install_constraints_docgen.step);
    tools_step.dependOn(&install_architecture_audit.step);
    tools_step.dependOn(&install_duplicate_candidates.step);
    tools_step.dependOn(&install_duplicate_baseline_write.step);
    tools_step.dependOn(&install_duplicate_check.step);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // Running directly from the cache avoids extra install work in tight edit/run loops.
    // Opt into install-dir execution with `-Drun_from_install=true` when needed.
    if (run_from_install) {
        run_cmd.step.dependOn(b.getInstallStep());
    }

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Compiler-driver entrypoint:
    // zig build cc -- hello.f -o zig-out/hello.exe
    const cc_step = b.step("cc", "Compile/link Fortran through col6forge cc driver");
    const run_cc = b.addRunArtifact(cc_exe);
    cc_step.dependOn(&run_cc.step);
    if (b.args) |args| {
        run_cc.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const lexer_fuzz_tests = b.addTest(.{
        .root_module = mod,
        .filters = &.{"lexer fuzzes malformed fixed-form legacy code without crashing"},
    });
    const fuzz_step = b.step("fuzz", "Run lexer fuzz tests (COL6FORGE_LEX_FUZZ_ITERS controls intensity)");
    const run_lexer_fuzz = b.addRunArtifact(lexer_fuzz_tests);
    fuzz_step.dependOn(&run_lexer_fuzz.step);

    // Compile-focused fast path: build core artifacts and tests without executing them.
    const check_step = b.step("check", "Compile CLI and tests without running");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&cc_exe.step);
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&exe_tests.step);

    // Compile all developer runners without install/copy overhead.
    const tools_check_step = b.step("tools-check", "Compile developer runner tools without install");
    tools_check_step.dependOn(&golden_runner.step);
    tools_check_step.dependOn(&diagnostic_golden_runner.step);
    tools_check_step.dependOn(&verify_runner.step);
    tools_check_step.dependOn(&gcc_dg_runner.step);
    tools_check_step.dependOn(&blas_runner.step);
    tools_check_step.dependOn(&lapack_runner.step);
    tools_check_step.dependOn(&test_harness.step);
    tools_check_step.dependOn(&perf_bench.step);
    tools_check_step.dependOn(&perf_compare.step);
    tools_check_step.dependOn(&perf_dashboard.step);
    tools_check_step.dependOn(&error_catalog_docgen.step);
    tools_check_step.dependOn(&constraints_check.step);
    tools_check_step.dependOn(&constraints_docgen.step);
    tools_check_step.dependOn(&architecture_audit.step);
    tools_check_step.dependOn(&duplicate_candidates.step);
    tools_check_step.dependOn(&duplicate_baseline_write.step);
    tools_check_step.dependOn(&duplicate_check.step);

    const architecture_audit_step = b.step("architecture-audit", "Run architecture guardrail audit");
    const duplicate_candidates_step = b.step("constraints-duplicate-scan", "Report duplicate function-body clusters as advisory findings");
    const duplicate_baseline_step = b.step("constraints-duplicate-baseline", "Refresh the code-native duplicate cluster baseline");
    const duplicate_check_step = b.step("constraints-duplicate-check", "Fail when new duplicate function-body clusters enter the tree");
    const errors_docs_check_step = b.step("errors-docs-check", "Verify docs/errors.md matches the source error catalog");
    const constraints_check_step = b.step("constraints-check", "Validate the code-native constraints registry");
    const constraints_docs_check_step = b.step("constraints-docs-check", "Verify docs/constraints.md matches the code-native constraints registry");
    const run_errors_docs_check = b.addRunArtifact(error_catalog_docgen);
    run_errors_docs_check.addArg("--check");
    errors_docs_check_step.dependOn(&run_errors_docs_check.step);

    const errors_docs_step = b.step("errors-docs", "Regenerate docs/errors.md from the source error catalog");
    const run_errors_docs_write = b.addRunArtifact(error_catalog_docgen);
    run_errors_docs_write.addArg("--write");
    errors_docs_step.dependOn(&run_errors_docs_write.step);

    const run_constraints_check = b.addRunArtifact(constraints_check);
    constraints_check_step.dependOn(&run_constraints_check.step);

    const constraints_docs_step = b.step("constraints-docs", "Regenerate docs/constraints.md from the code-native constraints registry");
    const run_constraints_docs_write = b.addRunArtifact(constraints_docgen);
    run_constraints_docs_write.addArg("--write");
    constraints_docs_step.dependOn(&run_constraints_docs_write.step);

    const run_constraints_docs_check = b.addRunArtifact(constraints_docgen);
    run_constraints_docs_check.addArg("--check");
    constraints_docs_check_step.dependOn(&run_constraints_docs_check.step);

    const run_architecture_audit = b.addRunArtifact(architecture_audit);
    architecture_audit_step.dependOn(&run_errors_docs_check.step);
    architecture_audit_step.dependOn(&run_constraints_check.step);
    architecture_audit_step.dependOn(&run_constraints_docs_check.step);
    const run_duplicate_check = b.addRunArtifact(duplicate_check);
    architecture_audit_step.dependOn(&run_duplicate_check.step);
    architecture_audit_step.dependOn(&run_architecture_audit.step);

    const run_duplicate_candidates = b.addRunArtifact(duplicate_candidates);
    duplicate_candidates_step.dependOn(&run_duplicate_candidates.step);
    if (b.args) |args| {
        run_duplicate_candidates.addArgs(args);
    }

    const run_duplicate_baseline = b.addRunArtifact(duplicate_baseline_write);
    run_duplicate_baseline.addArg("--write");
    duplicate_baseline_step.dependOn(&run_duplicate_baseline.step);
    if (b.args) |args| {
        run_duplicate_baseline.addArgs(args);
    }

    duplicate_check_step.dependOn(&run_duplicate_check.step);

    const golden_step = b.step("golden", "Run golden file tests");
    const run_golden = b.addRunArtifact(golden_runner);
    golden_step.dependOn(&run_golden.step);
    if (b.args) |args| {
        run_golden.addArgs(args);
    }

    const diagnostic_golden_step = b.step("diagnostic-golden", "Run diagnostic golden file tests");
    const run_diagnostic_golden = b.addRunArtifact(diagnostic_golden_runner);
    diagnostic_golden_step.dependOn(&run_diagnostic_golden.step);
    if (b.args) |args| {
        run_diagnostic_golden.addArgs(args);
    }

    const cc_diagnostic_golden_step = b.step("cc-diagnostic-golden", "Run cc translation diagnostic golden file tests");
    const run_cc_diagnostic_golden = b.addRunArtifact(diagnostic_golden_runner);
    run_cc_diagnostic_golden.addArgs(&.{ "--mode", "cc-translate" });
    cc_diagnostic_golden_step.dependOn(&run_cc_diagnostic_golden.step);
    if (b.args) |args| {
        run_cc_diagnostic_golden.addArgs(args);
    }

    const verify_step = b.step("verify", "Run NIST F78 verification tests");
    const verify_fcvs21_f95 = b.option(bool, "fcvs21_f95", "Verify with the Fortran 95 adapted NIST F78 suite (example: zig build verify -Dfcvs21_f95 -- --filter FM715)") orelse false;
    const verify_fcsv78 = b.option(bool, "fcsv78", "Verify with the original NIST F78 suite (example: zig build verify -Dfcsv78 -- --filter FM715)") orelse false;
    const verify_fail_on_fallback = b.option(bool, "verify_fail_on_fallback", "Fail verification immediately when any fallback path is taken") orelse false;
    const verify_max_fallbacks = b.option(usize, "verify_max_fallbacks", "Fail verification if total fallback count exceeds this budget");
    if (verify_fcvs21_f95 and verify_fcsv78) {
        @panic("choose at most one of -Dfcvs21_f95 or -Dfcsv78");
    }
    const run_verify = b.addRunArtifact(verify_runner);
    verify_step.dependOn(&run_verify.step);
    if (verify_fcvs21_f95) {
        run_verify.addArgs(&.{ "--tests-dir", "tests/NIST_F78_test_suite/fcvs21_f95" });
    } else if (verify_fcsv78) {
        run_verify.addArgs(&.{ "--tests-dir", "tests/NIST_F78_test_suite/FCSV78" });
    }
    addFallbackGateArgs(run_verify, .{
        .fail_on_fallback = verify_fail_on_fallback,
        .max_fallbacks = verify_max_fallbacks,
    });
    if (b.args) |args| {
        run_verify.addArgs(args);
    }

    const verify_strict_step = b.step("verify-strict", "Run NIST F78 verification tests and fail on any fallback path");
    const run_verify_strict = b.addRunArtifact(verify_runner);
    verify_strict_step.dependOn(&run_verify_strict.step);
    if (verify_fcvs21_f95) {
        run_verify_strict.addArgs(&.{ "--tests-dir", "tests/NIST_F78_test_suite/fcvs21_f95" });
    } else if (verify_fcsv78) {
        run_verify_strict.addArgs(&.{ "--tests-dir", "tests/NIST_F78_test_suite/FCSV78" });
    }
    addFallbackGateArgs(run_verify_strict, .{ .fail_on_fallback = true });
    if (b.args) |args| {
        run_verify_strict.addArgs(args);
    }

    const gcc_dg_verify_step = b.step("gcc-dg-verify", "Run GCC gfortran.dg compile verification tests");
    const run_gcc_dg_verify = b.addRunArtifact(gcc_dg_runner);
    gcc_dg_verify_step.dependOn(&run_gcc_dg_verify.step);
    if (b.args) |args| {
        run_gcc_dg_verify.addArgs(args);
    }

    const blas_verify_step = b.step("blas-verify", "Run BLAS 3.12.0 verification tests");
    const run_blas_verify = b.addRunArtifact(blas_runner);
    blas_verify_step.dependOn(&run_blas_verify.step);
    if (b.args) |args| {
        run_blas_verify.addArgs(args);
    }

    const lapack_verify_step = b.step("lapack-verify", "Run LAPACK-lite 3.1.1 verification tests");
    const lapack_fail_on_fallback = b.option(bool, "lapack_fail_on_fallback", "Fail LAPACK verification immediately when any fallback path is taken") orelse false;
    const lapack_max_fallbacks = b.option(usize, "lapack_max_fallbacks", "Fail LAPACK verification if total fallback count exceeds this budget");
    const run_lapack_verify = b.addRunArtifact(lapack_runner);
    lapack_verify_step.dependOn(&run_lapack_verify.step);
    addFallbackGateArgs(run_lapack_verify, .{
        .fail_on_fallback = lapack_fail_on_fallback,
        .max_fallbacks = lapack_max_fallbacks,
    });
    if (b.args) |args| {
        run_lapack_verify.addArgs(args);
    }

    const lapack_verify_strict_step = b.step("lapack-verify-strict", "Run LAPACK-lite verification and fail on any fallback path");
    const run_lapack_verify_strict = b.addRunArtifact(lapack_runner);
    lapack_verify_strict_step.dependOn(&run_lapack_verify_strict.step);
    addFallbackGateArgs(run_lapack_verify_strict, .{ .fail_on_fallback = true });
    if (b.args) |args| {
        run_lapack_verify_strict.addArgs(args);
    }

    const test_all_step = b.step("test-all", "Run unified test harness");
    const run_test_all = b.addRunArtifact(test_harness);
    test_all_step.dependOn(&run_test_all.step);
    if (b.args) |args| {
        run_test_all.addArgs(args);
    }

    const perf_bench_step = b.step("perf-bench", "Run BLAS/LAPACK benchmark sampling and emit JSON");
    const run_perf_bench = b.addRunArtifact(perf_bench);
    perf_bench_step.dependOn(&run_perf_bench.step);
    if (b.args) |args| {
        run_perf_bench.addArgs(args);
    }

    const perf_compare_step = b.step("perf-compare", "Compare two benchmark JSON reports and fail on regressions");
    const run_perf_compare = b.addRunArtifact(perf_compare);
    perf_compare_step.dependOn(&run_perf_compare.step);
    if (b.args) |args| {
        run_perf_compare.addArgs(args);
    }

    const perf_regress_step = b.step("perf-regress", "Alias of perf-compare for CI regression checks");
    perf_regress_step.dependOn(&run_perf_compare.step);

    const perf_dashboard_step = b.step("perf-dashboard", "Update performance history JSON and generate PERFORMANCE.md");
    const run_perf_dashboard = b.addRunArtifact(perf_dashboard);
    perf_dashboard_step.dependOn(&run_perf_dashboard.step);
    if (b.args) |args| {
        run_perf_dashboard.addArgs(args);
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
