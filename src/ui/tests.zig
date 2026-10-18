//! Tests of the toolkit: layouts (sensible and not), state, input, and
//! what is painted (drawn on the CPU with the real shaders).

const std = @import("std");
const gfx = @import("gfx");
const font = @import("font");
const window = @import("window");
const ui = @import("ui.zig");

const testing = std.testing;
const Widget = ui.Widget;
const Context = ui.Context;
const Node = ui.Node;

const fira_data = font.default_font_data;

/// The first node (depth first) whose widget is a `T`.
fn find(n: *Node, comptime T: type) ?*Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (find(ch, T)) |f| return f;
    return null;
}

fn findAll(n: *Node, comptime T: type, out: *std.ArrayList(*Node)) !void {
    if (n.widget.is(T)) try out.append(testing.allocator, n);
    for (n.children.items) |ch| try findAll(ch, T, out);
}

const Image = struct {
    pixels: []u32,
    img: gfx.software.Image,

    fn init(u: *ui.Ui, w: u32, h: u32) !Image {
        const pixels = try testing.allocator.alloc(u32, w * h);
        @memset(pixels, 0xff000000);
        const img: gfx.software.Image = .{ .pixels = pixels, .width = w, .height = h };
        try u.preview(img);
        return .{ .pixels = pixels, .img = img };
    }

    fn deinit(i: Image) void {
        testing.allocator.free(i.pixels);
    }

    fn at(i: Image, x: u32, y: u32) u32 {
        return i.img.at(x, y);
    }
};

fn channels(px: u32) [3]u8 {
    return .{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) };
}

fn isYellow(px: u32) bool {
    const c = channels(px);
    return c[0] > 150 and c[1] > 150 and c[2] < 100;
}

const red = gfx.Color.rgb(0xff0000);
const blue = gfx.Color.rgb(0x0000ff);

/// A root made by a function, for tests.
fn Root(comptime f: fn (*Context) Widget) type {
    return struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return f(cx);
        }
    };
}

test "an overflowing row is clipped, and striped along the edge it overflows" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 100, .height = 40, .child = cx.make(ui.Row{ .children = &.{
                cx.make(ui.SizedBox{ .width = 80, .child = cx.make(ui.Decorated{ .color = red }) }),
                cx.make(ui.SizedBox{ .width = 80, .child = cx.make(ui.Decorated{ .color = blue }) }),
            } }) }) });
        }
    }.f;
    u.frame(200, 60, 0, Root(build){});
    const row = find(u.root.?, ui.Row).?;
    try testing.expectEqual(@as(f32, 60), row.overflow.right);
    try testing.expectEqual(@as(f32, 0), row.overflow.bottom);
    const img = try Image.init(u, 200, 60);
    defer img.deinit();
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(40, 20));
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(85, 20));
    // The stripes along the right edge: some yellow there, none before.
    var yellow: u32 = 0;
    for (0..40) |y| for (92..100) |x| {
        yellow += @intFromBool(isYellow(img.at(@intCast(x), @intCast(y))));
    };
    try testing.expect(yellow > 40);
    // Nothing past the row.
    for (0..60) |y| try testing.expectEqual(@as(u32, 0xff000000), img.at(120, @intCast(y)));
    for (0..200) |x| try testing.expectEqual(@as(u32, 0xff000000), img.at(@intCast(x), 50));
}

/// A widget whose layout returns nonsense.
const Nonsense = struct {
    pub fn layout(_: *const Nonsense, _: *Node, _: ui.Constraints) ui.Size {
        return .{ .w = std.math.nan(f32), .h = -std.math.inf(f32) };
    }
};

test "layouts that make no sense still lay out" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Column{
                .children = &.{
                    // A column in a column: unbounded height, where Expanded
                    // has no space to share.
                    cx.make(ui.Column{ .children = &.{
                        cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = "Expanded in unbounded space" }) }),
                        cx.make(Nonsense{}),
                    } }),
                    // A row in a row: unbounded width.
                    cx.make(ui.Row{ .children = &.{cx.make(ui.Row{ .children = &.{cx.make(ui.Text{ .text = "Row in a row" })} })} }),
                    cx.make(ui.SizedBox{ .width = -5, .height = std.math.nan(f32) }),
                    cx.make(ui.Padding{ .padding = .all(1000), .child = cx.make(ui.Text{ .text = "Padded away" }) }),
                    cx.make(ui.Center{ .child = cx.make(ui.Overlay{}) }),
                },
            });
        }
    }.f;
    u.frame(300, 200, 0, Root(build){});
    // Everything got a finite size, and the column says it overflows.
    const Check = struct {
        fn all(n: *Node) !void {
            try testing.expect(std.math.isFinite(n.size.w) and n.size.w >= 0);
            try testing.expect(std.math.isFinite(n.size.h) and n.size.h >= 0);
            for (n.children.items) |ch| try all(ch);
        }
    };
    try Check.all(u.root.?);
    try testing.expect(u.root.?.child(0).overflow.bottom > 0);
    const img = try Image.init(u, 300, 200);
    img.deinit();
}

const Counter = struct {
    pub const State = struct {
        count: u32 = 0,
        fn add(s: *State) void {
            s.count += 1;
        }
    };

    pub fn build(_: *const Counter, cx: *Context, state: *State) Widget {
        return cx.make(ui.Column{ .children = &.{
            cx.make(ui.Text{ .text = cx.fmt("Count {d}", .{state.count}) }),
            cx.make(ui.OutlinedButton{ .label = "Add", .on_press = .of(state, State.add) }),
            cx.make(ui.OutlinedButton{ .label = "Disabled" }),
        } });
    }
};

fn click(u: *ui.Ui, n: *Node) void {
    const at = n.position();
    const p: ui.Point = .{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
}

test "buttons call back, state lasts between frames, and hovering tints" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    u.frame(300, 200, 0, Counter{});
    var buttons: std.ArrayList(*Node) = .empty;
    defer buttons.deinit(testing.allocator);
    try findAll(u.root.?, ui.OutlinedButton, &buttons);
    try testing.expectEqual(@as(usize, 2), buttons.items.len);
    // Material's size, centred in the column.
    try testing.expectEqual(@as(f32, 40), buttons.items[0].size.h);

    click(u, buttons.items[0]);
    click(u, buttons.items[0]);
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
    u.frame(300, 200, 1, Counter{});
    try testing.expectEqualStrings("Count 2", find(u.root.?, ui.Text).?.widget.as(ui.Text).?.text);
    // Still over the button: tinted.
    try testing.expect(find(buttons.items[0], ui.Decorated).?.widget.as(ui.Decorated).?.color != null);

    // The disabled button does nothing, and is not tinted.
    click(u, buttons.items[1]);
    u.frame(300, 200, 2, Counter{});
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
    try testing.expect(find(buttons.items[1], ui.Decorated).?.widget.as(ui.Decorated).?.color == null);

    // Pressing, moving off and releasing is not a click.
    const b = buttons.items[0];
    const at = b.position();
    u.pointerMotion(.{ at[0] + 5, at[1] + 20 });
    u.pointerButton(.{ at[0] + 5, at[1] + 20 }, ui.btn_left, true);
    u.pointerMotion(.{ 299, 199 });
    u.pointerButton(.{ 299, 199 }, ui.btn_left, false);
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);

    // Another button going up while the left is held is not a click; the
    // left going up is.
    const over: ui.Point = .{ at[0] + 5, at[1] + 20 };
    u.pointerMotion(over);
    u.pointerButton(over, ui.btn_left, true);
    u.pointerButton(over, ui.btn_right, true);
    u.pointerButton(over, ui.btn_right, false);
    try testing.expectEqual(@as(u32, 2), u.root.?.state(Counter.State).count);
    u.pointerButton(over, ui.btn_left, false);
    try testing.expectEqual(@as(u32, 3), u.root.?.state(Counter.State).count);
}

var freed: u32 = 0;

const Keeper = struct {
    id: u32,
    pub const State = struct {
        id: u32,
        pub fn deinit(_: *State) void {
            freed += 1;
        }
    };
    pub fn initState(self: *const Keeper) State {
        return .{ .id = self.id };
    }
    pub fn build(_: *const Keeper, cx: *Context, _: *State) Widget {
        return cx.make(ui.SizedBox{ .width = 10, .height = 10 });
    }
};

const Keepers = struct {
    ids: []const u32,
    pub fn build(self: *const Keepers, cx: *Context) Widget {
        var children = cx.arena.alloc(Widget, self.ids.len) catch return cx.make(ui.Empty{});
        for (self.ids, 0..) |id, i| children[i] = cx.make(Keeper{ .id = id }).withKey(id);
        return cx.make(ui.Column{ .children = children });
    }
};

test "keys keep state when siblings come and go, and dropped state is freed" {
    const u = try ui.Ui.create(testing.allocator, null);
    freed = 0;
    u.frame(100, 100, 0, Keepers{ .ids = &.{ 1, 2, 3 } });
    u.frame(100, 100, 0, Keepers{ .ids = &.{ 3, 1 } });
    var keepers: std.ArrayList(*Node) = .empty;
    defer keepers.deinit(testing.allocator);
    try findAll(u.root.?, Keeper, &keepers);
    try testing.expectEqual(@as(u32, 3), keepers.items[0].state(Keeper.State).id);
    try testing.expectEqual(@as(u32, 1), keepers.items[1].state(Keeper.State).id);
    try testing.expectEqual(@as(u32, 1), freed);
    u.destroy();
    try testing.expectEqual(@as(u32, 3), freed);
}

test "text wraps to fit, and a word that cannot is marked" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{
                .width = 70,
                .child = cx.make(ui.Text{ .text = "Some words then Supercalifragilistic", .style = .{ .size = 14 } }),
            }) });
        }
    }.f;
    u.frame(200, 200, 0, Root(build){});
    const t = find(u.root.?, ui.Text).?;
    const line = (font.Style{ .font = &fira, .size = 14 }).lineHeight();
    try testing.expect(t.size.h > 2.5 * line);
    try testing.expect(t.overflow.right > 0);
    const img = try Image.init(u, 200, 200);
    defer img.deinit();
    // Text was drawn.
    var lit: u32 = 0;
    for (img.pixels) |px| lit += @intFromBool(channels(px)[2] > 128);
    try testing.expect(lit > 50);
}

