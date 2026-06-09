// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "hawk_binary",
        .root_module = root_mod,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 2, .patch = 0 },
    });

    // gawkapi.h include path auto-detection
    const gawk_include = b.option(
        []const u8,
        "gawk-include",
        "Path to gawkapi.h directory",
    ) orelse findGawkInclude(b) orelse "";

    if (gawk_include.len > 0) {
        lib.root_module.addIncludePath(.{ .cwd_relative = gawk_include });
    } else {
        @panic("gawkapi.h not found. Set -Dgawk-include=/path/to/gawk/include or GAWK_INCLUDE_PATH");
    }

    b.installArtifact(lib);

    // Zig unit tests (binary.zig only, no gawk needed)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/binary_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const src_mod = b.createModule(.{
        .root_source_file = b.path("src/binary.zig"),
    });
    test_mod.addImport("binary", src_mod);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
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
