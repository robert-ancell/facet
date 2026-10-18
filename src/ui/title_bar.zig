//! TitleBar: the bar across the top of an app's window, with its title in
//! the middle and, at the right end, buttons that maximize (or restore) and
//! close it; dragging the bar moves the window.
//!
//! On Wayland with client-side decorations (`decorations == .client`), `Ui`
//! automatically adds `TitleBar` above the app's root widget; when the
//! compositor provides server-side decorations (`decorations == .server`) or
//! the window is fullscreen, no client-side `TitleBar` is added.

const std = @import("std");
const Controls = @import("window").Controls;
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Align = @import("align.zig").Align;
const Center = @import("center.zig").Center;
const Column = @import("flex.zig").Column;
const Decorated = @import("decorated.zig").Decorated;
const Overlay = @import("overlay.zig").Overlay;
const Padding = @import("padding.zig").Padding;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const BarButton = @import("bar_button.zig").BarButton;
const btn_left = @import("widget.zig").btn_left;

const Node = widget.Node;
const Context = widget.Context;
const Widget = widget.Widget;

pub const TitleBar = struct {
    title: []const u8,
    /// Pressing the close button (defaults to `cx.ui.controls` when set);
    /// without it there is none.
    on_close: ?widget.Callback = null,
    /// Pressing the maximize button, which shows whether the window fills
    /// the screen (defaults to `cx.ui.controls` when set); without it
    /// there is none.
    on_maximize: ?widget.Callback = null,
    maximized: bool = true,
    /// A press on the bar itself, to start moving the window (defaults to
    /// `cx.ui.controls` when set).
    on_drag: ?widget.Callback = null,

    pub const height = 44;

    pub fn build(self: *const TitleBar, cx: *Context) Widget {
        // A fullscreen window has none.
        if (cx.ui.fullscreen) return cx.make(@import("empty.zig").Empty{});
        const controls = cx.ui.controls;
        const on_maximize = self.on_maximize orelse if (controls) |c| widget.Callback.of(c, Controls.toggleMaximized) else null;
        const on_close = self.on_close orelse if (controls) |c| widget.Callback.of(c, Controls.close) else null;
        const on_drag = self.on_drag orelse if (controls) |c| widget.Callback.of(c, Controls.drag) else null;
        const maximized = if (self.on_maximize != null) self.maximized else cx.ui.maximized;
        const t = cx.theme();
        const size = 34;
        var buttons: [2]Widget = undefined;
        var n: usize = 0;
        if (on_maximize) |f| {
            // A square fills the screen; two, one behind the other, go back
            // to the window's own size.
            buttons[n] = cx.make(BarButton{ .on_press = f, .size = size, .icon = if (maximized) .filter_none else .crop_square });
            n += 1;
        }
        if (on_close) |f| {
            buttons[n] = cx.make(BarButton{ .on_press = f, .size = size, .icon = .close });
            n += 1;
        }
        const row = cx.make(Align{ .alignment = .center_right, .child = cx.make(Padding{
            .padding = .{ .right = 8 },
            .child = cx.make(Row{ .spacing = 4, .main_axis_size = .min, .children = cx.ui.arena().dupe(Widget, buttons[0..n]) catch &.{} }),
        }) });
        return cx.make(DragArea{ .on_drag = on_drag, .child = cx.make(Decorated{ .color = t.surface_container, .child = cx.make(SizedBox{
            .height = height,
            .child = cx.make(Overlay{ .children = &.{
                cx.make(Center{ .child = cx.make(@import("text.zig").Text{ .text = self.title, .style = .{ .size = 22, .color = t.on_surface }, .wrap = false }) }),
                row,
            } }),
        }) }) });
    }
};

/// Calls `on_drag` when pressed (the buttons on it get their presses
/// first). It does not take the pointer: the shell does, to move the
/// window, so the release never comes here.
const DragArea = struct {
    on_drag: ?widget.Callback,
    child: ?Widget = null,

    pub fn event(self: *const DragArea, _: *Node, e: widget.Event) bool {
        switch (e) {
            .press => |p| if (p.button == btn_left) if (self.on_drag) |f| f.call(),
            else => {},
        }
        return false;
    }
};

const testing = std.testing;

