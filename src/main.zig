const std = @import("std");
const wayland = @import("wayland");
const clap = @import("clap");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const wp = wayland.client.wp;

const ColorFormat = enum {
    cmyk,
    hex,
    rgb,
    hsl,
    hsv,
};

const Cli = struct {
    autocopy: bool = false,
    format: ColorFormat = .hex,
    lowercase_hex: bool = false,
    no_fancy: bool = false,
    no_zoom: bool = false,
    quiet: bool = false,
    render_inactive: bool = false,
};

const Screenshot = struct {
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: wl.Shm.Format = .argb8888,
    pixels: []u8 = &[_]u8{},
    buffer: ?*wl.Buffer = null,
    ready: bool = false,
};

const RenderBuffer = struct {
    buffer: ?*wl.Buffer = null,
    pixels: []u8 = &[_]u8{},
    busy: bool = false,
    last_cx: i32 = -1,
    last_cy: i32 = -1,
};

// Represents one physical monitor: its wl_output, its screencopy capture,
// the layer-shell surface drawn on top of it, and its double-buffer state.
const OutputEntry = struct {
    output: *wl.Output,
    scale: i32 = 1,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    screenshot: Screenshot = .{},
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    configured: bool = false,
    render_buffers: [2]RenderBuffer = .{ .{}, .{} },
    active: bool = false,
};

const State = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    screencopy_manager: ?*zwlr.ScreencopyManagerV1 = null,
    // All detected outputs.
    outputs: std.ArrayList(OutputEntry),
    // The output the pointer is currently on (index into outputs).
    active_output_idx: usize = 0,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    cursor_x: i32 = -1,
    cursor_y: i32 = -1,
    running: bool = true,
    cli: Cli,
    allocator: std.mem.Allocator,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    cursor_shape_device: ?*wp.CursorShapeDeviceV1 = null,
    frame_callback: ?*wl.Callback = null,
    needs_redraw: bool = false,
    // Convenience: display handle so listeners can dispatch/roundtrip if needed.
    display: *wl.Display = undefined,
};

fn rgbToHsl(r: u8, g: u8, b: u8) [3]f32 {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;

    const cmax = @max(rf, @max(gf, bf));
    const cmin = @min(rf, @min(gf, bf));
    const delta = cmax - cmin;

    var h: f32 = 0;
    var s: f32 = 0;
    const l: f32 = (cmax + cmin) / 2.0;

    if (delta != 0.0) {
        s = delta / (1.0 - @abs(2.0 * l - 1.0));
        if (cmax == rf) {
            h = 60.0 * @mod(((gf - bf) / delta), 6.0);
        } else if (cmax == gf) {
            h = 60.0 * (((bf - rf) / delta) + 2.0);
        } else {
            h = 60.0 * (((rf - gf) / delta) + 4.0);
        }
    }
    if (h < 0) h += 360.0;
    return .{ h, s * 100.0, l * 100.0 };
}

fn rgbToHsv(r: u8, g: u8, b: u8) [3]f32 {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;

    const cmax = @max(rf, @max(gf, bf));
    const cmin = @min(rf, @min(gf, bf));
    const delta = cmax - cmin;

    var h: f32 = 0;
    var s: f32 = 0;
    const v: f32 = cmax;

    if (delta != 0.0) {
        s = delta / cmax;
        if (cmax == rf) {
            h = 60.0 * @mod(((gf - bf) / delta), 6.0);
        } else if (cmax == gf) {
            h = 60.0 * (((bf - rf) / delta) + 2.0);
        } else {
            h = 60.0 * (((rf - gf) / delta) + 4.0);
        }
    }
    if (h < 0) h += 360.0;
    return .{ h, s * 100.0, v * 100.0 };
}

fn rgbToCmyk(r: u8, g: u8, b: u8) [4]f32 {
    const rf = @as(f32, @floatFromInt(r)) / 255.0;
    const gf = @as(f32, @floatFromInt(g)) / 255.0;
    const bf = @as(f32, @floatFromInt(b)) / 255.0;

    const cmax = @max(rf, @max(gf, bf));
    const k = 1.0 - cmax;

    if (k == 1.0) return .{ 0.0, 0.0, 0.0, 100.0 };

    const c = (1.0 - rf - k) / (1.0 - k);
    const m = (1.0 - gf - k) / (1.0 - k);
    const y = (1.0 - bf - k) / (1.0 - k);

    return .{ c * 100.0, m * 100.0, y * 100.0, k * 100.0 };
}

