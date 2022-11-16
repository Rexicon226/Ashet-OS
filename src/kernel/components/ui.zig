const std = @import("std");
const logger = std.log.scoped(.ui);
const ashet = @import("../main.zig");

const Size = ashet.abi.Size;
const Point = ashet.abi.Point;
const Rectangle = ashet.abi.Rectangle;
const ColorIndex = ashet.abi.ColorIndex;
const Color = ashet.abi.Color;

const WindowButton = struct {
    const Event = enum { minimize, maximize, close, resize };

    event: Event,
    bounds: Rectangle,
};

pub const Theme = struct {
    pub const WindowStyle = struct {
        border: ColorIndex,
        font: ColorIndex,
        title: ColorIndex,
    };
    active_window: WindowStyle,
    inactive_window: WindowStyle,
};

var current_theme = Theme{
    .active_window = Theme.WindowStyle{
        .border = ColorIndex.get(0x2), // dark blue
        .font = ColorIndex.get(0xF), // white
        .title = ColorIndex.get(0x8), // bright blue
    },
    .inactive_window = Theme.WindowStyle{
        .border = ColorIndex.get(0x1), // dark violet
        .font = ColorIndex.get(0xA), // bright gray
        .title = ColorIndex.get(0x3), // dim gray
    },
};

const min_window_content_size = ashet.abi.Size{
    .width = 39,
    .height = 9,
};

const max_window_content_size = ashet.abi.Size{
    .width = framebuffer.width - 2,
    .height = framebuffer.height - 12,
};

var mouse_cursor_pos: Point = .{
    .x = framebuffer.width / 2,
    .y = framebuffer.height / 2,
};

pub fn run(_: ?*anyopaque) callconv(.C) u32 {
    _ = createWindow("Bottom", Size.new(0, 0), Size.new(200, 100), Size.new(200, 100)) catch @panic("oom");
    _ = createWindow("Middle", Size.new(0, 0), Size.new(400, 300), Size.new(160, 80)) catch @panic("oom");
    const top = createWindow("Top", Size.new(47, 47), Size.new(47, 47), Size.new(47, 47)) catch @panic("oom");
    top.user_facing.flags.focus = true;

    while (true) {
        while (ashet.multi_tasking.exclusive_video_controller != null) {
            // wait until no process has access to the screen
            ashet.scheduler.yield();
        }

        // set up the gpu after a process might have changed
        // everything about the graphics state.
        initializeGraphics();

        // Enforce a full repaint of the user interface, so we have it "online"
        repaint();

        while (ashet.multi_tasking.exclusive_video_controller == null) {
            var force_repaint = false;
            while (ashet.input.getEvent()) |input_event| {
                switch (input_event) {
                    .keyboard => |event| {
                        _ = event;
                    },
                    .mouse => |event| {
                        mouse_cursor_pos.x = std.math.clamp(@intCast(i16, event.x), 0, framebuffer.width - 1);
                        mouse_cursor_pos.y = std.math.clamp(@intCast(i16, event.y), 0, framebuffer.height - 1);
                        if (event.type == .motion) {
                            force_repaint = true;
                        }

                        if (event.type == .button_press and event.button == .left) {
                            logger.info("click on ({},{})", .{ event.x, event.y });
                            const maybe_clicked_window = windowFromCursor(Point.new(@intCast(i16, event.x), @intCast(i16, event.y)));
                            if (maybe_clicked_window) |surface| {
                                WindowIterator.moveToTop(surface.window);
                                force_repaint = true;

                                switch (surface.part) {
                                    .title_bar => {}, // TODO: Initiaze dragging with moving
                                    .button => |button| switch (button) {
                                        .minimize => surface.window.user_facing.flags.minimized = true,
                                        .maximize => surface.window.user_facing.client_rectangle = Rectangle.new(Point.new(1, 11), max_window_content_size),
                                        .close => {}, // TODO: Forward event to app
                                        .resize => {}, // TODO: Initiaze dragging with resizing
                                    },
                                    .content => {}, // TODO: Forward event to app
                                }

                                logger.info("User clicked on window '{s}': {}", .{ surface.window.title.items, surface.part });
                            }
                        }
                    },
                }
            }

            if (force_repaint) {
                repaint();
            }

            ashet.scheduler.yield();
        }
    }
}

