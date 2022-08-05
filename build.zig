const std = @import("std");

const FatFS = @import("vendor/zfat/Sdk.zig");

const pkgs = struct {
    pub const ashet = std.build.Pkg{
        .name = "ashet",
        .source = .{ .path = "src/libashet/main.zig" },
        .dependencies = &.{ abi, text_editor },
    };

    pub const abi = std.build.Pkg{
        .name = "ashet-abi",
        .source = .{ .path = "src/abi/abi.zig" },
    };

    pub const hal_virt_riscv32 = std.build.Pkg{
        .name = "hal",
        .source = .{ .path = "src/kernel/hal/virt-riscv32/hal.zig" },
    };

    pub const hal_virt_arm = std.build.Pkg{
        .name = "hal",
        .source = .{ .path = "src/kernel/hal/virt-arm/hal.zig" },
    };

    pub const hal_ashet = std.build.Pkg{
        .name = "hal",
        .source = .{ .path = "src/kernel/hal/ashet/hal.zig" },
    };

    pub const hal_microvm = std.build.Pkg{
        .name = "hal",
        .source = .{ .path = "src/kernel/hal/microvm/hal.zig" },
    };

    pub const text_editor = std.build.Pkg{
        .name = "text-editor",
        .source = .{ .path = "vendor/text-editor/src/TextEditor.zig" },
        .dependencies = &.{ ziglyph, zigstr },
    };

    const ziglyph = std.build.Pkg{
        .name = "ziglyph",
        .source = .{ .path = "vendor/text-editor/vendor/ziglyph/src/ziglyph.zig" },
    };
    const zigstr = std.build.Pkg{
        .name = "zigstr",
        .source = .{ .path = "vendor/text-editor/vendor/zigstr/src/Zigstr.zig" },
        .dependencies = &.{ziglyph},
    };

    pub const zigimg = std.build.Pkg{
        .name = "zigimg",
        .source = .{ .path = "vendor/zigimg/zigimg.zig" },
    };
};

const PlatformConfig = struct {
    target: std.zig.CrossTarget,
    hal: std.build.Pkg,
    linkerscript: std.build.FileSource,
};

