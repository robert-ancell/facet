//! Animation: widgets made afresh each frame from how far through their time
//! they are, eased by the easing functions.

const std = @import("std");
const kete = @import("kete");
const common = @import("common.zig");

pub const State = struct {
    plays: u64 = 0,

    fn play(s: *State) void {
        s.plays += 1;
    }
};

pub fn build(cx: *kete.BuildContext, s: *State) kete.Widget {
    const anim = common.section(cx, "Animation", "A widget made afresh each frame from how far through its time it is, eased by a tweening function", animation(cx, s));
    return common.page(cx, &.{anim});
}

const Named = struct { []const u8, kete.Easing };

const easings = [_]Named{
    .{ "linear", .linear },
    .{ "inOutCubic", .inOutCubic },
    .{ "outBack", .outBack },
    .{ "outBounce", .outBounce },
    .{ "standard", .standard },
    .{ "emphasized", .emphasized_decelerate },
    .{ "steps(5)", kete.Easing.steps(5) },
};

fn animation(cx: *kete.BuildContext, s: *State) []const kete.Widget {
    const t = cx.theme();
    const rows = cx.arena.alloc(kete.Widget, easings.len + 2) catch return &.{};
    rows[0] = cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = cx.makeAll(.{
        kete.FilledButton{ .label = "Play", .icon = .bolt, .on_press = .of(s, State.play) },
        common.status(cx, "Each dot crosses in a second, eased differently"),
    }) });
    for (rows[1..][0..easings.len], &easings) |*row, *e| {
        row.* = common.labelled(cx, e[0], cx.makeAll(.{kete.Expanded{ .child = cx.make(kete.RoundedBox{
            .color = t.surface_container,
            .radius = .all(14),
            .child = cx.make(kete.SizedBox{ .height = 28, .child = cx.make(kete.Padding{
                .padding = .all(4),
                .child = cx.make(kete.AnimatedWidget{
                    .duration_ns = std.time.ns_per_s,
                    .restart = s.plays,
                    .builder = .of(e, dot),
                }),
            }) }),
        }) }}));
    }
    rows[easings.len + 1] = common.labelled(cx, "Back and forth", cx.makeAll(.{kete.Expanded{ .child = cx.make(kete.SizedBox{
        .height = 28,
        .child = cx.make(kete.AnimatedWidget{
            .duration_ns = 1500 * std.time.ns_per_ms,
            .repeat = .reverse,
            .builder = .func(pulse),
        }),
    }) }}));
    return rows;
}

/// A dot across its track, eased `t` of the way along (inset a little,
/// for easings that overshoot).
fn dot(e: *const Named, cx: *kete.BuildContext, t: f32) kete.Widget {
    return cx.make(kete.Align{
        .alignment = .{ .x = e[1].lerp(@as(f32, -0.8), 0.8, t), .y = 0 },
        .child = cx.make(kete.SizedBox{ .width = 20, .height = 20, .child = cx.make(kete.RoundedBox{
            .color = cx.theme().primary,
            .radius = .all(10),
        }) }),
    });
}

/// A bar growing and changing colour, and back.
fn pulse(cx: *kete.BuildContext, t: f32) kete.Widget {
    const th = cx.theme();
    const ease = kete.Easing.inOutSine;
    return cx.make(kete.Align{
        .alignment = .center_left,
        .child = cx.make(kete.SizedBox{ .width = ease.lerp(@as(f32, 40), 240, t), .height = 28, .child = cx.make(kete.RoundedBox{
            .color = ease.lerp(th.primary, th.@"error", t),
            .radius = .all(14),
        }) }),
    });
}
