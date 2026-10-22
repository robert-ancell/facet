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
//! Kete's widgets say what they are (`pub fn accessible(self, n) ?Info`).
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

const Node = widget.WidgetNode;
const Widget = widget.Widget;
const Callback = widget.Callback;
const Rect = geometry.Rect;

/// What an object is: WAI-ARIA 1.2's roles (the concrete ones).
pub const RoleKind = enum {
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
    pub fn childrenPresentational(r: RoleKind) bool {
        return switch (r) {
            .button, .checkbox, .img, .math, .menuitemcheckbox, .menuitemradio, .meter, .option, .progressbar, .radio, .scrollbar, .separator, .slider, .@"switch", .tab => true,
            else => false,
        };
    }
};

/// ARIA's tristate (`aria-checked`, `aria-pressed`).
pub const TristateKind = enum {
    /// Off, unchecked or not pressed.
    false,
    /// On, checked or pressed.
    true,
    /// Neither: some of what it covers is on (a checkbox over others that
    /// are only partly checked).
    mixed,

    pub fn of(v: bool) TristateKind {
        return if (v) .true else .false;
    }
};

/// What a popup it opens is (`aria-haspopup`).
pub const PopupKind = enum {
    /// A menu of actions.
    menu,
    /// A list of options to choose from.
    listbox,
    /// A tree of items.
    tree,
    /// A grid of cells.
    grid,
    /// A dialog.
    dialog,
};

