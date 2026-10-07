const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library is a module first: a protocol contract is consumed by
    // importers, not linked as a binary. The static artifact exists so that
    // `zig build` produces a checkable proof of compilation and so that a
    // C-ABI consumer has something to link.
    const lib_mod = b.addModule("zig-agent-protocols", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig-agent-protocols",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // The demonstration is a separate executable, not the library. A static
    // library cannot be executed, so `zig build run` needs something runnable,
    // and a protocol library that has only ever run its own tests has never
    // been used against real wire bytes.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("zig-agent-protocols", lib_mod);

    const demo = b.addExecutable(.{
        .name = "zig-agent-protocols-demo",
        .root_module = demo_mod,
    });
    b.installArtifact(demo);

    // The runtime example drives a real connection over a real socket with
    // the same `conn.Conn` a server binary would use, so it is the proof that
    // the codec and the runtime work together on actual transport bytes.

    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_mod.addImport("zig-agent-protocols", lib_mod);

    const runtime_demo = b.addExecutable(.{
        .name = "zig-agent-protocols-runtime",
        .root_module = runtime_mod,
    });
    b.installArtifact(runtime_demo);

    // running

    const run_cmd = b.addRunArtifact(demo);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the demonstration against real wire bytes");
    run_step.dependOn(&run_cmd.step);

    const run_runtime_cmd = b.addRunArtifact(runtime_demo);
    const run_runtime_step = b.step("run-runtime", "Run a live MCP client and server over a socket");
    run_runtime_step.dependOn(&run_runtime_cmd.step);

    // testing

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // The golden vectors decode the specifications' own worked examples. They
    // live outside `src/` because a fixture is a file, and they need their own
    // test binary because Zig only runs the tests in a root file the build
    // reaches. They are in the default `test` step: a normative example is
    // cheap to check and expensive to notice drifting.
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("test/golden_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    golden_mod.addImport("zig-agent-protocols", lib_mod);

    const golden_tests = b.addTest(.{
        .root_module = golden_mod,
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);

    // The loopback tests drive a real connection over a real socket: a client
    // and a server exchanging frames through a live `Io`. They are separate
    // from the unit tests for the same reason as the golden vectors, and
    // because they need their own `Io` rather than the one a test block
    // cannot own. A codec that has only ever been tested against slices has
    // never been driven by a transport.
    const loopback_mod = b.createModule(.{
        .root_source_file = b.path("test/loopback_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    loopback_mod.addImport("zig-agent-protocols", lib_mod);

    const loopback_tests = b.addTest(.{
        .root_module = loopback_mod,
    });
    const run_loopback_tests = b.addRunArtifact(loopback_tests);

    const test_step = b.step("test", "Run unit tests and the golden vectors");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_golden_tests.step);
    test_step.dependOn(&run_loopback_tests.step);

    // The property and differential harness. It is a separate step because it
    // generates tens of thousands of documents, and because the interesting
    // runs are the ones with a seed chosen to reproduce a failure or a number
    // of iterations chosen to crank. It inherits the standard optimize option,
    // and it must not be run in ReleaseFast: a bounds violation is a trap in
    // Debug and ReleaseSafe and nothing at all in ReleaseFast, and catching the
    // former is the reason the step exists.
    const fuzz_options = b.addOptions();
    fuzz_options.addOption(u64, "fuzz_seed", b.option(
        u64,
        "fuzz-seed",
        "Seed for the property and differential harness",
    ) orelse 0x5eed_5eed_5eed_5eed);
    fuzz_options.addOption(usize, "fuzz_iterations", b.option(
        usize,
        "fuzz-iterations",
        "Documents the property and differential harness generates",
    ) orelse 20_000);

    const testkit_mod = b.createModule(.{
        .root_source_file = b.path("src/testkit.zig"),
        .target = target,
        .optimize = optimize,
    });
    testkit_mod.addImport("zig-agent-protocols", lib_mod);
    testkit_mod.addOptions("build_options", fuzz_options);

    const testkit_tests = b.addTest(.{
        .root_module = testkit_mod,
    });
    const run_testkit_tests = b.addRunArtifact(testkit_tests);

    const fuzz_step = b.step("fuzz", "Run the property and differential harness");
    fuzz_step.dependOn(&run_testkit_tests.step);

    // docs

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
