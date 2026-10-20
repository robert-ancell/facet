//! What the UI is to assistive technologies (screen readers, switch
//! access, magnifiers): a tree of objects, each with a role (a button, a
//! check box, a label…), a name, states (checked, focused…), a value,
//! text, and an action, made from the widgets after each frame. On Linux
//! it is offered to them over AT-SPI (`atspi.zig`).
//!
//! Facet's widgets say what they are (`pub fn accessible(self, n) ?Info`).
//! Others, and the app's own, are described with `Accessible`:
//!
//!     // A name for a button that only has an icon.
//!     cx.make(ui.Accessible{ .label = "Zoom in", .child = cx.make(ui.IconButton{ .icon = .add, ... }) })
//!     // A widget of the app's own, as what it is.
//!     cx.make(ui.Accessible{ .role = .slider, .label = "Volume", .value = .{ .current = 0.8 }, .child = ... })
//!     // Not there at all (decoration).
//!     cx.make(ui.Accessible{ .hidden = true, .child = ... })
//!
//! Widgets that say nothing are left out, their descendants going in the
//! nearest object above them; those whose `Info` is a `leaf` (a button)
//! have none of theirs reported (their label is their name).

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Node = widget.Node;
const Widget = widget.Widget;
const Callback = widget.Callback;
const Rect = geometry.Rect;

/// What an object is (AT-SPI's roles, by its numbers).
pub const Role = enum(u32) {
    invalid = 0,
    accelerator_label = 1,
    alert = 2,
    animation = 3,
    arrow = 4,
    calendar = 5,
    canvas = 6,
    check_box = 7,
    check_menu_item = 8,
    color_chooser = 9,
    column_header = 10,
    combo_box = 11,
    date_editor = 12,
    desktop_icon = 13,
    desktop_frame = 14,
    dial = 15,
    dialog = 16,
    directory_pane = 17,
    drawing_area = 18,
    file_chooser = 19,
    filler = 20,
    focus_traversable = 21,
    font_chooser = 22,
    frame = 23,
    glass_pane = 24,
    html_container = 25,
    icon = 26,
    image = 27,
    internal_frame = 28,
    label = 29,
    layered_pane = 30,
    list = 31,
    list_item = 32,
    menu = 33,
    menu_bar = 34,
    menu_item = 35,
    option_pane = 36,
    page_tab = 37,
    page_tab_list = 38,
    panel = 39,
    password_text = 40,
    popup_menu = 41,
    progress_bar = 42,
    push_button = 43,
    radio_button = 44,
    radio_menu_item = 45,
    root_pane = 46,
    row_header = 47,
    scroll_bar = 48,
    scroll_pane = 49,
    separator = 50,
    slider = 51,
    spin_button = 52,
    split_pane = 53,
    status_bar = 54,
    table = 55,
    table_cell = 56,
    table_column_header = 57,
    table_row_header = 58,
    tearoff_menu_item = 59,
    terminal = 60,
    text = 61,
    toggle_button = 62,
    tool_bar = 63,
    tool_tip = 64,
    tree = 65,
    tree_table = 66,
    unknown = 67,
    viewport = 68,
    window = 69,
    extended = 70,
    header = 71,
    footer = 72,
    paragraph = 73,
    ruler = 74,
    application = 75,
    autocomplete = 76,
    editbar = 77,
    embedded = 78,
    entry = 79,
    chart = 80,
    caption = 81,
    document_frame = 82,
    heading = 83,
    page = 84,
    section = 85,
    redundant_object = 86,
    form = 87,
    link = 88,
    input_method_window = 89,
    table_row = 90,
    tree_item = 91,
    document_spreadsheet = 92,
    document_presentation = 93,
    document_text = 94,
    document_web = 95,
    document_email = 96,
    comment = 97,
    list_box = 98,
    grouping = 99,
    image_map = 100,
    notification = 101,
    info_bar = 102,
    level_bar = 103,
    title_bar = 104,
    block_quote = 105,
    audio = 106,
    video = 107,
    definition = 108,
    article = 109,
    landmark = 110,
    log = 111,
    marquee = 112,
    math = 113,
    rating = 114,
    timer = 115,
    static = 116,
    math_fraction = 117,
    math_root = 118,
    subscript = 119,
    superscript = 120,
    description_list = 121,
    description_term = 122,
    description_value = 123,
    footnote = 124,
    content_deletion = 125,
    content_insertion = 126,
    mark = 127,
    suggestion = 128,
    push_button_menu = 129,

    /// Its name, as AT-SPI gives it ("push button").
    pub fn name(r: Role, buf: []u8) []const u8 {
        const tag = @tagName(r);
        const n = @min(tag.len, buf.len);
        for (tag[0..n], buf[0..n]) |c, *o| o.* = if (c == '_') ' ' else c;
        return buf[0..n];
    }
};