/// Whether an object lies across or up and down (`aria-orientation`): a
/// slider, a scrollbar, a separator, a tab list.
pub const OrientationKind = enum {
    /// Across.
    horizontal,
    /// Up and down.
    vertical,
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

/// What a widget is to assistive technologies: its ARIA role, states and
/// properties (named as ARIA's, without "aria-"; null where it has none),
/// and what kete adds (its text, its action).
pub const Info = struct {
    /// What it is.
    role: RoleKind,
    // Its name and description.
    /// Its name, for assistive technologies (`aria-label`).
    label: []const u8 = "",
    /// A longer description of it (`aria-description`).
    description: []const u8 = "",
    /// What to call its role, if not the role's own name ("map").
    roledescription: []const u8 = "",
    /// A hint of what to enter (`aria-placeholder`).
    placeholder: []const u8 = "",
    /// The keyboard shortcuts that act on it (`aria-keyshortcuts`).
    keyshortcuts: []const u8 = "",
    // States.
    /// Whether it is checked (`aria-checked`).
    checked: ?TristateKind = null,
    /// A toggle button's (a `button` with it is one).
    pressed: ?TristateKind = null,
    /// Whether it is selected (`aria-selected`).
    selected: ?bool = null,
    /// Whether what it controls is shown (`aria-expanded`).
    expanded: ?bool = null,
    /// What kind of popup it opens (`aria-haspopup`).
    haspopup: ?PopupKind = null,
    /// Whether it cannot be used (`aria-disabled`).
    disabled: bool = false,
    /// Whether it can be read but not changed (`aria-readonly`).
    readonly: bool = false,
    /// Whether it has to be filled in (`aria-required`).
    required: bool = false,
    /// Whether what it holds is not valid (`aria-invalid`).
    invalid: bool = false,
    /// Whether it is being updated (`aria-busy`).
    busy: bool = false,
    /// Whether it blocks what is behind it, as a dialog does (`aria-modal`).
    modal: bool = false,
    /// Whether a text box takes more than one line (`aria-multiline`).
    multiline: bool = false,
    /// Whether it lies across or up and down (`aria-orientation`).
    orientation: ?OrientationKind = null,
    /// A heading's level (1 to 6), or a tree item's.
    level: ?u8 = null,
    // A range's value.
    /// A range's value (`aria-valuenow`).
    valuenow: ?f64 = null,
    /// The least a range's value can be (`aria-valuemin`).
    valuemin: ?f64 = null,
    /// The most a range's value can be (`aria-valuemax`).
    valuemax: ?f64 = null,
    /// A range's value written out, if the number is not enough (`aria-valuetext`).
    valuetext: []const u8 = "",

    // Not ARIA's (on the web, the page gives these):
    /// The text it shows or holds (a paragraph's, a text box's), and
    /// where its caret is in it (in characters).
    text: ?[]const u8 = null,
    /// Where the caret is in `text`, in characters.
    caret: ?usize = null,
    /// What pressing it does (its default action), and what setting its
    /// value does, for assistive technologies that do so.
    activate: ?Callback = null,
    /// What setting its value does, for assistive technologies that do so.
    set_value: ?ValueSetter = null,
};

/// Describes what is in it to assistive technologies: as an object of its
/// own (with a `role`), or (without) the objects of the widgets in it,
/// with these properties instead of theirs; or not at all (`hidden`).
/// Its fields are ARIA's states and properties (each one set replaces the
/// widgets'), and kete's own (as `Info`'s).
pub const Accessible = struct {
    /// What something is (`button`, `heading`, `img`...), as ARIA names its roles.
    pub const Role = RoleKind;
    /// On, off or between (`aria-checked`, `aria-pressed`).
    pub const Tristate = TristateKind;
    /// What kind of popup something opens.
    pub const Popup = PopupKind;
    /// Which way something lies.
    pub const Orientation = OrientationKind;

    /// What it is; null to describe the widgets in it instead.
    role: ?RoleKind = null,
    /// Its name, for assistive technologies (`aria-label`).
    label: ?[]const u8 = null,
    /// A longer description of it (`aria-description`).
    description: ?[]const u8 = null,
    /// What to call its role, if not the role's own name ("map"; `aria-roledescription`).
    roledescription: ?[]const u8 = null,
    /// A hint of what to enter (`aria-placeholder`).
    placeholder: ?[]const u8 = null,
    /// The keyboard shortcuts that act on it (`aria-keyshortcuts`).
    keyshortcuts: ?[]const u8 = null,
    /// Whether it is checked (`aria-checked`).
    checked: ?TristateKind = null,
    /// Whether a toggle button is pressed (`aria-pressed`).
    pressed: ?TristateKind = null,
    /// Whether it is selected (`aria-selected`).
    selected: ?bool = null,
    /// Whether what it controls is shown (`aria-expanded`).
    expanded: ?bool = null,
    /// What kind of popup it opens (`aria-haspopup`).
    haspopup: ?PopupKind = null,
    /// Whether it cannot be used (`aria-disabled`).
    disabled: ?bool = null,
    /// Whether it can be read but not changed (`aria-readonly`).
    readonly: ?bool = null,
    /// Whether it has to be filled in (`aria-required`).
    required: ?bool = null,
    /// Whether what it holds is not valid (`aria-invalid`).
    invalid: ?bool = null,
    /// Whether it is being updated (`aria-busy`).
    busy: ?bool = null,
    /// Whether it blocks what is behind it, as a dialog does (`aria-modal`).
    modal: ?bool = null,
    /// Whether a text box takes more than one line (`aria-multiline`).
    multiline: ?bool = null,
    /// Whether it lies across or up and down (`aria-orientation`).
    orientation: ?OrientationKind = null,
    /// A heading's level (1 to 6), or a tree item's (`aria-level`).
    level: ?u8 = null,
    /// A range's value (`aria-valuenow`).
    valuenow: ?f64 = null,
    /// The least a range's value can be (`aria-valuemin`).
    valuemin: ?f64 = null,
    /// The most a range's value can be (`aria-valuemax`).
    valuemax: ?f64 = null,
    /// A range's value written out, if the number is not enough (`aria-valuetext`).
    valuetext: ?[]const u8 = null,
    /// Not reported, nor anything in it (`aria-hidden`).
    hidden: bool = false,
    // Not ARIA's (as `Info`'s).
    /// The text it shows or holds (a paragraph's, a text box's).
    text: ?[]const u8 = null,
    /// What pressing it does (its default action), for assistive technologies that do so.
    on_activate: ?Callback = null,
    /// What setting its value does, for assistive technologies that do so.
    set_value: ?ValueSetter = null,
    /// The widget it describes.
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
    /// Its number (unique in the app: the window's is the one `build` is
    /// given), the same from frame to frame while its widget is there.
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

/// The first window's id (and an app with one window's).
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
pub fn build(gpa: std.mem.Allocator, root: *Node, extra_roots: []const *Node, title: []const u8, size: [2]f32, focused: ?*Node, window: u32, next_id: *u32) error{OutOfMemory}!*Tree {
    const t = try gpa.create(Tree);
    t.* = .{ .arena = .init(gpa) };
    errdefer {
        t.deinit();
        gpa.destroy(t);
    }
    const a = t.arena.allocator();
    var b: Builder = .{ .arena = a, .next_id = next_id, .focused = focused };
    try b.objects.append(a, .{
        .id = window,
        // (No ARIA role: it is the platform's window.)
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
