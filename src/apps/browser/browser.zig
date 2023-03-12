//!
//! A truly tiny browser for the interwebz.
//!
//! Supported protocols:
//! - gopher
//! - gemini
//! - http/s
//! - spartan
//! - finger
//!
//! Supported file formats:
//! - text/plain
//! - text/gemini
//! - text/html
//!

const std = @import("std");
const ashet = @import("ashet");
const gui = @import("ashet-gui");

const ColorIndex = ashet.abi.ColorIndex;

pub usingnamespace ashet.core;

var tb_url_field_backing: [64]u8 = undefined;
var tb_passwd_backing: [64]u8 = undefined;

// var interface = gui.Interface{ .widgets = &widgets };

// const icons = struct {
//     const back = gui.Bitmap.embed(@embedFile(""));
//     const forward = gui.Bitmap.embed(@embedFile(""));
//     const reload = gui.Bitmap.embed(@embedFile(""));
//     const home = gui.Bitmap.embed(@embedFile(""));
//     const go = gui.Bitmap.embed(@embedFile(""));
//     const stop = gui.Bitmap.embed(@embedFile(""));
//     const menu = gui.Bitmap.embed(@embedFile(""));
// };

// var widgets = blk: {
//     var list = [_]gui.Widget{
//         gui.Panel.new(5, 5, 172, 57), // 0: coolbar
//         gui.ToolButton.new(69, 42, icons.back), // 1: coolbar: backward
//         gui.ToolButton.new(69, 42, icons.forward), // 2: coolbar: forward
//         gui.ToolButton.new(69, 42, icons.reload), // 3: coolbar: reload
//         gui.ToolButton.new(69, 42, icons.home), // 4: coolbar: home
//         gui.TextBox.new(69, 42, 100, null, null), // 5: coolbar: address
//         gui.ToolButton.new(69, 42, icons.go), // 6: coolbar: go
//         gui.ToolButton.new(69, 42, icons.menu), // 7: coolbar: app menu
//         gui.ScrollBar.new(0, 0, .vertical, 100, 1000), // 8: scrollbar
//     };

//     list[1].control.tool_button.clickEvent = gui.Event.new(gui.EventID.from(.coolbar_backward));
//     list[2].control.tool_button.clickEvent = gui.Event.new(gui.EventID.from(.coolbar_forward));
//     list[3].control.tool_button.clickEvent = gui.Event.new(gui.EventID.from(.coolbar_reload));
//     list[4].control.tool_button.clickEvent = gui.Event.new(gui.EventID.from(.coolbar_home));
//     // list[5].control.text_box.clickEvent = gui.Event.new(gui.EventID.from(.coolbar_address));
//     list[6].control.tool_button.clickEvent = gui.Event.new(gui.EventID.from(.coolbar_go));
//     list[7].control.tool_button.clickEvent = gui.Event.new(gui.EventID.from(.coolbar_app_menu));

//     break :blk list;
// };

pub fn main() !void {
    const window = try ashet.ui.createWindow(
        "Gateway",
        ashet.abi.Size.new(182, 127),
        ashet.abi.Size.new(182, 127),
        ashet.abi.Size.new(182, 127),
        .{ .popup = false },
    );
    defer ashet.ui.destroyWindow(window);

    paint(window);

    app_loop: while (true) {
        const event = ashet.ui.getEvent(window);
        switch (event) {
            .mouse => |data| {
                _ = data;
                // if (interface.sendMouseEvent(data)) |guievt|
                // handleEvent(guievt);
                paint(window);
            },
            .keyboard => |data| {
                _ = data;
                // if (interface.sendKeyboardEvent(data)) |guievt|
                //     handleEvent(guievt);
                paint(window);
            },
            .window_close => break :app_loop,
            .window_minimize => {},
            .window_restore => {},
            .window_moving => {},
            .window_moved => {},
            .window_resizing => {},
            .window_resized => {},
        }
    }
}

fn handleEvent(evt: gui.Event) void {
    switch (evt.id) {
        gui.EventID.from(.coolbar_backward) => std.log.info("gui.EventID.from(.coolbar_backward)", .{}),
        gui.EventID.from(.coolbar_forward) => std.log.info("gui.EventID.from(.coolbar_forward)", .{}),
        gui.EventID.from(.coolbar_reload) => std.log.info("gui.EventID.from(.coolbar_reload)", .{}),
        gui.EventID.from(.coolbar_home) => std.log.info("gui.EventID.from(.coolbar_home)", .{}),
        gui.EventID.from(.coolbar_go) => std.log.info("gui.EventID.from(.coolbar_go)", .{}),
        gui.EventID.from(.coolbar_app_menu) => std.log.info("gui.EventID.from(.coolbar_app_menu)", .{}),
        else => std.log.info("unhandled gui event: {}\n", .{evt}),
    }
}

fn paint(window: *const ashet.ui.Window) void {
    var fb = gui.Framebuffer.forWindow(window);

    fb.clear(ColorIndex.get(0));

    // interface.paint(fb);
}

fn udp_demo() !void {
    var socket = try ashet.net.Udp.open();
    defer socket.close();

    _ = try socket.bind(ashet.net.EndPoint.new(
        ashet.net.IP.ipv4(.{ 0, 0, 0, 0 }),
        8000,
    ));

    _ = try socket.sendTo(
        ashet.net.EndPoint.new(
            ashet.net.IP.ipv4(.{ 10, 0, 2, 2 }),
            4567,
        ),
        "Hello, World!\n",
    );

    while (true) {
        var buf: [256]u8 = undefined;
        var ep: ashet.net.EndPoint = undefined;
        const len = try socket.receiveFrom(&ep, &buf);
        if (len > 0) {
            std.log.info("received {s} from {}", .{ buf[0..len], ep });
        }
        ashet.process.yield();
    }
}
