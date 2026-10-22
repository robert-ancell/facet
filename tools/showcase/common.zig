//! Pieces the showcase's pages share: section headings, labelled rows of
//! demos, and callbacks that remember which control was used.

const std = @import("std");
const kete = @import("kete");

/// A page: its sections one above the other, with dividers between them.
pub fn page(cx: *kete.BuildContext, sections: []const kete.Widget) kete.Widget {
    const children = cx.arena.alloc(kete.Widget, sections.len * 2 -| 1) catch return cx.make(kete.SizedBox.empty);
    for (sections, 0..) |s, i| {
        children[i * 2] = s;
        if (i + 1 < sections.len) children[i * 2 + 1] = cx.make(kete.HorizontalDivider{});
    }
    return cx.make(kete.Column{
        .fill = false,
        .cross_axis_alignment = .stretch,
        .spacing = 20,
        .children = children,
    });
}

/// A section: a title, a line saying what it shows, and its demos.
pub fn section(cx: *kete.BuildContext, title: []const u8, subtitle: []const u8, demos: []const kete.Widget) kete.Widget {
    const t = cx.theme();
    const children = cx.arena.alloc(kete.Widget, demos.len + 1) catch return cx.make(kete.SizedBox.empty);
    children[0] = cx.make(kete.Column{
        .fill = false,
        .cross_axis_alignment = .start,
        .spacing = 4,
        .children = cx.makeAll(.{
            kete.Text{ .text = title, .style = .{ .size = 18, .color = t.on_surface }, .wrap = false },
            kete.Text{ .text = subtitle, .style = .{ .size = 13, .color = t.on_surface_variant } },
        }),
    });
    @memcpy(children[1..], demos);
    return cx.make(kete.Column{
        .fill = false,
        .cross_axis_alignment = .stretch,
        .spacing = 14,
        .children = children,
    });
}

/// Widgets in a row, with a label at the left saying what they are.
pub fn labelled(cx: *kete.BuildContext, label: []const u8, widgets: []const kete.Widget) kete.Widget {
    const t = cx.theme();
    const children = cx.arena.alloc(kete.Widget, widgets.len + 1) catch return cx.make(kete.SizedBox.empty);
    children[0] = cx.make(kete.SizedBox{
        .width = label_width,
        .child = cx.make(kete.Text{ .text = label, .style = .{ .size = 13, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
    });
    @memcpy(children[1..], widgets);
    return cx.make(kete.Row{
        .spacing = 12,
        .cross_axis_alignment = .center,
        .children = children,
    });
}

pub const label_width = 96;

/// Text saying what was last done, under a demo.
pub fn status(cx: *kete.BuildContext, text: []const u8) kete.Widget {
    const t = cx.theme();
    return cx.make(kete.Text{ .text = text, .style = .{ .size = 13, .color = t.primary }, .wrap = false, .ellipsis = true });
}

/// Where a page notes what was last done ("Pressed Filled").
pub const Log = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    pub fn set(log: *Log, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&log.buf, f, args) catch log.buf[0..];
        log.len = s.len;
    }

    pub fn text(log: *const Log, empty: []const u8) []const u8 {
        return if (log.len == 0) empty else log.buf[0..log.len];
    }
};

/// A callback noting in `log` that `name` was pressed.
pub fn pressed(cx: *kete.BuildContext, log: *Log, name: []const u8) kete.Callback {
    const Press = struct {
        log: *Log,
        name: []const u8,

        fn press(p: *const @This()) void {
            p.log.set("Pressed “{s}”", .{p.name});
        }
    };
    const p = cx.arena.create(Press) catch return .of(log, ignore);
    p.* = .{ .log = log, .name = name };
    return .of(p, Press.press);
}

fn ignore(_: *Log) void {}
