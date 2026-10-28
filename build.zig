// `zig build` works where Zig can link against the installed SDK. On macOS 26
// with Zig 0.15.2 it cannot, so use scripts/build.sh there (see README).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const exe = b.addExecutable(.{
        .name = "snapmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/shim.m"),
        .flags = &.{ "-fobjc-arc", "-Wall" },
        .language = .objective_c,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("objc");
    for ([_][]const u8{ "AppKit", "Foundation", "CoreGraphics", "CoreText", "Carbon" }) |framework| {
        exe.root_module.linkFramework(framework, .{});
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run SnapMark").dependOn(&run_cmd.step);

    const app_cmd = b.addSystemCommand(&.{ "bash", "scripts/make_app.sh" });
    app_cmd.step.dependOn(b.getInstallStep());
    b.step("app", "Create zig-out/SnapMark.app").dependOn(&app_cmd.step);

    const dmg_cmd = b.addSystemCommand(&.{ "bash", "scripts/make_dmg.sh" });
    dmg_cmd.step.dependOn(&app_cmd.step);
    b.step("dmg", "Create zig-out/SnapMark.dmg").dependOn(&dmg_cmd.step);

    const bench_cmd = b.addSystemCommand(&.{ "bash", "scripts/bench.sh", "zig-out/bin/snapmark" });
    bench_cmd.step.dependOn(b.getInstallStep());
    b.step("bench", "Run startup/RSS/CPU benchmark harness").dependOn(&bench_cmd.step);
}
