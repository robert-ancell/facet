//! Reports the windowing, buffer, synchronization and rendering backends
//! facet picks on this system, live from `cx.backend()` (`zig build run-info`).

const std = @import("std");
const facet = @import("facet");

const Info = struct {
    pub fn build(_: *const Info, cx: *facet.Context) facet.Widget {
        return cx.make(facet.Decorated{
            .color = cx.theme().surface,
            .child = cx.make(facet.ScrollView{
                .child = cx.make(facet.Padding{
                    .padding = .all(24),
                    .child = buildReport(cx),
                }),
            }),
        });
    }
};

fn sectionHeading(cx: *facet.Context, title: []const u8, subtitle: []const u8) facet.Widget {
    const t = cx.theme();
    return cx.make(facet.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .start,
        .spacing = 4,
        .children = cx.makeAll(.{
            facet.Text{ .text = title, .style = .{ .size = 18, .color = t.on_surface }, .wrap = false },
            facet.Text{ .text = subtitle, .style = .{ .size = 13, .color = t.on_surface_variant } },
        }),
    });
}

fn buildReport(cx: *facet.Context) facet.Widget {
    const t = cx.theme();
    const info = cx.backend();

    const platform_desc = switch (info.platform) {
        .wayland => "Native Wayland protocol client (xdg_toplevel)",
        .headless => "Offscreen / headless surface",
        .x11 => "X11 window system client",
        .windows => "Win32 window backend",
        .macos => "Cocoa / AppKit window backend",
        .custom => "Custom window backend implementation",
    };

    const transport_desc = switch (info.buffer_transport) {
        .wl_shm => "Shared-memory buffers via wl_shm_pool",
        .linux_dmabuf => "Zero-copy GPU DMA-BUF via zwp_linux_dmabuf_v1",
        .memory => "In-memory CPU pixel buffer",
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

    const decorations_desc = switch (info.decorations) {
        .client => "Toolkit TitleBar, drop shadows & rounded corners (CSD)",
        .server => "Compositor / window manager frame (zxdg_decoration_v1 SSD)",
        .none => "No window decorations (headless / offscreen)",
    };

    const window_state = if (info.fullscreen)
        "Fullscreen"
    else if (info.maximized)
        "Maximized"
    else if (info.tiled)
        "Tiled"
    else if (info.decorations == .client)
        "Floating (with CSD shadow & rounded corners)"
    else
        "Floating";

    const sync_text = if (info.refresh_hz > 0)
        cx.fmt("Frame pacing: {s} ({d:.1} Hz)  ·  Buffer sync: {s}", .{
            if (info.frame_sync.vsync) "VSync enabled" else "Uncapped",
            info.refresh_hz,
            info.buffer_sync.name(),
        })
    else
        cx.fmt("Frame pacing: {s}  ·  Buffer sync: {s}", .{
            if (info.frame_sync.vsync) "VSync enabled" else "Uncapped",
            info.buffer_sync.name(),
        });

    const vsync_badge = if (info.refresh_hz > 0)
        cx.fmt("{s} · {d:.0} Hz", .{ if (info.frame_sync.vsync) "VSync" else "Off", info.refresh_hz })
    else if (info.frame_sync.vsync)
        "VSync ON"
    else
        "VSync OFF";

    const ext_section: facet.Widget = if (info.extensions.len > 0) blk: {
        const rows_list = cx.arena.alloc(facet.Widget, info.extensions.len) catch unreachable;
        var row_count: usize = 0;
        var i: usize = 0;
        while (i < info.extensions.len) {
            const row_chips = cx.arena.alloc(facet.Widget, 4) catch unreachable;
            var chip_count: usize = 0;
            var row_chars: usize = 0;
            while (i < info.extensions.len and chip_count < 4) {
                const ext = info.extensions[i];
                if (chip_count > 0 and row_chars + ext.len > 56) break;
                row_chips[chip_count] = cx.make(facet.Chip{
                    .label = ext,
                    .selected = true,
                });
                chip_count += 1;
                row_chars += ext.len + 4;
                i += 1;
            }
            rows_list[row_count] = cx.make(facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = row_chips[0..chip_count],
            });
            row_count += 1;
        }
        break :blk cx.make(facet.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .start,
            .spacing = 8,
            .children = rows_list[0..row_count],
        });
    } else cx.make(facet.Text{
        .text = "No Wayland extensions active (non-Wayland or headless backend)",
        .style = .{ .size = 13, .color = t.on_surface_variant },
    });

    return cx.make(facet.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 18,
        .children = cx.makeAll(.{
            sectionHeading(
                cx,
                "Active Runtime Backend",
                "Live windowing platform, surface buffer transport, window decorations, and 2D renderer reported by cx.backend()",
            ),
            facet.Row{
                .spacing = 16,
                .cross_axis_alignment = .start,
                .children = cx.makeAll(.{
                    facet.Expanded{
                        .child = cx.make(facet.Card{
                            .variant = .elevated,
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = cx.makeAll(.{
                                    facet.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = cx.makeAll(.{
                                            facet.Icon{ .icon = .computer, .size = 20, .color = t.primary },
                                            facet.Text{ .text = "Windowing Platform", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false },
                                        }),
                                    },
                                    facet.Text{ .text = info.platform.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false },
                                    facet.Text{ .text = platform_desc, .style = .{ .size = 13, .color = t.on_surface_variant } },
                                }),
                            }),
                        }),
                    },
                    facet.Expanded{
                        .child = cx.make(facet.Card{
                            .variant = .elevated,
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = cx.makeAll(.{
                                    facet.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = cx.makeAll(.{
                                            facet.Icon{ .icon = .layers, .size = 20, .color = t.primary },
                                            facet.Text{ .text = "Buffer Transport", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false },
                                        }),
                                    },
                                    facet.Text{ .text = info.buffer_transport.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false },
                                    facet.Text{ .text = transport_desc, .style = .{ .size = 13, .color = t.on_surface_variant } },
                                }),
                            }),
                        }),
                    },
                    facet.Expanded{
                        .child = cx.make(facet.Card{
                            .variant = .elevated,
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = cx.makeAll(.{
                                    facet.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = cx.makeAll(.{
                                            facet.Icon{ .icon = .memory, .size = 20, .color = t.primary },
                                            facet.Text{ .text = "2D Renderer", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false },
                                        }),
                                    },
                                    facet.Text{ .text = info.renderer.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false },
                                    facet.Text{ .text = renderer_desc, .style = .{ .size = 13, .color = t.on_surface_variant } },
                                }),
                            }),
                        }),
                    },
                }),
            },
            facet.Divider{},
            sectionHeading(cx, "Backend Matrix", "Checkmarks indicate the active platform, buffer protocol, synchronization, decoration mode, and rendering pipeline"),
            facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    facet.Text{ .text = "Platform:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    facet.Chip{ .label = "Wayland", .selected = info.platform == .wayland },
                    facet.Chip{ .label = "X11", .selected = info.platform == .x11 },
                    facet.Chip{ .label = "Windows", .selected = info.platform == .windows },
                    facet.Chip{ .label = "macOS", .selected = info.platform == .macos },
                    facet.Chip{ .label = "Headless", .selected = info.platform == .headless },
                }),
            },
            facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    facet.Text{ .text = "Surface Buffers:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    facet.Chip{ .label = "wl_shm", .selected = info.buffer_transport == .wl_shm },
                    facet.Chip{ .label = "linux_dmabuf", .selected = info.buffer_transport == .linux_dmabuf },
                    facet.Chip{ .label = "Swapchain", .selected = info.buffer_transport == .swapchain },
                    facet.Chip{ .label = "CPU Memory", .selected = info.buffer_transport == .memory },
                }),
            },
            facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    facet.Text{ .text = "Buffer Sync:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    facet.Chip{ .label = "Implicit", .selected = info.buffer_sync == .implicit },
                    facet.Chip{ .label = "wp_linux_drm_syncobj_v1", .selected = info.buffer_sync == .linux_drm_syncobj_v1 },
                    facet.Chip{ .label = "None", .selected = info.buffer_sync == .none },
                }),
            },
            facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    facet.Text{ .text = "Frame Sync:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    facet.Chip{ .label = "wl_surface.frame", .selected = info.frame_sync.frame_callback },
                    facet.Chip{ .label = "wp_presentation", .selected = info.frame_sync.presentation_time },
                    facet.Chip{ .label = "wp_fifo_v1", .selected = info.frame_sync.fifo_v1 },
                    facet.Chip{ .label = "wp_commit_timing_v1", .selected = info.frame_sync.commit_timing_v1 },
                }),
            },
            facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    facet.Text{ .text = "Decorations:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    facet.Chip{ .label = "Client-side (CSD)", .selected = info.decorations == .client },
                    facet.Chip{ .label = "Server-side (SSD)", .selected = info.decorations == .server },
                    facet.Chip{ .label = "None", .selected = info.decorations == .none },
                }),
            },
            facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    facet.Text{ .text = "Renderer:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false },
                    facet.Chip{ .label = "Software", .selected = info.renderer == .software },
                    facet.Chip{ .label = "OpenGL", .selected = info.renderer == .opengl },
                    facet.Chip{ .label = "Vulkan", .selected = info.renderer == .vulkan },
                    facet.Chip{ .label = "Metal", .selected = info.renderer == .metal },
                    facet.Chip{ .label = "Direct3D 11", .selected = info.renderer == .d3d11 },
                }),
            },
            facet.Divider{},
            sectionHeading(
                cx,
                "Wayland Extensions",
                cx.fmt("{d} active Wayland protocol extensions bound by the window backend", .{info.extensions.len}),
            ),
            ext_section,
            facet.Divider{},
            sectionHeading(cx, "Surface & Window Properties", "Live geometry, DPI scale, VSync & synchronization, window decorations, window state, and input configuration"),
            facet.Card{
                .variant = .outlined,
                .padding = .all(4),
                .child = cx.make(facet.Column{
                    .main_axis_size = .min,
                    .cross_axis_alignment = .stretch,
                    .children = cx.makeAll(.{
                        facet.ListItem{
                            .headline = "Windowing & Buffer Protocol",
                            .supporting_text = cx.fmt("{s}  ·  {s}", .{ platform_desc, transport_desc }),
                            .leading_icon = .computer,
                            .trailing = cx.make(facet.Badge{
                                .label = cx.fmt("{s} ({s})", .{ info.platform.name(), info.buffer_transport.name() }),
                                .color = t.primary,
                            }),
                        },
                        facet.Divider{ .inset = 16 },
                        facet.ListItem{
                            .headline = "VSync & Frame Synchronization",
                            .supporting_text = sync_text,
                            .leading_icon = .speed,
                            .trailing = cx.make(facet.Badge{ .label = vsync_badge, .color = t.primary }),
                        },
                        facet.Divider{ .inset = 16 },
                        facet.ListItem{
                            .headline = "Window Decorations",
                            .supporting_text = decorations_desc,
                            .leading_icon = .widgets,
                            .trailing = cx.make(facet.Badge{ .label = info.decorations.name(), .color = t.primary }),
                        },
                        facet.Divider{ .inset = 16 },
                        facet.ListItem{
                            .headline = "2D Rendering Pipeline",
                            .supporting_text = renderer_desc,
                            .leading_icon = .memory,
                            .trailing = cx.make(facet.Badge{ .label = info.renderer.name(), .color = t.primary }),
                        },
                        facet.Divider{ .inset = 16 },
                        facet.ListItem{
                            .headline = "Surface Resolution & HiDPI Scale",
                            .supporting_text = cx.fmt(
                                "Logical: {d} × {d} px  ·  Physical buffer: {d} × {d} px",
                                .{ info.logical_size[0], info.logical_size[1], info.physical_size[0], info.physical_size[1] },
                            ),
                            .leading_icon = .fullscreen,
                            .trailing_text = cx.fmt("{d}x scale", .{info.scale}),
                        },
                        facet.Divider{ .inset = 16 },
                        facet.ListItem{
                            .headline = "Window State & Keyboard Layout",
                            .supporting_text = cx.fmt("State: {s}  ·  Keyboard: {s}", .{ window_state, info.keyboard.name() }),
                            .leading_icon = .keyboard,
                            .trailing_text = info.keyboard.code(),
                        },
                    }),
                }),
            },
        }),
    });
}

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.init(init.gpa, init.io, init.minimal.environ, .{
        .app_id = "facet-info",
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    const root = Info{};
    _ = try app.openWindow(.{
        .title = "Facet Info",
        .root = .of(&root),
        .size = .{ 1000, 720 },
        .min_size = .{ 640, 400 },
        .on_close_request = .close,
    });
    try app.run();
}
