//! Reports the windowing, buffer, synchronization and rendering backends
//! kete picks on this system, live from `cx.backend()` and `cx.window()`
//! (`zig build run-info`).

const std = @import("std");
const kete = @import("kete");

const Info = struct {
    pub fn build(_: *const Info, cx: *kete.BuildContext) kete.Widget {
        return cx.make(kete.RoundedBox{
            .color = cx.theme().surface,
            .child = cx.make(kete.ScrollView{
                .child = cx.make(kete.Padding{
                    .padding = .all(24),
                    .child = buildReport(cx),
                }),
            }),
        });
    }
};

fn sectionHeading(cx: *kete.BuildContext, title: []const u8, subtitle: []const u8) kete.Widget {
    const t = cx.theme();
    return cx.make(kete.Column{
        .fill = false,
        .cross_axis_alignment = .start,
        .spacing = 4,
        .children = cx.makeAll(.{
            kete.Text{ .text = title, .style = .{ .size = 18, .color = t.on_surface }, .wrap = false },
            kete.Text{ .text = subtitle, .style = .{ .size = 13, .color = t.on_surface_variant } },
        }),
    });
}

fn buildReport(cx: *kete.BuildContext) kete.Widget {
    const t = cx.theme();
    const info = cx.backend();
    const win = cx.window();

    const platform_desc = switch (info.platform) {
        .wayland => "Native Wayland protocol client (xdg_toplevel)",
        .headless => "Offscreen / headless surface",
        .windows => "Win32 window backend",
        .macos => "Cocoa / AppKit window backend",
        .custom => "Custom window backend implementation",
    };

    const transport_desc = switch (win.buffer_transport) {
        .linux_dmabuf => "Zero-copy GPU DMA-BUF via zwp_linux_dmabuf_v1",
        .memory => "CPU pixel buffer in memory the window system takes",
        .swapchain => "GPU presentation swapchain",
        .custom => "Custom surface buffer transport",
    };

    const renderer_desc = switch (info.renderer) {
        .software => "CPU SDF vector & glyph rasterizer",
        .opengl => "OpenGL 3.3+ / 4.6 SPIR-V GPU renderer",
        .vulkan => "Vulkan 1.1+ SPIR-V GPU renderer",
        .metal => "Metal GPU renderer",
        .d3d11 => "Direct3D 11 GPU renderer",
        .custom => "Custom 2D rendering backend",
    };

    const decorations_desc = switch (win.decorations) {
        .client => "Toolkit TitleBar, drop shadows & rounded corners (CSD)",
        .server => "Compositor / window manager frame (zxdg_decoration_v1 SSD)",
        .none => "No window decorations (headless / offscreen)",
    };

    const window_state = if (win.fullscreen)
        "Fullscreen"
    else if (win.maximized)
        "Maximized"
    else if (win.tiled)
        "Tiled"
    else if (win.decorations == .client)
        "Floating (with CSD shadow & rounded corners)"
    else
        "Floating";

    const sync_text = if (win.refresh_hz > 0)
        cx.fmt("Frame pacing: {s} ({d:.1} Hz)  ·  Buffer sync: {s}", .{
            if (win.frame_sync.vsync) "VSync enabled" else "Uncapped",
            win.refresh_hz,
            win.buffer_sync.name(),
        })
    else
        cx.fmt("Frame pacing: {s}  ·  Buffer sync: {s}", .{
            if (win.frame_sync.vsync) "VSync enabled" else "Uncapped",
            win.buffer_sync.name(),
        });

    const vsync_badge = if (win.refresh_hz > 0)
        cx.fmt("{s} · {d:.0} Hz", .{ if (win.frame_sync.vsync) "VSync" else "Off", win.refresh_hz })
    else if (win.frame_sync.vsync)
        "VSync ON"
    else
        "VSync OFF";

    const ext_section: kete.Widget = if (win.wayland_extensions.len > 0) blk: {
        const rows_list = cx.arena.alloc(kete.Widget, win.wayland_extensions.len) catch unreachable;
        var row_count: usize = 0;
        var i: usize = 0;
        while (i < win.wayland_extensions.len) {
            const row_chips = cx.arena.alloc(kete.Widget, 4) catch unreachable;
            var chip_count: usize = 0;
            var row_chars: usize = 0;
            while (i < win.wayland_extensions.len and chip_count < 4) {
                const ext = win.wayland_extensions[i];
                if (chip_count > 0 and row_chars + ext.len > 56) break;
                row_chips[chip_count] = cx.make(kete.Chip{
                    .label = ext,
                    .selected = true,
                });
                chip_count += 1;
                row_chars += ext.len + 4;
                i += 1;
            }
            rows_list[row_count] = cx.make(kete.Row{
                .spacing = 8,
                .fill = false,
                .cross_axis_alignment = .center,
                .children = row_chips[0..chip_count],
            });
            row_count += 1;
        }
        break :blk cx.make(kete.Column{
            .fill = false,
            .cross_axis_alignment = .start,
            .spacing = 8,
            .children = rows_list[0..row_count],
        });
    } else cx.make(kete.Text{
        .text = "No Wayland extensions active (non-Wayland or headless backend)",
        .style = .{ .size = 13, .color = t.on_surface_variant },
    });

    return cx.make(kete.Column{
        .fill = false,
        .cross_axis_alignment = .stretch,
        .spacing = 18,
        .children = cx.makeAll(.{
            sectionHeading(
                cx,
                "Active Runtime Backend",
                "Live windowing platform, surface buffer transport, window decorations, and 2D renderer reported by cx.backend() and cx.window()",
            ),
            kete.Row{
                .spacing = 16,
                .cross_axis_alignment = .start,
                .children = cx.makeAll(.{
                    kete.Expanded{
                        .child = cx.make(kete.Card{
                            .variant = .elevated,
                            .child = cx.make(kete.Column{
                                .fill = false,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = cx.makeAll(.{
                                    kete.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = cx.makeAll(.{
                                            kete.Icon{ .icon = .computer, .size = 20, .color = t.primary },
                                            kete.Text{ .text = "Windowing Platform", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false },
                                        }),
                                    },
                                    kete.Text{ .text = info.platform.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false },
                                    kete.Text{ .text = platform_desc, .style = .{ .size = 13, .color = t.on_surface_variant } },
                                }),
                            }),
                        }),
                    },
                    kete.Expanded{
                        .child = cx.make(kete.Card{
                            .variant = .elevated,
                            .child = cx.make(kete.Column{
                                .fill = false,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = cx.makeAll(.{
                                    kete.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = cx.makeAll(.{
                                            kete.Icon{ .icon = .layers, .size = 20, .color = t.primary },
                                            kete.Text{ .text = "Buffer Transport", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false },
                                        }),
                                    },
                                    kete.Text{ .text = win.buffer_transport.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false },
                                    kete.Text{ .text = transport_desc, .style = .{ .size = 13, .color = t.on_surface_variant } },
                                }),
                            }),
                        }),
                    },
                    kete.Expanded{
                        .child = cx.make(kete.Card{
                            .variant = .elevated,
                            .child = cx.make(kete.Column{
                                .fill = false,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = cx.makeAll(.{
                                    kete.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = cx.makeAll(.{
                                            kete.Icon{ .icon = .memory, .size = 20, .color = t.primary },
                                            kete.Text{ .text = "2D Renderer", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false },
                                        }),
                                    },
                                    kete.Text{ .text = info.renderer.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false },
                                    kete.Text{ .text = renderer_desc, .style = .{ .size = 13, .color = t.on_surface_variant } },
                                }),
                            }),
                        }),
                    },
                }),
            },
            kete.Divider{},
            sectionHeading(cx, "Backend Matrix", "Checkmarks indicate the active platform, buffer protocol, synchronization, decoration mode, and rendering pipeline"),
            kete.Row{
                .spacing = 8,
                .fill = false,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    kete.Text{ .text = "Platform:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    kete.Chip{ .label = "Wayland", .selected = info.platform == .wayland },
                    kete.Chip{ .label = "Windows", .selected = info.platform == .windows },
                    kete.Chip{ .label = "macOS", .selected = info.platform == .macos },
                    kete.Chip{ .label = "Headless", .selected = info.platform == .headless },
                }),
            },
            kete.Row{
                .spacing = 8,
                .fill = false,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    kete.Text{ .text = "Surface Buffers:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    kete.Chip{ .label = "linux_dmabuf", .selected = win.buffer_transport == .linux_dmabuf },
                    kete.Chip{ .label = "Swapchain", .selected = win.buffer_transport == .swapchain },
                    kete.Chip{ .label = "CPU Memory", .selected = win.buffer_transport == .memory },
                }),
            },
            kete.Row{
                .spacing = 8,
                .fill = false,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    kete.Text{ .text = "Buffer Sync:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    kete.Chip{ .label = "Implicit", .selected = win.buffer_sync == .implicit },
                    kete.Chip{ .label = "Explicit", .selected = win.buffer_sync == .explicit },
                    kete.Chip{ .label = "None", .selected = win.buffer_sync == .none },
                }),
            },
            kete.Row{
                .spacing = 8,
                .fill = false,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    kete.Text{ .text = "Frame Sync:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    kete.Chip{ .label = "wl_surface.frame", .selected = win.frame_sync.frame_callback },
                    kete.Chip{ .label = "wp_presentation", .selected = win.frame_sync.presentation_time },
                    kete.Chip{ .label = "wp_fifo_v1", .selected = win.frame_sync.fifo },
                    kete.Chip{ .label = "wp_commit_timing_v1", .selected = win.frame_sync.timed_presentation },
                }),
            },
            kete.Row{
                .spacing = 8,
                .fill = false,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    kete.Text{ .text = "Decorations:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    kete.Chip{ .label = "Client-side (CSD)", .selected = win.decorations == .client },
                    kete.Chip{ .label = "Server-side (SSD)", .selected = win.decorations == .server },
                    kete.Chip{ .label = "None", .selected = win.decorations == .none },
                }),
            },
            kete.Row{
                .spacing = 8,
                .fill = false,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    kete.Text{ .text = "Renderer:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    kete.Chip{ .label = "Software", .selected = info.renderer == .software },
                    kete.Chip{ .label = "OpenGL", .selected = info.renderer == .opengl },
                    kete.Chip{ .label = "Vulkan", .selected = info.renderer == .vulkan },
                    kete.Chip{ .label = "Metal", .selected = info.renderer == .metal },
                    kete.Chip{ .label = "Direct3D 11", .selected = info.renderer == .d3d11 },
                }),
            },
            kete.Divider{},
            sectionHeading(
                cx,
                "Wayland Extensions",
                cx.fmt("{d} active Wayland protocol extensions bound by the window backend", .{win.wayland_extensions.len}),
            ),
            ext_section,
            kete.Divider{},
            sectionHeading(cx, "Surface & Window Properties", "Live geometry, DPI scale, VSync & synchronization, window decorations, window state, and input configuration"),
            kete.Card{
                .variant = .outlined,
                .padding = .all(4),
                .child = cx.make(kete.Column{
                    .fill = false,
                    .cross_axis_alignment = .stretch,
                    .children = cx.makeAll(.{
                        kete.ListItem{
                            .headline = "Windowing & Buffer Protocol",
                            .supporting_text = cx.fmt("{s}  ·  {s}", .{ platform_desc, transport_desc }),
                            .leading_icon = .computer,
                            .trailing = cx.make(kete.Badge{
                                .label = cx.fmt("{s} ({s})", .{ info.platform.name(), win.buffer_transport.name() }),
                                .color = t.primary,
                            }),
                        },
                        kete.Divider{ .inset = 16 },
                        kete.ListItem{
                            .headline = "VSync & Frame Synchronization",
                            .supporting_text = sync_text,
                            .leading_icon = .speed,
                            .trailing = cx.make(kete.Badge{ .label = vsync_badge, .color = t.primary }),
                        },
                        kete.Divider{ .inset = 16 },
                        kete.ListItem{
                            .headline = "Window Decorations",
                            .supporting_text = decorations_desc,
                            .leading_icon = .widgets,
                            .trailing = cx.make(kete.Badge{ .label = win.decorations.name(), .color = t.primary }),
                        },
                        kete.Divider{ .inset = 16 },
                        kete.ListItem{
                            .headline = "2D Rendering Pipeline",
                            .supporting_text = renderer_desc,
                            .leading_icon = .memory,
                            .trailing = cx.make(kete.Badge{ .label = info.renderer.name(), .color = t.primary }),
                        },
                        kete.Divider{ .inset = 16 },
                        kete.ListItem{
                            .headline = "Surface Resolution & HiDPI Scale",
                            .supporting_text = cx.fmt(
                                "Logical: {d} × {d} px  ·  Physical buffer: {d} × {d} px",
                                .{ win.logical_size[0], win.logical_size[1], win.physical_size[0], win.physical_size[1] },
                            ),
                            .leading_icon = .fullscreen,
                            .trailing_text = cx.fmt("{d}x scale", .{win.scale}),
                        },
                        kete.Divider{ .inset = 16 },
                        kete.ListItem{
                            .headline = "Window State & Keyboard Layout",
                            .supporting_text = cx.fmt("State: {s}  ·  Keyboard: {s}", .{ window_state, info.keyboard.name() }),
                            .leading_icon = .keyboard,
                            .trailing_text = cx.fmt("{s}", .{info.keyboard.code()}),
                        },
                    }),
                }),
            },
        }),
    });
}

pub fn main(init: std.process.Init) !void {
    const app = try kete.App.init(init.gpa, init.io, init.minimal.environ, .{
        .app_id = "kete-info",
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    const root = Info{};
    _ = try app.openWindow(.{
        .title = "Kete Info",
        .root = .of(&root),
        .size = .{ 1000, 720 },
        .min_size = .{ 640, 400 },
        .on_close_request = .close,
    });
    try app.run();
}