test "an overlay's top layer takes the pointer where it has something" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const S = struct {
        var below: u32 = 0;
        var above: u32 = 0;
        fn addBelow(_: *const u8) void {
            below += 1;
        }
        fn addAbove(_: *const u8) void {
            above += 1;
        }
        const token: u8 = 0;
        fn f(cx: *Context) Widget {
            return cx.make(ui.Overlay{ .children = &.{
                cx.make(ui.Pressable{ .on_press = .of(&token, addBelow) }),
                cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 50, .height = 50, .child = cx.make(ui.Pressable{ .on_press = .of(&token, addAbove) }) }) }),
            } });
        }
    };
    u.frame(200, 200, 0, Root(S.f){});
    for ([_]ui.Point{ .{ 10, 10 }, .{ 100, 100 }, .{ 20, 40 } }) |p| {
        u.pointerMotion(p);
        u.pointerButton(p, ui.btn_left, true);
        u.pointerButton(p, ui.btn_left, false);
    }
    try testing.expectEqual(@as(u32, 2), S.above);
    try testing.expectEqual(@as(u32, 1), S.below);
}

/// Draws straight to the GPU.
const GpuView = struct {
    fn draw(_: *const GpuView, _: *anyopaque, _: ui.GpuArea) anyerror!void {}
    pub fn paint(self: *const GpuView, _: *Node, p: *ui.Painter) void {
        p.gpu(self, draw);
    }
};

test "GPU draws go between the 2D layers, in the tree's order" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Overlay{ .children = &.{
                cx.make(ui.Decorated{ .color = red }),
                cx.make(ui.Padding{ .padding = .all(10), .child = cx.make(GpuView{}) }),
                cx.make(ui.Center{ .child = cx.make(ui.Text{ .text = "Over" }) }),
            } });
        }
    }.f;
    u.frame(200, 100, 0, Root(build){});
    const segs = u.segments.items;
    try testing.expectEqual(@as(usize, 3), segs.len);
    try testing.expect(segs[0] == .canvas and segs[1] == .gpu and segs[2] == .canvas);
    try testing.expectEqual(gfx.Viewport{ .x = 10, .y = 10, .width = 180, .height = 80 }, segs[1].gpu.area.viewport);
    try testing.expect(segs[1].gpu.area.scissor == null);
}

test "rows and columns align and space their children" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Column{ .children = &.{
                cx.make(ui.Row{ .main_axis_alignment = .center, .spacing = 10, .children = &.{
                    cx.make(ui.SizedBox{ .width = 20, .height = 10 }),
                    cx.make(ui.SizedBox{ .width = 30, .height = 20 }),
                } }),
                cx.make(ui.Row{ .main_axis_alignment = .space_between, .cross_axis_alignment = .end, .children = &.{
                    cx.make(ui.SizedBox{ .width = 20, .height = 10 }),
                    cx.make(ui.Expanded{ .child = cx.make(ui.SizedBox{ .height = 5 }) }),
                    cx.make(ui.SizedBox{ .width = 30, .height = 20 }),
                } }),
            } });
        }
    }.f;
    u.frame(200, 100, 0, Root(build){});
    const col = u.root.?.child(0);
    const r1 = col.child(0);
    // 20 + 10 + 30 = 60 wide, centred in 200; the small box centred
    // across.
    try testing.expectEqual(ui.Point{ 70, 5 }, r1.child(0).offset);
    try testing.expectEqual(ui.Point{ 100, 0 }, r1.child(1).offset);
    try testing.expectEqual(@as(f32, 20), r1.size.h);
    const r2 = col.child(1);
    try testing.expectEqual(@as(f32, 150), r2.child(1).size.w);
    try testing.expectEqual(ui.Point{ 170, 0 }, r2.child(2).offset);
    try testing.expectEqual(ui.Point{ 20, 15 }, r2.child(1).offset);
}

const Choice = enum { a, b, c };

const Controls = struct {
    pub const State = struct {
        checked: bool = false,
        on: bool = false,
        choice: Choice = .a,
        fn setChecked(s: *State, v: bool) void {
            s.checked = v;
        }
        fn setOn(s: *State, v: bool) void {
            s.on = v;
        }
        fn choose(s: *State, v: Choice) void {
            s.choice = v;
        }
    };

    pub fn build(_: *const Controls, cx: *Context, state: *State) Widget {
        return cx.make(ui.Column{ .cross_axis_alignment = .start, .children = &.{
            cx.make(ui.Checkbox{ .value = state.checked, .on_changed = .of(state, State.setChecked), .label = "Check" }),
            cx.make(ui.Switch{ .value = state.on, .on_changed = .of(state, State.setOn), .label = "Switch" }),
            cx.make(ui.Radio(Choice){ .value = .a, .group_value = state.choice, .on_changed = .of(state, State.choose), .label = "A" }),
            cx.make(ui.Radio(Choice){ .value = .b, .group_value = state.choice, .on_changed = .of(state, State.choose), .label = "B" }),
            cx.make(ui.Radio(Choice){ .value = .c, .group_value = state.choice, .label = "C (disabled)" }),
            cx.make(ui.Checkbox{ .value = true }),
        } });
    }
};

fn clickAt(u: *ui.Ui, p: ui.Point) void {
    u.pointerMotion(p);
    u.pointerButton(p, ui.btn_left, true);
    u.pointerButton(p, ui.btn_left, false);
}

test "checkboxes, switches and radio buttons report changes, and their labels press them" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    u.frame(400, 400, 0, Controls{});
    var items: std.ArrayList(*Node) = .empty;
    defer items.deinit(testing.allocator);
    try findAll(u.root.?, ui.Pressable, &items);
    try testing.expectEqual(@as(usize, 6), items.items.len);
    for (items.items[0..5]) |n| try testing.expectEqual(@as(f32, 40), n.size.h);
    const st = u.root.?.state(Controls.State);

    // The box itself, then the label.
    click(u, find(items.items[0], ui.checkbox.CheckboxMark).?);
    try testing.expect(st.checked);
    u.frame(400, 400, 1, Controls{});
    const label = find(items.items[0], ui.Text).?;
    click(u, label);
    try testing.expect(!st.checked);
    u.frame(400, 400, 2, Controls{});

    // The switch slides over, asking for frames until it is there.
    click(u, items.items[1]);
    try testing.expect(st.on);
    u.frame(400, 400, 3, Controls{});
    try testing.expect(u.needs_frame);
    u.frame(400, 400, 3 + ui.Switch.travel_ns / 2, Controls{});
    const mark = find(items.items[1], ui.@"switch".SwitchMark).?.widget.as(ui.@"switch".SwitchMark).?;
    try testing.expect(mark.position > 0.3 and mark.position < 0.7);
    u.frame(400, 400, 3 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expectEqual(@as(f32, 1), find(items.items[1], ui.@"switch".SwitchMark).?.widget.as(ui.@"switch".SwitchMark).?.position);
    u.frame(400, 400, 4 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expect(!u.needs_frame);

    // Radio buttons: choosing B selects it; C is disabled.
    click(u, items.items[3]);
    try testing.expectEqual(Choice.b, st.choice);
    click(u, items.items[4]);
    try testing.expectEqual(Choice.b, st.choice);
    u.frame(400, 400, 5 + ui.Switch.travel_ns * 2, Controls{});
    try testing.expect(!find(items.items[2], ui.radio.RadioMark).?.widget.as(ui.radio.RadioMark).?.selected);
    try testing.expect(find(items.items[3], ui.radio.RadioMark).?.widget.as(ui.radio.RadioMark).?.selected);

    // A disabled checkbox ignores clicks (and draws without failing).
    click(u, items.items[5]);
    const img = try Image.init(u, 400, 400);
    img.deinit();
}

const Label = struct {
    text: []const u8,
    pub fn build(self: *const Label, cx: *Context) Widget {
        return cx.make(ui.Column{ .cross_axis_alignment = .start, .children = &.{
            cx.make(ui.Text{ .text = "Static title" }),
            cx.make(ui.Text{ .text = self.text }),
            cx.make(ui.OutlinedButton{ .label = "Button", .on_press = .of(&dummy_count, addDummy) }),
        } });
    }
};

var dummy_count: u32 = 0;
fn addDummy(c: *u32) void {
    c.* += 1;
}

fn within(r: ui.Rect, outer: ui.Rect) bool {
    return r.x >= outer.x and r.y >= outer.y and r.x + r.w <= outer.x + outer.w and r.y + r.h <= outer.y + outer.h;
}

test "only what changed is damaged" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    u.frame(300, 200, 0, Label{ .text = "One" });
    // The first frame: everything.
    try testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .w = 300, .h = 200 }, u.damaged()[0]);
    // The same again: nothing.
    u.frame(300, 200, 1, Label{ .text = "One" });
    try testing.expect(!u.changed());
    try testing.expect(u.repaint(1).isEmpty());

    // New text: only around it.
    u.frame(300, 200, 2, Label{ .text = "Two" });
    try testing.expect(u.changed());
    var texts: std.ArrayList(*Node) = .empty;
    defer texts.deinit(testing.allocator);
    try findAll(u.root.?, ui.Text, &texts);
    const second = texts.items[1];
    const at = second.position();
    // Glyphs can reach an em around the text's box.
    const near: ui.Rect = .{ .x = at[0] - 20, .y = at[1] - 30, .w = second.size.w + 60, .h = second.size.h + 50 };
    for (u.damaged()) |r| try testing.expect(within(r, near));
    const first = texts.items[0];
    for (u.damaged()) |r| try testing.expect(r.y > first.position()[1]);

    // Hovering the button: only the button.
    const button = find(u.root.?, ui.OutlinedButton).?;
    const b = button.position();
    u.pointerMotion(.{ b[0] + 10, b[1] + 10 });
    u.frame(300, 200, 3, Label{ .text = "Two" });
    const box: ui.Rect = .{ .x = b[0] - 2, .y = b[1] - 2, .w = button.size.w + 4, .h = button.size.h + 4 };
    try testing.expect(u.changed());
    for (u.damaged()) |r| try testing.expect(within(r, box));
    // The buffer from two frames ago also needs the text's change.
    try testing.expect(u.repaint(2).len >= 1);
    var covers_text = false;
    for (u.repaint(2).slice()) |r| covers_text = covers_text or r.intersects(.{ .x = at[0], .y = at[1], .w = second.size.w, .h = second.size.h });
    try testing.expect(covers_text);
}

const Maybe = struct {
    show: bool,
    pub fn build(self: *const Maybe, cx: *Context) Widget {
        return cx.make(ui.Column{ .children = if (self.show) &.{
            cx.make(ui.SizedBox{ .width = 50, .height = 20, .child = cx.make(ui.Decorated{ .color = red }) }),
        } else &.{} });
    }
};

