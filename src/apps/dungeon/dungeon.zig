const std = @import("std");
const ashet = @import("ashet");
const gui = @import("ashet-gui");
const Vec2 = @import("Vector2.zig");

pub usingnamespace ashet.core;

const ColorIndex = ashet.abi.ColorIndex;

var raycaster: Raycaster = .{};

pub fn main() !void {
    if (!ashet.video.acquire()) {
        ashet.process.exit(1);
    }

    ashet.video.setResolution(400, 300);
    ashet.video.setBorder(ColorIndex.get(2));

    render();

    while (true) {
        var moved = false;
        const event = try ashet.input.getEvent();
        switch (event) {
            .mouse => |data| std.log.info("mouse => {}", .{data}),
            .keyboard => |data| {
                if (data.pressed and data.key == .escape)
                    return;
                // std.log.info("keyboard: pressed={}, alt={}, shift={}, ctrl={}, altgr={}, scancode={d: >3}, key={s: <10}, text='{?s}'", .{
                //     @boolToInt(data.pressed),
                //     @boolToInt(data.modifiers.alt),
                //     @boolToInt(data.modifiers.shift),
                //     @boolToInt(data.modifiers.ctrl),
                //     @boolToInt(data.modifiers.alt_graph),
                //     data.scancode,
                //     @tagName(data.key),
                //     data.text,
                // });
                if (data.pressed) {
                    moved = true;

                    const fwd = Vec2.unitX.rotate(raycaster.camera_rotation).scale(0.1);
                    const right = Vec2.unitY.rotate(raycaster.camera_rotation).scale(0.1);

                    switch (data.key) {
                        .up => raycaster.camera_position = raycaster.camera_position.add(fwd),
                        .down => raycaster.camera_position = raycaster.camera_position.sub(fwd),

                        .left => raycaster.camera_position = raycaster.camera_position.sub(right),
                        .right => raycaster.camera_position = raycaster.camera_position.add(right),

                        .page_up => raycaster.camera_rotation -= 0.1,
                        .page_down => raycaster.camera_rotation += 0.1,

                        else => moved = false,
                    }
                }
            },
        }
        if (moved) {
            render();
        }
    }
}

const screen_width = 400;
const screen_height = 300;

var clonebuffer: [screen_width * screen_height]ColorIndex = undefined;

fn render() void {
    std.mem.set(ColorIndex, &clonebuffer, ColorIndex.get(0));

    const fb = gui.Framebuffer{
        .width = screen_width,
        .height = screen_height,
        .stride = screen_width,
        .pixels = &clonebuffer,
    };

    raycaster.drawWalls(fb);

    // double buffering:
    std.mem.copy(ashet.abi.Color, ashet.video.getPaletteMemory(), &palette);
    std.mem.copy(ColorIndex, ashet.video.getVideoMemory()[0..clonebuffer.len], &clonebuffer);
}

const Texture = struct {
    const width = 32;
    const height = 32;

    pixels: [width][height]ColorIndex,
    palette: [16]ashet.abi.Color,

    pub inline fn sample(tex: Texture, x: i32, y: i32) ColorIndex {
        @setRuntimeSafety(false);
        const u = @bitCast(u32, x) & (width - 1);
        const v = @bitCast(u32, y) & (height - 1);
        return tex.pixels[v][u];
    }

    pub fn load(bmp_src: gui.Bitmap.EmbeddedBitmap) Texture {
        const bmp = bmp_src.bitmap;
        if (bmp.width != width or bmp.height != height)
            @panic("invalid bitmap");
        if (bmp_src.palette.len > 16)
            @panic("palette too large");
        if (bmp.transparent != null)
            @panic("transparent texture");
        var tex = Texture{
            .pixels = @bitCast([width][height]ColorIndex, bmp.pixels[0 .. width * height].*),
            .palette = undefined,
        };
        std.mem.copy(ashet.abi.Color, &tex.palette, bmp_src.palette);
        return tex;
    }
};

