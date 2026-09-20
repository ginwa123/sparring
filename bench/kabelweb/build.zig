const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kw_dep = b.dependency("kabelweb", .{
        .target = target,
        .optimize = optimize,
    });
    const kw_mod = kw_dep.module("kabelweb");

    const exe = b.addExecutable(.{
        .name = "kabelweb-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kabelweb", .module = kw_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the kabelweb bench server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
