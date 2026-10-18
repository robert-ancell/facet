//! Facet's declarative Material 3 widget toolkit. An app describes
//! its UI as a tree of widgets, made again each frame from its state;
//! the toolkit keeps what persists (state, layout) between frames, lays
//! the tree out, paints it with the `gfx` canvas and sends it pointer
//! and keyboard events.
//!
//! There is one kind of widget: any struct. One with `build` is made of
//! other widgets, and one with a `State` type keeps that state between
//! frames (so there is no separate stateless and stateful widget):
//!
//!     const Counter = struct {
//!         label: []const u8,
//!         pub const State = struct {
//!             count: u32 = 0,
//!             fn add(s: *State) void { s.count += 1; }
//!         };
//!         pub fn build(self: *const Counter, cx: *ui.Context, state: *State) ui.Widget {
//!             return cx.make(ui.Row{ .spacing = 12, .children = &.{
//!                 cx.make(ui.Text{ .text = cx.fmt("{s}: {d}", .{ self.label, state.count }) }),
//!                 cx.make(ui.OutlinedButton{ .label = "Add", .on_press = .of(state, State.add) }),
//!             } });
//!         }
//!     };
//!
//! Any struct with `paint` draws whatever it likes: shapes and text on the
//! canvas (`p.canvas()`), or its own draws straight into the target frame
//! (`p.gpu(...)`), layered in the tree's order. `layout` and `event` give it
//! its own size and input.
//!
//! Layout never fails: unbounded space, impossible constraints and
//! children that do not fit all still give a layout. What overflows is
//! clipped and its edges are striped black and yellow. It is better to
//! look wrong than not to work.

pub const geometry = @import("geometry.zig");
pub const widget = @import("widget.zig");
pub const empty = @import("empty.zig");
pub const sized_box = @import("sized_box.zig");
pub const constrained_box = @import("constrained_box.zig");
pub const padding = @import("padding.zig");
pub const @"align" = @import("align.zig");
pub const center = @import("center.zig");
pub const flex = @import("flex.zig");
pub const expanded = @import("expanded.zig");
pub const grid = @import("grid.zig");
pub const overlay = @import("overlay.zig");
pub const decorated = @import("decorated.zig");
pub const pressable = @import("pressable.zig");
pub const drag = @import("drag.zig");
pub const text = @import("text.zig");
pub const theme = @import("theme.zig");
pub const outlined_button = @import("outlined_button.zig");
pub const button = @import("button.zig");
pub const icon_button = @import("icon_button.zig");
pub const pill_bar = @import("pill_bar.zig");
pub const spinner = @import("spinner.zig");
pub const progress_bar = @import("progress_bar.zig");
pub const slider = @import("slider.zig");
pub const dropdown_menu = @import("dropdown_menu.zig");
pub const divider = @import("divider.zig");
pub const card = @import("card.zig");
pub const list_item = @import("list_item.zig");
pub const chip = @import("chip.zig");
pub const badge = @import("badge.zig");
pub const navigation_rail = @import("navigation_rail.zig");
pub const tabs = @import("tabs.zig");
pub const dialog = @import("dialog.zig");
pub const snackbar = @import("snackbar.zig");
pub const tooltip = @import("tooltip.zig");
pub const control = @import("control.zig");
pub const checkbox = @import("checkbox.zig");
pub const radio = @import("radio.zig");
pub const @"switch" = @import("switch.zig");
pub const text_field = @import("text_field.zig");
pub const text_area = @import("text_area.zig");
pub const menu = @import("menu.zig");
pub const title_bar = @import("title_bar.zig");
pub const bar_button = @import("bar_button.zig");
pub const scroll_view = @import("scroll_view.zig");
pub const lazy_grid = @import("lazy_grid.zig");
pub const icon = @import("icon.zig");
pub const image = @import("image.zig");
pub const qr_code = @import("qr_code.zig");
pub const opengl_area = @import("opengl_area.zig");
pub const vulkan_area = @import("vulkan_area.zig");
/// The icons there are (`icons.Icon`), and their font.
pub const icons = @import("icons");
pub const keymap = @import("keymap.zig");
pub const painter = @import("painter.zig");
pub const damage = @import("damage.zig");
pub const runtime = @import("runtime.zig");

pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Constraints = geometry.Constraints;
pub const Insets = geometry.Insets;
pub const Alignment = geometry.Alignment;

pub const Widget = widget.Widget;
pub const Context = widget.Context;
pub const Node = widget.Node;
pub const Event = widget.Event;
pub const Cursor = widget.Cursor;
pub const TextInputInfo = widget.TextInputInfo;
pub const Callback = widget.Callback;
pub const ValueCallback = widget.ValueCallback;

