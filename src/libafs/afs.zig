//!
//! Ashet File System
//!

const std = @import("std");
const logger = std.log.scoped(.ashet_fs);

const asBytes = std.mem.asBytes;
const bytesAsValue = std.mem.bytesAsValue;

fn makeZeroPaddedString(str: []const u8, comptime len: comptime_int) [len]u8 {
    var buf = std.mem.zeroes([len]u8);
    std.mem.copy(u8, &buf, str);
    return buf;
}

pub const magic_number: [32]u8 = .{
    0x2c, 0xcd, 0xbe, 0xe2, 0xca, 0xd9, 0x99, 0xa7, 0x65, 0xe7, 0x57, 0x31, 0x6b, 0x1c, 0xe1, 0x2b,
    0xb5, 0xac, 0x9d, 0x13, 0x76, 0xa4, 0x54, 0x69, 0xfc, 0x57, 0x29, 0xa8, 0xc9, 0x3b, 0xef, 0x62,
};

pub const Block = [512]u8;

pub const BlockDevice = struct {
    pub const IoError = error{
        WriteProtected,
        OperationTimeout,
    };

    pub const CompletedCallback = fn (*anyopaque, ?IoError) void;

    pub const VTable = struct {
        getBlockCountFn: *const fn (*anyopaque) u32,
        writeBlockFn: *const fn (*anyopaque, offset: u32, block: *const Block) IoError!void,
        readBlockFn: *const fn (*anyopaque, offset: u32, block: *Block) IoError!void,
    };

    object: *anyopaque,
    vtable: *const VTable,

    /// Returns the number of blocks in this block device.
    /// Support a maximum of 2 TB storage.
    pub fn getBlockCount(bd: BlockDevice) u32 {
        return bd.vtable.getBlockCountFn(bd.object);
    }

    /// Starts a write operation on the underlying block device. When done, will call `callback` with `callback_ctx` as the first argument, and
    /// an optional error state.
    /// NOTE: When the block device is non-blocking, `callback` is already invoked in this function! Design your code in a way that this won't
    /// affect your control flow.
    pub fn writeBlock(bd: BlockDevice, offset: u32, block: *const Block) IoError!void {
        try bd.vtable.writeBlockFn(bd.object, offset, block);
    }

    /// Starts a read operation on the underlying block device. When done, will call `callback` with `callback_ctx` as the first argument, and
    /// an optional error state.
    /// NOTE: When the block device is non-blocking, `callback` is already invoked in this function! Design your code in a way that this won't
    /// affect your control flow.
    pub fn readBlock(bd: BlockDevice, offset: u32, block: *Block) IoError!void {
        try bd.vtable.readBlockFn(bd.object, offset, block);
    }
};

