//! What the UI is to assistive technologies (screen readers, switch
//! access, magnifiers): a tree of objects described in WAI-ARIA's terms
//! (ARIA 1.2, the W3C's vocabulary for accessible widgets, which WCAG's
//! guidance is written in): each has a role (`button`, `checkbox`,
//! `slider`…) and ARIA's states and properties (`label`, `checked`,
//! `expanded`, `valuenow`…), named as ARIA names them without "aria-".
//! It is made from the widgets after each frame and given to the
//! platform's accessibility API as the W3C's Core Accessibility API
//! Mappings say: on Linux, AT-SPI (`atspi.zig`).
//!
//! Facet's widgets say what they are (`pub fn accessible(self, n) ?Info`).
//! Others, and the app's own, are described with `Accessible`:
//!
//!     // A name for a button that only has an icon (aria-label).
//!     cx.make(ui.Accessible{ .label = "Zoom in", .child = cx.make(ui.IconButton{ .icon = .add, ... }) })
//!     // A widget of the app's own, as what it is.
//!     cx.make(ui.Accessible{ .role = .slider, .label = "Volume", .valuenow = 0.8, .valuemin = 0, .valuemax = 1, .child = ... })
//!     // Not there at all (aria-hidden), as decoration.
//!     cx.make(ui.Accessible{ .hidden = true, .child = ... })
//!
//! Widgets that say nothing are left out (as role `none` is), their
//! descendants going in the nearest object above them; those whose role
//! ARIA says has presentational children (a button: its label is its
//! name) have none of theirs reported.
//!
//! What is not ARIA's is only what ARIA leaves to the web page: what a
//! widget holds (its text, and its caret) and what assistive
//! technologies can do with it (press it, set its value).

const std = @import("std");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");

const Node = widget.Node;
const Widget = widget.Widget;
const Callback = widget.Callback;
const Rect = geometry.Rect;

/// What an object is: WAI-ARIA 1.2's roles (the concrete ones).
pub const Role = enum {
    alert,
    alertdialog,
    application,
    article,
    banner,
    blockquote,
    button,
    caption,
    cell,
    checkbox,
    code,
    columnheader,
    combobox,
    complementary,
    contentinfo,
    definition,
    deletion,
    dialog,
    document,
    emphasis,
    feed,
    figure,
    form,
    generic,
    grid,
    gridcell,
    group,
    heading,
    img,
    insertion,
    link,
    list,
    listbox,
    listitem,
    log,
    main,
    marquee,
    math,
    menu,
    menubar,
    menuitem,
    menuitemcheckbox,
    menuitemradio,
    meter,
    navigation,
    /// Not an object at all (`presentation` too): what is in it goes in
    /// the object above.
    none,
    note,
    option,
    paragraph,
    progressbar,
    radio,
    radiogroup,
    region,
    row,
    rowgroup,
    rowheader,
    scrollbar,
    search,
    searchbox,
    separator,
    slider,
    spinbutton,
    status,
    strong,
    subscript,
    superscript,
    @"switch",
    tab,
    table,
    tablist,
    tabpanel,
    term,
    textbox,
    time,
    timer,
    toolbar,
    tooltip,
    tree,
    treegrid,
    treeitem,

    /// Whether ARIA says the role's children are presentational: part of
    /// it (its name comes from them), not objects of their own.
    pub fn childrenPresentational(r: Role) bool {
        return switch (r) {
            .button, .checkbox, .img, .math, .menuitemcheckbox, .menuitemradio, .meter, .option, .progressbar, .radio, .scrollbar, .separator, .slider, .@"switch", .tab => true,
            else => false,
        };
    }
};

/// ARIA's tristate (`aria-checked`, `aria-pressed`).
pub const Tristate = enum {
    false,
    true,
    mixed,

    pub fn of(v: bool) Tristate {
        return if (v) .true else .false;
    }
};

/// What a popup it opens is (`aria-haspopup`).
pub const Popup = enum { menu, listbox, tree, grid, dialog };

pub const Orientation = enum { horizontal, vertical };

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

/// What a widget is to assistive technologies: its ARIA role, states and
/// properties (named as ARIA's, without "aria-"; null where it has none),
/// and what facet adds (its text, its action).
pub const Info = struct {
    role: Role,
    // Its name and description.
    label: []const u8 = "",
    description: []const u8 = "",
    /// What to call its role, if not the role's own name ("map").
    roledescription: []const u8 = "",
    placeholder: []const u8 = "",
    keyshortcuts: []const u8 = "",
    // States.
    checked: ?Tristate = null,
    /// A toggle button's (a `button` with it is one).
    pressed: ?Tristate = null,
    selected: ?bool = null,
    expanded: ?bool = null,
    haspopup: ?Popup = null,
    disabled: bool = false,
    readonly: bool = false,
    required: bool = false,
    invalid: bool = false,
    busy: bool = false,
    modal: bool = false,
    multiline: bool = false,
    orientation: ?Orientation = null,
    /// A heading's level (1 to 6), or a tree item's.
    level: ?u8 = null,
    // A range's value.
    valuenow: ?f64 = null,
    valuemin: ?f64 = null,
    valuemax: ?f64 = null,
    valuetext: []const u8 = "",

    // Not ARIA's (on the web, the page gives these):
    /// The text it shows or holds (a paragraph's, a text box's), and
    /// where its caret is in it (in characters).
    text: ?[]const u8 = null,
    caret: ?usize = null,
    /// What pressing it does (its default action), and what setting its
    /// value does, for assistive technologies that do so.
    activate: ?Callback = null,
    set_value: ?ValueSetter = null,
};

