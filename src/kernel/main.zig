const std = @import("std");

pub const abi = @import("ashet-abi");
pub const apps = @import("components/apps.zig");
pub const drivers = @import("drivers/drivers.zig");
pub const filesystem = @import("components/filesystem.zig");
pub const input = @import("components/input.zig");
pub const io = @import("components/io.zig");
pub const memory = @import("components/memory.zig");
pub const multi_tasking = @import("components/multi_tasking.zig");
pub const network = @import("components/network.zig");
pub const scheduler = @import("components/scheduler.zig");
pub const serial = @import("components/serial.zig");
pub const storage = @import("components/storage.zig");
pub const syscalls = @import("components/syscalls.zig");
pub const time = @import("components/time.zig");
pub const ui = @import("components/ui.zig");
pub const video = @import("components/video.zig");

pub const platforms = @import("platform/all.zig");
pub const machines = @import("machine/all.zig");

pub const machine = @import("machine").machine;
pub const platform = @import("machine").platform;

pub const machine_config: machines.MachineConfig = machine.machine_config;

comptime {
    // force instantiation of the machine and platform elements
    _ = machine;
    _ = platform;
    _ = platform.start; // explicitly refer to the entry point implementation
}

export fn ashet_kernelMain() void {
    memory.loadKernelMemory(machine_config.load_sections);

    if (@hasDecl(machine, "earlyInitialize")) {
        // If required, initialize the machine basics first,
        // set up linear memory or detect how much memory is available.
        machine.earlyInitialize();
    }

    // Populate RAM with the right sections, and compute how much dynamic memory we have available
    memory.initializeLinearMemory();

    // Initialize scheduler before HAL as it doesn't require anything except memory pages for thread
    // storage, queues and stacks.
    scheduler.initialize();

    main() catch |err| {
        std.log.err("main() failed with {}", .{err});
        @panic("system failure");
    };
}

fn main() !void {
    // Before we initialize the hardware, we already add hardware independent drivers
    // for stuff like file systems, virtual block devices and so on...
    drivers.installBuiltinDrivers();

    // Initialize the hardware into a well-defined state. After this, we can safely perform I/O ops.
    // This will install all relevant drivers, set up interrupts if necessary and so on.
    try machine.initialize();

    video.initialize();

    filesystem.initialize();

    input.initialize();

    const thread = try scheduler.Thread.spawn(tickSystem, null, .{});
    try thread.setName("os.tick");
    try thread.start();
    thread.detach();

    try ui.start();

    try network.start();

    syscalls.initialize();

    scheduler.start();

    // All tasks stopped, what should we do now?
    std.log.warn("All threads stopped. System is now halting.", .{});
}

pub const global_hotkeys = struct {
    pub fn handle(event: abi.KeyboardEvent) bool {
        if (!event.pressed)
            return false;
        if (event.modifiers.alt) {
            switch (event.key) {
                .f1 => @panic("F1 induced kernel panic"),
                .f10 => scheduler.dumpStats(),
                .f11 => network.dumpStats(),
                .f12 => {
                    const total_pages = memory.debug.getPageCount();
                    const free_pages = memory.debug.getFreePageCount();

                    std.log.info("current memory usage: {}/{} pages free, {:.3}/{:.3} used, {}% used", .{
                        free_pages,
                        total_pages,
                        std.fmt.fmtIntSizeBin(memory.page_size * (total_pages - free_pages)),
                        std.fmt.fmtIntSizeBin(memory.page_size * total_pages),
                        100 - (100 * free_pages) / total_pages,
                    });
                },

                else => {},
            }
        }
        return false;
    }
};

fn tickSystem(_: ?*anyopaque) callconv(.C) u32 {
    while (true) {
        if (video.auto_flush) {
            video.flush();
        }
        input.tick();
        time.tick();
        scheduler.yield();
    }
}

var runtime_data_string = "Hello, well initialized .data!\r\n".*;
var runtime_sdata_string = "Hello, well initialized .sdata!\r\n".*;

extern fn hang() callconv(.C) noreturn;

