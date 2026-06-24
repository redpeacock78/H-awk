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

    const gzip_mod = b.createModule(.{
        .root_source_file = b.path("src/gzip.zig"),
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("gawk_ffi", ffi_mod);
    root_mod.addImport("gzip", gzip_mod);

    const lib = b.addLibrary(.{
        .name = "hawk_gzip",
        .root_module = root_mod,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    b.installArtifact(lib);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/gzip_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("gzip", gzip_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn findGawkInclude(b: *std.Build) ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/include/gawk",
        "/usr/local/include/gawk",
        "/usr/local/include",
        "/usr/include/gawk",
    };
    for (candidates) |p| {
        const dir = std.Io.Dir.openDirAbsolute(b.graph.io, p, .{}) catch continue;
        dir.close(b.graph.io);
        return p;
    }
    return null;
}