/// What is so of an object (the AT-SPI states it reports; it is also
/// visible, showing, and, unless `disabled`, enabled and sensitive).
pub const States = packed struct(u16) {
    focusable: bool = false,
    focused: bool = false,
    checkable: bool = false,
    checked: bool = false,
    /// Neither checked nor not (a check box for some of several).
    indeterminate: bool = false,
    pressed: bool = false,
    selectable: bool = false,
    selected: bool = false,
    expandable: bool = false,
    expanded: bool = false,
    editable: bool = false,
    multi_line: bool = false,
    read_only: bool = false,
    busy: bool = false,
    disabled: bool = false,
    modal: bool = false,

    /// AT-SPI's state numbers (bits of `GetState`'s two words), and the
    /// names its events give them.
    pub const atspi = [_]struct { []const u8, u6, []const u8 }{
        .{ "focusable", 11, "focusable" },
        .{ "focused", 12, "focused" },
        .{ "checkable", 41, "checkable" },
        .{ "checked", 4, "checked" },
        .{ "indeterminate", 32, "indeterminate" },
        .{ "pressed", 20, "pressed" },
        .{ "selectable", 22, "selectable" },
        .{ "selected", 23, "selected" },
        .{ "expandable", 9, "expandable" },
        .{ "expanded", 10, "expanded" },
        .{ "editable", 7, "editable" },
        .{ "multi_line", 17, "multi-line" },
        .{ "read_only", 43, "read-only" },
        .{ "busy", 3, "busy" },
        .{ "modal", 16, "modal" },
    };

    /// AT-SPI's state set: its two words.
    pub fn bits(s: States) [2]u32 {
        var out: u64 = 0;
        inline for (atspi) |a| if (@field(s, a[0])) {
            out |= @as(u64, 1) << a[1];
        };
        // Visible and showing; enabled and sensitive unless disabled.
        out |= @as(u64, 1) << 30 | @as(u64, 1) << 25;
        if (!s.disabled) out |= @as(u64, 1) << 8 | @as(u64, 1) << 24;
        if (s.editable or s.multi_line) {
            out |= @as(u64, 1) << (if (s.multi_line) 17 else 26);
        }
        return .{ @truncate(out), @truncate(out >> 32) };
    }
};

/// A value it shows or sets (a slider's, a progress bar's).
pub const Value = struct {
    current: f64,
    min: f64 = 0,
    max: f64 = 1,
    /// The smallest step it moves by (0: any).
    step: f64 = 0,
    /// How it is read out, if not as the number ("40%").
    text: []const u8 = "",
};

/// Sets an object's value (for assistive technologies that move a slider).
pub const ValueSetter = struct {
    ctx: *anyopaque,
    f: *const fn (*anyopaque, f64) void,

    pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), f64) void) ValueSetter {
        const P = @TypeOf(ptr);
        return .{ .ctx = @ptrCast(@constCast(ptr)), .f = struct {
            fn call(ctx: *anyopaque, v: f64) void {
                f(@as(P, @ptrCast(@alignCast(ctx))), v);
            }
        }.call };
    }

    pub fn call(s: ValueSetter, v: f64) void {
        s.f(s.ctx, v);
    }
};

/// What a widget is to assistive technologies.
pub const Info = struct {
    role: Role,
    name: []const u8 = "",
    description: []const u8 = "",
    states: States = .{},
    value: ?Value = null,
    set_value: ?ValueSetter = null,
    /// The text it shows or holds (a label's, a field's), and where its
    /// caret is in it (in characters).
    text: ?[]const u8 = null,
    caret: ?usize = null,
    /// What its action does (pressing it, toggling it), if it has one:
    /// its name ("click", "toggle"), and what it calls.
    action: []const u8 = "click",
    activate: ?Callback = null,
    /// Its descendants are part of it (a button's label is its name):
    /// none of them is reported.
    leaf: bool = false,
};