/// The AshetFS filesystem driver. Implements all supported operations on the file
/// system over a block device.
/// It's recommended to use a caching block device so not every small change will
/// create disk activity.
pub const FileSystem = struct {
    device: BlockDevice,

    version: u32,
    size: u64,

    root_directory: DirectoryHandle,

    pub fn init(bd: BlockDevice) !FileSystem {
        var fs = FileSystem{
            .device = bd,
            .version = undefined,
            .size = undefined,
            .root_directory = undefined,
        };

        var root_block: RootBlock = undefined;
        try bd.readBlock(0, asBytes(&root_block));

        if (!std.mem.eql(u8, &root_block.magic_identification_number, &magic_number))
            return error.NoFilesystem;

        if (root_block.size > bd.getBlockCount())
            return error.CorruptFileSystem;

        if (root_block.version != 1)
            return error.UnsupportedVersion;

        const bitmap_block_count = ((root_block.size + 4095) / 4096);

        fs.version = root_block.version;
        fs.size = root_block.size;
        fs.root_directory = @intToEnum(DirectoryHandle, bitmap_block_count + 1);

        return fs;
    }

    pub fn getRootDir(fs: FileSystem) DirectoryHandle {
        return fs.root_directory;
    }

    pub fn iterate(fs: *FileSystem, dir: DirectoryHandle) !Iterator {
        var iter = Iterator{
            .device = fs.device,
            .total_count = undefined,
            .ref_storage = undefined,
            .refs = undefined,
            .entry_index = 0,
        };

        try fs.device.readBlock(dir.blockNumber(), asBytes(&iter.ref_storage));

        const blocklist = @ptrCast(*align(4) ObjectBlock, &iter.ref_storage);

        iter.refs = &blocklist.refs;
        iter.total_count = blocklist.size / @sizeOf(Entry);

        return iter;
    }

    pub fn readMetaData(fs: *FileSystem, object: ObjectHandle) !MetaData {
        var block: ObjectBlock = undefined;

        try fs.device.readBlock(object.blockNumber(), asBytes(&block));

        return MetaData{
            .create_time = block.create_time,
            .modify_time = block.modify_time,
            .size = block.size,
            .flags = block.flags,
        };
    }

    pub fn updateMetaData(fs: *FileSystem, object: ObjectHandle, changeset: MetaDataChangeSet) !void {
        var block: ObjectBlock = undefined;

        try fs.device.readBlock(object.blockNumber(), asBytes(&block));

        if (changeset.create_time) |new_value| block.create_time = new_value;
        if (changeset.modify_time) |new_value| block.modify_time = new_value;
        if (changeset.flags) |new_value| block.flags = new_value;

        try fs.device.writeBlock(object.blockNumber(), asBytes(&block));
    }

    fn stringsEqualZ(lhs: []const u8, rhs: []const u8) bool {
        const lhs_strip = if (std.mem.indexOfScalar(u8, lhs, 0)) |i| lhs[0..i] else lhs;
        const rhs_strip = if (std.mem.indexOfScalar(u8, rhs, 0)) |i| rhs[0..i] else rhs;

        return std.mem.eql(u8, lhs_strip, rhs_strip);
    }

    // Allocates a new block on the file system and returns its number.
    fn allocBlock(fs: *FileSystem) !u32 {
        var current_bitmap_block: u32 = 1;

        // the root directy is always directly after the bitmap, so as soon as our
        // cursor is hitting the root dir, we're out of memory.
        while (current_bitmap_block != @enumToInt(fs.root_directory)) : (current_bitmap_block += 1) {
            var buf: Block align(4) = undefined;
            try fs.device.readBlock(current_bitmap_block, &buf);

            const buf_slice = std.mem.bytesAsSlice(u32, &buf);

            const Bit = struct {
                offset: u32,
                bit: u5,
            };

            const bit: Bit = for (buf_slice, 0..) |*item, word_index| {
                if (item.* == 0xFFFF_FFFF) // early check
                    continue;

                break Bit{
                    .offset = @intCast(u32, word_index),
                    .bit = @intCast(u5, @ctz(~item.*)),
                };
            } else continue;

            // std.debug.print("alloc block: {}.{}.{}\n", .{
            //     current_bitmap_block,
            //     bit.offset,
            //     bit.bit,
            // });

            buf_slice[bit.offset] |= (@as(u32, 1) << bit.bit);

            // write back the allocation
            try fs.device.writeBlock(current_bitmap_block, &buf);

            // compute the absolute block index
            return 4096 * (current_bitmap_block - 1) + 32 * bit.offset + bit.bit;
        }

        return error.DiskFull;
    }

    // Frees a previously allocated block.
    fn freeBlock(fs: *FileSystem, block: u32) !void {
        _ = fs;
        _ = block;
        @panic("unimplemented");
    }

    /// Creates a new entry in a directory and initializes the ObjectBlock with default values.
    /// Ensures the created object isn't duplicate by name
    fn createEntryInDir(fs: *FileSystem, dir: DirectoryHandle, name: []const u8, entry_type: Entry.Type, time_stamp: i128) !ObjectHandle {
        if (name.len > 120)
            return error.NameTooLong;

        var list_block_num: u32 = undefined;
        var list_buf: Block align(16) = undefined;

        var refs: []u32 = undefined;
        var ref_count: u32 = undefined;
        var next_ref_block: u32 = undefined;
        var entry_count: u32 = undefined;

        {
            const entries_per_block = @divExact(@sizeOf(Block), @sizeOf(Entry));

            list_block_num = dir.blockNumber();
            try fs.device.readBlock(list_block_num, &list_buf);

            const object_block: *ObjectBlock = bytesAsValue(ObjectBlock, &list_buf);

            entry_count = object_block.size / @sizeOf(Entry);

            ref_count = (entry_count + entries_per_block - 1) / entries_per_block;
            refs = &object_block.refs;
            next_ref_block = object_block.next;
        }

        const StorageTarget = struct {
            block: u32,
            index: u2,
        };

        var valid_slot: ?StorageTarget = null;

        search_loop: for (0..ref_count) |_| {
            std.debug.assert(entry_count > 0);
            if (refs.len == 0) {
                if (next_ref_block == 0)
                    return error.CorruptFileSystem;
                list_block_num = next_ref_block;
                try fs.device.readBlock(list_block_num, &list_buf);
                const ref_block: *RefListBlock = bytesAsValue(RefListBlock, &list_buf);
                refs = &ref_block.refs;
                next_ref_block = ref_block.next;
                if (refs.len == 0)
                    return error.CorruptFileSystem;
            }

            const current_data_block = refs[0];
            refs = refs[1..];

            var entry_buf: Block align(16) = undefined;
            try fs.device.readBlock(current_data_block, &entry_buf);
            const dir_data: *DirectoryDataBlock = bytesAsValue(DirectoryDataBlock, &entry_buf);

            for (&dir_data.entries, 0..) |entry, i| {
                //   T we used up all entries, but there are still entries left in our current segment
                //   |
                //   |                      T the current entry was freed at a previous point in time.
                //   v                      v
                if ((entry_count == 0 or entry.ref == 0) and valid_slot == null) {
                    valid_slot = StorageTarget{
                        .block = current_data_block,
                        .index = @intCast(u2, i),
                    };
                    if (entry_count == 0)
                        break :search_loop;
                }
                if (stringsEqualZ(&entry.name, name))
                    return error.FileAlreadyExists;

                entry_count -= 1;
            }
        }

        // std.debug.print("valid_slot     = {?}\n", .{valid_slot});
        // std.debug.print("refs           = {any}\n", .{refs});
        // std.debug.print("ref_count      = {}\n", .{ref_count});
        // std.debug.print("next_ref_block = {}\n", .{next_ref_block});
        // std.debug.print("entry_count    = {}\n", .{entry_count});

        const storage_slot = if (valid_slot) |slot| slot else blk: {
            // no free entry blocks are in the block ref chain,
            // so we need to allocate a new block into the chain.

            const slot = StorageTarget{
                .block = try fs.allocBlock(),
                .index = 0,
            };
            errdefer fs.freeBlock(slot.block) catch |err| {
                // TODO: What to do here?
                logger.err("failed to free block {}: {s}\nfile system garbage collection is required!", .{
                    slot.block,
                    @errorName(err),
                });
            };

            if (next_ref_block != 0)
                return error.CorruptFileSystem; // must be 0, otherwise something got inconsistent. this has to be the last page

            if (refs.len > 0) {
                // we still got some refs in our current list available
                // let's emplace ourselves there

                // mutate the data stored in `list_buf`. This is safe as we
                // will always write into the right place in the buffer, no matter
                // if it's an `ObjectBlock` or a `RefListBlock`.
                refs[0] = slot.block;

                // then write-back the block into the filesystem. we have now successfully emplaced ourselves
                try fs.device.writeBlock(list_block_num, &list_buf);
            } else {

                // we are at the total end of the block ref chain, we have to get a new ref list and put ourselves into the chain:

                const new_list_block = try fs.allocBlock();
                errdefer fs.freeBlock(new_list_block) catch |err| {
                    // TODO: What to do here?
                    logger.err("failed to free block {}: {s}\nfile system garbage collection is required!", .{
                        new_list_block,
                        @errorName(err),
                    });
                };

                // we can savely write the next block in the chain, no matter
                // if `list_buf` contains a `ObjectBlock` or `RefListBlock`.
                // the `next` field is always the last 4 bytes.
                std.mem.writeIntLittle(u32, list_buf[508..512], new_list_block);

                // write-back the changes to the fs.
                try fs.device.writeBlock(list_block_num, &list_buf);

                // TOOD: How to handle error failure after that, FS is potentially in an inconsistent state?!

                const new_list: *RefListBlock = bytesAsValue(RefListBlock, &list_buf);
                new_list.* = RefListBlock{
                    .refs = std.mem.zeroes([127]u32),
                    .next = 0,
                };
                new_list.refs[0] = slot.block;

                // Write the new block to disk. File system is now semi-consistent
                try fs.device.writeBlock(new_list_block, &list_buf);
            }

            // initialize new block
            const new_entry_block: *DirectoryDataBlock = bytesAsValue(DirectoryDataBlock, &list_buf);
            new_entry_block.* = DirectoryDataBlock{
                .entries = std.mem.zeroes([4]DirectoryEntry),
            };

            try fs.device.writeBlock(slot.block, &list_buf);

            break :blk slot;
        };

        // std.debug.print("storage_slot   = {}\n", .{storage_slot});

        // Prepare new object block for the created file
        const object_block = try fs.allocBlock();
        {
            const object: *ObjectBlock = bytesAsValue(ObjectBlock, &list_buf);
            object.* = ObjectBlock{
                .size = 0,
                .create_time = time_stamp,
                .modify_time = time_stamp,
                .flags = 0,
                .refs = std.mem.zeroes([117]u32),
                .next = 0,
            };
            try fs.device.writeBlock(object_block, &list_buf);
        }

        // std.debug.print("object_block   = {}\n", .{object_block});

        // Read-modify-write our entry for the new file:
        {
            try fs.device.readBlock(storage_slot.block, &list_buf);

            const entry_list: *DirectoryDataBlock = bytesAsValue(DirectoryDataBlock, &list_buf);

            entry_list.entries[storage_slot.index] = DirectoryEntry{
                .name = makeZeroPaddedString(name, 120),
                .type = switch (entry_type) {
                    .directory => 0,
                    .file => 1,
                },
                .ref = object_block,
            };

            try fs.device.writeBlock(storage_slot.block, &list_buf);
        }

        // Read-modify-write the original directory and increase its size
        {
            try fs.device.readBlock(dir.blockNumber(), &list_buf);

            const dir_data: *ObjectBlock = bytesAsValue(ObjectBlock, &list_buf);

            // Increment directory size by a single entry.
            dir_data.size += @sizeOf(Entry);

            try fs.device.writeBlock(dir.blockNumber(), &list_buf);
        }

        return @intToEnum(ObjectHandle, object_block);
    }

    pub fn createFile(fs: *FileSystem, dir: DirectoryHandle, name: []const u8, create_time: i128) !FileHandle {
        const file_handle = try fs.createEntryInDir(dir, name, .file, create_time);
        // file is already fully initialized with an empty object
        return file_handle.toFileHandle();
    }

    pub fn resizeFile(fs: *FileSystem, file: FileHandle, new_size: u64) !void {
        _ = fs;
        _ = file;
        _ = new_size;
    }

    pub fn writeData(fs: *FileSystem, file: FileHandle, offset: u64, data: []const u8) !usize {
        _ = fs;
        _ = file;
        _ = offset;
        _ = data;
    }

    pub fn readData(fs: *FileSystem, file: FileHandle, offset: u64, data: []u8) !usize {
        _ = fs;
        _ = file;
        _ = offset;
        _ = data;
    }

    pub fn createDirectory(fs: *FileSystem, dir: DirectoryHandle, name: []const u8, create_time: i128) !DirectoryHandle {
        const dir_handle = try fs.createEntryInDir(dir, name, .file, create_time);
        // directory is already fully initialized with an empty object
        return dir_handle.toDirectoryHandle();
    }

    pub fn renameEntry(fs: *FileSystem, dir: DirectoryHandle, current_name: []const u8, new_name: []const u8) !void {
        _ = fs;
        _ = dir;
        _ = current_name;
        _ = new_name;
    }

    pub fn moveEntry(fs: *FileSystem, src_dir: DirectoryHandle, src_name: []const u8, dst_dir: DirectoryHandle, dst_name: []const u8) !void {
        _ = fs;
        _ = src_dir;
        _ = src_name;
        _ = dst_dir;
        _ = dst_name;
    }

    pub fn deleteEntry(fs: *FileSystem, dir: DirectoryHandle, name: []const u8) !void {
        _ = fs;
        _ = dir;
        _ = name;
    }

    pub const Iterator = struct {
        device: BlockDevice,
        total_count: u64,
        ref_storage: RefListBlock,
        refs: []const u32,
        entry_index: u2 = 0,

        pub fn next(iter: *Iterator) !?Entry {
            while (try iter.nextRaw()) |raw| {
                if (raw.handle.object() != @intToEnum(ObjectHandle, 0))
                    return raw;
            }
            return null;
        }

        fn nextRaw(iter: *Iterator) !?Entry {
            if (iter.total_count == 0)
                return null;

            var entry_list: DirectoryDataBlock = undefined;
            try iter.device.readBlock(iter.refs[0], asBytes(&entry_list));

            const raw_entry = entry_list.entries[iter.entry_index];

            const entry = Entry{
                .name_buffer = raw_entry.name,
                .handle = switch (raw_entry.type) {
                    0 => .{ .directory = @intToEnum(DirectoryHandle, raw_entry.ref) },
                    1 => .{ .file = @intToEnum(FileHandle, raw_entry.ref) },
                    else => return error.CorruptFilesystem,
                },
            };

            iter.entry_index +%= 1;
            iter.total_count -= 1;

            if (iter.total_count > 0 and iter.entry_index == 0) {
                if (iter.refs.len == 0) {
                    if (iter.ref_storage.next == 0)
                        return error.CorruptFilesystem;
                    try iter.device.readBlock(iter.ref_storage.next, asBytes(&iter.ref_storage));
                    iter.refs = &iter.ref_storage.refs;
                }
                iter.refs = iter.refs[1..];
            }

            return entry;
        }
    };
};