pub const Debug = struct {
    const Error = error{};
    fn write(_: void, bytes: []const u8) Error!usize {
        machine.debugWrite(bytes);
        return bytes.len;
    }

    const Writer = std.io.Writer(void, Error, write);

    pub fn writer() Writer {
        return Writer{ .context = {} };
    }
};

extern var kernel_stack: u8;
extern var kernel_stack_start: u8;

pub fn stackCheck() void {
    const sp = platform.getStackPointer();

    var stack_end: usize = @intFromPtr(&kernel_stack);
    var stack_start: usize = @intFromPtr(&kernel_stack_start);

    if (scheduler.Thread.current()) |thread| {
        stack_end = @intFromPtr(thread.getBasePointer());
        stack_start = stack_end - thread.stack_size;
    }

    if (sp > stack_end) {
        // stack underflow
        @panic("STACK UNDERFLOW");
    } else if (sp <= stack_start) {
        // stack overflow
        @panic("STACK OVERFLOW");
    } else {
        // stack nominal
    }
}

var double_panic = false;

pub const LogLevel = std.log.Level;

pub const log_levels = struct {
    pub var io: LogLevel = .info;
    pub var ui: LogLevel = .info;
    pub var network: LogLevel = .info;
    pub var filesystem: LogLevel = .debug;
    pub var memory: LogLevel = .info;
    pub var drivers: LogLevel = .info;

    // drivers:
    pub var @"virtio-net": LogLevel = .info;
    pub var @"virtio-gpu": LogLevel = .info;
    pub var @"virtio-input": LogLevel = .info;

    // system modules:
    pub var fatfs: LogLevel = .info;
};

