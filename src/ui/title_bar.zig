//! TitleBar: the bar across the top of an app's window, with its title in
//! the middle and, at the right end, buttons that minimize, maximize (or
//! restore) and close it; dragging the bar moves the window. A title too
//! long for the bar ends in "…", and the bar is never narrower than its
//! buttons either side of a "…".
//!
//! On Wayland with client-side decorations (`decorations == .client`), `Ui`
//! automatically adds `TitleBar` above the app's root widget; when the
//! compositor provides server-side decorations (`decorations == .server`) or
//! the window is fullscreen, no client-side `TitleBar` is added.

const std = @import("std");
const Controls = @import("window").Controls;
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const Column = @import("flex.zig").Column;
const Decorated = @import("decorated.zig").Decorated;
const Row = @import("flex.zig").Row;
const SizedBox = @import("sized_box.zig").SizedBox;
const BarButton = @import("bar_button.zig").BarButton;
const Text = @import("text.zig").Text;
const btn_left = @import("widget.zig").btn_left;

const Node = widget.Node;
const Context = widget.Context;
const Widget = widget.Widget;
const Size = geometry.Size;
const Constraints = geometry.Constraints;

pub const TitleBar = struct {
    title: []const u8,
    /// Pressing the close button (defaults to `cx.ui.controls` when set);
    /// without it there is none.
    on_close: ?widget.Callback = null,
    /// Pressing the minimize button (defaults to `cx.ui.controls` when set,
    /// if the window can be minimized); without it there is none.
    on_minimize: ?widget.Callback = null,
    /// Pressing the maximize button, which shows whether the window fills
    /// the screen (defaults to `cx.ui.controls` when set, if the window can
    /// be maximized); without it there is none.
    on_maximize: ?widget.Callback = null,
    maximized: bool = true,
    /// A press on the bar itself, to start moving the window (defaults to
    /// `cx.ui.controls` when set).
    on_drag: ?widget.Callback = null,

    pub const height = 44;
    /// The buttons' size, the space between them, and that at the bar's
    /// ends and around the title.
    const button_size = 34;
    const spacing = 4;
    const margin = 8;
    /// How much of the title still shows in the narrowest window.
    const min_title_width = 120;

    pub fn build(self: *const TitleBar, cx: *Context) Widget {
        // A fullscreen window has none.
        if (cx.ui.fullscreen) return cx.make(@import("empty.zig").Empty{});
        const controls = cx.ui.controls;
        const win = cx.ui.win;
        const can_minimize = if (win) |w| w.canMinimize() else false;
        const can_maximize = if (win) |w| w.canMaximize() else true;
        const on_minimize = self.on_minimize orelse if (controls) |c| (if (can_minimize) widget.Callback.of(c, Controls.minimize) else null) else null;
        const on_maximize = self.on_maximize orelse if (controls) |c| (if (can_maximize) widget.Callback.of(c, Controls.toggleMaximized) else null) else null;
        const on_close = self.on_close orelse if (controls) |c| widget.Callback.of(c, Controls.close) else null;
        const on_drag = self.on_drag orelse if (controls) |c| widget.Callback.of(c, Controls.drag) else null;
        const maximized = if (self.on_maximize != null) self.maximized else cx.ui.maximized;
        const t = cx.theme();
        var buttons: [3]Widget = undefined;
        var n: usize = 0;
        if (on_minimize) |f| {
            buttons[n] = cx.make(BarButton{ .on_press = f, .size = button_size, .icon = .minimize });
            n += 1;
        }
        if (on_maximize) |f| {
            // A square fills the screen; two, one behind the other, go back
            // to the window's own size.
            buttons[n] = cx.make(BarButton{ .on_press = f, .size = button_size, .icon = if (maximized) .filter_none else .crop_square });
            n += 1;
        }
        if (on_close) |f| {
            buttons[n] = cx.make(BarButton{ .on_press = f, .size = button_size, .icon = .close });
            n += 1;
        }
        return cx.make(DragArea{ .on_drag = on_drag, .child = cx.make(Decorated{ .color = t.surface_container, .child = cx.make(Bar{
            .title = self.title,
            .children = &.{
                cx.make(Text{ .text = self.title, .style = .{ .color = t.on_surface }, .wrap = false, .ellipsis = true }),
                cx.make(Row{ .spacing = spacing, .main_axis_size = .min, .children = buttons[0..n] }),
            },
        }) }) });
    }
};

