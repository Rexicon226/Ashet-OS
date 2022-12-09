const std = @import("std");
const ashet = @import("../main.zig");

pub const BlockDevice = struct {
    pub const DeviceError = error{InvalidBlock};
    pub const ReadError = DeviceError || error{};
    pub const WriteError = DeviceError || error{ Fault, NotSupported };

    name: []const u8,
    block_size: u32, // typically 512
    num_blocks: u64 align(4), // number

    presentFn: std.meta.FnPtr(fn (*ashet.drivers.Driver) bool),
    readFn: std.meta.FnPtr(fn (*ashet.drivers.Driver, block: u64, []u8) ReadError!void),
    writeFn: std.meta.FnPtr(fn (*ashet.drivers.Driver, block: u64, []const u8) WriteError!void),

    pub fn isPresent(dev: *BlockDevice) bool {
        return dev.presentFn(ashet.drivers.resolveDriver(.block, dev));
    }

    pub fn blockCount(dev: BlockDevice) u64 {
        return dev.num_blocks;
    }

    pub fn blockSize(dev: BlockDevice) usize {
        return dev.block_size;
    }

    pub fn byteSize(dev: BlockDevice) u64 {
        return dev.num_blocks * dev.block_size;
    }

    pub fn writeBlock(dev: *BlockDevice, block_num: u32, buffer: []const u8) WriteError!void {
        std.debug.assert(buffer.len == dev.block_size);
        return dev.writeFn(ashet.drivers.resolveDriver(.block, dev), block_num, buffer);
    }

    pub fn readBlock(dev: *BlockDevice, block_num: u32, buffer: []u8) ReadError!void {
        std.debug.assert(buffer.len == dev.block_size);
        return dev.readFn(ashet.drivers.resolveDriver(.block, dev), block_num, buffer);
    }
};

pub fn enumerate() ashet.drivers.DriverIterator(.block) {
    return ashet.drivers.enumerate(.block);
}
