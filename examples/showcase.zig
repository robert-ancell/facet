//! Interactive gallery of Material 3 widgets across five pages (`Actions`,
//! `Inputs`, `Containers`, `Feedback & Media`, and `Backend`) (`zig build run-showcase`).

const std = @import("std");
const facet = @import("facet");

pub const min_size = [2]u32{ 800, 480 };
pub const open_size = [2]u32{ 1120, 740 };

pub const initial_notes =
    \\Material 3 Widget Showcase
    \\Edit multi-line text here with selection, copy and paste.
;

pub const Page = enum(usize) {
    actions = 0,
    inputs = 1,
    containers = 2,
    feedback = 3,
    backend = 4,
};

pub const SpeedPreset = enum {
    slow,
    normal,
    fast,
    turbo,
};

const sample_image_pixels: [64 * 64]u32 = blk: {
    @setEvalBranchQuota(20000);
    var px: [64 * 64]u32 = undefined;
    for (0..64) |y| {
        for (0..64) |x| {
            const r: u32 = @intCast((x * 255) / 63);
            const g: u32 = @intCast((y * 255) / 63);
            const b: u32 = 220;
            px[y * 64 + x] = 0xff000000 | (r << 16) | (g << 8) | b;
        }
    }
    break :blk px;
};

pub const Showcase = struct {
    doc: ?*facet.TextDocument = null,

    pub const State = struct {
        page: Page = .actions,
        sub_tab: usize = 0,
        extended_rail: bool = true,
        light_theme: bool = false,
        system_light: ?bool = null,

        // Buttons & Chips state.
        button_clicks: u32 = 0,
        pill_index: usize = 0,
        fav_selected: bool = true,
        mute_selected: bool = false,
        lock_selected: bool = false,
        chip_wifi: bool = true,
        chip_gpio: bool = false,
        chip_usb: bool = true,
        tag_visible: [3]bool = .{ true, true, true },

        // Inputs & Sliders state.
        continuous_val: f32 = 0.65,
        discrete_val: f32 = 60,
        animate_progress: bool = false,
        dropdown_idx: usize = 1,
        preset: SpeedPreset = .normal,
        check_a: bool = true,
        check_b: bool = false,
        switch_notifications: bool = true,
        radio_choice: u8 = 0,
        text_buf: [64]u8 = undefined,
        text_len: usize = 0,

        // Containers, Lists & Drag state.
        selected_card: usize = 0,
        selected_list_item: usize = 0,
        badge_count: u32 = 3,
        dropped_item: ?usize = null,
        lazy_selected: ?usize = null,

        // Dialogs, Feedback & Media state.
        confirm_dialog_open: bool = false,
        confirmed_count: u32 = 0,
        snackbar_msg: []const u8 = "Welcome to the Facet Material 3 widget showcase",
        snackbar_undo_count: u32 = 0,
        sample_img: facet.gfx.Image = .{ .pixels = &sample_image_pixels, .width = 64, .height = 64, .id = 1 },

        fn selectPage(s: *State, idx: usize) void {
            if (idx <= @backingInt(Page.backend)) s.page = @fromBackingInt(idx);
        }

        fn selectTab(s: *State, idx: usize) void {
            s.sub_tab = idx;
        }

        fn setExtendedRail(s: *State, v: bool) void {
            s.extended_rail = v;
        }

        fn setLightTheme(s: *State, v: bool) void {
            s.light_theme = v;
        }

        fn addClick(s: *State) void {
            s.button_clicks += 1;
        }

        fn setPill0(s: *State) void {
            s.pill_index = 0;
        }
        fn setPill1(s: *State) void {
            s.pill_index = 1;
        }
        fn setPill2(s: *State) void {
            s.pill_index = 2;
        }

        fn toggleFav(s: *State) void {
            s.fav_selected = !s.fav_selected;
        }
        fn toggleMute(s: *State) void {
            s.mute_selected = !s.mute_selected;
        }
        fn toggleLock(s: *State) void {
            s.lock_selected = !s.lock_selected;
        }

        fn toggleChipWifi(s: *State) void {
            s.chip_wifi = !s.chip_wifi;
        }
        fn toggleChipGpio(s: *State) void {
            s.chip_gpio = !s.chip_gpio;
        }
        fn toggleChipUsb(s: *State) void {
            s.chip_usb = !s.chip_usb;
        }
        fn removeTag0(s: *State) void {
            s.tag_visible[0] = false;
        }
        fn removeTag1(s: *State) void {
            s.tag_visible[1] = false;
        }
        fn removeTag2(s: *State) void {
            s.tag_visible[2] = false;
        }
        fn resetTags(s: *State) void {
            s.tag_visible = .{ true, true, true };
        }

        fn setContinuous(s: *State, v: f32) void {
            s.continuous_val = v;
        }
        fn setDiscrete(s: *State, v: f32) void {
            s.discrete_val = v;
        }
        fn setAnimateProgress(s: *State, v: bool) void {
            s.animate_progress = v;
        }
        fn setDropdown(s: *State, idx: usize) void {
            s.dropdown_idx = idx;
        }
        fn setPreset(s: *State, p: SpeedPreset) void {
            s.preset = p;
        }
        fn setCheckA(s: *State, v: bool) void {
            s.check_a = v;
        }
        fn setCheckB(s: *State, v: bool) void {
            s.check_b = v;
        }
        fn setNotifications(s: *State, v: bool) void {
            s.switch_notifications = v;
        }
        fn setRadio(s: *State, v: u8) void {
            s.radio_choice = v;
        }
        fn setText(s: *State, txt: []const u8) void {
            var n = @min(txt.len, s.text_buf.len);
            while (n > 0 and n < txt.len and txt[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(s.text_buf[0..n], txt[0..n]);
            s.text_len = n;
        }

        fn selectCard0(s: *State) void {
            s.selected_card = 0;
        }
        fn selectCard1(s: *State) void {
            s.selected_card = 1;
        }
        fn selectCard2(s: *State) void {
            s.selected_card = 2;
        }
        fn selectList0(s: *State) void {
            s.selected_list_item = 0;
        }
        fn selectList1(s: *State) void {
            s.selected_list_item = 1;
        }
        fn selectList2(s: *State) void {
            s.selected_list_item = 2;
        }
        fn addBadge(s: *State) void {
            s.badge_count +|= 1;
        }
        fn clearBadge(s: *State) void {
            s.badge_count = 0;
        }
        fn onDropItem(s: *State, data: usize) void {
            s.dropped_item = data;
        }

        fn openDialog(s: *State) void {
            s.confirm_dialog_open = true;
        }
        fn closeDialog(s: *State) void {
            s.confirm_dialog_open = false;
        }
        fn confirmDialog(s: *State) void {
            s.confirm_dialog_open = false;
            s.confirmed_count += 1;
            s.snackbar_msg = "Dialog action confirmed";
        }
        fn showSavedSnackbar(s: *State) void {
            s.snackbar_msg = "Configuration saved to disk";
        }
        fn showNetworkSnackbar(s: *State) void {
            s.snackbar_msg = "Connected to Wi-Fi network";
        }
        fn dismissSnackbar(s: *State) void {
            s.snackbar_msg = "";
        }
        fn undoSnackbar(s: *State) void {
            s.snackbar_undo_count += 1;
            s.snackbar_msg = "";
        }
    };

    pub fn build(self: *const Showcase, cx: *facet.Context, state: *State) facet.Widget {
        const ui_light = cx.ui.theme.surface.r > 0.5;
        if (state.system_light == null) {
            state.system_light = ui_light;
            if (ui_light) state.light_theme = true;
        } else if (ui_light != state.light_theme and ui_light != state.system_light.?) {
            state.system_light = ui_light;
            state.light_theme = ui_light;
        }
        cx.ui.theme = if (state.light_theme) .light else .dark;
        const t = cx.theme();

        const rail_items = [_]facet.NavigationRail.Item{
            .{ .label = "Actions", .icon = .apps },
            .{ .label = "Inputs", .icon = .settings_input_component },
            .{ .label = "Containers", .icon = .view_list, .badge = if (state.badge_count > 0) state.badge_count else null },
            .{ .label = "Feedback", .icon = .info },
            .{ .label = "Backend", .icon = .developer_board },
        };

        const header = cx.make(facet.Padding{
            .padding = .symmetric(20, 10),
            .child = cx.make(facet.Row{
                .cross_axis_alignment = .center,
                .spacing = 12,
                .children = &.{
                    cx.make(facet.Expanded{
                        .child = cx.make(facet.Text{
                            .text = "Material 3 Showcase",
                            .style = .{ .size = 20, .color = t.on_surface },
                            .wrap = false,
                            .ellipsis = true,
                        }),
                    }),
                    cx.make(facet.Switch{
                        .value = state.extended_rail,
                        .on_changed = .of(state, State.setExtendedRail),
                        .label = "Wide rail",
                    }),
                    cx.make(facet.Switch{
                        .value = state.light_theme,
                        .on_changed = .of(state, State.setLightTheme),
                        .label = "Light",
                    }),
                },
            }),
        });

        const page_content = switch (state.page) {
            .actions => buildActionsPage(cx, state),
            .inputs => buildInputsPage(cx, state, self.doc),
            .containers => buildContainersPage(cx, state),
            .feedback => buildFeedbackPage(cx, state),
            .backend => buildBackendPage(cx),
        };

        const body = cx.make(facet.Row{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(facet.NavigationRail{
                    .items = &rail_items,
                    .selected = @backingInt(state.page),
                    .on_select = .of(state, State.selectPage),
                    .extended = state.extended_rail,
                }),
                cx.make(facet.Divider{ .axis = .vertical }),
                cx.make(facet.Expanded{
                    .child = cx.make(facet.Column{
                        .cross_axis_alignment = .stretch,
                        .children = &.{
                            header,
                            cx.make(facet.Divider{}),
                            cx.make(facet.Expanded{
                                .child = cx.make(facet.ScrollView{
                                    .child = cx.make(facet.Padding{
                                        .padding = .all(24),
                                        .child = page_content,
                                    }),
                                }),
                            }),
                        },
                    }),
                }),
            },
        });

        const with_snackbar = cx.make(facet.Snackbar{
            .message = state.snackbar_msg,
            .action_label = "Undo",
            .on_action = .of(state, State.undoSnackbar),
            .on_dismiss = .of(state, State.dismissSnackbar),
            .child = body,
        });

        const with_dialog = cx.make(facet.Dialog{
            .open = state.confirm_dialog_open,
            .icon = .info,
            .title = "Apply configuration?",
            .description = "This modal dialog demonstrates Material 3 scrims, surface elevation, headline typography, and primary/secondary button emphasis.",
            .dismiss_label = "Cancel",
            .on_dismiss = .of(state, State.closeDialog),
            .confirm_label = "Confirm",
            .on_confirm = .of(state, State.confirmDialog),
            .child = with_snackbar,
        });

        return cx.make(facet.Decorated{
            .color = t.surface,
            .child = with_dialog,
        });
    }
};

fn sectionHeading(cx: *facet.Context, title: []const u8, subtitle: []const u8) facet.Widget {
    const t = cx.theme();
    return cx.make(facet.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .start,
        .spacing = 4,
        .children = &.{
            cx.make(facet.Text{ .text = title, .style = .{ .size = 18, .color = t.on_surface }, .wrap = false }),
            cx.make(facet.Text{ .text = subtitle, .style = .{ .size = 13, .color = t.on_surface_variant } }),
        },
    });
}

