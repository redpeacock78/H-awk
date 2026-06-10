// libs/net/build.zig
// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/http_parser.zig"),
    });
    const pool_mod = b.createModule(.{
        .root_source_file = b.path("src/conn_pool.zig"),
    });
    const loop_mod = b.createModule(.{
        .root_source_file = b.path("src/event_loop.zig"),
    });
    loop_mod.addImport("http_parser", parser_mod);
    loop_mod.addImport("conn_pool", pool_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/net_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("http_parser", parser_mod);
    test_mod.addImport("conn_pool", pool_mod);
    test_mod.addImport("event_loop", loop_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
