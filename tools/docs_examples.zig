//! The examples in the API reference: each widget's doc comment shows one
//! (its code, and the image `docs_images.zig` draws from it). An example
//! is a function that makes the widget, written as an app would: the
//! comment holds a copy of its body, so keep the two the same.

const std = @import("std");
const facet = @import("facet");

const Widget = facet.Widget;
const BuildContext = facet.BuildContext;
const Ui = facet.WindowUi;

/// What the examples' callbacks are: they do nothing.
const State = struct {
    fn save(_: *State) void {}
    fn setOn(_: *State, _: bool) void {}
    fn setAmount(_: *State, _: f32) void {}
    fn select(_: *State, _: usize) void {}
    fn setText(_: *State, _: []const u8) void {}
    fn setQuality(_: *State, _: Quality) void {}
};
var demo_state: State = .{};
const state = &demo_state;

const Quality = enum { low, medium, high };

/// The pixels `photo` is: a gradient.
var photo_pixels: []u32 = &.{};
var photo: facet.gfx.Image = undefined;
var document: facet.TextDocument = undefined;

pub fn init(gpa: std.mem.Allocator) !void {
    const w = 160;
    const h = 100;
    photo_pixels = try gpa.alloc(u32, w * h);
    for (photo_pixels, 0..) |*px, i| {
        const x: u32 = @intCast(i % w);
        const y: u32 = @intCast(i / w);
        px.* = 0xff000000 | ((x * 255 / w) << 16) | ((y * 200 / h) << 8) | 0x90;
    }
    photo = facet.gfx.Image.init(photo_pixels, w, h);
    document = try facet.TextDocument.init(gpa, "const answer = 42;\n\nfn main() void {}");
}

pub fn deinit(gpa: std.mem.Allocator) void {
    gpa.free(photo_pixels);
    document.deinit();
}

/// An example: the widget `name`, from `build`, centred in an image
/// `width` by `height` logical pixels (just big enough for it, if not
/// given).
fn Example(comptime name_: []const u8, comptime build_: fn (*BuildContext) Widget, comptime options: struct {
    width: ?u32 = null,
    height: ?u32 = null,
    /// Done after the first frame (to open a menu, or hover).
    after: ?*const fn (*Ui) void = null,
}) type {
    return struct {
        pub const name = name_;
        pub const width = options.width;
        pub const height = options.height;
        pub const after: ?*const fn (*Ui) void = options.after;
        pub const Root = struct {
            /// Whether it is only to be measured (at its natural size, at
            /// the top left).
            measure: bool = false,

            pub fn build(self: *const Root, cx: *BuildContext) Widget {
                const widget = build_(cx);
                if (self.measure) return cx.make(facet.Align{ .alignment = .top_left, .child = cx.make(facet.Padding{ .padding = .all(16), .child = widget }) });
                return cx.make(facet.Align.center(widget));
            }
        };
    };
}

fn box(cx: *BuildContext, label: []const u8, w: f32, h: f32) Widget {
    const t = cx.theme();
    return cx.make(facet.RoundedBox{
        .color = t.primary_container,
        .radius = .all(8),
        .child = cx.make(facet.SizedBox{ .width = w, .height = h, .child = cx.make(facet.Align.center(cx.make(facet.Text{
            .text = label,
            .style = .{ .color = t.on_primary_container },
            .wrap = false,
        }))) }),
    });
}

// --- Buttons -----------------------------------------------------------------

fn filledButton(cx: *BuildContext) Widget {
    return cx.make(facet.FilledButton{ .label = "Save", .icon = .check, .on_press = .of(state, State.save) });
}

fn tonalButton(cx: *BuildContext) Widget {
    return cx.make(facet.TonalButton{ .label = "Add to cart", .icon = .shopping_cart, .on_press = .of(state, State.save) });
}

fn outlinedButton(cx: *BuildContext) Widget {
    return cx.make(facet.OutlinedButton{ .label = "Cancel", .on_press = .of(state, State.save) });
}

fn textButton(cx: *BuildContext) Widget {
    return cx.make(facet.TextButton{ .label = "Learn more", .trailing_icon = .arrow_forward, .on_press = .of(state, State.save) });
}

fn iconButton(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        facet.IconButton{ .icon = .favorite, .on_press = .of(state, State.save) },
        facet.IconButton{ .icon = .favorite, .variant = .filled, .on_press = .of(state, State.save) },
        facet.IconButton{ .icon = .favorite, .variant = .tonal, .on_press = .of(state, State.save) },
        facet.IconButton{ .icon = .favorite, .variant = .outlined, .selected = true, .on_press = .of(state, State.save) },
    }) });
}