fn buildActionsPage(cx: *facet.Context, state: *Showcase.State) facet.Widget {
    const t = cx.theme();

    var tag_widgets: [4]facet.Widget = undefined;
    var tag_count: usize = 0;
    const tag_labels = [3][]const u8{ "zig", "wayland", "material-3" };
    const tag_removes = [3]facet.Callback{
        .of(state, Showcase.State.removeTag0),
        .of(state, Showcase.State.removeTag1),
        .of(state, Showcase.State.removeTag2),
    };
    for (tag_labels, tag_removes, state.tag_visible) |lbl, rem, vis| {
        if (vis) {
            tag_widgets[tag_count] = cx.make(facet.Chip{
                .label = lbl,
                .on_press = .of(state, Showcase.State.addClick),
                .on_remove = rem,
            });
            tag_count += 1;
        }
    }
    tag_widgets[tag_count] = cx.make(facet.TextButton{
        .label = "Reset tags",
        .icon = .refresh,
        .on_press = .of(state, Showcase.State.resetTags),
    });
    tag_count += 1;

    return cx.make(facet.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 18,
        .children = &.{
            sectionHeading(cx, "Button Emphasis Variants", cx.fmt("Filled, tonal, outlined and text buttons  ·  pressed {d} times", .{state.button_clicks})),
            cx.make(facet.Row{
                .spacing = 10,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.FilledButton{ .label = "Filled", .icon = .add, .on_press = .of(state, Showcase.State.addClick) }),
                    cx.make(facet.TonalButton{ .label = "Tonal", .icon = .edit, .on_press = .of(state, Showcase.State.addClick) }),
                    cx.make(facet.OutlinedButton{ .label = "Outlined", .icon = .download, .on_press = .of(state, Showcase.State.addClick) }),
                    cx.make(facet.TextButton{ .label = "Text", .on_press = .of(state, Showcase.State.addClick) }),
                },
            }),
            cx.make(facet.Row{
                .spacing = 10,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.FilledButton{ .label = "Disabled" }),
                    cx.make(facet.OutlinedButton{ .label = "Disabled Outlined" }),
                },
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "Segmented PillBar", "Single-select segmented button group"),
            cx.make(facet.Row{
                .spacing = 16,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.PillBar{ .children = &.{
                        cx.make(facet.PillButton{ .label = "Day", .selected = state.pill_index == 0, .first = true, .on_press = .of(state, Showcase.State.setPill0) }),
                        cx.make(facet.PillButton{ .label = "Week", .selected = state.pill_index == 1, .on_press = .of(state, Showcase.State.setPill1) }),
                        cx.make(facet.PillButton{ .label = "Month", .selected = state.pill_index == 2, .last = true, .on_press = .of(state, Showcase.State.setPill2) }),
                    } }),
                    cx.make(facet.Text{
                        .text = cx.fmt("Selected segment: {d}", .{state.pill_index}),
                        .style = .{ .size = 14, .color = t.on_surface_variant },
                        .wrap = false,
                    }),
                },
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "Icon Buttons & Tooltips", "Standard, filled, tonal and outlined icon buttons wrapped in hover tooltips"),
            cx.make(facet.Row{
                .spacing = 16,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Tooltip{
                        .text = "Standard icon button",
                        .child = cx.make(facet.IconButton{
                            .icon = .settings,
                            .variant = .standard,
                            .selected = state.fav_selected,
                            .on_press = .of(state, Showcase.State.toggleFav),
                        }),
                    }),
                    cx.make(facet.Tooltip{
                        .text = "Filled icon button",
                        .child = cx.make(facet.IconButton{
                            .icon = .play_arrow,
                            .variant = .filled,
                            .on_press = .of(state, Showcase.State.addClick),
                        }),
                    }),
                    cx.make(facet.Tooltip{
                        .text = "Tonal toggle button",
                        .child = cx.make(facet.IconButton{
                            .icon = .wifi,
                            .variant = .tonal,
                            .selected = state.mute_selected,
                            .on_press = .of(state, Showcase.State.toggleMute),
                        }),
                    }),
                    cx.make(facet.Tooltip{
                        .text = "Outlined toggle button",
                        .child = cx.make(facet.IconButton{
                            .icon = .lock,
                            .variant = .outlined,
                            .selected = state.lock_selected,
                            .on_press = .of(state, Showcase.State.toggleLock),
                        }),
                    }),
                    cx.make(facet.Tooltip{
                        .text = "Disabled icon button",
                        .child = cx.make(facet.IconButton{
                            .icon = .delete,
                            .variant = .outlined,
                        }),
                    }),
                },
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "Chips", "Filter chips with selection checkmarks and removable input chips"),
            cx.make(facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Chip{ .label = "Wi-Fi", .icon = .wifi, .selected = state.chip_wifi, .on_press = .of(state, Showcase.State.toggleChipWifi) }),
                    cx.make(facet.Chip{ .label = "GPIO", .icon = .developer_board, .selected = state.chip_gpio, .on_press = .of(state, Showcase.State.toggleChipGpio) }),
                    cx.make(facet.Chip{ .label = "USB", .icon = .usb, .selected = state.chip_usb, .on_press = .of(state, Showcase.State.toggleChipUsb) }),
                },
            }),
            cx.make(facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = tag_widgets[0..tag_count],
            }),
        },
    });
}

