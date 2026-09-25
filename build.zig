// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ui = b.dependency("fluxion_ui", .{ .target = target, .optimize = optimize });
    const text = b.dependency("fluxion_text", .{ .target = target, .optimize = optimize });

    // A program that has fluxion-ui already builds `src/root.zig` over its
    // own instead, so that the two are one package and one `Ui` type.
    const mod = b.addModule("fluxion_code", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_ui", .module = ui.module("fluxion_ui") },
            .{ .name = "fluxion_text", .module = text.module("fluxion_text") },
        },
    });

    const tests = b.addTest(.{ .name = "fluxion-code-tests", .root_module = mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