/// Describes what is in it to assistive technologies: as an object of its
/// own (with a `role`), or (without) the objects of the widgets in it, with
/// this name, description and so on instead of theirs; or not at all
/// (`hidden`).
pub const Accessible = struct {
    /// What it is; null to describe the widgets in it instead.
    role: ?Role = null,
    /// Its name (what a screen reader says it is).
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    value: ?Value = null,
    set_value: ?ValueSetter = null,
    states: ?States = null,
    text: ?[]const u8 = null,
    /// What its action does, and its name.
    on_activate: ?Callback = null,
    action: ?[]const u8 = null,
    /// Its descendants are part of it (with a role): none reported.
    leaf: bool = false,
    /// Not reported, nor anything in it.
    hidden: bool = false,
    child: ?Widget = null,

    pub fn accessible(self: *const Accessible, _: *Node) ?Info {
        const role = self.role orelse return null;
        var info: Info = .{ .role = role, .leaf = self.leaf };
        self.apply(&info);
        return info;
    }

    /// Puts what it says in `info`.
    fn apply(self: *const Accessible, info: *Info) void {
        if (self.label) |l| info.name = l;
        if (self.description) |d| info.description = d;
        if (self.value) |v| info.value = v;
        if (self.set_value) |v| info.set_value = v;
        if (self.states) |s| info.states = s;
        if (self.text) |t| info.text = t;
        if (self.on_activate) |a| info.activate = a;
        if (self.action) |a| info.action = a;
    }
};

/// For an action: a callback calling `cb` with `value` (made in the
/// frame's arena, so good for the tree made from it); none without `cb`.
pub fn callWith(n: *Node, comptime T: type, cb: ?widget.ValueCallback(T), value: T) ?Callback {
    const f = cb orelse return null;
    const Bound = struct {
        f: widget.ValueCallback(T),
        v: T,
        fn run(b: *@This()) void {
            b.f.call(b.v);
        }
    };
    const b = n.ui.arena().create(Bound) catch return null;
    b.* = .{ .f = f, .v = value };
    return .of(b, Bound.run);
}

/// For a value set by assistive technologies: `cb`, given it as a
/// float (and clamped to `min` to `max`); none without `cb`.
pub fn setterOf(n: *Node, cb: ?widget.ValueCallback(f32), min: f32, max: f32) ?ValueSetter {
    const f = cb orelse return null;
    const Bound = struct {
        f: widget.ValueCallback(f32),
        min: f32,
        max: f32,
        fn run(b: *@This(), v: f64) void {
            b.f.call(std.math.clamp(@as(f32, @floatCast(v)), b.min, b.max));
        }
    };
    const b = n.ui.arena().create(Bound) catch return null;
    b.* = .{ .f = f, .min = min, .max = max };
    return .of(b, Bound.run);
}

/// An icon's name, to name what has only it ("light mode").
pub fn iconName(n: *Node, icon: anytype) []const u8 {
    const tag = @tagName(icon);
    const out = n.ui.arena().dupe(u8, tag) catch return tag;
    for (out) |*c| if (c.* == '_') {
        c.* = ' ';
    };
    return out;
}

/// An object in the tree.
pub const Object = struct {
    /// Its number (the window's is `window_id`), the same from frame to
    /// frame while its widget is there.
    id: u32,
    info: Info,
    /// Where it is in the window (logical pixels).
    bounds: Rect,
    /// Its parent's index (none for the window), and its children's.
    parent: ?u32,
    children: []const u32,
    /// Its widget's node (none for the window): there until the next
    /// frame.
    node: ?*Node,
};

pub const window_id = 1;

/// The objects of a frame: the window first, then the rest, each after
/// its parent.
pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    objects: []Object = &.{},
    by_id: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// The focused object's index, if any is.
    focused: ?u32 = null,

    pub fn deinit(t: *Tree) void {
        t.arena.deinit();
    }

    pub fn find(t: *const Tree, id: u32) ?*const Object {
        const i = t.by_id.get(id) orelse return null;
        return &t.objects[i];
    }

    pub fn indexOf(t: *const Tree, id: u32) ?u32 {
        return t.by_id.get(id);
    }

    /// The deepest object at `p` (in the window).
    pub fn at(t: *const Tree, p: [2]f32) ?u32 {
        var best: ?u32 = null;
        var i: u32 = 0;
        while (i < t.objects.len) : (i += 1) {
            const b = t.objects[i].bounds;
            // Children come after their parents: the last that has it is
            // the deepest.
            if (p[0] >= b.x and p[1] >= b.y and p[0] < b.x + b.w and p[1] < b.y + b.h) best = i;
        }
        return best;
    }
};

