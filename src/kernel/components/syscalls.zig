//!
//! This file implements or forwards all syscalls
//! that are available to applications.
//!
const std = @import("std");
const hal = @import("hal");
const ashet = @import("../main.zig");

const abi = ashet.abi;

const ashet_syscall_interface: abi.SysCallInterface align(16) = .{
    .video = .{
        .aquire = @"video.acquire",
        .release = @"video.release",
        .setBorder = @"video.setBorder",
        .setResolution = @"video.setResolution",
        .getVideoMemory = @"video.getVideoMemory",
        .getPaletteMemory = @"video.getPaletteMemory",
    },

    .ui = .{
        .createWindow = @"ui.createWindow",
        .destroyWindow = @"ui.destroyWindow",
        .moveWindow = @"ui.moveWindow",
        .resizeWindow = @"ui.resizeWindow",
        .setWindowTitle = @"ui.setWindowTitle",
        .getEvent = @"ui.getEvent",
        .invalidate = @"ui.invalidate",
    },

    .process = .{
        .yield = @"process.yield",
        .exit = @"process.exit",
    },
    .fs = .{
        .delete = @"fs.delete",
        .mkdir = @"fs.mkdir",
        .rename = @"fs.rename",
        .stat = @"fs.stat",
        .openFile = @"fs.openFile",
        .read = @"fs.read",
        .write = @"fs.write",
        .seekTo = @"fs.seekTo",
        .flush = @"fs.flush",
        .close = @"fs.close",
        .openDir = @"fs.openDir",
        .nextFile = @"fs.nextFile",
        .closeDir = @"fs.closeDir",
    },
    .input = .{
        .getEvent = @"input.getEvent",
        .getKeyboardEvent = @"input.getKeyboardEvent",
        .getMouseEvent = @"input.getMouseEvent",
    },
};

fn getCurrentThread() *ashet.scheduler.Thread {
    return ashet.scheduler.Thread.current() orelse @panic("syscall only legal in a process");
}

fn getCurrentProcess() *ashet.multi_tasking.Process {
    return getCurrentThread().process orelse @panic("syscall only legal in a process");
}

pub fn initialize() void {
    //
}

pub fn getInterfacePointer() *align(16) const abi.SysCallInterface {
    return &ashet_syscall_interface;
}

fn @"video.acquire"() callconv(.C) bool {
    if (ashet.multi_tasking.exclusive_video_controller == null) {
        ashet.multi_tasking.exclusive_video_controller = getCurrentProcess();
        return true;
    } else {
        return false;
    }
}

fn videoExclusiveWarning() noreturn {
    std.log.warn("process {*} does not have exclusive control over ", .{getCurrentProcess()});
    ashet.scheduler.exit(1);
}

fn @"video.release"() callconv(.C) void {
    if (getCurrentProcess().isExclusiveVideoController()) {
        ashet.multi_tasking.exclusive_video_controller = null;
    }
}

fn @"video.setMode"(mode: abi.VideoMode) callconv(.C) void {
    if (!getCurrentProcess().isExclusiveVideoController()) {
        return videoExclusiveWarning();
    }
    ashet.video.setMode(mode);
}
fn @"video.setBorder"(color: abi.ColorIndex) callconv(.C) void {
    if (!getCurrentProcess().isExclusiveVideoController()) {
        videoExclusiveWarning();
    }
    ashet.video.setBorder(color);
}
fn @"video.getVideoMemory"() callconv(.C) [*]align(4) abi.ColorIndex {
    if (!getCurrentProcess().isExclusiveVideoController()) {
        videoExclusiveWarning();
    }
    return ashet.video.memory.ptr;
}
fn @"video.getPaletteMemory"() callconv(.C) *[abi.palette_size]abi.Color {
    if (!getCurrentProcess().isExclusiveVideoController()) {
        videoExclusiveWarning();
    }
    return ashet.video.palette;
}
fn @"video.setResolution"(w: u16, h: u16) callconv(.C) void {
    if (!getCurrentProcess().isExclusiveVideoController()) {
        videoExclusiveWarning();
    }
    ashet.video.setResolution(
        std.math.min(w, 400),
        std.math.min(h, 300),
    );
}

fn @"process.exit"(exit_code: u32) callconv(.C) noreturn {
    ashet.scheduler.exit(exit_code);
}

fn @"process.yield"() callconv(.C) void {
    ashet.scheduler.yield();
}

fn @"fs.delete"(path_ptr: [*]const u8, path_len: usize) callconv(.C) bool {
    _ = path_len;
    _ = path_ptr;
    return false;
}

fn @"fs.mkdir"(path_ptr: [*]const u8, path_len: usize) callconv(.C) bool {
    _ = path_len;
    _ = path_ptr;
    return false;
}

fn @"fs.rename"(old_path_ptr: [*]const u8, old_path_len: usize, new_path_ptr: [*]const u8, new_path_len: usize) callconv(.C) bool {
    _ = old_path_len;
    _ = old_path_ptr;
    _ = new_path_len;
    _ = new_path_ptr;
    return false;
}

fn @"fs.stat"(path_ptr: [*]const u8, path_len: usize, info: *abi.FileInfo) callconv(.C) bool {
    info.* = ashet.filesystem.stat(path_ptr[0..path_len]) catch return false;
    return true;
}

fn @"fs.openFile"(path_ptr: [*]const u8, path_len: usize, access: abi.FileAccess, mode: abi.FileMode) callconv(.C) abi.FileHandle {
    return ashet.filesystem.open(path_ptr[0..path_len], access, mode) catch .invalid;
}

