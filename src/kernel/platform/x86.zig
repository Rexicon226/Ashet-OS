const std = @import("std");
const ashet = @import("../main.zig");

pub const multiboot = @import("x86/multiboot.zig");

pub const page_size = 4096;

pub const scheduler = struct {
    //
};

pub const start = struct {
    pub export var multiboot_info: ?*multiboot.Info = null;

    comptime {
        @export(multiboot_info, .{
            .name = "ashet_x86_kernel_multiboot_info",
        });

        // the startup routine must be written in assembler to
        // guarantee that no stack and register is touched is used until
        // we saved
        asm (
            \\.section .text
            \\.global _start
            \\_start:
            \\  mov $kernel_stack, %esp
            \\  cmpl $0x2BADB002, %eax
            \\  jne .no_multiboot
            \\
            \\.has_multiboot:
            \\  movl %ebx, ashet_x86_kernel_multiboot_info
            \\  call ashet_kernelMain
            \\  jmp hang
            \\
            \\.no_multiboot:
            \\  movl $0, ashet_x86_kernel_multiboot_info
            \\  call ashet_kernelMain
            \\
            \\hang:
            \\  cli
            \\  hlt
            \\  jmp hang
            \\
        );
    }
};

pub inline fn getStackPointer() usize {
    return asm (""
        : [sp] "={esp}" (-> usize),
    );
}

pub fn areInterruptsEnabled() bool {
    // TODO: Implement this
    return false;
}

pub fn disableInterrupts() void {
    // TODO: Implement this
}

pub fn enableInterrupts() void {
    // TODO: Implement this
}

/// Implements the `out` instruction for an x86 processor.
/// `type` must be one of `u8`, `u16`, `u32`, `port` is the
/// port number and `value` will be sent to that port.
pub inline fn out(comptime T: type, port: u16, value: T) void {
    switch (T) {
        u8 => asm volatile ("outb %[value], %[port]"
            :
            : [port] "{dx}" (port),
              [value] "{al}" (value),
        ),
        u16 => asm volatile ("outw %[value], %[port]"
            :
            : [port] "{dx}" (port),
              [value] "{ax}" (value),
        ),
        u32 => asm volatile ("outl %[value], %[port]"
            :
            : [port] "{dx}" (port),
              [value] "{eax}" (value),
        ),
        else => @compileError("Only u8, u16 or u32 are allowed for port I/O!"),
    }
}

/// Implements the `in` instruction for an x86 processor.
/// `type` must be one of `u8`, `u16`, `u32`, `port` is the
/// port number and the value received from that port will be returned.
pub inline fn in(comptime T: type, port: u16) T {
    return switch (T) {
        u8 => asm volatile ("inb  %[port], %[ret]"
            : [ret] "={al}" (-> u8),
            : [port] "{dx}" (port),
        ),
        u16 => asm volatile ("inw  %[port], %[ret]"
            : [ret] "={ax}" (-> u16),
            : [port] "{dx}" (port),
        ),
        u32 => asm volatile ("inl  %[port], %[ret]"
            : [ret] "={eax}" (-> u32),
            : [port] "{dx}" (port),
        ),
        else => @compileError("Only u8, u16 or u32 are allowed for port I/O!"),
    };
}
