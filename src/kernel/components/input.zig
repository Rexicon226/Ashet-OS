const std = @import("std");
const ashet = @import("../main.zig");
const logger = std.log.scoped(.input);
const astd = @import("ashet-std");

var shift_left_state: bool = false;
var shift_right_state: bool = false;

var ctrl_left_state: bool = false;
var ctrl_right_state: bool = false;

var alt_state: bool = false;
var alt_graph_state: bool = false;

pub var cursor: ashet.abi.Point = undefined;

pub fn initialize() void {
    const res = ashet.video.getResolution();

    cursor = ashet.abi.Point.new(@as(i16, @intCast(res.width / 2)), @as(i16, @intCast(res.height / 2)));
}

/// Period subsystem update, will poll for input events
pub fn tick() void {
    var devices = ashet.drivers.enumerate(.input);
    while (devices.next()) |device| {
        device.poll();
    }

    {
        var cs = ashet.CriticalSection.enter();
        defer cs.leave();

        while (async_queue.pull()) |evt| {
            pushRawEvent(evt);
        }
    }
}

pub const raw = struct {
    pub const Event = union(enum) {
        mouse_abs_motion: MouseAbsMotion,
        mouse_rel_motion: MouseRelMotion,
        mouse_button: MouseButton,
        keyboard: KeyEvent,
    };

    pub const MouseAbsMotion = struct {
        x: i16,
        y: i16,
    };

    pub const MouseRelMotion = struct {
        dx: i32,
        dy: i32,
    };

    pub const MouseButton = struct {
        button: ashet.abi.MouseButton,
        down: bool,
    };

    pub const KeyEvent = struct {
        scancode: u16,
        down: bool,
    };
};

pub const Event = union(enum) {
    keyboard: ashet.abi.KeyboardEvent,
    mouse: ashet.abi.MouseEvent,
};

/// stores incoming events from either interrupts or polling.
var event_queue: astd.RingBuffer(raw.Event, 32) = .{};

var event_awaiter: ?*ashet.abi.input.GetEvent = null;

var async_queue: astd.RingBuffer(raw.Event, 16) = .{};

pub fn pushRawEventFromIRQ(raw_event: raw.Event) void {
    if (async_queue.full()) {
        logger.warn("dropping {s} event", .{@tagName(event_queue.pull().?)});
    }
    async_queue.push(raw_event);
}

pub fn pushRawEvent(raw_event: raw.Event) void {
    if (event_queue.full()) {
        logger.warn("dropping {s} event", .{@tagName(event_queue.pull().?)});
    }
    event_queue.push(raw_event);

    if (event_awaiter) |awaiter| {
        if (getEvent()) |evt| {
            finishIOP(awaiter, evt);
            event_awaiter = null;
        }
    }
}

pub fn getEventIOP(iop: *ashet.abi.input.GetEvent) void {
    const proc = ashet.syscalls.getCurrentProcess();

    if (!proc.isExclusiveVideoController()) {
        return ashet.io.finalizeWithError(iop, error.NonExclusiveAccess);
    }

    if (event_awaiter != null) {
        return ashet.io.finalizeWithError(iop, error.InProgress);
    }

    if (getEvent()) |evt| {
        return finishIOP(iop, evt);
    }

    event_awaiter = iop;
}

fn finishIOP(iop: *ashet.abi.input.GetEvent, evt: Event) void {
    const result: ashet.abi.input.GetEvent.Outputs = switch (evt) {
        .keyboard => |data| .{
            .event_type = .keyboard,
            .event = .{ .keyboard = data },
        },
        .mouse => |data| .{
            .event_type = .mouse,
            .event = .{ .mouse = data },
        },
    };
    ashet.io.finalizeWithResult(iop, result);
}