pub const btn_left = widget.btn_left;
pub const btn_right = widget.btn_right;

pub const Empty = empty.Empty;
pub const SizedBox = sized_box.SizedBox;
pub const ConstrainedBox = constrained_box.ConstrainedBox;
pub const Padding = padding.Padding;
pub const Align = @"align".Align;
pub const Center = center.Center;
pub const Row = flex.Row;
pub const Column = flex.Column;
pub const Flex = flex.Flex;
pub const Axis = flex.Axis;
pub const Expanded = expanded.Expanded;
pub const Grid = grid.Grid;
pub const Overlay = overlay.Overlay;
pub const Decorated = decorated.Decorated;
pub const Border = decorated.Border;
pub const Pressable = pressable.Pressable;
pub const Interaction = pressable.Interaction;
pub const Draggable = drag.Draggable;
pub const DropTarget = drag.DropTarget;
pub const MainAxisAlignment = flex.MainAxisAlignment;
pub const CrossAxisAlignment = flex.CrossAxisAlignment;
pub const MainAxisSize = flex.MainAxisSize;

pub const Text = text.Text;
pub const TextStyle = text.TextStyle;
pub const TextAlign = text.TextAlign;

pub const Theme = theme.Theme;
pub const Highlight = theme.Highlight;
pub const OutlinedButton = outlined_button.OutlinedButton;
pub const FilledButton = button.FilledButton;
pub const TonalButton = button.TonalButton;
pub const TextButton = button.TextButton;
pub const IconButton = icon_button.IconButton;
pub const PillBar = pill_bar.PillBar;
pub const PillButton = pill_bar.PillButton;
pub const Spinner = spinner.Spinner;
pub const ProgressBar = progress_bar.ProgressBar;
pub const Slider = slider.Slider;
pub const DropdownMenu = dropdown_menu.DropdownMenu;
pub const Select = dropdown_menu.Select;
pub const Divider = divider.Divider;
pub const Card = card.Card;
pub const ListItem = list_item.ListItem;
pub const Chip = chip.Chip;
pub const Badge = badge.Badge;
pub const NavigationRail = navigation_rail.NavigationRail;
pub const TabBar = tabs.TabBar;
pub const Tab = tabs.Tab;
pub const Dialog = dialog.Dialog;
pub const Snackbar = snackbar.Snackbar;
pub const Tooltip = tooltip.Tooltip;
pub const Checkbox = checkbox.Checkbox;
pub const Radio = radio.Radio;
pub const Switch = @"switch".Switch;
pub const TextField = text_field.TextField;
pub const TextArea = text_area.TextArea;
pub const TextDocument = text_area.Document;
pub const Menu = menu.Menu;
pub const MenuItem = menu.Item;
pub const TitleBar = title_bar.TitleBar;
pub const BarButton = bar_button.BarButton;
pub const ScrollView = scroll_view.ScrollView;
pub const LazyGrid = lazy_grid.LazyGrid;
pub const Icon = icon.Icon;
pub const Image = image.Image;
pub const QrCode = qr_code.QrCode;
pub const OpenGlArea = opengl_area.OpenGlArea;
pub const VulkanArea = vulkan_area.VulkanArea;

pub const Painter = painter.Painter;
pub const GpuArea = painter.GpuArea;
pub const Ui = runtime.Ui;
pub const App = runtime.App;
pub const Clipboard = runtime.Clipboard;

test {
    _ = geometry;
    _ = widget;
    _ = empty;
    _ = sized_box;
    _ = constrained_box;
    _ = padding;
    _ = @"align";
    _ = center;
    _ = flex;
    _ = expanded;
    _ = grid;
    _ = overlay;
    _ = decorated;
    _ = pressable;
    _ = text;
    _ = theme;
    _ = outlined_button;
    _ = button;
    _ = icon_button;
    _ = pill_bar;
    _ = spinner;
    _ = progress_bar;
    _ = slider;
    _ = dropdown_menu;
    _ = divider;
    _ = card;
    _ = list_item;
    _ = chip;
    _ = badge;
    _ = navigation_rail;
    _ = tabs;
    _ = dialog;
    _ = snackbar;
    _ = tooltip;
    _ = control;
    _ = checkbox;
    _ = radio;
    _ = @"switch";
    _ = text_field;
    _ = text_area;
    _ = menu;
    _ = title_bar;
    _ = bar_button;
    _ = scroll_view;
    _ = lazy_grid;
    _ = icon;
    _ = image;
    _ = qr_code;
    _ = opengl_area;
    _ = vulkan_area;
    _ = keymap;
    _ = painter;
    _ = damage;
    _ = runtime;
    _ = @import("tests.zig");
}