/// The title and the buttons: the buttons at the right end, and the title
/// in the middle of the bar, or as near it as it can be left of the buttons.
/// What does not fit ends in "…".
const Bar = struct {
    title: []const u8,
    /// The title's text, and the row of buttons.
    children: []const Widget,

    pub fn layout(_: *const Bar, n: *Node, c: Constraints) Size {
        const w = c.constrain(.{ .w = c.max_w, .h = TitleBar.height }).w;
        const h: f32 = TitleBar.height;
        const buttons = n.child(1);
        const bs = buttons.layout(.{ .max_w = w, .max_h = h });
        const buttons_x = w - TitleBar.margin - bs.w;
        buttons.place(buttons_x, (h - bs.h) / 2);
        const title = n.child(0);
        const end = (if (bs.w > 0) buttons_x else w) - TitleBar.margin;
        const ts = title.layout(.{ .max_w = @max(end - TitleBar.margin, 0), .max_h = h });
        const centred = (w - ts.w) / 2;
        title.place(@max(TitleBar.margin, @min(centred, end - ts.w)), @round((h - ts.h) / 2));
        return c.constrain(.{ .w = w, .h = h });
    }

    pub fn minSize(self: *const Bar, n: *Node, c: Constraints) Size {
        const buttons = n.child(1).minSize(.{});
        const title: f32 = if (n.ui.font) |f| n.ui.atlas.runs.measure(.{ .font = f, .size = n.ui.theme.body_size }, self.title) else 0;
        const gap: f32 = if (buttons.w > 0) TitleBar.margin else 0;
        return c.constrain(.{ .w = TitleBar.margin + @ceil(@min(title, TitleBar.min_title_width)) + gap + buttons.w + TitleBar.margin, .h = TitleBar.height });
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
    const f = try font.Font.init(font.default_font_data);
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
    const f = try font.Font.init(font.default_font_data);
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
    const f = try font.Font.init(font.default_font_data);
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
    const f = try font.Font.init(font.default_font_data);
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

fn findText(n: *Node) ?*Node {
    if (n.widget.is(Text)) return n;
    for (n.children.items) |ch| if (findText(ch)) |t| return t;
    return null;
}

test "a long title ends in an ellipsis before the buttons, and the bar sets the window's minimum width" {
    const Ui = @import("runtime.zig").Ui;
    const window_mod = @import("window");
    const u = try Ui.createDefault(testing.allocator);
    defer u.destroy();

    const MockWin = struct {
        pub const platform: window_mod.Platform = .wayland;
        title: []const u8 = "A very long window title that cannot possibly fit in a narrow window",
        decorations: window_mod.Decorations = .client,
        width: u32 = 300,
        height: u32 = 200,
        min_size: [2]u32 = .{ 0, 0 },
        minimized: u32 = 0,
        pub fn setMaximized(_: *@This(), _: bool) void {}
        pub fn setMinimized(self: *@This()) void {
            self.minimized += 1;
        }
        pub fn setMinSize(self: *@This(), w: u32, h: u32) void {
            self.min_size = .{ w, h };
        }
    };
    var win: MockWin = .{};
    var controls: Controls = .init(&win);
    u.attachWindow(&win, &controls);
    u.maximized = false;
    const Root = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(SizedBox{ .width = 10, .height = 10 });
        }
    };
    u.frame(win.width, win.height, 0, Root{});
    const bar = u.title_bar_root.?;
    const text = findText(bar).?;
    // In the app's text size, not a heading's.
    try testing.expect(text.size.h < 22);
    // Ellipsized, ending before the first (minimize) button, which is
    // three buttons from the right end.
    const text_right = text.position()[0] + text.size.w;
    const first_button = @as(f32, @floatFromInt(win.width)) - TitleBar.margin - 3 * TitleBar.button_size - 2 * TitleBar.spacing;
    try testing.expect(text_right <= first_button - TitleBar.margin);
    try testing.expect(!text.overflow.any());
    // The window is never too narrow for the buttons and the start of the
    // title.
    const buttons = 3 * TitleBar.button_size + 2 * TitleBar.spacing;
    try testing.expectEqual(@as(u32, 3 * TitleBar.margin + TitleBar.min_title_width + buttons), win.min_size[0]);

    // The first button minimizes.
    const at: geometry.Point = .{ first_button + TitleBar.button_size / 2, TitleBar.height / 2 };
    u.pointerMotion(at);
    u.pointerButton(at, btn_left, true);
    u.pointerButton(at, btn_left, false);
    try testing.expectEqual(@as(u32, 1), win.minimized);

    // So the title is never squeezed to less than that.
    u.frame(win.min_size[0], win.height, 1, Root{});
    try testing.expect(findText(u.title_bar_root.?).?.size.w > TitleBar.min_title_width - 20);
}

test "a window that cannot be minimized has no minimize button" {
    const Ui = @import("runtime.zig").Ui;
    const window_mod = @import("window");
    const u = try Ui.createDefault(testing.allocator);
    defer u.destroy();
    const MockWin = struct {
        pub const platform: window_mod.Platform = .wayland;
        title: []const u8 = "Title",
        decorations: window_mod.Decorations = .client,
        width: u32 = 400,
        height: u32 = 200,
        pub fn setMaximized(_: *@This(), _: bool) void {}
        pub fn setMinimized(_: *@This()) void {}
        pub fn canMinimize(_: *const @This()) bool {
            return false;
        }
    };
    var win: MockWin = .{};
    var controls: Controls = .init(&win);
    u.attachWindow(&win, &controls);
    u.frame(win.width, win.height, 0, SizedBox{ .width = 10, .height = 10 });
    var buttons: usize = 0;
    const count = struct {
        fn f(n: *Node, out: *usize) void {
            if (n.widget.is(BarButton)) out.* += 1;
            for (n.children.items) |ch| f(ch, out);
        }
    }.f;
    count(u.title_bar_root.?, &buttons);
    // Maximize and close.
    try testing.expectEqual(@as(usize, 2), buttons);
}