test "a removed widget damages where it was" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    u.frame(200, 100, 0, Maybe{ .show = true });
    u.frame(200, 100, 1, Maybe{ .show = true });
    try testing.expect(!u.changed());
    u.frame(200, 100, 2, Maybe{ .show = false });
    try testing.expect(u.changed());
    for (u.damaged()) |r| try testing.expect(within(r, .{ .x = 74, .y = 0, .w = 52, .h = 22 }));
}

const Keyed = struct {
    key: ?u64,
    fn draw(_: *const Keyed, _: *anyopaque, _: ui.GpuArea) anyerror!void {}
    pub fn paint(self: *const Keyed, _: *Node, p: *ui.Painter) void {
        p.gpuWith(.{ .key = self.key, .bounds = .{ .x = 10, .y = 10, .w = 20, .h = 20 } }, self, draw);
    }
};

test "GPU draws are damaged every frame, unless their key stays the same" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    u.frame(100, 100, 0, Keyed{ .key = null });
    u.frame(100, 100, 1, Keyed{ .key = null });
    try testing.expectEqual(ui.Rect{ .x = 10, .y = 10, .w = 20, .h = 20 }, u.damaged()[0]);
    u.frame(100, 100, 2, Keyed{ .key = 7 });
    u.frame(100, 100, 3, Keyed{ .key = 7 });
    try testing.expect(!u.changed());
    u.frame(100, 100, 4, Keyed{ .key = 8 });
    try testing.expectEqual(ui.Rect{ .x = 10, .y = 10, .w = 20, .h = 20 }, u.damaged()[0]);
}

test "a grid puts as many cells in a row as fit" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            var cells: [7]Widget = undefined;
            for (&cells) |*c| c.* = cx.make(ui.Decorated{ .color = red });
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 250, .child = cx.make(ui.Grid{ .cell = .{ .w = 60, .h = 40 }, .spacing = 10, .children = &cells }) }) });
        }
    }.f;
    u.frame(400, 300, 0, Root(build){});
    var cells: std.ArrayList(*Node) = .empty;
    defer cells.deinit(testing.allocator);
    try findAll(u.root.?, ui.Decorated, &cells);
    // 250 wide: three 60-wide cells with 10 between (four would need 270).
    try testing.expectEqual(@as(usize, 7), cells.items.len);
    try testing.expectEqual(ui.Point{ 140, 0 }, cells.items[2].offset);
    try testing.expectEqual(ui.Point{ 0, 50 }, cells.items[3].offset);
    try testing.expectEqual(ui.Point{ 0, 100 }, cells.items[6].offset);
    try testing.expectEqual(ui.Size{ .w = 60, .h = 40 }, cells.items[6].size);
    const grid = find(u.root.?, ui.Grid).?;
    try testing.expectEqual(ui.Size{ .w = 250, .h = 140 }, grid.size);
}

const LazyItems = struct {
    pressed: ?usize = null,
    made: usize = 0,

    const Press = struct {
        items: *LazyItems,
        i: usize,
        fn f(p: *const Press) void {
            p.items.pressed = p.i;
        }
    };

    fn item(items: *LazyItems, cx: *Context, i: usize) Widget {
        items.made += 1;
        const p = cx.arena.create(Press) catch unreachable;
        p.* = .{ .items = items, .i = i };
        return cx.make(ui.Pressable{ .on_press = .of(p, Press.f), .child = cx.make(ui.Decorated{ .color = if (i % 2 == 0) red else blue }) });
    }
};

const LazyApp = struct {
    items: *LazyItems,
    in_scroll_view: bool = true,
    pub fn build(self: *const @This(), cx: *Context) Widget {
        const grid = cx.make(ui.LazyGrid{ .count = 100, .cell = .{ .w = 50, .h = 40 }, .spacing = 10, .item = .of(self.items, LazyItems.item) });
        return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = if (self.in_scroll_view) cx.make(ui.ScrollView{ .child = grid }) else grid }) });
    }
};

test "a lazy grid makes only the rows that show, as it scrolls" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    var items: LazyItems = .{};
    u.frame(400, 400, 0, LazyApp{ .items = &items });
    const view = find(u.root.?, ui.ScrollView).?;
    const grid = view.child(0);
    // 188 wide beside the bar: three columns; 34 rows of 50.
    try testing.expectEqual(ui.Size{ .w = 188, .h = 34 * 50 - 10 }, grid.size);
    // Rows 0 to 5 show (300 of 50 each), and one more is made.
    try testing.expectEqual(@as(usize, 21), grid.childCount());
    try testing.expectEqual(ui.Point{ 60, 50 }, grid.child(4).offset);
    try testing.expectEqual(ui.Size{ .w = 50, .h = 40 }, grid.child(4).size);
    // The next frame makes the same ones, with the rest of the tree.
    items.made = 0;
    u.frame(400, 400, 1, LazyApp{ .items = &items });
    try testing.expectEqual(@as(usize, 21), items.made);

    // Scrolled to 1000: rows 20 to 25 show; 19 to 26 are made.
    _ = view.state(ui.ScrollView.State).scrollTo(1000);
    u.frame(400, 400, 2, LazyApp{ .items = &items });
    try testing.expectEqual(@as(usize, 24), grid.childCount());
    try testing.expectEqual(@as(?u64, 57), grid.child(0).widget.key);
    try testing.expectEqual(ui.Point{ 0, 19 * 50 }, grid.child(0).offset);
    try testing.expect(!grid.child(0).paint.valid);
    try testing.expect(grid.child(3).paint.valid);
    // Pressing one presses the right item.
    u.pointerMotion(.{ 70, 15 });
    u.pointerButton(.{ 70, 15 }, ui.btn_left, true);
    u.pointerButton(.{ 70, 15 }, ui.btn_left, false);
    try testing.expectEqual(@as(?usize, 61), items.pressed);

    // Not in a scroll view: all of it shows.
    u.frame(400, 400, 3, LazyApp{ .items = &items, .in_scroll_view = false });
    try testing.expectEqual(@as(usize, 100), find(u.root.?, ui.LazyGrid).?.childCount());
}

const LazyList = struct {
    items: *LazyItems,
    reveal: ?usize = null,
    pub fn build(self: *const @This(), cx: *Context) Widget {
        const list = cx.make(ui.LazyGrid{ .count = 100, .cell = .{ .w = std.math.inf(f32), .h = 30 }, .item = .of(self.items, LazyListItems.row), .keep = self.reveal });
        return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
            .reveal = if (self.reveal) |r| 1000 + @as(u64, r) else null,
            .child = list,
        }) }) });
    }
};

const LazyListItems = struct {
    /// Item `i`, keyed 1000 + i for the scroll view to reveal.
    fn row(items: *LazyItems, cx: *Context, i: usize) Widget {
        return LazyItems.item(items, cx, i).withKey(1000 + @as(u64, i));
    }
};

test "a lazy list's items are as wide as it, and one far down can be revealed" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    var items: LazyItems = .{};
    u.frame(400, 400, 0, LazyList{ .items = &items });
    const view = find(u.root.?, ui.ScrollView).?;
    const list = view.child(0);
    // One column, each row as wide as the list (beside the bar): ten rows
    // show, and one more is made.
    try testing.expectEqual(@as(usize, 11), list.childCount());
    try testing.expectEqual(ui.Size{ .w = 188, .h = 30 }, list.child(3).size);
    try testing.expectEqual(ui.Point{ 0, 90 }, list.child(3).offset);
    try testing.expectEqual(ui.Size{ .w = 188, .h = 3000 }, list.size);

    // Revealing row 80, which is not made: it is kept, so the scroll view
    // finds it and scrolls to it, and the rows around it are made.
    u.frame(400, 400, 1, LazyList{ .items = &items, .reveal = 80 });
    const st = view.state(ui.ScrollView.State);
    try testing.expectEqual(@as(f32, 81 * 30 - 300), st.offset);
    var shows = false;
    for (list.children.items) |ch| if (ch.widget.key == 1000 + 80) {
        try testing.expectEqual(ui.Point{ 0, 80 * 30 }, ch.offset);
        shows = ch.paint.valid;
    };
    try testing.expect(shows);
    // Scrolled back to the top, row 80 is still made (and kept last).
    _ = st.scrollTo(0);
    u.frame(400, 400, 2, LazyList{ .items = &items, .reveal = 80 });
    try testing.expectEqual(@as(usize, 12), list.childCount());
    try testing.expectEqual(@as(?u64, 1000 + 80), list.child(11).widget.key);
    try testing.expectEqual(ui.Point{ 0, 80 * 30 }, list.child(11).offset);
}

test "icons are drawn from the icon font, in their box" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Row{ .main_axis_size = .min, .children = &.{
                cx.make(ui.Icon{ .icon = .folder, .size = 48, .color = red }),
                cx.make(ui.OutlinedButton{ .label = "Up", .icon = .arrow_upward }),
                cx.make(ui.OutlinedButton{ .icon = .close }),
                cx.make(ui.OutlinedButton{ .label = "More", .trailing_icon = .expand_more }),
            } }) });
        }
    }.f;
    u.frame(400, 100, 0, Root(build){});
    const icon = find(u.root.?, ui.Icon).?;
    try testing.expectEqual(ui.Size{ .w = 48, .h = 48 }, icon.size);
    var img = try Image.init(u, 400, 100);
    defer img.deinit();
    // The folder fills the middle of its box, and nothing is below it.
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(24, 28));
    try testing.expectEqual(@as(u32, 0xff000000), img.at(24, 60));
    // A button's icon goes before its label (or after, for trailing_icon),
    // in the label's colour; one with only an icon is round.
    var buttons: std.ArrayList(*Node) = .empty;
    defer buttons.deinit(testing.allocator);
    try findAll(u.root.?, ui.OutlinedButton, &buttons);
    const with_label = buttons.items[0];
    const glyph = find(with_label, ui.Icon).?;
    const label = find(with_label, ui.Text).?;
    try testing.expect(glyph.position()[0] < label.position()[0]);
    try testing.expectEqual(label.widget.as(ui.Text).?.style.color.?, glyph.widget.as(ui.Icon).?.color.?);
    try testing.expectEqual(@as(f32, 40), buttons.items[1].size.h);
    try testing.expect(find(buttons.items[1], ui.Text) == null);
    const with_trailing = buttons.items[2];
    try testing.expect(find(with_trailing, ui.Text).?.position()[0] < find(with_trailing, ui.Icon).?.position()[0]);
}

