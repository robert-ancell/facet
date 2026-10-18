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
//!     const ui = try Ui.createDefault(gpa);
//!     defer ui.destroy();
//!     // Each frame:
//!     ui.frame(width, height, now_ns, MyApp{ .title = "Hello" });
//!     try ui.preview(image);

const std = @import("std");
const linux = std.os.linux;
const window_mod = @import("window");
const gfx = @import("gfx");
const font = @import("font");
const geometry = @import("geometry.zig");
const widget = @import("widget.zig");
const painter_mod = @import("painter.zig");
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const damage_mod = @import("damage.zig");
const keymap = @import("keymap.zig");
const menu_mod = @import("menu.zig");
const drag_mod = @import("drag.zig");
const tooltip_mod = @import("tooltip.zig");

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

pub const Ui = struct {
    gpa: std.mem.Allocator,
    /// Text is drawn in it; without one, text takes no space.
    font: ?*const font.Font,
    owned_font: ?font.Font = null,
    font_data: ?[]const u8 = null,
    emoji_font: ?font.Font = null,
    emoji_font_data: ?[]const u8 = null,
    /// Icons are drawn with it (see `Icon`).
    icon_font: font.Font,
    theme: Theme = .dark,
    last_surface: ?gfx.Color = null,
    atlas: gfx.Atlas,
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
    /// The widget keys go to.
    focused: ?*Node = null,
    shift: u2 = 0,
    ctrl: u2 = 0,
    /// The right Alt, for a keyboard's third characters (the UK's €).
    altgr: u2 = 0,
    caps_lock: bool = false,
    /// The keyboard's layout: what character each key types.
    keyboard: window_mod.Keyboard = .us,
    /// The window fills the screen: title bars are not drawn.
    fullscreen: bool = false,
    /// Whether the window fills the work area (for `TitleBar`).
    maximized: bool = true,
    /// Whether the window is tiled by the compositor.
    tiled: bool = false,
    /// The window attached to the UI, if any.
    win: ?window_mod.Window = null,
    /// What the window's title bar buttons do (set by `attachWindow`).
    controls: ?*window_mod.Controls = null,
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
    pub fn create(gpa: std.mem.Allocator, f: ?*const font.Font) !*Ui {
        const ui = try gpa.create(Ui);
        errdefer gpa.destroy(ui);
        ui.* = .{
            .gpa = gpa,
            .font = f,
            .icon_font = try font.Font.init(@import("icons").font_data),
            .atlas = try gfx.Atlas.init(gpa),
            .arenas = .{ .init(gpa), .init(gpa) },
        };
        ui.renderer = ui.software_renderer.renderer();
        return ui;
    }

    /// Creates a `Ui` using the bundled default Fira Sans and Twemoji Mozilla
    /// fallback fonts.
    pub fn createDefault(gpa: std.mem.Allocator) !*Ui {
        const ui = try create(gpa, null);
        errdefer ui.destroy();
        ui.owned_font = try font.Font.init(font.default_font_data);
        ui.emoji_font = font.Font.init(font.emoji_font_data) catch null;
        if (ui.owned_font) |*f| {
            if (ui.emoji_font) |*ef| f.fallback = ef;
            ui.font = f;
        }
        return ui;
    }

    /// Creates a `Ui` with the font at `path` (or the bundled default font
    /// when `path == null`).
    pub fn createWithFont(gpa: std.mem.Allocator, _: []const u8, path: ?[*:0]const u8) !*Ui {
        const p = path orelse return createDefault(gpa);
        const span = std.mem.span(p);
        const ui = try create(gpa, null);
        errdefer ui.destroy();
        if (readFileAlloc(gpa, span, 32 * 1024 * 1024)) |data| {
            if (font.Font.init(data)) |f| {
                ui.font_data = data;
                ui.owned_font = f;
            } else |_| {
                gpa.free(data);
            }
        } else |_| {}
        if (ui.owned_font == null) {
            ui.owned_font = font.Font.init(font.default_font_data) catch null;
        }
        ui.emoji_font = font.Font.init(font.emoji_font_data) catch null;
        if (ui.owned_font) |*f| {
            if (ui.emoji_font) |*ef| f.fallback = ef;
            ui.font = f;
        }
        return ui;
    }

    pub fn destroy(ui: *Ui) void {
        ui.closeMenu();
        ui.endDrag(false);
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
        if (ui.font_data) |d| ui.gpa.free(d);
        if (ui.emoji_font_data) |d| ui.gpa.free(d);
        ui.gpa.destroy(ui);
    }

    /// Attaches a custom or GPU `gfx.Renderer` (e.g. `OpenGlRenderer.renderer()`,
    /// `VulkanRenderer.renderer()`, or `gfx.Renderer.of(&my_backend)`).
    pub fn attachRenderer(ui: *Ui, r: gfx.Renderer, take_ownership: bool) void {
        if (ui.owns_renderer) if (ui.renderer) |old| old.deinit();
        ui.renderer = r;
        ui.owns_renderer = take_ownership;
    }

    /// Connects the UI's clipboard, keyboard layout, and window state to
    /// `win` (either a `window.Window` or a pointer such as `*window.WaylandWindow`).
    pub fn attachWindow(ui: *Ui, win_any: anytype, controls: ?*window_mod.Controls) void {
        const w: window_mod.Window = if (@TypeOf(win_any) == window_mod.Window) win_any else window_mod.Window.of(win_any);
        ui.win = w;
        if (@TypeOf(win_any) != window_mod.Window) {
            const Child = @typeInfo(@TypeOf(win_any)).pointer.child;
            if (@hasField(Child, "clipboard")) {
                ui.clipboard = .of(&win_any.clipboard);
            } else if (@hasDecl(Child, "copy") and @hasDecl(Child, "paste")) {
                ui.clipboard = .of(win_any);
            }
            if (@hasField(Child, "min_size") and ui.min_size_floor[0] == 0 and ui.min_size_floor[1] == 0) {
                ui.min_size_floor = win_any.min_size;
            }
        }
        ui.controls = controls;
        ui.syncWindow(w);
    }

    /// Updates the UI's keyboard layout and window state from `win`.
    pub fn syncWindow(ui: *Ui, win_any: anytype) void {
        const w: window_mod.Window = if (@TypeOf(win_any) == window_mod.Window) win_any else window_mod.Window.of(win_any);
        ui.keyboard = w.layout();
        ui.fullscreen = w.isFullscreen();
        ui.maximized = w.isMaximized();
        ui.tiled = w.isTiled();
        ui.scale = @max(w.scale(), 1);
    }

    /// Returns information about the active windowing platform, surface buffer
    /// transport, and 2D rendering backend.
    pub fn backend(ui: *const Ui) widget.BackendInfo {
        const s = @max(ui.scale, 1);
        const lsize = if (ui.win) |w| w.size() else ui.logical_size;
        return .{
            .platform = if (ui.win) |w| w.platform() else .headless,
            .buffer_transport = if (ui.win) |w| w.bufferTransport() else .memory,
            .renderer = if (ui.renderer) |r| r.backend() else .software,
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

    /// Maps a `widget.Cursor` to its `wp_cursor_shape_device_v1.shape` code.
    pub fn cursorShape(c: widget.Cursor) u32 {
        const sh = window_mod.CursorShape;
        return switch (c) {
            .default => sh.default,
            .pointer => sh.pointer,
            .text => sh.text,
            .grab => sh.grab,
            .grabbing => sh.grabbing,
            .crosshair => sh.crosshair,
            .move => sh.move,
            .not_allowed => sh.not_allowed,
            .wait => sh.wait,
            .progress => sh.progress,
            .help => sh.help,
            .ew_resize => sh.ew_resize,
            .ns_resize => sh.ns_resize,
            .nwse_resize => sh.nwse_resize,
            .nesw_resize => sh.nesw_resize,
        };
    }

    /// Updates `win`'s cursor shape to match `ui.cursor()`.
    pub fn syncCursor(ui: *const Ui, win_any: anytype) void {
        const w: window_mod.Window = if (@TypeOf(win_any) == window_mod.Window) win_any else window_mod.Window.of(win_any);
        w.setCursor(cursorShape(ui.cursor()));
    }

    /// Updates `win`'s minimum size to match `ui.min_size`.
    pub fn syncMinSize(ui: *const Ui, win_any: anytype) void {
        const w: window_mod.Window = if (@TypeOf(win_any) == window_mod.Window) win_any else window_mod.Window.of(win_any);
        w.setMinSize(ui.min_size[0], ui.min_size[1]);
    }

    /// The `zwp_text_input_v3` state for the currently focused widget, or
    /// null when no text input widget is focused.
    pub fn textInputState(ui: *const Ui) ?window_mod.TextInputState {
        const n = ui.focused orelse return null;
        const f = n.widget.vtable.text_input orelse return null;
        const info = f(n.widget.ptr, n) orelse return null;
        const origin = n.position();
        const ox: i32 = @intFromFloat(@round(origin[0]));
        const oy: i32 = @intFromFloat(@round(origin[1]));
        const ti = window_mod.TextInputProtocol;
        const hint: u32 = if (info.password)
            (ti.content_hint.hidden_text | ti.content_hint.sensitive_data)
        else if (info.multiline)
            ti.content_hint.multiline
        else
            ti.content_hint.none;
        const purpose: u32 = if (info.password) ti.content_purpose.password else ti.content_purpose.normal;
        const cause: u32 = if (info.change_cause_other) ti.change_cause.other else ti.change_cause.input_method;
        return .{
            .surrounding_text = info.surrounding_text,
            .cursor = info.cursor,
            .anchor = info.anchor,
            .change_cause = cause,
            .content_hint = hint,
            .content_purpose = purpose,
            .cursor_rect = .{
                ox + info.cursor_rect[0],
                oy + info.cursor_rect[1],
                info.cursor_rect[2],
                info.cursor_rect[3],
            },
        };
    }

    /// Synchronizes `win`'s `zwp_text_input_v3` state with the focused widget.
    pub fn syncTextInput(ui: *const Ui, win_any: anytype) void {
        const w: window_mod.Window = if (@TypeOf(win_any) == window_mod.Window) win_any else window_mod.Window.of(win_any);
        w.setTextInput(ui.textInputState());
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
        r.build(w);
        const min = r.minSize(.unbounded);
        ui.min_size = .{
            @max(ui.min_size_floor[0], @as(u32, @intFromFloat(@ceil(@max(min.w, 1))))),
            @max(ui.min_size_floor[1], @as(u32, @intFromFloat(@ceil(@max(min.h, 1))))),
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
        _ = r.layout(.tight(window));
        r.offset = .{ 0, 0 };
        const m = ui.buildMenu(window);
        const d = ui.buildDrag(window);
        const tt = ui.buildTooltip(window);
        ui.paint(r, d, m, tt, w_px, h_px);
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
    }

    fn buildMenu(ui: *Ui, window: Size) ?*Node {
        const menu = ui.menu orelse {
            if (ui.menu_root) |n| n.destroy();
            ui.menu_root = null;
            return null;
        };
        var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
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
        n.build(w);
        const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
        n.offset = menu_mod.place(window, menu.at, size);
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
        n.build(w);
        const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
        n.offset = .{
            std.math.clamp(d.pos[0] + 12, 0, @max(0, window.w - size.w)),
            std.math.clamp(d.pos[1] + 16, 0, @max(0, window.h - size.h)),
        };
        return n;
    }

    fn buildTooltip(ui: *Ui, window: Size) ?*Node {
        if (ui.menu == null and ui.drag == null) {
            for (ui.hovered.items) |target| {
                if (target.laid_out != ui.frame_no) continue;
                const tt = target.widget.as(tooltip_mod.Tooltip) orelse continue;
                if (tt.text.len == 0) continue;
                var cx: Context = .{ .ui = ui, .arena = ui.arena(), .node = undefined };
                const w = cx.make(tooltip_mod.Bubble{ .text = tt.text });
                if (ui.tooltip_root == null) ui.tooltip_root = Node.create(ui, w);
                const n = ui.tooltip_root orelse return null;
                n.build(w);
                const size = n.layout(.{ .max_w = window.w, .max_h = window.h });
                const at = target.position();
                n.offset = tooltip_mod.place(window, .{ .x = at[0], .y = at[1], .w = target.size.w, .h = target.size.h }, size);
                return n;
            }
        }
        if (ui.tooltip_root) |n| n.destroy();
        ui.tooltip_root = null;
        return null;
    }

    fn paint(ui: *Ui, r: *Node, drag: ?*Node, menu: ?*Node, tooltip: ?*Node, width: u32, height: u32) void {
        ui.atlas.beginFrame();
        ui.canvases_used = 0;
        ui.segments.clearRetainingCapacity();
        const s = @max(ui.scale, 1);
        ui.logical_size = .{ width, height };
        ui.frame_size = .{ width * s, height * s };
        ui.paint_order = 0;
        var p: Painter = .{ .ui = ui, .node = r };
        p.paintNode(r);
        if (drag) |d| p.paintNode(d);
        if (menu) |m| p.paintNode(m);
        if (tooltip) |tt| p.paintNode(tt);
    }

    // --- Menus ------------------------------------------------------------------

    pub fn openMenu(ui: *Ui, owner: *Node, at: Point, items: []const menu_mod.Item) void {
        ui.closeMenu();
        const copy = ui.gpa.dupe(menu_mod.Item, items) catch return;
        ui.menu = .{ .content = .{ .items = copy }, .at = at, .owner = owner };
        ui.needs_frame = true;
    }

    pub fn openPopup(ui: *Ui, owner: *Node, at: Point, popup: PopupBuilder) void {
        ui.closeMenu();
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
        if (ui.root) |r| _ = r.hitTest(pos, &ui.drag_scratch);
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
        ui.local_clipboard.clearRetainingCapacity();
        ui.local_clipboard.appendSlice(ui.gpa, text) catch {};
    }

    pub fn pasteText(ui: *Ui, owner: *Node, on_text: widget.ValueCallback([]const u8)) void {
        ui.paste = .{ .owner = owner, .on_text = on_text };
        if (ui.clipboard) |c| return c.vtable.paste(c.ptr, .{ .ctx = ui, .f = pasted });
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
        if (ui.canvases_used == ui.canvases.items.len) {
            const c = ui.gpa.create(gfx.Canvas) catch return null;
            c.* = .init(ui.gpa);
            ui.canvases.append(ui.gpa, c) catch {
                ui.gpa.destroy(c);
                return null;
            };
        }
        const c = ui.canvases.items[ui.canvases_used];
        c.beginScaled(ui.logical_size[0], ui.logical_size[1], @max(ui.scale, 1));
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
    pub fn render(ui: *Ui, target: anytype, damage: ?[]const gfx.Viewport) !void {
        const r = ui.renderer orelse return error.NoRenderer;
        try r.prepare(ui.canvases.items[0..ui.canvases_used]);
        const target_ptr: *anyopaque = if (@typeInfo(@TypeOf(target)) == .pointer)
            @ptrCast(@constCast(target))
        else
            @panic("Ui.render expects a pointer to the render target");
        try r.render(ui.segments.items, target_ptr, ui.frame_size[0], ui.frame_size[1], damage);
    }

    /// Draws the last painted frame into `img` on the CPU using `gfx.software`.
    pub fn preview(ui: *Ui, img: gfx.software.Image) !void {
        var mutable_img = img;
        for (ui.segments.items) |s| switch (s) {
            .canvas => |c| try gfx.software.renderCanvas(c, mutable_img),
            .gpu => |g| try g.f(g.ctx, @ptrCast(&mutable_img), g.area),
        };
    }

    /// If the last `frame` changed anything, renders only the damaged parts
    /// into `win` and presents it.
    pub fn present(ui: *Ui, win: *window_mod.WaylandWindow, clear: u32) !bool {
        if (!ui.changed()) return false;
        var img = try win.beginFrame();
        const repaint_region = ui.repaint(win.bufferAge());
        var repaint_vps: [damage_mod.Region.max_rects]gfx.Viewport = undefined;
        const vps = regionViewports(&repaint_region, &repaint_vps);
        img.clearViewports(clear, vps);
        try ui.render(&img, vps);
        win.finishFrame(vps);
        var damage: [damage_mod.Region.max_rects]gfx.Viewport = undefined;
        try win.showDamaged(ui.damagedViewports(&damage));
        return true;
    }

    // --- Input ------------------------------------------------------------------

    pub fn handleInput(ui: *Ui, e: window_mod.InputEvent) void {
        switch (e) {
            .motion => |pos| ui.pointerMotion(pos),
            .button => |b| ui.pointerButton(b.pos, b.code, b.pressed),
            .scroll => |s| ui.pointerScroll(s.pos, s.dx, s.dy),
            .key => |k| ui.keyEvent(k.code, k.pressed),
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
        }
    }

    pub fn takeInput(ui: *Ui, win_any: anytype) void {
        const w: window_mod.Window = if (@TypeOf(win_any) == window_mod.Window) win_any else window_mod.Window.of(win_any);
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

    pub fn pointerButton(ui: *Ui, pos: Point, button: u32, pressed: bool) void {
        ui.pointer = pos;
        ui.updateHover(pos);
        ui.needs_frame = true;
        defer if (ui.win) |win| ui.syncCursor(win);
        if (pressed) {
            if (ui.captured != null) return;
            if (ui.menu != null and !ui.overMenu()) {
                ui.closeMenu();
                return;
            }
            if (ui.focused) |f| if (std.mem.indexOfScalar(*Node, ui.hovered.items, f) == null) ui.focus(null);
            if (button == widget.btn_right) for (ui.hovered.items) |n| if (send(n, .{ .context = local(n, pos) })) return;
            for (ui.hovered.items) |n| if (send(n, .{ .press = .{ .pos = local(n, pos), .button = button } })) {
                ui.captured = n;
                return;
            };
        } else if (ui.swallow_release) {
            ui.swallow_release = false;
            ui.hold = null;
        } else if (ui.captured) |n| {
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
        _ = send(n, .{ .release = .{ .pos = .{ -1, -1 }, .button = widget.btn_left, .inside = false } });
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

    pub fn keyEvent(ui: *Ui, code: u32, pressed: bool) void {
        switch (code) {
            keymap.left_shift, keymap.right_shift => {
                ui.shift = if (pressed) ui.shift +| 1 else ui.shift -| 1;
                return;
            },
            keymap.left_ctrl, keymap.right_ctrl => {
                ui.ctrl = if (pressed) ui.ctrl +| 1 else ui.ctrl -| 1;
                return;
            },
            keymap.right_alt => {
                ui.altgr = if (pressed) ui.altgr +| 1 else ui.altgr -| 1;
                return;
            },
            keymap.caps_lock => if (pressed) {
                ui.caps_lock = !ui.caps_lock;
            },
            keymap.escape => if (pressed and ui.menu != null) {
                ui.closeMenu();
                return;
            },
            else => {},
        }
        const n = ui.focused orelse return;
        const ctrl = ui.ctrl > 0;
        const shift = ui.shift > 0;
        _ = send(n, .{ .key = .{
            .code = code,
            .pressed = pressed,
            .char = if (pressed and !ctrl) ui.keyboard.char(code, shift, ui.caps_lock, ui.altgr > 0) else null,
            .ctrl = ctrl,
            .shift = shift,
        } });
        ui.needs_frame = true;
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
        } else if (ui.root) |r| _ = r.hitTest(pos, &path);
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
        if (std.mem.indexOfScalar(*Node, ui.hovered.items, n)) |i| _ = ui.hovered.orderedRemove(i);
    }
};

fn readFileAlloc(gpa: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) ![]u8 {
    const rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.FileNotFound;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx)) != .SUCCESS) return error.SystemError;
    if (stx.size == 0 or stx.size > max_bytes) return error.FileTooBig;
    const size: usize = @intCast(stx.size);
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    var read_total: usize = 0;
    while (read_total < size) {
        const n = linux.read(fd, buf[read_total..].ptr, size - read_total);
        if (linux.errno(n) != .SUCCESS or n == 0) return error.SystemError;
        read_total += n;
    }
    return buf;
}

/// A native toolkit app: owns a `WaylandWindow`, `Controls`, and `Ui`.
pub const App = struct {
    gpa: std.mem.Allocator,
    name: []const u8,
    win: *window_mod.WaylandWindow,
    controls: window_mod.Controls,
    ui: *Ui,
    clear_color: ?u32 = null,
    appearance: theme_mod.Settings = .{},
    theme_watch: theme_mod.Watch = .{},
    width: u32,
    height: u32,
    dirty: bool = true,
    idle: bool = false,
    suspended: bool = false,
    sync_keyboard: bool = true,
    resized: bool = false,
    suspended_changed: bool = false,

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = .{ 1280, 720 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
        font_path: ?[*:0]const u8 = null,
        clear_color: ?u32 = null,
    };

    /// Connects to the Wayland compositor in `environ`, opens the window,
    /// loads the font (defaulting to the bundled Fira Sans + Twemoji fonts),
    /// and attaches the toolkit to the window.
    pub fn open(gpa: std.mem.Allocator, environ: std.process.Environ, options: Options) !*App {
        const name = options.app_id orelse options.title;
        const a = try gpa.create(App);
        errdefer gpa.destroy(a);
        a.gpa = gpa;
        a.name = name;
        a.win = try window_mod.WaylandWindow.open(gpa, environ, .{
            .title = options.title,
            .app_id = options.app_id,
            .size = options.size,
            .min_size = options.min_size,
            .maximized = options.maximized,
        });
        errdefer a.win.close();
        a.controls = .init(a.win);
        a.ui = try Ui.createWithFont(gpa, name, options.font_path);
        errdefer a.ui.destroy();
        a.ui.min_size_floor = options.min_size orelse .{ 0, 0 };
        a.ui.attachWindow(a.win, &a.controls);
        a.clear_color = options.clear_color;
        a.appearance = theme_mod.loadSettings();
        a.theme_watch = .{};
        _ = a.theme_watch.changed();
        a.ui.theme = a.appearance.theme.scheme();
        a.width = a.win.width;
        a.height = a.win.height;
        a.dirty = true;
        a.idle = false;
        a.suspended = false;
        a.sync_keyboard = true;
        a.resized = false;
        a.suspended_changed = false;
        return a;
    }

    pub fn close(a: *App) void {
        a.ui.destroy();
        a.win.close();
        a.gpa.destroy(a);
    }

    pub fn setTheme(a: *App, mode: theme_mod.Mode) void {
        a.appearance.theme = mode;
        a.ui.theme = mode.scheme();
        _ = a.theme_watch.changed();
        a.dirty = true;
    }

    pub fn step(a: *App, idle_timeout_ns: u64) !bool {
        if (a.idle) {
            const refresh = if (a.win.refresh_ns > 0) a.win.refresh_ns else 16 * std.time.ns_per_ms;
            const timeout: u64 = if (a.ui.needs_frame and !a.suspended) refresh else idle_timeout_ns;
            try a.win.wait(timeout);
        } else {
            try a.win.poll();
        }
        if (a.win.closed or a.controls.quit) return false;
        a.resized = false;
        if (try a.win.applyConfigure()) |size| {
            a.width = size[0];
            a.height = size[1];
            a.dirty = true;
            a.resized = true;
        }
        if (a.win.scale_changed) {
            a.win.scale_changed = false;
            a.dirty = true;
        }
        a.suspended_changed = a.win.suspended != a.suspended;
        if (a.suspended_changed) {
            a.suspended = a.win.suspended;
            if (a.suspended) {
                a.win.releaseSpareBuffers();
            } else {
                a.dirty = true;
            }
        }
        if (a.theme_watch.changed()) {
            a.appearance = theme_mod.loadSettings();
            a.ui.theme = a.appearance.theme.scheme();
            a.dirty = true;
        }
        if (a.sync_keyboard) a.ui.keyboard = a.win.layout;
        if (a.resized or a.ui.fullscreen != a.win.fullscreen or a.ui.maximized != a.win.maximized or a.ui.tiled != a.win.tiled) {
            a.ui.damage.invalidate();
            a.dirty = true;
        }
        a.ui.fullscreen = a.win.fullscreen;
        a.ui.maximized = a.win.maximized;
        a.ui.tiled = a.win.tiled;
        a.ui.scale = @max(a.win.scale, 1);
        return true;
    }

    pub fn takeInput(a: *App) void {
        if (a.sync_keyboard) a.ui.keyboard = a.win.layout;
        a.ui.fullscreen = a.win.fullscreen;
        a.ui.maximized = a.win.maximized;
        a.ui.tiled = a.win.tiled;
        a.ui.scale = @max(a.win.scale, 1);
        for (a.win.takeInput()) |e| a.ui.handleInput(e);
        a.ui.syncCursor(a.win);
    }

    pub fn draw(a: *App, now_ns: u64, root: anytype) !void {
        a.idle = true;
        if (!a.suspended and (a.dirty or a.ui.needs_frame)) {
            a.dirty = false;
            const target_ns = a.win.nextPresentationNs(now_ns);
            a.ui.frame(a.width, a.height, target_ns, root);
            a.width = a.win.width;
            a.height = a.win.height;
            const clear = a.clear_color orelse a.ui.theme.surface.toArgb();
            if (try a.ui.present(a.win, clear)) a.idle = false;
        }
    }
};
