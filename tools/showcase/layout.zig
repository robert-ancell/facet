//! Layout: rows and columns, sharing space, grids, layers, alignment,
//! sizing, decoration, and the building blocks for pressing and dragging.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

const swatches = [_]u24{ 0xef5350, 0xffa726, 0x66bb6a, 0x42a5f5, 0xab47bc, 0x26a69a };
const fruit = [_][]const u8{ "Apple", "Banana", "Cherry", "Grape" };

pub const State = struct {
    hover: facet.PointerInteraction = .{},
    presses: u32 = 0,
    basket: [fruit.len]bool = @splat(false),
    /// Each theme panel's switch.
    themed_switches: [3]bool = .{ true, true, true },

    fn press(s: *State) void {
        s.presses += 1;
    }
    fn drop(s: *State, i: usize) void {
        if (i < s.basket.len) s.basket[i] = true;
    }
    fn empty(s: *State) void {
        s.basket = @splat(false);
    }
};

/// A coloured box, `w` by `h`.
fn box(cx: *facet.Context, i: usize, w: ?f32, h: ?f32) facet.Widget {
    return cx.make(facet.SizedBox{ .width = w, .height = h, .child = cx.make(facet.Decorated{
        .color = .rgb(swatches[i % swatches.len]),
        .radius = .all(4),
    }) });
}

/// `child` on a strip `height` high, showing the space it lays out in.
fn strip(cx: *facet.Context, height: f32, child: facet.Widget) facet.Widget {
    const t = cx.theme();
    return cx.make(facet.Expanded{ .child = cx.make(facet.SizedBox{ .height = height, .child = cx.make(facet.Decorated{
        .color = t.surface_container,
        .radius = .all(6),
        .child = cx.make(facet.Padding{ .padding = .all(6), .child = child }),
    }) }) });
}

/// The light theme in a dark one, and the other way round.
fn opposite(t: *const facet.Theme) facet.Theme {
    return if (t.brightness == .dark) .light else .dark;
}

/// The theme with its primary colour teal, and its error colour a brighter
/// red than Material's.
fn custom(t: *const facet.Theme) facet.Theme {
    var out = t.*;
    switch (t.brightness) {
        .dark => {
            out.primary = .rgb(0x4fd8c4);
            out.on_primary = .rgb(0x003731);
            out.@"error" = .rgb(0xff5449);
            out.on_error = .rgb(0xffffff);
        },
        .light => {
            out.primary = .rgb(0x006a60);
            out.on_primary = .rgb(0xffffff);
            out.@"error" = .rgb(0xd32f2f);
        },
    }
    return out;
}

/// A few widgets on a surface, in whatever theme it is in.
const ThemePanel = struct {
    title: []const u8,
    on: *bool,

    fn set(on: *bool, v: bool) void {
        on.* = v;
    }

    pub fn build(self: *const ThemePanel, cx: *facet.Context) facet.Widget {
        const t = cx.theme();
        return cx.make(facet.Decorated{
            .color = t.surface,
            .border = .{ .width = 1, .color = t.outline_variant },
            .radius = .all(12),
            .child = cx.make(facet.Padding{ .padding = .all(12), .child = cx.make(facet.Column{
                .fill = false,
                .cross_axis_alignment = .start,
                .spacing = 10,
                .children = cx.makeAll(.{
                    facet.Text{ .text = self.title, .style = .{ .color = t.on_surface }, .wrap = false, .ellipsis = true },
                    facet.Row{ .spacing = 10, .cross_axis_alignment = .center, .children = cx.makeAll(.{
                        facet.Switch{ .value = self.on.*, .on_changed = .of(self.on, set) },
                        facet.Badge{ .count = 3, .child = cx.make(facet.Icon{ .icon = .mail }) },
                    }) },
                    facet.FilledButton{ .label = "Save", .on_press = .of(self.on, toggle) },
                    facet.OutlinedButton{ .label = "Delete", .icon = .delete, .destructive = true, .on_press = .of(self.on, toggle) },
                }),
            }) }),
        });
    }

    fn toggle(on: *bool) void {
        on.* = !on.*;
    }
};