test "images fit the space given, keeping their shape, and text can have its own font" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    const pixels: [8]u32 = .{ 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000, 0xff0000ff, 0xff0000ff, 0xff0000ff, 0xff0000ff };
    const pic = gfx.Image.init(&pixels, 4, 2);
    const App = struct {
        pic: *const gfx.Image,
        width: f32,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = self.width, .height = 100, .child = cx.make(ui.Center{ .child = cx.make(ui.Image{ .image = self.pic }) }) }) });
        }
    };
    // Smaller than the space: as big as it is.
    u.frame(300, 200, 0, App{ .pic = &pic, .width = 300 });
    try testing.expectEqual(ui.Size{ .w = 4, .h = 2 }, find(u.root.?, ui.Image).?.size);
    // Bigger: made to fit, keeping its shape (and drawn, top red, bottom blue).
    const big = gfx.Image.init(&(@as([200 * 50]u32, @splat(0xffff0000)) ++ @as([200 * 50]u32, @splat(0xff0000ff))), 200, 100);
    u.frame(300, 200, 1, App{ .pic = &big, .width = 100 });
    const node = find(u.root.?, ui.Image).?;
    try testing.expectEqual(ui.Size{ .w = 100, .h = 50 }, node.size);
    try testing.expectEqual(ui.Point{ 0, 25 }, node.offset);
    var img = try Image.init(u, 300, 200);
    defer img.deinit();
    try testing.expectEqual(@as(u32, 0xffff0000), img.at(50, 30));
    try testing.expectEqual(@as(u32, 0xff0000ff), img.at(50, 70));
    try testing.expectEqual(@as(u32, 0xff000000), img.at(50, 80));

    // Text in another font: the icon font draws "folder" as its icon.
    const icon_font = try font.Font.init(ui.icons.font_data);
    const Shown = struct {
        f: *const font.Font,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Text{ .text = "\u{e2c7}", .style = .{ .size = 40, .font = self.f } }) });
        }
    };
    u.frame(300, 200, 2, Shown{ .f = &icon_font });
    const text = find(u.root.?, ui.Text).?;
    try testing.expectApproxEqAbs(@as(f32, 40), text.size.w, 0.5);
}

test "a scroll view scrolls with the wheel and its bar, and paints only what shows" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const build = struct {
        fn f(cx: *Context) Widget {
            var rows: [20]Widget = undefined;
            for (&rows, 0..) |*r, i| r.* = cx.make(ui.SizedBox{ .height = 50, .child = cx.make(ui.Decorated{ .color = if (i % 2 == 0) red else blue }) });
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &rows }),
            }) }) });
        }
    }.f;
    u.frame(400, 400, 0, Root(build){});
    const view = find(u.root.?, ui.ScrollView).?;
    const column = view.child(0);
    const st = view.state(ui.ScrollView.State);
    // Too tall: the bar takes its width, and nothing counts as overflow.
    try testing.expectEqual(ui.Size{ .w = 200, .h = 300 }, view.size);
    try testing.expectEqual(@as(f32, 188), column.size.w);
    try testing.expectEqual(@as(f32, 1000), st.content);
    try testing.expect(!view.overflow.any());
    // Rows below the view are not painted.
    try testing.expect(column.child(5).paint.valid);
    try testing.expect(!column.child(6).paint.valid);

    // The wheel: a notch (15 pixels) scrolls three times that.
    u.pointerScroll(.{ 100, 100 }, 0, 15);
    try testing.expect(u.needs_frame);
    u.frame(400, 400, 1, Root(build){});
    try testing.expectEqual(@as(f32, 45), st.offset);
    try testing.expectEqual(ui.Point{ 0, -45 }, column.offset);
    try testing.expect(u.changed());
    // No further than the end, and no further back than the top.
    u.pointerScroll(.{ 100, 100 }, 0, 10000);
    u.frame(400, 400, 2, Root(build){});
    try testing.expectEqual(@as(f32, 700), st.offset);
    try testing.expect(!column.child(0).paint.valid);
    try testing.expect(column.child(19).paint.valid);
    u.pointerScroll(.{ 100, 100 }, 0, -10000);
    u.frame(400, 400, 3, Root(build){});
    try testing.expectEqual(@as(f32, 0), st.offset);
    // At the top already, the wheel up is not taken.
    u.needs_frame = false;
    u.pointerScroll(.{ 100, 100 }, 0, -15);
    try testing.expect(!u.needs_frame);

    // Pressing the bar below the thumb (90 tall: 300 of 1000) jumps there,
    // centred on the pointer; dragging moves it.
    u.pointerMotion(.{ 194, 255 });
    u.pointerButton(.{ 194, 255 }, ui.btn_left, true);
    // The thumb's top at 210 of the 210 it can travel: the end.
    try testing.expectEqual(@as(f32, 700), st.offset);
    u.pointerMotion(.{ 194, 150 });
    try testing.expectEqual(@as(f32, 350), st.offset);
    u.pointerButton(.{ 194, 150 }, ui.btn_left, false);
    try testing.expect(st.grab == null);
    u.frame(400, 400, 4, Root(build){});
    try testing.expectEqual(ui.Point{ 0, -350 }, column.offset);

    // Content that fits needs no bar, and does not scroll.
    const short = struct {
        fn f(cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .child = cx.make(ui.SizedBox{ .height = 100, .child = cx.make(ui.Decorated{ .color = red }) }),
            }) }) });
        }
    }.f;
    u.frame(400, 400, 5, Root(short){});
    const v2 = find(u.root.?, ui.ScrollView).?;
    try testing.expectEqual(@as(f32, 200), v2.child(0).size.w);
    try testing.expectEqual(@as(f32, 0), v2.state(ui.ScrollView.State).offset);
}

test "a scroll view scrolls to the widget it is told to reveal, once" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const Reveal = struct {
        target: ?u64,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            var rows: [20]Widget = undefined;
            for (&rows, 0..) |*r, i| r.* = cx.make(ui.SizedBox{ .height = 50, .child = cx.make(ui.Decorated{ .color = red }) }).withKey(i);
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .reveal = self.target,
                .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &rows }),
            }) }) });
        }
    };
    u.frame(400, 400, 0, Reveal{ .target = 12 });
    const st = find(u.root.?, ui.ScrollView).?.state(ui.ScrollView.State);
    // Row 12 (600 to 650) at the bottom of the view.
    try testing.expectEqual(@as(f32, 350), st.offset);
    // Scrolled away, it stays away until another is revealed.
    _ = st.scrollTo(0);
    u.frame(400, 400, 1, Reveal{ .target = 12 });
    try testing.expectEqual(@as(f32, 0), st.offset);
    u.frame(400, 400, 2, Reveal{ .target = 19 });
    try testing.expectEqual(@as(f32, 700), st.offset);
    // Above the view: at its top.
    u.frame(400, 400, 3, Reveal{ .target = 2 });
    try testing.expectEqual(@as(f32, 100), st.offset);
}

test "a tap presses a button; a touch that moves over a list scrolls it, pressing nothing" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const Count = struct {
        var presses: u32 = 0;
        fn press(_: *u8) void {
            presses += 1;
        }
    };
    Count.presses = 0;
    var dummy: u8 = 0;
    const App = struct {
        dummy: *u8,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            var rows: [20]Widget = undefined;
            for (&rows) |*r| r.* = cx.make(ui.Pressable{ .on_press = .of(self.dummy, Count.press), .child = cx.make(ui.SizedBox{ .height = 50 }) });
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 200, .height = 300, .child = cx.make(ui.ScrollView{
                .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &rows }),
            }) }) });
        }
    };
    u.frame(400, 400, 0, App{ .dummy = &dummy });
    const st = find(u.root.?, ui.ScrollView).?.state(ui.ScrollView.State);
    // A tap: a press.
    u.touchDown(1, .{ 100, 100 });
    u.touchUp(1);
    try testing.expectEqual(@as(u32, 1), Count.presses);
    // A touch that wobbles less than the slop is still a tap.
    u.touchDown(2, .{ 100, 100 });
    u.touchMotion(2, .{ 103, 104 });
    u.touchUp(2);
    try testing.expectEqual(@as(u32, 2), Count.presses);
    // Up the list by 60: the list follows it, by as much, and the row it
    // went down on is not pressed.
    u.frame(400, 400, 1, App{ .dummy = &dummy });
    u.touchDown(3, .{ 100, 200 });
    u.touchMotion(3, .{ 100, 170 });
    u.touchMotion(3, .{ 100, 140 });
    u.touchUp(3);
    try testing.expectEqual(@as(f32, 60), st.offset);
    try testing.expectEqual(@as(u32, 2), Count.presses);
    // Nothing is hovered once it is up.
    try testing.expectEqual(@as(usize, 0), u.hovered.items.len);
    // A second finger while one is down is ignored; a cancelled touch
    // presses nothing.
    u.touchDown(4, .{ 100, 100 });
    u.touchDown(5, .{ 100, 150 });
    u.touchUp(5);
    u.touchCancel();
    try testing.expectEqual(@as(u32, 2), Count.presses);
    try testing.expect(u.captured == null);
}

const DragTest = struct {
    dropped: *?usize,
    clicked: *u32,

    fn drop(self: *const DragTest, data: usize) void {
        self.dropped.* = data;
    }

    fn pressed(self: *const DragTest) void {
        self.clicked.* += 1;
    }

    fn odd(_: ?*const anyopaque, data: usize) bool {
        return data % 2 == 1;
    }

    pub fn build(self: *const DragTest, cx: *Context) Widget {
        const box = cx.make(ui.SizedBox{ .width = 80, .height = 80 });
        return cx.make(ui.Row{ .children = &.{
            cx.make(ui.Draggable{ .data = 7, .label = "seven", .on_press = .of(self, pressed), .child = box }),
            cx.make(ui.Draggable{ .data = 8, .label = "eight", .child = box }),
            cx.make(ui.DropTarget{ .on_drop = .of(self, drop), .accepts = odd, .child = box }),
        } });
    }
};

