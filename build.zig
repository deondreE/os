const std = @import("std");

pub fn build(b: *std.Build) void { // Standard target options allow the person running `zig build` to choose
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86,
            .os_tag = .freestanding,
            .abi = .none,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("opsys", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "opsys", .module = mod },
            },
        }),
    });
    exe.addAssemblyFile(b.path("src/boot.s"));
    exe.setLinkerScript(b.path("linker.ld"));
    exe.entry = .{ .symbol_name = "_start" };
    b.installArtifact(exe);

    const disk_step = b.addSystemCommand(&[_][]const u8{
        "qemu-img",
        "create",
        "-f",
        "raw",
        "zig-out/disk.img",
        "4M",
    });
    disk_step.step.dependOn(b.getInstallStep());

    const qemu_step = b.addSystemCommand(&[_][]const u8{
        "qemu-system-i386",
        "-kernel",
        "zig-out/bin/kernel",
        "-machine",
        "pc",
        "-m",
        "32M",
        "-serial",
        "stdio",
        "-no-reboot",
        "-no-shutdown",
        "-drive",
        "file=zig-out/disk.img,format=raw,index=0,media=disk",
        // "-d",
        // "int,cpu_reset",
        // // "-D",
        // "qemu.log",
    });
    qemu_step.step.dependOn(b.getInstallStep());
    qemu_step.step.dependOn(&disk_step.step);

    const run_step = b.step("run", "Run the app in qu");

    // const run_cmd = b.addRunArtifact(exe);

    run_step.dependOn(&qemu_step.step);
    if (b.args) |args| {
        qemu_step.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
