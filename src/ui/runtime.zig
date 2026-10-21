//! `Ui`: runs a widget tree. Each frame it builds the root widget (keeping
//! the nodes and state that still match), lays it out to the window's
//! size, and paints it; `render` then draws it through the active `gfx.Renderer`
//! (Software, OpenGL, Vulkan, or a custom backend).
//! Pointer events go to the widgets under the pointer, and keys to the
//! widget with the keyboard (`focus`). A menu (`openMenu`) is shown above
//! everything and gets the pointer first; the right button, or a touch held
//! without moving (`long_press_ns`), asks the widget under it for one
//! (`Event.context`).
//!
//! A touch (one at a time) acts as the left button: a tap clicks. One
//! that moves pans: whatever can scroll under it follows it, and nothing is
//! clicked; if nothing can, it drags as the pointer would.
//!
//! Text is copied and pasted through `clipboard` (the system's, which the
//! app or window gives), or within the app if there is none.
//!
//!     const ui = try Ui.createDefault(gpa, io);
//!     defer ui.destroy();
//!     // Each frame:
//!     ui.frame(width, height, now_ns, MyApp{ .title = "Hello" });
//!     try ui.preview(image);

const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const theme_mod = @import("theme.zig");
const image_loader = @import("image_loader.zig");
const Theme = theme_mod.Theme;
const damage_mod = @import("damage.zig");
const keymap = @import("keymap.zig");
const menu_mod = @import("menu.zig");
const drag_mod = @import("drag.zig");
const tooltip_mod = @import("tooltip.zig");
const title_bar_mod = @import("title_bar.zig");
const accessibility = @import("accessibility.zig");
const focus_mod = @import("focus.zig");
const sys = window_mod.sys;
/// AT-SPI is Linux's (on other systems, nothing is offered yet).
const has_atspi = sys.is_linux;
const atspi = if (has_atspi) @import("atspi.zig") else struct {
    pub const Bridge = opaque {};
};

const Point = geometry.Point;
const Size = geometry.Size;
const Constraints = geometry.Constraints;
const Widget = widget.Widget;
const Node = widget.Node;
const Context = widget.Context;
const Event = widget.Event;
const Painter = painter_mod.Painter;
const Segment = painter_mod.Segment;

/// The system's clipboard, for text: `Clipboard.of(&app_clipboard)`, for
/// a type with `copy(self, text)` and `paste(self, sink)`.
pub const Clipboard = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Sink = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, text: ?[]const u8) void,
    };

    pub const VTable = struct {
        copy: *const fn (*anyopaque, []const u8) void,
        paste: *const fn (*anyopaque, Sink) void,
    };

    pub fn of(impl: anytype) Clipboard {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        return .{ .ptr = impl, .vtable = &struct {
            const vtable: VTable = .{ .copy = copy, .paste = paste };
            fn copy(ptr: *anyopaque, text: []const u8) void {
                T.copy(@ptrCast(@alignCast(ptr)), text);
            }
            fn paste(ptr: *anyopaque, sink: Sink) void {
                T.paste(@ptrCast(@alignCast(ptr)), .{ .ctx = sink.ctx, .f = sink.f });
            }
        }.vtable };
    }
};

