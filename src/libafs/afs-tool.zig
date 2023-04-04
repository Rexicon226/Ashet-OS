const std = @import("std");
const afs = @import("afs.zig");
const args_parser = @import("args");

var verbose: bool = true;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cli = args_parser.parseWithVerbForCurrentProcess(CliOptions, CliVerb, allocator, .print) catch return 1;
    defer cli.deinit();

    if (cli.options.help) {
        try usage(std.io.getStdOut());
        return 0;
    }

    verbose = cli.options.verbose;

    var image_file_name = cli.options.image orelse {
        try std.io.getStdErr().writeAll("Missing option --image!\n");
        return 1;
    };

    var image_file = try std.fs.cwd().openFile(image_file_name, .{ .mode = .read_write });
    defer image_file.close();

    const image_file_stat = try image_file.stat();

    if (image_file_stat.size % @sizeOf(Block) != 0) {
        try std.io.getStdErr().writeAll("Image file does not have a size that is a multiple of 512!\n");
        return 1;
    }

    var block_device = BlockDevice{
        .file = image_file,
        .block_count = std.math.cast(u32, image_file_stat.size / @sizeOf(Block)) orelse return error.DiskTooLarge,
    };

    if (block_device.block_count < 8) {
        try std.io.getStdErr().writeAll("Image file is too small. Requires at least 4096 bytes size.\n");
        return 1;
    }

    const verb: CliVerb = cli.verb orelse {
        try usage(std.io.getStdErr());
        return 1;
    };

    if (verb == .format) {
        if (cli.positionals.len > 1) {
            return try usageError("format <root> only accepts none or a single positional argument!");
        }

        afs.format(block_device.interface(), std.time.nanoTimestamp()) catch |err| {
            try std.io.getStdErr().writeAll(switch (err) {
                error.DeviceTooSmall => "error: the device does not contain enough blocks.\n",
                error.OperationTimeout => "error: disk timeout.\n",
                error.DeviceError => "error: i/o failure\n",
                error.WriteProtected => unreachable,
            });
            return 1;
        };

        if (cli.positionals.len > 0) {
            var dir = try std.fs.cwd().openIterableDir(cli.positionals[0], .{});
            defer dir.close();

            var fs = try FileSystem.init(block_device.interface());
            try copyDirectoryToDisk(&fs, dir, fs.root_directory);
        }

        return 0;
    }

    var fs = FileSystem.init(block_device.interface()) catch |err| {
        try std.io.getStdErr().writeAll(switch (err) {
            error.OperationTimeout => "error: operation timeout\n",
            error.WriteProtected => unreachable,
            error.NoFilesystem => "error: image does not contain a file system\n",
            error.CorruptFileSystem => "error: corrupt file system\n",
            error.UnsupportedVersion => "error: unsupported file system version\n",
            error.DeviceError => "error: i/o failure\n",
        });
        return 1;
    };

    switch (verb) {
        .ls => @panic("ls not implemented yet!"),
        .tree => |opt| {
            const dir = if (cli.positionals.len == 1)
                try resolvePath(&fs, cli.positionals[0])
            else
                fs.root_directory;

            try printTreeListingRecursive(&fs, dir, 0, opt.depth orelse std.math.maxInt(usize));
        },
        .mv => @panic("mv not implemented yet!"),
        .rm => @panic("rm not implemented yet!"),
        .put => @panic("put not implemented yet!"),
        .get => @panic("get not implemented yet!"),
        .fsck => @panic("fsck not implemented yet!"),
        .format => unreachable,
    }

    return 0;
}

fn resolvePath(fs: *FileSystem, path: []const u8) !afs.DirectoryHandle {
    _ = fs;
    _ = path;
    return error.NotImplementedYet;
}

fn printTreeListingRecursive(fs: *FileSystem, dir: afs.DirectoryHandle, depth: usize, limit: usize) !void {
    const indent = 3 * depth;

    var stdout = std.io.getStdOut();
    if (depth >= limit) {
        try stdout.writer().writeByteNTimes(' ', indent);
        try stdout.writer().writeAll("...\n");
        return;
    }

    var iter = try fs.iterate(dir);
    while (try iter.next()) |entry| {
        try stdout.writer().writeByteNTimes(' ', indent);
        try stdout.writer().print("- {s}", .{entry.name()});
        switch (entry.handle) {
            .file => try stdout.writeAll("\n"),
            .directory => |subdir| {
                try stdout.writeAll("/\n");

                try printTreeListingRecursive(fs, subdir, depth + 1, limit);
            },
        }
    }
}

const CliOptions = struct {
    verbose: bool = false,
    help: bool = false,
    image: ?[]const u8 = null,

    pub const shorthands = .{
        .h = "help",
        .i = "image",
        .v = "verbose",
    };
};

const CliVerb = union(enum) {
    ls: struct {
        human: bool = false,
        list: bool = false,
        pub const shorthands = .{
            .l = "list",
            .h = "human",
        };
    },
    tree: struct {
        depth: ?usize = null,
        pub const shorthands = .{
            .d = "depth",
        };
    },
    mv: struct {
        //
        pub const shorthands = .{};
    },
    rm: struct {
        recursive: bool = false,

        pub const shorthands = .{
            .r = "recursive",
        };
    },
    put: struct {
        recursive: bool = false,

        pub const shorthands = .{
            .r = "recursive",
        };
    },
    get: struct {
        recursive: bool = false,

        pub const shorthands = .{
            .r = "recursive",
        };
    },
    fsck: struct {
        //
        pub const shorthands = .{};
    },
    format: struct {
        //
        pub const shorthands = .{};
    },
};

