// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const multipart_mod = b.createModule(.{
        .root_source_file = b.path("src/multipart.zig"),
    });

    // Unit tests — no gawk needed, no root.zig dependency
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/multipart_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("multipart", multipart_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Dylib build — requires gawkapi.h and src/root.zig (Task 3)
    const gawk_include = b.option(
        []const u8,
        "gawk-include",
        "Path to gawkapi.h directory",
    ) orelse findGawkInclude(b) orelse "";

    if (gawk_include.len == 0) return; // skip dylib if gawk not found

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("../_common/gawk_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ffi_mod.addIncludePath(.{ .cwd_relative = gawk_include });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("gawk_ffi", ffi_mod);
    root_mod.addImport("multipart", multipart_mod);

    const lib = b.addLibrary(.{
        .name = "hawk_multipart",
        .root_module = root_mod,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 3, .patch = 0 },
    });
    b.installArtifact(lib);
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