/// Wakes a `Ui` for a frame from any thread or task: for work done in the
/// background (a fetch started with `io.async`, say), once it has put what
/// it made where the UI will find it. It neither blocks nor allocates, so
/// it can be used from anywhere. From `Ui.waker`; good for as long as the
/// `Ui` is.
pub const Waker = struct {
    wake_: ?sys.Wake = null,
    woken: ?*std.atomic.Value(bool) = null,

    pub fn wake(w: Waker) void {
        if (w.woken) |f| f.store(true, .release);
        if (w.wake_) |x| x.signal();
    }
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    /// What it does its I/O (loading images, the accessibility bus) and
    /// tells the time through: the app's.
    io: std.Io,
    /// Text is drawn in it; without one, text takes no space.
    font: ?*const font.Font,
    owned_font: ?font.Font = null,
    emoji_font: ?font.Font = null,
    /// Icons are drawn with it (see `Icon`).
    icon_font: font.Font,
    theme: Theme = .dark,
    last_surface: ?gfx.Color = null,
    atlas: gfx.Atlas,
    vulkan_renderer: ?gfx.VulkanRenderer = null,
    opengl_renderer: ?gfx.OpenGlRenderer = null,
    metal_renderer: ?gfx.MetalRenderer = null,
    software_renderer: gfx.SoftwareRenderer = .{},
    renderer: ?gfx.Renderer = null,
    owns_renderer: bool = false,
    root: ?*Node = null,
    /// Widgets are made in one while the other holds the last frame's
    /// (which events between frames still use).
    arenas: [2]std.heap.ArenaAllocator,
    frame_no: u64 = 0,
    now_ns: u64 = 0,
    /// Something changed (input, or a widget asked for another frame).
    needs_frame: bool = true,
    /// The frame's drawing: canvases (kept for reuse) and GPU draws.
    canvases: std.ArrayList(*gfx.Canvas) = .empty,
    canvases_used: usize = 0,
    segments: std.ArrayList(Segment) = .empty,
    pointer: ?Point = null,
    /// Event handlers under the pointer, deepest first.
    hovered: std.ArrayList(*Node) = .empty,
    hover_scratch: std.ArrayList(*Node) = .empty,
    /// The handler that took the pointer when a button went down.
    captured: ?*Node = null,
    /// The button that went down when it was taken (only its release
    /// gives it back).
    captured_button: u32 = widget.btn_left,
    /// The last press, to count the clicks of a double click.
    last_press: ?struct { ns: u64, pos: Point, button: u32, clicks: u8 } = null,
    /// The widget keys go to.
    focused: ?*Node = null,
    /// Whether the focus was moved by the keyboard (so its ring shows),
    /// not since the pointer was pressed.
    focus_visible: bool = false,
    /// What had the focus when a menu was opened from the keyboard (it
    /// has it again when the menu closes), and that the menu is to be
    /// given it once it is made.
    focus_before_menu: ?*Node = null,
    menu_focus_pending: bool = false,
    /// The keyboard layout in use (from the window, or `loaded_keymap`).
    keyboard: window_mod.Layout = .{},
    /// A keymap of its own (`loadKeymap`), for keys from `keyEvent` that
    /// say nothing of what they type, and the modifiers it keeps.
    loaded_keymap: ?window_mod.xkb.Keymap = null,
    /// Images loaded in the background (for `Image`).
    images: image_loader.Cache = .{},
    /// Readable when a `Waker` has woken it (made by the first `waker`),
    /// and set (as it might be read by the window's wait first).
    wake: ?sys.Wake = null,
    woken: std.atomic.Value(bool) = .init(false),
    /// What it is to assistive technologies (once `enableAccessibility`
    /// has connected to AT-SPI): the last frame's tree, and the number for
    /// the next object.
    a11y: ?*atspi.Bridge = null,
    a11y_tree: ?*accessibility.Tree = null,
    a11y_next_id: u32 = accessibility.window_id + 1,
    key_state: window_mod.xkb.State = .{},
    /// The window fills the screen: title bars are not drawn.
    fullscreen: bool = false,
    /// Whether the window fills the work area (for `TitleBar`).
    maximized: bool = true,
    /// Whether the window is tiled by the compositor.
    tiled: bool = false,
    /// Active window decoration mode (`none`, `client`, `server`).
    decorations: window_mod.Decorations = .none,
    /// The window attached to the UI, if any.
    win: ?window_mod.Window = null,
    /// What the window's title bar buttons do (set by `attachWindow`).
    controls: ?*window_mod.Controls = null,
    /// Automatic client-side title bar node (used on Wayland when `decorations == .client`).
    title_bar_root: ?*Node = null,
    /// The system's clipboard (the app gives it); without one, text is
    /// copied within the app (`local_clipboard`).
    clipboard: ?Clipboard = null,
    local_clipboard: std.ArrayList(u8) = .empty,
    /// A paste under way: the widget that asked (whose going drops it),
    /// and where the text goes.
    paste: ?struct { owner: *Node, on_text: widget.ValueCallback([]const u8) } = null,
    /// The menu or popup shown, if any.
    menu: ?struct {
        content: union(enum) {
            items: []menu_mod.Item,
            popup: PopupBuilder,
        },
        at: Point,
        owner: *Node,
    } = null,
    menu_root: ?*Node = null,
    /// The menu and tooltip in popups of their own, when the window has
    /// them (`Window.openPopup`); otherwise they are drawn in the window.
    menu_popup: ?PopupLayer = null,
    tooltip_popup: ?PopupLayer = null,
    /// Where the menu and tooltip built this frame want to be, if in popups.
    wanted_menu: ?window_mod.PopupPlacement = null,
    wanted_tooltip: ?window_mod.PopupPlacement = null,
    /// How many of `segments` are the window's (the rest are popups').
    main_segments: usize = 0,
    /// What presents its frames in the window (with `renderer`).
    presenter: window_mod.Presenter = .{},
    /// What is being dragged, if anything (see drag.zig), and the chip
    /// that follows the pointer.
    drag: ?drag_mod.Drag = null,
    drag_root: ?*Node = null,
    drag_scratch: std.ArrayList(*Node) = .empty,
    tooltip_root: ?*Node = null,
    /// A touch held down on a widget, which becomes a long press
    /// (`Event.context`) if it stays there.
    hold: ?struct { node: *Node, pos: Point, since: ?u64 = null } = null,
    /// The touch followed (others are ignored).
    touch: ?struct { id: i32, start: Point, last: Point, moved: bool = false, panning: bool = false } = null,
    /// The release of a press that became a long press is not sent.
    swallow_release: bool = false,
    /// The window's physical buffer size at the last frame (`logical_size * scale`).
    frame_size: [2]u32 = .{ 1, 1 },
    /// The window's logical size at the last frame.
    logical_size: [2]u32 = .{ 1, 1 },
    /// The integer buffer scale factor (1 for standard DPI, 2+ for HiDPI).
    scale: u32 = 1,
    /// The minimum window size required by the widget tree at the last frame
    /// (at least `min_size_floor`).
    min_size: [2]u32 = .{ 1, 1 },
    /// Optional explicit floor for `min_size` (e.g. from `App.Options.min_size`).
    min_size_floor: [2]u32 = .{ 0, 0 },
    /// What changed in the last frame (and the frames before).
    damage: damage_mod.Tracker = .{},
    /// Counts nodes as they are painted (their order is part of what they
    /// draw).
    paint_order: u64 = 0,
    /// How many scroll views are laying out their children.
    scrolling: u32 = 0,

    /// A menu or tooltip in a popup: the window's popup, where it is, and
    /// which of the frame's segments are drawn in it.
    pub const PopupLayer = struct {
        id: u32,
        placement: window_mod.PopupPlacement,
        first: usize = 0,
        end: usize = 0,
        /// What it paints (`paintedHash`), and what it painted when last
        /// drawn: it is drawn again when they differ.
        hash: ?u64 = null,
        drawn_hash: ?u64 = null,
    };

    /// A builder that creates a popup widget each frame while open.
    pub const PopupBuilder = struct {
        ctx: *const anyopaque,
        f: *const fn (ctx: *const anyopaque, cx: *Context) Widget,

        pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *Context) Widget) PopupBuilder {
            return .{ .ctx = ptr, .f = struct {
                fn call(raw: *const anyopaque, cx: *Context) Widget {
                    return f(@ptrCast(@alignCast(@constCast(raw))), cx);
                }
            }.call };
        }
    };

    /// Creates a `Ui` with the given `font` (`null` for no text font; icons
    /// still use the bundled Material Icons font).
    /// Tries initializing the Metal 2D renderer (on macOS), or the Vulkan
    /// one first, then OpenGL (elsewhere), before falling back to Software.
    ///
    /// It does its I/O, and tells the time, through `io`: the app's (as
    /// from `std.process.Init`).
    pub fn create(gpa: std.mem.Allocator, io: std.Io, f: ?*const font.Font) !*Ui {
        const ui = try gpa.create(Ui);
        errdefer gpa.destroy(ui);
        ui.* = .{
            .gpa = gpa,
            .io = io,
            .images = .{ .io = io },
            .font = f,
            .icon_font = try font.Font.init(@import("icons").font_data),
            .atlas = try gfx.Atlas.init(gpa),
            .arenas = .{ .init(gpa), .init(gpa) },
        };
        if (comptime builtin.os.tag == .macos) {
            if (gfx.MetalRenderer.initDefault(gpa)) |mtl| {
                ui.metal_renderer = mtl;
                ui.renderer = ui.metal_renderer.?.renderer();
                ui.owns_renderer = true;
            } else |_| {
                ui.renderer = ui.software_renderer.renderer();
            }
        } else if (comptime builtin.os.tag == .windows) {
            ui.renderer = ui.software_renderer.renderer();
        } else if (gfx.VulkanRenderer.initDefault(gpa)) |vk| {
            ui.vulkan_renderer = vk;
            ui.renderer = ui.vulkan_renderer.?.renderer();
            ui.owns_renderer = true;
        } else |_| if (gfx.OpenGlRenderer.initDefault(gpa)) |gl| {
            ui.opengl_renderer = gl;
            ui.renderer = ui.opengl_renderer.?.renderer();
            ui.owns_renderer = true;
        } else |_| {
            ui.renderer = ui.software_renderer.renderer();
        }
        ui.presenter = .{ .renderer = ui.renderer };
        return ui;
    }

    /// Creates a `Ui` using the bundled default Fira Sans and Twemoji Mozilla
    /// fallback fonts.
    pub fn createDefault(gpa: std.mem.Allocator, io: std.Io) !*Ui {
        return createWithFontData(gpa, io, font.default_font_data);
    }

    /// Creates a `Ui` drawing text in the OpenType or TrueType font in
    /// `data` (which must outlive it), falling back to the bundled Twemoji
    /// Mozilla font for emoji.
    pub fn createWithFontData(gpa: std.mem.Allocator, io: std.Io, data: []const u8) !*Ui {
        const ui = try create(gpa, io, null);
        errdefer ui.destroy();
        ui.owned_font = try font.Font.init(data);
        ui.emoji_font = font.Font.init(font.emoji_font_data) catch null;
        const f = &ui.owned_font.?;
        if (ui.emoji_font) |*ef| f.fallback = ef;
        ui.font = f;
        return ui;
    }

    pub fn destroy(ui: *Ui) void {
        if (ui.win) |w| {
            if (ui.tooltip_popup) |t| w.closePopup(t.id);
            if (ui.menu_popup) |m| w.closePopup(m.id);
        }
        ui.closeMenu();
        ui.endDrag(false);
        if (ui.loaded_keymap) |*km| km.deinit();
        if (ui.title_bar_root) |tb| tb.destroy();
        if (ui.images.waitSource()) |src| if (ui.win) |w| w.watch(src, false);
        ui.images.deinit();
        if (ui.wake) |*x| {
            if (ui.win) |w| w.watch(.ofWake(x), false);
            x.deinit();
        }
        if (has_atspi) if (ui.a11y) |b| {
            if (ui.win) |w| w.watch(b.source(), false);
            b.close();
        };
        if (ui.a11y_tree) |t| {
            t.deinit();
            ui.gpa.destroy(t);
        }
        if (ui.menu_root) |m| m.destroy();
        if (ui.drag_root) |d| d.destroy();
        if (ui.tooltip_root) |t| t.destroy();
        ui.drag_scratch.deinit(ui.gpa);
        if (ui.root) |r| r.destroy();
        ui.local_clipboard.deinit(ui.gpa);
        ui.hovered.deinit(ui.gpa);
        ui.hover_scratch.deinit(ui.gpa);
        for (ui.canvases.items) |c| {
            c.deinit();
            ui.gpa.destroy(c);
        }
        ui.canvases.deinit(ui.gpa);
        ui.segments.deinit(ui.gpa);
        if (ui.owns_renderer) if (ui.renderer) |r| r.deinit();
        ui.atlas.deinit();
        for (&ui.arenas) |*a| a.deinit();
        ui.gpa.destroy(ui);
    }

    /// Attaches a custom or GPU `gfx.Renderer` (e.g. `OpenGlRenderer.renderer()`,
    /// `VulkanRenderer.renderer()`, or `gfx.Renderer.of(&my_backend)`).
    pub fn attachRenderer(ui: *Ui, r: gfx.Renderer, take_ownership: bool) void {
        if (ui.owns_renderer) if (ui.renderer) |old| old.deinit();
        ui.vulkan_renderer = null;
        ui.opengl_renderer = null;
        ui.metal_renderer = null;
        ui.renderer = r;
        ui.owns_renderer = take_ownership;
        ui.presenter = .{ .renderer = r };
    }

    /// Connects the UI's clipboard, keyboard layout, and window state to
    /// `win` (either a `window.Window` or a pointer such as `*window.WaylandWindow`).
    pub fn attachWindow(ui: *Ui, win: anytype, controls: ?*window_mod.Controls) void {
        const w = window_mod.Window.from(win);
        ui.win = w;
        ui.controls = controls;
        ui.syncWindow(w);
    }

    /// Updates the UI's keyboard layout and window state from `win` (the
    /// one place they are copied from the window). A change to how the
    /// window is shown redraws all of it.
    pub fn syncWindow(ui: *Ui, win: anytype) void {
        const w = window_mod.Window.from(win);
        if (ui.loaded_keymap == null) ui.keyboard = w.layout();
        const fullscreen = w.isFullscreen();
        const maximized = w.isMaximized();
        const tiled = w.isTiled();
        const decorations = w.decorations();
        const scale = @max(w.scale(), 1);
        if (fullscreen != ui.fullscreen or maximized != ui.maximized or tiled != ui.tiled or
            decorations != ui.decorations or scale != ui.scale)
        {
            ui.damage.invalidate();
            ui.needs_frame = true;
        }
        ui.fullscreen = fullscreen;
        ui.maximized = maximized;
        ui.tiled = tiled;
        ui.decorations = decorations;
        ui.scale = scale;
    }

    /// True when the toolkit should automatically add a client-side `TitleBar`
    /// above the application's root widget (in a window with client-side
    /// decorations, when not fullscreen).
    pub fn hasClientTitleBar(ui: *const Ui) bool {
        return ui.win != null and ui.decorations == .client and !ui.fullscreen;
    }

    /// Returns information about the active windowing platform, surface buffer
    /// transport, synchronization protocols, and 2D rendering backend.
    pub fn backend(ui: *const Ui) widget.BackendInfo {
        const s = @max(ui.scale, 1);
        const lsize = if (ui.win) |w| w.size() else ui.logical_size;
        return .{
            .platform = if (ui.win) |w| w.platform() else .headless,
            .buffer_transport = if (ui.win) |w| w.bufferTransport() else .memory,
            .buffer_sync = if (ui.win) |w| w.bufferSync() else .none,
            .frame_sync = if (ui.win) |w| w.frameSync() else .{},
            .refresh_hz = if (ui.win) |w| w.refreshHz() else 0.0,
            .extensions = if (ui.win) |w| w.extensions() else &.{},
            .renderer = if (ui.renderer) |r| r.backend() else .software,
            .decorations = ui.decorations,
            .logical_size = lsize,
            .physical_size = .{ lsize[0] * s, lsize[1] * s },
            .scale = s,
            .keyboard = ui.keyboard,
            .maximized = ui.maximized,
            .fullscreen = ui.fullscreen,
            .tiled = ui.tiled,
        };
    }

    /// The pointer cursor shape requested by the currently dragged,
    /// captured, or hovered widget.
    pub fn cursor(ui: *const Ui) widget.Cursor {
        if (ui.drag != null) return .grabbing;
        if (ui.captured) |cap| {
            if (cap.widget.vtable.cursor) |f| {
                const pos = ui.pointer orelse Point{ 0, 0 };
                if (f(cap.widget.ptr, cap, local(cap, pos))) |c| return c;
            }
        }
        if (ui.pointer) |pos| {
            for (ui.hovered.items) |n| {
                if (n.widget.vtable.cursor) |f| {
                    if (f(n.widget.ptr, n, local(n, pos))) |c| return c;
                }
            }
        }
        return .default;
    }

    /// Updates `win`'s cursor shape to match `ui.cursor()`.
    pub fn syncCursor(ui: *const Ui, win: anytype) void {
        window_mod.Window.from(win).setCursor(ui.cursor());
    }

    /// Updates `win`'s minimum size to match `ui.min_size`.
    pub fn syncMinSize(ui: *const Ui, win: anytype) void {
        window_mod.Window.from(win).setMinSize(ui.min_size[0], ui.min_size[1]);
    }

    /// The input method state for the currently focused widget, or null
    /// when no text input widget is focused.
    pub fn textInputState(ui: *const Ui) ?window_mod.TextInputState {
        const n = ui.focused orelse return null;
        const f = n.widget.vtable.text_input orelse return null;
        const info = f(n.widget.ptr, n) orelse return null;
        const origin = n.position();
        const ox: i32 = @intFromFloat(@round(origin[0]));
        const oy: i32 = @intFromFloat(@round(origin[1]));
        return .{
            .surrounding_text = info.surrounding_text,
            .cursor = info.cursor,
            .anchor = info.anchor,
            .change_cause = if (info.change_cause_other) .other else .input_method,
            .password = info.password,
            .multiline = info.multiline,
            .cursor_rect = .{
                ox + info.cursor_rect[0],
                oy + info.cursor_rect[1],
                info.cursor_rect[2],
                info.cursor_rect[3],
            },
        };
    }

    /// Synchronizes `win`'s input method state with the focused widget.
    pub fn syncTextInput(ui: *const Ui, win: anytype) void {
        window_mod.Window.from(win).setTextInput(ui.textInputState());
    }

    /// Something to wake the UI for a frame from another thread or task
    /// (it only marks it to be drawn if there are no fds left).
    pub fn waker(ui: *Ui) Waker {
        if (ui.wake == null) ui.wake = sys.Wake.create() catch return .{ .woken = &ui.woken };
        return .{ .wake_ = ui.wake, .woken = &ui.woken };
    }

    /// What is read when a `Waker` wakes it (to wait on with the window's),
    /// once there is a waker.
    pub fn wakeSource(ui: *Ui) ?window_mod.Source {
        return if (ui.wake) |*x| .ofWake(x) else null;
    }

    /// Takes the wakes since the last time; true if there were any.
    pub fn takeWakes(ui: *Ui) bool {
        const drained = if (ui.wake) |*w| w.drain() else false;
        return ui.woken.swap(false, .acq_rel) or drained;
    }

    /// Now, on the clock frames and input are timed on (`window.nowNs`).
    pub fn clockNs(ui: *const Ui) u64 {
        return window_mod.nowNs(ui.io);
    }

    /// The arena this frame's widgets are made in.
    pub fn arena(ui: *Ui) std.mem.Allocator {
        return ui.arenas[@intCast(ui.frame_no % 2)].allocator();
    }

    /// Builds, lays out and paints a frame with `root` (a widget's value)
    /// filling a `width` by `height` window.
    pub fn frame(ui: *Ui, width: u32, height: u32, now_ns: u64, root: anytype) void {
        ui.frame_no += 1;
        _ = ui.arenas[@intCast(ui.frame_no % 2)].reset(.retain_capacity);
        ui.now_ns = now_ns;
        ui.needs_frame = false;
        ui.checkHold();
        _ = ui.images.collect();
        const s = @max(ui.scale, 1);
        ui.damage.begin(ui.frame_no, width * s, height * s);
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
        const w = cx.make(root);
        if (ui.root) |r| if (r.widget.vtable != w.vtable) {
            r.destroy();
            ui.root = null;
        };
        if (ui.root == null) ui.root = Node.create(ui, w);
        const r = ui.root orelse return;
        r.theme_ptr = null;
        r.build(w);
        const tb = ui.buildTitleBar();
        const tb_min: Size = if (tb) |t| t.minSize(.unbounded) else .{};
        const tb_min_h: f32 = if (tb != null) title_bar_mod.TitleBar.height else 0;
        const min = r.minSize(.unbounded);
        ui.min_size = .{
            @max(ui.min_size_floor[0], @as(u32, @intFromFloat(@ceil(@max(min.w, tb_min.w, 1))))),
            @max(ui.min_size_floor[1], @as(u32, @intFromFloat(@ceil(@max(min.h + tb_min_h, 1))))),
        };
        var w_px = width;
        var h_px = height;
        if (ui.win) |win| {
            ui.syncMinSize(win);
            if (!ui.fullscreen and !ui.maximized and !ui.tiled) {
                w_px = @max(w_px, ui.min_size[0]);
                h_px = @max(h_px, ui.min_size[1]);
            }
            ui.damage.resize(w_px * s, h_px * s);
        }
        if (ui.last_surface == null or !std.meta.eql(ui.last_surface.?, ui.theme.surface)) {
            ui.last_surface = ui.theme.surface;
            ui.damage.invalidate();
        }
        const window: Size = .{ .w = @floatFromInt(w_px), .h = @floatFromInt(h_px) };
        var tb_h: f32 = 0;
        if (tb) |t| {
            const ts = t.layout(.{ .min_w = window.w, .max_w = window.w, .max_h = window.h });
            t.offset = .{ 0, 0 };
            tb_h = ts.h;
        }
        _ = r.layout(.tight(.{ .w = window.w, .h = @max(0, window.h - tb_h) }));
        r.offset = .{ 0, tb_h };
        const m = ui.buildMenu(window);
        const d = ui.buildDrag(window);
        const tt = ui.buildTooltip(window);
        ui.syncPopups(m, tt);
        ui.paint(tb, r, d, m, tt, w_px, h_px);
        if (tb) |n| ui.damage.sweep(n);
        ui.damage.sweep(r);
        if (d) |n| ui.damage.sweep(n);
        if (m) |n| ui.damage.sweep(n);
        if (tt) |n| ui.damage.sweep(n);
        if (ui.pointer) |p| ui.updateHover(p);
        if (ui.win) |win| {
            ui.syncCursor(win);
            ui.syncTextInput(win);
        }
        if (ui.hold != null) ui.needs_frame = true;
        ui.images.evict(now_ns);
        if (ui.menu_focus_pending) if (ui.menu_root) |mr| if (focus_mod.first(mr)) |f| {
            ui.menu_focus_pending = false;
            focus_mod.show(ui, f);
        };
        ui.updateAccessibility();
    }

    /// Offers the UI to assistive technologies (screen readers) over
    /// AT-SPI, if the desktop has its bus (and `NO_AT_BRIDGE` is not set).
    /// Without it, nothing is offered; it can be tried again.
    pub fn enableAccessibility(ui: *Ui, environ: std.process.Environ) void {
        if (!has_atspi) return;
        if (ui.a11y != null) return;
        if (envIs(environ, "NO_AT_BRIDGE", "1")) return;
        const title = if (ui.win) |w| w.title() else "";
        ui.a11y = atspi.Bridge.connect(ui.gpa, ui.io, environ, title) catch null;
        ui.needs_frame = true;
    }

    /// The tree of the frame just made, offered (and what changed in it
    /// told), if it is offered at all.
    fn updateAccessibility(ui: *Ui) void {
        if (!has_atspi) return;
        const b = ui.a11y orelse return;
        const root = ui.root orelse return;
        var extra: [3]*Node = undefined;
        var n: usize = 0;
        for ([_]?*Node{ ui.menu_root, ui.tooltip_root, ui.drag_root }) |r| if (r) |x| {
            extra[n] = x;
            n += 1;
        };
        const title = if (ui.win) |w| w.title() else "";
        const size: [2]f32 = .{ @floatFromInt(ui.logical_size[0]), @floatFromInt(ui.logical_size[1]) };
        const tree = accessibility.build(ui.gpa, root, extra[0..n], title, size, ui.focused, &ui.a11y_next_id) catch return;
        const old = ui.a11y_tree;
        b.update(old, tree);
        ui.a11y_tree = tree;
        if (old) |t| {
            t.deinit();
            ui.gpa.destroy(t);
        }
    }

    /// Answers assistive technologies' calls; true if one did something
    /// (pressed a button), so a frame is needed.
    pub fn dispatchAccessibility(ui: *Ui) bool {
        if (!has_atspi) return false;
        const b = ui.a11y orelse return false;
        const acted = b.dispatch();
        if (acted) ui.needs_frame = true;
        return acted;
    }

    fn buildTitleBar(ui: *Ui) ?*Node {
        if (!ui.hasClientTitleBar()) {
            if (ui.title_bar_root) |n| n.destroy();
            ui.title_bar_root = null;
            return null;
        }
        const title = if (ui.win) |w| w.title() else "";
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
        const w = cx.make(title_bar_mod.TitleBar{ .title = title });
        if (ui.title_bar_root) |tb| if (tb.widget.vtable != w.vtable) {
            tb.destroy();
            ui.title_bar_root = null;
        };
        if (ui.title_bar_root == null) ui.title_bar_root = Node.create(ui, w);
        const n = ui.title_bar_root orelse return null;
        n.theme_ptr = null;
        n.build(w);
        return n;
    }

    fn buildMenu(ui: *Ui, window: Size) ?*Node {
        ui.wanted_menu = null;
        const menu = ui.menu orelse {
            if (ui.menu_root) |n| n.destroy();
            ui.menu_root = null;
            return null;
        };
        // In the theme of the widget that opened it.
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined, .theme_ptr = menu.owner.theme_ptr };
        const w = switch (menu.content) {
            .items => |items| cx.make(menu_mod.Menu{ .items = items }),
            .popup => |popup| popup.f(popup.ctx, &cx),
        };
        if (ui.menu_root) |m| if (m.widget.vtable != w.vtable) {
            m.destroy();
            ui.menu_root = null;
        };
        if (ui.menu_root == null) ui.menu_root = Node.create(ui, w);
        const n = ui.menu_root orelse return null;
        n.theme_ptr = menu.owner.theme_ptr;
        n.build(w);
        const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
        n.offset = menu_mod.place(window, menu.at, size);
        if (ui.usesPopups()) ui.wanted_menu = .{
            .kind = .menu,
            .anchor = .{ @intFromFloat(@round(menu.at[0])), @intFromFloat(@round(menu.at[1])), 1, 1 },
            .size = popupSize(size),
            .side = .below_right,
        };
        return n;
    }

    fn buildDrag(ui: *Ui, window: Size) ?*Node {
        const d = ui.drag orelse {
            if (ui.drag_root) |n| n.destroy();
            ui.drag_root = null;
            return null;
        };
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
        const w = cx.make(drag_mod.Chip{ .label = d.label, .icon = d.icon });
        if (ui.drag_root == null) ui.drag_root = Node.create(ui, w);
        const n = ui.drag_root orelse return null;
        n.theme_ptr = d.source.theme_ptr;
        n.build(w);
        const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
        n.offset = .{
            std.math.clamp(d.pos[0] + 12, 0, @max(0, window.w - size.w)),
            std.math.clamp(d.pos[1] + 16, 0, @max(0, window.h - size.h)),
        };
        return n;
    }

    fn buildTooltip(ui: *Ui, window: Size) ?*Node {
        ui.wanted_tooltip = null;
        if (ui.menu == null and ui.drag == null) {
            for (ui.hovered.items) |target| {
                if (target.laid_out != ui.frame_no) continue;
                const tt = target.widget.as(tooltip_mod.Tooltip) orelse continue;
                if (tt.text.len == 0) continue;
                var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
                const w = cx.make(tooltip_mod.Bubble{ .text = tt.text });
                if (ui.tooltip_root == null) ui.tooltip_root = Node.create(ui, w);
                const n = ui.tooltip_root orelse return null;
                n.theme_ptr = target.theme_ptr;
                n.build(w);
                const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
                const at = target.position();
                n.offset = tooltip_mod.place(window, .{ .x = at[0], .y = at[1], .w = target.size.w, .h = target.size.h }, size);
                if (ui.usesPopups()) ui.wanted_tooltip = .{
                    .kind = .tooltip,
                    .anchor = .{ @intFromFloat(@round(at[0])), @intFromFloat(@round(at[1])), @intFromFloat(@round(target.size.w)), @intFromFloat(@round(target.size.h)) },
                    .size = popupSize(size),
                    .side = .above,
                    .gap = tooltip_mod.gap,
                };
                return n;
            }
        }
        if (ui.tooltip_root) |n| n.destroy();
        ui.tooltip_root = null;
        return null;
    }

    fn paint(ui: *Ui, tb: ?*Node, r: *Node, drag: ?*Node, menu: ?*Node, tooltip: ?*Node, width: u32, height: u32) void {
        ui.paintOnce(tb, r, drag, menu, tooltip, width, height);
        // The glyph atlas filled part way through, so some text is missing
        // glyphs: painted again with it empty, so that the frame is whole.
        // (Otherwise the text would stay that way in this frame's buffer,
        // where nothing changed after, while the window's other buffers
        // show it whole: it would flicker as they take turns.)
        if (ui.atlas.full) ui.paintOnce(tb, r, drag, menu, tooltip, width, height);
    }

    fn paintOnce(ui: *Ui, tb: ?*Node, r: *Node, drag: ?*Node, menu: ?*Node, tooltip: ?*Node, width: u32, height: u32) void {
        ui.atlas.beginFrame();
        ui.canvases_used = 0;
        ui.segments.clearRetainingCapacity();
        const s = @max(ui.scale, 1);
        ui.logical_size = .{ width, height };
        ui.frame_size = .{ width * s, height * s };
        ui.paint_order = 0;
        var p: Painter = .{ .ui = ui, .node = r };
        if (tb) |t| p.paintNode(t);
        p.paintNode(r);
        if (drag) |d| p.paintNode(d);
        if (menu) |m| if (ui.menu_popup == null) p.paintNode(m);
        if (tooltip) |tt| if (ui.tooltip_popup == null) p.paintNode(tt);
        ui.main_segments = ui.segments.items.len;
        if (menu) |m| if (ui.menu_popup) |*layer| ui.paintPopup(m, layer);
        if (tooltip) |tt| if (ui.tooltip_popup) |*layer| ui.paintPopup(tt, layer);
    }

    /// Whether menus and tooltips go in popups of their own.
    fn usesPopups(ui: *const Ui) bool {
        const w = ui.win orelse return false;
        return w.supportsPopups();
    }

    fn popupSize(size: Size) [2]u32 {
        return .{ @intFromFloat(@max(@ceil(size.w), 1)), @intFromFloat(@max(@ceil(size.h), 1)) };
    }

    /// Opens and closes the popups for the menu and tooltip built this
    /// frame (closing first, the newest first, as the window system
    /// requires), and puts the menu and tooltip where their popups are.
    fn syncPopups(ui: *Ui, menu: ?*Node, tooltip: ?*Node) void {
        const w = ui.win orelse return;
        const stale = struct {
            fn f(layer: ?PopupLayer, wanted: ?window_mod.PopupPlacement) bool {
                const l = layer orelse return false;
                const want = wanted orelse return true;
                return !l.placement.eql(want);
            }
        }.f;
        const menu_stale = stale(ui.menu_popup, ui.wanted_menu);
        if (stale(ui.tooltip_popup, ui.wanted_tooltip) or menu_stale) if (ui.tooltip_popup) |t| {
            w.closePopup(t.id);
            ui.tooltip_popup = null;
        };
        if (menu_stale) {
            w.closePopup(ui.menu_popup.?.id);
            ui.menu_popup = null;
        }
        if (ui.wanted_menu) |pl| if (ui.menu_popup == null) {
            if (w.openPopup(pl)) |id| ui.menu_popup = .{ .id = id, .placement = pl };
        };
        if (ui.wanted_tooltip) |pl| if (ui.tooltip_popup == null) {
            if (w.openPopup(pl)) |id| ui.tooltip_popup = .{ .id = id, .placement = pl };
        };
        // Where the window system put them (until it has, where they
        // would go in the window).
        if (menu) |n| if (ui.menu_popup) |l| if (w.popupPosition(l.id)) |at| {
            n.offset = .{ @floatFromInt(at[0]), @floatFromInt(at[1]) };
        };
        if (tooltip) |n| if (ui.tooltip_popup) |l| if (w.popupPosition(l.id)) |at| {
            n.offset = .{ @floatFromInt(at[0]), @floatFromInt(at[1]) };
        };
    }

    /// Paints a menu or tooltip on canvases of its own, its size, with its
    /// top left at the origin.
    fn paintPopup(ui: *Ui, n: *Node, layer: *PopupLayer) void {
        layer.first = ui.segments.items.len;
        _ = ui.newCanvasSized(layer.placement.size);
        var p: Painter = .{ .ui = ui, .node = n, .origin = .{ -n.offset[0], -n.offset[1] }, .track_damage = false };
        p.paintNode(n);
        layer.end = ui.segments.items.len;
        // What a 3D area draws is only known once it has: redraw it always.
        layer.hash = paintedHash(ui.segments.items[layer.first..layer.end]);
        if (layer.hash == null) layer.drawn_hash = null;
    }

    /// What `segments` paint, to tell whether a popup needs drawing again:
    /// null if it cannot be told (they hold GPU areas).
    pub fn paintedHash(segments: []const Segment) ?u64 {
        var h = std.hash.Wyhash.init(0);
        for (segments) |seg| switch (seg) {
            .canvas => |c| for (c.batches.items) |*b| {
                h.update(std.mem.asBytes(&b.kind));
                h.update(std.mem.sliceAsBytes(b.floats.items));
                if (b.clip) |r| h.update(std.mem.asBytes(&r)) else h.update("no clip");
                if (b.image) |img| {
                    // Known by its id: new pixels are a new image.
                    h.update(std.mem.asBytes(&img.id));
                    h.update(std.mem.asBytes(&[_]u32{ img.width, img.height }));
                }
            },
            .gpu => return null,
        };
        return h.final();
    }

    // --- Menus ------------------------------------------------------------------

    pub fn openMenu(ui: *Ui, owner: *Node, at: Point, items: []const menu_mod.Item) void {
        ui.closeMenu();
        ui.focusMenuWhenMade();
        const copy = ui.gpa.dupe(menu_mod.Item, items) catch return;
        ui.menu = .{ .content = .{ .items = copy }, .at = at, .owner = owner };
        ui.needs_frame = true;
    }

    pub fn openPopup(ui: *Ui, owner: *Node, at: Point, popup: PopupBuilder) void {
        ui.closeMenu();
        ui.focusMenuWhenMade();
        ui.menu = .{ .content = .{ .popup = popup }, .at = at, .owner = owner };
        ui.needs_frame = true;
    }

    pub fn closeMenu(ui: *Ui) void {
        const menu = ui.menu orelse return;
        switch (menu.content) {
            .items => |items| ui.gpa.free(items),
            .popup => {},
        }
        ui.menu = null;
        ui.needs_frame = true;
        ui.menu_focus_pending = false;
        // The focus back where it was before the menu (if it is in it).
        if (ui.focus_before_menu) |n| {
            ui.focus_before_menu = null;
            const in_menu = if (ui.focused) |f| if (ui.menu_root) |m| focus_mod.within(f, m) else false else true;
            if (in_menu) ui.focus(n);
        }
    }

    /// A menu opened from the keyboard: it has the focus once it is made,
    /// and gives it back when it closes.
    fn focusMenuWhenMade(ui: *Ui) void {
        if (!ui.focus_visible) return;
        ui.menu_focus_pending = true;
        ui.focus_before_menu = ui.focused;
    }

    // --- Dragging -----------------------------------------------------------------

    pub fn startDrag(ui: *Ui, d: drag_mod.Drag) void {
        ui.endDrag(false);
        var drag = d;
        drag.label = ui.gpa.dupe(u8, d.label) catch return;
        drag.target = null;
        ui.drag = drag;
        ui.moveDrag(d.pos);
    }

    pub fn moveDrag(ui: *Ui, pos: Point) void {
        const d = &(ui.drag orelse return);
        d.pos = pos;
        ui.drag_scratch.clearRetainingCapacity();
        if (ui.root) |r| _ = r.hitTest(.{ pos[0] - r.offset[0], pos[1] - r.offset[1] }, &ui.drag_scratch);
        d.target = drag_mod.targetIn(ui.drag_scratch.items, d.data);
        ui.needs_frame = true;
    }

    pub fn endDrag(ui: *Ui, drop: bool) void {
        const d = ui.drag orelse return;
        ui.drag = null;
        ui.gpa.free(d.label);
        ui.needs_frame = true;
        if (!drop) return;
        const target = d.target orelse return;
        const t = target.widget.as(drag_mod.DropTarget) orelse return;
        if (t.on_drop) |f| f.call(d.data);
    }

    // --- Copy and paste -----------------------------------------------------------

    pub fn copyText(ui: *Ui, text: []const u8) void {
        if (ui.clipboard) |c| return c.vtable.copy(c.ptr, text);
        if (ui.win) |w| if (w.hasClipboard()) return w.copy(text);
        ui.local_clipboard.clearRetainingCapacity();
        ui.local_clipboard.appendSlice(ui.gpa, text) catch {};
    }

    pub fn pasteText(ui: *Ui, owner: *Node, on_text: widget.ValueCallback([]const u8)) void {
        ui.paste = .{ .owner = owner, .on_text = on_text };
        if (ui.clipboard) |c| return c.vtable.paste(c.ptr, .{ .ctx = ui, .f = pasted });
        if (ui.win) |w| if (w.hasClipboard()) return w.paste(.{ .ctx = ui, .f = pasted });
        pasted(ui, if (ui.local_clipboard.items.len > 0) ui.local_clipboard.items else null);
    }

    fn pasted(ctx: *anyopaque, text: ?[]const u8) void {
        const ui: *Ui = @ptrCast(@alignCast(ctx));
        const p = ui.paste orelse return;
        ui.paste = null;
        if (text) |t| p.on_text.call(t);
        ui.needs_frame = true;
    }

    // --- Long presses ---------------------------------------------------------------

    pub const long_press_ns = 500 * std.time.ns_per_ms;
    pub const touch_slop = 8;

    fn checkHold(ui: *Ui) void {
        const h = &(ui.hold orelse return);
        const since = h.since orelse {
            h.since = ui.now_ns;
            return;
        };
        if (ui.now_ns -| since < long_press_ns) return;
        const n = h.node;
        const pos = h.pos;
        ui.hold = null;
        if (send(n, .{ .context = local(n, pos) })) {
            ui.captured = null;
            ui.swallow_release = true;
        }
    }

    pub fn currentCanvas(ui: *Ui) *gfx.Canvas {
        if (ui.segments.items.len > 0) switch (ui.segments.items[ui.segments.items.len - 1]) {
            .canvas => |c| return c,
            .gpu => {},
        };
        return ui.newCanvas() orelse {
            if (ui.canvases.items.len > 0) return ui.canvases.items[0];
            return &scratch_canvas;
        };
    }

    var scratch_canvas: gfx.Canvas = .init(std.heap.page_allocator);

    fn newCanvas(ui: *Ui) ?*gfx.Canvas {
        return ui.newCanvasSized(ui.logical_size);
    }

    fn newCanvasSized(ui: *Ui, size: [2]u32) ?*gfx.Canvas {
        if (ui.canvases_used == ui.canvases.items.len) {
            const c = ui.gpa.create(gfx.Canvas) catch return null;
            c.* = .init(ui.gpa);
            ui.canvases.append(ui.gpa, c) catch {
                ui.gpa.destroy(c);
                return null;
            };
        }
        const c = ui.canvases.items[ui.canvases_used];
        c.beginScaled(size[0], size[1], @max(ui.scale, 1));
        ui.segments.append(ui.gpa, .{ .canvas = c }) catch return null;
        ui.canvases_used += 1;
        return c;
    }

    pub fn addGpu(ui: *Ui, d: painter_mod.GpuDraw) void {
        ui.segments.append(ui.gpa, .{ .gpu = d }) catch {};
    }

    pub fn changed(ui: *const Ui) bool {
        return !ui.damage.frame.isEmpty();
    }

    pub fn damaged(ui: *const Ui) []const geometry.Rect {
        return ui.damage.frame.slice();
    }

    pub fn damagedViewports(ui: *const Ui, out: *[damage_mod.Region.max_rects]gfx.Viewport) []const gfx.Viewport {
        const rects = ui.damaged();
        for (rects, out[0..rects.len]) |r, *v| v.* = .{
            .x = @intFromFloat(r.x),
            .y = @intFromFloat(r.y),
            .width = @intFromFloat(r.w),
            .height = @intFromFloat(r.h),
        };
        return out[0..rects.len];
    }

    pub fn repaint(ui: *const Ui, age: u32) damage_mod.Region {
        return ui.damage.repaint(age);
    }

    pub fn regionViewports(region: *const damage_mod.Region, out: *[damage_mod.Region.max_rects]gfx.Viewport) []const gfx.Viewport {
        for (region.slice(), out[0..region.len]) |r, *v| v.* = .{
            .x = @intFromFloat(r.x),
            .y = @intFromFloat(r.y),
            .width = @intFromFloat(r.w),
            .height = @intFromFloat(r.h),
        };
        return out[0..region.len];
    }

    /// Renders the last painted frame through `ui.renderer` into `target`.
    /// `target` is a pointer to the renderer's target type (`*gfx.software.Image`
    /// for the software renderer); another type is `error.WrongTarget`.
    pub fn render(ui: *Ui, target: anytype, damage: ?[]const gfx.Viewport) !void {
        const r = ui.renderer orelse return error.NoRenderer;
        try r.renderSegments(ui.canvases.items[0..ui.canvases_used], ui.segments.items[0..ui.main_segments], target, damage);
    }

    /// Draws the last painted frame into `img` on the CPU using `gfx.software`.
    pub fn preview(ui: *Ui, img: gfx.software.Image) !void {
        var mutable_img = img;
        for (ui.segments.items) |s| switch (s) {
            .canvas => |c| try gfx.software.render(c, mutable_img),
            .gpu => |g| try g.f(g.ctx, @ptrCast(&mutable_img), g.area),
        };
    }

    /// The frame last painted, to present over `clear` (ARGB): the window's
    /// segments, and what changed in it (see `gfx.Frame`). It is good until
    /// the next `frame`.
    pub fn framePacket(ui: *const Ui, clear: u32) gfx.Frame {
        var f: gfx.Frame = .{
            .canvases = ui.canvases.items[0..ui.canvases_used],
            .segments = ui.segments.items[0..ui.main_segments],
            .clear = clear,
            .damage = damageOf(&ui.damage.frame),
        };
        comptime std.debug.assert(damage_mod.Tracker.history_len + 1 <= gfx.Frame.max_ages);
        comptime std.debug.assert(damage_mod.Region.max_rects <= gfx.frame.Damage.max_rects);
        f.ages = @intCast(ui.damage.known + 1);
        for (f.repaints[0 .. @as(usize, f.ages) + 1], 0..) |*r, age| r.* = damageOf(&ui.damage.repaint(@intCast(age)));
        return f;
    }

    fn damageOf(region: *const damage_mod.Region) gfx.frame.Damage {
        var out: [damage_mod.Region.max_rects]gfx.Viewport = undefined;
        var d: gfx.frame.Damage = .{};
        for (regionViewports(region, &out)) |v| d.add(v);
        return d;
    }

    /// If the last `frame` changed anything, renders only the damaged parts
    /// into `win` (a `window.Window`, or a pointer to a window) and presents it.
    pub fn present(ui: *Ui, win: anytype, clear: u32) !bool {
        const w = window_mod.Window.from(win);
        const popups = try ui.presentPopups(w);
        if (!ui.changed()) return popups;
        const f = ui.framePacket(clear);
        try ui.presenter.present(w, &f);
        return true;
    }

    /// Draws the menu and tooltip popups (whole: they are small).
    fn presentPopups(ui: *Ui, w: window_mod.Window) !bool {
        var shown = false;
        for ([_]*?PopupLayer{ &ui.menu_popup, &ui.tooltip_popup }) |slot| {
            const layer = &(slot.* orelse continue);
            if (layer.end <= layer.first or (layer.hash != null and layer.drawn_hash == layer.hash)) continue;
            const segments = ui.segments.items[layer.first..layer.end];
            var canvases: [16]*const gfx.Canvas = undefined;
            var n: usize = 0;
            for (segments) |s| switch (s) {
                .canvas => |c| if (n < canvases.len) {
                    canvases[n] = c;
                    n += 1;
                },
                .gpu => {},
            };
            const f: gfx.Frame = .{ .canvases = canvases[0..n], .segments = segments, .clear = 0 };
            if (!try ui.presenter.presentPopup(w, layer.id, &f)) {
                ui.needs_frame = true;
                continue;
            }
            layer.drawn_hash = layer.hash;
            shown = true;
        }
        return shown;
    }

    // --- Input ------------------------------------------------------------------

    pub fn handleInput(ui: *Ui, e: window_mod.InputEvent) void {
        switch (e) {
            .motion => |pos| ui.pointerMotion(pos),
            .button => |b| ui.pointerButton(b.pos, b.code, b.pressed),
            .scroll => |s| ui.pointerScroll(s.pos, s.dx, s.dy),
            .key => |k| if (ui.loaded_keymap != null)
                ui.keyEvent(k.code, k.pressed)
            else
                ui.key(.{ .code = k.code, .pressed = k.pressed, .char = k.char, .shift = k.shift, .ctrl = k.ctrl }),
            .leave => ui.pointerLeave(),
            .touch_down => |t| ui.touchDown(t.id, t.pos),
            .touch_motion => |t| ui.touchMotion(t.id, t.pos),
            .touch_up => |id| ui.touchUp(id),
            .touch_cancel => ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
            .text_commit => |*c| if (ui.focused) |n| {
                _ = send(n, .{ .text_commit = c.slice() });
                ui.needs_frame = true;
            },
            .text_preedit => |*p| if (ui.focused) |n| {
                _ = send(n, .{ .text_preedit = .{ .text = p.slice(), .cursor_begin = p.cursor_begin, .cursor_end = p.cursor_end } });
                ui.needs_frame = true;
            },
            .text_delete_surrounding => |d| if (ui.focused) |n| {
                _ = send(n, .{ .text_delete_surrounding = .{ .before_length = d.before_length, .after_length = d.after_length } });
                ui.needs_frame = true;
            },
            .drag_enter, .drag_motion, .drop => |pos| {
                ui.pointer = pos;
                ui.updateHover(pos);
            },
            .drag_leave => ui.pointerLeave(),
            .popup_done => |id| {
                // The window system closed it: a menu goes; a tooltip
                // comes back next frame if it is still wanted.
                if (ui.menu_popup) |m| if (m.id == id) {
                    if (ui.tooltip_popup) |t| if (ui.win) |w| {
                        w.closePopup(t.id);
                        ui.tooltip_popup = null;
                    };
                    if (ui.win) |w| w.closePopup(id);
                    ui.menu_popup = null;
                    ui.closeMenu();
                };
                if (ui.tooltip_popup) |t| if (t.id == id) {
                    if (ui.win) |w| w.closePopup(id);
                    ui.tooltip_popup = null;
                    ui.needs_frame = true;
                };
            },
        }
    }

    pub fn takeInput(ui: *Ui, win: anytype) void {
        const w = window_mod.Window.from(win);
        ui.syncWindow(w);
        for (w.takeInput()) |e| ui.handleInput(e);
        ui.syncCursor(w);
    }

    pub fn pointerMotion(ui: *Ui, pos: Point) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        for (ui.hovered.items) |n| if (send(n, .{ .motion = local(n, pos) })) {
            ui.needs_frame = true;
        };
        if (ui.captured) |n| if (std.mem.indexOfScalar(*Node, ui.hovered.items, n) == null) {
            if (send(n, .{ .motion = local(n, pos) })) ui.needs_frame = true;
        };
        if (ui.win) |win| ui.syncCursor(win);
    }

    /// Presses this close together, in time and space, are one double
    /// (or triple...) click.
    pub const multi_click_ns = 400 * std.time.ns_per_ms;
    pub const multi_click_slop = 6;

    pub fn pointerButton(ui: *Ui, pos: Point, button: u32, pressed: bool) void {
        ui.pointerButtonAt(pos, button, pressed, ui.clockNs());
    }

    /// `pointerButton`, at a time on the monotonic clock (`window.nowNs`).
    pub fn pointerButtonAt(ui: *Ui, pos: Point, button: u32, pressed: bool, now_ns: u64) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        ui.needs_frame = true;
        defer if (ui.win) |win| ui.syncCursor(win);
        if (pressed) {
            // The pointer's: the focus ring goes.
            ui.focus_visible = false;
            if (ui.captured != null) return;
            if (ui.menu != null and !ui.overMenu()) {
                ui.closeMenu();
                return;
            }
            const clicks: u8 = if (ui.last_press) |last| if (last.button == button and
                now_ns -| last.ns <= multi_click_ns and
                @abs(pos[0] - last.pos[0]) <= multi_click_slop and
                @abs(pos[1] - last.pos[1]) <= multi_click_slop) last.clicks +| 1 else 1 else 1;
            ui.last_press = .{ .ns = now_ns, .pos = pos, .button = button, .clicks = clicks };
            if (ui.focused) |f| if (std.mem.indexOfScalar(*Node, ui.hovered.items, f) == null) ui.focus(null);
            if (button == widget.btn_right) for (ui.hovered.items) |n| if (send(n, .{ .context = local(n, pos) })) return;
            for (ui.hovered.items) |n| if (send(n, .{ .press = .{ .pos = local(n, pos), .button = button, .clicks = clicks } })) {
                ui.captured = n;
                ui.captured_button = button;
                return;
            };
        } else if (ui.swallow_release) {
            ui.swallow_release = false;
            ui.hold = null;
        } else if (ui.captured) |n| {
            if (button != ui.captured_button) return;
            ui.hold = null;
            ui.captured = null;
            const inside = std.mem.indexOfScalar(*Node, ui.hovered.items, n) != null;
            _ = send(n, .{ .release = .{ .pos = local(n, pos), .button = button, .inside = inside } });
        }
    }

    // --- Touch ----------------------------------------------------------------------

    pub fn touchDown(ui: *Ui, id: i32, pos: Point) void {
        if (ui.touch != null) return;
        ui.touch = .{ .id = id, .start = pos, .last = pos };
        ui.pointerButton(pos, widget.btn_left, true);
        if (ui.captured) |n| ui.hold = .{ .node = n, .pos = pos };
    }

    pub fn touchMotion(ui: *Ui, id: i32, pos: Point) void {
        const t = &(ui.touch orelse return);
        if (t.id != id) return;
        if (ui.swallow_release) return;
        if (!t.moved and @abs(pos[0] - t.start[0]) <= touch_slop and @abs(pos[1] - t.start[1]) <= touch_slop) return;
        const first = !t.moved;
        t.moved = true;
        ui.hold = null;
        const dx = t.last[0] - pos[0];
        const dy = t.last[1] - pos[1];
        t.last = pos;
        if (t.panning) {
            _ = ui.pan(t.start, dx, dy);
            return;
        }
        if (first and ui.pan(t.start, dx, dy)) {
            t.panning = true;
            ui.cancelPress();
            return;
        }
        ui.pointerMotion(pos);
    }

    pub fn touchUp(ui: *Ui, id: i32) void {
        const t = ui.touch orelse return;
        if (t.id != id) return;
        if (!t.panning) ui.pointerButton(t.last, widget.btn_left, false);
        ui.touch = null;
        ui.hold = null;
        ui.swallow_release = false;
        ui.pointerLeave();
    }

    pub fn touchCancel(ui: *Ui) void {
        ui.cancelPress();
        ui.touch = null;
        ui.hold = null;
        ui.swallow_release = false;
        ui.pointerLeave();
    }

    fn pan(ui: *Ui, at: Point, dx: f32, dy: f32) bool {
        ui.updateHover(at);
        for (ui.hovered.items) |n| if (send(n, .{ .scroll = .{ .pos = local(n, at), .dx = dx, .dy = dy, .touch = true } })) {
            ui.needs_frame = true;
            return true;
        };
        return false;
    }

    fn cancelPress(ui: *Ui) void {
        const n = ui.captured orelse return;
        ui.captured = null;
        _ = send(n, .{ .release = .{ .pos = .{ -1, -1 }, .button = ui.captured_button, .inside = false } });
        ui.needs_frame = true;
    }

    pub fn pointerScroll(ui: *Ui, pos: Point, dx: f32, dy: f32) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        for (ui.hovered.items) |n| if (send(n, .{ .scroll = .{ .pos = local(n, pos), .dx = dx, .dy = dy } })) {
            ui.needs_frame = true;
            return;
        };
    }

    pub fn focus(ui: *Ui, n: ?*Node) void {
        if (ui.focused == n) return;
        if (ui.focused) |old| _ = send(old, .blur);
        ui.focused = n;
        if (n) |new| _ = send(new, .focus);
        ui.needs_frame = true;
    }

    /// Gives it a keymap of its own (XKB's text format), for keys from
    /// `keyEvent`: what they type, and the modifiers they change. (Keys from
    /// a window with a keymap come with what they type.)
    pub fn loadKeymap(ui: *Ui, text: []const u8) !void {
        var km = try window_mod.xkb.Keymap.parse(ui.gpa, text);
        if (ui.loaded_keymap) |*old| old.deinit();
        ui.loaded_keymap = km;
        ui.key_state = .{};
        ui.keyboard = .init(km.layoutName(.{}), km.layoutCode(.{}));
    }

    /// A key went down or up: what it types, by `loaded_keymap` if it has
    /// one.
    pub fn keyEvent(ui: *Ui, code: u32, pressed: bool) void {
        const km = &(ui.loaded_keymap orelse return ui.key(.{ .code = code, .pressed = pressed }));
        const mods = ui.key_state.mods();
        const char = if (pressed) km.char(code, ui.key_state) else null;
        km.update(&ui.key_state, code, pressed);
        ui.key(.{
            .code = code,
            .pressed = pressed,
            .char = char,
            .shift = mods & window_mod.xkb.shift_mask != 0,
            .ctrl = mods & window_mod.xkb.control_mask != 0,
        });
    }

    /// A key went down or up, with what it types (if anything) and the
    /// modifiers held.
    pub fn key(ui: *Ui, k: widget.Event.Key) void {
        switch (k.code) {
            // Modifiers only change what other keys do.
            keymap.left_shift, keymap.right_shift, keymap.left_ctrl, keymap.right_ctrl, keymap.right_alt => return,
            keymap.escape => if (k.pressed and ui.menu != null) {
                ui.closeMenu();
                return;
            },
            else => {},
        }
        ui.needs_frame = true;
        // Tab moves the focus (Control and Tab, from what takes Tab).
        if (k.code == keymap.tab) {
            const takes_tab = if (ui.focused) |f| f.widget.vtable.takes_tab else false;
            if (k.ctrl or !takes_tab) {
                if (k.pressed) _ = focus_mod.move(ui, !k.shift);
                return;
            }
        }
        var e = k;
        // Control and a key is a shortcut, not typing.
        if (!k.pressed or k.ctrl) e.char = null;
        // To what has the focus, then what that is in, until one takes it.
        var at = ui.focused;
        while (at) |n| : (at = n.parent) if (send(n, .{ .key = e })) return;
        if (!k.pressed) return;
        switch (k.code) {
            // Escape dismisses the dialog in front.
            keymap.escape => if (ui.root) |r| if (focus_mod.topDialog(r)) |d| {
                if (d.widget.as(@import("dialog.zig").Dialog).?.on_dismiss) |f| f.call();
            },
            // Up and down move through a menu.
            keymap.up, keymap.down => if (ui.menu != null) {
                _ = focus_mod.move(ui, k.code == keymap.down);
            },
            else => {},
        }
    }

    pub fn pointerLeave(ui: *Ui) void {
        ui.cancelPress();
        ui.hold = null;
        ui.swallow_release = false;
        ui.pointer = null;
        for (ui.hovered.items) |n| _ = send(n, .leave);
        ui.hovered.clearRetainingCapacity();
        if (ui.win) |win| ui.syncCursor(win);
        ui.needs_frame = true;
    }

    fn updateHover(ui: *Ui, pos: Point) void {
        var path = ui.hover_scratch;
        path.clearRetainingCapacity();
        if (ui.menu != null) {
            if (ui.menu_root) |m| _ = m.hitTest(.{ pos[0] - m.offset[0], pos[1] - m.offset[1] }, &path);
        } else {
            var hit = false;
            if (ui.title_bar_root) |tb| {
                hit = tb.hitTest(.{ pos[0] - tb.offset[0], pos[1] - tb.offset[1] }, &path);
            }
            if (!hit) {
                if (ui.root) |r| _ = r.hitTest(.{ pos[0] - r.offset[0], pos[1] - r.offset[1] }, &path);
            }
        }
        for (ui.hovered.items) |n| if (std.mem.indexOfScalar(*Node, path.items, n) == null) {
            _ = send(n, .leave);
            ui.needs_frame = true;
        };
        for (path.items) |n| if (std.mem.indexOfScalar(*Node, ui.hovered.items, n) == null) {
            _ = send(n, .enter);
            ui.needs_frame = true;
        };
        ui.hover_scratch = ui.hovered;
        ui.hovered = path;
    }

    fn send(n: *Node, e: Event) bool {
        const f = n.widget.vtable.event orelse return false;
        return f(n.widget.ptr, n, e);
    }

    fn local(n: *const Node, pos: Point) Point {
        const at = n.position();
        return .{ pos[0] - at[0], pos[1] - at[1] };
    }

    fn overMenu(ui: *const Ui) bool {
        const m = ui.menu_root orelse return false;
        const pos = ui.pointer orelse return false;
        const x = pos[0] - m.offset[0];
        const y = pos[1] - m.offset[1];
        return x >= 0 and y >= 0 and x < m.size.w and y < m.size.h;
    }

    pub fn forget(ui: *Ui, n: *Node) void {
        if (ui.menu) |m| if (m.owner == n) ui.closeMenu();
        if (ui.drag) |*d| {
            if (d.source == n) ui.endDrag(false) else if (d.target == n) d.target = null;
        }
        if (ui.paste) |p| if (p.owner == n) {
            ui.paste = null;
        };
        if (ui.hold) |h| if (h.node == n) {
            ui.hold = null;
        };
        if (ui.captured == n) ui.captured = null;
        if (ui.focused == n) ui.focused = null;
        if (ui.focus_before_menu == n) ui.focus_before_menu = null;
        if (std.mem.indexOfScalar(*Node, ui.hovered.items, n)) |i| _ = ui.hovered.orderedRemove(i);
    }
};

