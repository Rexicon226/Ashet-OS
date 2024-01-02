const std = @import("std");

const FatFS = @import("zfat");

const ashet_com = @import("os-common.zig");
const ashet_lwip = @import("lwip.zig");

const build_targets = @import("targets.zig");

pub const KernelOptions = struct {
    optimize: std.builtin.OptimizeMode,
    fatfs_config: FatFS.Config,
    machine_spec: *const build_targets.MachineSpec,
    modules: ashet_com.Modules,
    system_assets: *std.Build.Module,
};

fn renderMachineInfo(
    b: *std.Build,
    machine_spec: *const build_targets.MachineSpec,
    platform_spec: *const build_targets.PlatformSpec,
) ![]const u8 {
    var stream = std.ArrayList(u8).init(b.allocator);
    defer stream.deinit();

    const writer = stream.writer();

    try writer.writeAll("//! This is a machine-generated description of the Ashet OS target machine.\n\n");

    try writer.print("pub const machine_name = \"{}\";\n", .{
        std.zig.fmtEscapes(machine_spec.name),
    });
    try writer.print("pub const platform_name = \"{}\";\n", .{
        std.zig.fmtEscapes(platform_spec.name),
    });

    return try stream.toOwnedSlice();
}

pub fn create(b: *std.Build, options: KernelOptions) *std.Build.Step.Compile {
    const platform_spec = build_targets.getPlatformSpec(options.machine_spec.platform);

    const machine_info_module = blk: {
        const machine_info = renderMachineInfo(
            b,
            options.machine_spec,
            platform_spec,
        ) catch @panic("out of memory!");

        const write_file_step = b.addWriteFile("machine-info.zig", machine_info);

        const module = b.createModule(.{
            .source_file = write_file_step.files.items[0].getPath(),
        });

        break :blk module;
    };

    const platform_module = b.createModule(.{
        .source_file = .{ .path = platform_spec.source_file },
    });

    const machine_module = b.createModule(.{
        .source_file = .{ .path = options.machine_spec.source_file },
        .dependencies = &.{
            .{ .name = "platform", .module = platform_module },
            .{ .name = "args", .module = options.modules.args }, // TODO: Make explicit list of dependencies
        },
    });

    const cguana_dep = b.anonymousDependency("vendor/ziglibc", @import("../../vendor/ziglibc/build.zig"), .{
        .target = platform_spec.target,
        .optimize = .ReleaseSafe,

        .static = true,
        .dynamic = false,
        .start = .none,
        .trace = false,

        .cstd = true,
        .posix = false,
        .gnu = false,
        .linux = false,
    });

    const ashet_libc = cguana_dep.artifact("cguana");

    const kernel_exe = b.addExecutable(.{
        .name = "ashet-os",
        .root_source_file = .{ .path = "src/kernel/main.zig" },
        .target = platform_spec.target,
        .optimize = options.optimize,
    });

    kernel_exe.code_model = .small;
    kernel_exe.bundle_compiler_rt = true;
    kernel_exe.rdynamic = true; // Prevent the compiler from garbage collecting exported symbols
    kernel_exe.single_threaded = true;
    kernel_exe.omit_frame_pointer = false;
    kernel_exe.strip = false; // never strip debug info
    if (options.optimize == .Debug) {
        // we always want frame pointers in debug build!
        kernel_exe.omit_frame_pointer = false;
    }

    kernel_exe.addModule("system-assets", options.system_assets);
    kernel_exe.addModule("ashet-abi", options.modules.ashet_abi);
    kernel_exe.addModule("ashet-std", options.modules.ashet_std);
    kernel_exe.addModule("ashet", options.modules.libashet);
    kernel_exe.addModule("ashet-gui", options.modules.ashet_gui);
    kernel_exe.addModule("virtio", options.modules.virtio);
    kernel_exe.addModule("ashet-fs", options.modules.libashetfs);
    kernel_exe.addModule("args", options.modules.args);
    kernel_exe.addModule("machine-info", machine_info_module);
    kernel_exe.addModule("machine", machine_module);
    kernel_exe.addModule("platform", platform_module);

    kernel_exe.addModule("platform.x86", platform_module);

    kernel_exe.addModule("fatfs", options.modules.fatfs);
    kernel_exe.setLinkerScriptPath(.{ .path = options.machine_spec.linker_script });

    kernel_exe.addSystemIncludePath(.{ .path = "vendor/ziglibc/inc/libc" });

    FatFS.link(kernel_exe, options.fatfs_config);

    kernel_exe.linkLibrary(ashet_libc);

    {
        const lwip = ashet_lwip.create(b, kernel_exe.target, .ReleaseSafe);
        lwip.is_linking_libc = false;
        lwip.strip = false;
        lwip.addSystemIncludePath(.{ .path = "vendor/ziglibc/inc/libc" });
        kernel_exe.linkLibrary(lwip);
        ashet_lwip.setup(kernel_exe);
    }

    return kernel_exe;
}