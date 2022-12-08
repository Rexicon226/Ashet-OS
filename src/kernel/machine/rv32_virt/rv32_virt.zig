const std = @import("std");
const ashet = @import("root");

const VPBA_UART_BASE = 0x10000000;
const VPBA_VIRTIO_BASE = 0x10001000;

const hw = struct {
    //! list of fixed hardware components

    var rtc = ashet.drivers.rtc.Goldfish.init(0x0101000);
};

pub fn initialize() !void {
    // TODO: Port over RV32/virt hal

    try ashet.drivers.scanVirtioDevices(ashet.memory.allocator, VPBA_VIRTIO_BASE, 8);

    ashet.drivers.install(&hw.rtc.driver);
}

pub fn debugWrite(msg: []const u8) void {
    for (msg) |c| {
        @intToPtr(*volatile u8, VPBA_UART_BASE).* = c;
    }
}

// pub const flash = ashet.memory.Section{ .offset = 0x2000_000, .length = 0x200_0000 };

extern const __machine_linmem_start: anyopaque align(4);
extern const __machine_linmem_end: anyopaque align(4);

pub fn getLinearMemoryRegion() ashet.memory.Section {
    const linmem_start = @ptrToInt(&__machine_linmem_start);
    const linmem_end = @ptrToInt(&__machine_linmem_end);
    return ashet.memory.Section{ .offset = linmem_start, .length = linmem_end - linmem_start };
}

// /// Defines which serial ports are available to the system
// pub const Port = enum {
//     COM1,
// };

// pub fn isOnline(port: Port) bool {
//     // virtual ports are always online
//     _ = port;
//     return true;
// }

// pub fn write(port: Port, string: []const u8) void {
//     _ = port;
//     for (string) |char| {
//         @intToPtr(*volatile u8, @import("regs.zig").VPBA_UART_BASE).* = char;
//     }
// }
