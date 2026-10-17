//! Facet: a declarative Material 3 UI toolkit for Zig.
//!
//! * `ui` (and top-level re-exports): declarative widget tree, Material 3
//!   widgets, layout, state, damage tracking, and input handling
//! * `gfx`: 2D vector canvas (`Canvas`), glyph `Atlas`, `Image`, generic
//!   `Renderer` interface, and built-in `SoftwareRenderer`, `OpenGlRenderer`,
//!   and `VulkanRenderer` backends
//! * `window`: generic `Window` interface, `Controls`, `InputEvent`,
//!   `Clipboard`, and the built-in `WaylandWindow` client backend
//! * `font`: pure-Zig OpenType/TrueType font parser, shaper, and rasterizer,
//!   including bundled default Fira Sans and Twemoji Mozilla fallback fonts
//! * `icons`: Material Icons enum (`Icon`) and subsetted icon font
//! * `wayland`: zero-dependency Wayland wire protocol and client library

pub const ui = @import("ui");
pub const gfx = @import("gfx");
pub const font = @import("font");
pub const icons = @import("icons");
pub const window = @import("window");
pub const wayland = @import("wayland");

pub const Ui = ui.Ui;
pub const App = ui.App;
pub const Widget = ui.Widget;
pub const Context = ui.Context;
pub const Node = ui.Node;
pub const Event = ui.Event;
pub const Cursor = ui.Cursor;
pub const Callback = ui.Callback;
pub const ValueCallback = ui.ValueCallback;
pub const Painter = ui.Painter;
pub const GpuArea = ui.GpuArea;
pub const Theme = ui.Theme;
pub const Highlight = ui.Highlight;
pub const Clipboard = ui.Clipboard;

pub const Size = ui.Size;
pub const Point = ui.Point;
pub const Rect = ui.Rect;
pub const Constraints = ui.Constraints;
pub const Insets = ui.Insets;
pub const Alignment = ui.Alignment;

pub const Empty = ui.Empty;
pub const SizedBox = ui.SizedBox;
pub const ConstrainedBox = ui.ConstrainedBox;
pub const Padding = ui.Padding;
pub const Align = ui.Align;
pub const Center = ui.Center;
pub const Row = ui.Row;
pub const Column = ui.Column;
pub const Flex = ui.Flex;
pub const Axis = ui.Axis;
pub const Expanded = ui.Expanded;
pub const Grid = ui.Grid;
pub const Overlay = ui.Overlay;
pub const Decorated = ui.Decorated;
pub const Border = ui.Border;
pub const Pressable = ui.Pressable;
pub const Interaction = ui.Interaction;
pub const Draggable = ui.Draggable;
pub const DropTarget = ui.DropTarget;
pub const MainAxisAlignment = ui.MainAxisAlignment;
pub const CrossAxisAlignment = ui.CrossAxisAlignment;
pub const MainAxisSize = ui.MainAxisSize;

pub const Text = ui.Text;
pub const TextStyle = ui.TextStyle;
pub const TextAlign = ui.TextAlign;
pub const OutlinedButton = ui.OutlinedButton;
pub const FilledButton = ui.FilledButton;
pub const TonalButton = ui.TonalButton;
pub const TextButton = ui.TextButton;
pub const IconButton = ui.IconButton;
pub const PillBar = ui.PillBar;
pub const PillButton = ui.PillButton;
pub const Spinner = ui.Spinner;
pub const ProgressBar = ui.ProgressBar;
pub const Slider = ui.Slider;
pub const DropdownMenu = ui.DropdownMenu;
pub const Select = ui.Select;
pub const Divider = ui.Divider;
pub const Card = ui.Card;
pub const ListItem = ui.ListItem;
pub const Chip = ui.Chip;
pub const Badge = ui.Badge;
pub const NavigationRail = ui.NavigationRail;
pub const TabBar = ui.TabBar;
pub const Tab = ui.Tab;
pub const Dialog = ui.Dialog;
pub const Snackbar = ui.Snackbar;
pub const Tooltip = ui.Tooltip;
pub const Checkbox = ui.Checkbox;
pub const Radio = ui.Radio;
pub const Switch = ui.Switch;
pub const TextField = ui.TextField;
pub const TextArea = ui.TextArea;
pub const TextDocument = ui.TextDocument;
pub const Menu = ui.Menu;
pub const MenuItem = ui.MenuItem;
pub const TitleBar = ui.TitleBar;
pub const BarButton = ui.BarButton;
pub const ScrollView = ui.ScrollView;
pub const LazyGrid = ui.LazyGrid;
pub const Icon = ui.Icon;
pub const Image = ui.Image;
pub const QrCode = ui.QrCode;

pub const Renderer = gfx.Renderer;
pub const SoftwareRenderer = gfx.SoftwareRenderer;
pub const OpenGlRenderer = gfx.OpenGlRenderer;
pub const VulkanRenderer = gfx.VulkanRenderer;
pub const Window = window.Window;
pub const WaylandWindow = window.WaylandWindow;
pub const Controls = window.Controls;

test {
    _ = ui;
    _ = gfx;
    _ = font;
    _ = icons;
    _ = window;
    _ = wayland;
}