const WindowSurface = struct {
    const Part = union(enum) {
        title_bar,
        button: WindowButton.Event,
        content,
    };

    window: *Window,
    part: Part,

    fn init(window: *Window, part: Part) WindowSurface {
        return WindowSurface{ .window = window, .part = part };
    }
};
fn windowFromCursor(point: Point) ?WindowSurface {
    var iter = WindowIterator.init(WindowIterator.regular, .top_to_bottom);
    while (iter.next()) |window| {
        const client_rectangle = window.user_facing.client_rectangle;
        const window_rectangle = expandClientRectangle(client_rectangle);

        if (window_rectangle.contains(point)) {
            var buttons = window.getButtons();
            for (buttons.slice()) |btn| {
                if (btn.bounds.contains(point)) {
                    return WindowSurface.init(window, .{ .button = btn.event });
                }
            }

            if (client_rectangle.contains(point)) {
                // we can only be over the window content if we didn't hit a button.
                // this is intended
                return WindowSurface.init(window, .content);
            }

            return WindowSurface.init(window, .title_bar);
        }
    }
    return null;
}

const framebuffer_wallpaper_shift = 240;

fn initializeGraphics() void {
    ashet.video.setBorder(ColorIndex.get(0));
    ashet.video.setResolution(framebuffer.width, framebuffer.height);

    ashet.video.palette.* = ashet.video.defaults.palette;

    // use the last 15 colors for the wallpaper

    std.mem.copy(Color, ashet.video.palette[framebuffer_wallpaper_shift..], &wallpaper.palette);
}

fn repaint() void {
    // framebuffer.clear(ColorIndex.get(0));

    for (wallpaper.pixels) |c, i| {
        framebuffer.fb[i] = c.shift(framebuffer_wallpaper_shift - 1);
    }

    var iter = WindowIterator.init(WindowIterator.regular, .bottom_to_top);
    while (iter.next()) |window| {
        const client_rectangle = window.user_facing.client_rectangle;
        const window_rectangle = expandClientRectangle(client_rectangle);

        const style = if (window.user_facing.flags.focus)
            current_theme.active_window
        else
            current_theme.inactive_window;

        const buttons = window.getButtons();

        const title_width = @intCast(u15, window_rectangle.width - 2);

        framebuffer.horizontalLine(window_rectangle.x, window_rectangle.y, window_rectangle.width, style.border);
        framebuffer.verticalLine(window_rectangle.x, window_rectangle.y + 1, window_rectangle.height - 1, style.border);

        framebuffer.horizontalLine(window_rectangle.x, window_rectangle.y + @intCast(i16, window_rectangle.height) - 1, window_rectangle.width, style.border);
        framebuffer.verticalLine(window_rectangle.x + @intCast(i16, window_rectangle.width) - 1, window_rectangle.y + 1, window_rectangle.height - 1, style.border);

        framebuffer.horizontalLine(window_rectangle.x + 1, window_rectangle.y + 10, window_rectangle.width - 2, style.border);

        framebuffer.rectangle(window_rectangle.x + 1, window_rectangle.y + 1, title_width, 9, style.title);

        framebuffer.text(
            window_rectangle.x + 2,
            window_rectangle.y + 2,
            std.mem.sliceTo(window.title.items, 0),
            title_width - 2,
            style.font,
        );

        var dy: u15 = 0;
        var row_ptr = window.user_facing.pixels;
        while (dy < client_rectangle.height) : (dy += 1) {
            var dx: u15 = 0;
            while (dx < client_rectangle.width) : (dx += 1) {
                framebuffer.setPixel(client_rectangle.x + dx, client_rectangle.y + dy, ColorIndex.get(row_ptr[dx]));
            }
            row_ptr += window.user_facing.stride;
        }

        for (buttons.slice()) |button| {
            const bounds = button.bounds;
            framebuffer.horizontalLine(bounds.x, bounds.y, bounds.width, style.border);
            framebuffer.horizontalLine(bounds.x, bounds.y + @intCast(u15, bounds.width) - 1, bounds.width, style.border);
            framebuffer.verticalLine(bounds.x, bounds.y, bounds.height, style.border);
            framebuffer.verticalLine(bounds.x + @intCast(u15, bounds.width) - 1, bounds.y, bounds.height, style.border);
            framebuffer.rectangle(bounds.x + 1, bounds.y + 1, bounds.width - 2, bounds.height - 2, style.title);
            switch (button.event) {
                inline else => |tag| framebuffer.icon(bounds.x + 1, bounds.y + 1, @field(icons, @tagName(tag))),
            }
        }
    }

    framebuffer.icon(mouse_cursor_pos.x, mouse_cursor_pos.y, icons.cursor);
}