pub const std_options = struct {
    pub const log_level = if (@import("builtin").mode == .Debug) .debug else .info;

    pub fn logFn(
        comptime message_level: std.log.Level,
        comptime scope: @Type(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const ansi = true;

        const scope_name = @tagName(scope);

        if (@hasDecl(log_levels, scope_name)) {
            if (@intFromEnum(message_level) > @intFromEnum(@field(log_levels, scope_name)))
                return;
        }

        const prefix = if (ansi)
            switch (message_level) {
                .err => "\x1B[91m", // red
                .warn => "\x1B[93m", // yellow
                .info => "\x1B[97m", // white
                .debug => "\x1B[90m", // gray
            }
        else
            "";
        const postfix = if (ansi) "\x1B[0m" else ""; // reset terminal properties

        const level_txt = comptime message_level.asText();
        const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        Debug.writer().print(prefix ++ level_txt ++ prefix2 ++ format ++ postfix ++ "\n", args) catch return;
    }
};

pub fn panic(message: []const u8, maybe_error_trace: ?*std.builtin.StackTrace, maybe_return_address: ?usize) noreturn {
    @setCold(true);
    const sp = platform.getStackPointer();

    _ = maybe_return_address;
    _ = maybe_error_trace;

    var writer = Debug.writer();
    if (double_panic) {
        writer.writeAll("\r\nDOUBLE PANIC: ") catch {};
        writer.writeAll(message) catch {};
        writer.writeAll("\r\n") catch {};
        hang();
    }
    double_panic = true;

    writer.writeAll("\r\n") catch {};
    writer.writeAll("=========================================================================\r\n") catch {};
    writer.writeAll("Kernel Panic: ") catch {};
    writer.writeAll(message) catch {};
    writer.writeAll("\r\n") catch {};
    writer.writeAll("=========================================================================\r\n") catch {};
    writer.writeAll("\r\n") catch {};

    const current_thread = scheduler.Thread.current();

    writer.print("return address:\r\n      0x{X:0>8}\r\n\r\n", .{@returnAddress()}) catch {};

    {
        var stack_end: usize = @intFromPtr(&kernel_stack);
        var stack_start: usize = @intFromPtr(&kernel_stack_start);

        if (current_thread) |thread| {
            stack_end = @intFromPtr(thread.getBasePointer());
            stack_start = stack_end - thread.stack_size;
        }

        std.debug.assert(stack_end > stack_start);

        const stack_size: usize = stack_end - stack_start;

        writer.print("stack usage:\r\n", .{}) catch {};

        writer.print("  low:     0x{X:0>8}\r\n", .{stack_start}) catch {};
        writer.print("  pointer: 0x{X:0>8}\r\n", .{sp}) catch {};
        writer.print("  high:    0x{X:0>8}\r\n", .{stack_end}) catch {};
        // writer.print("  size:    {d:.3}\r\n", .{std.fmt.fmtIntSizeBin(stack_size)}) catch {};
        writer.print("  size:    {d}\r\n", .{stack_size}) catch {};

        if (sp > stack_end) {
            // stack underflow
            writer.print("  usage:   UNDERFLOW by {} bytes!\r\n", .{
                sp - stack_end,
            }) catch {};
        } else if (sp <= stack_start) {
            // stack overflow
            writer.print("  usage:   OVERFLOW by {} bytes!\r\n", .{
                stack_start - sp,
            }) catch {};
        } else {
            // stack nominal
            writer.print("  usage:   {d}%\r\n", .{
                100 - (100 * (sp - stack_start)) / stack_size,
            }) catch {};
        }
        writer.writeAll("\r\n") catch {};
    }

    if (@import("builtin").mode == .Debug) {
        if (scheduler.Thread.current()) |thread| {
            writer.print("current thread:\r\n", .{}) catch {};
            writer.print("  [!] {}\r\n\r\n", .{thread}) catch {};
        }

        writer.writeAll("waiting threads:\r\n") catch {};
        var index: usize = 0;
        var queue = scheduler.ThreadIterator.init();
        while (queue.next()) |thread| : (index += 1) {
            writer.print("  [{}] {}\r\n", .{ index, thread }) catch {};
        }
        writer.writeAll("\r\n") catch {};
    }

    {
        writer.writeAll("stack trace:\r\n") catch {};
        var index: usize = 0;
        var it = std.debug.StackIterator.init(@returnAddress(), null);
        while (it.next()) |addr| : (index += 1) {
            if (current_thread) |thread| {
                if (thread.process) |proc| {
                    const base = @intFromPtr(proc.process_memory.ptr);
                    const top = base +| proc.process_memory.len;

                    if (addr >= base and addr < top) {
                        writer.print("{d: >4}:{s}: 0x{X:0>8}\r\n", .{ index, proc.file_name, addr - base }) catch {};
                        writer.print("0x{X:0>8}\r\n", .{addr - base}) catch {};
                        continue;
                    }
                }
            }

            writer.print("{d: >4}: kernel:0x{X:0>8}\r\n", .{ index, addr }) catch {};
            writer.print("0x{X:0>8}\r\n", .{addr}) catch {};
        }
    }

    writer.writeAll("\r\n") catch {};

    writer.writeAll("Memory map:\r\n") catch {};
    memory.debug.dumpPageMap();

    // print the kernel message again so we have a wraparound
    writer.writeAll("\r\n") catch {};
    writer.writeAll("=========================================================================\r\n") catch {};
    writer.writeAll("Kernel Panic: ") catch {};
    writer.writeAll(message) catch {};
    writer.writeAll("\r\n") catch {};
    writer.writeAll("=========================================================================\r\n") catch {};
    writer.writeAll("\r\n") catch {};

    hang();
}

export fn ashet_lockInterrupts(were_enabled: *bool) void {
    were_enabled.* = platform.areInterruptsEnabled();
    platform.disableInterrupts();
}

export fn ashet_unlockInterrupts(enable: bool) void {
    if (enable) {
        platform.enableInterrupts();
    }
}

export fn ashet_rand() u32 {
    // TODO: Improve this
    return 4; // chose by a fair dice roll
}

pub const CriticalSection = struct {
    restore: bool,

    pub fn enter() CriticalSection {
        var cs = CriticalSection{ .restore = undefined };
        ashet_lockInterrupts(&cs.restore);
        return cs;
    }

    pub fn leave(cs: *CriticalSection) void {
        ashet_unlockInterrupts(cs.restore);
        cs.* = undefined;
    }
};