fn buildInputsPage(cx: *facet.Context, state: *Showcase.State, doc: ?*facet.TextDocument) facet.Widget {
    const t = cx.theme();
    const dropdown_options = [_][]const u8{ "1080p Full HD (60 Hz)", "720p HD (60 Hz)", "480p SD (60 Hz)" };
    const preset_options = [_]facet.Select(SpeedPreset).Option{
        .{ .value = .slow, .label = "Slow (1 Hz)" },
        .{ .value = .normal, .label = "Normal (10 Hz)" },
        .{ .value = .fast, .label = "Fast (100 Hz)" },
        .{ .value = .turbo, .label = "Turbo (1 kHz)" },
    };

    var progress_row: [3]facet.Widget = undefined;
    var prog_count: usize = 0;
    progress_row[prog_count] = cx.make(facet.Switch{
        .value = state.animate_progress,
        .on_changed = .of(state, Showcase.State.setAnimateProgress),
        .label = "Animate indeterminate",
    });
    prog_count += 1;
    if (state.animate_progress) {
        progress_row[prog_count] = cx.make(facet.Expanded{ .child = cx.make(facet.ProgressBar{ .value = null }) });
        prog_count += 1;
        progress_row[prog_count] = cx.make(facet.Spinner{ .size = 28 });
        prog_count += 1;
    }

    return cx.make(facet.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 18,
        .children = &.{
            sectionHeading(cx, "Sliders & Progress Indicators", "Continuous and discrete sliders driving a determinate linear ProgressBar"),
            cx.make(facet.Row{
                .spacing = 16,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.SizedBox{ .width = 140, .child = cx.make(facet.Text{ .text = cx.fmt("Continuous: {d:.0}%", .{state.continuous_val * 100}), .style = .{ .size = 14, .color = t.on_surface }, .wrap = false }) }),
                    cx.make(facet.Expanded{ .child = cx.make(facet.Slider{
                        .value = state.continuous_val,
                        .on_changed = .of(state, Showcase.State.setContinuous),
                    }) }),
                },
            }),
            cx.make(facet.Row{
                .spacing = 16,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.SizedBox{ .width = 140, .child = cx.make(facet.Text{ .text = cx.fmt("Discrete (5 steps): {d:.0}", .{state.discrete_val}), .style = .{ .size = 14, .color = t.on_surface }, .wrap = false }) }),
                    cx.make(facet.Expanded{ .child = cx.make(facet.Slider{
                        .value = state.discrete_val,
                        .min = 0,
                        .max = 100,
                        .divisions = 5,
                        .on_changed = .of(state, Showcase.State.setDiscrete),
                    }) }),
                },
            }),
            cx.make(facet.ProgressBar{ .value = state.continuous_val, .height = 8 }),
            cx.make(facet.Row{
                .spacing = 16,
                .cross_axis_alignment = .center,
                .children = progress_row[0..prog_count],
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "Dropdown Menus & Typed Selects", "Popup menus anchored below outlined selector fields"),
            cx.make(facet.Row{
                .spacing = 16,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.DropdownMenu{
                        .options = &dropdown_options,
                        .selected = state.dropdown_idx,
                        .on_selected = .of(state, Showcase.State.setDropdown),
                        .icon = .videocam,
                        .width = 220,
                    }),
                    cx.make(facet.Select(SpeedPreset){
                        .options = &preset_options,
                        .value = state.preset,
                        .on_changed = .of(state, Showcase.State.setPreset),
                        .icon = .speed,
                        .width = 190,
                    }),
                },
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "Selection Controls", "Checkboxes, switches and radio buttons"),
            cx.make(facet.Row{
                .spacing = 20,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Checkbox{ .value = state.check_a, .on_changed = .of(state, Showcase.State.setCheckA), .label = "Enable logging" }),
                    cx.make(facet.Checkbox{ .value = state.check_b, .on_changed = .of(state, Showcase.State.setCheckB), .label = "Auto-scroll" }),
                    cx.make(facet.Switch{ .value = state.switch_notifications, .on_changed = .of(state, Showcase.State.setNotifications), .label = "Alerts" }),
                },
            }),
            cx.make(facet.Row{
                .spacing = 16,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Radio(u8){ .value = 0, .group_value = state.radio_choice, .on_changed = .of(state, Showcase.State.setRadio), .label = "Channel A" }),
                    cx.make(facet.Radio(u8){ .value = 1, .group_value = state.radio_choice, .on_changed = .of(state, Showcase.State.setRadio), .label = "Channel B" }),
                    cx.make(facet.Radio(u8){ .value = 2, .group_value = state.radio_choice, .on_changed = .of(state, Showcase.State.setRadio), .label = "Channel C" }),
                },
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "TextField & TextArea", "Single-line and multi-line editable text controls"),
            cx.make(facet.TextField{
                .placeholder = "Type a hostname or filter...",
                .initial = state.text_buf[0..state.text_len],
                .on_changed = .of(state, Showcase.State.setText),
            }),
            if (doc) |d|
                cx.make(facet.SizedBox{
                    .height = 96,
                    .child = cx.make(facet.Decorated{
                        .color = t.surface_container,
                        .border = .{ .width = 1, .color = t.outline_variant },
                        .radius = .all(8),
                        .child = cx.make(facet.TextArea{ .doc = d }),
                    }),
                })
            else
                cx.make(facet.Empty{}),
        },
    });
}