const textures = [_]Texture{
    Texture.load(gui.Bitmap.embed(@embedFile("data/floor.abm"))),
    Texture.load(gui.Bitmap.embed(@embedFile("data/wall-plain.abm"))),
    Texture.load(gui.Bitmap.embed(@embedFile("data/wall-cobweb.abm"))),
    Texture.load(gui.Bitmap.embed(@embedFile("data/wall-paper.abm"))),
    Texture.load(gui.Bitmap.embed(@embedFile("data/wall-vines.abm"))),
    Texture.load(gui.Bitmap.embed(@embedFile("data/wall-door.abm"))),
    Texture.load(gui.Bitmap.embed(@embedFile("data/wall-post-l.abm"))),
    Texture.load(gui.Bitmap.embed(@embedFile("data/wall-post-r.abm"))),
};

const palette = blk: {
    var pal: [256]ashet.abi.Color = undefined;
    for (textures) |tex, i| {
        std.mem.copy(
            ashet.abi.Color,
            pal[16 * i ..],
            &tex.palette,
        );
    }
    break :blk pal;
};

const Raycaster = struct {
    const width = screen_width;
    const height = screen_height;
    const aspect = @intToFloat(f32, screen_width) / @intToFloat(f32, screen_height);

    const floor_color = ashet.abi.ColorIndex.get(3); // dim gray
    const ceiling_color = ashet.abi.ColorIndex.get(8); // light blue

    const walls = [_]Wall{
        Wall{
            .texture_id = 1,
            .points = .{ Vec2.new(2, -0.5), Vec2.new(-2, -0.5) },
            .u_offset = .{ 0, 4 },
        },

        Wall{
            .texture_id = 1,
            .points = .{ Vec2.new(2, -0.5), Vec2.new(2, 0.5) },
            .u_offset = .{ 0, 1 },
        },

        Wall{
            .texture_id = 5,
            .points = .{ Vec2.new(2, 0.5), Vec2.new(2, 1.5) },
            .u_offset = .{ 0, 1 },
        },

        Wall{
            .texture_id = 1,
            .points = .{ Vec2.new(2, 1.5), Vec2.new(2, 2.5) },
            .u_offset = .{ 0, 1 },
        },

        Wall{
            .texture_id = 1,
            .points = .{ Vec2.new(2, 2.5), Vec2.new(-2, 2.5) },
            .u_offset = .{ 0, 4 },
        },

        Wall{
            .texture_id = 1,
            .points = .{ Vec2.new(-2, -0.5), Vec2.new(-2, 2.5) },
            .u_offset = .{ 0, 3 },
        },
    };

    camera_rotation: f32 = 0,
    camera_position: Vec2 = Vec2.zero,
    zbuffer: [width]f32 = undefined,

    /// returns the direction a ray has when going through a specifc column
    fn getRayDirection(rc: Raycaster, column: usize) Vec2 {
        return protorays[column].rotate(rc.camera_rotation);
    }

    const protorays = blk: {
        @setEvalBranchQuota(10_000);

        var rays: [width]Vec2 = undefined;
        for (rays) |*dir, x| {
            const fx = aspect * (2.0 * (@intToFloat(f32, x) / (width - 1)) - 1.0);

            const deltaAngle = std.math.atan(0.5 * fx);

            const raw_dir = Vec2.unitX.rotate(deltaAngle);

            // set length of x to 1 for early correct perspective correction
            dir.* = raw_dir.scale(1.0 / raw_dir.x);
        }
        break :blk rays;
    };

    const Wall = struct {
        texture_id: u16,
        points: [2]Vec2,
        u_offset: [2]f32,
    };

    const RaycastResult = struct {
        wall: *const Wall,
        distance: f32,
        u: f32,
    };

    fn drawWalls(rc: *Raycaster, fb: gui.Framebuffer) void {
        std.debug.assert(fb.width == width);
        std.debug.assert(fb.height == height);

        // render the walls
        var x: u15 = 0;
        while (x < width) : (x += 1) {
            // std.log.info("cast {}...", .{x});
            // rotate our precalculated ray
            const dir = rc.getRayDirection(x);

            // Raycast here
            var maybe_hit = castRay(rc.camera_position, dir);

            var wallHeight: u32 = 0;
            rc.zbuffer[x] = if (maybe_hit) |result| blk: {
                // std.log.info("hit {}", .{result});
                if (result.distance < 0.01) {
                    // znear discard
                    maybe_hit = null;
                    break :blk std.math.inf(f32);
                }

                // project the wall height onto the screen and
                // adjust the zbuffer
                wallHeight = @floatToInt(u32, height / @fabs(result.distance) + 0.5);
                // std.log.info("x={} => d={d} => {}", .{ x, result.distance, wallHeight });
                break :blk result.distance;
            } else std.math.inf(f32); // no hit means infinite distance

            // calculate screen boundaries of the wall
            const wallTop = (height / 2) -| (wallHeight / 2);
            const wallBottom = (height / 2) +| (wallHeight / 2);

            //   // draw the ceiling with either texture or color
            //   if constexpr (not ceiling_color) {
            //     real constexpr factor = real(2.0 / (height - 1));
            //     real fy = real(1.0);

            //     for (int y = 0; y < wallTop; y++, fy -= factor) {
            //       // real const fy = real(1.0) - factor * real(y);

            //       if (fy == real(0))
            //         continue;

            //       real const d = real(1.0) / fy;

            //       vec2_t const pos(CameraPosition + dir * d);

            //       int const u(int(real(int(indoor_ceiling.width)) * fract(pos.x)));
            //       int const v(int(real(int(indoor_ceiling.height)) * fract(pos.y)));

            //       setPixel(x, y, indoor_ceiling(u, v));
            //       if (y < wallTop - 1) {
            //         setPixel(x, y, indoor_ceiling(u + 1, v + 1));
            //         y++;
            //         fy -= factor;
            //       }
            //     }
            //   } else
            {
                var y: u15 = 0;
                while (y < wallTop) : (y += 1) {
                    fb.setPixel(x, y, ceiling_color);
                }
            }

            //   // draw the wall

            //   auto const walltex = wall_textures[texture_index];

            if (maybe_hit) |result| {
                const tex_id = result.wall.texture_id;
                const walltex = &textures[tex_id];

                const index_shift = @intCast(u8, 16 * tex_id);

                const u = @floatToInt(i32, @intToFloat(f32, Texture.width - 1) * (result.u - @floor(result.u)));

                const maxy = std.math.min(height, wallBottom);

                var y: u15 = @truncate(u15, std.math.clamp(wallTop, 0, height));
                while (y < maxy) : (y += 1) {
                    // TODO: Fix y computation
                    const v = @intCast(i32, Texture.height * (y - wallTop) / wallHeight);
                    fb.setPixel(x, y, walltex.sample(u, v).shift(index_shift));
                }
            }

            //   if constexpr (not floor_color) {
            //     for (int y = wallBottom; y < height; y++) {
            //       real const fy =
            //           real(1.0 / (height / 2)) * real(y - int(height / 2) + 1);

            //       if (fy == real(0))
            //         continue;

            //       real const d = real(1.0) / fy;

            //       vec2_t const pos(CameraPosition + dir * d);

            //       int const u(int(real(int(dirt.width) - 1) * fract(pos.x)));
            //       int const v(int(real(int(dirt.height) - 1) * fract(pos.y)));

            //       setPixel(x, y, dirt(u, v));
            //     }
            //   } else {
            {
                var y: u15 = @truncate(u15, std.math.min(height, wallBottom));
                while (y < height) : (y += 1) {
                    fb.setPixel(x, y, floor_color);
                }
            }
        }
    }

    fn intersect(ray_pos: Vec2, ray_dir: Vec2, line_start: Vec2, line_offset: Vec2, t: *f32, u: *f32) bool {
        const d = Vec2.cross(ray_dir, line_offset);
        const v = line_start.sub(ray_pos);

        if (d == 0) // parallel or colinear
            return false;

        t.* = Vec2.cross(v, line_offset) / d;
        u.* = Vec2.cross(v, ray_dir) / d;

        return (t.* >= 0.0) and (u.* >= 0.0 and u.* <= 1.0);
    }

    fn castRay(pos: Vec2, dir: Vec2) ?RaycastResult {
        var nearest: ?RaycastResult = null;

        for (walls) |*wall| {
            var t: f32 = undefined;
            var u: f32 = undefined;
            if (!intersect(pos, dir, wall.points[0], wall.points[1].sub(wall.points[0]), &t, &u))
                continue;

            // std.log.info("wall hit with {} distance", .{t});

            if ((nearest == null) or (nearest.?.distance > t)) {
                nearest = RaycastResult{
                    .distance = t,
                    .wall = wall,
                    .u = wall.u_offset[0] + u * (wall.u_offset[1] - wall.u_offset[0]),
                };
            }
        }

        return nearest;
    }
};
