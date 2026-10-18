//! Interactive form controls and theme switcher (`zig build run-controls`).

const std = @import("std");
const facet = @import("facet");

pub const Quality = enum {
    low,
    balanced,
    high,
};

pub const ViewMode = enum {
    list,
    grid,
};

pub const ControlsDemo = struct {
    pub const State = struct {
        ui: ?*facet.Ui = null,
        light_mode: bool = false,
        name_buf: [64]u8 = undefined,
        name_len: usize = 0,
        notifications: bool = true,
        remember_me: bool = false,
        volume: f32 = 0.7,
        steps: f32 = 50,
        quality: Quality = .balanced,
        view_mode: ViewMode = .list,
        filter_active: bool = true,

        pub fn toggleTheme(s: *State, light: bool) void {
            s.light_mode = light;
            if (s.ui) |u| {
                u.theme = if (light) .light else .dark;
            }
        }

        pub fn setName(s: *State, text: []const u8) void {
            const n = @min(text.len, s.name_buf.len);
            @memcpy(s.name_buf[0..n], text[0..n]);
            s.name_len = n;
        }

        pub fn setNotifications(s: *State, v: bool) void {
            s.notifications = v;
        }

        pub fn setRememberMe(s: *State, v: bool) void {
            s.remember_me = v;
        }

        pub fn setVolume(s: *State, v: f32) void {
            s.volume = v;
        }

        pub fn setSteps(s: *State, v: f32) void {
            s.steps = v;
        }

        pub fn setQuality(s: *State, q: Quality) void {
            s.quality = q;
        }

        pub fn setListView(s: *State) void {
            s.view_mode = .list;
        }

        pub fn setGridView(s: *State) void {
            s.view_mode = .grid;
        }

        pub fn toggleFilter(s: *State) void {
            s.filter_active = !s.filter_active;
        }
    };

    pub fn build(_: *const ControlsDemo, cx: *facet.Context, state: *State) facet.Widget {
        state.ui = cx.ui;
        const t = cx.theme();
        const name = if (state.name_len > 0) state.name_buf[0..state.name_len] else "World";
        const quality_options = [_]facet.Select(Quality).Option{
            .{ .value = .low, .label = "Power Saver" },
            .{ .value = .balanced, .label = "Balanced" },
            .{ .value = .high, .label = "High Performance" },
        };

        return cx.make(facet.ScrollView{
            .child = cx.make(facet.Padding{
                .padding = .all(24),
                .child = cx.make(facet.Column{
                    .cross_axis_alignment = .start,
                    .spacing = 16,
                    .children = &.{
                        cx.make(facet.Row{
                            .spacing = 16,
                            .cross_axis_alignment = .center,
                            .children = &.{
                                cx.make(facet.Text{
                                    .text = cx.fmt("Hello, {s}!", .{name}),
                                    .style = .{ .size = t.title_size, .color = t.on_surface },
                                }),
                                cx.make(facet.Switch{
                                    .value = state.light_mode,
                                    .on_changed = .of(state, State.toggleTheme),
                                    .label = "Light theme",
                                }),
                            },
                        }),
                        cx.make(facet.Divider{}),
                        cx.make(facet.Row{
                            .spacing = 16,
                            .children = &.{
                                cx.make(facet.TextField{
                                    .placeholder = "Your name",
                                    .initial = "World",
                                    .on_changed = .of(state, State.setName),
                                }),
                                cx.make(facet.TextField{
                                    .placeholder = "Password",
                                    .initial = "hunter2",
                                    .obscure = true,
                                }),
                            },
                        }),
                        cx.make(facet.Row{
                            .spacing = 24,
                            .children = &.{
                                cx.make(facet.Switch{
                                    .value = state.notifications,
                                    .on_changed = .of(state, State.setNotifications),
                                    .label = "Enable notifications",
                                }),
                                cx.make(facet.Checkbox{
                                    .value = state.remember_me,
                                    .on_changed = .of(state, State.setRememberMe),
                                    .label = "Remember session",
                                }),
                            },
                        }),
                        cx.make(facet.Row{
                            .spacing = 16,
                            .children = &.{
                                cx.make(facet.Radio(Quality){
                                    .value = .low,
                                    .group_value = state.quality,
                                    .on_changed = .of(state, State.setQuality),
                                    .label = "Low",
                                }),
                                cx.make(facet.Radio(Quality){
                                    .value = .balanced,
                                    .group_value = state.quality,
                                    .on_changed = .of(state, State.setQuality),
                                    .label = "Balanced",
                                }),
                                cx.make(facet.Radio(Quality){
                                    .value = .high,
                                    .group_value = state.quality,
                                    .on_changed = .of(state, State.setQuality),
                                    .label = "High",
                                }),
                                cx.make(facet.Select(Quality){
                                    .options = &quality_options,
                                    .value = state.quality,
                                    .on_changed = .of(state, State.setQuality),
                                }),
                            },
                        }),
                        cx.make(facet.SizedBox{
                            .width = 360,
                            .child = cx.make(facet.Column{
                                .cross_axis_alignment = .stretch,
                                .spacing = 8,
                                .children = &.{
                                    cx.make(facet.Text{
                                        .text = cx.fmt("Volume: {d:.0}%", .{state.volume * 100}),
                                    }),
                                    cx.make(facet.Slider{
                                        .value = state.volume,
                                        .on_changed = .of(state, State.setVolume),
                                    }),
                                    cx.make(facet.ProgressBar{ .value = state.volume }),
                                    cx.make(facet.Text{
                                        .text = cx.fmt("Discrete step: {d:.0}", .{state.steps}),
                                    }),
                                    cx.make(facet.Slider{
                                        .value = state.steps,
                                        .min = 0,
                                        .max = 100,
                                        .divisions = 4,
                                        .on_changed = .of(state, State.setSteps),
                                    }),
                                },
                            }),
                        }),
                        cx.make(facet.Row{
                            .spacing = 16,
                            .cross_axis_alignment = .center,
                            .children = &.{
                                cx.make(facet.PillBar{
                                    .children = &.{
                                        cx.make(facet.PillButton{
                                            .label = "List",
                                            .icon = .view_list,
                                            .selected = state.view_mode == .list,
                                            .first = true,
                                            .on_press = .of(state, State.setListView),
                                        }),
                                        cx.make(facet.PillButton{
                                            .label = "Grid",
                                            .icon = .grid_view,
                                            .selected = state.view_mode == .grid,
                                            .last = true,
                                            .on_press = .of(state, State.setGridView),
                                        }),
                                    },
                                }),
                                cx.make(facet.Chip{
                                    .label = "Filter active",
                                    .icon = .widgets,
                                    .selected = state.filter_active,
                                    .on_press = .of(state, State.toggleFilter),
                                }),
                            },
                        }),
                    },
                }),
            }),
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.open(init.gpa, init.minimal.environ, .{
        .title = "Facet Controls",
        .size = .{ 760, 560 },
    });
    defer app.close();

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try app.draw(facet.window.nowNs(), ControlsDemo{});
    }
}
