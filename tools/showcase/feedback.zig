//! Feedback: progress indicators, badges, dialogs and snackbars.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

pub const Ringtone = enum { classic, chime, pulse };

pub const State = struct {
    /// Whether the determinate progress bar is filling, and how far.
    running: bool = true,
    progress: f32 = 0.25,
    last_ns: ?u64 = null,
    unread: u32 = 3,
    dialog: enum { none, simple, content } = .none,
    ringtone: Ringtone = .chime,
    snackbar: []const u8 = "",
    deleted: u32 = 0,
    log: common.Log = .{},

    fn setRunning(s: *State, v: bool) void {
        s.running = v;
        s.last_ns = null;
    }
    fn addUnread(s: *State) void {
        s.unread +|= 1;
    }
    fn addManyUnread(s: *State) void {
        s.unread +|= 50;
    }
    fn readAll(s: *State) void {
        s.unread = 0;
    }
    fn openSimple(s: *State) void {
        s.dialog = .simple;
    }
    fn openContent(s: *State) void {
        s.dialog = .content;
    }
    fn closeDialog(s: *State) void {
        s.dialog = .none;
        s.log.set("Cancelled the dialog", .{});
    }
    fn confirmDialog(s: *State) void {
        if (s.dialog == .simple) s.log.set("Discarded the draft", .{}) else s.log.set("Chose the {s} ringtone", .{@tagName(s.ringtone)});
        s.dialog = .none;
    }
    fn setRingtone(s: *State, v: Ringtone) void {
        s.ringtone = v;
    }
    fn showSaved(s: *State) void {
        s.snackbar = "Changes saved";
    }
    fn showDeleted(s: *State) void {
        s.deleted += 1;
        s.snackbar = "Message deleted";
    }
    fn undo(s: *State) void {
        s.deleted -|= 1;
        s.snackbar = "";
    }
    fn dismiss(s: *State) void {
        s.snackbar = "";
    }
};

pub fn build(cx: *facet.Context, s: *State) facet.Widget {
    const t = cx.theme();
    if (s.running) {
        const now = cx.now();
        if (s.last_ns) |prev| {
            const dt: f32 = @floatCast(@as(f64, @floatFromInt(now -| prev)) / std.time.ns_per_s);
            s.progress = @mod(s.progress + dt * 0.2, 1);
        }
        s.last_ns = now;
        cx.requestFrame();
    }

    return common.page(cx, &.{
        common.section(cx, "Progress indicators", "How far along work is, or that it is happening when that is not known", &.{
            common.labelled(cx, cx.fmt("Determinate {d:.0}%", .{s.progress * 100}), &.{
                cx.make(facet.Expanded{ .child = cx.make(facet.ProgressBar{ .value = s.progress }) }),
                cx.make(facet.SwitchRow{ .value = s.running, .on_changed = .of(s, State.setRunning), .label = "Run" }),
            }),
            common.labelled(cx, "Indeterminate", &.{
                cx.make(facet.Expanded{ .child = cx.make(facet.ProgressBar{}) }),
            }),
            common.labelled(cx, "Styled", &.{
                cx.make(facet.Expanded{ .child = cx.make(facet.ProgressBar{ .value = 0.7, .height = 12, .color = t.@"error", .track_color = t.surface_container_highest }) }),
            }),
            common.labelled(cx, "Spinners", &.{
                cx.make(facet.Spinner{ .size = 24 }),
                cx.make(facet.Spinner{}),
                cx.make(facet.Spinner{ .size = 64, .color = t.@"error" }),
            }),
        }),
        common.section(cx, "Badges", "Counts and labels on icons, or on their own", &.{
            common.labelled(cx, "On icons", &.{
                cx.make(facet.Badge{ .child = cx.make(facet.Icon{ .icon = .notifications, .size = 28 }) }),
                cx.make(facet.Badge{ .count = s.unread, .show = s.unread > 0, .child = cx.make(facet.Icon{ .icon = .mail, .size = 28 }) }),
                cx.make(facet.Badge{ .label = "NEW", .child = cx.make(facet.Icon{ .icon = .star, .size = 28 }) }),
            }),
            common.labelled(cx, "On their own", &.{
                cx.make(facet.Badge{ .count = 7 }),
                cx.make(facet.Badge{ .count = 1234 }),
                cx.make(facet.Badge{ .label = "Beta", .color = t.primary, .text_color = t.on_primary }),
            }),
            common.labelled(cx, cx.fmt("{d} unread", .{s.unread}), &.{
                cx.make(facet.OutlinedButton{ .label = "Add one", .icon = .add, .on_press = .of(s, State.addUnread) }),
                cx.make(facet.OutlinedButton{ .label = "Add 50", .on_press = .of(s, State.addManyUnread) }),
                cx.make(facet.TextButton{ .label = "Read all", .on_press = .of(s, State.readAll) }),
            }),
        }),
        common.section(cx, "Dialogs", "A question over the app that must be answered before going on", &.{
            cx.make(facet.Row{
                .spacing = 12,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.FilledButton{ .label = "Simple dialog", .on_press = .of(s, State.openSimple) }),
                    cx.make(facet.TonalButton{ .label = "Dialog with content", .icon = .notifications, .on_press = .of(s, State.openContent) }),
                    common.status(cx, s.log.text("")),
                },
            }),
        }),
        common.section(cx, "Snackbars", "A brief message at the bottom of the window, with an optional action", &.{
            cx.make(facet.Row{
                .spacing = 12,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(facet.TonalButton{ .label = "Save", .icon = .save, .on_press = .of(s, State.showSaved) }),
                    cx.make(facet.OutlinedButton{ .label = "Delete", .icon = .delete, .on_press = .of(s, State.showDeleted) }),
                    common.status(cx, cx.fmt("{d} messages deleted", .{s.deleted})),
                },
            }),
        }),
    });
}

