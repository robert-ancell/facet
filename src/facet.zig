//! Facet: a declarative Material 3 UI toolkit for Zig.
//!
//! * `ui` (and top-level re-exports): declarative widget tree, Material 3
//!   widgets, layout, state, damage tracking, and input handling
//! * `gfx`: 2D vector canvas (`Canvas`), glyph `Atlas`, `Image`, generic
//!   `Renderer` interface, and built-in `SoftwareRenderer`, `OpenGlRenderer`,
//!   `VulkanRenderer`, `MetalRenderer` (macOS) and `D3D11Renderer`
//!   (Windows) backends
//! * `window`: generic `Window` interface, `WindowControls`, `InputEvent`,
//!   `Clipboard`, and the built-in backends: `WaylandWindow` (Linux),
//!   `MacWindow` (macOS) and `Win32Window` (Windows), `NativeWindow` being
//!   the one built for
//! * `font`: pure-Zig OpenType/TrueType font parser, shaper, and rasterizer,
//!   including bundled default Fira Sans and Twemoji Mozilla fallback fonts

pub const ui = @import("ui");
pub const gfx = @import("gfx");
pub const font = @import("font");
pub const window = @import("window");

pub const WindowUi = ui.WindowUi;
pub const Shared = ui.Shared;
pub const App = ui.App;
pub const Widget = ui.Widget;
pub const Context = ui.Context;
pub const WidgetAnchor = ui.WidgetAnchor;
pub const BackendInfo = ui.BackendInfo;
pub const WindowInfo = ui.WindowInfo;
pub const WidgetNode = ui.WidgetNode;
pub const Event = ui.Event;
pub const PointerCursor = ui.PointerCursor;
pub const Callback = ui.Callback;
pub const ValueCallback = ui.ValueCallback;
pub const Painter = ui.Painter;
pub const Theme = ui.Theme;
pub const ThemeBrightness = ui.ThemeBrightness;
pub const Themed = ui.Themed;
pub const SyntaxHighlight = ui.SyntaxHighlight;
pub const Clipboard = ui.Clipboard;
pub const Waker = ui.Waker;

pub const Size = ui.Size;
pub const Point = ui.Point;
pub const Rect = ui.Rect;
pub const Constraints = ui.Constraints;
pub const Insets = ui.Insets;
pub const Alignment = ui.Alignment;
pub const Color = gfx.Color;
pub const CornerRadii = gfx.CornerRadii;
pub const PointerButton = ui.PointerButton;
pub const KeyboardKey = ui.KeyboardKey;

pub const SizedBox = ui.SizedBox;
pub const ConstrainedBox = ui.ConstrainedBox;
pub const Padding = ui.Padding;
pub const Align = ui.Align;
pub const Center = ui.Center;
pub const Row = ui.Row;
pub const Column = ui.Column;
pub const Axis = ui.Axis;
pub const Expanded = ui.Expanded;
pub const Grid = ui.Grid;
pub const Overlay = ui.Overlay;
pub const Decorated = ui.Decorated;
pub const Border = ui.Border;
pub const Pressable = ui.Pressable;
pub const PointerInteraction = ui.PointerInteraction;
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
pub const CheckboxRow = ui.CheckboxRow;
pub const Radio = ui.Radio;
pub const RadioRow = ui.RadioRow;
pub const Switch = ui.Switch;
pub const SwitchRow = ui.SwitchRow;
pub const TextField = ui.TextField;
pub const TextArea = ui.TextArea;
pub const TextDocument = ui.TextDocument;
pub const Menu = ui.Menu;
pub const MenuItem = ui.MenuItem;
pub const TitleBar = ui.TitleBar;
pub const BarButton = ui.BarButton;
pub const ScrollView = ui.ScrollView;
pub const Icon = ui.Icon;
pub const IconName = ui.IconName;
pub const Image = ui.Image;
pub const QrCode = ui.QrCode;
pub const Accessible = ui.Accessible;
pub const AccessibleRole = ui.AccessibleRole;
pub const AccessibleTristate = ui.AccessibleTristate;
pub const AccessiblePopup = ui.AccessiblePopup;
pub const AccessibleOrientation = ui.AccessibleOrientation;
pub const AccessibleInfo = ui.AccessibleInfo;
pub const MapView = ui.MapView;
pub const MapSource = ui.MapSource;
pub const MapTile = ui.MapTile;
pub const MapTileId = ui.MapTileId;
pub const MapVectorTile = ui.MapVectorTile;
pub const MapStyle = ui.MapStyle;
pub const MapCamera = ui.MapCamera;
pub const MapProjection = ui.MapProjection;
pub const MapCoordinate = ui.MapCoordinate;
pub const MapTilePainter = ui.MapTilePainter;
pub const MapLabelStyle = ui.MapLabelStyle;
pub const MapNight = ui.MapNight;
pub const AnimatedWidget = ui.AnimatedWidget;
pub const Easing = ui.Easing;
pub const OpenGlArea = ui.OpenGlArea;
pub const VulkanArea = ui.VulkanArea;
pub const MetalArea = ui.MetalArea;
pub const D3D11Area = ui.D3D11Area;

pub const WindowPlatform = window.WindowPlatform;
pub const WindowBufferTransport = window.WindowBufferTransport;
pub const WindowBufferSync = window.WindowBufferSync;
pub const WindowFrameSync = window.WindowFrameSync;
pub const WindowDecorations = window.WindowDecorations;
pub const Window = window.Window;
pub const WindowControls = window.WindowControls;

test {
    _ = ui;
    _ = gfx;
    _ = font;
    _ = window;
}