fn keyboardListener(
    keyboard: *wl.Keyboard,
    event: wl.Keyboard.Event,
    state: *State,
) void {
    _ = keyboard;
    switch (event) {
        .key => |k| {
            if (k.key == 1 and k.state == .pressed) { // Escape
                state.running = false;
            }
        },
        else => {},
    }
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    state: *State,
) void {
    switch (event) {
        .global => |g| {
            // Each wl_output gets its own OutputEntry.
            if (std.mem.orderZ(u8, g.interface, wl.Output.interface.name) == .eq) {
                const output = registry.bind(g.name, wl.Output, 4) catch return;
                const entry = OutputEntry{ .output = output };
                state.outputs.append(state.allocator, entry) catch return;
                const idx = state.outputs.items.len - 1;
                state.outputs.items[idx].output.setListener(*State, outputListener, state);
                return;
            }

            const bindings = .{
                .{ wl.Compositor, &state.compositor, 5 },
                .{ wl.Shm, &state.shm, 1 },
                .{ wl.Seat, &state.seat, 5 },
                .{ zwlr.LayerShellV1, &state.layer_shell, 4 },
                .{ zwlr.ScreencopyManagerV1, &state.screencopy_manager, 3 },
                .{ wp.CursorShapeManagerV1, &state.cursor_shape_manager, 1 },
            };

            inline for (bindings) |b| {
                if (std.mem.orderZ(u8, g.interface, b[0].interface.name) == .eq) {
                    b[1].* = registry.bind(g.name, b[0], @min(g.version, b[2])) catch return;
                }
            }
        },
        .global_remove => {},
    }
}

fn outputListener(
    output: *wl.Output,
    event: wl.Output.Event,
    state: *State,
) void {
    // Find which entry owns this output.
    for (state.outputs.items) |*entry| {
        if (entry.output == output) {
            switch (event) {
                .scale => |s| entry.scale = s.factor,
                .geometry => |g| {
                    entry.x = g.x;
                    entry.y = g.y;
                },
                .mode => |m| {
                    entry.width = m.width;
                    entry.height = m.height;
                },
                else => {},
            }
            return;
        }
    }
}

// We need to know which entry a screencopy frame belongs to, so we use a
// small context struct instead of passing State directly.
const ScreencopyCtx = struct {
    state: *State,
    entry_idx: usize,
};

fn screencopyFrameListener(
    frame: *zwlr.ScreencopyFrameV1,
    event: zwlr.ScreencopyFrameV1.Event,
    ctx: *ScreencopyCtx,
) void {
    const entry = &ctx.state.outputs.items[ctx.entry_idx];
    switch (event) {
        .buffer => |b| {
            entry.screenshot.width = b.width;
            entry.screenshot.height = b.height;
            entry.screenshot.stride = b.stride;
            entry.screenshot.format = b.format;

            const size = b.stride * b.height;

            const fd = std.posix.memfd_create("pickz-capture", 0) catch unreachable;
            std.posix.ftruncate(fd, size) catch unreachable;

            entry.screenshot.pixels = std.posix.mmap(
                null,
                size,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                std.posix.MAP{ .TYPE = .SHARED },
                fd,
                0,
            ) catch unreachable;

            const pool = ctx.state.shm.?.createPool(fd, @intCast(size)) catch unreachable;
            defer pool.destroy();

            entry.screenshot.buffer = pool.createBuffer(
                0,
                @intCast(b.width),
                @intCast(b.height),
                @intCast(b.stride),
                b.format,
            ) catch unreachable;

            frame.copy(entry.screenshot.buffer.?);
        },
        .ready => {
            entry.screenshot.ready = true;
        },
        .failed => {
            std.process.exit(1);
        },
        else => {},
    }
}

fn layerSurfaceListener(
    layer_surface: *zwlr.LayerSurfaceV1,
    event: zwlr.LayerSurfaceV1.Event,
    state: *State,
) void {
    // Find the entry that owns this layer surface.
    for (state.outputs.items) |*entry| {
        if (entry.layer_surface == layer_surface) {
            switch (event) {
                .configure => |cfg| {
                    layer_surface.ackConfigure(cfg.serial);
                    entry.configured = true;
                },
                .closed => std.process.exit(0),
            }
            return;
        }
    }
}