/// A native toolkit app: a window (the system's own, a `NativeWindow`,
/// unless given one), its `Controls`, and a `Ui`. The app runs it in a
/// loop of its own:
///
///     while (try app.step(std.math.maxInt(u64))) {
///         app.takeInput();
///         try app.draw(Root{ .state = &state });
///     }
///
/// It does its I/O, waits, and tells the time through the `std.Io` it is
/// given (the app's, as from `std.process.Init`), so other tasks on it go
/// on while `step` waits: a fetch started with `io.async`, which wakes
/// the UI (`Ui.waker`) when it is done.
/// Whether environment variable `key` is `value` (both ASCII).
fn envIs(environ: std.process.Environ, comptime key: []const u8, comptime value: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const v = environ.getWindows(std.unicode.utf8ToUtf16LeStringLiteral(key)) orelse return false;
        if (v.len != value.len) return false;
        for (v, value) |a, b| if (a != b) return false;
        return true;
    }
    const v = environ.getPosix(key) orelse return false;
    return std.mem.eql(u8, v, value);
}

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    win: window_mod.Window,
    /// Whether `close` closes `win` (it was opened by `open`).
    owns_window: bool = false,
    controls: window_mod.Controls,
    ui: *Ui,
    clear_color: ?u32 = null,
    appearance: theme_mod.Settings = .{},
    theme_watch: theme_mod.Watch = .{},
    /// The system's appearance (dark or not) when last seen, for windows
    /// that say (macOS): the theme follows it when it changes.
    system_dark: ?bool = null,
    dirty: bool = true,
    /// Whether the window waits on the image loader, the `Waker`s, and the
    /// accessibility bus.
    watching_images: bool = false,
    watching_wake: bool = false,
    watching_a11y: bool = false,
    /// Each frame's timings written to stderr (`FACET_TRACE=1`), and when
    /// the last was begun.
    trace: bool = false,
    last_frame_ns: u64 = 0,
    /// A frame is being drawn because the window asked (from inside the
    /// window system's loop, which holds the app's).
    held: bool = false,
    /// The last `draw` showed nothing, so `step` waits rather than going
    /// straight on to draw again.
    idle: bool = false,
    suspended: bool = false,
    /// The root last drawn, kept to draw again when the window asks (see
    /// `window.Window.setRedraw`), and whether a frame is being drawn.
    kept_root: ?KeptRoot = null,
    drawing: bool = false,

    const KeptRoot = struct {
        ptr: *anyopaque,
        draw: *const fn (a: *App, ptr: *anyopaque) anyerror!void,
        free: *const fn (gpa: std.mem.Allocator, ptr: *anyopaque) void,
    };

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = .{ 1280, 720 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
        /// The OpenType or TrueType font text is drawn in (the file's
        /// bytes, which must outlive the app); the bundled Fira Sans if
        /// null.
        font_data: ?[]const u8 = null,
        clear_color: ?u32 = null,
    };

    /// Opens a window of the system's (connecting to the Wayland compositor
    /// in `environ`, on Linux; AppKit's, on macOS) and makes an app in it
    /// (see `openIn`), both doing their I/O through `io`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !*App {
        const win = try window_mod.NativeWindow.open(gpa, io, environ, .{
            .title = options.title,
            .app_id = options.app_id,
            .size = options.size,
            .min_size = options.min_size,
            .maximized = options.maximized,
        });
        errdefer win.close();
        const a = try openIn(gpa, io, win, options);
        a.owns_window = true;
        a.ui.enableAccessibility(environ);
        a.trace = envIs(environ, "FACET_TRACE", "1");
        return a;
    }

    /// Makes an app in `win` (a `window.Window`, or a pointer to a window
    /// `Window.of` takes), which stays the caller's to close after the
    /// app. Of `options`, only `min_size`, `font_data` and `clear_color`
    /// apply: the window is already open. The app does its I/O through
    /// `io` (the window, through its own).
    pub fn openIn(gpa: std.mem.Allocator, io: std.Io, win: anytype, options: Options) !*App {
        const w = window_mod.Window.from(win);
        const ui = if (options.font_data) |data| try Ui.createWithFontData(gpa, io, data) else try Ui.createDefault(gpa, io);
        errdefer ui.destroy();
        const a = try gpa.create(App);
        a.* = .{
            .gpa = gpa,
            .io = io,
            .win = w,
            .controls = .init(w),
            .ui = ui,
            .clear_color = options.clear_color,
            .appearance = theme_mod.loadSettings(io),
        };
        _ = a.theme_watch.changed(io);
        _ = a.followSystem();
        ui.theme = a.appearance.theme.scheme();
        ui.min_size_floor = options.min_size orelse .{ 0, 0 };
        ui.attachWindow(w, &a.controls);
        w.setRedraw(.{ .ctx = a, .f = redraw });
        return a;
    }

    pub fn close(a: *App) void {
        a.win.setRedraw(null);
        if (a.kept_root) |k| k.free(a.gpa, k.ptr);
        a.ui.destroy();
        if (a.owns_window) a.win.close();
        a.gpa.destroy(a);
    }

    /// Takes the system's appearance, if the window says what it is and it
    /// has changed since last seen; true if it had.
    fn followSystem(a: *App) bool {
        const dark = a.win.prefersDark() orelse return false;
        if (a.system_dark == dark) return false;
        a.system_dark = dark;
        a.appearance.theme = if (dark) .dark else .light;
        return true;
    }

    pub fn setTheme(a: *App, mode: theme_mod.Mode) void {
        a.appearance.theme = mode;
        a.ui.theme = mode.scheme();
        _ = a.theme_watch.changed(a.io);
        a.dirty = true;
    }

    /// Waits until there is something to do: a frame to draw that the
    /// window is ready for, or something from the window (or, with nothing
    /// to draw, `idle_timeout_ns`); then brings the UI up to date with the
    /// window. False when the app should end.
    ///
    /// A frame is drawn only once the window has shown the last one, so
    /// that it is drawn for the time it will be shown, not a frame early.
    ///
    /// It waits through the app's `std.Io`, so other tasks on it go on
    /// meanwhile; `error.Canceled` if this task is canceled.
    pub fn step(a: *App, idle_timeout_ns: u64) !bool {
        // Woken when an image is loaded, as by the window's events.
        if (!a.watching_images) if (a.ui.images.waitSource()) |src| {
            a.win.watch(src, true);
            a.watching_images = true;
        };
        if (!a.watching_wake) if (a.ui.wakeSource()) |src| {
            a.win.watch(src, true);
            a.watching_wake = true;
        };
        if (has_atspi and !a.watching_a11y) if (a.ui.a11y) |b| {
            a.win.watch(b.source(), true);
            a.watching_a11y = true;
        };
        if (!a.wantsFrame() or a.idle or a.win.isFramePending()) {
            const refresh = a.win.refreshNs();
            const frame_ns = if (refresh > 0) refresh else 16 * std.time.ns_per_ms;
            try a.win.wait(if (a.wantsFrame()) frame_ns else idle_timeout_ns);
        } else {
            try a.win.poll();
        }
        if (a.win.isClosed() or a.controls.quit) return false;
        if (a.ui.images.collect()) a.dirty = true;
        if (a.ui.takeWakes()) a.dirty = true;
        if (a.ui.dispatchAccessibility()) a.dirty = true;
        if (try a.win.applyConfigure() != null) a.dirty = true;
        const suspended = a.win.isSuspended();
        if (suspended != a.suspended) {
            a.suspended = suspended;
            if (suspended) a.win.releaseSpareBuffers() else a.dirty = true;
        }
        if (a.theme_watch.changed(a.io)) {
            a.appearance = theme_mod.loadSettings(a.io);
            a.ui.theme = a.appearance.theme.scheme();
            a.dirty = true;
        }
        if (a.followSystem()) {
            a.ui.theme = a.appearance.theme.scheme();
            a.dirty = true;
        }
        a.ui.syncWindow(a.win);
        return true;
    }

    pub fn takeInput(a: *App) void {
        a.ui.takeInput(a.win);
    }

    /// Whether there is a frame to draw: the window shows, and something
    /// changed or a widget asked for one.
    fn wantsFrame(a: *const App) bool {
        return !a.suspended and (a.dirty or a.ui.needs_frame);
    }

    /// Draws and shows a frame of `root` (for now, on the `Io`'s clock), if
    /// there is one to draw and the window is ready for it.
    ///
    /// `root` is kept until the next `draw`, for the window to have drawn
    /// again while the app's loop is held by the window system (macOS,
    /// while the window is resized by its edge); what it points to must
    /// last as long.
    pub fn draw(a: *App, root: anytype) !void {
        a.keepRoot(root);
        a.idle = true;
        if (!a.wantsFrame()) return;
        if (a.win.isFramePending()) {
            if (try a.ui.presentPopups(a.win)) a.idle = false;
            return;
        }
        try a.drawFrame(a.ui.clockNs(), root);
    }

    fn drawFrame(a: *App, now_ns: u64, root: anytype) !void {
        a.drawing = true;
        defer a.drawing = false;
        a.dirty = false;
        const size = a.win.size();
        const target_ns = a.win.nextPresentationNs(now_ns);
        const begun = a.ui.clockNs();
        a.ui.frame(size[0], size[1], target_ns, root);
        const built = a.ui.clockNs();
        a.win.setPresentationTime(target_ns);
        const clear = a.clear_color orelse a.ui.theme.surface.toArgb();
        const shown = try a.ui.present(a.win, clear);
        if (shown) a.idle = false;
        if (a.trace) a.traceFrame(begun, built, shown);
    }

    /// Writes how the frame just drawn went (`FACET_TRACE=1`): since the
    /// last began, whether the window system was holding the loop (the
    /// window asked for it), and how long it took to build and to present.
    fn traceFrame(a: *App, begun: u64, built: u64, shown: bool) void {
        const done = a.ui.clockNs();
        const ms = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
            }
        }.f;
        std.debug.print("facet: frame {d}: +{d:.1} ms{s}{s} build {d:.1} present {d:.1}\n", .{
            a.ui.frame_no,
            ms(begun -| a.last_frame_ns),
            if (a.held) " held" else "",
            if (shown) "" else " (nothing shown)",
            ms(built - begun),
            ms(done - built),
        });
        a.last_frame_ns = begun;
    }

    fn keepRoot(a: *App, root: anytype) void {
        const T = @TypeOf(root);
        const Kept = struct {
            fn draw(app: *App, p: *anyopaque) anyerror!void {
                try app.drawFrame(app.ui.clockNs(), @as(*const T, @ptrCast(@alignCast(p))).*);
            }
            fn free(gpa: std.mem.Allocator, p: *anyopaque) void {
                gpa.destroy(@as(*T, @ptrCast(@alignCast(p))));
            }
        };
        if (a.kept_root) |k| {
            if (k.draw == &Kept.draw) {
                @as(*T, @ptrCast(@alignCast(k.ptr))).* = root;
                return;
            }
            k.free(a.gpa, k.ptr);
            a.kept_root = null;
        }
        const p = a.gpa.create(T) catch return;
        p.* = root;
        a.kept_root = .{ .ptr = p, .draw = &Kept.draw, .free = &Kept.free };
    }

    /// Draws a frame of the root kept, at the window's size now, if
    /// there is one to draw (it was resized, or a widget asked for one):
    /// the window asks, from inside the window system's loop.
    fn redraw(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        // Not inside a frame (one can resize the window, to its minimum).
        if (a.drawing) return;
        const k = a.kept_root orelse return;
        if (a.win.applyConfigure() catch return) |_| a.dirty = true;
        if (!a.wantsFrame()) return;
        a.ui.syncWindow(a.win);
        a.held = true;
        defer a.held = false;
        k.draw(a, k.ptr) catch {};
    }
};