const WindowIterator = struct {
    const Filter = std.meta.FnPtr(fn (*Window) bool);
    const Direction = enum { top_to_bottom, bottom_to_top };

    var list = WindowQueue{};

    it: ?*WindowQueue.Node,
    filter: Filter,
    direction: Direction,

    pub fn topWindow() ?*Window {
        var iter = init(regular, .top_to_bottom);
        return iter.next();
    }

    /// will move the window to the top, and unminimizes it.
    pub fn moveToTop(window: *Window) void {
        window.user_facing.flags.minimized = false;
        list.remove(&window.node);
        list.append(&window.node);
    }

    pub fn init(filter: Filter, direction: Direction) WindowIterator {
        return WindowIterator{
            .it = switch (direction) {
                .bottom_to_top => list.first,
                .top_to_bottom => list.last,
            },
            .filter = filter,
            .direction = direction,
        };
    }

    pub fn next(self: *WindowIterator) ?*Window {
        while (true) {
            const node = self.it orelse return null;
            self.it = switch (self.direction) {
                .bottom_to_top => node.next,
                .top_to_bottom => node.prev,
            };
            const window = nodeToWindow(node);
            if (self.filter(window))
                return window;
        }
    }

    /// Lists all windows
    pub fn all(_: *Window) bool {
        return true;
    }

    /// Lists all minimized windows
    pub fn minimized(w: *Window) bool {
        return w.user_facing.flags.minimized;
    }

    /// Lists all non-minimized windows
    pub fn regular(w: *Window) bool {
        return !w.user_facing.flags.minimized;
    }
};

const WindowQueue = std.TailQueue(void);

const Window = struct {
    memory: std.heap.ArenaAllocator,
    user_facing: ashet.abi.Window,
    node: WindowQueue.Node,
    title: std.ArrayList(u8),

    pub fn destroy(window: *Window) void {
        WindowIterator.list.remove(&window.node);

        var clone = window.memory;
        window.* = undefined;
        clone.deinit();
    }

    /// Windows can be resized if their minimum size and maximum size differ
    pub fn isResizable(window: Window) bool {
        return (window.user_facing.min_size.width != window.user_facing.max_size.width) or
            (window.user_facing.min_size.height != window.user_facing.max_size.height);
    }

    /// Windows can be maximized if their maximum size is the full screen size
    pub fn canMaximize(window: Window) bool {
        return (window.user_facing.max_size.width == max_window_content_size.width) and
            (window.user_facing.max_size.height == max_window_content_size.height);
    }

    /// All windows except popups can be minimized.
    pub fn canMinimize(window: Window) bool {
        return !window.user_facing.flags.popup;
    }

    const ButtonCollection = std.BoundedArray(WindowButton, std.enums.values(WindowButton.Event).len);
    pub fn getButtons(window: Window) ButtonCollection {
        const rectangle = expandClientRectangle(window.user_facing.client_rectangle);
        var buttons = ButtonCollection{};

        var top_row = Rectangle{
            .x = rectangle.x + @intCast(u15, rectangle.width) - 11,
            .y = rectangle.y,
            .width = 11,
            .height = 11,
        };

        buttons.appendAssumeCapacity(WindowButton{ .bounds = top_row, .event = .close });

        if (window.canMaximize()) {
            top_row.x -= 10;
            buttons.appendAssumeCapacity(WindowButton{ .bounds = top_row, .event = .maximize });
        }
        if (window.canMinimize()) {
            top_row.x -= 10;
            buttons.appendAssumeCapacity(WindowButton{ .bounds = top_row, .event = .minimize });
        }

        if (window.isResizable()) {
            buttons.appendAssumeCapacity(WindowButton{
                .bounds = Rectangle{
                    .x = rectangle.x + @intCast(u15, rectangle.width) - 11,
                    .y = rectangle.y + @intCast(u15, rectangle.height) - 11,
                    .width = 11,
                    .height = 11,
                },
                .event = .resize,
            });
        }

        return buttons;
    }
};

