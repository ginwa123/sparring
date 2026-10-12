const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Compile SQLite from the package's vendored amalgamation instead of
    // linking the distro's libsqlite3. The amalgamation is built with this
    // build's optimize mode (ReleaseFast) and the package's own flags, so
    // it is one variable the benchmark can actually control.
    const sqlite_vendor = b.option(bool, "sqlite-vendor", "Compile ruangsql's vendored SQLite amalgamation instead of linking the system libsqlite3") orelse false;

    const kw_dep = b.dependency("kabelweb", .{
        .target = target,
        .optimize = optimize,
    });
    const kw_mod = kw_dep.module("kabelweb");

    const ruang_dep = b.dependency("ruangsql", .{
        .target = target,
        .optimize = optimize,
        .db_used = "sqlite",
        .@"sqlite-vendor" = sqlite_vendor,
    });
    const ruang_mod = ruang_dep.module("databases");

    const exe = b.addExecutable(.{
        .name = "kabelweb-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kabelweb", .module = kw_mod },
                .{ .name = "databases", .module = ruang_mod },
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
