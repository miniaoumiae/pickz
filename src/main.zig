const std = @import("std");
const wayland = @import("wayland");
const clap = @import("clap");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const wp = wayland.client.wp;

const Screenshot = struct {
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: wl.Shm.Format = .argb8888,
    pixels: []u8 = &[_]u8{},
    buffer: ?*wl.Buffer = null,
    ready: bool = false,
};

const State = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    output: ?*wl.Output = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    screencopy_manager: ?*zwlr.ScreencopyManagerV1 = null,
    screenshot: Screenshot = .{},
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    configured: bool = false,
    output_scale: i32 = 1,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    cursor_x: i32 = -1,
    cursor_y: i32 = -1,
    running: bool = true,
    autocopy: bool = false,
    allocator: std.mem.Allocator,
    draw_buffer: ?*wl.Buffer = null,
    draw_pixels: []u8 = &[_]u8{},
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    cursor_shape_device: ?*wp.CursorShapeDeviceV1 = null,
    frame_callback: ?*wl.Callback = null,
    needs_redraw: bool = false,
};

fn keyboardListener(
    keyboard: *wl.Keyboard,
    event: wl.Keyboard.Event,
    state: *State,
) void {
    _ = keyboard;
    switch (event) {
        .key => |k| {
            // Linux evdev keycode for ESC is 1
            if (k.key == 1 and k.state == .pressed) {
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
            if (std.mem.orderZ(u8, g.interface, wl.Compositor.interface.name) == .eq) {
                state.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 5)) catch return;
            } else if (std.mem.orderZ(u8, g.interface, wl.Shm.interface.name) == .eq) {
                state.shm = registry.bind(g.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, g.interface, wl.Seat.interface.name) == .eq) {
                state.seat = registry.bind(g.name, wl.Seat, 5) catch return;
            } else if (std.mem.orderZ(u8, g.interface, wl.Output.interface.name) == .eq) {
                // NOTE: For multi-monitor, we just grab the first for now.
                // TODO: Build a list for multi-monitor.
                if (state.output == null) {
                    state.output = registry.bind(g.name, wl.Output, 4) catch return;
                    state.output.?.setListener(*State, outputListener, state);
                }
            } else if (std.mem.orderZ(u8, g.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                state.layer_shell = registry.bind(g.name, zwlr.LayerShellV1, @min(g.version, 4)) catch return;
            } else if (std.mem.orderZ(u8, g.interface, zwlr.ScreencopyManagerV1.interface.name) == .eq) {
                state.screencopy_manager =
                    registry.bind(g.name, zwlr.ScreencopyManagerV1, @min(g.version, 3)) catch return;
            } else if (std.mem.orderZ(u8, g.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                state.cursor_shape_manager =
                    registry.bind(g.name, wp.CursorShapeManagerV1, 1) catch return;
            }
        },
        .global_remove => |_| {
            // We don't care about hotplugging
        },
    }
}

fn screencopyFrameListener(
    frame: *zwlr.ScreencopyFrameV1,
    event: zwlr.ScreencopyFrameV1.Event,
    state: *State,
) void {
    switch (event) {
        .buffer => |b| {
            state.screenshot.width = b.width;
            state.screenshot.height = b.height;
            state.screenshot.stride = b.stride;
            state.screenshot.format = b.format;

            const size = b.stride * b.height;

            const fd = std.posix.memfd_create("pickz-capture", 0) catch unreachable;
            std.posix.ftruncate(fd, size) catch unreachable;

            const pixels = std.posix.mmap(
                null,
                size,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                std.posix.MAP{ .TYPE = .SHARED },
                fd,
                0,
            ) catch unreachable;
            state.screenshot.pixels = pixels;

            const pool = state.shm.?.createPool(fd, @intCast(size)) catch unreachable;
            defer pool.destroy();

            state.screenshot.buffer = pool.createBuffer(
                0,
                @intCast(b.width),
                @intCast(b.height),
                @intCast(b.stride),
                b.format,
            ) catch unreachable;

            frame.copy(state.screenshot.buffer.?);
        },
        .ready => {
            state.screenshot.ready = true;
        },
        .failed => {
            std.process.exit(1);
        },
        else => {},
    }
}

fn outputListener(
    output: *wl.Output,
    event: wl.Output.Event,
    state: *State,
) void {
    _ = output;
    switch (event) {
        .scale => |s| {
            state.output_scale = s.factor;
        },
        else => {},
    }
}

fn layerSurfaceListener(
    layer_surface: *zwlr.LayerSurfaceV1,
    event: zwlr.LayerSurfaceV1.Event,
    state: *State,
) void {
    switch (event) {
        .configure => |cfg| {
            layer_surface.ackConfigure(cfg.serial);
            if (!state.configured) {
                state.configured = true;
            }
        },
        .closed => {
            std.process.exit(0);
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
    if (state.frame_callback != null) {
        state.needs_redraw = true;
        return;
    }
    if (state.surface == null or state.draw_buffer == null) return;
    if (state.cursor_x < 0 or state.cursor_y < 0) return;

    state.needs_redraw = false;

    const scale = state.output_scale;
    const cx = state.cursor_x * scale;
    const cy = state.cursor_y * scale;

    @memcpy(state.draw_pixels, state.screenshot.pixels);

    const inner_radius: i32 = 100;
    const border_thickness: i32 = 5;
    const zoom: i32 = 10;

    const outer_radius = inner_radius + border_thickness;
    const outer_radius_sq = outer_radius * outer_radius;
    const inner_radius_sq = inner_radius * inner_radius;

    var border_b: u8 = 0;
    var border_g: u8 = 0;
    var border_r: u8 = 0;
    if (cx >= 0 and cx < state.screenshot.width and cy >= 0 and cy < state.screenshot.height) {
        const center_idx = @as(usize, @intCast(cy)) * state.screenshot.stride + @as(usize, @intCast(cx)) * 4;
        border_b = state.screenshot.pixels[center_idx];
        border_g = state.screenshot.pixels[center_idx + 1];
        border_r = state.screenshot.pixels[center_idx + 2];
    }

    var dy: i32 = -outer_radius;
    while (dy <= outer_radius) : (dy += 1) {
        var dx: i32 = -outer_radius;
        while (dx <= outer_radius) : (dx += 1) {
            const dist_sq = (dx * dx) + (dy * dy);
            if (dist_sq > outer_radius_sq) continue;

            const target_x = cx + dx;
            const target_y = cy + dy;

            if (target_x >= 0 and target_x < state.screenshot.width and target_y >= 0 and target_y < state.screenshot.height) {
                const dst_idx = @as(usize, @intCast(target_y)) * state.screenshot.stride + @as(usize, @intCast(target_x)) * 4;

                if (dist_sq > inner_radius_sq) {
                    state.draw_pixels[dst_idx] = border_b;
                    state.draw_pixels[dst_idx + 1] = border_g;
                    state.draw_pixels[dst_idx + 2] = border_r;
                    state.draw_pixels[dst_idx + 3] = 255;
                } else {
                    const src_x = cx + @divTrunc(dx, zoom);
                    const src_y = cy + @divTrunc(dy, zoom);

                    if (src_x >= 0 and src_x < state.screenshot.width and src_y >= 0 and src_y < state.screenshot.height) {
                        const src_idx = @as(usize, @intCast(src_y)) * state.screenshot.stride + @as(usize, @intCast(src_x)) * 4;
                        state.draw_pixels[dst_idx] = state.screenshot.pixels[src_idx];
                        state.draw_pixels[dst_idx + 1] = state.screenshot.pixels[src_idx + 1];
                        state.draw_pixels[dst_idx + 2] = state.screenshot.pixels[src_idx + 2];
                        state.draw_pixels[dst_idx + 3] = 255;
                    }
                }
            }
        }
    }

    state.surface.?.attach(state.draw_buffer, 0, 0);
    state.surface.?.damageBuffer(0, 0, @intCast(state.screenshot.width), @intCast(state.screenshot.height));
    state.frame_callback = state.surface.?.frame() catch return;
    state.frame_callback.?.setListener(*State, frameListener, state);
    state.surface.?.commit();
}

fn pointerListener(
    pointer: *wl.Pointer,
    event: wl.Pointer.Event,
    state: *State,
) void {
    _ = pointer;
    switch (event) {
        .enter => |e| {
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
            if (b.button == 272 and b.state == .pressed) {
                const cx = state.cursor_x * state.output_scale;
                const cy = state.cursor_y * state.output_scale;

                if (cx >= 0 and cx < state.screenshot.width and cy >= 0 and cy < state.screenshot.height) {
                    const idx = @as(usize, @intCast(cy)) * state.screenshot.stride + @as(usize, @intCast(cx)) * 4;

                    const blue = state.screenshot.pixels[idx];
                    const green = state.screenshot.pixels[idx + 1];
                    const red = state.screenshot.pixels[idx + 2];

                    var buf_no_nl: [16]u8 = undefined;
                    var buf_nl: [16]u8 = undefined;
                    const hex_no_nl = std.fmt.bufPrint(&buf_no_nl, "#{X:0>2}{X:0>2}{X:0>2}", .{ red, green, blue }) catch return;
                    const hex_with_nl = std.fmt.bufPrint(&buf_nl, "#{X:0>2}{X:0>2}{X:0>2}\n", .{ red, green, blue }) catch return;
                    std.fs.File.stdout().writeAll(hex_with_nl) catch {};

                    if (state.autocopy) {
                        var child = std.process.Child.init(
                            &[_][]const u8{ "wl-copy", hex_no_nl },
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-a, --autocopy            Automatically copies the output to the clipboard (requires wl-clipboard)
        \\-h, --help                Show this help message
        \\-v, --version             Print version info
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
        std.debug.print("pickz v0.1.0\n", .{});
        return;
    }

    // Connect to the default Wayland display
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    var state = State{
        .allocator = allocator,
        .autocopy = res.args.autocopy != 0,
    };

    // Get the registry from the display
    const registry = try display.getRegistry();

    // Set our callbacks so we know what globals are available
    registry.setListener(*State, registryListener, &state);

    // Wait for the compositor to send us all the initial globals
    if (display.roundtrip() != .SUCCESS) {
        return error.RoundtripFailed;
    }

    if (display.roundtrip() != .SUCCESS) {
        return error.RoundtripFailed;
    }

    // Verify we got the bare minimum to function and required extensions
    if (state.compositor == null or state.shm == null or state.layer_shell == null or state.screencopy_manager == null) {
        return error.MissingGlobals;
    }

    const frame = try state.screencopy_manager.?.captureOutput(0, state.output.?);
    frame.setListener(*State, screencopyFrameListener, &state);

    while (!state.screenshot.ready) {
        if (display.dispatch() != .SUCCESS) {
            return error.DispatchFailed;
        }
    }

    state.surface = try state.compositor.?.createSurface();
    state.layer_surface = try state.layer_shell.?.getLayerSurface(
        state.surface.?,
        state.output.?,
        .overlay,
        "pickz",
    );

    state.layer_surface.?.setListener(*State, layerSurfaceListener, &state);
    state.layer_surface.?.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
    state.layer_surface.?.setExclusiveZone(-1);
    state.layer_surface.?.setKeyboardInteractivity(.exclusive);

    state.surface.?.commit();

    while (!state.configured) {
        if (display.dispatch() != .SUCCESS) {
            return error.DispatchFailed;
        }
    }

    state.pointer = try state.seat.?.getPointer();
    state.pointer.?.setListener(*State, pointerListener, &state);

    state.keyboard = try state.seat.?.getKeyboard();
    state.keyboard.?.setListener(*State, keyboardListener, &state);

    if (state.cursor_shape_manager) |mgr| {
        state.cursor_shape_device = try mgr.getPointer(state.pointer.?);
    }

    const size = state.screenshot.stride * state.screenshot.height;
    const fd = std.posix.memfd_create("pickz-draw", 0) catch unreachable;
    std.posix.ftruncate(fd, size) catch unreachable;

    state.draw_pixels = std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        std.posix.MAP{ .TYPE = .SHARED },
        fd,
        0,
    ) catch unreachable;

    const pool = state.shm.?.createPool(fd, @intCast(size)) catch unreachable;
    defer pool.destroy();

    state.draw_buffer = try pool.createBuffer(
        0,
        @intCast(state.screenshot.width),
        @intCast(state.screenshot.height),
        @intCast(state.screenshot.stride),
        state.screenshot.format,
    );

    @memcpy(state.draw_pixels, state.screenshot.pixels);

    state.surface.?.setBufferScale(state.output_scale);
    state.surface.?.attach(state.draw_buffer, 0, 0);
    state.surface.?.damageBuffer(0, 0, @intCast(state.screenshot.width), @intCast(state.screenshot.height));
    state.surface.?.commit();

    while (state.running) {
        if (display.dispatch() != .SUCCESS) {
            return error.DispatchFailed;
        }
    }
}