test "dragging onto a target that takes it drops it there; a click is still a click" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();
    var dropped: ?usize = null;
    var clicked: u32 = 0;
    const w: DragTest = .{ .dropped = &dropped, .clicked = &clicked };
    u.frame(300, 100, 0, w);
    // Pressed and let go without moving: clicked.
    u.pointerMotion(.{ 40, 40 });
    u.pointerButton(.{ 40, 40 }, ui.btn_left, true);
    u.pointerMotion(.{ 43, 42 });
    u.pointerButton(.{ 43, 42 }, ui.btn_left, false);
    try testing.expectEqual(@as(u32, 1), clicked);
    try testing.expect(u.drag == null);

    // Dragged to the target: the chip follows, the target lights up, and
    // it gets 7 (no click).
    u.pointerButton(.{ 40, 40 }, ui.btn_left, true);
    u.pointerMotion(.{ 120, 40 });
    try testing.expectEqualStrings("seven", u.drag.?.label);
    try testing.expect(u.drag.?.target == null);
    u.pointerMotion(.{ 200, 40 });
    try testing.expect(u.drag.?.target.?.widget.is(ui.DropTarget));
    u.frame(300, 100, 1, w);
    try testing.expect(u.drag_root != null);
    try testing.expectEqualStrings("seven", find(u.drag_root.?, ui.Text).?.widget.as(ui.Text).?.text);
    u.pointerButton(.{ 200, 40 }, ui.btn_left, false);
    try testing.expectEqual(@as(?usize, 7), dropped);
    try testing.expectEqual(@as(u32, 1), clicked);
    try testing.expect(u.drag == null);
    u.frame(300, 100, 2, w);
    try testing.expect(u.drag_root == null);

    // 8 is not taken: no target, nothing dropped.
    dropped = null;
    u.pointerMotion(.{ 120, 40 });
    u.pointerButton(.{ 120, 40 }, ui.btn_left, true);
    u.pointerMotion(.{ 200, 40 });
    try testing.expect(u.drag.?.target == null);
    u.pointerButton(.{ 200, 40 }, ui.btn_left, false);
    try testing.expect(dropped == null);

    // If the pointer leaves the window during a press or drag, it is cancelled
    // cleanly so later clicks still work.
    u.pointerMotion(.{ 40, 40 });
    u.pointerButton(.{ 40, 40 }, ui.btn_left, true);
    try testing.expect(u.captured != null);
    u.pointerLeave();
    try testing.expect(u.captured == null);
    try testing.expectEqual(@as(u32, 1), clicked);
    clickAt(u, .{ 40, 40 });
    try testing.expectEqual(@as(u32, 2), clicked);
}

test "sliders, dropdowns, dialogs, tooltips, chips, badges, tabs and rails" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();

    const Mode = enum { one, two, three };
    const Gallery = struct {
        pub const State = struct {
            slider_val: f32 = 0.25,
            discrete_val: f32 = 20,
            mode: Mode = .one,
            chip_selected: bool = false,
            chip_removed: bool = false,
            tab: usize = 0,
            rail: usize = 0,
            dialog_open: bool = false,
            confirmed: u32 = 0,
            dismissed: u32 = 0,
            snack_actions: u32 = 0,

            fn setSlider(s: *State, v: f32) void {
                s.slider_val = v;
            }
            fn setDiscrete(s: *State, v: f32) void {
                s.discrete_val = v;
            }
            fn setMode(s: *State, m: Mode) void {
                s.mode = m;
            }
            fn toggleChip(s: *State) void {
                s.chip_selected = !s.chip_selected;
            }
            fn removeChip(s: *State) void {
                s.chip_removed = true;
            }
            fn setTab(s: *State, idx: usize) void {
                s.tab = idx;
            }
            fn setRail(s: *State, idx: usize) void {
                s.rail = idx;
            }
            fn confirm(s: *State) void {
                s.confirmed += 1;
                s.dialog_open = false;
            }
            fn dismiss(s: *State) void {
                s.dismissed += 1;
                s.dialog_open = false;
            }
            fn snackAct(s: *State) void {
                s.snack_actions += 1;
            }
        };

        pub fn build(_: *const @This(), cx: *Context, state: *State) Widget {
            const opts = [_]ui.Select(Mode).Option{
                .{ .value = .one, .label = "One" },
                .{ .value = .two, .label = "Two" },
                .{ .value = .three, .label = "Three" },
            };
            const rail_items = [_]ui.NavigationRail.Item{
                .{ .label = "First", .icon = .folder },
                .{ .label = "Second", .icon = .settings, .badge = 4 },
            };
            const tabs = [_]ui.Tab{
                .{ .label = "Alpha", .icon = .apps },
                .{ .label = "Beta", .badge = 2 },
            };
            const main_col = cx.make(ui.Row{
                .children = &.{
                    cx.make(ui.NavigationRail{
                        .items = &rail_items,
                        .selected = state.rail,
                        .on_select = .of(state, State.setRail),
                        .extended = false,
                    }),
                    cx.make(ui.Divider{ .axis = .vertical }),
                    cx.make(ui.Expanded{
                        .child = cx.make(ui.Column{
                            .cross_axis_alignment = .stretch,
                            .spacing = 8,
                            .children = &.{
                                cx.make(ui.TabBar{
                                    .tabs = &tabs,
                                    .selected = state.tab,
                                    .on_select = .of(state, State.setTab),
                                }),
                                cx.make(ui.Slider{
                                    .value = state.slider_val,
                                    .on_changed = .of(state, State.setSlider),
                                }),
                                cx.make(ui.Slider{
                                    .value = state.discrete_val,
                                    .min = 0,
                                    .max = 100,
                                    .divisions = 4,
                                    .on_changed = .of(state, State.setDiscrete),
                                }),
                                cx.make(ui.ProgressBar{ .value = state.slider_val }),
                                cx.make(ui.Select(Mode){
                                    .options = &opts,
                                    .value = state.mode,
                                    .on_changed = .of(state, State.setMode),
                                }),
                                cx.make(ui.Row{
                                    .spacing = 8,
                                    .children = &.{
                                        cx.make(ui.FilledButton{ .label = "Filled", .on_press = .of(state, State.toggleChip) }),
                                        cx.make(ui.TonalButton{ .label = "Tonal", .on_press = .of(state, State.toggleChip) }),
                                        cx.make(ui.TextButton{ .label = "Text", .on_press = .of(state, State.toggleChip) }),
                                        cx.make(ui.Tooltip{
                                            .text = "Settings tip",
                                            .child = cx.make(ui.IconButton{ .icon = .settings, .variant = .tonal, .on_press = .of(state, State.toggleChip) }),
                                        }),
                                        cx.make(ui.Chip{
                                            .label = "Tag",
                                            .selected = state.chip_selected,
                                            .on_press = .of(state, State.toggleChip),
                                            .on_remove = .of(state, State.removeChip),
                                        }),
                                        cx.make(ui.Badge{ .count = 150, .child = cx.make(ui.Icon{ .icon = .wifi }) }),
                                    },
                                }),
                                cx.make(ui.Card{
                                    .variant = .outlined,
                                    .child = cx.make(ui.ListItem{
                                        .headline = "Row title",
                                        .supporting_text = "Details",
                                        .leading_icon = .folder,
                                        .trailing_icon = .chevron_right,
                                    }),
                                }),
                            },
                        }),
                    }),
                },
            });
            const with_snack = cx.make(ui.Snackbar{
                .message = "Saved",
                .action_label = "Undo",
                .on_action = .of(state, State.snackAct),
                .child = main_col,
            });
            return cx.make(ui.Dialog{
                .open = state.dialog_open,
                .title = "Confirm?",
                .description = "Are you sure?",
                .dismiss_label = "No",
                .on_dismiss = .of(state, State.dismiss),
                .confirm_label = "Yes",
                .on_confirm = .of(state, State.confirm),
                .child = with_snack,
            });
        }
    };

    u.frame(900, 700, 0, Gallery{});
    const st = u.root.?.state(Gallery.State);

    // Drag continuous slider to 75% and discrete slider (4 divisions) near 70% -> snaps to 75.
    var sliders: std.ArrayList(*Node) = .empty;
    defer sliders.deinit(testing.allocator);
    try findAll(u.root.?, ui.Slider, &sliders);
    try testing.expectEqual(@as(usize, 2), sliders.items.len);
    {
        const s0 = sliders.items[0];
        const pos = s0.position();
        const x0 = pos[0] + ui.Slider.halo_radius;
        const x1 = pos[0] + s0.size.w - ui.Slider.halo_radius;
        u.pointerMotion(.{ x0 + (x1 - x0) * 0.5, pos[1] + 10 });
        u.pointerButton(.{ x0 + (x1 - x0) * 0.5, pos[1] + 10 }, ui.btn_left, true);
        u.pointerMotion(.{ x0 + (x1 - x0) * 0.75, pos[1] + 10 });
        u.pointerButton(.{ x0 + (x1 - x0) * 0.75, pos[1] + 10 }, ui.btn_left, false);
        try testing.expectApproxEqAbs(@as(f32, 0.75), st.slider_val, 0.01);

        const s1 = sliders.items[1];
        const p1 = s1.position();
        const d0 = p1[0] + ui.Slider.halo_radius;
        const d1 = p1[0] + s1.size.w - ui.Slider.halo_radius;
        clickAt(u, .{ d0 + (d1 - d0) * 0.70, p1[1] + 10 });
        try testing.expectEqual(@as(f32, 75), st.discrete_val);
    }

    // Hovering the Tooltip shows tooltip_root on the next frame.
    const tt_node = find(u.root.?, ui.Tooltip).?;
    const tt_pos = tt_node.position();
    u.pointerMotion(.{ tt_pos[0] + 10, tt_pos[1] + 10 });
    u.frame(900, 700, 1, Gallery{});
    try testing.expect(u.tooltip_root != null);
    try testing.expectEqualStrings("Settings tip", find(u.tooltip_root.?, ui.Text).?.widget.as(ui.Text).?.text);

    // DropdownMenu opens a menu and picks an option.
    const dd = find(u.root.?, ui.DropdownMenu).?;
    click(u, dd);
    u.frame(900, 700, 2, Gallery{});
    try testing.expect(u.menu_root != null);
    const mpos = u.menu_root.?.offset;
    clickAt(u, .{ mpos[0] + 30, mpos[1] + ui.menu.padding + ui.menu.item_height * 2.5 });
    try testing.expectEqual(Mode.three, st.mode);

    // Dialog blocks background clicks, confirms via FilledButton, and dismisses via scrim.
    st.dialog_open = true;
    u.frame(900, 700, 3, Gallery{});
    clickAt(u, .{ 10, 10 });
    try testing.expectEqual(@as(u32, 1), st.dismissed);
    try testing.expect(!st.dialog_open);

    st.dialog_open = true;
    u.frame(900, 700, 4, Gallery{});
    const dialog_node = find(u.root.?, ui.Dialog).?;
    var filled_btns: std.ArrayList(*Node) = .empty;
    defer filled_btns.deinit(testing.allocator);
    try findAll(dialog_node, ui.FilledButton, &filled_btns);
    // The last FilledButton in the tree is the dialog's Confirm button.
    click(u, filled_btns.items[filled_btns.items.len - 1]);
    try testing.expectEqual(@as(u32, 1), st.confirmed);
    try testing.expect(!st.dialog_open);
}