pub fn getEvent() ?Event {
    while (true) {
        const raw_event = event_queue.pull() orelse return null;
        switch (raw_event) {
            .mouse_abs_motion => |data| {
                const max_size = ashet.video.getMaxResolution();

                const old_cursor = cursor;

                cursor.x = @intCast(std.math.clamp(data.x, 0, @as(i17, max_size.width -| 1)));
                cursor.y = @intCast(std.math.clamp(data.y, 0, @as(i17, max_size.height -| 1)));

                return Event{ .mouse = .{
                    .type = .motion,
                    .dx = cursor.x - old_cursor.x,
                    .dy = cursor.y - old_cursor.y,
                    .x = cursor.x,
                    .y = cursor.y,
                    .button = .none,
                } };
            },

            .mouse_rel_motion => |data| {
                const dx = @as(i16, @truncate(std.math.clamp(data.dx, std.math.minInt(i16), std.math.maxInt(i16))));
                const dy = @as(i16, @truncate(std.math.clamp(data.dy, std.math.minInt(i16), std.math.maxInt(i16))));

                const max_size = ashet.video.getMaxResolution();

                cursor.x = @intCast(std.math.clamp(cursor.x + dx, 0, @as(i17, max_size.width -| 1)));
                cursor.y = @intCast(std.math.clamp(cursor.y + dy, 0, @as(i17, max_size.height -| 1)));

                return Event{ .mouse = .{
                    .type = .motion,
                    .dx = dx,
                    .dy = dy,
                    .x = cursor.x,
                    .y = cursor.y,
                    .button = .none,
                } };
            },

            .mouse_button => |data| {
                const event_type = if (data.down)
                    ashet.abi.MouseEvent.Type.button_press
                else
                    ashet.abi.MouseEvent.Type.button_release;
                const button = switch (data.button) {
                    .left => ashet.abi.MouseButton.left,
                    .right => ashet.abi.MouseButton.right,
                    .middle => ashet.abi.MouseButton.middle,
                    .nav_previous => ashet.abi.MouseButton.nav_previous,
                    .nav_next => ashet.abi.MouseButton.nav_next,
                    .wheel_down => ashet.abi.MouseButton.wheel_down,
                    .wheel_up => ashet.abi.MouseButton.wheel_up,
                    else => return null,
                };
                return Event{ .mouse = .{
                    .type = event_type,
                    .dx = 0,
                    .dy = 0,
                    .x = cursor.x,
                    .y = cursor.y,
                    .button = button,
                } };
            },
            .keyboard => |src_event| {
                const key_code = keyboard.model.scancodeToKeycode(src_event.scancode) orelse .unknown;

                switch (key_code) {
                    .shift_left => shift_left_state = src_event.down,
                    .shift_right => shift_right_state = src_event.down,
                    .ctrl_left => ctrl_left_state = src_event.down,
                    .ctrl_right => ctrl_right_state = src_event.down,
                    .alt => alt_state = src_event.down,
                    .alt_graph => alt_graph_state = src_event.down,

                    else => {},
                }

                const modifiers = getKeyboardModifiers();

                const text_ptr = keyboard.layout.translate(key_code, modifiers.shift, modifiers.alt_graph);

                const event = ashet.abi.KeyboardEvent{
                    .scancode = src_event.scancode,
                    .key = key_code,
                    .text = text_ptr,
                    .modifiers = modifiers,
                    .pressed = src_event.down,
                };

                // We swallow the event if the global hotkey system consumes it
                if (ashet.global_hotkeys.handle(event))
                    continue;

                return Event{ .keyboard = event };
            },
        }
    }
}

pub fn getKeyboardModifiers() ashet.abi.KeyboardModifiers {
    return ashet.abi.KeyboardModifiers{
        .shift = shift_left_state or shift_right_state,
        .alt = alt_state,
        .alt_graph = alt_graph_state,
        .ctrl = ctrl_left_state or ctrl_right_state,

        .shift_left = shift_left_state,
        .shift_right = shift_right_state,
        .ctrl_left = ctrl_left_state,
        .ctrl_right = ctrl_right_state,
    };
}