test "the title bar's buttons, and dragging it" {
    const Ui = @import("runtime.zig").Ui;
    const font = @import("font");
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try Ui.create(testing.allocator, &f);
    defer u.destroy();
    const App = struct {
        closed: bool = false,
        drags: u32 = 0,
        maximizes: u32 = 0,
        fn close(a: *@This()) void {
            a.closed = true;
        }
        fn drag(a: *@This()) void {
            a.drags += 1;
        }
        fn maximize(a: *@This()) void {
            a.maximizes += 1;
        }
    };
    var app: App = .{};
    u.frame(800, 600, 0, Column{ .cross_axis_alignment = .stretch, .children = &.{} });
    const Root = struct {
        app: *App,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(Column{ .cross_axis_alignment = .stretch, .children = &.{
                cx.make(TitleBar{ .title = "Settings", .on_close = .of(self.app, App.close), .on_maximize = .of(self.app, App.maximize), .on_drag = .of(self.app, App.drag) }),
            } });
        }
    };
    u.frame(800, 600, 0, Root{ .app = &app });
    // The bar is across the top, 44 high; the button at its right end.
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, btn_left, true);
    u.pointerButton(at, btn_left, false);
    try testing.expect(app.closed);
    // Elsewhere on the bar starts a drag (and closes nothing).
    app.closed = false;
    u.pointerMotion(.{ 400, 22 });
    u.pointerButton(.{ 400, 22 }, btn_left, true);
    try testing.expect(!app.closed);
    try testing.expectEqual(@as(u32, 1), app.drags);
    // The shell takes the pointer for the drag, so no release comes; the
    // next press still works. The maximize button is left of the close
    // button.
    const max_at: geometry.Point = .{ 800 - 8 - 34 - 4 - 17, 22 };
    u.pointerMotion(max_at);
    u.pointerButton(max_at, btn_left, true);
    u.pointerButton(max_at, btn_left, false);
    try testing.expectEqual(@as(u32, 1), app.maximizes);
    try testing.expectEqual(@as(u32, 1), app.drags);
}

test "a fullscreen window has no title bar" {
    const Ui = @import("runtime.zig").Ui;
    const font = @import("font");
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try Ui.create(testing.allocator, &f);
    defer u.destroy();
    var closed = false;
    const Root = struct {
        closed: *bool,
        fn close(b: *bool) void {
            b.* = true;
        }
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(Column{ .cross_axis_alignment = .stretch, .children = &.{
                cx.make(TitleBar{ .title = "Settings", .on_close = .of(self.closed, close) }),
            } });
        }
    };
    u.fullscreen = true;
    u.frame(800, 600, 0, Root{ .closed = &closed });
    // Where its close button would be, there is nothing to press.
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, btn_left, true);
    u.pointerButton(at, btn_left, false);
    try testing.expect(!closed);
    // Out of fullscreen, it is back.
    u.fullscreen = false;
    u.frame(800, 600, 1, Root{ .closed = &closed });
    u.pointerMotion(at);
    u.pointerButton(at, btn_left, true);
    u.pointerButton(at, btn_left, false);
    try testing.expect(closed);
}

test "the title bar defaults to the UI's window controls" {
    const Ui = @import("runtime.zig").Ui;
    const font = @import("font");
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try Ui.create(testing.allocator, &f);
    defer u.destroy();
    var controls: Controls = .{ .win = undefined };
    u.controls = &controls;
    const Root = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(Column{ .cross_axis_alignment = .stretch, .children = &.{
                cx.make(TitleBar{ .title = "Settings" }),
            } });
        }
    };
    u.frame(800, 600, 0, Root{});
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, btn_left, true);
    u.pointerButton(at, btn_left, false);
    try testing.expect(controls.quit);
}

test "Ui automatically adds TitleBar on Wayland with client-side decorations and omits it with server-side decorations" {
    const Ui = @import("runtime.zig").Ui;
    const window_mod = @import("window");
    const font = @import("font");
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try Ui.create(testing.allocator, &f);
    defer u.destroy();

    const MockWaylandWin = struct {
        pub const platform: window_mod.Platform = .wayland;
        pub const buffer_transport: window_mod.BufferTransport = .wl_shm;
        title: []const u8 = "Facet Test",
        decorations: window_mod.Decorations = .client,
        width: u32 = 800,
        height: u32 = 600,
    };
    var mock_win: MockWaylandWin = .{};
    var controls: Controls = .init(&mock_win);
    u.attachWindow(&mock_win, &controls);

    const Root = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(SizedBox{ .width = 200, .height = 100 });
        }
    };

    // With client-side decorations on Wayland, TitleBar is added automatically above root.
    u.frame(800, 600, 0, Root{});
    try testing.expect(u.title_bar_root != null);
    try testing.expectEqual(@as(f32, TitleBar.height), u.root.?.offset[1]);
    try testing.expectEqual(@as(f32, 600 - TitleBar.height), u.root.?.size.h);
    try testing.expectEqual(window_mod.Decorations.client, u.backend().decorations);

    // Clicking the automatic title bar's close button triggers controls.quit.
    const at: geometry.Point = .{ 800 - 8 - 17, 22 };
    u.pointerMotion(at);
    u.pointerButton(at, btn_left, true);
    u.pointerButton(at, btn_left, false);
    try testing.expect(controls.quit);

    // When the compositor negotiates server-side decorations, TitleBar is not added.
    controls.quit = false;
    mock_win.decorations = .server;
    u.syncWindow(&mock_win);
    u.frame(800, 600, 1, Root{});
    try testing.expect(u.title_bar_root == null);
    try testing.expectEqual(@as(f32, 0), u.root.?.offset[1]);
    try testing.expectEqual(@as(f32, 600), u.root.?.size.h);
    try testing.expectEqual(window_mod.Decorations.server, u.backend().decorations);
}