fn bufferReleaseListener(
    buffer: *wl.Buffer,
    event: wl.Buffer.Event,
    state: *State,
) void {
    switch (event) {
        .release => {
            for (state.outputs.items) |*entry| {
                for (&entry.render_buffers) |*rb| {
                    if (rb.buffer == buffer) {
                        rb.busy = false;
                        if (state.needs_redraw and state.frame_callback == null) {
                            drawLens(state);
                        }
                        return;
                    }
                }
            }
        },
    }
}

fn frameListener(
    callback: *wl.Callback,
    event: wl.Callback.Event,
    state: *State,
) void {
    switch (event) {
        .done => {
            callback.destroy();
            state.frame_callback = null;
            if (state.needs_redraw) {
                drawLens(state);
            }
        },
    }
}

fn drawLens(state: *State) void {
    // When --no-zoom is set we never overdraw anything; the frozen screenshot
    // already covers the surface.  We still need to pick up pointer events, so
    // we just return early here.
    if (state.cli.no_zoom) return;

    if (state.frame_callback != null) {
        state.needs_redraw = true;
        return;
    }

    // Only draw on the active output (the one under the pointer).
    if (state.outputs.items.len == 0) return;
    const entry = &state.outputs.items[state.active_output_idx];
    if (entry.surface == null) return;
    if (state.cursor_x < 0 or state.cursor_y < 0) return;

    var target_buffer: ?*RenderBuffer = null;
    for (&entry.render_buffers) |*rb| {
        if (!rb.busy and rb.buffer != null) {
            target_buffer = rb;
            break;
        }
    }
    if (target_buffer == null) {
        state.needs_redraw = true;
        return;
    }

    state.needs_redraw = false;

    const rb = target_buffer.?;
    const scale = entry.scale;
    const cx = state.cursor_x * scale;
    const cy = state.cursor_y * scale;

    const inner_radius: i32 = 100;
    const border_thickness: i32 = 5;
    const zoom: i32 = 10;

    const outer_radius = inner_radius + border_thickness;
    const outer_radius_sq = outer_radius * outer_radius;
    const inner_radius_sq = inner_radius * inner_radius;
    const box_size = (outer_radius * 2) + 1;

    const width_i32: i32 = @intCast(entry.screenshot.width);
    const height_i32: i32 = @intCast(entry.screenshot.height);
    const stride: usize = @intCast(entry.screenshot.stride);

    // Restore the previously drawn region from the clean screenshot.
    if (rb.last_cx >= 0 and rb.last_cy >= 0) {
        const old_x0 = std.math.clamp(rb.last_cx - outer_radius, 0, width_i32);
        const old_y0 = std.math.clamp(rb.last_cy - outer_radius, 0, height_i32);
        const old_x1 = std.math.clamp(rb.last_cx + outer_radius + 1, 0, width_i32);
        const old_y1 = std.math.clamp(rb.last_cy + outer_radius + 1, 0, height_i32);
        const row_bytes: usize = @intCast((old_x1 - old_x0) * 4);

        var y: i32 = old_y0;
        while (y < old_y1) : (y += 1) {
            const row_start = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(old_x0)) * 4;
            const dst = rb.pixels[row_start .. row_start + row_bytes];
            const src = entry.screenshot.pixels[row_start .. row_start + row_bytes];
            @memcpy(dst, src);
        }

        entry.surface.?.damageBuffer(old_x0, old_y0, box_size, box_size);
    }

    // Sample the center pixel for the border color.
    var border_b: u8 = 0;
    var border_g: u8 = 0;
    var border_r: u8 = 0;
    if (cx >= 0 and cx < entry.screenshot.width and cy >= 0 and cy < entry.screenshot.height) {
        const center_idx = @as(usize, @intCast(cy)) * entry.screenshot.stride + @as(usize, @intCast(cx)) * 4;
        border_b = entry.screenshot.pixels[center_idx];
        border_g = entry.screenshot.pixels[center_idx + 1];
        border_r = entry.screenshot.pixels[center_idx + 2];
    }

    var dy: i32 = -outer_radius;
    while (dy <= outer_radius) : (dy += 1) {
        var dx: i32 = -outer_radius;
        while (dx <= outer_radius) : (dx += 1) {
            const dist_sq = (dx * dx) + (dy * dy);
            if (dist_sq > outer_radius_sq) continue;

            const target_x = cx + dx;
            const target_y = cy + dy;

            if (target_x >= 0 and target_x < entry.screenshot.width and
                target_y >= 0 and target_y < entry.screenshot.height)
            {
                const dst_idx = @as(usize, @intCast(target_y)) * entry.screenshot.stride +
                    @as(usize, @intCast(target_x)) * 4;

                if (dist_sq > inner_radius_sq) {
                    // Border ring: tinted with the center pixel color.
                    rb.pixels[dst_idx] = border_b;
                    rb.pixels[dst_idx + 1] = border_g;
                    rb.pixels[dst_idx + 2] = border_r;
                    rb.pixels[dst_idx + 3] = 255;
                } else {
                    // Magnified region.
                    const src_x = cx + @divTrunc(dx, zoom);
                    const src_y = cy + @divTrunc(dy, zoom);

                    if (src_x >= 0 and src_x < entry.screenshot.width and
                        src_y >= 0 and src_y < entry.screenshot.height)
                    {
                        const src_idx = @as(usize, @intCast(src_y)) * entry.screenshot.stride +
                            @as(usize, @intCast(src_x)) * 4;
                        rb.pixels[dst_idx] = entry.screenshot.pixels[src_idx];
                        rb.pixels[dst_idx + 1] = entry.screenshot.pixels[src_idx + 1];
                        rb.pixels[dst_idx + 2] = entry.screenshot.pixels[src_idx + 2];
                        rb.pixels[dst_idx + 3] = 255;
                    }
                }
            }
        }
    }

    rb.last_cx = cx;
    rb.last_cy = cy;

    rb.busy = true;
    entry.surface.?.attach(rb.buffer, 0, 0);
    entry.surface.?.damageBuffer(cx - outer_radius, cy - outer_radius, box_size, box_size);
    state.frame_callback = entry.surface.?.frame() catch return;
    state.frame_callback.?.setListener(*State, frameListener, state);
    entry.surface.?.commit();
}