/// A fruit, to drag or in the basket.
fn fruitPill(cx: *facet.Context, name: []const u8, in_basket: bool) facet.Widget {
    const t = cx.theme();
    const fg = if (in_basket) t.on_primary_container else t.on_surface;
    return cx.make(facet.Decorated{
        .color = if (in_basket) t.primary_container else t.surface_container_highest,
        .radius = .all(16),
        .child = cx.make(facet.Padding{ .padding = .symmetric(12, 6), .child = cx.make(facet.Row{
            .fill = false,
            .spacing = 6,
            .cross_axis_alignment = .center,
            .children = cx.makeAll(.{
                facet.Icon{ .icon = .sell, .size = 18, .color = fg },
                facet.Text{ .text = name, .style = .{ .size = 14, .color = fg }, .wrap = false },
            }),
        }) }),
    });
}

pub fn build(cx: *facet.Context, s: *State) facet.Widget {
    const t = cx.theme();

    const mains = [_]facet.MainAxisAlignment{ .start, .center, .end, .space_between, .space_around, .space_evenly };
    var main_rows: [mains.len]facet.Widget = undefined;
    for (&main_rows, mains) |*w, m| {
        w.* = common.labelled(cx, @tagName(m), &.{strip(cx, 36, cx.make(facet.Row{
            .main_axis_alignment = m,
            .spacing = 6,
            .children = &.{ box(cx, 0, 40, 24), box(cx, 1, 40, 24), box(cx, 2, 40, 24) },
        }))});
    }

    const crosses = [_]facet.CrossAxisAlignment{ .start, .center, .end, .stretch };
    var cross_rows: [crosses.len]facet.Widget = undefined;
    for (&cross_rows, crosses) |*w, c| {
        w.* = common.labelled(cx, @tagName(c), &.{strip(cx, 56, cx.make(facet.Row{
            .cross_axis_alignment = c,
            .spacing = 6,
            .children = &.{ box(cx, 3, 40, 16), box(cx, 4, 40, 28), box(cx, 5, 40, 40) },
        }))});
    }

    var tiles: [12]facet.Widget = undefined;
    for (&tiles, 0..) |*w, i| {
        w.* = cx.make(facet.Decorated{
            .color = .rgb(swatches[i % swatches.len]),
            .radius = .all(6),
            .child = cx.make(facet.Align.center(cx.make(facet.Text{ .text = cx.fmt("{d}", .{i + 1}), .style = .{ .color = .rgb(0xffffff) }, .wrap = false }))),
        });
    }

    const alignments = [_]struct { facet.Alignment, []const u8 }{
        .{ .top_left, "top left" },       .{ .top_center, "top center" },       .{ .top_right, "top right" },
        .{ .center_left, "center left" }, .{ .center, "center" },               .{ .center_right, "center right" },
        .{ .bottom_left, "bottom left" }, .{ .bottom_center, "bottom center" }, .{ .bottom_right, "bottom right" },
    };
    var layers: [alignments.len + 1]facet.Widget = undefined;
    layers[0] = cx.make(facet.Decorated{ .color = t.surface_container, .radius = .all(8) });
    for (layers[1..], alignments) |*w, a| {
        w.* = cx.make(facet.Align{ .alignment = a[0], .child = cx.make(facet.Padding{
            .padding = .all(8),
            .child = cx.make(facet.Decorated{
                .color = t.primary_container,
                .radius = .all(4),
                .child = cx.make(facet.Padding{ .padding = .symmetric(8, 4), .child = cx.make(facet.Text{
                    .text = a[1],
                    .style = .{ .size = 12, .color = t.on_primary_container },
                    .wrap = false,
                }) }),
            }),
        }) });
    }

    var sources: [fruit.len]facet.Widget = undefined;
    var source_count: usize = 0;
    var basket: [fruit.len]facet.Widget = undefined;
    var basket_count: usize = 0;
    for (fruit, s.basket, 0..) |name, in_basket, i| {
        if (in_basket) {
            basket[basket_count] = fruitPill(cx, name, true);
            basket_count += 1;
        } else {
            sources[source_count] = cx.make(facet.Draggable{
                .data = i,
                .label = name,
                .icon = .sell,
                .child = fruitPill(cx, name, false),
            });
            source_count += 1;
        }
    }

    return common.page(cx, &.{
        common.section(cx, "Rows and columns", "Children along a line: spread along it by main axis alignment", &main_rows),
        common.section(cx, "Cross axis alignment", "And placed across it by cross axis alignment", &cross_rows),
        common.section(cx, "Sharing space", "Expanded children share what is left over by their flex: here 1, 2 and 3", cx.makeAll(.{
            facet.Row{ .spacing = 6, .children = cx.makeAll(.{
                facet.Expanded{ .flex = 1, .child = box(cx, 0, null, 32) },
                facet.Expanded{ .flex = 2, .child = box(cx, 1, null, 32) },
                facet.Expanded{ .flex = 3, .child = box(cx, 2, null, 32) },
            }) },
            facet.SizedBox{ .height = 120, .child = cx.make(facet.Row{ .spacing = 6, .cross_axis_alignment = .stretch, .children = cx.makeAll(.{
                box(cx, 3, 80, null),
                facet.Expanded{ .child = cx.make(facet.Column{ .spacing = 6, .cross_axis_alignment = .stretch, .children = cx.makeAll(.{
                    facet.Expanded{ .child = box(cx, 4, null, null) },
                    facet.Expanded{ .flex = 2, .child = box(cx, 5, null, null) },
                }) }) },
            }) }) },
        })),
        common.section(cx, "Grid", "Equal cells, as many to a row as fit", cx.makeAll(.{
            facet.Grid.fixed(cx, &tiles, .{ .w = 72, .h = 48 }, 8),
        })),
        common.section(cx, "Layers and alignment", "An overlay stacks layers; each aligns its content in the space", cx.makeAll(.{
            facet.SizedBox{ .height = 170, .child = cx.make(facet.Overlay{ .children = &layers }) },
        })),
        common.section(cx, "Sizing", "Fixed sizes, sizes within limits, padding, and centering", &.{
            common.labelled(cx, "Sized box", &.{ box(cx, 0, 24, 24), box(cx, 1, 48, 24), box(cx, 2, 96, 24) }),
            common.labelled(cx, "Constrained", cx.makeAll(.{
                facet.ConstrainedBox{ .constraints = .{ .min_w = 160, .max_w = 160 }, .child = cx.make(facet.OutlinedButton{ .label = "At least 160 wide", .on_press = .of(s, State.press) }) },
                facet.ConstrainedBox{ .constraints = .{ .max_w = 120 }, .child = cx.make(facet.Text{ .text = "At most 120 pixels wide, so this wraps", .style = .{ .size = 13, .color = t.on_surface } }) },
            })),
            common.labelled(cx, "Padding", cx.makeAll(.{
                facet.Decorated{ .color = t.surface_container_highest, .radius = .all(4), .child = cx.make(facet.Padding{ .padding = .all(4), .child = box(cx, 3, 32, 16) }) },
                facet.Decorated{ .color = t.surface_container_highest, .radius = .all(4), .child = cx.make(facet.Padding{ .padding = .all(16), .child = box(cx, 3, 32, 16) }) },
                facet.Decorated{ .color = t.surface_container_highest, .radius = .all(4), .child = cx.make(facet.Padding{ .padding = .symmetric(32, 4), .child = box(cx, 3, 32, 16) }) },
            })),
            common.labelled(cx, "Center", &.{strip(cx, 56, cx.make(facet.Align.center(box(cx, 4, 64, 20))))}),
        }),
        common.section(cx, "Decoration", "Backgrounds, borders, and rounded corners, the same or each different", cx.makeAll(.{
            facet.Row{ .spacing = 12, .children = cx.makeAll(.{
                facet.SizedBox{ .width = 72, .height = 48, .child = cx.make(facet.Decorated{ .color = t.primary }) },
                facet.SizedBox{ .width = 72, .height = 48, .child = cx.make(facet.Decorated{ .color = t.primary, .radius = .all(12) }) },
                facet.SizedBox{ .width = 72, .height = 48, .child = cx.make(facet.Decorated{ .color = t.primary, .radius = .all(24) }) },
                facet.SizedBox{ .width = 72, .height = 48, .child = cx.make(facet.Decorated{ .color = t.primary, .radius = .{ .tl = 24, .br = 24 } }) },
                facet.SizedBox{ .width = 72, .height = 48, .child = cx.make(facet.Decorated{ .border = .{ .width = 2, .color = t.primary }, .radius = .all(12) }) },
                facet.SizedBox{ .width = 72, .height = 48, .child = cx.make(facet.Decorated{ .color = t.primary_container, .border = .{ .width = 4, .color = t.outline }, .radius = .{ .tl = 4, .tr = 16, .br = 4, .bl = 16 } }) },
            }) },
        })),
        common.section(cx, "Themes", "Themed gives the widgets below it a theme of its own: here the opposite one, and one with colours changed", cx.makeAll(.{
            facet.Row{ .spacing = 12, .cross_axis_alignment = .start, .children = cx.makeAll(.{
                facet.Expanded{ .child = cx.make(ThemePanel{ .title = "The app's theme", .on = &s.themed_switches[0] }) },
                facet.Expanded{ .child = cx.make(facet.Themed{ .theme = opposite(cx.theme()), .child = cx.make(ThemePanel{ .title = "The opposite", .on = &s.themed_switches[1] }) }) },
                facet.Expanded{ .child = cx.make(facet.Themed{ .theme = custom(cx.theme()), .child = cx.make(ThemePanel{ .title = "Changed colours", .on = &s.themed_switches[2] }) }) },
            }) },
        })),
        common.section(cx, "Pressing", "Pressable makes anything a button, and says when the pointer is over it or pressing it", cx.makeAll(.{
            facet.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = cx.makeAll(.{
                facet.Pressable{
                    .on_press = .of(s, State.press),
                    .interaction = &s.hover,
                    .child = cx.make(facet.SizedBox{ .width = 200, .height = 56, .child = cx.make(facet.Decorated{
                        .color = if (s.hover.pressed) t.primary else if (s.hover.hovered) t.primary_container else t.surface_container_highest,
                        .radius = .all(28),
                        .child = cx.make(facet.Align.center(cx.make(facet.Text{
                            .text = if (s.hover.pressed) "Pressing" else if (s.hover.hovered) "Hovering" else "Press me",
                            .style = .{ .color = if (s.hover.pressed) t.on_primary else t.on_surface },
                            .wrap = false,
                        }))),
                    }) }),
                },
                common.status(cx, cx.fmt("Pressed {d} times", .{s.presses})),
            }) },
        })),
        common.section(cx, "Dragging and dropping", "Drag a fruit into the basket", cx.makeAll(.{
            facet.Row{ .spacing = 8, .cross_axis_alignment = .center, .children = if (source_count > 0) sources[0..source_count] else &[_]facet.Widget{
                common.status(cx, "All the fruit is in the basket"),
            } },
            facet.SizedBox{ .height = 96, .child = cx.make(facet.DropTarget{
                .on_drop = .of(s, State.drop),
                .child = cx.make(facet.Card{
                    .variant = .outlined,
                    .child = cx.make(facet.Row{ .spacing = 8, .cross_axis_alignment = .center, .children = cx.makeAll(.{
                        facet.Icon{ .icon = .folder, .color = t.on_surface_variant },
                        facet.Expanded{ .child = if (basket_count > 0)
                            cx.make(facet.Row{ .spacing = 8, .children = basket[0..basket_count] })
                        else
                            cx.make(facet.Text{ .text = "The basket is empty", .style = .{ .color = t.on_surface_variant } }) },
                        facet.TextButton{ .label = "Empty", .on_press = if (basket_count > 0) .of(s, State.empty) else null },
                    }) }),
                }),
            }) },
        })),
    });
}
