const std = @import("std");
const abiBuild = @import("ashet-abi");
const Platform = abiBuild.Platform;

pub const Machine = @import("port/machine_id.zig").MachineID;

pub fn build(b: *std.Build) void {
    // Options:
    const machine_id = b.option(Machine, "machine", "Selects the machine for which the kernel should be built.") orelse @panic("-Dmachine required!");
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // Target configuration:
    const machine_config = machine_info_map.get(machine_id);
    const platform_config = platform_info_map.get(machine_config.platform);

    const kernel_target = b.resolveTargetQuery(machine_config.target);
    const platform_id = machine_config.platform;

    // Dependencies:
    const abi_dep = b.dependency("abi", .{});
    const virtio_dep = b.dependency("virtio", .{});
    const ashet_fs_dep = b.dependency("ashet_fs", .{});
    const ashet_std_dep = b.dependency("ashet_std", .{});
    const args_dep = b.dependency("args", .{});
    const network_dep = b.dependency("network", .{});
    const vnc_dep = b.dependency("vnc", .{});
    const lwip_dep = b.dependency("lwip", .{ .target = kernel_target, .optimize = .ReleaseSafe });
    const libc_dep = b.dependency("foundation-libc", .{ .target = kernel_target, .optimize = optimize });
    const zfat_dep = b.dependency("zfat", .{
        .@"no-libc" = true,
        .target = kernel_target,
        .optimize = optimize,
        .max_long_name_len = @as(u8, 121),
        .code_page = .us,
        .@"volume-count" = @as(u8, 8),
        .@"static-rtc" = @as([]const u8, "2022-07-10"), // TODO: Fix this
        .mkfs = true,
    });

    // Modules:

    const abi_mod = abi_dep.module("ashet-abi");
    const virtio_mod = virtio_dep.module("virtio");
    const ashet_fs_mod = ashet_fs_dep.module("ashet-fs");
    const ashet_std_mod = ashet_std_dep.module("ashet-std");
    const args_mod = args_dep.module("args");
    const network_mod = network_dep.module("network");
    const vnc_mod = vnc_dep.module("vnc");
    const zfat_mod = zfat_dep.module("zfat");
    const lwip_mod = lwip_dep.module("lwip");

    // Build:

    const machine_info_module = blk: {
        const machine_info = renderMachineInfo(
            b,
            machine_id,
            platform_id,
        ) catch @panic("out of memory!");

        const write_file_step = b.addWriteFile("machine-info.zig", machine_info);

        const module = b.createModule(.{
            .root_source_file = write_file_step.files.items[0].getPath(),
        });

        break :blk module;
    };

    const kernel_mod = b.createModule(.{
        .target = kernel_target,
        .optimize = optimize,
        .root_source_file = b.path("main.zig"),
        .imports = &.{
            .{ .name = "machine-info", .module = machine_info_module },
            .{ .name = "ashet-abi", .module = abi_mod },
            .{ .name = "ashet-std", .module = ashet_std_mod },
            .{ .name = "virtio", .module = virtio_mod },
            .{ .name = "ashet-fs", .module = ashet_fs_mod },
            .{ .name = "args", .module = args_mod },
            .{ .name = "fatfs", .module = zfat_mod },
            .{ .name = "vnc", .module = vnc_mod },
            // .{ .name = "ashet", .module = options.modules.libashet },

            // only required on hosted instances:
            .{ .name = "network", .module = network_mod },
            // .{ .name = "sdl", .module = options.modules.sdl },
        },
    });

    kernel_mod.addImport("lwip", lwip_mod);
    kernel_mod.addIncludePath(b.path("components/network/include"));
    lwip_mod.addIncludePath(b.path("components/network/include"));
    for (lwip_mod.include_dirs.items) |dir| {
        kernel_mod.include_dirs.append(b.allocator, dir) catch @panic("out of memory");
    }

    const start_file = if (machine_id.is_hosted())
        b.path("port/platform/startup/hosted.zig")
    else
        b.path("port/platform/startup/generic.zig");

    const kernel_exe = b.addExecutable(.{
        .name = "ashet-os",
        .root_source_file = start_file,
        .target = kernel_target,
        .optimize = optimize,
    });

    kernel_exe.step.dependOn(machine_info_module.root_source_file.?.generated.file.step);
    kernel_exe.root_module.addImport("kernel", kernel_mod);

    // TODO(fqu): kernel_exe.root_module.code_model = .small;
    kernel_exe.bundle_compiler_rt = true;
    kernel_exe.rdynamic = true; // Prevent the compiler from garbage collecting exported symbols
    kernel_exe.root_module.single_threaded = (kernel_exe.rootModuleTarget().os.tag == .freestanding);
    kernel_exe.root_module.omit_frame_pointer = false;
    kernel_exe.root_module.strip = false; // never strip debug info
    if (optimize == .Debug) {
        // we always want frame pointers in debug build!
        kernel_exe.root_module.omit_frame_pointer = false;
    }

    kernel_exe.setLinkerScriptPath(b.path(machine_config.linker_script));

    // for (options.platforms.include_paths.get(machine_spec.platform).items) |path| {
    //     kernel_exe.addSystemIncludePath(path);
    // }

    _ = platform_config;

    if (machine_id.is_hosted()) {
        kernel_mod.linkSystemLibrary("sdl2", .{
            .use_pkg_config = .force,
            .search_strategy = .mode_first,
        });
        kernel_exe.linkage = .dynamic;
        kernel_exe.linkLibC();
    } else {
        const libc = libc_dep.artifact("foundation");

        lwip_mod.addIncludePath(libc.getEmittedIncludeTree());
        zfat_mod.addIncludePath(libc.getEmittedIncludeTree());

        kernel_exe.linkLibrary(libc);
    }

    b.installArtifact(kernel_exe);
}