fn pillBar(cx: *BuildContext) Widget {
    return cx.make(facet.PillBar{ .children = cx.makeAll(.{
        facet.PillButton{ .label = "Day", .selected = true, .first = true, .on_press = .of(state, State.save) },
        facet.PillButton{ .label = "Week", .selected = false, .on_press = .of(state, State.save) },
        facet.PillButton{ .label = "Month", .selected = false, .last = true, .on_press = .of(state, State.save) },
    }) });
}

// --- Selection ---------------------------------------------------------------

fn checkbox(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
        facet.Checkbox{ .value = true, .on_changed = .of(state, State.setOn) },
        facet.Checkbox{ .value = false, .on_changed = .of(state, State.setOn) },
    }) });
}

fn checkboxRow(cx: *BuildContext) Widget {
    return cx.make(facet.CheckboxRow{ .value = true, .label = "Send me updates", .on_changed = .of(state, State.setOn) });
}

fn radio(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
        facet.Radio(Quality){ .value = .low, .group_value = .low, .on_changed = .of(state, State.setQuality) },
        facet.Radio(Quality){ .value = .high, .group_value = .low, .on_changed = .of(state, State.setQuality) },
    }) });
}

fn radioRow(cx: *BuildContext) Widget {
    return cx.make(facet.Column{ .fill = false, .cross_axis_alignment = .start, .children = cx.makeAll(.{
        facet.RadioRow(Quality){ .value = .low, .group_value = .medium, .label = "Low", .on_changed = .of(state, State.setQuality) },
        facet.RadioRow(Quality){ .value = .medium, .group_value = .medium, .label = "Medium", .on_changed = .of(state, State.setQuality) },
        facet.RadioRow(Quality){ .value = .high, .group_value = .medium, .label = "High", .on_changed = .of(state, State.setQuality) },
    }) });
}

fn switchWidget(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
        facet.Switch{ .value = true, .on_changed = .of(state, State.setOn) },
        facet.Switch{ .value = false, .on_changed = .of(state, State.setOn) },
    }) });
}

fn switchRow(cx: *BuildContext) Widget {
    return cx.make(facet.SwitchRow{ .value = true, .label = "Wi-Fi", .on_changed = .of(state, State.setOn) });
}

fn slider(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 240, .child = cx.make(facet.Slider{ .value = 0.4, .on_changed = .of(state, State.setAmount) }) });
}

fn dropdownMenu(cx: *BuildContext) Widget {
    return cx.make(facet.DropdownMenu{
        .options = &.{
            .{ .label = "Light", .leading_icon = .light_mode },
            .{ .label = "Dark", .leading_icon = .dark_mode },
            .{ .label = "Automatic", .leading_icon = .settings },
        },
        .selected = 1,
        .on_selected = .of(state, State.select),
        .width = 180,
    });
}

fn select(cx: *BuildContext) Widget {
    return cx.make(facet.Select(Quality){
        .options = &.{
            .labeled(.low, "Low"),
            .labeled(.medium, "Medium"),
            .labeled(.high, "High"),
        },
        .value = .medium,
        .on_changed = .of(state, State.setQuality),
        .width = 180,
    });
}

// --- Text --------------------------------------------------------------------

fn text(cx: *BuildContext) Widget {
    const t = cx.theme();
    return cx.make(facet.SizedBox{ .width = 280, .child = cx.make(facet.Column{ .fill = false, .cross_axis_alignment = .start, .spacing = 8, .children = cx.makeAll(.{
        facet.Text{ .text = "Headline", .style = .{ .size = 28, .color = t.primary }, .wrap = false },
        facet.Text{ .text = "Text wraps to the width it is given, and can be aligned in it." },
    }) }) });
}

fn textField(cx: *BuildContext) Widget {
    return cx.make(facet.Column{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        facet.TextField{ .placeholder = "Search", .on_changed = .of(state, State.setText) },
        facet.TextField{ .initial = "Ada Lovelace", .on_changed = .of(state, State.setText) },
    }) });
}

fn textArea(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 320, .height = 96, .child = cx.make(facet.TextArea{ .doc = &document }) });
}

fn icon(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 16, .children = cx.makeAll(.{
        facet.Icon{ .icon = .home },
        facet.Icon{ .icon = .settings, .size = 32 },
        facet.Icon{ .icon = .favorite, .size = 40, .color = cx.theme().primary },
    }) });
}

fn image(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 160, .height = 100, .child = cx.make(facet.Image{ .source = .{ .image = &photo } }) });
}