test "widget cursor shapes reflect hovered and captured widgets" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();

    var slider_val: f32 = 0.5;
    const SetSlider = struct {
        fn set(v: *f32, x: f32) void {
            v.* = x;
        }
    };

    const CursorApp = struct {
        slider_val: *f32,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{
                .alignment = .top_left,
                .child = cx.make(ui.Column{
                    .cross_axis_alignment = .start,
                    .spacing = 10,
                    .children = &.{
                        cx.make(ui.OutlinedButton{ .label = "Enabled", .on_press = .of(&dummy_count, addDummy) }),
                        cx.make(ui.OutlinedButton{ .label = "Disabled" }),
                        cx.make(ui.SizedBox{
                            .width = 200,
                            .child = cx.make(ui.TextField{ .initial = "hello" }),
                        }),
                        cx.make(ui.SizedBox{
                            .width = 200,
                            .child = cx.make(ui.Slider{ .value = self.slider_val.*, .on_changed = .of(self.slider_val, SetSlider.set) }),
                        }),
                        cx.make(ui.Draggable{
                            .data = 1,
                            .label = "drag-me",
                            .child = cx.make(ui.SizedBox{ .width = 80, .height = 40 }),
                        }),
                    },
                }),
            });
        }
    };

    const w: CursorApp = .{ .slider_val = &slider_val };
    u.frame(400, 400, 0, w);

    // Empty background -> default cursor.
    u.pointerMotion(.{ 350, 350 });
    try testing.expectEqual(ui.Cursor.default, u.cursor());

    // Enabled button -> pointer cursor; disabled button -> default cursor.
    var buttons: std.ArrayList(*Node) = .empty;
    defer buttons.deinit(testing.allocator);
    try findAll(u.root.?, ui.OutlinedButton, &buttons);
    const btn_pos = buttons.items[0].position();
    u.pointerMotion(.{ btn_pos[0] + 10, btn_pos[1] + 10 });
    try testing.expectEqual(ui.Cursor.pointer, u.cursor());

    const dis_pos = buttons.items[1].position();
    u.pointerMotion(.{ dis_pos[0] + 10, dis_pos[1] + 10 });
    try testing.expectEqual(ui.Cursor.default, u.cursor());

    // TextField -> text cursor.
    const tf = find(u.root.?, ui.TextField).?;
    const tf_pos = tf.position();
    u.pointerMotion(.{ tf_pos[0] + 10, tf_pos[1] + 10 });
    try testing.expectEqual(ui.Cursor.text, u.cursor());

    // Slider -> pointer cursor.
    const sl = find(u.root.?, ui.Slider).?;
    const sl_pos = sl.position();
    u.pointerMotion(.{ sl_pos[0] + 30, sl_pos[1] + 10 });
    try testing.expectEqual(ui.Cursor.pointer, u.cursor());

    // Draggable -> grab when hovered, grabbing while actively dragging.
    const dr = find(u.root.?, ui.Draggable).?;
    const dr_pos = dr.position();
    u.pointerMotion(.{ dr_pos[0] + 10, dr_pos[1] + 10 });
    try testing.expectEqual(ui.Cursor.grab, u.cursor());
    u.pointerButton(.{ dr_pos[0] + 10, dr_pos[1] + 10 }, ui.btn_left, true);
    u.pointerMotion(.{ dr_pos[0] + 40, dr_pos[1] + 10 });
    try testing.expectEqual(ui.Cursor.grabbing, u.cursor());
    u.pointerButton(.{ dr_pos[0] + 40, dr_pos[1] + 10 }, ui.btn_left, false);
}

test "zwp_text_input_v3 events commit text, render preedit, and delete surrounding bytes in TextField" {
    const fira = try font.Font.init(fira_data);
    const u = try ui.Ui.create(testing.allocator, &fira);
    defer u.destroy();

    const FieldApp = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{
                .alignment = .top_left,
                .child = cx.make(ui.SizedBox{
                    .width = 240,
                    .child = cx.make(ui.TextField{ .initial = "hello" }),
                }),
            });
        }
    };

    u.frame(300, 100, 0, FieldApp{});
    // Before focus, textInputState is null.
    try testing.expect(u.textInputState() == null);

    // Click to focus the TextField at the end of "hello".
    const tf = find(u.root.?, ui.TextField).?;
    clickAt(u, .{ tf.position()[0] + 200, tf.position()[1] + 15 });
    u.frame(300, 100, 1, FieldApp{});

    const st0 = u.textInputState().?;
    try testing.expectEqualStrings("hello", st0.surrounding_text);
    try testing.expectEqual(@as(u32, 5), st0.cursor);
    try testing.expectEqual(@as(u32, 5), st0.anchor);

    const tf_state = find(u.root.?, ui.TextField).?.state(ui.TextField.State);

    // Preedit string appears without mutating committed text yet.
    var pre_ev: window.InputEvent = .{ .text_preedit = .{ .len = 2, .cursor_begin = 2, .cursor_end = 2 } };
    @memcpy(pre_ev.text_preedit.buf[0..2], "ni");
    u.handleInput(pre_ev);
    try testing.expectEqualStrings("hello", tf_state.text());
    u.frame(300, 100, 2, FieldApp{});

    // Commit string replaces preedit and inserts into the TextField.
    var com_ev: window.InputEvent = .{ .text_commit = .{ .len = 1 } };
    com_ev.text_commit.buf[0] = '!';
    u.handleInput(com_ev);
    u.handleInput(.{ .text_preedit = .{} });
    try testing.expectEqualStrings("hello!", tf_state.text());

    // delete_surrounding_text deletes 2 bytes before cursor ("o!").
    u.handleInput(.{ .text_delete_surrounding = .{ .before_length = 2, .after_length = 0 } });
    try testing.expectEqualStrings("hell", tf_state.text());
}

test "Ui.createDefault loads bundled Fira Sans and Twemoji fallback fonts" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();
    try testing.expect(u.font != null);
    try testing.expect(u.font.?.fallback != null);
    u.frame(200, 80, 0, ui.Text{ .text = "Hello 😀" });
    const img = try Image.init(u, 200, 80);
    defer img.deinit();
    var lit: u32 = 0;
    for (img.pixels) |px| if (px != 0xff000000) {
        lit += 1;
    };
    try testing.expect(lit > 50);
}

test "minimum window size is computed from widget tree and synchronized to window" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();

    const MockWin = struct {
        w: u32 = 300,
        h: u32 = 200,
        min_size: [2]u32 = .{ 0, 0 },
        pub fn size(self: *const @This()) [2]u32 {
            return .{ self.w, self.h };
        }
        pub fn setMinSize(self: *@This(), mw: u32, mh: u32) void {
            self.min_size = .{ mw, mh };
            if (self.w < mw) self.w = mw;
            if (self.h < mh) self.h = mh;
        }
    };
    var mock: MockWin = .{};
    u.attachWindow(&mock, null);
    u.maximized = false;

    const MinApp = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .children = &.{
                    cx.make(ui.TitleBar{ .title = "Min Size" }),
                    cx.make(ui.Expanded{
                        .child = cx.make(ui.Padding{
                            .padding = .all(20),
                            .child = cx.make(ui.SizedBox{ .width = 400, .height = 260 }),
                        }),
                    }),
                },
            });
        }
    };

    u.frame(mock.w, mock.h, 0, MinApp{});
    try testing.expectEqual([2]u32{ 440, 344 }, u.min_size);
    try testing.expectEqual([2]u32{ 440, 344 }, mock.min_size);
    try testing.expectEqual([2]u32{ 440, 344 }, u.frame_size);
    try testing.expect(!u.root.?.overflow.any());

    // Explicit min_size_floor is respected when larger than content minimum.
    u.min_size_floor = .{ 500, 400 };
    u.frame(mock.w, mock.h, 1, MinApp{});
    try testing.expectEqual([2]u32{ 500, 400 }, u.min_size);
    try testing.expectEqual([2]u32{ 500, 400 }, mock.min_size);
}

test "HiDPI scale factor renders text and shapes at physical buffer resolution while keeping logical layout" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();
    u.theme = .light;

    const HiDpiWin = struct {
        width: u32 = 200,
        height: u32 = 80,
        scale: u32 = 2,
    };
    var win: HiDpiWin = .{};
    u.attachWindow(&win, null);
    try testing.expectEqual(@as(u32, 2), u.scale);

    var clicked = false;
    u.frame(200, 80, 0, ui.FilledButton{
        .label = "Sharp Text",
        .icon = .check,
        .on_press = .of(&clicked, struct {
            fn f(flag: *bool) void {
                flag.* = true;
            }
        }.f),
    });
    try testing.expectEqual([2]u32{ 200, 80 }, u.logical_size);
    try testing.expectEqual([2]u32{ 400, 160 }, u.frame_size);

    const img = try Image.init(u, 400, 160);
    defer img.deinit();
    // Both top-left and bottom-right quadrants of the 400x160 physical buffer
    // should contain rendered button pixels.
    try testing.expectEqual(u.theme.primary.toArgb(), img.at(40, 40));
    try testing.expectEqual(u.theme.primary.toArgb(), img.at(360, 120));
}

test "Context.backend reports platform, buffer transport, and renderer" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();

    const expected_renderer: gfx.RenderBackend = if (u.vulkan_renderer != null)
        .vulkan
    else if (u.opengl_renderer != null)
        .opengl
    else
        .software;

    const Probe = struct {
        out: *ui.BackendInfo,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            self.out.* = cx.backend();
            return cx.make(ui.Empty{});
        }
    };

    var info: ui.BackendInfo = .{};
    u.frame(320, 240, 0, Probe{ .out = &info });
    try testing.expectEqual(window.Platform.headless, info.platform);
    try testing.expectEqual(window.Decorations.none, info.decorations);
    try testing.expectEqual(window.BufferTransport.memory, info.buffer_transport);
    try testing.expectEqual(expected_renderer, info.renderer);

    var wl_win: window.WaylandWindow = .{
        .gpa = testing.allocator,
        .conn = undefined,
        .clipboard = .{ .gpa = testing.allocator },
        .wm_base = .{ .id = 2 },
        .presentation = .{ .id = 3 },
        .fifo = .{ .id = 4 },
        .width = 800,
        .height = 600,
        .min_size = .{ 1, 1 },
        .scale = 2,
    };
    wl_win.updateExtensions();
    u.attachWindow(&wl_win, null);
    u.frame(800, 600, 1, Probe{ .out = &info });
    try testing.expectEqual(window.Platform.wayland, info.platform);
    try testing.expectEqual(window.Decorations.client, info.decorations);
    try testing.expectEqual(window.BufferTransport.wl_shm, info.buffer_transport);
    try testing.expectEqual(window.BufferSync.none, info.buffer_sync);
    try testing.expect(info.frame_sync.vsync);
    try testing.expect(info.frame_sync.frame_callback);
    try testing.expect(info.frame_sync.presentation_time);
    try testing.expect(info.frame_sync.fifo_v1);
    try testing.expect(!info.frame_sync.commit_timing_v1);
    try testing.expect(info.hasExtension("xdg_wm_base"));
    try testing.expect(info.hasExtension("wp_presentation"));
    try testing.expect(info.hasExtension("wp_fifo_manager_v1"));
    try testing.expect(!info.hasExtension("wp_commit_timing_manager_v1"));
    try testing.expectEqual(expected_renderer, info.renderer);
    try testing.expectEqual([2]u32{ 800, 600 }, info.logical_size);
    try testing.expectEqual([2]u32{ 1600, 1200 }, info.physical_size);
    try testing.expectEqual(@as(u32, 2), info.scale);

    wl_win.server_decorations = true;
    u.attachWindow(&wl_win, null);
    u.frame(800, 600, 2, Probe{ .out = &info });
    try testing.expectEqual(window.Decorations.server, info.decorations);
}

