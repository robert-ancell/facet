//! Icons: Material's icons at any size and colour, and all of them, to
//! search and pick from.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

const Icon = facet.IconName;
const all = std.enums.values(Icon);

pub const State = struct {
    query: [64]u8 = undefined,
    query_len: usize = 0,
    /// The icons whose names have the query in them, by index in `all`.
    matches: [all.len]u16 = undefined,
    match_count: usize = 0,
    chosen: Icon = .favorite,

    fn setQuery(s: *State, v: []const u8) void {
        var n = @min(v.len, s.query.len);
        while (n > 0 and n < v.len and v[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(s.query[0..n], v[0..n]);
        s.query_len = n;
    }

    fn match(s: *State) void {
        const q = s.query[0..s.query_len];
        s.match_count = 0;
        for (all, 0..) |icon, i| {
            if (q.len > 0 and std.ascii.findIgnoreCase(@tagName(icon), q) == null) continue;
            s.matches[s.match_count] = @intCast(i);
            s.match_count += 1;
        }
    }
};

pub fn build(cx: *facet.Context, s: *State) facet.Widget {
    const t = cx.theme();
    s.match();
    const colours = [_]facet.Color{ t.on_surface, t.primary, t.@"error", .rgb(0x66bb6a), .rgb(0xffa726) };
    var sizes: [5]facet.Widget = undefined;
    for (&sizes, [_]f32{ 16, 24, 32, 48, 64 }) |*w, size| {
        w.* = cx.make(facet.Column{ .main_axis_size = .min, .spacing = 4, .children = cx.makeAll(.{
            facet.Icon{ .icon = s.chosen, .size = size, .color = t.on_surface },
            facet.Text{ .text = cx.fmt("{d:.0}", .{size}), .style = .{ .size = 12, .color = t.on_surface_variant }, .wrap = false },
        }) });
    }
    var tinted: [colours.len]facet.Widget = undefined;
    for (&tinted, colours) |*w, c| w.* = cx.make(facet.Icon{ .icon = s.chosen, .size = 40, .color = c });

    const q = s.query[0..s.query_len];
    return common.page(cx, &.{
        common.section(cx, cx.fmt("All {d} icons", .{all.len}), "Material's icons, from a font of them built in; type to search their names, and press one to choose it", cx.makeAll(.{
            facet.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = cx.makeAll(.{
                facet.TextField{ .placeholder = "Search", .initial = q, .on_changed = .of(s, State.setQuery) },
                common.status(cx, if (q.len == 0) cx.fmt("{d} icons", .{s.match_count}) else cx.fmt("{d} with “{s}”", .{ s.match_count, q })),
            }) },
            facet.SizedBox{
                .height = 340,
                .child = cx.make(facet.Decorated{
                    .border = .{ .width = 1, .color = t.outline_variant },
                    .radius = .all(8),
                    .child = if (s.match_count == 0)
                        cx.make(facet.Center{ .child = cx.make(facet.Text{ .text = "No icon has that in its name", .style = .{ .color = t.on_surface_variant } }) })
                    else
                        // A view for each search, so each starts at the top.
                        cx.make(facet.ScrollView{ .child = cx.make(facet.Padding{ .padding = .all(8), .child = cx.make(facet.LazyGrid{
                            .count = s.match_count,
                            .cell = .{ .w = 104, .h = 76 },
                            .spacing = 4,
                            .item = .of(s, cell),
                        }) }) }).withKey(std.hash.Wyhash.hash(0, q)),
                }),
            },
        })),
        common.section(cx, cx.fmt("“{s}”", .{@tagName(s.chosen)}), "The icon chosen, at sizes and in colours", cx.makeAll(.{
            facet.Row{ .spacing = 20, .cross_axis_alignment = .end, .children = &sizes },
            facet.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = &tinted },
            facet.Decorated{ .color = t.surface_container, .radius = .all(6), .child = cx.make(facet.Padding{
                .padding = .symmetric(12, 8),
                .child = cx.make(facet.Text{ .text = cx.fmt("cx.make(facet.Icon{{ .icon = .{f}, .size = 24 }})", .{std.zig.fmtId(@tagName(s.chosen))}), .style = .{ .size = 13, .color = t.on_surface } }),
            }) },
        })),
    });
}

/// The `i`th icon found: it and its name, to press to choose it.
fn cell(s: *State, cx: *facet.Context, i: usize) facet.Widget {
    const t = cx.theme();
    const icon = all[s.matches[i]];
    const Choose = struct {
        s: *State,
        icon: Icon,
        fn choose(c: *const @This()) void {
            c.s.chosen = c.icon;
        }
    };
    const c = cx.arena.create(Choose) catch return cx.make(facet.SizedBox.empty);
    c.* = .{ .s = s, .icon = icon };
    const chosen = s.chosen == icon;
    return cx.make(facet.Tooltip{ .text = @tagName(icon), .child = cx.make(facet.Card{
        .variant = if (chosen) .filled else .outlined,
        .selected = chosen,
        .padding = .all(6),
        .radius = 8,
        .on_press = .of(c, Choose.choose),
        .child = cx.make(facet.Column{ .spacing = 6, .children = cx.makeAll(.{
            facet.Icon{ .icon = icon, .size = 28, .color = if (chosen) t.primary else t.on_surface },
            facet.Text{ .text = @tagName(icon), .style = .{ .size = 11, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true, .text_align = .center },
        }) }),
    }) });
}