fn usageError(msg: []const u8) !u8 {
    try std.io.getStdErr().writer().print("error: {s}\n", .{msg});
    return 1;
}

fn usage(stream: std.fs.File) !void {
    const writer = stream.writer();

    try writer.writeAll(
        \\afs-tool [-v] [-i <image>] <action> <args…>
        \\
        \\Options are:
        \\  -v, --verbose      - Outputs more information on what's happening.
        \\  -h, --help         - Prints this help text to stdout.
        \\  -i, --image <file> - Selects <file> as the image file that is used.
        \\
        \\Available actions are:
        \\  ls <path> [-h] [-l]
        \\    Lists all files at the given <path>.
        \\
        \\    -h, --human      - Prints file sizes human-readable.
        \\    -l, --list       - Prints a list of files including file size and change dates.
        \\
        \\  tree <path> [-d <depth>]
        \\    Prints the given path in a nice tree structure.
        \\
        \\    -d, --depth <l>  - Only prints the tree to a depth of <l> levels.
        \\
        \\  mv <old> <new>
        \\    Moves a file inside the file system from <old> to <new>.
        \\
        \\  rm <path> [-r]
        \\    Deletes the file or directory <path>.
        \\
        \\    -r, --recursive  - Deletes the directory recursively and all subdirs.
        \\
        \\  put <host> <inner> [-r]
        \\    Copies a file from the <host> filesystem into the <inner> path.
        \\
        \\    -r, --recursive  - Copies the given directory recursively.
        \\
        \\  get <inner> <host> [-r]
        \\    Copies a file from the <inner> filesystem to the <host> path.
        \\
        \\    -r, --recursive  - Copies the given directory recursively.
        \\
        \\  fsck
        \\    Checks for file system integrity
        \\
        \\  format [<root>]
        \\    Formats a new file system. If <root> is given, it will be copied
        \\    into the filesystem as the initial root contents.
        \\
    );
}

const FileSystem = afs.FileSystem;

const Block = afs.Block;

const BlockDevice = struct {
    const BD = @This();

    file: std.fs.File,
    block_count: u32,

    pub fn interface(bd: *BD) afs.BlockDevice {
        return afs.BlockDevice{
            .object = bd,
            .vtable = &vtable,
        };
    }

    fn fromCtx(ctx: *anyopaque) *BD {
        return @ptrCast(*BD, @alignCast(@alignOf(BD), ctx));
    }

    fn getBlockCount(ctx: *anyopaque) u32 {
        return fromCtx(ctx).block_count;
    }
    fn writeBlock(ctx: *anyopaque, offset: u32, block: *const Block) !void {
        // std.debug.print("write block {}:\n", .{offset});
        const bd = fromCtx(ctx);

        bd.file.seekTo(512 * offset) catch |err| {
            std.log.scoped(.image).err("{s}", .{@errorName(err)});
            return error.DeviceError;
        };
        bd.file.writer().writeAll(block) catch |err| {
            std.log.scoped(.image).err("{s}", .{@errorName(err)});
            return error.DeviceError;
        };
    }

    fn readBlock(ctx: *anyopaque, offset: u32, block: *Block) !void {
        // std.debug.print("read block {}\n", .{offset});
        const bd = fromCtx(ctx);

        bd.file.seekTo(512 * offset) catch |err| {
            std.log.scoped(.image).err("{s}", .{@errorName(err)});
            return error.DeviceError;
        };
        bd.file.reader().readNoEof(block) catch |err| {
            std.log.scoped(.image).err("{s}", .{@errorName(err)});
            return error.DeviceError;
        };
    }

    const vtable = afs.BlockDevice.VTable{
        .getBlockCountFn = getBlockCount,
        .writeBlockFn = writeBlock,
        .readBlockFn = readBlock,
    };
};

fn copyDirectoryToDisk(fs: *FileSystem, src_dir: std.fs.IterableDir, target_dir: afs.DirectoryHandle) !void {
    var iter = src_dir.iterate();

    while (try iter.next()) |_entry| {
        const entry: std.fs.IterableDir.Entry = _entry;

        var realpath_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;

        if (verbose) {
            std.log.info("copying {s}...", .{
                try src_dir.dir.realpath(entry.name, &realpath_buffer),
            });
        }

        switch (entry.kind) {
            .Directory => {
                var src_child_dir = try src_dir.dir.openIterableDir(entry.name, .{});
                defer src_child_dir.close();

                var dst_child_dir = try fs.createDirectory(target_dir, entry.name, std.time.nanoTimestamp());

                try copyDirectoryToDisk(fs, src_child_dir, dst_child_dir);
            },
            .File => {
                var src_file = try src_dir.dir.openFile(entry.name, .{});
                defer src_file.close();

                var stat = try src_file.stat();

                var dst_file = try fs.createFile(target_dir, entry.name, std.time.nanoTimestamp());
                try fs.resizeFile(dst_file, stat.size);

                var block_data: [8192]u8 = undefined;
                var i: u64 = 0;
                while (i < stat.size) {
                    const len = try src_file.readAll(&block_data);
                    if (len == 0)
                        return error.UnexpectedEndOfFile;
                    const len2 = try fs.writeData(dst_file, i, block_data[0..len]);
                    std.debug.assert(len == len2); // we should always have enough size for this
                    i += len;
                }
            },

            else => std.log.err("cannot copy {s}: {s} is not a supported file type!", .{
                try src_dir.dir.realpath(entry.name, &realpath_buffer),
                @tagName(entry.kind),
            }),
        }
    }
}