fn @"fs.read"(handle: abi.FileHandle, ptr: [*]u8, len: usize) callconv(.C) usize {
    return ashet.filesystem.read(handle, ptr[0..len]) catch 0;
}
fn @"fs.write"(handle: abi.FileHandle, ptr: [*]const u8, len: usize) callconv(.C) usize {
    return ashet.filesystem.write(handle, ptr[0..len]) catch 0;
}

fn @"fs.seekTo"(handle: abi.FileHandle, offset: u64) callconv(.C) bool {
    ashet.filesystem.seekTo(handle, offset) catch return false;
    return true;
}

fn @"fs.flush"(handle: abi.FileHandle) callconv(.C) bool {
    ashet.filesystem.flush(handle) catch return false;
    return true;
}
fn @"fs.close"(handle: abi.FileHandle) callconv(.C) void {
    ashet.filesystem.close(handle);
}

fn @"fs.openDir"(path_ptr: [*]const u8, path_len: usize) callconv(.C) abi.DirectoryHandle {
    return ashet.filesystem.openDir(path_ptr[0..path_len]) catch .invalid;
}
fn @"fs.nextFile"(handle: abi.DirectoryHandle, info: *abi.FileInfo) callconv(.C) bool {
    if (ashet.filesystem.next(handle) catch return false) |file| {
        info.* = file;
        return true;
    } else {
        info.* = undefined;
        return false;
    }
}
fn @"fs.closeDir"(handle: abi.DirectoryHandle) callconv(.C) void {
    ashet.filesystem.closeDir(handle);
}

fn @"input.getEvent"(event: *abi.InputEvent) callconv(.C) abi.InputEventType {
    if (!getCurrentProcess().isExclusiveVideoController()) {
        return videoExclusiveWarning();
    }

    const evt = ashet.input.getEvent() orelse return .none;
    switch (evt) {
        .keyboard => |data| {
            event.* = .{ .keyboard = data };
            return .keyboard;
        },
        .mouse => |data| {
            event.* = .{ .mouse = data };
            return .mouse;
        },
    }
}

fn @"input.getKeyboardEvent"(event: *abi.KeyboardEvent) callconv(.C) bool {
    if (!getCurrentProcess().isExclusiveVideoController()) {
        return videoExclusiveWarning();
    }
    event.* = ashet.input.getKeyboardEvent() orelse return false;
    return true;
}

fn @"input.getMouseEvent"(event: *abi.MouseEvent) callconv(.C) bool {
    if (!getCurrentProcess().isExclusiveVideoController()) {
        return videoExclusiveWarning();
    }
    event.* = ashet.input.getMouseEvent() orelse return false;
    return true;
}

fn @"ui.createWindow"(title: [*:0]const u8, min: abi.Size, max: abi.Size, startup: abi.Size, flags: abi.CreateWindowFlags) callconv(.C) ?*const abi.Window {
    const window = ashet.ui.Window.create(getCurrentProcess(), std.mem.sliceTo(title, 0), min, max, startup, flags) catch return null;
    return &window.user_facing;
}

fn getMutableWindow(win: *const abi.Window) *ashet.ui.Window {
    const window = @fieldParentPtr(ashet.ui.Window, "user_facing", win);
    return @intToPtr(*ashet.ui.Window, @ptrToInt(window));
}

fn @"ui.destroyWindow"(win: *const abi.Window) callconv(.C) void {
    const window = getMutableWindow(win);
    window.destroy();
}

fn @"ui.moveWindow"(win: *const abi.Window, x: i16, y: i16) callconv(.C) void {
    const window = getMutableWindow(win);

    window.user_facing.client_rectangle.x = x;
    window.user_facing.client_rectangle.y = y;

    window.pushEvent(.window_moved);
}

fn @"ui.resizeWindow"(win: *const abi.Window, x: u16, y: u16) callconv(.C) void {
    const window = getMutableWindow(win);

    window.user_facing.client_rectangle.width = x;
    window.user_facing.client_rectangle.height = y;

    window.pushEvent(.window_resized);
}

fn @"ui.setWindowTitle"(win: *const abi.Window, title: [*:0]const u8) callconv(.C) void {
    const window = getMutableWindow(win);
    window.setTitle(std.mem.sliceTo(title, 0)) catch std.log.err("setWindowTitle: out of memory!", .{});
}

fn @"ui.getEvent"(win: *const abi.Window, out: *abi.UiEvent) callconv(.C) abi.UiEventType {
    const window = getMutableWindow(win);

    const event = window.pullEvent() orelse return .none;
    switch (event) {
        .none => unreachable,
        .mouse => |val| out.* = .{ .mouse = val },
        .keyboard => |val| out.* = .{ .keyboard = val },
        .window_close, .window_minimize, .window_restore, .window_moving, .window_moved, .window_resizing, .window_resized => {},
    }
    return event;
}

fn @"ui.invalidate"(win: *const abi.Window, rect: abi.Rectangle) callconv(.C) void {
    const window = getMutableWindow(win);

    var screen_rect = abi.Rectangle{
        .x = window.user_facing.client_rectangle.x + rect.x,
        .y = window.user_facing.client_rectangle.y + rect.y,
        .width = @intCast(u16, std.math.clamp(rect.width, 0, @as(i17, window.user_facing.client_rectangle.width) - rect.x)),
        .height = @intCast(u16, std.math.clamp(rect.height, 0, @as(i17, window.user_facing.client_rectangle.height) - rect.y)),
    };

    ashet.ui.invalidateRegion(screen_rect);
}