fn pointerListener(
    pointer: *wl.Pointer,
    event: wl.Pointer.Event,
    state: *State,
) void {
    _ = pointer;
    switch (event) {
        .enter => |e| {
            // Identify which output's surface the pointer entered.
            for (state.outputs.items, 0..) |*entry, idx| {
                if (entry.surface != null) {
                    // The enter event carries a surface pointer; compare them.
                    if (entry.surface == e.surface) {
                        state.active_output_idx = idx;
                        break;
                    }
                }
            }
            state.cursor_x = e.surface_x.toInt();
            state.cursor_y = e.surface_y.toInt();
            if (state.cursor_shape_device) |device| {
                device.setShape(e.serial, .crosshair);
            }
            state.needs_redraw = true;
            drawLens(state);
        },
        .motion => |m| {
            state.cursor_x = m.surface_x.toInt();
            state.cursor_y = m.surface_y.toInt();
            state.needs_redraw = true;
            drawLens(state);
        },
        .button => |b| {
            if (b.button == 272 and b.state == .pressed) { // left click
                if (state.outputs.items.len == 0) return;
                const entry = &state.outputs.items[state.active_output_idx];
                const cx = state.cursor_x * entry.scale;
                const cy = state.cursor_y * entry.scale;

                if (cx >= 0 and cx < entry.screenshot.width and
                    cy >= 0 and cy < entry.screenshot.height)
                {
                    const idx = @as(usize, @intCast(cy)) * entry.screenshot.stride +
                        @as(usize, @intCast(cx)) * 4;

                    const blue = entry.screenshot.pixels[idx];
                    const green = entry.screenshot.pixels[idx + 1];
                    const red = entry.screenshot.pixels[idx + 2];

                    var buf_no_nl: [64]u8 = undefined;
                    var len_no_nl: usize = 0;

                    switch (state.cli.format) {
                        .hex => {
                            if (state.cli.lowercase_hex) {
                                len_no_nl = (std.fmt.bufPrint(
                                    &buf_no_nl,
                                    "#{x:0>2}{x:0>2}{x:0>2}",
                                    .{ red, green, blue },
                                ) catch return).len;
                            } else {
                                len_no_nl = (std.fmt.bufPrint(
                                    &buf_no_nl,
                                    "#{X:0>2}{X:0>2}{X:0>2}",
                                    .{ red, green, blue },
                                ) catch return).len;
                            }
                        },
                        .rgb => {
                            len_no_nl = (std.fmt.bufPrint(
                                &buf_no_nl,
                                "rgb({d}, {d}, {d})",
                                .{ red, green, blue },
                            ) catch return).len;
                        },
                        .hsl => {
                            const hsl = rgbToHsl(red, green, blue);
                            len_no_nl = (std.fmt.bufPrint(
                                &buf_no_nl,
                                "hsl({d:.1}, {d:.1}%, {d:.1}%)",
                                .{ hsl[0], hsl[1], hsl[2] },
                            ) catch return).len;
                        },
                        .hsv => {
                            const hsv = rgbToHsv(red, green, blue);
                            len_no_nl = (std.fmt.bufPrint(
                                &buf_no_nl,
                                "hsv({d:.1}, {d:.1}%, {d:.1}%)",
                                .{ hsv[0], hsv[1], hsv[2] },
                            ) catch return).len;
                        },
                        .cmyk => {
                            const cmyk = rgbToCmyk(red, green, blue);
                            len_no_nl = (std.fmt.bufPrint(
                                &buf_no_nl,
                                "cmyk({d:.1}%, {d:.1}%, {d:.1}%, {d:.1}%)",
                                .{ cmyk[0], cmyk[1], cmyk[2], cmyk[3] },
                            ) catch return).len;
                        },
                    }

                    const final_no_nl = buf_no_nl[0..len_no_nl];

                    if (!state.cli.quiet) {
                        const is_tty = std.posix.isatty(std.fs.File.stdout().handle);

                        // --no-fancy disables colored terminal output regardless of TTY.
                        if (is_tty and !state.cli.no_fancy) {
                            const luminance = (299 * @as(u32, red) + 587 * @as(u32, green) +
                                114 * @as(u32, blue)) / 1000;
                            const fg_code: []const u8 = if (luminance > 128) "\x1b[30m" else "\x1b[97m";

                            var stdout_buf: [128]u8 = undefined;
                            const colored_output = std.fmt.bufPrint(
                                &stdout_buf,
                                "\x1b[48;2;{d};{d};{d}m{s}{s}\x1b[0m\n",
                                .{ red, green, blue, fg_code, final_no_nl },
                            ) catch return;
                            std.fs.File.stdout().writeAll(colored_output) catch {};
                        } else {
                            var plain_buf: [72]u8 = undefined;
                            const plain_output = std.fmt.bufPrint(
                                &plain_buf,
                                "{s}\n",
                                .{final_no_nl},
                            ) catch return;
                            std.fs.File.stdout().writeAll(plain_output) catch {};
                        }
                    }

                    if (state.cli.autocopy) {
                        var child = std.process.Child.init(
                            &[_][]const u8{ "wl-copy", final_no_nl },
                            state.allocator,
                        );
                        _ = child.spawnAndWait() catch |err| {
                            std.debug.print(
                                "Error: Could not copy to clipboard. Is 'wl-clipboard' installed? ({})\n",
                                .{err},
                            );
                        };
                    }
                }

                state.running = false;
            }
        },
        else => {},
    }
}