pub const Entry = struct {
    name_buffer: [120]u8,
    handle: union(Type) {
        file: FileHandle,
        directory: DirectoryHandle,

        fn object(val: @This()) ObjectHandle {
            return switch (val) {
                inline else => |x| x.object(),
            };
        }
    },

    pub fn name(entry: *const Entry) []const u8 {
        return std.mem.sliceTo(&entry.name_buffer, 0);
    }

    pub const Type = enum { file, directory };
};

pub const MetaData = struct {
    create_time: i128,
    modify_time: i128,
    size: u32,
    flags: u32,
};

pub const MetaDataChangeSet = struct {
    create_time: ?i128 = null,
    modify_time: ?i128 = null,
    flags: ?u32 = null,
};

pub const FileHandle = enum(u32) {
    _,
    pub fn object(h: FileHandle) ObjectHandle {
        return @intToEnum(ObjectHandle, @enumToInt(h));
    }

    pub fn blockNumber(h: FileHandle) u32 {
        return @enumToInt(h);
    }
};

pub const DirectoryHandle = enum(u32) {
    _,
    pub fn object(h: DirectoryHandle) ObjectHandle {
        return @intToEnum(ObjectHandle, @enumToInt(h));
    }

    pub fn blockNumber(h: DirectoryHandle) u32 {
        return @enumToInt(h);
    }
};
pub const ObjectHandle = enum(u32) {
    _,

    pub fn toFileHandle(h: ObjectHandle) FileHandle {
        return @intToEnum(FileHandle, @enumToInt(h));
    }
    pub fn toDirectoryHandle(h: ObjectHandle) DirectoryHandle {
        return @intToEnum(DirectoryHandle, @enumToInt(h));
    }

    pub fn blockNumber(h: ObjectHandle) u32 {
        return @enumToInt(h);
    }
};