fn qrCode(cx: *BuildContext) Widget {
    return cx.make(facet.QrCode{ .text = "https://example.com", .size = 120 });
}

// --- Content -----------------------------------------------------------------

fn card(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        facet.Card{ .child = cx.make(facet.Text{ .text = "Filled", .wrap = false }) },
        facet.Card{ .variant = .elevated, .child = cx.make(facet.Text{ .text = "Elevated", .wrap = false }) },
        facet.Card{ .variant = .outlined, .child = cx.make(facet.Text{ .text = "Outlined", .wrap = false }) },
    }) });
}

fn listItem(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 320, .child = cx.make(facet.Column{ .fill = false, .children = cx.makeAll(.{
        facet.ListItem{ .headline = "Photos", .supporting_text = "Jan 9, 2026", .leading_icon = .image, .trailing_icon = .chevron_right, .on_press = .of(state, State.save) },
        facet.ListItem{ .headline = "Documents", .supporting_text = "Updated yesterday", .leading_icon = .folder, .trailing_text = "12 items", .selected = true, .on_press = .of(state, State.save) },
    }) }) });
}

fn chip(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 8, .children = cx.makeAll(.{
        facet.Chip{ .label = "Filter", .on_press = .of(state, State.save) },
        facet.Chip{ .label = "Selected", .selected = true, .on_press = .of(state, State.save) },
        facet.Chip{ .label = "Remove", .icon = .tag, .on_remove = .of(state, State.save) },
    }) });
}

fn badge(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 24, .children = cx.makeAll(.{
        facet.Badge{ .count = 3, .child = cx.make(facet.Icon{ .icon = .mail }) },
        facet.Badge{ .count = 128, .child = cx.make(facet.Icon{ .icon = .notifications }) },
        facet.Badge{ .label = "", .child = cx.make(facet.Icon{ .icon = .chat }) },
    }) });
}

fn progressBar(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 240, .child = cx.make(facet.ProgressBar{ .value = 0.6 }) });
}

fn spinner(cx: *BuildContext) Widget {
    return cx.make(facet.Spinner{ .size = 40 });
}

fn divider(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 240, .child = cx.make(facet.Column{ .fill = false, .spacing = 8, .children = cx.makeAll(.{
        facet.Text{ .text = "Above" },
        facet.Divider{},
        facet.Text{ .text = "Below" },
    }) }) });
}

// --- Navigation --------------------------------------------------------------

fn navigationRail(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .height = 180, .child = cx.make(facet.NavigationRail{
        .items = &.{
            .{ .label = "Home", .icon = .home },
            .{ .label = "Inbox", .icon = .mail, .badge = 4 },
            .{ .label = "Settings", .icon = .settings },
        },
        .selected = 0,
        .on_select = .of(state, State.select),
        .width = 220,
    }) });
}

fn tabBar(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 480, .child = cx.make(facet.TabBar{
        .tabs = &.{
            .{ .label = "Flights", .icon = .flight },
            .{ .label = "Hotels", .icon = .hotel, .badge = 2 },
            .{ .label = "Cars", .icon = .directions_car },
        },
        .selected = 1,
        .on_select = .of(state, State.select),
    }) });
}

fn titleBar(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 360, .child = cx.make(facet.TitleBar{
        .title = "Untitled",
        .on_close = .of(state, State.save),
        .on_minimize = .of(state, State.save),
        .on_maximize = .of(state, State.save),
        .maximized = false,
    }) });
}

fn barButton(cx: *BuildContext) Widget {
    return cx.make(facet.Row{ .fill = false, .spacing = 8, .children = cx.makeAll(.{
        facet.BarButton{ .icon = .minimize, .size = 34, .on_press = .of(state, State.save) },
        facet.BarButton{ .icon = .close, .size = 34, .on_press = .of(state, State.save) },
    }) });
}

// --- Feedback ----------------------------------------------------------------

fn snackbar(cx: *BuildContext) Widget {
    return cx.make(facet.Snackbar{
        .message = "Message archived",
        .action_label = "Undo",
        .on_action = .of(state, State.save),
        .on_dismiss = .of(state, State.save),
    });
}

fn dialog(cx: *BuildContext) Widget {
    return cx.make(facet.Dialog{
        .icon = .delete,
        .title = "Delete the file?",
        .description = "It will be removed from every device.",
        .confirm_label = "Delete",
        .on_confirm = .of(state, State.save),
        .dismiss_label = "Cancel",
        .on_dismiss = .of(state, State.save),
        .child = cx.make(facet.SizedBox{}),
    });
}