/// `child` with the page's dialog and snackbar over it.
pub fn wrap(cx: *facet.Context, s: *State, child: facet.Widget) facet.Widget {
    const ringtones = [_]struct { Ringtone, []const u8 }{ .{ .classic, "Classic" }, .{ .chime, "Chime" }, .{ .pulse, "Pulse" } };
    var radios: [ringtones.len]facet.Widget = undefined;
    for (&radios, ringtones) |*w, r| {
        w.* = cx.make(facet.RadioRow(Ringtone){ .value = r[0], .group_value = s.ringtone, .on_changed = .of(s, State.setRingtone), .label = r[1] });
    }
    const with_snackbar = cx.make(facet.Snackbar{
        .message = s.snackbar,
        .action_label = if (std.mem.eql(u8, s.snackbar, "Message deleted")) "Undo" else "",
        .on_action = .of(s, State.undo),
        .on_dismiss = .of(s, State.dismiss),
        .child = child,
    });
    return switch (s.dialog) {
        .none => cx.make(facet.Dialog{ .open = false, .title = "", .child = with_snackbar }),
        .simple => cx.make(facet.Dialog{
            .title = "Discard draft?",
            .description = "The message you were writing will be lost.",
            .confirm_label = "Discard",
            .on_confirm = .of(s, State.confirmDialog),
            .dismiss_label = "Cancel",
            .on_dismiss = .of(s, State.closeDialog),
            .child = with_snackbar,
        }),
        .content => cx.make(facet.Dialog{
            .icon = .notifications,
            .title = "Ringtone",
            .description = "Choose the sound played for incoming calls.",
            .content = cx.make(facet.Column{ .main_axis_size = .min, .cross_axis_alignment = .start, .spacing = 4, .children = &radios }),
            .confirm_label = "OK",
            .on_confirm = .of(s, State.confirmDialog),
            .dismiss_label = "Cancel",
            .on_dismiss = .of(s, State.closeDialog),
            .child = with_snackbar,
        }),
    };
}