const BitmapLocation = struct {
    block: u32,
    byte_offset: u9,
    bit_offset: u3,
};

fn blockToBitPos(block_num: usize) BitmapLocation {
    const page = 1 + (block_num / 4096);
    const bit = block_num % 4096;
    const word_index = bit / 8;
    const word_bit = bit % 8;

    return BitmapLocation{
        .block = @intCast(u32, page),
        .byte_offset = @intCast(u9, word_index),
        .bit_offset = @intCast(u3, word_bit),
    };
}

fn setBuffer(block: *Block, data: anytype) void {
    if (@sizeOf(@TypeOf(data)) != @sizeOf(Block))
        @compileError("Invalid size: " ++ @typeName(@TypeOf(data)) ++ " is not 512 byte large!");
    std.mem.copy(u8, block, asBytes(&data));
}

pub fn format(device: BlockDevice, init_time: i128) !void {
    const block_count = device.getBlockCount();
    logger.debug("start formatting with {} blocks", .{block_count});

    if (block_count < 32) {
        return error.DeviceTooSmall;
    }

    var block: Block = undefined;

    setBuffer(&block, RootBlock{
        .size = block_count,
    });
    try device.writeBlock(0, &block);

    const bitmap_block_count = ((block_count + 4095) / 4096);

    for (1..bitmap_block_count + 2) |index| {
        std.mem.set(u8, &block, 0);

        if (index == 1) {
            block[0] |= 0x01; // mark "root block" as allocated
        }

        // we have to mark all bits in the bitmap *and* the root directory
        // thus, we're counting from [1;bitmap_block_count+1] inclusive.
        for (1..bitmap_block_count + 2) |block_num| {
            const pos = blockToBitPos(block_num);
            if (pos.block == index) {
                block[pos.byte_offset] |= (@as(u8, 1) << pos.bit_offset);
            }
            if (pos.block > index)
                break;
        }

        try device.writeBlock(@intCast(u32, index), &block);
    }

    setBuffer(&block, ObjectBlock{
        .size = 0, // empty directory
        .create_time = init_time,
        .modify_time = init_time,
        .flags = 0,
        .refs = std.mem.zeroes([117]u32),
        .next = 0,
    });

    try device.writeBlock(bitmap_block_count + 1, &block);
}