test "VulkanRenderer, OpenGlRenderer, and SoftwareRenderer render UI widgets and text" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();
    u.theme = .light;

    var clicked = false;
    u.frame(200, 80, 0, ui.FilledButton{
        .label = "GPU 2D",
        .icon = .check,
        .on_press = .of(&clicked, struct {
            fn f(flag: *bool) void {
                flag.* = true;
            }
        }.f),
    });

    // 1. Default renderer (Vulkan -> OpenGL -> Software)
    {
        const img = try Image.init(u, 200, 80);
        defer img.deinit();
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(20, 20));
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(180, 60));
    }

    // 2. Explicitly test OpenGlRenderer if available
    if (gfx.OpenGlRenderer.initDefault(testing.allocator)) |gl_val| {
        var gl = gl_val;
        defer gl.deinit();
        u.attachRenderer(gl.renderer(), false);
        try testing.expectEqual(gfx.RenderBackend.opengl, u.renderer.?.backend());
        const img = try Image.init(u, 200, 80);
        defer img.deinit();
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(20, 20));
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(180, 60));
    } else |_| {}

    // 3. Explicitly test SoftwareRenderer fallback
    {
        u.attachRenderer(u.software_renderer.renderer(), false);
        try testing.expectEqual(gfx.RenderBackend.software, u.renderer.?.backend());
        const img = try Image.init(u, 200, 80);
        defer img.deinit();
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(20, 20));
        try testing.expectEqual(u.theme.primary.toArgb(), img.at(180, 60));
    }
}
test "any window can show frames and give the clipboard, not only Wayland's" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();

    const PlainWin = struct {
        width: u32 = 120,
        height: u32 = 60,
        pixels: [120 * 60]u32 = @splat(0),
        shown: u32 = 0,
        copied: [16]u8 = undefined,
        copied_len: usize = 0,
        pub fn beginFrame(w: *@This()) !gfx.software.Image {
            return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
        }
        pub fn showDamaged(w: *@This(), _: ?[]const gfx.Viewport) !void {
            w.shown += 1;
        }
        pub fn copy(w: *@This(), text: []const u8) void {
            @memcpy(w.copied[0..text.len], text);
            w.copied_len = text.len;
        }
        pub fn paste(w: *@This(), sink: window.clipboard.Sink) void {
            sink.f(sink.ctx, w.copied[0..w.copied_len]);
        }
    };
    var win: PlainWin = .{};
    u.attachWindow(&win, null);
    u.frame(win.width, win.height, 0, ui.SizedBox{ .width = 10, .height = 10 });
    try testing.expect(try u.present(&win, 0xff112233));
    try testing.expectEqual(@as(u32, 1), win.shown);
    try testing.expectEqual(@as(u32, 0xff112233), win.pixels[0]);
    // Nothing changed: nothing to show.
    u.frame(win.width, win.height, 1, ui.SizedBox{ .width = 10, .height = 10 });
    try testing.expect(!try u.present(&win, 0xff112233));

    u.copyText("hello");
    try testing.expectEqualStrings("hello", win.copied[0..win.copied_len]);

    // A renderer drawing into something else cannot draw into the window's
    // buffer.
    var wrong: u32 = 0;
    try testing.expectError(error.WrongTarget, u.render(&wrong, null));
}

/// A window with popups (as Wayland's `xdg_popup`): it records what is
/// opened and closed, and puts each popup at a fixed place.
const PopupWin = struct {
    width: u32 = 400,
    height: u32 = 300,
    pixels: [400 * 300]u32 = @splat(0),
    popup_pixels: [300 * 300]u32 = @splat(0),
    opened: std.ArrayList(window.PopupPlacement) = .empty,
    /// Opens (positive ids) and closes (negative), in order.
    log: std.ArrayList(i64) = .empty,
    next: u32 = 1,
    popup_size: [2]u32 = .{ 0, 0 },
    configured: bool = true,
    shown: u32 = 0,
    /// Where popups go: past the window's right edge, as a popup can.
    const at: [2]i32 = .{ 350, 40 };

    fn deinit(w: *PopupWin) void {
        w.opened.deinit(testing.allocator);
        w.log.deinit(testing.allocator);
    }
    pub fn beginFrame(w: *PopupWin) !gfx.software.Image {
        return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
    }
    pub fn showDamaged(_: *PopupWin, _: ?[]const gfx.Viewport) !void {}
    pub fn openPopup(w: *PopupWin, pl: window.PopupPlacement) ?u32 {
        w.opened.append(testing.allocator, pl) catch return null;
        w.log.append(testing.allocator, w.next) catch return null;
        w.popup_size = pl.size;
        w.next += 1;
        return w.next - 1;
    }
    pub fn closePopup(w: *PopupWin, id: u32) void {
        w.log.append(testing.allocator, -@as(i64, id)) catch {};
    }
    pub fn popupPosition(_: *PopupWin, _: u32) ?[2]i32 {
        return at;
    }
    pub fn beginPopupFrame(w: *PopupWin, _: u32) !?gfx.software.Image {
        if (!w.configured) return null;
        return .{ .pixels = w.popup_pixels[0 .. w.popup_size[0] * w.popup_size[1]], .width = w.popup_size[0], .height = w.popup_size[1] };
    }
    pub fn showPopup(w: *PopupWin, _: u32) !void {
        w.shown += 1;
    }
};

test "menus and tooltips go in popups of their own when the window has them" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();
    u.attachRenderer(u.software_renderer.renderer(), false);
    u.theme = .light;
    var win: PopupWin = .{};
    defer win.deinit();
    u.attachWindow(&win, null);

    const HelpRoot = struct {
        pub fn build(_: *const @This(), cx: *Context) Widget {
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Tooltip{
                .text = "Help",
                .child = cx.make(ui.SizedBox{ .width = 100, .height = 40 }),
            }) });
        }
    };
    var pressed = false;
    const press = struct {
        fn f(b: *bool) void {
            b.* = true;
        }
    }.f;

    // Hovering the widget opens its tooltip in a popup above it.
    // On Wayland, a newly opened xdg_popup is not yet configured on the
    // frame it opens (`beginPopupFrame` returns `null`); `present` must
    // request another frame so the popup is drawn once configured.
    u.frame(win.width, win.height, 0, HelpRoot{});
    _ = try u.present(&win, 0xff000000);
    win.configured = false;
    u.pointerMotion(.{ 50, 20 });
    u.frame(win.width, win.height, 1, HelpRoot{});
    try testing.expectEqual(@as(usize, 1), win.opened.items.len);
    const tip = win.opened.items[0];
    try testing.expectEqual(window.PopupKind.tooltip, tip.kind);
    try testing.expectEqual(window.PopupPlacement.Side.above, tip.side);
    try testing.expectEqual([4]i32{ 0, 0, 100, 40 }, tip.anchor);
    try testing.expect(!u.needs_frame);
    try testing.expect(!try u.present(&win, 0xff000000));
    try testing.expectEqual(@as(u32, 0), win.shown);
    try testing.expect(u.needs_frame);

    // Once the compositor configures the popup, the requested frame draws
    // it; a subsequent unchanged frame does not redraw it.
    win.configured = true;
    u.frame(win.width, win.height, 1, HelpRoot{});
    try testing.expect(try u.present(&win, 0xff000000));
    try testing.expectEqual(@as(u32, 1), win.shown);
    try testing.expect(!u.needs_frame);
    u.frame(win.width, win.height, 1, HelpRoot{});
    try testing.expect(!try u.present(&win, 0xff000000));
    try testing.expectEqual(@as(u32, 1), win.shown);

    // A menu: the tooltip's popup closes before the menu's opens.
    win.shown = 0;
    u.openMenu(u.root.?, .{ 30, 25 }, &.{.{ .label = "Copy", .on_press = .of(&pressed, press) }});
    u.frame(win.width, win.height, 2, HelpRoot{});
    try testing.expectEqualSlices(i64, &.{ 1, -1, 2 }, win.log.items);
    const menu = win.opened.items[1];
    try testing.expectEqual(window.PopupKind.menu, menu.kind);
    try testing.expectEqual([4]i32{ 30, 25, 1, 1 }, menu.anchor);
    try testing.expectEqual(window.PopupPlacement.Side.below_right, menu.side);
    // It is where the popup is (past the window's edge), drawn in the
    // popup and not in the window.
    try testing.expectEqual(ui.Point{ 350, 40 }, u.menu_root.?.offset);
    @memset(&win.pixels, 0);
    try testing.expect(try u.present(&win, 0xff000000));
    try testing.expect(win.shown > 0);
    const surface = u.theme.surface_container.toArgb();
    try testing.expectEqual(surface, win.popup_pixels[10 * win.popup_size[0] + 10]);
    try testing.expect(win.pixels[60 * win.width + 60] != surface);

    // Pointer events there go to it: pressing its item does the action and
    // closes it (and its popup).
    const item: ui.Point = .{ 350 + 20, 40 + 8 + 20 };
    u.pointerMotion(item);
    u.pointerButton(item, ui.btn_left, true);
    u.pointerButton(item, ui.btn_left, false);
    try testing.expect(pressed);
    try testing.expect(u.menu == null);
    u.frame(win.width, win.height, 3, HelpRoot{});
    try testing.expectEqual(@as(i64, -2), win.log.items[win.log.items.len - 1]);

    // The window system closing a menu's popup closes the menu.
    u.openMenu(u.root.?, .{ 30, 25 }, &.{.{ .label = "Copy" }});
    u.frame(win.width, win.height, 4, HelpRoot{});
    const id: u32 = @intCast(win.log.items[win.log.items.len - 1]);
    u.handleInput(.{ .popup_done = id });
    try testing.expect(u.menu == null);
    try testing.expect(u.menu_popup == null);
    try testing.expectEqual(-@as(i64, id), win.log.items[win.log.items.len - 1]);
}

