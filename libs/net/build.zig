// libs/net/build.zig
// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const gawk_include = b.option(
        []const u8,
        "gawk-include",
        "Path to gawkapi.h directory",
    ) orelse findGawkInclude(b) orelse "";

    if (gawk_include.len == 0) {
        @panic("gawkapi.h not found. Set -Dgawk-include=/path/to/gawk/include");
    }

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../_common/gawk_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ffi_mod.addIncludePath(.{ .cwd_relative = gawk_include });

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

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("gawk_ffi", ffi_mod);
    root_mod.addImport("event_loop", loop_mod);

    const lib = b.addLibrary(.{
        .name = "hawk_net",
        .root_module = root_mod,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    b.installArtifact(lib);

    // Unit tests (no gawk needed)
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

    const test_server_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_server_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_server_mod.addImport("event_loop", loop_mod);

    const test_server = b.addExecutable(.{
        .name = "hawk-net-test-server",
        .root_module = test_server_mod,
    });
    b.installArtifact(test_server);
}

fn findGawkInclude(_: *std.Build) ?[]const u8 {
    const candidates = [_][]const u8{
        "/usr/local/include",
        "/opt/homebrew/include/gawk",
        "/usr/local/include/gawk",
        "/usr/include/gawk",
    };
    for (candidates) |p| {
        return p;
    }
    return null;
}