pub const Target = union(enum) {
    riscv32: RiscvPlatform,
    arm: ArmPlatform,
    x86: X86Platform,

    pub fn resolve(target: Target) PlatformConfig {
        switch (target) {
            .riscv32 => |platform| {
                const cpu = std.zig.CrossTarget{
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
                return switch (platform) {
                    .virt => PlatformConfig{
                        .target = cpu,
                        .hal = pkgs.hal_virt_riscv32,
                        .linkerscript = .{ .path = "src/kernel/hal/virt-riscv32/linker.ld" },
                    },
                    .ashet => PlatformConfig{
                        .target = cpu,
                        .hal = pkgs.hal_ashet,
                        .linkerscript = .{ .path = "" },
                    },
                };
            },
            .arm => |platform| {
                const cpu = std.zig.CrossTarget{
                    .cpu_arch = .arm,
                    .os_tag = .freestanding,
                    .abi = .eabi,
                    .cpu_model = .{ .explicit = &std.Target.arm.cpu.generic },
                };
                return switch (platform) {
                    .virt => PlatformConfig{
                        .target = cpu,
                        .hal = pkgs.hal_virt_arm,
                        .linkerscript = .{ .path = "" },
                    },
                };
            },
            .x86 => |platform| {
                const cpu = std.zig.CrossTarget{
                    .cpu_arch = .i386,
                    .os_tag = .freestanding,
                    .abi = .eabi,
                    .cpu_model = .{ .explicit = &std.Target.x86.cpu.@"i686" },
                };
                return switch (platform) {
                    .microvm => PlatformConfig{
                        .target = cpu,
                        .hal = pkgs.hal_microvm,
                        .linkerscript = .{ .path = "" },
                    },
                };
            },
        }
    }
};

pub const TargetId = std.meta.Tag(Target);

pub const RiscvPlatform = enum {
    virt,
    ashet,
};

pub const ArmPlatform = enum {
    virt,
};

pub const X86Platform = enum {
    microvm,
};

const AshetContext = struct {
    b: *std.build.Builder,
    mkicon: *std.build.LibExeObjStep,
    target: std.zig.CrossTarget,

    fn createAshetApp(ctx: AshetContext, name: []const u8, source: []const u8, maybe_icon: ?[]const u8) *std.build.LibExeObjStep {
        const exe = ctx.b.addExecutable(ctx.b.fmt("{s}.app", .{name}), source);

        exe.omit_frame_pointer = false; // this is useful for debugging
        exe.single_threaded = true; // AshetOS doesn't support multithreading in a modern sensegs
        exe.pie = true; // AshetOS requires PIE executables
        exe.force_pic = true; // which need PIC code
        exe.linkage = .static; // but everything is statically linked, we don't support shared objects

        exe.setLinkerScriptPath(.{ .path = "src/libashet/application.ld" });
        exe.setTarget(ctx.target);
        exe.addPackage(pkgs.ashet);
        exe.install();

        const install_step = ctx.b.addInstallArtifact(exe);
        install_step.dest_dir = .{ .custom = "apps" };
        ctx.b.getInstallStep().dependOn(&install_step.step);

        if (maybe_icon) |src_icon| {
            const mkicon = ctx.mkicon.run();

            mkicon.addArg(src_icon);

            mkicon.addArg(ctx.b.fmt("zig-out/apps/{s}.icon", .{name}));

            ctx.b.getInstallStep().dependOn(&mkicon.step);
        }

        return exe;
    }
};

pub fn build(b: *std.build.Builder) void {
    const fatfs_config = FatFS.Config{
        .volumes = .{
            // .named = &.{"CF0"},
            .count = 8,
        },
        .rtc = .{
            .static = .{ .year = 2022, .month = .jul, .day = 10 },
        },
    };

    const mode = b.standardReleaseOptions();

    const target_id = b.option(TargetId, "cpu", "The target cpu architecture") orelse .riscv32;
    const system_target: Target = switch (target_id) {
        .riscv32 => Target{
            .riscv32 = b.option(RiscvPlatform, "platform", "The target machine for the os") orelse .virt,
        },
        .arm => Target{
            .arm = b.option(ArmPlatform, "platform", "The target machine for the os") orelse .virt,
        },
        .x86 => Target{
            .x86 = b.option(X86Platform, "platform", "The target machine for the os") orelse .microvm,
        },
    };
    const system_platform = system_target.resolve();

    const tool_mkicon = b.addExecutable("tool_mkicon", "tools/mkicon.zig");
    tool_mkicon.addPackage(pkgs.zigimg);
    tool_mkicon.addPackage(pkgs.abi);
    tool_mkicon.install();

    const experiment = b.addExecutable("experiment", "tools/fs-experiments.zig");
    experiment.addPackage(FatFS.getPackage(b, "fatfs", fatfs_config));
    FatFS.link(experiment, fatfs_config);
    experiment.linkLibC();
    experiment.install();

    const kernel_exe = b.addExecutable("ashet-os", "src/kernel/main.zig");
    kernel_exe.single_threaded = true;
    kernel_exe.omit_frame_pointer = false;
    if (mode == .Debug) {
        // we always want frame pointers in debug build!
        kernel_exe.omit_frame_pointer = false;
    }
    kernel_exe.setTarget(system_platform.target);
    kernel_exe.setBuildMode(mode);
    kernel_exe.addPackage(system_platform.hal);
    kernel_exe.addPackage(pkgs.abi);
    kernel_exe.addPackage(std.build.Pkg{
        .name = "libashet",
        .source = .{ .path = "src/libashet/main.zig" },
        .dependencies = &.{ pkgs.abi, pkgs.text_editor },
    });
    kernel_exe.addPackage(FatFS.getPackage(b, "fatfs", fatfs_config));
    kernel_exe.setLinkerScriptPath(system_platform.linkerscript);
    kernel_exe.install();

    // kernel_exe.setLibCFile(std.build.FileSource{ .path = "vendor/libc/libc.txt" });
    kernel_exe.addSystemIncludePath("vendor/libc/include");

    FatFS.link(kernel_exe, fatfs_config);

    const generate_stub_icon = tool_mkicon.run();
    generate_stub_icon.addArg("design/apps/generic.png");
    generate_stub_icon.addArg("src/kernel/data/generic-app.icon");
    kernel_exe.step.dependOn(&generate_stub_icon.step);

    const raw_step = kernel_exe.installRaw("ashet-os.bin", .{
        .format = .bin,
        .pad_to_size = 0x200_0000,
    });

    b.getInstallStep().dependOn(&raw_step.step);

    // dd if=/dev/zero of=zig-out/disk.img bs=512 count=65536
    // mkfs.vfat -n ASHET -S 512 zig-out/disk.img
    // mformat -i zig-out/disk.img -v ASHET
    // ls -hal zig-out/disk.img
    // file zig-out/disk.img

    // Makes sure zig-out/disk.img exists, but doesn't touch the data at all
    const setup_disk_cmd = b.addSystemCommand(&.{
        "fallocate",
        "-l",
        "32M",
        "zig-out/disk.img",
    });

    const run_cmd = b.addSystemCommand(&.{"qemu-system-riscv32"});
    run_cmd.addArgs(&.{
        "-M", "virt",
        "-m",      "32M", // we have *some* overhead on the virt platform
        "-device", "virtio-gpu-device,xres=400,yres=300",
        "-device", "virtio-keyboard-device",
        "-device", "virtio-mouse-device",
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

    var ctx = AshetContext{
        .b = b,
        .mkicon = tool_mkicon,
        .target = system_platform.target,
    };

    {
        const app_shell = ctx.createAshetApp("shell", "src/apps/shell.zig", "design/apps/shell.png");
        app_shell.setBuildMode(mode);

        const app_commander = ctx.createAshetApp("commander", "src/apps/commander.zig", "design/apps/commander.png");
        app_commander.setBuildMode(mode);

        const app_editor = ctx.createAshetApp("editor", "src/apps/dummy.zig", "design/apps/text-editor.png");
        app_editor.setBuildMode(mode);

        const app_browser = ctx.createAshetApp("browser", "src/apps/dummy.zig", "design/apps/browser.png");
        app_browser.setBuildMode(mode);

        const app_music = ctx.createAshetApp("music", "src/apps/music.zig", "design/apps/music.png");
        app_music.setBuildMode(mode);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(system_platform.target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
