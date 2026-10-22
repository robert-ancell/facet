//! Animation: widgets made afresh each frame from how far through their time
//! they are, eased by the easing functions.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

pub const State = struct {
    plays: u64 = 0,

    fn play(s: *State) void {
        s.plays += 1;
    }
};

pub fn build(cx: *facet.BuildContext, s: *State) facet.Widget {
    const anim = common.section(cx, "Animation", "A widget made afresh each frame from how far through its time it is, eased by a tweening function", animation(cx, s));
    return common.page(cx, &.{anim});
}

const Named = struct { []const u8, facet.Easing };

const easings = [_]Named{
    .{ "linear", .linear },
    .{ "inOutCubic", .inOutCubic },
    .{ "outBack", .outBack },
    .{ "outBounce", .outBounce },
    .{ "standard", .standard },
    .{ "emphasized", .emphasized_decelerate },
    .{ "steps(5)", facet.Easing.steps(5) },
};

fn animation(cx: *facet.BuildContext, s: *State) []const facet.Widget {
    const t = cx.theme();
    const rows = cx.arena.alloc(facet.Widget, easings.len + 2) catch return &.{};
    rows[0] = cx.make(facet.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = cx.makeAll(.{
        facet.FilledButton{ .label = "Play", .icon = .bolt, .on_press = .of(s, State.play) },
        common.status(cx, "Each dot crosses in a second, eased differently"),
    }) });
    for (rows[1..][0..easings.len], &easings) |*row, *e| {
        row.* = common.labelled(cx, e[0], cx.makeAll(.{facet.Expanded{ .child = cx.make(facet.RoundedBox{
            .color = t.surface_container,
            .radius = .all(14),
            .child = cx.make(facet.SizedBox{ .height = 28, .child = cx.make(facet.Padding{
                .padding = .all(4),
                .child = cx.make(facet.AnimatedWidget{
                    .duration_ns = std.time.ns_per_s,
                    .restart = s.plays,
                    .builder = .of(e, dot),
                }),
            }) }),
        }) }}));
    }
    rows[easings.len + 1] = common.labelled(cx, "Back and forth", cx.makeAll(.{facet.Expanded{ .child = cx.make(facet.SizedBox{
        .height = 28,
        .child = cx.make(facet.AnimatedWidget{
            .duration_ns = 1500 * std.time.ns_per_ms,
            .repeat = .reverse,
            .builder = .func(pulse),
        }),
    }) }}));
    return rows;
}

/// A dot across its track, eased `t` of the way along (inset a little,
/// for easings that overshoot).
fn dot(e: *const Named, cx: *facet.BuildContext, t: f32) facet.Widget {
    return cx.make(facet.Align{
        .alignment = .{ .x = e[1].lerp(@as(f32, -0.8), 0.8, t), .y = 0 },
        .child = cx.make(facet.SizedBox{ .width = 20, .height = 20, .child = cx.make(facet.RoundedBox{
            .color = cx.theme().primary,
            .radius = .all(10),
        }) }),
    });
}

/// A bar growing and changing colour, and back.
fn pulse(cx: *facet.BuildContext, t: f32) facet.Widget {
    const th = cx.theme();
    const ease = facet.Easing.inOutSine;
    return cx.make(facet.Align{
        .alignment = .center_left,
        .child = cx.make(facet.SizedBox{ .width = ease.lerp(@as(f32, 40), 240, t), .height = 28, .child = cx.make(facet.RoundedBox{
            .color = ease.lerp(th.primary, th.@"error", t),
            .radius = .all(14),
        }) }),
    });
}
