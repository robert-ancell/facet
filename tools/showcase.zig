//! A tour of every widget in facet, grouped into pages by what they are
//! for (`zig build run-showcase`): buttons, selection, text, feedback,
//! containers, layout, images, icons, maps, 3D, and special widgets such
//! as QR codes.

const std = @import("std");
const facet = @import("facet");
const buttons = @import("showcase/buttons.zig");
const selection = @import("showcase/selection.zig");
const text = @import("showcase/text.zig");
const feedback = @import("showcase/feedback.zig");
const containers = @import("showcase/containers.zig");
const layout = @import("showcase/layout.zig");
const images = @import("showcase/images.zig");
const icons = @import("showcase/icons.zig");
const maps = @import("showcase/maps.zig");
const three_d = @import("showcase/three_d.zig");
const special = @import("showcase/special.zig");

pub const Page = enum {
    buttons,
    selection,
    text,
    feedback,
    containers,
    layout,
    images,
    icons,
    maps,
    three_d,
    special,

    fn title(p: Page) []const u8 {
        return switch (p) {
            .buttons => "Buttons",
            .selection => "Selection",
            .text => "Text",
            .feedback => "Feedback",
            .containers => "Containers",
            .layout => "Layout",
            .images => "Images",
            .icons => "Icons",
            .maps => "Maps",
            .three_d => "3D",
            .special => "Special",
        };
    }

    fn icon(p: Page) facet.IconName {
        return switch (p) {
            .buttons => .smart_button,
            .selection => .toggle_on,
            .text => .text_fields,
            .feedback => .notifications,
            .containers => .view_agenda,
            .layout => .dashboard,
            .images => .image,
            .icons => .interests,
            .maps => .public,
            .three_d => .@"3d_rotation",
            .special => .auto_awesome,
        };
    }

    fn description(p: Page) []const u8 {
        return switch (p) {
            .buttons => "Actions, from the most emphasis to the least",
            .selection => "Choosing options and values",
            .text => "Showing and editing text",
            .feedback => "Progress, counts, questions and messages",
            .containers => "Grouping, listing and scrolling content",
            .layout => "Arranging, sizing, decorating, pressing and dragging",
            .images => "Pixels in memory, and PNG, JPEG, GIF and WebP files loaded in the background",
            .icons => "Material's icons, at any size and colour",
            .maps => "A slippy map of tiles from a source, zoomed out a globe",
            .three_d => if (@import("builtin").os.tag == .macos) "A scene drawn on the GPU with Metal" else "Scenes drawn on the GPU with Vulkan and OpenGL",
            .special => "QR codes, custom painting, accessibility and animation",
        };
    }
};