/// Makes the tree of the widgets under `root` (in a window `size` big,
/// called `title`), numbering new objects from `next_id`.
pub fn build(gpa: std.mem.Allocator, root: *Node, extra_roots: []const *Node, title: []const u8, size: [2]f32, focused: ?*Node, next_id: *u32) error{OutOfMemory}!*Tree {
    const t = try gpa.create(Tree);
    t.* = .{ .arena = .init(gpa) };
    errdefer {
        t.deinit();
        gpa.destroy(t);
    }
    const a = t.arena.allocator();
    var b: Builder = .{ .arena = a, .next_id = next_id, .focused = focused };
    try b.objects.append(a, .{
        .id = window_id,
        .info = .{ .role = .frame, .name = try a.dupe(u8, title), .states = .{ .focusable = true } },
        .bounds = .{ .x = 0, .y = 0, .w = size[0], .h = size[1] },
        .parent = null,
        .children = &.{},
        .node = null,
    });
    try b.kids.append(a, .empty);
    try b.walk(root, 0, .{});
    for (extra_roots) |r| try b.walk(r, 0, .{});
    for (b.objects.items, b.kids.items) |*o, k| o.children = k.items;
    if (b.focused_index) |i| b.objects.items[i].info.states.focused = true;
    t.objects = b.objects.items;
    for (t.objects, 0..) |o, i| try t.by_id.put(a, o.id, @intCast(i));
    t.focused = b.focused_index;
    return t;
}

const Builder = struct {
    arena: std.mem.Allocator,
    objects: std.ArrayList(Object) = .empty,
    kids: std.ArrayList(std.ArrayList(u32)) = .empty,
    next_id: *u32,
    focused: ?*Node,
    focused_index: ?u32 = null,

    /// What describes the objects below: an `Accessible` without a role,
    /// and a tooltip (their name if they have none, or else their
    /// description).
    const Over = struct { acc: ?*const Accessible = null, tip: ?[]const u8 = null };

    fn walk(b: *Builder, n: *Node, parent: u32, describe: Over) error{OutOfMemory}!void {
        var over = describe;
        if (n.widget.as(Accessible)) |acc| {
            if (acc.hidden) return;
            // Without a role, it describes the objects in it.
            if (acc.role == null) over.acc = acc;
        }
        if (n.widget.as(@import("tooltip.zig").Tooltip)) |tip| over.tip = tip.text;
        const info_fn = n.widget.vtable.accessible orelse {
            for (n.children.items) |ch| try b.walk(ch, parent, over);
            return;
        };
        var info = info_fn(n.widget.ptr, n) orelse {
            for (n.children.items) |ch| try b.walk(ch, parent, over);
            return;
        };
        if (over.tip) |tip| {
            if (info.name.len == 0) info.name = tip else if (info.description.len == 0) info.description = tip;
        }
        if (over.acc) |acc| if (acc != n.widget.as(Accessible)) acc.apply(&info);
        // What takes the focus (it, or a widget it is made of), and
        // whether it has it: the deepest object the focus is in has.
        const focus = @import("focus.zig");
        if (focus.first(n) != null and (info.leaf or focus.takes(n))) info.states.focusable = true;
        const has_focus = if (b.focused) |f| focus.within(f, n) else false;
        // Strings kept with the tree.
        info.name = try b.arena.dupe(u8, info.name);
        info.description = try b.arena.dupe(u8, info.description);
        info.action = try b.arena.dupe(u8, info.action);
        if (info.text) |tx| info.text = try b.arena.dupe(u8, tx);
        if (info.value) |*v| v.text = try b.arena.dupe(u8, v.text);
        if (n.a11y_id == 0) {
            n.a11y_id = b.next_id.*;
            b.next_id.* += 1;
        }
        const pos = n.position();
        const index: u32 = @intCast(b.objects.items.len);
        try b.objects.append(b.arena, .{
            .id = n.a11y_id,
            .info = info,
            .bounds = .{ .x = pos[0], .y = pos[1], .w = n.size.w, .h = n.size.h },
            .parent = parent,
            .children = &.{},
            .node = n,
        });
        try b.kids.append(b.arena, .empty);
        try b.kids.items[parent].append(b.arena, index);
        if (has_focus) b.focused_index = index;
        if (info.leaf) return;
        for (n.children.items) |ch| try b.walk(ch, index, .{});
    }
};