fn createWindow(title: []const u8, min: ashet.abi.Size, max: ashet.abi.Size, initial_size: Size) !*Window {
    var temp_arena = std.heap.ArenaAllocator.init(ashet.memory.allocator);
    var window = temp_arena.allocator().create(Window) catch |err| {
        temp_arena.deinit();
        return err;
    };

    window.* = Window{
        .memory = temp_arena,
        .user_facing = ashet.abi.Window{
            .pixels = undefined,
            .stride = max_window_content_size.width,
            .client_rectangle = undefined,
            .min_size = limitWindowSize(sizeMin(min, max)),
            .max_size = limitWindowSize(sizeMax(min, max)),
            .title = "",
            .flags = .{
                .minimized = false,
                .focus = false,
                .popup = false,
            },
        },
        .node = .{ .data = {} },
        .title = undefined,
    };
    errdefer window.memory.deinit();

    const allocator = window.memory.allocator();

    window.title = std.ArrayList(u8).init(allocator);
    try window.title.ensureTotalCapacity(64);

    const pixel_count = @as(usize, window.user_facing.max_size.height) * @as(usize, window.user_facing.stride);
    window.user_facing.pixels = (try allocator.alloc(u8, pixel_count)).ptr;
    std.mem.set(u8, window.user_facing.pixels[0..pixel_count], 4); // brown

    const clamped_initial_size = sizeMax(sizeMin(initial_size, window.user_facing.max_size), window.user_facing.min_size);

    window.user_facing.client_rectangle = Rectangle{
        .x = 16,
        .y = 16,
        .width = clamped_initial_size.width,
        .height = clamped_initial_size.height,
    };

    if (WindowIterator.topWindow()) |top_window| blk: {
        var spawn_x = top_window.user_facing.client_rectangle.x + 16;
        var spawn_y = top_window.user_facing.client_rectangle.y + 16;

        if (spawn_x + @as(i17, top_window.user_facing.client_rectangle.width) >= framebuffer.width)
            break :blk;
        if (spawn_y + @as(i17, top_window.user_facing.client_rectangle.height) >= framebuffer.height)
            break :blk;

        window.user_facing.client_rectangle.x = spawn_x;
        window.user_facing.client_rectangle.y = spawn_y;
    }

    try window.title.appendSlice(title);
    try window.title.append(0);

    window.user_facing.title = window.title.items[0 .. window.title.items.len - 1 :0];

    // TODO: Setup

    WindowIterator.list.append(&window.node);
    return window;
}

fn expandClientRectangle(rect: Rectangle) Rectangle {
    return Rectangle{
        .x = rect.x - 1,
        .y = rect.y - 11,
        .width = rect.width + 2,
        .height = rect.height + 12,
    };
}

fn limitWindowSize(size: Size) Size {
    return Size{
        .width = std.math.clamp(size.width, min_window_content_size.width, max_window_content_size.width),
        .height = std.math.clamp(size.height, min_window_content_size.height, max_window_content_size.height),
    };
}

fn sizeMin(a: Size, b: Size) Size {
    return Size{
        .width = std.math.min(a.width, b.width),
        .height = std.math.min(a.height, b.height),
    };
}

fn sizeMax(a: Size, b: Size) Size {
    return Size{
        .width = std.math.max(a.width, b.width),
        .height = std.math.max(a.height, b.height),
    };
}

fn nodeToWindow(node: *WindowQueue.Node) *Window {
    return @fieldParentPtr(Window, "node", node);
}

