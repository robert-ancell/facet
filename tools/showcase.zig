//! A tour of every widget in facet, grouped into pages by what they are
//! for (`zig build run-showcase`): buttons, selection, text, feedback,
//! containers, layout, and special widgets such as QR codes and 3D.

const std = @import("std");
const facet = @import("facet");
const buttons = @import("showcase/buttons.zig");
const selection = @import("showcase/selection.zig");
const text = @import("showcase/text.zig");
const feedback = @import("showcase/feedback.zig");
const containers = @import("showcase/containers.zig");
const layout = @import("showcase/layout.zig");
const special = @import("showcase/special.zig");

pub const Page = enum {
    buttons,
    selection,
    text,
    feedback,
    containers,
    layout,
    special,

    fn title(p: Page) []const u8 {
        return switch (p) {
            .buttons => "Buttons",
            .selection => "Selection",
            .text => "Text",
            .feedback => "Feedback",
            .containers => "Containers",
            .layout => "Layout",
            .special => "Special",
        };
    }

    fn icon(p: Page) facet.icons.Icon {
        return switch (p) {
            .buttons => .smart_button,
            .selection => .toggle_on,
            .text => .text_fields,
            .feedback => .notifications,
            .containers => .view_agenda,
            .layout => .dashboard,
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
            .special => "QR codes, images, icons, custom painting, animation, 3D and the title bar",
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
        special: special.State = .{},

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
        const ui_light = cx.ui.theme.surface.r > 0.5;
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
            .special => special.build(cx, &s.special),
        };

        const header = cx.make(facet.Padding{
            .padding = .symmetric(24, 12),
            .child = cx.make(facet.Row{
                .spacing = 16,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Expanded{ .child = cx.make(facet.Column{
                        .main_axis_size = .min,
                        .cross_axis_alignment = .start,
                        .spacing = 2,
                        .children = &.{
                            cx.make(facet.Text{ .text = s.page.title(), .style = .{ .size = t.title_size, .color = t.on_surface }, .wrap = false, .ellipsis = true }),
                            cx.make(facet.Text{ .text = s.page.description(), .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
                        },
                    }) }),
                    cx.make(facet.Switch{ .value = s.extended_rail, .on_changed = .of(s, State.setExtendedRail), .label = "Labels" }),
                    cx.make(facet.Tooltip{
                        .text = if (s.light_theme) "Use the dark theme" else "Use the light theme",
                        .child = cx.make(facet.IconButton{ .icon = if (s.light_theme) .dark_mode else .light_mode, .on_press = .of(s, State.toggleTheme) }),
                    }),
                },
            }),
        });

        const body = cx.make(facet.Row{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(facet.NavigationRail{
                    .items = &rail_items,
                    .selected = @backingInt(s.page),
                    .on_select = .of(s, State.selectPage),
                    .extended = s.extended_rail,
                }),
                cx.make(facet.Divider{ .axis = .vertical }),
                cx.make(facet.Expanded{
                    .child = cx.make(facet.Column{
                        .cross_axis_alignment = .stretch,
                        .children = &.{
                            header,
                            cx.make(facet.Divider{}),
                            cx.make(facet.Expanded{
                                // A view for each page, so each starts at the top.
                                .child = cx.make(facet.ScrollView{
                                    .child = cx.make(facet.Padding{ .padding = .all(24), .child = content }),
                                }).withKey(@backingInt(s.page)),
                            }),
                        },
                    }),
                }),
            },
        });

        return cx.make(facet.Decorated{
            .color = t.surface,
            .child = feedback.wrap(cx, &s.feedback, body),
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.open(init.gpa, init.minimal.environ, .{
        .title = "Facet Showcase",
        .app_id = "facet-showcase",
        .size = .{ 1120, 760 },
        .min_size = .{ 800, 480 },
    });
    defer app.close();

    var notes = try facet.TextDocument.init(init.gpa, text.initial_notes);
    defer notes.deinit();
    var code = try facet.TextDocument.init(init.gpa, text.initial_code);
    defer code.deinit();

    while (try app.step(60 * std.time.ns_per_s)) {
        app.takeInput();
        try app.draw(facet.window.nowNs(), Showcase{ .notes = &notes, .code = &code });
    }
}

test "every page lays out without overflowing, at the smallest and a large size, in both themes" {
    const fira = try facet.font.Font.init(facet.font.default_font_data);
    const u = try facet.Ui.create(std.testing.allocator, &fira);
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
            };
        }
    }
}

/// Everything got a finite size, and fits in the space it was given.
fn expectSane(n: *facet.Node) !void {
    try std.testing.expect(std.math.isFinite(n.size.w) and n.size.w >= 0);
    try std.testing.expect(std.math.isFinite(n.size.h) and n.size.h >= 0);
    std.testing.expect(n.overflow.right < 0.5 and n.overflow.bottom < 0.5) catch |err| {
        std.debug.print("{s} overflows by {d} right and {d} down\n", .{ n.widget.vtable.name, n.overflow.right, n.overflow.bottom });
        return err;
    };
    for (n.children.items) |ch| try expectSane(ch);
}
