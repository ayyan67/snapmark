const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "snapmark-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/shim.m"),
        .flags = &.{ "-fobjc-arc" },
        .language = .objective_c,
    });

    exe.linkLibC();
    exe.linkSystemLibrary("objc");
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("CoreText", .{});
    exe.root_module.linkFramework("Carbon", .{});
    exe.root_module.linkFramework("ApplicationServices", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run SnapMark Zig");
    run_step.dependOn(&run_cmd.step);

    const release_step = b.step("release", "Create a macOS .app bundle in zig-out/");
    const release_cmd = b.addSystemCommand(&.{ "bash", "scripts/make_app.sh" });
    release_cmd.step.dependOn(b.getInstallStep());
    release_step.dependOn(&release_cmd.step);

    const dmg_step = b.step("dmg", "Build a DMG from the .app bundle");
    const dmg_cmd = b.addSystemCommand(&.{ "bash", "scripts/make_dmg.sh" });
    dmg_cmd.step.dependOn(&release_cmd.step);
    dmg_step.dependOn(&dmg_cmd.step);

    const acceptance_step = b.step("acceptance", "Generate side-by-side acceptance report");
    const acceptance_cmd = b.addSystemCommand(&.{ "bash", "scripts/acceptance.sh" });
    acceptance_cmd.step.dependOn(&dmg_cmd.step);
    acceptance_step.dependOn(&acceptance_cmd.step);

    const bench_step = b.step("bench", "Run startup/RSS/CPU benchmark harness");
    const bench_cmd = b.addSystemCommand(&.{ "bash", "scripts/bench.sh", "zig-out/bin/snapmark-zig" });
    bench_cmd.step.dependOn(b.getInstallStep());
    bench_step.dependOn(&bench_cmd.step);
}