const LazyCellPress = struct {
    state: *Showcase.State,
    idx: usize,
    fn press(p: *const LazyCellPress) void {
        p.state.lazy_selected = p.idx;
    }
};

fn buildLazyCell(state: *Showcase.State, cx: *facet.Context, idx: usize) facet.Widget {
    const t = cx.theme();
    const sel = state.lazy_selected == idx;
    const p = cx.arena.create(LazyCellPress) catch unreachable;
    p.* = .{ .state = state, .idx = idx };
    const lbl = cx.fmt("Cell #{d}", .{idx + 1});
    return cx.make(facet.Draggable{
        .data = idx + 1,
        .label = lbl,
        .icon = .widgets,
        .on_press = .of(p, LazyCellPress.press),
        .child = cx.make(facet.Card{
            .variant = if (sel) .filled else .outlined,
            .selected = sel,
            .padding = .symmetric(10, 8),
            .child = cx.make(facet.Center{
                .child = cx.make(facet.Text{
                    .text = lbl,
                    .style = .{ .size = 13, .color = if (sel) t.on_surface else t.on_surface_variant },
                    .wrap = false,
                }),
            }),
        }),
    });
}

fn buildContainersPage(cx: *facet.Context, state: *Showcase.State) facet.Widget {
    const t = cx.theme();
    const tabs = [_]facet.Tab{
        .{ .label = "Cards & Badges", .icon = .grid_view },
        .{ .label = "List Items", .icon = .view_list, .badge = if (state.badge_count > 0) state.badge_count else null },
        .{ .label = "Grids & Drag", .icon = .apps },
    };

    const tab_body = switch (state.sub_tab) {
        0 => cx.make(facet.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .spacing = 16,
            .children = &.{
                sectionHeading(cx, "Cards", "Filled, elevated and outlined Material 3 surface cards (click to select)"),
                cx.make(facet.Row{
                    .spacing = 16,
                    .cross_axis_alignment = .start,
                    .children = &.{
                        cx.make(facet.Expanded{ .child = cx.make(facet.Card{
                            .variant = .filled,
                            .selected = state.selected_card == 0,
                            .on_press = .of(state, Showcase.State.selectCard0),
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(facet.Text{ .text = "Filled Card", .style = .{ .size = 16, .color = t.on_surface }, .wrap = false }),
                                    cx.make(facet.Text{ .text = "High-contrast surface container for featured items.", .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }) }),
                        cx.make(facet.Expanded{ .child = cx.make(facet.Card{
                            .variant = .elevated,
                            .selected = state.selected_card == 1,
                            .on_press = .of(state, Showcase.State.selectCard1),
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(facet.Text{ .text = "Elevated Card", .style = .{ .size = 16, .color = t.on_surface }, .wrap = false }),
                                    cx.make(facet.Text{ .text = "Tonal surface container separating content from background.", .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }) }),
                        cx.make(facet.Expanded{ .child = cx.make(facet.Card{
                            .variant = .outlined,
                            .selected = state.selected_card == 2,
                            .on_press = .of(state, Showcase.State.selectCard2),
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(facet.Text{ .text = "Outlined Card", .style = .{ .size = 16, .color = t.on_surface }, .wrap = false }),
                                    cx.make(facet.Text{ .text = "Clean outline border on the base surface colour.", .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }) }),
                    },
                }),
                cx.make(facet.Divider{}),
                sectionHeading(cx, "Badges", "Status dots, notification counts, 99+ overflow and custom labels"),
                cx.make(facet.Row{
                    .spacing = 24,
                    .main_axis_size = .min,
                    .cross_axis_alignment = .center,
                    .children = &.{
                        cx.make(facet.Badge{ .child = cx.make(facet.Icon{ .icon = .wifi, .size = 28 }) }),
                        cx.make(facet.Badge{ .count = state.badge_count, .show = state.badge_count > 0, .child = cx.make(facet.Icon{ .icon = .folder, .size = 28 }) }),
                        cx.make(facet.Badge{ .count = 128, .child = cx.make(facet.Icon{ .icon = .article, .size = 28 }) }),
                        cx.make(facet.Badge{ .label = "NEW" }),
                        cx.make(facet.OutlinedButton{ .label = "Add badge", .icon = .add, .on_press = .of(state, Showcase.State.addBadge) }),
                        cx.make(facet.TextButton{ .label = "Clear", .on_press = .of(state, Showcase.State.clearBadge) }),
                    },
                }),
            },
        }),
        1 => cx.make(facet.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .spacing = 12,
            .children = &.{
                sectionHeading(cx, "List Items & Dividers", "One-line and two-line list rows inside an outlined Card"),
                cx.make(facet.Card{
                    .variant = .outlined,
                    .padding = .all(4),
                    .child = cx.make(facet.Column{
                        .main_axis_size = .min,
                        .cross_axis_alignment = .stretch,
                        .children = &.{
                            cx.make(facet.ListItem{
                                .headline = "Wi-Fi Network",
                                .supporting_text = "Connected to Canonical-5G (192.168.1.42/24)",
                                .leading_icon = .wifi,
                                .trailing_text = "5 GHz",
                                .trailing_icon = .chevron_right,
                                .selected = state.selected_list_item == 0,
                                .on_press = .of(state, Showcase.State.selectList0),
                            }),
                            cx.make(facet.Divider{ .inset = 16 }),
                            cx.make(facet.ListItem{
                                .headline = "GPIO Header",
                                .supporting_text = "40-pin header  ·  I2C1 and SPI0 enabled",
                                .leading_icon = .developer_board,
                                .trailing_icon = .chevron_right,
                                .selected = state.selected_list_item == 1,
                                .on_press = .of(state, Showcase.State.selectList1),
                            }),
                            cx.make(facet.Divider{ .inset = 16 }),
                            cx.make(facet.ListItem{
                                .headline = "USB Storage Drive",
                                .supporting_text = "14.2 GB free of 16.0 GB",
                                .leading_icon = .usb,
                                .trailing = cx.make(facet.Badge{ .label = "Mounted", .color = t.primary }),
                                .selected = state.selected_list_item == 2,
                                .on_press = .of(state, Showcase.State.selectList2),
                            }),
                        },
                    }),
                }),
            },
        }),
        else => cx.make(facet.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .spacing = 16,
            .children = &.{
                sectionHeading(cx, "LazyGrid, Draggable & DropTarget", "Virtualized grid of draggable cells and a drop target zone"),
                cx.make(facet.Row{
                    .spacing = 16,
                    .cross_axis_alignment = .start,
                    .children = &.{
                        cx.make(facet.Expanded{
                            .child = cx.make(facet.SizedBox{
                                .height = 200,
                                .child = cx.make(facet.ScrollView{
                                    .child = cx.make(facet.LazyGrid{
                                        .count = 120,
                                        .cell = .{ .w = 110, .h = 44 },
                                        .spacing = 8,
                                        .item = .of(state, buildLazyCell),
                                    }),
                                }),
                            }),
                        }),
                        cx.make(facet.SizedBox{
                            .width = 220,
                            .height = 200,
                            .child = cx.make(facet.DropTarget{
                                .on_drop = .of(state, Showcase.State.onDropItem),
                                .child = cx.make(facet.Card{
                                    .variant = .elevated,
                                    .child = cx.make(facet.Center{
                                        .child = cx.make(facet.Text{
                                            .text = if (state.dropped_item) |d|
                                                cx.fmt("Dropped Cell #{d}", .{d})
                                            else
                                                "Drop a cell here",
                                            .style = .{ .size = 14, .color = t.on_surface },
                                            .text_align = .center,
                                        }),
                                    }),
                                }),
                            }),
                        }),
                    },
                }),
            },
        }),
    };

    return cx.make(facet.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 20,
        .children = &.{
            cx.make(facet.TabBar{
                .tabs = &tabs,
                .selected = state.sub_tab,
                .on_select = .of(state, Showcase.State.selectTab),
            }),
            tab_body,
        },
    });
}

fn buildFeedbackPage(cx: *facet.Context, state: *Showcase.State) facet.Widget {
    const qr_text = if (state.text_len > 0) state.text_buf[0..state.text_len] else "https://github.com/robert-ancell/facet";
    return cx.make(facet.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 20,
        .children = &.{
            sectionHeading(
                cx,
                "Modal Dialog",
                cx.fmt("Opens a centered Dialog over a dimmed backdrop  ·  confirmed {d} times", .{state.confirmed_count}),
            ),
            cx.make(facet.Row{
                .spacing = 12,
                .main_axis_size = .min,
                .children = &.{
                    cx.make(facet.FilledButton{
                        .label = "Open Dialog",
                        .icon = .info,
                        .on_press = .of(state, Showcase.State.openDialog),
                    }),
                },
            }),
            cx.make(facet.Divider{}),
            sectionHeading(
                cx,
                "Snackbar",
                cx.fmt("Bottom notification bar with action and dismiss buttons  ·  undo pressed {d} times", .{state.snackbar_undo_count}),
            ),
            cx.make(facet.Row{
                .spacing = 12,
                .main_axis_size = .min,
                .children = &.{
                    cx.make(facet.TonalButton{
                        .label = "Show Saved Snackbar",
                        .icon = .save,
                        .on_press = .of(state, Showcase.State.showSavedSnackbar),
                    }),
                    cx.make(facet.OutlinedButton{
                        .label = "Show Network Snackbar",
                        .icon = .wifi,
                        .on_press = .of(state, Showcase.State.showNetworkSnackbar),
                    }),
                },
            }),
            cx.make(facet.Snackbar{
                .message = "Inline snackbar preview with an action button",
                .action_label = "Action",
                .on_action = .of(state, Showcase.State.addClick),
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "QrCode & Image", "ISO/IEC 18004 QR Code widget and bitmap Image widget"),
            cx.make(facet.Row{
                .spacing = 24,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.QrCode{
                        .text = qr_text,
                        .size = 132,
                    }),
                    cx.make(facet.SizedBox{
                        .width = 96,
                        .height = 96,
                        .child = cx.make(facet.Image{
                            .image = &state.sample_img,
                        }),
                    }),
                },
            }),
        },
    });
}