fn tooltip(cx: *BuildContext) Widget {
    return cx.make(facet.Tooltip{
        .text = "Add to favourites",
        .child = cx.make(facet.IconButton{ .icon = .favorite, .variant = .tonal, .on_press = .of(state, State.save) }),
    });
}

fn hoverTooltip(u: *Ui) void {
    const find = struct {
        fn f(n: *facet.WidgetNode) ?*facet.WidgetNode {
            if (n.widget.is(facet.Tooltip)) return n;
            for (n.children.items) |ch| if (f(ch)) |x| return x;
            return null;
        }
    }.f;
    const n = find(u.root.?) orelse return;
    const at = n.position();
    u.pointerMotion(.{ at[0] + n.size.w / 2, at[1] + n.size.h / 2 });
}

fn menu(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{});
}

fn openMenu(u: *Ui) void {
    u.openMenu(u.root.?, .{ 24, 16 }, &.{
        .{ .label = "Cut", .leading_icon = .content_cut, .shortcut = "Ctrl+X", .on_press = .of(state, State.save) },
        .{ .label = "Copy", .leading_icon = .content_copy, .shortcut = "Ctrl+C", .on_press = .of(state, State.save) },
        .{ .label = "Paste", .leading_icon = .content_paste, .shortcut = "Ctrl+V" },
        facet.MenuItem.divider,
        .{ .label = "Sort by", .leading_icon = .sort, .submenu = &.{
            .{ .label = "Name", .kind = .radio, .checked = true, .on_press = .of(state, State.save) },
            .{ .label = "Date", .kind = .radio, .on_press = .of(state, State.save) },
        } },
        .{ .label = "Delete", .leading_icon = .delete, .destructive = true, .on_press = .of(state, State.save) },
    });
}

// --- Layout ------------------------------------------------------------------

fn row(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 320, .child = cx.make(facet.Row{
        .main_axis_alignment = .space_between,
        .cross_axis_alignment = .center,
        .children = cx.makeAll(.{
            box(cx, "A", 48, 48),
            box(cx, "B", 48, 80),
            box(cx, "C", 48, 32),
        }),
    }) });
}

fn column(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .height = 200, .child = cx.make(facet.Column{
        .main_axis_alignment = .space_between,
        .cross_axis_alignment = .start,
        .children = cx.makeAll(.{
            box(cx, "A", 80, 40),
            box(cx, "B", 120, 40),
            box(cx, "C", 60, 40),
        }),
    }) });
}

fn expanded(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 360, .child = cx.make(facet.Row{ .spacing = 8, .children = cx.makeAll(.{
        box(cx, "Fixed", 72, 48),
        facet.Expanded{ .child = box(cx, "Expanded", 0, 48) },
        facet.Expanded{ .flex = 2, .child = box(cx, "Twice as much", 0, 48) },
    }) }) });
}

fn paddingWidget(cx: *BuildContext) Widget {
    return cx.make(facet.RoundedBox{
        .border_color = cx.theme().outline,
        .child = cx.make(facet.Padding{ .padding = .symmetric(32, 12), .child = box(cx, "Padded", 80, 32) }),
    });
}

fn alignWidget(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 240, .height = 120, .child = cx.make(facet.RoundedBox{
        .border_color = cx.theme().outline,
        .child = cx.make(facet.Align{ .alignment = .bottom_right, .child = box(cx, "Corner", 72, 36) }),
    }) });
}

fn sizedBox(cx: *BuildContext) Widget {
    return cx.make(facet.RoundedBox{
        .border_color = cx.theme().outline,
        .child = cx.make(facet.SizedBox{ .width = 160, .height = 64, .child = cx.make(facet.Align.center(cx.make(facet.Text{ .text = "160 by 64", .wrap = false }))) }),
    });
}

fn constrainedBox(cx: *BuildContext) Widget {
    return cx.make(facet.RoundedBox{
        .border_color = cx.theme().outline,
        .child = cx.make(facet.ConstrainedBox{
            .constraints = .{ .min_w = 200, .min_h = 56 },
            .child = box(cx, "Small", 60, 24),
        }),
    });
}

fn roundedBox(cx: *BuildContext) Widget {
    const t = cx.theme();
    return cx.make(facet.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
        facet.RoundedBox{ .color = t.primary_container, .radius = .all(16), .child = cx.make(facet.SizedBox{ .width = 72, .height = 56 }) },
        facet.RoundedBox{ .border_color = t.primary, .border_width = 2, .radius = .all(28), .child = cx.make(facet.SizedBox{ .width = 72, .height = 56 }) },
        facet.RoundedBox{ .color = t.secondary_container, .radius = .{ .tl = 4, .tr = 24, .br = 4, .bl = 24 }, .child = cx.make(facet.SizedBox{ .width = 72, .height = 56 }) },
    }) });
}