const RootBlock = extern struct {
    magic_identification_number: [32]u8 = magic_number,
    version: u32 = 1, // must be 1
    size: u32 align(4), // number of managed blocks including this

    padding: [472]u8 = std.mem.zeroes([472]u8), // fill up to 512
};

const ObjectBlock = extern struct {
    size: u32 align(4), // size of this object in bytes. for directories, this means the directory contains `size/sizeof(Entry)` elements.
    create_time: i128 align(4), // stores the date when this object was created, unix timestamp in nano seconds
    modify_time: i128 align(4), // stores the date when this object was last modified, unix timestamp in nano seconds
    flags: u32, // type-dependent bit field (file: bit 0 = read only; directory: none; all other bits are reserved=0)
    refs: [117]u32, // pointer to a type-dependent data block (FileDataBlock, DirectoryDataBlock)
    next: u32 align(4), // link to a RefListBlock to continue the refs listing. 0 is "end of chain"
};

const RefListBlock = extern struct {
    refs: [127]u32, // pointers to data blocks to list the entries
    next: u32 align(4), // pointer to the next RefListBlock or 0
};

const FileDataBlock = extern struct {
    @"opaque": [512]u8, // arbitrary file content, has no filesystem-defined meaning.
};

const DirectoryDataBlock = extern struct {
    entries: [4]DirectoryEntry, // two entries in the directory.
};

const DirectoryEntry = extern struct {
    type: u32, // the kind of this entry. 0 = directory, 1 = file, all other values are illegal
    ref: u32, // link to the associated ObjectBlock. if 0, the entry is deleted. this allows a panic recovery for accidentially deleted files.
    name: [120]u8, // zero-padded file name
};

comptime {
    const block_types = [_]type{
        RootBlock,
        ObjectBlock,
        RefListBlock,
        FileDataBlock,
        DirectoryDataBlock,
    };
    for (block_types) |t| {
        if (@sizeOf(t) != 512) @compileError(@typeName(t) ++ " is not 512 bytes large!");
    }
}