/// A renderer that can draw straight into dmabufs (or fail to), and draws
/// the CPU way with the software renderer.
const DirectRenderer = struct {
    fail: bool = false,
    direct: u32 = 0,
    clears: usize = 0,
    damage: usize = 0,
    pub fn prepare(_: *DirectRenderer, _: []const *const gfx.Canvas) !void {}
    pub fn record(_: *DirectRenderer, c: *const gfx.Canvas, target: *gfx.software.Image, damage: ?[]const gfx.Viewport) !void {
        try gfx.software.renderWithDamage(c, target.*, damage);
    }
    pub fn renderDmabuf(r: *DirectRenderer, _: []const *const gfx.Canvas, _: []const gfx.Segment, _: *const gfx.DmabufTarget, _: u32, clear_rects: []const gfx.Viewport, damage: []const gfx.Viewport) !void {
        if (r.fail) return error.Unsupported;
        r.direct += 1;
        r.clears = clear_rects.len;
        r.damage = damage.len;
    }
};

/// A window whose buffers are dmabufs.
const DmabufWin = struct {
    width: u32 = 200,
    height: u32 = 100,
    pixels: [200 * 100]u32 = @splat(0),
    cpu_frames: u32 = 0,
    shown: u32 = 0,
    pub fn beginFrame(w: *DmabufWin) !gfx.software.Image {
        w.cpu_frames += 1;
        return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
    }
    pub fn beginDmabufFrame(w: *DmabufWin) ?gfx.DmabufTarget {
        return .{ .id = 1, .fd = -1, .fourcc = 0, .modifier = 0, .offset = 0, .stride = w.width * 4, .width = w.width, .height = w.height, .origin = .{ 0, 0 }, .content = .{ w.width, w.height }, .cpu = .{ .ctx = w, .begin = cpuBegin, .end = cpuEnd } };
    }
    fn cpuBegin(ctx: *anyopaque) anyerror!gfx.software.Image {
        const w: *DmabufWin = @ptrCast(@alignCast(ctx));
        return .{ .pixels = &w.pixels, .width = w.width, .height = w.height };
    }
    fn cpuEnd(_: *anyopaque) void {}
    pub fn showDamaged(w: *DmabufWin, _: ?[]const gfx.Viewport) !void {
        w.shown += 1;
    }
};

test "frames are drawn straight into dmabufs when the renderer can, and the CPU way when it cannot" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();
    var r: DirectRenderer = .{};
    u.attachRenderer(gfx.Renderer.of(&r), false);
    var win: DmabufWin = .{};
    u.attachWindow(&win, null);
    const content = ui.SizedBox{ .width = 20, .height = 20 };

    // On the GPU: the whole window is cleared and drawn, and nothing is
    // mapped for the CPU.
    u.frame(win.width, win.height, 0, content);
    try testing.expect(try u.present(&win, 0xff102030));
    try testing.expectEqual(@as(u32, 1), r.direct);
    try testing.expectEqual(@as(usize, 1), r.clears);
    try testing.expectEqual(@as(u32, 0), win.cpu_frames);
    try testing.expectEqual(@as(u32, 1), win.shown);

    // A renderer that fails: the frame is drawn on the CPU, and the GPU way
    // is not tried again.
    r.fail = true;
    u.frame(win.width, win.height, 1, content);
    u.damage.invalidate();
    try testing.expect(try u.present(&win, 0xff102030));
    try testing.expectEqual(@as(u32, 1), win.cpu_frames);
    try testing.expectEqual(@as(u32, 0xff102030), win.pixels[0]);
    r.fail = false;
    u.frame(win.width, win.height, 2, content);
    u.damage.invalidate();
    _ = try u.present(&win, 0xff102030);
    try testing.expectEqual(@as(u32, 1), r.direct);
    try testing.expectEqual(@as(u32, 2), win.cpu_frames);
}

test "a GPU draw can also say how to draw straight into a GPU frame, which the CPU way ignores" {
    const u = try ui.Ui.createDefault(testing.allocator);
    defer u.destroy();
    u.attachRenderer(u.software_renderer.renderer(), false);
    const Area = struct {
        var cpu: u32 = 0;
        var direct: u32 = 0;
        pub fn layout(_: *const @This(), _: *Node, c: ui.Constraints) ui.Size {
            return c.constrain(.{ .w = 40, .h = 30 });
        }
        pub fn paint(self: *const @This(), _: *Node, p: *ui.Painter) void {
            p.gpuWithDirect(.{ .fills = true }, self, draw, drawDirect);
        }
        fn draw(_: *const @This(), _: *gfx.software.Image, _: gfx.GpuArea) anyerror!void {
            cpu += 1;
        }
        fn drawDirect(_: *const @This(), backend: gfx.RenderBackend, _: *const anyopaque, _: gfx.GpuArea) anyerror!bool {
            direct += 1;
            return backend == .vulkan;
        }
    };
    u.frame(100, 100, 0, Area{});
    const seg = for (u.segments.items) |s| {
        if (s == .gpu) break s.gpu;
    } else return error.TestUnexpectedResult;
    try testing.expect(seg.direct != null);
    try testing.expect(seg.area.fills);
    // The software renderer draws it the CPU way.
    var pixels: [100 * 100]u32 = @splat(0);
    var img: gfx.software.Image = .{ .pixels = &pixels, .width = 100, .height = 100 };
    try u.render(&img, null);
    try testing.expectEqual(@as(u32, 1), Area.cpu);
    try testing.expectEqual(@as(u32, 0), Area.direct);
    // A GPU frame gets the direct draw, which may decline.
    var frame: u8 = 0;
    try testing.expect(try seg.direct.?(seg.ctx, .vulkan, &frame, seg.area));
    try testing.expect(!try seg.direct.?(seg.ctx, .opengl, &frame, seg.area));
}

test "an animated widget makes its child from how far through it is, and stops asking for frames at the end" {
    const u = try ui.Ui.create(testing.allocator, null);
    defer u.destroy();
    const Anim = struct {
        t: f32 = -1,
        restart: u64 = 0,
        repeat: ui.AnimatedWidget.Repeat = .once,
        fn child(a: *@This(), cx: *Context, t: f32) Widget {
            a.t = t;
            return cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.SizedBox{ .width = 10 + 90 * t, .height = 10 }) });
        }
    };
    const AnimRoot = struct {
        a: *Anim,
        pub fn build(self: *const @This(), cx: *Context) Widget {
            return cx.make(ui.AnimatedWidget{
                .duration_ns = 1000,
                .delay_ns = 100,
                .repeat = self.a.repeat,
                .restart = self.a.restart,
                .builder = .of(self.a, Anim.child),
            });
        }
    };
    var a: Anim = .{};
    // It starts the first frame it is built, waits out its delay, and
    // runs for its duration.
    u.frame(200, 100, 5000, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 0), a.t);
    try testing.expect(u.needs_frame);
    u.frame(200, 100, 5100, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 0), a.t);
    u.frame(200, 100, 5350, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.25), a.t, 1e-6);
    try testing.expect(u.needs_frame);
    // The child is made afresh from it.
    try testing.expectEqual(@as(f32, 32.5), find(u.root.?, ui.SizedBox).?.size.w);
    // At the end, it stays at 1 and asks for no more frames.
    u.frame(200, 100, 6100, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 1), a.t);
    try testing.expect(!u.needs_frame);
    u.frame(200, 100, 9000, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 1), a.t);
    try testing.expect(!u.needs_frame);
    // Changing `restart` starts it over.
    a.restart += 1;
    u.frame(200, 100, 10_000, AnimRoot{ .a = &a });
    try testing.expectEqual(@as(f32, 0), a.t);
    u.frame(200, 100, 10_600, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.5), a.t, 1e-6);
    // Looping, it goes from 0 to 1 over and over; reversing, back and forth.
    a.repeat = .loop;
    u.frame(200, 100, 11_850, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.75), a.t, 1e-6);
    try testing.expect(u.needs_frame);
    a.repeat = .reverse;
    u.frame(200, 100, 11_850, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.25), a.t, 1e-6);
    u.frame(200, 100, 12_350, AnimRoot{ .a = &a });
    try testing.expectApproxEqAbs(@as(f32, 0.25), a.t, 1e-6);
    try testing.expect(u.needs_frame);
}

test "what a popup paints is told apart by its shapes, clips and images, and not at all with a GPU area" {
    const hash = ui.Ui.paintedHash;
    const rect: gfx.Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    var a = gfx.Canvas.init(testing.allocator);
    defer a.deinit();
    a.begin(100, 50);
    a.fillRect(rect, red);
    var b = gfx.Canvas.init(testing.allocator);
    defer b.deinit();
    b.begin(100, 50);
    b.fillRect(rect, red);
    // The same shapes, the same.
    try testing.expectEqual(hash(&.{.{ .canvas = &a }}).?, hash(&.{.{ .canvas = &b }}).?);
    // A different colour, or a clip (here cutting nothing off), differs.
    b.begin(100, 50);
    b.fillRect(rect, blue);
    try testing.expect(hash(&.{.{ .canvas = &a }}).? != hash(&.{.{ .canvas = &b }}).?);
    b.begin(100, 50);
    b.setClip(.{ .x = 0, .y = 0, .w = 100, .h = 50 });
    b.fillRect(rect, red);
    try testing.expect(hash(&.{.{ .canvas = &a }}).? != hash(&.{.{ .canvas = &b }}).?);
    // A different image in the same place differs.
    const pixels: [4]u32 = @splat(0xffffffff);
    const one = gfx.Image.init(&pixels, 2, 2);
    const other = gfx.Image.init(&pixels, 2, 2);
    a.begin(100, 50);
    a.drawImage(&one, rect, 1);
    b.begin(100, 50);
    b.drawImage(&other, rect, 1);
    try testing.expect(hash(&.{.{ .canvas = &a }}).? != hash(&.{.{ .canvas = &b }}).?);
    // What a GPU area draws is not known.
    const noop = struct {
        fn f(_: *const anyopaque, _: *anyopaque, _: gfx.GpuArea) anyerror!void {}
    }.f;
    try testing.expectEqual(@as(?u64, null), hash(&.{ .{ .canvas = &a }, .{ .gpu = .{ .ctx = undefined, .f = noop, .area = undefined } } }));
}
