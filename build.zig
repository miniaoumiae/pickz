const std = @import("std");
const wayland = @import("wayland");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const clap = b.dependency("clap", .{});

    // 1. Generate the Wayland protocol bindings (client side)
    const scanner = wayland.Scanner.create(b, .{});

    // wlr-protocols are not part of wayland-protocols; add them explicitly.
    const wlr_protocols = b.option([]const u8, "wlr-protocols", "Path to wlr-protocols pkgdatadir") orelse blk: {
        const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wlr-protocols" });
        break :blk std.mem.trim(u8, pc_output, &std.ascii.whitespace);
    };
    const wayland_protocols = b.option([]const u8, "wayland-protocols", "Path to wayland-protocols pkgdatadir") orelse blk: {
        const pc_output = b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" });
        break :blk std.mem.trim(u8, pc_output, &std.ascii.whitespace);
    };
    // Needed by wlr-layer-shell (references xdg-shell types).
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(.{
        .cwd_relative = b.pathJoin(&.{ wlr_protocols, "unstable/wlr-layer-shell-unstable-v1.xml" }),
    });
    scanner.addCustomProtocol(.{
        .cwd_relative = b.pathJoin(&.{ wlr_protocols, "unstable/wlr-screencopy-unstable-v1.xml" }),
    });
    scanner.addCustomProtocol(.{
        .cwd_relative = b.pathJoin(&.{ wayland_protocols, "staging/cursor-shape/cursor-shape-v1.xml" }),
    });
    scanner.addCustomProtocol(.{
        .cwd_relative = b.pathJoin(&.{ wayland_protocols, "unstable/tablet/tablet-unstable-v2.xml" }),
    });

    // zig-wayland always includes wl_display, wl_registry, wl_callback, and wl_buffer.
    // Add the core interfaces we know we'll need.
    scanner.generate("wl_compositor", 5);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 5);
    scanner.generate("wl_output", 4);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("wp_cursor_shape_manager_v1", 1);

    const wayland_module = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Add the module to our executable
    root_mod.addImport("wayland", wayland_module);
    root_mod.addImport("clap", clap.module("clap"));

    const exe = b.addExecutable(.{
        .name = "pickz",
        .root_module = root_mod,
    });

    // 3. Link system libraries (libc and libwayland-client are required)
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