/// Describes what is in it to assistive technologies: as an object of its
/// own (with a `role`), or (without) the objects of the widgets in it,
/// with these properties instead of theirs; or not at all (`hidden`).
/// Its fields are ARIA's states and properties (each one set replaces the
/// widgets'), and facet's own (as `Info`'s).
pub const Accessible = struct {
    /// What it is; null to describe the widgets in it instead.
    role: ?Role = null,
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
    roledescription: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    keyshortcuts: ?[]const u8 = null,
    checked: ?Tristate = null,
    pressed: ?Tristate = null,
    selected: ?bool = null,
    expanded: ?bool = null,
    haspopup: ?Popup = null,
    disabled: ?bool = null,
    readonly: ?bool = null,
    required: ?bool = null,
    invalid: ?bool = null,
    busy: ?bool = null,
    modal: ?bool = null,
    multiline: ?bool = null,
    orientation: ?Orientation = null,
    level: ?u8 = null,
    valuenow: ?f64 = null,
    valuemin: ?f64 = null,
    valuemax: ?f64 = null,
    valuetext: ?[]const u8 = null,
    /// Not reported, nor anything in it (`aria-hidden`).
    hidden: bool = false,
    // Not ARIA's (as `Info`'s).
    text: ?[]const u8 = null,
    on_activate: ?Callback = null,
    set_value: ?ValueSetter = null,
    child: ?Widget = null,

    pub fn accessible(self: *const Accessible, _: *Node) ?Info {
        const role = self.role orelse return null;
        var info: Info = .{ .role = role };
        self.apply(&info);
        return info;
    }

    /// Puts what it says in `info`.
    fn apply(self: *const Accessible, info: *Info) void {
        inline for (@typeInfo(Accessible).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "role") or std.mem.eql(u8, name, "hidden") or
                std.mem.eql(u8, name, "child") or std.mem.eql(u8, name, "on_activate")) continue;
            if (@field(self, name)) |v| @field(info, name) = v;
        }
        if (self.on_activate) |a| info.activate = a;
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
    /// Whether it (or a widget it is made of) takes the keyboard's focus,
    /// and whether it has it.
    focusable: bool = false,
    focused: bool = false,
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
        // (No ARIA role: it is the platform's window, `window_id`.)
        .info = .{ .role = .generic, .label = try a.dupe(u8, title) },
        .focusable = true,
        .bounds = .{ .x = 0, .y = 0, .w = size[0], .h = size[1] },
        .parent = null,
        .children = &.{},
        .node = null,
    });
    try b.kids.append(a, .empty);
    try b.walk(root, 0, .{});
    for (extra_roots) |r| try b.walk(r, 0, .{});
    for (b.objects.items, b.kids.items) |*o, k| o.children = k.items;
    if (b.focused_index) |i| b.objects.items[i].focused = true;
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
            if (info.label.len == 0) info.label = tip else if (info.description.len == 0) info.description = tip;
        }
        if (over.acc) |acc| if (acc != n.widget.as(Accessible)) acc.apply(&info);
        // Role none: no object, what is in it in the one above.
        if (info.role == .none) {
            for (n.children.items) |ch| try b.walk(ch, parent, .{});
            return;
        }
        // What takes the focus (it, or a widget it is made of), and
        // whether it has it: the deepest object the focus is in has.
        const focus = @import("focus.zig");
        const presentational = info.role.childrenPresentational();
        const focusable = focus.first(n) != null and (presentational or focus.takes(n));
        const has_focus = if (b.focused) |f| focus.within(f, n) else false;
        // Strings kept with the tree.
        inline for (.{ "label", "description", "roledescription", "placeholder", "keyshortcuts", "valuetext" }) |name| {
            @field(info, name) = try b.arena.dupe(u8, @field(info, name));
        }
        if (info.text) |tx| info.text = try b.arena.dupe(u8, tx);
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
            .focusable = focusable,
        });
        try b.kids.append(b.arena, .empty);
        try b.kids.items[parent].append(b.arena, index);
        if (has_focus) b.focused_index = index;
        if (presentational) return;
        for (n.children.items) |ch| try b.walk(ch, index, .{});
    }
};