fn initRenderBuffers(state: *State, entry: *OutputEntry) void {
    const size = entry.screenshot.stride * entry.screenshot.height;
    for (&entry.render_buffers) |*rb| {
        const fd = std.posix.memfd_create("pickz-draw", 0) catch unreachable;
        std.posix.ftruncate(fd, size) catch unreachable;

        rb.pixels = std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            std.posix.MAP{ .TYPE = .SHARED },
            fd,
            0,
        ) catch unreachable;

        const pool = state.shm.?.createPool(fd, @intCast(size)) catch unreachable;
        defer pool.destroy();

        rb.buffer = pool.createBuffer(
            0,
            @intCast(entry.screenshot.width),
            @intCast(entry.screenshot.height),
            @intCast(entry.screenshot.stride),
            entry.screenshot.format,
        ) catch unreachable;
        rb.buffer.?.setListener(*State, bufferReleaseListener, state);
        @memcpy(rb.pixels, entry.screenshot.pixels);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-a, --autocopy            Automatically copies the output to the clipboard (requires wl-clipboard)
        \\-f, --format <str>        Specifies the output format (cmyk, hex, rgb, hsl, hsv)
        \\-l, --lowercase-hex       Outputs the hexcode in lowercase
        \\-n, --no-fancy            Disables colored terminal output
        \\-z, --no-zoom             Disables the zoom lens
        \\-q, --quiet               Suppresses all non-error output
        \\-r, --render-inactive     Freeze and render all displays (not just the active one)
        \\-h, --help                Show this help message
        \\-V, --version             Print version info
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(std.fs.File.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(std.fs.File.stderr(), clap.Help, &params, .{});
    }
    if (res.args.version != 0) {
        std.debug.print("pickz v{s}\n", .{@import("build_options").version});
        return;
    }

    const selected_format: ColorFormat = if (res.args.format) |fmt_str|
        std.meta.stringToEnum(ColorFormat, fmt_str) orelse {
            std.debug.print("Invalid format: {s}\nValid options: cmyk, hex, rgb, hsl, hsv\n", .{fmt_str});
            std.process.exit(1);
        }
    else
        .hex;

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    var state = State{
        .allocator = allocator,
        .display = display,
        .outputs = try std.ArrayList(OutputEntry).initCapacity(allocator, 0),
        .cli = .{
            .autocopy = res.args.autocopy != 0,
            .format = selected_format,
            .lowercase_hex = res.args.@"lowercase-hex" != 0,
            .no_fancy = res.args.@"no-fancy" != 0,
            .no_zoom = res.args.@"no-zoom" != 0,
            .quiet = res.args.quiet != 0,
            .render_inactive = res.args.@"render-inactive" != 0,
        },
    };
    defer state.outputs.deinit(allocator);

    const registry = try display.getRegistry();
    registry.setListener(*State, registryListener, &state);

    // Two roundtrips: first populates globals, second flushes output events.
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    if (state.compositor == null or state.shm == null or
        state.layer_shell == null or state.screencopy_manager == null)
    {
        return error.MissingGlobals;
    }
    if (state.outputs.items.len == 0) return error.NoOutputs;

    // We always capture all outputs so render_inactive can show frozen content.
    // Allocate ScreencopyCtx on the heap so each frame listener has a stable ptr.
    var screencopy_ctxs = try allocator.alloc(ScreencopyCtx, state.outputs.items.len);
    defer allocator.free(screencopy_ctxs);

    for (state.outputs.items, 0..) |*entry, i| {
        screencopy_ctxs[i] = .{ .state = &state, .entry_idx = i };
        const frame = try state.screencopy_manager.?.captureOutput(0, entry.output);
        frame.setListener(*ScreencopyCtx, screencopyFrameListener, &screencopy_ctxs[i]);
    }

    // Pump until every output has a complete screenshot.
    var all_ready = false;
    while (!all_ready) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        all_ready = true;
        for (state.outputs.items) |*entry| {
            if (!entry.screenshot.ready) {
                all_ready = false;
                break;
            }
        }
    }

    for (state.outputs.items) |*entry| {
        entry.surface = try state.compositor.?.createSurface();
        entry.layer_surface = try state.layer_shell.?.getLayerSurface(
            entry.surface.?,
            entry.output,
            .overlay,
            "pickz",
        );
        entry.layer_surface.?.setListener(*State, layerSurfaceListener, &state);
        entry.layer_surface.?.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        entry.layer_surface.?.setExclusiveZone(-1);
        // Only the first output gets keyboard focus; we still need to cover the
        // others for --render-inactive.
        if (entry.output == state.outputs.items[0].output) {
            entry.layer_surface.?.setKeyboardInteractivity(.exclusive);
        }
        entry.surface.?.commit();
    }

    // Wait for all layer surfaces to be configured.
    var all_configured = false;
    while (!all_configured) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        all_configured = true;
        for (state.outputs.items) |*entry| {
            if (!entry.configured) {
                all_configured = false;
                break;
            }
        }
    }

    state.pointer = try state.seat.?.getPointer();
    state.pointer.?.setListener(*State, pointerListener, &state);

    state.keyboard = try state.seat.?.getKeyboard();
    state.keyboard.?.setListener(*State, keyboardListener, &state);

    if (state.cursor_shape_manager) |mgr| {
        state.cursor_shape_device = try mgr.getPointer(state.pointer.?);
    }

    for (state.outputs.items) |*entry| {
        initRenderBuffers(&state, entry);

        entry.surface.?.setBufferScale(entry.scale);
        entry.render_buffers[0].busy = true;
        entry.surface.?.attach(entry.render_buffers[0].buffer, 0, 0);
        entry.surface.?.damageBuffer(
            0,
            0,
            @intCast(entry.screenshot.width),
            @intCast(entry.screenshot.height),
        );
        entry.surface.?.commit();
    }

    while (state.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
}