fn buildBackendPage(cx: *facet.Context) facet.Widget {
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

    return cx.make(facet.Column{
        .main_axis_size = .min,
        .cross_axis_alignment = .stretch,
        .spacing = 18,
        .children = &.{
            sectionHeading(
                cx,
                "Active Runtime Backend",
                "Live windowing platform, surface buffer transport, window decorations, and 2D renderer reported by cx.backend()",
            ),
            cx.make(facet.Row{
                .spacing = 16,
                .cross_axis_alignment = .start,
                .children = &.{
                    cx.make(facet.Expanded{
                        .child = cx.make(facet.Card{
                            .variant = .elevated,
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(facet.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = &.{
                                            cx.make(facet.Icon{ .icon = .computer, .size = 20, .color = t.primary }),
                                            cx.make(facet.Text{ .text = "Windowing Platform", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false }),
                                        },
                                    }),
                                    cx.make(facet.Text{ .text = info.platform.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false }),
                                    cx.make(facet.Text{ .text = platform_desc, .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }),
                    }),
                    cx.make(facet.Expanded{
                        .child = cx.make(facet.Card{
                            .variant = .elevated,
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(facet.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = &.{
                                            cx.make(facet.Icon{ .icon = .layers, .size = 20, .color = t.primary }),
                                            cx.make(facet.Text{ .text = "Buffer Transport", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false }),
                                        },
                                    }),
                                    cx.make(facet.Text{ .text = info.buffer_transport.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false }),
                                    cx.make(facet.Text{ .text = transport_desc, .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }),
                    }),
                    cx.make(facet.Expanded{
                        .child = cx.make(facet.Card{
                            .variant = .elevated,
                            .child = cx.make(facet.Column{
                                .main_axis_size = .min,
                                .cross_axis_alignment = .start,
                                .spacing = 6,
                                .children = &.{
                                    cx.make(facet.Row{
                                        .spacing = 8,
                                        .cross_axis_alignment = .center,
                                        .children = &.{
                                            cx.make(facet.Icon{ .icon = .memory, .size = 20, .color = t.primary }),
                                            cx.make(facet.Text{ .text = "2D Renderer", .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false }),
                                        },
                                    }),
                                    cx.make(facet.Text{ .text = info.renderer.name(), .style = .{ .size = 20, .color = t.on_surface }, .wrap = false }),
                                    cx.make(facet.Text{ .text = renderer_desc, .style = .{ .size = 13, .color = t.on_surface_variant } }),
                                },
                            }),
                        }),
                    }),
                },
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "Backend Matrix", "Checkmarks indicate the active platform, buffer protocol, decoration mode, and rendering pipeline"),
            cx.make(facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Text{ .text = "Platform:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false }),
                    cx.make(facet.Chip{ .label = "Wayland", .selected = info.platform == .wayland }),
                    cx.make(facet.Chip{ .label = "X11", .selected = info.platform == .x11 }),
                    cx.make(facet.Chip{ .label = "Windows", .selected = info.platform == .windows }),
                    cx.make(facet.Chip{ .label = "macOS", .selected = info.platform == .macos }),
                    cx.make(facet.Chip{ .label = "Headless", .selected = info.platform == .headless }),
                },
            }),
            cx.make(facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Text{ .text = "Surface Buffers:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false }),
                    cx.make(facet.Chip{ .label = "wl_shm", .selected = info.buffer_transport == .wl_shm }),
                    cx.make(facet.Chip{ .label = "linux_dmabuf", .selected = info.buffer_transport == .linux_dmabuf }),
                    cx.make(facet.Chip{ .label = "Swapchain", .selected = info.buffer_transport == .swapchain }),
                    cx.make(facet.Chip{ .label = "CPU Memory", .selected = info.buffer_transport == .memory }),
                },
            }),
            cx.make(facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Text{ .text = "Decorations:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false }),
                    cx.make(facet.Chip{ .label = "Client-side (CSD)", .selected = info.decorations == .client }),
                    cx.make(facet.Chip{ .label = "Server-side (SSD)", .selected = info.decorations == .server }),
                    cx.make(facet.Chip{ .label = "None", .selected = info.decorations == .none }),
                },
            }),
            cx.make(facet.Row{
                .spacing = 8,
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.Text{ .text = "Renderer:", .style = .{ .size = 14, .color = t.on_surface_variant }, .wrap = false }),
                    cx.make(facet.Chip{ .label = "Software", .selected = info.renderer == .software }),
                    cx.make(facet.Chip{ .label = "OpenGL", .selected = info.renderer == .opengl }),
                    cx.make(facet.Chip{ .label = "Vulkan", .selected = info.renderer == .vulkan }),
                },
            }),
            cx.make(facet.Divider{}),
            sectionHeading(cx, "Surface & Window Properties", "Live geometry, DPI scale, window decorations, window state, and input configuration"),
            cx.make(facet.Card{
                .variant = .outlined,
                .padding = .all(4),
                .child = cx.make(facet.Column{
                    .main_axis_size = .min,
                    .cross_axis_alignment = .stretch,
                    .children = &.{
                        cx.make(facet.ListItem{
                            .headline = "Windowing & Buffer Protocol",
                            .supporting_text = cx.fmt("{s}  ·  {s}", .{ platform_desc, transport_desc }),
                            .leading_icon = .computer,
                            .trailing = cx.make(facet.Badge{
                                .label = cx.fmt("{s} ({s})", .{ info.platform.name(), info.buffer_transport.name() }),
                                .color = t.primary,
                            }),
                        }),
                        cx.make(facet.Divider{ .inset = 16 }),
                        cx.make(facet.ListItem{
                            .headline = "Window Decorations",
                            .supporting_text = decorations_desc,
                            .leading_icon = .widgets,
                            .trailing = cx.make(facet.Badge{ .label = info.decorations.name(), .color = t.primary }),
                        }),
                        cx.make(facet.Divider{ .inset = 16 }),
                        cx.make(facet.ListItem{
                            .headline = "2D Rendering Pipeline",
                            .supporting_text = renderer_desc,
                            .leading_icon = .memory,
                            .trailing = cx.make(facet.Badge{ .label = info.renderer.name(), .color = t.primary }),
                        }),
                        cx.make(facet.Divider{ .inset = 16 }),
                        cx.make(facet.ListItem{
                            .headline = "Surface Resolution & HiDPI Scale",
                            .supporting_text = cx.fmt(
                                "Logical: {d} × {d} px  ·  Physical buffer: {d} × {d} px",
                                .{ info.logical_size[0], info.logical_size[1], info.physical_size[0], info.physical_size[1] },
                            ),
                            .leading_icon = .fullscreen,
                            .trailing_text = cx.fmt("{d}x scale", .{info.scale}),
                        }),
                        cx.make(facet.Divider{ .inset = 16 }),
                        cx.make(facet.ListItem{
                            .headline = "Window State & Keyboard Layout",
                            .supporting_text = cx.fmt("State: {s}  ·  Keyboard: {s}", .{ window_state, info.keyboard.name() }),
                            .leading_icon = .keyboard,
                            .trailing_text = info.keyboard.code(),
                        }),
                    },
                }),
            }),
        },
    });
}

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.open(init.gpa, init.minimal.environ, .{
        .title = "Widget Showcase",
        .app_id = "facet-showcase",
        .size = open_size,
        .min_size = min_size,
    });
    defer app.close();

    var doc = try facet.TextDocument.init(init.gpa, initial_notes);
    defer doc.deinit();

    while (try app.step(60 * std.time.ns_per_s)) {
        const now = facet.window.nowNs();
        app.takeInput();
        try app.draw(now, Showcase{ .doc = &doc });
    }
}
