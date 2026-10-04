const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const testio_mod = b.createModule(.{
        .root_source_file = b.path("src/testio.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Consumers use the native Zig module below. Keep the static packaging
    // artifact, but it exports no C ABI and does not force analysis of every
    // lazy function body. Tests and executable consumers exercise those bodies.
    const lib_mod = b.addModule("zig-agent-protocols", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("testio", testio_mod);

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
    runtime_mod.addImport("testio", testio_mod);

    const runtime_demo = b.addExecutable(.{
        .name = "zig-agent-protocols-runtime",
        .root_module = runtime_mod,
    });
    b.installArtifact(runtime_demo);

    // The sessions example drives an ACP session and the mcp-over-acp binding
    // over one real connection, so it is the proof that the two protocol layers
    // compose on transport bytes rather than only against each other in a
    // slice.

    const sessions_mod = b.createModule(.{
        .root_source_file = b.path("src/sessions_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    sessions_mod.addImport("zig-agent-protocols", lib_mod);
    sessions_mod.addImport("testio", testio_mod);

    const sessions_demo = b.addExecutable(.{
        .name = "zig-agent-protocols-sessions",
        .root_module = sessions_mod,
    });
    b.installArtifact(sessions_demo);

    const run_sessions_cmd = b.addRunArtifact(sessions_demo);
    const run_sessions_step = b.step("run-sessions", "Run an ACP session and the binding over a socket");
    run_sessions_step.dependOn(&run_sessions_cmd.step);

    // The HTTP example drives the Streamable HTTP transport over a real
    // loopback socket, so it is the proof that the second transport works on
    // real HTTP bytes and not only against header blocks in a slice.

    const http_mod = b.createModule(.{
        .root_source_file = b.path("src/http_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_mod.addImport("zig-agent-protocols", lib_mod);

    const http_demo = b.addExecutable(.{
        .name = "zig-agent-protocols-http",
        .root_module = http_mod,
    });
    b.installArtifact(http_demo);

    const run_http_cmd = b.addRunArtifact(http_demo);
    const run_http_step = b.step("run-http", "Run the Streamable HTTP transport over a socket");
    run_http_step.dependOn(&run_http_cmd.step);

    // The A2A example drives the fourth protocol over a real socket: a card
    // discovered from an origin, one unary JSON-RPC call answered with a task,
    // one with a message, and one refused. It is an installed demonstration
    // with a `run-a2a` step for the same reason the other three are — the A2A
    // codec has never been driven by anything but literals until a transport
    // carries it, and a refusal is only refused correctly when a peer sent it.
    const a2a_mod = b.createModule(.{
        .root_source_file = b.path("src/a2a_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    a2a_mod.addImport("zig-agent-protocols", lib_mod);
    const a2a_demo = b.addExecutable(.{
        .name = "zig-agent-protocols-a2a",
        .root_module = a2a_mod,
    });
    b.installArtifact(a2a_demo);
    const run_a2a_cmd = b.addRunArtifact(a2a_demo);
    b.step("run-a2a", "Run A2A discovery and unary JSON-RPC over a socket").dependOn(&run_a2a_cmd.step);

    // The benchmarks are three modules because they answer three different
    // questions. The driver only sizes a run and prints it, and refusing a
    // mistyped count before any work starts is its whole job; the codec module
    // measures literals in buffers; the runtime module opens sockets and
    // measures a round trip. `b.args` reaches the driver rather than the build,
    // so `zig build run-bench -- --mode codec` sizes the run and the driver
    // decides what is in range.
    const bench_codec_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_codec_mod.addImport("zig-agent-protocols", lib_mod);
    const bench_runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_runtime_mod.addImport("zig-agent-protocols", lib_mod);
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("bench_codec", bench_codec_mod);
    bench_mod.addImport("bench_runtime", bench_runtime_mod);
    const bench = b.addExecutable(.{
        .name = "zig-agent-protocols-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);
    const run_bench_cmd = b.addRunArtifact(bench);
    if (b.args) |args| run_bench_cmd.addArgs(args);
    b.step("run-bench", "Run bounded codec and live runtime benchmarks").dependOn(&run_bench_cmd.step);

    // The interoperability participants are peers, not examples. Each one is
    // started as a child process by the Python supervisor in `test/interop/`
    // and answers an independent upstream SDK, so the build cannot run them:
    // with no peer on the other end of their pipes, a run proves nothing. They
    // are installed rather than only built because the supervisor starts them
    // by the installed path, and the `interop-*` steps build exactly that
    // artifact — `zig build interop-mcp` compiles the participant, and the
    // `interop-mcp` script in `devenv.nix` is what drives the exchange.
    const mcp_interop_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp_interop.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_interop_mod.addImport("zig-agent-protocols", lib_mod);
    const mcp_interop = b.addExecutable(.{
        .name = "zig-agent-protocols-mcp-interop",
        .root_module = mcp_interop_mod,
    });
    const install_mcp_interop = b.addInstallArtifact(mcp_interop, .{});
    b.getInstallStep().dependOn(&install_mcp_interop.step);
    b.step(
        "interop-mcp",
        "Build the participant for the independent MCP SDK exchange",
    ).dependOn(&install_mcp_interop.step);

    const a2a_interop_mod = b.createModule(.{
        .root_source_file = b.path("src/a2a_interop.zig"),
        .target = target,
        .optimize = optimize,
    });
    a2a_interop_mod.addImport("zig-agent-protocols", lib_mod);
    const a2a_interop = b.addExecutable(.{
        .name = "zig-agent-protocols-a2a-interop",
        .root_module = a2a_interop_mod,
    });
    const install_a2a_interop = b.addInstallArtifact(a2a_interop, .{});
    b.getInstallStep().dependOn(&install_a2a_interop.step);
    b.step(
        "interop-a2a",
        "Build the participant for the independent A2A SDK exchange",
    ).dependOn(&install_a2a_interop.step);

    const mcp_current_interop_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp_current_interop.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_current_interop_mod.addImport("zig-agent-protocols", lib_mod);
    const mcp_current_interop = b.addExecutable(.{
        .name = "zig-agent-protocols-mcp-current-interop",
        .root_module = mcp_current_interop_mod,
    });
    const install_mcp_current_interop = b.addInstallArtifact(mcp_current_interop, .{});
    b.getInstallStep().dependOn(&install_mcp_current_interop.step);
    b.step(
        "interop-mcp-current",
        "Build the participant for the current MCP SDK exchange",
    ).dependOn(&install_mcp_current_interop.step);

    const acp_interop_mod = b.createModule(.{
        .root_source_file = b.path("src/acp_interop.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_interop_mod.addImport("zig-agent-protocols", lib_mod);
    const acp_interop = b.addExecutable(.{
        .name = "zig-agent-protocols-acp-interop",
        .root_module = acp_interop_mod,
    });
    const install_acp_interop = b.addInstallArtifact(acp_interop, .{});
    b.getInstallStep().dependOn(&install_acp_interop.step);
    b.step(
        "interop-acp",
        "Build the participant for the independent ACP SDK exchange",
    ).dependOn(&install_acp_interop.step);

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
    loopback_mod.addImport("testio", testio_mod);

    const loopback_tests = b.addTest(.{
        .root_module = loopback_mod,
    });
    const run_loopback_tests = b.addRunArtifact(loopback_tests);

    // The examples carry test blocks of their own: the runtime, the sessions,
    // the HTTP and the A2A examples assert the failure paths their printed
    // output cannot show, such as a handler answering a string id and an error
    // member landing beside `result` rather than inside it. Zig only runs the
    // tests in a root the build reaches, so without these binaries those
    // blocks are source that no compiler ever looks at, which is the dormancy
    // this repository has already been bitten by once.
    const runtime_example_tests = b.addTest(.{
        .root_module = runtime_mod,
    });
    const run_runtime_example_tests = b.addRunArtifact(runtime_example_tests);

    const sessions_example_tests = b.addTest(.{
        .root_module = sessions_mod,
    });
    const run_sessions_example_tests = b.addRunArtifact(sessions_example_tests);

    const http_example_tests = b.addTest(.{
        .root_module = http_mod,
    });
    const run_http_example_tests = b.addRunArtifact(http_example_tests);

    // The benchmarks are three roots for the same reason they are three
    // modules: a driver test cannot see the corpus a codec run decodes, and a
    // statistics test that had to open a socket to reach its numbers would be
    // testing the machine as much as the arithmetic. `testio` is a root of its
    // own because the library reaches it as a named import; the shared module
    // is one instance here and one instance inside the library, so a type the
    // harness and the runtime exchange is one type rather than two that only
    // happen to have the same name.
    const bench_tests = b.addTest(.{ .root_module = bench_mod });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    const bench_codec_tests = b.addTest(.{ .root_module = bench_codec_mod });
    const run_bench_codec_tests = b.addRunArtifact(bench_codec_tests);
    const bench_runtime_tests = b.addTest(.{ .root_module = bench_runtime_mod });
    const run_bench_runtime_tests = b.addRunArtifact(bench_runtime_tests);
    const testio_tests = b.addTest(.{ .root_module = testio_mod });
    const run_testio_tests = b.addRunArtifact(testio_tests);

    const a2a_example_tests = b.addTest(.{ .root_module = a2a_mod });
    const run_a2a_example_tests = b.addRunArtifact(a2a_example_tests);

    // The interoperability participants carry test blocks of their own, for
    // the same reason the examples do: the decoding each one owns outside the
    // library — the MCP participant's protocol version member and its
    // `tools/list` name view, the A2A participant's command line — is the code
    // that decides whether a run against a real SDK reaches its handshake at
    // all, and a defect in it is a failed exchange rather than a reported
    // difference. Each root reuses the module the installed executable is
    // built from, so the participant a test covers and the participant the
    // supervisor starts are one module instance rather than two copies.
    const a2a_interop_tests = b.addTest(.{ .root_module = a2a_interop_mod });
    const run_a2a_interop_tests = b.addRunArtifact(a2a_interop_tests);
    const mcp_interop_tests = b.addTest(.{ .root_module = mcp_interop_mod });
    const run_mcp_interop_tests = b.addRunArtifact(mcp_interop_tests);
    const mcp_current_interop_tests = b.addTest(.{ .root_module = mcp_current_interop_mod });
    const run_mcp_current_interop_tests = b.addRunArtifact(mcp_current_interop_tests);
    const acp_interop_tests = b.addTest(.{ .root_module = acp_interop_mod });
    const run_acp_interop_tests = b.addRunArtifact(acp_interop_tests);

    const test_step = b.step(
        "test",
        "Run unit tests, the golden vectors, the example tests and the interop participants",
    );
    // Guest runners use the same binaries as `test`, not a codec-only subset.
    // The manifest is generated from this one registry so adding a root cannot
    // leave the exported suite or its guest runner behind.
    const artifacts_step = b.step(
        "test-artifacts",
        "Install every test binary for a guest runner without executing it",
    );
    const suites = [_]struct {
        name: []const u8,
        binary: *std.Build.Step.Compile,
        run: *std.Build.Step.Run,
    }{
        .{ .name = "library", .binary = lib_unit_tests, .run = run_lib_unit_tests },
        .{ .name = "golden", .binary = golden_tests, .run = run_golden_tests },
        .{ .name = "loopback", .binary = loopback_tests, .run = run_loopback_tests },
        .{ .name = "runtime", .binary = runtime_example_tests, .run = run_runtime_example_tests },
        .{ .name = "http", .binary = http_example_tests, .run = run_http_example_tests },
        .{ .name = "sessions", .binary = sessions_example_tests, .run = run_sessions_example_tests },
        .{ .name = "bench", .binary = bench_tests, .run = run_bench_tests },
        .{ .name = "bench-codec", .binary = bench_codec_tests, .run = run_bench_codec_tests },
        .{ .name = "bench-runtime", .binary = bench_runtime_tests, .run = run_bench_runtime_tests },
        .{ .name = "testio", .binary = testio_tests, .run = run_testio_tests },
        .{ .name = "a2a", .binary = a2a_example_tests, .run = run_a2a_example_tests },
        .{ .name = "a2a-interop", .binary = a2a_interop_tests, .run = run_a2a_interop_tests },
        .{ .name = "mcp-interop", .binary = mcp_interop_tests, .run = run_mcp_interop_tests },
        .{
            .name = "mcp-current-interop",
            .binary = mcp_current_interop_tests,
            .run = run_mcp_current_interop_tests,
        },
        .{ .name = "acp-interop", .binary = acp_interop_tests, .run = run_acp_interop_tests },
    };
    var manifest = std.ArrayList(u8).empty;
    for (suites) |suite| {
        // std.testing.tmpDir is relative to cwd, not --cache-dir. Keep fixture
        // writes in the caller's cache rather than beside the source checkout.
        suite.run.setCwd(.{ .cwd_relative = b.cache_root.path.? });
        test_step.dependOn(&suite.run.step);
        const install = b.addInstallArtifact(suite.binary, .{
            .dest_dir = .{ .override = .prefix },
            .dest_sub_path = b.fmt("tests/{s}", .{suite.name}),
        });
        artifacts_step.dependOn(&install.step);
        manifest.appendSlice(b.allocator, suite.name) catch @panic("OOM");
        manifest.append(b.allocator, '\n') catch @panic("OOM");
    }
    const manifest_file = b.addWriteFiles().add("manifest", manifest.items);
    artifacts_step.dependOn(&b.addInstallFileWithDir(manifest_file, .prefix, "tests/manifest").step);

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
    run_testkit_tests.setCwd(.{ .cwd_relative = b.cache_root.path.? });

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