pub const keyboard = struct {
    pub const Key = ashet.abi.KeyCode;

    pub var model: *const Model = &models.pc105;
    pub var layout: *const Layout = &layouts.de;

    pub const models = struct {
        pub const pc105 = Model.compile(@embedFile("../data/keyboard/models/pc105"));
        pub const vnc = Model.compile(@embedFile("../data/keyboard/models/vnc"));
    };

    pub const layouts = struct {
        pub const de = Layout.compile(@embedFile("../data/keyboard/layouts/de"));
    };

    pub const Layout = struct {
        const Strings = struct {
            normal: ?[*:0]const u8 = null,
            shift: ?[*:0]const u8 = null,
            alt_graph: ?[*:0]const u8 = null,
            shift_alt_graph: ?[*:0]const u8 = null,
        };

        const Map = blk: {
            @setEvalBranchQuota(10_000);
            break :blk std.enums.EnumArray(Key, Strings);
        };

        mapping: *const Map,

        pub fn compile(comptime source_def: []const u8) Layout {
            const mapping = comptime blk: {
                const Entry = struct {
                    keycode: Key,
                    strings: Strings = .{},
                };

                @setEvalBranchQuota(100_000);
                var lines = ConfigFileIterator.init(source_def);

                var mapping_list: []const Entry = &.{};

                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "keymap")) {
                        var items = std.mem.tokenizeAny(u8, line, " \t");

                        _ = items.next() orelse unreachable; // this is "scancode"

                        const keycode_str = items.next() orelse @compileError("keymap requires a symbolic keycode: " ++ line);
                        const keycode = std.meta.stringToEnum(Key, keycode_str) orelse @compileError("keymap requires a valid keycode: " ++ keycode_str);

                        var entry = Entry{ .keycode = keycode };

                        entry.strings.normal = internAndMapOptionalString(items.next());
                        entry.strings.shift = internAndMapOptionalString(items.next());
                        entry.strings.alt_graph = internAndMapOptionalString(items.next());
                        entry.strings.shift_alt_graph = internAndMapOptionalString(items.next());

                        if (entry.strings.normal != null) {
                            mapping_list = mapping_list ++ [1]Entry{entry};
                        }
                    } else {
                        @compileError("Invalid line in keyboard model definition: " ++ line);
                    }
                }

                var mapping = Map.initFill(Strings{});

                for (mapping_list) |item| {
                    if (mapping.get(item.keycode).normal != null)
                        @compileError(std.fmt.comptimePrint("Duplicate mapping for scancode {}!", .{item.scancode}));
                    mapping.set(item.keycode, item.strings);
                }

                break :blk mapping;
            };
            return Layout{
                .mapping = &mapping,
            };
        }

        fn internAndMapOptionalString(comptime str: ?[]const u8) ?[*:0]const u8 {
            return if (str) |s|
                internAndMapString(s)
            else
                null;
        }

        fn internAndMapString(comptime str: []const u8) [*:0]const u8 {
            const map = .{
                .LF = "\n",
                .CR = "\r",
                .TAB = "\t",
                .SPACE = " ",
                .NBSPACE = "\u{A0}",
            };

            inline for (std.meta.fields(@TypeOf(map))) |fld| {
                if (std.mem.eql(u8, str, "<" ++ fld.name ++ ">")) {
                    const name = @field(map, fld.name);
                    return internString(name.len, name.*);
                }
            }

            return internString(str.len, str[0..str.len].*);
        }

        fn internString(comptime len: comptime_int, comptime items: [len]u8) [*:0]const u8 {
            const storage: [len + 1]u8 = comptime items ++ [1]u8{0};
            return storage[0..len :0];
        }

        pub fn translate(self: Layout, key: Key, shift: bool, altgr: bool) ?[*:0]const u8 {
            const strings: Strings = self.mapping.get(key);

            if (shift and altgr and strings.shift_alt_graph != null)
                return strings.shift_alt_graph;

            if (altgr and strings.alt_graph != null)
                return strings.alt_graph;

            if (shift and strings.shift != null)
                return strings.shift;

            return strings.normal;
        }
    };

    pub const Model = struct {
        entries: []const ?Key,

        pub fn compile(comptime source_def: []const u8) Model {
            const mapping = comptime blk: {
                const Entry = struct {
                    scancode: u16,
                    keycode: Key,
                };

                @setEvalBranchQuota(100_000);
                var lines = ConfigFileIterator.init(source_def);

                var mapping_list: []const Entry = &.{};
                var limit = 0;

                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "scancode")) {
                        var items = std.mem.tokenizeAny(u8, line, " \t");

                        _ = items.next() orelse unreachable; // this is "scancode"

                        const scancode_str = items.next() orelse @compileError("scancode requires a numeric scancode: " ++ line);
                        const keycode_str = items.next() orelse @compileError("scancode requires a symbolic keycode: " ++ line);

                        const scancode = std.fmt.parseInt(u16, scancode_str, 0) catch @compileError("scancode requires a numeric scancode: " ++ scancode_str);
                        const keycode = std.meta.stringToEnum(Key, keycode_str) orelse @compileError("scancode requires a valid keycode: " ++ keycode_str);

                        mapping_list = mapping_list ++ [1]Entry{Entry{
                            .scancode = scancode,
                            .keycode = keycode,
                        }};

                        if (limit < scancode)
                            limit = scancode;
                    } else {
                        @compileError("Invalid line in keyboard model definition: " ++ line);
                    }
                }

                var mapping = [1]?Key{null} ** (limit + 1);
                for (mapping_list) |item| {
                    if (mapping[item.scancode] != null)
                        @compileError(std.fmt.comptimePrint("Duplicate mapping for scancode {}!", .{item.scancode}));
                    mapping[item.scancode] = item.keycode;
                }

                break :blk mapping;
            };
            return Model{
                .entries = &mapping,
            };
        }

        pub fn scancodeToKeycode(self: Model, scancode: u16) ?ashet.abi.KeyCode {
            return if (scancode < self.entries.len)
                self.entries[scancode]
            else
                null;
        }
    };

    const ConfigFileIterator = struct {
        iter: std.mem.TokenIterator(u8, .any),

        pub fn init(str: []const u8) ConfigFileIterator {
            return .{
                .iter = std.mem.tokenizeAny(u8, str, "\r\n"),
            };
        }

        pub fn next(self: *ConfigFileIterator) ?[]const u8 {
            while (self.iter.next()) |raw_line| {
                const trimmed_line = std.mem.trim(u8, raw_line, " \t\r\n");
                if (std.mem.startsWith(u8, trimmed_line, "#"))
                    continue;
                return trimmed_line;
            }
            return null;
        }
    };
};
