const std = @import("std");

const pkgs = struct {
    pub const ashet = std.build.Pkg{
        .name = "ashet",
        .source = .{ .path = "src/libashet/main.zig" },
        .dependencies = &.{abi},
    };

    pub const abi = std.build.Pkg{
        .name = "ashet-abi",
        .source = .{ .path = "src/abi/abi.zig" },
    };

    pub const hal_virt = std.build.Pkg{
        .name = "hal",
        .source = .{ .path = "src/kernel/hal/virt/hal.zig" },
    };

    pub const hal_ashet = std.build.Pkg{
        .name = "hal",
        .source = .{ .path = "src/kernel/hal/ashet/hal.zig" },
    };
};

const target = std.zig.CrossTarget{
    .cpu_arch = .riscv32,
    .os_tag = .freestanding,
    .abi = .eabi,
    .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
    .cpu_features_add = std.Target.riscv.featureSet(&[_]std.Target.riscv.Feature{
        .c,
        .m,
        .reserve_x4, // Don't allow LLVM to use the "tp" register. We want that for our own purposes
    }),
};

fn createAshetApp(b: *std.build.Builder, name: []const u8, source: []const u8) *std.build.LibExeObjStep {
    const exe = b.addExecutable(name, source);

    exe.setTarget(target);
    exe.addPackage(pkgs.ashet);
    exe.setLinkerScriptPath(.{ .path = "src/abi/application.ld" });
    exe.single_threaded = true;

    return exe;
}

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    const kernel_exe = b.addExecutable("ashet-os", "src/kernel/main.zig");
    kernel_exe.single_threaded = true;
    if (mode == .Debug) {
        // we always want frame pointers in debug build!
        kernel_exe.omit_frame_pointer = false;
    }
    kernel_exe.setTarget(target);
    kernel_exe.setBuildMode(mode);
    kernel_exe.addPackage(pkgs.hal_virt);
    kernel_exe.addPackage(pkgs.abi);
    kernel_exe.setLinkerScriptPath(.{ .path = "src/kernel/hal/virt/linker.ld" });
    kernel_exe.install();

    const raw_step = kernel_exe.installRaw("ashet-os.bin", .{
        .format = .bin,
        .pad_to_size = 0x200_0000,
    });

    b.getInstallStep().dependOn(&raw_step.step);

    // Makes sure zig-out/disk.img exists, but doesn't touch the data at all
    const setup_disk_cmd = b.addSystemCommand(&.{
        "fallocate",
        "-l",
        "32M",
        "zig-out/disk.img",
    });

    const run_cmd = b.addSystemCommand(&.{"qemu-system-riscv32"});
    run_cmd.addArgs(&.{
        "-M",      "virt",
        "-m",      "16M",
        "-device", "virtio-gpu-device,xres=400,yres=300",
        "-d",      "guest_errors",
        "-bios",   "none",
        "-drive",  "if=pflash,index=0,file=zig-out/bin/ashet-os.bin,format=raw",
        "-drive",  "if=pflash,index=1,file=zig-out/disk.img,format=raw",
    });
    run_cmd.step.dependOn(&setup_disk_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const shell = createAshetApp(b, "shell", "src/apps/shell.zig");
    shell.setBuildMode(.ReleaseFast);
    shell.install();

    const raw_shell_step = shell.installRaw("shell.bin", .{
        .format = .bin,
    });

    b.getInstallStep().dependOn(&raw_shell_step.step);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