pub const Showcase = struct {
    notes: *facet.TextDocument,
    code: *facet.TextDocument,

    pub const State = struct {
        page: Page = .buttons,
        extended_rail: bool = true,
        light_theme: bool = false,
        /// Whether the system's theme was light when last seen, to follow
        /// it when it changes.
        system_light: ?bool = null,

        buttons: buttons.State = .{},
        selection: selection.State = .{},
        text: text.State = .{},
        feedback: feedback.State = .{},
        containers: containers.State = .{},
        layout: layout.State = .{},
        images: images.State = .{},
        icons: icons.State = .{},
        maps: maps.State = .{},
        three_d: three_d.State = .{},
        special: special.State = .{},

        pub fn deinit(s: *State) void {
            s.maps.deinit();
        }

        fn selectPage(s: *State, i: usize) void {
            if (i < std.enums.values(Page).len) s.page = std.enums.values(Page)[i];
        }
        fn setExtendedRail(s: *State, v: bool) void {
            s.extended_rail = v;
        }
        fn toggleTheme(s: *State) void {
            s.light_theme = !s.light_theme;
        }
    };

    pub fn build(self: *const Showcase, cx: *facet.Context, s: *State) facet.Widget {
        // Start with the system's theme, and follow it when it changes.
        const ui_light = cx.ui.theme.brightness == .light;
        if (s.system_light == null or ui_light != s.system_light.? and ui_light != s.light_theme) {
            s.system_light = ui_light;
            s.light_theme = ui_light;
        }
        cx.ui.theme = if (s.light_theme) .light else .dark;
        const t = cx.theme();

        const pages = comptime std.enums.values(Page);
        var rail_items: [pages.len]facet.NavigationRail.Item = undefined;
        for (&rail_items, pages) |*item, p| item.* = .{ .label = p.title(), .icon = p.icon() };

        const content = switch (s.page) {
            .buttons => buttons.build(cx, &s.buttons),
            .selection => selection.build(cx, &s.selection),
            .text => text.build(cx, &s.text, self.notes, self.code),
            .feedback => feedback.build(cx, &s.feedback),
            .containers => containers.build(cx, &s.containers),
            .layout => layout.build(cx, &s.layout),
            .images => images.build(cx, &s.images),
            .icons => icons.build(cx, &s.icons),
            .maps => maps.build(cx, &s.maps),
            .three_d => three_d.build(cx, &s.three_d),
            .special => special.build(cx, &s.special),
        };

        const header = cx.make(facet.Padding{
            .padding = .symmetric(24, 12),
            .child = cx.make(facet.Row{
                .spacing = 16,
                .cross_axis_alignment = .center,
                .children = cx.makeAll(.{
                    facet.Expanded{ .child = cx.make(facet.Column{
                        .main_axis_size = .min,
                        .cross_axis_alignment = .start,
                        .spacing = 2,
                        .children = cx.makeAll(.{
                            facet.Text{ .text = s.page.title(), .style = .{ .size = t.title_size, .color = t.on_surface }, .wrap = false, .ellipsis = true },
                            facet.Text{ .text = s.page.description(), .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true },
                        }),
                    }) },
                    facet.SwitchRow{ .value = s.extended_rail, .on_changed = .of(s, State.setExtendedRail), .label = "Labels" },
                    facet.Tooltip{
                        .text = if (s.light_theme) "Use the dark theme" else "Use the light theme",
                        .child = cx.make(facet.IconButton{ .icon = if (s.light_theme) .dark_mode else .light_mode, .on_press = .of(s, State.toggleTheme) }),
                    },
                }),
            }),
        });

        const body = cx.make(facet.Row{
            .cross_axis_alignment = .stretch,
            .children = cx.makeAll(.{
                facet.NavigationRail{
                    .items = &rail_items,
                    .selected = @backingInt(s.page),
                    .on_select = .of(s, State.selectPage),
                    .extended = s.extended_rail,
                },
                facet.Divider{ .axis = .vertical },
                facet.Expanded{
                    .child = cx.make(facet.Column{
                        .cross_axis_alignment = .stretch,
                        .children = cx.makeAll(.{
                            header,
                            facet.Divider{},
                            facet.Expanded{
                                // A view for each page, so each starts at the top.
                                .child = cx.make(facet.ScrollView{
                                    .child = cx.make(facet.Padding{ .padding = .all(24), .child = content }),
                                }).withKey(@backingInt(s.page)),
                            },
                        }),
                    }),
                },
            }),
        });

        return cx.make(facet.Decorated{
            .color = t.surface,
            .child = feedback.wrap(cx, &s.feedback, body),
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.init(init.gpa, init.io, init.minimal.environ, .{
        .app_id = "facet-showcase",
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    var notes = try facet.TextDocument.init(init.gpa, text.initial_notes);
    defer notes.deinit();
    var code = try facet.TextDocument.init(init.gpa, text.initial_code);
    defer code.deinit();

    const root = Showcase{ .notes = &notes, .code = &code };
    _ = try app.openWindow(.{
        .title = "Facet Showcase",
        .root = .of(&root),
        .size = .{ 1120, 760 },
        .min_size = .{ 800, 480 },
        .on_close_request = .close,
    });
    try app.run();
}

test "every page fits the smallest window and lays out without overflowing, at it and a large size, in both themes" {
    const fira = try facet.font.Font.init(facet.font.default_font_data);
    const u = try facet.WindowUi.create(std.testing.allocator, std.testing.io, &fira);
    defer u.destroy();
    var notes = try facet.TextDocument.init(std.testing.allocator, text.initial_notes);
    defer notes.deinit();
    var code = try facet.TextDocument.init(std.testing.allocator, text.initial_code);
    defer code.deinit();
    const root: Showcase = .{ .notes = &notes, .code = &code };

    for ([_]facet.Theme{ .dark, .light }) |theme| {
        for ([_][2]u32{ .{ 800, 480 }, .{ 1400, 1000 } }) |size| {
            for ([_]bool{ true, false }) |labels| for (std.enums.values(Page), 0..) |p, i| {
                u.theme = theme;
                u.frame(size[0], size[1], i, root);
                const state = u.root.?.state(Showcase.State);
                state.page = p;
                state.extended_rail = labels;
                u.frame(size[0], size[1], i, root);
                try expectSane(u.root.?);
                // The window can be made as small as the smallest asked for.
                std.testing.expect(u.min_size[0] <= 800 and u.min_size[1] <= 480) catch |err| {
                    std.debug.print("{t} needs a window of at least {d} by {d}\n", .{ p, u.min_size[0], u.min_size[1] });
                    return err;
                };
            };
        }
    }
}

/// Everything got a finite size, and fits in the space it was given.
fn expectSane(n: *facet.WidgetNode) !void {
    try std.testing.expect(std.math.isFinite(n.size.w) and n.size.w >= 0);
    try std.testing.expect(std.math.isFinite(n.size.h) and n.size.h >= 0);
    std.testing.expect(n.overflow.right < 0.5 and n.overflow.bottom < 0.5) catch |err| {
        std.debug.print("{s} overflows by {d} right and {d} down\n", .{ n.widget.vtable.name, n.overflow.right, n.overflow.bottom });
        return err;
    };
    for (n.children.items) |ch| try expectSane(ch);
}

test {
    _ = maps;
}

test "what is drawn again on every page matches drawing it all, in buffers given back in any order" {
    const fira = try facet.font.Font.init(facet.font.default_font_data);
    const u = try facet.WindowUi.create(std.testing.allocator, std.testing.io, &fira);
    defer u.destroy();
    u.attachRenderer(u.shared.software_renderer.renderer(), false);
    var notes = try facet.TextDocument.init(std.testing.allocator, text.initial_notes);
    defer notes.deinit();
    var code = try facet.TextDocument.init(std.testing.allocator, text.initial_code);
    defer code.deinit();
    const root: Showcase = .{ .notes = &notes, .code = &code };
    const w = 900;
    const h = 600;
    // Three buffers, each keeping what was drawn in it, given back in any
    // order (as a compositor may).
    const Win = struct {
        width: u32 = w,
        height: u32 = h,
        pixels: [3][]u32,
        drawn: [3]u64 = @splat(0),
        frames: u64 = 0,
        back: usize = 0,
        rng: std.Random.DefaultPrng = .init(7),

        pub fn beginSoftwareFrame(win: *@This()) !facet.gfx.software.Image {
            win.back = win.rng.random().uintLessThan(usize, win.pixels.len);
            return .{ .pixels = win.pixels[win.back], .width = w, .height = h };
        }
        pub fn bufferAge(win: *const @This()) u32 {
            const d = win.drawn[win.back];
            return if (d == 0) 0 else @intCast(win.frames + 1 - d);
        }
        pub fn showDamaged(win: *@This(), _: ?[]const facet.gfx.Viewport) !void {
            win.frames += 1;
            win.drawn[win.back] = win.frames;
        }
    };
    var win: Win = .{ .pixels = undefined };
    for (&win.pixels) |*p| p.* = try std.testing.allocator.alloc(u32, w * h);
    defer for (win.pixels) |p| std.testing.allocator.free(p);
    const want = try std.testing.allocator.alloc(u32, w * h);
    defer std.testing.allocator.free(want);
    u.attachWindow(&win, null);

    // Each page for a while, its animations running, with the pointer
    // moving, clicking and scrolling about.
    var rng = std.Random.DefaultPrng.init(1);
    var t: u64 = 0;
    u.frame(w, h, t, root);
    for (std.enums.values(Page)) |page| for (0..40) |f| {
        if (f == 0) u.root.?.state(Showcase.State).page = page;
        const pos: facet.Point = .{ @floatFromInt(rng.random().uintLessThan(u32, w)), @floatFromInt(rng.random().uintLessThan(u32, h)) };
        switch (rng.random().uintLessThan(u8, 12)) {
            0, 1, 2 => u.pointerMotion(pos),
            // Not on the rail, which would change the page.
            3 => if (pos[0] > 220) {
                u.pointerMotion(pos);
                u.pointerButton(pos, .left, true);
                u.pointerButton(pos, .left, false);
            },
            4 => u.pointerScroll(pos, 0, 40),
            5 => u.pointerScroll(pos, 0, -40),
            else => {},
        }
        t += (1 + rng.random().uintLessThan(u64, 3)) * 8 * std.time.ns_per_ms;
        u.frame(w, h, t, root);
        if (!try u.present(&win, 0xff000000)) continue;
        @memset(want, 0xff000000);
        var img: facet.gfx.software.Image = .{ .pixels = want, .width = w, .height = h };
        try u.render(&img, null);
        std.testing.expectEqualSlices(u32, want, win.pixels[win.back]) catch |err| {
            std.debug.print("on the {s} page, frame {d}\n", .{ @tagName(page), f });
            return err;
        };
    };
}