const PlatformConfig = struct {
    source_file: []const u8,
};

const MachineConfig = struct {
    platform: Platform,
    target: std.Target.Query,

    linker_script: []const u8,
    source_file: []const u8,
};

fn constructTargetQuery(spec: std.Target.Query) std.Target.Query {
    var base: std.Target.Query = spec;

    if (base.os_tag == null) {
        std.debug.assert(base.dynamic_linker.len == 0);
        std.debug.assert(base.ofmt == null);
        base.os_tag = .freestanding;
        base.ofmt = .elf;
    } else {
        std.debug.assert(base.os_tag != .freestanding);
        // We're in a hosted environment, explicit os is set
    }

    return base;
}

const platform_info_map = std.EnumArray(Platform, PlatformConfig).init(.{
    .x86 = .{
        .source_file = "port/platform/x86.zig",
    },
    .arm = .{
        .source_file = "port/platform/arm.zig",
    },
    .rv32 = .{
        .source_file = "port/platform/riscv.zig",
    },
});

const machine_info_map = std.EnumArray(Machine, MachineConfig).init(.{
    .@"pc-bios" = .{
        .platform = .x86,
        .target = constructTargetQuery(generic_x86),

        .source_file = "port/machine/bios_pc/bios_pc.zig",
        .linker_script = "port/machine/bios_pc/linker.ld",
    },

    .@"qemu-virt-rv32" = .{
        .platform = .rv32,
        .target = constructTargetQuery(generic_rv32),

        .source_file = "port/machine/rv32_virt/rv32_virt.zig",
        .linker_script = "port/machine/rv32_virt/linker.ld",
    },

    .@"qemu-virt-arm" = .{
        .platform = .arm,
        .target = constructTargetQuery(generic_arm),

        .source_file = "port/machine/arm_virt/arm_virt.zig",
        .linker_script = "port/machine/arm_virt/linker.ld",
    },

    .@"hosted-x86-linux" = .{
        .platform = .x86,
        .target = constructTargetQuery(.{
            .cpu_arch = .x86,
            .os_tag = .linux,
            .abi = .gnu,
            .cpu_model = .{ .explicit = &std.Target.x86.cpu.i686 },
            .dynamic_linker = std.Target.DynamicLinker.init("/nix/store/xlyscnvzz5l3pkvf280qp5czg387b98f-glibc-2.38-44/lib/ld-linux.so.2"),
        }),

        .source_file = "port/machine/linux_pc/linux_pc.zig",
        .linker_script = "port/machine/linux_pc/linker.ld",
    },
});

const generic_x86 = .{
    .cpu_arch = .x86,
    .abi = .eabi,
    .cpu_model = .{ .explicit = &std.Target.x86.cpu.i686 },
    .cpu_features_add = std.Target.x86.featureSet(&.{
        .soft_float,
    }),
    .cpu_features_sub = std.Target.x86.featureSet(&.{
        .x87,
    }),
};

const generic_arm =
    .{
    .cpu_arch = .thumb,
    .abi = .eabi,
    .cpu_model = .{
        // .explicit = &std.Target.arm.cpu.cortex_a7, // this seems to be a pretty reasonable base line
        .explicit = &std.Target.arm.cpu.generic,
    },
    .cpu_features_add = std.Target.arm.featureSet(&.{
        .v7a,
    }),
    .cpu_features_sub = std.Target.arm.featureSet(&.{
        .v7a, // this is stupid, but it keeps out all the neon stuff we don't wnat

        // drop everything FPU related:
        .neon,
        .neonfp,
        .neon_fpmovs,
        .fp64,
        .fpregs,
        .fpregs64,
        .vfp2,
        .vfp2sp,
        .vfp3,
        .vfp3d16,
        .vfp3d16sp,
        .vfp3sp,
    }),
};

const generic_rv32 = .{
    .cpu_arch = .riscv32,
    .abi = .eabi,
    .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
    .cpu_features_add = std.Target.riscv.featureSet(&[_]std.Target.riscv.Feature{
        .c,
        .m,
        .reserve_x4, // Don't allow LLVM to use the "tp" register. We want that for our own purposes
    }),
};

fn renderMachineInfo(
    b: *std.Build,
    machine_id: Machine,
    platform_id: Platform,
    // machine_spec: *const build_targets.MachineSpec,
    // platform_spec: *const build_targets.PlatformSpec,
) ![]const u8 {
    var stream = std.ArrayList(u8).init(b.allocator);
    defer stream.deinit();

    const writer = stream.writer();

    try writer.writeAll("//! This is a machine-generated description of the Ashet OS target machine.\n\n");

    try writer.print("pub const machine_id = .{};\n", .{
        std.zig.fmtId(@tagName(machine_id)),
    });
    try writer.print("pub const machine_name = \"{}\";\n", .{
        std.zig.fmtEscapes(machine_id.get_display_name()),
    });
    try writer.print("pub const platform_id = .{};\n", .{
        std.zig.fmtId(@tagName(platform_id)),
    });
    try writer.print("pub const platform_name = \"{}\";\n", .{
        std.zig.fmtEscapes(platform_id.get_display_name()),
    });

    return try stream.toOwnedSlice();
}