fn overlay(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 200, .height = 120, .child = cx.make(facet.Overlay{ .children = cx.makeAll(.{
        facet.Align{ .alignment = .top_left, .child = box(cx, "Behind", 120, 72) },
        facet.Align{ .alignment = .bottom_right, .child = box(cx, "In front", 120, 72) },
    }) }) });
}

fn gridWidget(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 260, .height = 140, .child = cx.make(facet.Grid.fixed(cx, &.{
        box(cx, "1", 0, 0),
        box(cx, "2", 0, 0),
        box(cx, "3", 0, 0),
        box(cx, "4", 0, 0),
        box(cx, "5", 0, 0),
        box(cx, "6", 0, 0),
    }, .{ .w = 80, .h = 60 }, 8)) });
}

fn scrollView(cx: *BuildContext) Widget {
    return cx.make(facet.SizedBox{ .width = 240, .height = 140, .child = cx.make(facet.ScrollView{ .child = cx.make(facet.Column{
        .fill = false,
        .cross_axis_alignment = .stretch,
        .children = cx.makeAll(.{
            facet.ListItem{ .headline = "One" },
            facet.ListItem{ .headline = "Two" },
            facet.ListItem{ .headline = "Three" },
            facet.ListItem{ .headline = "Four" },
            facet.ListItem{ .headline = "Five" },
            facet.ListItem{ .headline = "Six" },
        }),
    }) }) });
}

fn themed(cx: *BuildContext) Widget {
    return cx.make(facet.Themed{ .theme = .dark, .child = cx.make(facet.Card{
        .child = cx.make(facet.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
            facet.Text{ .text = "Dark inside", .wrap = false },
            facet.FilledButton{ .label = "Go", .on_press = .of(state, State.save) },
        }) }),
    }) });
}

/// Every example, in the order of the files they are in.
pub const all = .{
    Example("FilledButton", filledButton, .{}),
    Example("TonalButton", tonalButton, .{}),
    Example("OutlinedButton", outlinedButton, .{}),
    Example("TextButton", textButton, .{}),
    Example("IconButton", iconButton, .{}),
    Example("PillBar", pillBar, .{}),
    Example("Checkbox", checkbox, .{}),
    Example("CheckboxRow", checkboxRow, .{}),
    Example("Radio", radio, .{}),
    Example("RadioRow", radioRow, .{}),
    Example("Switch", switchWidget, .{}),
    Example("SwitchRow", switchRow, .{}),
    Example("Slider", slider, .{}),
    Example("DropdownMenu", dropdownMenu, .{}),
    Example("Select", select, .{}),
    Example("Text", text, .{}),
    Example("TextField", textField, .{}),
    Example("TextArea", textArea, .{}),
    Example("Icon", icon, .{}),
    Example("Image", image, .{}),
    Example("QrCode", qrCode, .{}),
    Example("Card", card, .{}),
    Example("ListItem", listItem, .{}),
    Example("Chip", chip, .{}),
    Example("Badge", badge, .{}),
    Example("ProgressBar", progressBar, .{}),
    Example("Spinner", spinner, .{}),
    Example("Divider", divider, .{}),
    Example("NavigationRail", navigationRail, .{}),
    Example("TabBar", tabBar, .{}),
    Example("TitleBar", titleBar, .{}),
    Example("BarButton", barButton, .{}),
    Example("Snackbar", snackbar, .{}),
    Example("Dialog", dialog, .{ .width = 440, .height = 300 }),
    Example("Tooltip", tooltip, .{ .width = 200, .height = 110, .after = hoverTooltip }),
    Example("Menu", menu, .{ .width = 400, .height = 280, .after = openMenu }),
    Example("Row", row, .{}),
    Example("Column", column, .{}),
    Example("Expanded", expanded, .{}),
    Example("Padding", paddingWidget, .{}),
    Example("Align", alignWidget, .{}),
    Example("SizedBox", sizedBox, .{}),
    Example("ConstrainedBox", constrainedBox, .{}),
    Example("RoundedBox", roundedBox, .{}),
    Example("Overlay", overlay, .{}),
    Example("Grid", gridWidget, .{}),
    Example("ScrollView", scrollView, .{}),
    Example("Themed", themed, .{}),
};