const framebuffer = struct {
    const width = ashet.video.max_res_x;
    const height = ashet.video.max_res_y;

    const fb = ashet.video.memory[0 .. width * height];

    fn setPixel(x: i16, y: i16, color: ColorIndex) void {
        if (x < 0 or y < 0 or x >= width or y >= height) return;
        const ux = @intCast(usize, x);
        const uy = @intCast(usize, y);
        fb[uy * width + ux] = color;
    }

    fn horizontalLine(x: i16, y: i16, w: u16, color: ColorIndex) void {
        var i: u15 = 0;
        while (i < w) : (i += 1) {
            setPixel(x + i, y, color);
        }
    }

    fn verticalLine(x: i16, y: i16, h: u16, color: ColorIndex) void {
        var i: u15 = 0;
        while (i < h) : (i += 1) {
            setPixel(x, y + i, color);
        }
    }

    fn rectangle(x: i16, y: i16, w: u16, h: u16, color: ColorIndex) void {
        var i: i16 = y;
        while (i < y + @intCast(u15, h)) : (i += 1) {
            framebuffer.horizontalLine(x, i, w, color);
        }
    }

    fn icon(x: i16, y: i16, sprite: anytype) void {
        for (sprite) |row, dy| {
            for (row) |pix, dx| {
                if (pix) |c| {
                    setPixel(x + @intCast(i16, dx), y + @intCast(i16, dy), c);
                }
            }
        }
    }

    fn text(x: i16, y: i16, string: []const u8, max_width: u16, color: ColorIndex) void {
        const gw = 6;
        const gh = 8;
        const font = ashet.video.defaults.font;

        var dx: i16 = x;
        var dy: i16 = y;
        for (string) |char| {
            if (dx + gw > x + @intCast(u15, max_width)) {
                break;
            }
            const glyph = font[char];

            var gx: u15 = 0;
            while (gx < gw) : (gx += 1) {
                var bits = glyph[gx];

                comptime var gy: u15 = 0;
                inline while (gy < gh) : (gy += 1) {
                    if ((bits & (1 << gy)) != 0) {
                        setPixel(dx + gx, dy + gy, color);
                    }
                }
            }

            dx += gw;
        }
    }

    fn clear(color: ColorIndex) void {
        std.mem.set(ColorIndex, fb, color);
    }
};

pub const icons = struct {
    fn parsedSpriteSize(comptime def: []const u8) Size {
        var it = std.mem.split(u8, def, "\n");
        var first = it.next().?;
        const width = first.len;
        var height = 1;
        while (it.next()) |line| {
            std.debug.assert(line.len == width);
            height += 1;
        }
        return Size{ .width = width, .height = height };
    }

    fn ParseResult(comptime def: []const u8) type {
        const size = parsedSpriteSize(def);
        return [size.height][size.width]?ColorIndex;
    }

    fn parse(comptime def: []const u8) ParseResult(def) {
        @setEvalBranchQuota(10_000);

        const size = parsedSpriteSize(def);
        var icon: [size.height][size.width]?ColorIndex = [1][size.width]?ColorIndex{
            [1]?ColorIndex{null} ** size.width,
        } ** size.height;

        var it = std.mem.split(u8, def, "\n");
        var y: usize = 0;
        while (it.next()) |line| : (y += 1) {
            var x: usize = 0;
            while (x < icon[0].len) : (x += 1) {
                icon[y][x] = if (std.fmt.parseInt(u8, line[x .. x + 1], 16)) |index|
                    ColorIndex.get(index)
                else |_|
                    null;
            }
        }
        return icon;
    }

    pub const maximize = parse(
        \\.........
        \\.FFFFFFF.
        \\.F.....F.
        \\.FFFFFFF.
        \\.F.....F.
        \\.F.....F.
        \\.F.....F.
        \\.FFFFFFF.
        \\.........
    );

    pub const minimize = parse(
        \\.........
        \\.........
        \\.........
        \\.........
        \\.........
        \\.........
        \\.........
        \\..FFFFF..
        \\.........
    );

    pub const close = parse(
        \\666666666
        \\666666666
        \\66F666F66
        \\666F6F666
        \\6666F6666
        \\666F6F666
        \\66F666F66
        \\666666666
        \\666666666
    );

    pub const resize = parse(
        \\.........
        \\.FFF.....
        \\.F.F.....
        \\.FFFFFFF.
        \\...F...F.
        \\...F...F.
        \\...F...F.
        \\...FFFFF.
        \\.........
    );

    pub const cursor = parse(
        \\888..........
        \\2FF88........
        \\2FFFF88......
        \\.2FFFFF88....
        \\.2FFFFFFF88..
        \\..2FFFFFFFF8.
        \\..2FFFFFFF8..
        \\...2FFFFF8...
        \\...2FFFFF8...
        \\....2FF22F8..
        \\....2F2..2F8.
        \\.....2....2F8
        \\...........2.
    );
};

const wallpaper = struct {
    const raw = @embedFile("../data/ui/wallpaper.img");

    const pixels = @bitCast([400 * 300]ColorIndex, raw[0 .. 400 * 300].*);
    const palette = @bitCast([15]Color, @as([]const u8, raw)[400 * 300 .. 400 * 300 + 15 * @sizeOf(Color)].*);
};
