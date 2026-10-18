//! Window abstraction (`Window` vtable interface), input events (`InputEvent`),
//! text input state (`TextInputState`), window controls (`Controls`), keyboard
//! layout (`Layout`) and keymaps (`xkb`), and the built-in Wayland client window backend
//! (`WaylandWindow`).
//!
//! Apps can either use `WaylandWindow` directly or implement custom window
//! backends (e.g. X11, SDL, GLFW, macOS, Windows) via `Window.of(&impl)`.

const std = @import("std");
const gfx = @import("gfx");

pub const clipboard = @import("clipboard.zig");
pub const wayland = @import("wayland.zig");

pub const Clipboard = clipboard.Clipboard;
pub const DroppedData = clipboard.DroppedData;
pub const WaylandWindow = wayland.WaylandWindow;
pub const nowNs = clipboard.nowNs;

/// The pointer shape the window shows.
pub const Cursor = enum {
    default,
    pointer,
    text,
    grab,
    grabbing,
    crosshair,
    move,
    not_allowed,
    wait,
    progress,
    help,
    ew_resize,
    ns_resize,
    nwse_resize,
    nesw_resize,
};

/// The focused text widget's state, for the platform's input method.
pub const TextInputState = struct {
    surrounding_text: []const u8 = "",
    /// Byte offsets of the cursor and the selection's other end in
    /// `surrounding_text`.
    cursor: u32 = 0,
    anchor: u32 = 0,
    /// Whether the input method or something else (the app, the user
    /// editing directly) made the last change.
    change_cause: ChangeCause = .input_method,
    password: bool = false,
    multiline: bool = false,
    /// The cursor in window coordinates (`[x, y, width, height]`).
    cursor_rect: [4]i32 = .{ 0, 0, 1, 20 },

    pub const ChangeCause = enum { input_method, other };

    pub fn eql(a: TextInputState, b: TextInputState) bool {
        return a.cursor == b.cursor and
            a.anchor == b.anchor and
            a.change_cause == b.change_cause and
            a.password == b.password and
            a.multiline == b.multiline and
            std.mem.eql(i32, &a.cursor_rect, &b.cursor_rect) and
            std.mem.eql(u8, a.surrounding_text, b.surrounding_text);
    }
};

pub const InputEvent = union(enum) {
    /// The pointer moved to (or entered at) a position in the window.
    motion: [2]f32,
    /// A Linux button code (BTN_LEFT, ...), and where the pointer was.
    button: struct { pos: [2]f32, code: u32, pressed: bool },
    /// A Linux key code (KEY_A, ...).
    /// What it types (from the keymap), and the modifiers held, if the
    /// window has a keymap.
    key: struct { code: u32, pressed: bool, char: ?u21 = null, shift: bool = false, ctrl: bool = false },
    /// The wheel turned: by `dy` pixels down (and `dx` right), with the
    /// pointer at `pos`.
    scroll: struct { pos: [2]f32, dx: f32, dy: f32 },
    /// The pointer left the window.
    leave,
    /// A touch went down at a position (`id` is the touch's while it
    /// lasts), moved, or came up.
    touch_down: struct { id: i32, pos: [2]f32 },
    touch_motion: struct { id: i32, pos: [2]f32 },
    touch_up: i32,
    /// The window's touches were cancelled by the shell.
    touch_cancel,
    /// Relative pointer motion for a locked pointer.
    relative_motion: [2]f32,
    /// The pointer lock took effect (true), or ended (false).
    pointer_locked: bool,
    /// An input method committed UTF-8 text (`zwp_text_input_v3`).
    text_commit: struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    },
    /// An input method updated its preedit string (`zwp_text_input_v3`).
    text_preedit: struct {
        buf: [128]u8 = undefined,
        len: u8 = 0,
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    },
    /// An input method asked to delete bytes around the cursor.
    text_delete_surrounding: struct { before_length: u32, after_length: u32 },
    /// Drag-and-drop events.
    drag_enter: [2]f32,
    drag_motion: [2]f32,
    drag_leave,
    drop: [2]f32,
    /// The window system closed a popup (`Window.openPopup`), with this id:
    /// a menu, when its pointer or keyboard was used elsewhere.
    popup_done: u32,
};

/// Windowing system / display server backend.
pub const Platform = enum {
    headless,
    wayland,
    x11,
    windows,
    macos,
    custom,

    pub fn name(p: Platform) []const u8 {
        return switch (p) {
            .headless => "Headless",
            .wayland => "Wayland",
            .x11 => "X11",
            .windows => "Windows",
            .macos => "macOS",
            .custom => "Custom",
        };
    }
};

/// Surface buffer presentation mechanism.
pub const BufferTransport = enum {
    memory,
    wl_shm,
    linux_dmabuf,
    swapchain,
    custom,

    pub fn name(t: BufferTransport) []const u8 {
        return switch (t) {
            .memory => "CPU Memory",
            .wl_shm => "wl_shm",
            .linux_dmabuf => "linux_dmabuf",
            .swapchain => "Swapchain",
            .custom => "Custom",
        };
    }
};

/// Whether window decorations (title bar, drop shadows, resize borders) are
/// drawn by the toolkit (`client`), the compositor/window manager (`server`),
/// or not at all (`none`).
pub const Decorations = enum {
    none,
    client,
    server,

    pub fn name(d: Decorations) []const u8 {
        return switch (d) {
            .none => "None",
            .client => "Client-side (CSD)",
            .server => "Server-side (SSD)",
        };
    }
};

/// How the window system knows a GPU buffer's drawing is finished (and
/// the window when it may draw in it again).
pub const BufferSync = enum {
    /// There is nothing to wait for: the buffers are in CPU memory
    /// (`wl_shm`, headless).
    none,
    /// Fences the kernel keeps with each buffer (dmabuf implicit sync).
    implicit,
    /// Explicit timeline points (`wp_linux_drm_syncobj_v1`).
    linux_drm_syncobj_v1,

    pub fn name(s: BufferSync) []const u8 {
        return switch (s) {
            .none => "None",
            .implicit => "Implicit (dma-buf fences)",
            .linux_drm_syncobj_v1 => "wp_linux_drm_syncobj_v1",
        };
    }
};

/// Active frame pacing and vertical synchronization protocols on the surface.
pub const FrameSync = packed struct(u8) {
    /// Frames are shown at most once a refresh, without tearing.
    vsync: bool = false,
    frame_callback: bool = false,
    presentation_time: bool = false,
    fifo_v1: bool = false,
    commit_timing_v1: bool = false,
    _pad: u3 = 0,
};

/// What a popup is for. A menu takes the keyboard and the pointer, and
/// goes when they are used outside the app; a tooltip takes no input (the
/// pointer goes through it).
pub const PopupKind = enum { menu, tooltip };

/// Where a popup goes (`Window.openPopup`), in the window's coordinates
/// (logical pixels). Where there is no room on the screen, it flips to the
/// other side of the anchor, or slides along it.
pub const PopupPlacement = struct {
    kind: PopupKind,
    /// The rectangle it is placed against, `[x, y, width, height]`.
    anchor: [4]i32,
    size: [2]u32,
    side: Side,
    /// How far it is from the anchor.
    gap: i32 = 0,

    pub const Side = enum {
        /// Down and to the right of the anchor's top left corner (a menu at
        /// a point: a 1 by 1 anchor).
        below_right,
        /// Centred above the anchor (a tooltip).
        above,
    };

    pub fn eql(a: PopupPlacement, b: PopupPlacement) bool {
        return std.meta.eql(a, b);
    }
};

/// Generic window interface (`Window.of(&impl)`).
pub const Window = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        platform: *const fn (ptr: *anyopaque) Platform,
        bufferTransport: *const fn (ptr: *anyopaque) BufferTransport,
        bufferSync: *const fn (ptr: *anyopaque) BufferSync,
        frameSync: *const fn (ptr: *anyopaque) FrameSync,
        refreshHz: *const fn (ptr: *anyopaque) f32,
        extensions: *const fn (ptr: *anyopaque) []const []const u8,
        decorations: *const fn (ptr: *anyopaque) Decorations,
        title: *const fn (ptr: *anyopaque) []const u8,
        poll: *const fn (ptr: *anyopaque) anyerror!void,
        wait: *const fn (ptr: *anyopaque, timeout_ns: u64) anyerror!void,
        takeInput: *const fn (ptr: *anyopaque) []const InputEvent,
        size: *const fn (ptr: *anyopaque) [2]u32,
        scale: *const fn (ptr: *anyopaque) u32,
        isClosed: *const fn (ptr: *anyopaque) bool,
        isSuspended: *const fn (ptr: *anyopaque) bool,
        isMaximized: *const fn (ptr: *anyopaque) bool,
        isFullscreen: *const fn (ptr: *anyopaque) bool,
        isTiled: *const fn (ptr: *anyopaque) bool,
        isFramePending: *const fn (ptr: *anyopaque) bool,
        setCursor: *const fn (ptr: *anyopaque, cursor: Cursor) void,
        setMinSize: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
        setMaximized: *const fn (ptr: *anyopaque, on: bool) void,
        setMinimized: *const fn (ptr: *anyopaque) void,
        canMaximize: *const fn (ptr: *anyopaque) bool,
        canMinimize: *const fn (ptr: *anyopaque) bool,
        setFullscreen: *const fn (ptr: *anyopaque, on: bool) void,
        startMove: *const fn (ptr: *anyopaque) void,
        setTextInput: *const fn (ptr: *anyopaque, state: ?TextInputState) void,
        startDrag: *const fn (ptr: *anyopaque, mime_type: []const u8, bytes: []const u8, actions: u32) bool,
        takeDrop: *const fn (ptr: *anyopaque) ?DroppedData,
        nextPresentationNs: *const fn (ptr: *anyopaque, now_ns: u64) u64,
        setPresentationTime: *const fn (ptr: *anyopaque, target_ns: u64) void,
        layout: *const fn (ptr: *anyopaque) Layout,
        refreshNs: *const fn (ptr: *anyopaque) u64,
        applyConfigure: *const fn (ptr: *anyopaque) anyerror!?[2]u32,
        releaseSpareBuffers: *const fn (ptr: *anyopaque) void,
        beginFrame: *const fn (ptr: *anyopaque) anyerror!gfx.software.Image,
        beginDmabufFrame: *const fn (ptr: *anyopaque) ?gfx.DmabufTarget,
        bufferAge: *const fn (ptr: *anyopaque) u32,
        finishFrame: *const fn (ptr: *anyopaque, repainted: ?[]const gfx.Viewport) void,
        showDamaged: *const fn (ptr: *anyopaque, damage: ?[]const gfx.Viewport) anyerror!void,
        close: *const fn (ptr: *anyopaque) void,
        supportsPopups: *const fn (ptr: *anyopaque) bool,
        openPopup: *const fn (ptr: *anyopaque, placement: PopupPlacement) ?u32,
        closePopup: *const fn (ptr: *anyopaque, id: u32) void,
        popupPosition: *const fn (ptr: *anyopaque, id: u32) ?[2]i32,
        beginPopupFrame: *const fn (ptr: *anyopaque, id: u32) anyerror!?gfx.software.Image,
        showPopup: *const fn (ptr: *anyopaque, id: u32) anyerror!void,
        copy: ?*const fn (ptr: *anyopaque, text: []const u8) void = null,
        paste: ?*const fn (ptr: *anyopaque, sink: clipboard.Sink) void = null,
    };

    /// `win` as a `Window`: either one already, or a pointer to a type
    /// `of` takes.
    pub fn from(win: anytype) Window {
        return if (@TypeOf(win) == Window) win else of(win);
    }

    pub fn of(impl: anytype) Window {
        const Ptr = @TypeOf(impl);
        const T = @typeInfo(Ptr).pointer.child;
        const gen = struct {
            fn self(p: *anyopaque) *T {
                return @ptrCast(@alignCast(p));
            }
            fn platformFn(p: *anyopaque) Platform {
                if (@hasDecl(T, "platform")) {
                    if (@TypeOf(T.platform) == Platform) return T.platform;
                    return self(p).platform();
                }
                if (@hasField(T, "platform")) return self(p).platform;
                return .custom;
            }
            fn bufferTransportFn(p: *anyopaque) BufferTransport {
                if (@hasDecl(T, "bufferTransport")) return self(p).bufferTransport();
                if (@hasDecl(T, "buffer_transport")) return T.buffer_transport;
                if (@hasField(T, "buffer_transport")) return self(p).buffer_transport;
                return .custom;
            }
            fn bufferSyncFn(p: *anyopaque) BufferSync {
                if (@hasDecl(T, "bufferSync")) return self(p).bufferSync();
                if (@hasField(T, "buffer_sync")) return self(p).buffer_sync;
                return .none;
            }
            fn frameSyncFn(p: *anyopaque) FrameSync {
                if (@hasDecl(T, "frameSync")) return self(p).frameSync();
                if (@hasField(T, "frame_sync")) return self(p).frame_sync;
                return .{};
            }
            fn refreshHzFn(p: *anyopaque) f32 {
                if (@hasDecl(T, "refreshHz")) return self(p).refreshHz();
                if (@hasField(T, "refresh_ns")) {
                    const r = self(p).refresh_ns;
                    if (r > 0) return @as(f32, @floatFromInt(std.time.ns_per_s)) / @as(f32, @floatFromInt(r));
                }
                return 0.0;
            }
            fn extensionsFn(p: *anyopaque) []const []const u8 {
                if (@hasDecl(T, "extensions")) return self(p).extensions();
                return &.{};
            }
            fn decorationsFn(p: *anyopaque) Decorations {
                if (@hasDecl(T, "decorations")) {
                    if (@TypeOf(T.decorations) == Decorations) return T.decorations;
                    return self(p).decorations();
                }
                if (@hasField(T, "decorations")) return self(p).decorations;
                return switch (platformFn(p)) {
                    .wayland => .client,
                    .headless => .none,
                    else => .server,
                };
            }
            fn titleFn(p: *anyopaque) []const u8 {
                if (@hasDecl(T, "getTitle")) return self(p).getTitle();
                if (@hasField(T, "title")) return self(p).title;
                return "";
            }
            fn pollFn(p: *anyopaque) anyerror!void {
                if (@hasDecl(T, "poll")) return self(p).poll();
            }
            fn waitFn(p: *anyopaque, timeout_ns: u64) anyerror!void {
                if (@hasDecl(T, "wait")) return self(p).wait(timeout_ns);
            }
            fn takeInputFn(p: *anyopaque) []const InputEvent {
                if (@hasDecl(T, "takeInput")) return self(p).takeInput();
                return &.{};
            }
            fn sizeFn(p: *anyopaque) [2]u32 {
                const s = self(p);
                if (@hasDecl(T, "size")) return s.size();
                return .{ s.width, s.height };
            }
            fn scaleFn(p: *anyopaque) u32 {
                const s = self(p);
                if (@hasDecl(T, "getScale")) return s.getScale();
                if (@hasField(T, "scale")) return s.scale;
                return 1;
            }
            fn isClosedFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "closed")) return s.closed;
                return false;
            }
            fn isSuspendedFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "suspended")) return s.suspended;
                return false;
            }
            fn isMaximizedFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "maximized")) return s.maximized;
                return false;
            }
            fn isFullscreenFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "fullscreen")) return s.fullscreen;
                return false;
            }
            fn isTiledFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "tiled")) return s.tiled;
                return false;
            }
            fn isFramePendingFn(p: *anyopaque) bool {
                const s = self(p);
                if (@hasField(T, "frame_pending")) return s.frame_pending;
                return false;
            }
            fn setCursorFn(p: *anyopaque, cursor: Cursor) void {
                if (@hasDecl(T, "setCursor")) self(p).setCursor(cursor);
            }
            fn setMinSizeFn(p: *anyopaque, w: u32, h: u32) void {
                if (@hasDecl(T, "setMinSize")) self(p).setMinSize(w, h);
            }
            fn setMinimizedFn(p: *anyopaque) void {
                if (@hasDecl(T, "setMinimized")) self(p).setMinimized();
            }
            fn canMaximizeFn(p: *anyopaque) bool {
                if (@hasDecl(T, "canMaximize")) return self(p).canMaximize();
                return @hasDecl(T, "setMaximized");
            }
            fn canMinimizeFn(p: *anyopaque) bool {
                if (@hasDecl(T, "canMinimize")) return self(p).canMinimize();
                return @hasDecl(T, "setMinimized");
            }
            fn setMaximizedFn(p: *anyopaque, on: bool) void {
                if (@hasDecl(T, "setMaximized")) self(p).setMaximized(on);
            }
            fn setFullscreenFn(p: *anyopaque, on: bool) void {
                if (@hasDecl(T, "setFullscreen")) self(p).setFullscreen(on);
            }
            fn startMoveFn(p: *anyopaque) void {
                if (@hasDecl(T, "startMove")) self(p).startMove();
            }
            fn setTextInputFn(p: *anyopaque, state: ?TextInputState) void {
                if (@hasDecl(T, "setTextInput")) self(p).setTextInput(state);
            }
            fn startDragFn(p: *anyopaque, mime_type: []const u8, bytes: []const u8, actions: u32) bool {
                if (@hasDecl(T, "startDrag")) return self(p).startDrag(mime_type, bytes, actions);
                return false;
            }
            fn takeDropFn(p: *anyopaque) ?DroppedData {
                if (@hasDecl(T, "takeDrop")) return self(p).takeDrop();
                return null;
            }
            fn setPresentationTimeFn(p: *anyopaque, target_ns: u64) void {
                if (@hasDecl(T, "setPresentationTime")) self(p).setPresentationTime(target_ns);
            }
            fn nextPresentationNsFn(p: *anyopaque, now_ns: u64) u64 {
                if (@hasDecl(T, "nextPresentationNs")) return self(p).nextPresentationNs(now_ns);
                return now_ns;
            }
            fn layoutFn(p: *anyopaque) Layout {
                if (@hasDecl(T, "layout")) return self(p).layout();
                return .{};
            }
            fn refreshNsFn(p: *anyopaque) u64 {
                if (@hasDecl(T, "refreshNs")) return self(p).refreshNs();
                if (@hasField(T, "refresh_ns")) return self(p).refresh_ns;
                return 0;
            }
            fn applyConfigureFn(p: *anyopaque) anyerror!?[2]u32 {
                if (@hasDecl(T, "applyConfigure")) return self(p).applyConfigure();
                return null;
            }
            fn releaseSpareBuffersFn(p: *anyopaque) void {
                if (@hasDecl(T, "releaseSpareBuffers")) self(p).releaseSpareBuffers();
            }
            fn beginFrameFn(p: *anyopaque) anyerror!gfx.software.Image {
                if (@hasDecl(T, "beginFrame")) return self(p).beginFrame();
                return error.Unsupported;
            }
            fn beginDmabufFrameFn(p: *anyopaque) ?gfx.DmabufTarget {
                if (@hasDecl(T, "beginDmabufFrame")) return self(p).beginDmabufFrame();
                return null;
            }
            fn bufferAgeFn(p: *anyopaque) u32 {
                if (@hasDecl(T, "bufferAge")) return self(p).bufferAge();
                return 0;
            }
            fn finishFrameFn(p: *anyopaque, repainted: ?[]const gfx.Viewport) void {
                if (@hasDecl(T, "finishFrame")) self(p).finishFrame(repainted);
            }
            fn showDamagedFn(p: *anyopaque, damage: ?[]const gfx.Viewport) anyerror!void {
                if (@hasDecl(T, "showDamaged")) return self(p).showDamaged(damage);
                return error.Unsupported;
            }
            fn supportsPopupsFn(_: *anyopaque) bool {
                return @hasDecl(T, "openPopup");
            }
            fn openPopupFn(p: *anyopaque, placement: PopupPlacement) ?u32 {
                if (@hasDecl(T, "openPopup")) return self(p).openPopup(placement);
                return null;
            }
            fn closePopupFn(p: *anyopaque, id: u32) void {
                if (@hasDecl(T, "closePopup")) self(p).closePopup(id);
            }
            fn popupPositionFn(p: *anyopaque, id: u32) ?[2]i32 {
                if (@hasDecl(T, "popupPosition")) return self(p).popupPosition(id);
                return null;
            }
            fn beginPopupFrameFn(p: *anyopaque, id: u32) anyerror!?gfx.software.Image {
                if (@hasDecl(T, "beginPopupFrame")) return self(p).beginPopupFrame(id);
                return null;
            }
            fn showPopupFn(p: *anyopaque, id: u32) anyerror!void {
                if (@hasDecl(T, "showPopup")) return self(p).showPopup(id);
            }
            fn closeFn(p: *anyopaque) void {
                if (@hasDecl(T, "close")) self(p).close();
            }
            fn copyFn(p: *anyopaque, text: []const u8) void {
                const s = self(p);
                if (@hasDecl(T, "copy")) s.copy(text) else if (@hasField(T, "clipboard")) s.clipboard.copy(text);
            }
            fn pasteFn(p: *anyopaque, sink: clipboard.Sink) void {
                const s = self(p);
                if (@hasDecl(T, "paste")) s.paste(sink) else if (@hasField(T, "clipboard")) s.clipboard.paste(sink);
            }
            const vt = VTable{
                .platform = platformFn,
                .bufferTransport = bufferTransportFn,
                .bufferSync = bufferSyncFn,
                .frameSync = frameSyncFn,
                .refreshHz = refreshHzFn,
                .extensions = extensionsFn,
                .decorations = decorationsFn,
                .title = titleFn,
                .poll = pollFn,
                .wait = waitFn,
                .takeInput = takeInputFn,
                .size = sizeFn,
                .scale = scaleFn,
                .isClosed = isClosedFn,
                .isSuspended = isSuspendedFn,
                .isMaximized = isMaximizedFn,
                .isFullscreen = isFullscreenFn,
                .isTiled = isTiledFn,
                .isFramePending = isFramePendingFn,
                .setCursor = setCursorFn,
                .setMinSize = setMinSizeFn,
                .setMaximized = setMaximizedFn,
                .setMinimized = setMinimizedFn,
                .canMaximize = canMaximizeFn,
                .canMinimize = canMinimizeFn,
                .setFullscreen = setFullscreenFn,
                .startMove = startMoveFn,
                .setTextInput = setTextInputFn,
                .startDrag = startDragFn,
                .takeDrop = takeDropFn,
                .nextPresentationNs = nextPresentationNsFn,
                .setPresentationTime = setPresentationTimeFn,
                .layout = layoutFn,
                .refreshNs = refreshNsFn,
                .applyConfigure = applyConfigureFn,
                .releaseSpareBuffers = releaseSpareBuffersFn,
                .beginFrame = beginFrameFn,
                .beginDmabufFrame = beginDmabufFrameFn,
                .bufferAge = bufferAgeFn,
                .finishFrame = finishFrameFn,
                .showDamaged = showDamagedFn,
                .close = closeFn,
                .supportsPopups = supportsPopupsFn,
                .openPopup = openPopupFn,
                .closePopup = closePopupFn,
                .popupPosition = popupPositionFn,
                .beginPopupFrame = beginPopupFrameFn,
                .showPopup = showPopupFn,
                .copy = if (@hasDecl(T, "copy") or @hasField(T, "clipboard")) copyFn else null,
                .paste = if (@hasDecl(T, "paste") or @hasField(T, "clipboard")) pasteFn else null,
            };
        };
        return .{ .ptr = @ptrCast(@constCast(impl)), .vtable = &gen.vt };
    }

    pub fn platform(w: Window) Platform {
        return w.vtable.platform(w.ptr);
    }
    pub fn bufferTransport(w: Window) BufferTransport {
        return w.vtable.bufferTransport(w.ptr);
    }
    pub fn bufferSync(w: Window) BufferSync {
        return w.vtable.bufferSync(w.ptr);
    }
    pub fn frameSync(w: Window) FrameSync {
        return w.vtable.frameSync(w.ptr);
    }
    pub fn refreshHz(w: Window) f32 {
        return w.vtable.refreshHz(w.ptr);
    }
    /// The window system's protocol extensions the window uses (for
    /// Wayland, the global interfaces bound).
    pub fn extensions(w: Window) []const []const u8 {
        return w.vtable.extensions(w.ptr);
    }
    pub fn decorations(w: Window) Decorations {
        return w.vtable.decorations(w.ptr);
    }
    pub fn title(w: Window) []const u8 {
        return w.vtable.title(w.ptr);
    }
    pub fn poll(w: Window) !void {
        return w.vtable.poll(w.ptr);
    }
    pub fn wait(w: Window, timeout_ns: u64) !void {
        return w.vtable.wait(w.ptr, timeout_ns);
    }
    pub fn takeInput(w: Window) []const InputEvent {
        return w.vtable.takeInput(w.ptr);
    }
    pub fn size(w: Window) [2]u32 {
        return w.vtable.size(w.ptr);
    }
    pub fn scale(w: Window) u32 {
        return w.vtable.scale(w.ptr);
    }
    pub fn isClosed(w: Window) bool {
        return w.vtable.isClosed(w.ptr);
    }
    pub fn isSuspended(w: Window) bool {
        return w.vtable.isSuspended(w.ptr);
    }
    pub fn isMaximized(w: Window) bool {
        return w.vtable.isMaximized(w.ptr);
    }
    pub fn isFullscreen(w: Window) bool {
        return w.vtable.isFullscreen(w.ptr);
    }
    pub fn isTiled(w: Window) bool {
        return w.vtable.isTiled(w.ptr);
    }
    /// Whether the last frame shown is still waiting for the windowing
    /// system to be ready for the next (drawing one now would only wait).
    pub fn isFramePending(w: Window) bool {
        return w.vtable.isFramePending(w.ptr);
    }
    pub fn setCursor(w: Window, cursor: Cursor) void {
        w.vtable.setCursor(w.ptr, cursor);
    }
    pub fn setMinSize(w: Window, width: u32, height: u32) void {
        w.vtable.setMinSize(w.ptr, width, height);
    }
    /// Hides the window (to the dock or task bar); the window system
    /// shows it again.
    pub fn setMinimized(w: Window) void {
        w.vtable.setMinimized(w.ptr);
    }
    /// Whether the window system can maximize (or minimize) the window.
    pub fn canMaximize(w: Window) bool {
        return w.vtable.canMaximize(w.ptr);
    }
    pub fn canMinimize(w: Window) bool {
        return w.vtable.canMinimize(w.ptr);
    }
    pub fn setMaximized(w: Window, on: bool) void {
        w.vtable.setMaximized(w.ptr, on);
    }
    pub fn setFullscreen(w: Window, on: bool) void {
        w.vtable.setFullscreen(w.ptr, on);
    }
    pub fn startMove(w: Window) void {
        w.vtable.startMove(w.ptr);
    }
    pub fn setTextInput(w: Window, state: ?TextInputState) void {
        w.vtable.setTextInput(w.ptr, state);
    }
    pub fn startDrag(w: Window, mime_type: []const u8, bytes: []const u8, actions: u32) bool {
        return w.vtable.startDrag(w.ptr, mime_type, bytes, actions);
    }
    pub fn takeDrop(w: Window) ?DroppedData {
        return w.vtable.takeDrop(w.ptr);
    }
    /// Says the next frame shown is drawn for `target_ns` (on the monotonic
    /// clock, as `nextPresentationNs` gives): a window that can, does not
    /// show it before then.
    pub fn setPresentationTime(w: Window, target_ns: u64) void {
        w.vtable.setPresentationTime(w.ptr, target_ns);
    }
    pub fn nextPresentationNs(w: Window, now_ns: u64) u64 {
        return w.vtable.nextPresentationNs(w.ptr, now_ns);
    }
    /// The keyboard layout in use.
    pub fn layout(w: Window) Layout {
        return w.vtable.layout(w.ptr);
    }
    /// The display's refresh period, or 0 if unknown.
    pub fn refreshNs(w: Window) u64 {
        return w.vtable.refreshNs(w.ptr);
    }
    /// Applies the size the windowing system last asked for; returns it if
    /// it changed.
    pub fn applyConfigure(w: Window) !?[2]u32 {
        return w.vtable.applyConfigure(w.ptr);
    }
    /// Frees buffers not needed while the window is not shown.
    pub fn releaseSpareBuffers(w: Window) void {
        w.vtable.releaseSpareBuffers(w.ptr);
    }
    /// The buffer to draw the next frame into.
    pub fn beginFrame(w: Window) !gfx.software.Image {
        return w.vtable.beginFrame(w.ptr);
    }
    /// The buffer to draw the next frame into, as a dmabuf for the GPU to
    /// draw into directly (instead of `beginFrame`), or null if it is not one.
    pub fn beginDmabufFrame(w: Window) ?gfx.DmabufTarget {
        return w.vtable.beginDmabufFrame(w.ptr);
    }
    /// How many frames ago `beginFrame`'s buffer was last drawn: 1 if in
    /// the frame before, 0 if never.
    pub fn bufferAge(w: Window) u32 {
        return w.vtable.bufferAge(w.ptr);
    }
    /// Draws the window's own decorations over the `repainted` parts of
    /// the frame (or all of it if null).
    pub fn finishFrame(w: Window, repainted: ?[]const gfx.Viewport) void {
        w.vtable.finishFrame(w.ptr, repainted);
    }
    /// Shows the frame, telling the system what of it changed (or all of
    /// it if null).
    pub fn showDamaged(w: Window, damage: ?[]const gfx.Viewport) !void {
        return w.vtable.showDamaged(w.ptr, damage);
    }
    /// Closes the window and frees it.
    /// Opens a surface of its own over the window (and maybe beyond it),
    /// placed as `placement` says: its id, or null if the window cannot.
    /// A frame is drawn in it with `beginPopupFrame` and `showPopup`.
    pub fn supportsPopups(w: Window) bool {
        return w.vtable.supportsPopups(w.ptr);
    }
    pub fn openPopup(w: Window, placement: PopupPlacement) ?u32 {
        return w.vtable.openPopup(w.ptr, placement);
    }
    /// Closes the popup (popups are closed newest first).
    pub fn closePopup(w: Window, id: u32) void {
        w.vtable.closePopup(w.ptr, id);
    }
    /// Where the window system put the popup (in the window's
    /// coordinates), once it has.
    pub fn popupPosition(w: Window, id: u32) ?[2]i32 {
        return w.vtable.popupPosition(w.ptr, id);
    }
    /// The buffer to draw the popup's next frame into (all of it), or null
    /// if it cannot be drawn yet.
    pub fn beginPopupFrame(w: Window, id: u32) !?gfx.software.Image {
        return w.vtable.beginPopupFrame(w.ptr, id);
    }
    pub fn showPopup(w: Window, id: u32) !void {
        return w.vtable.showPopup(w.ptr, id);
    }
    pub fn close(w: Window) void {
        w.vtable.close(w.ptr);
    }
    /// Whether the window has the system's clipboard (`copy`, `paste`).
    pub fn hasClipboard(w: Window) bool {
        return w.vtable.copy != null and w.vtable.paste != null;
    }
    pub fn copy(w: Window, text: []const u8) void {
        if (w.vtable.copy) |f| f(w.ptr, text);
    }
    pub fn paste(w: Window, sink: clipboard.Sink) void {
        if (w.vtable.paste) |f| f(w.ptr, sink) else sink.f(sink.ctx, null);
    }
};

/// What an app's title bar does to its window (for the toolkit's TitleBar:
/// `.on_close = .of(&controls, Controls.close)`, and so on).
pub const Controls = struct {
    win: ?Window = null,
    /// The close button was pressed: the app should end.
    quit: bool = false,

    pub fn init(impl: anytype) Controls {
        return .{ .win = Window.from(impl) };
    }

    pub fn close(c: *Controls) void {
        c.quit = true;
    }

    /// The minimize button: hide the window.
    pub fn minimize(c: *Controls) void {
        if (c.win) |w| w.setMinimized();
    }

    /// The maximize button: fill the screen, or go back to the window's
    /// own size.
    pub fn toggleMaximized(c: *Controls) void {
        if (c.win) |w| w.setMaximized(!w.isMaximized());
    }

    /// Toggle whether the window fills the entire display (fullscreen).
    pub fn toggleFullscreen(c: *Controls) void {
        if (c.win) |w| w.setFullscreen(!w.isFullscreen());
    }

    /// The title bar was pressed: drag the window (unless it fills the
    /// screen).
    pub fn drag(c: *Controls) void {
        if (c.win) |w| if (!w.isMaximized()) w.startMove();
    }
};

/// Keymaps: what each key types, from the compositor.
pub const xkb = @import("xkb.zig");

/// The keyboard layout in use: its name ("English (UK)") and XKB code
/// ("gb"), from the keymap the compositor gave.
pub const Layout = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    code_buf: [32]u8 = undefined,
    code_len: u8 = 0,

    pub fn init(name_: []const u8, code_: []const u8) Layout {
        var l: Layout = .{};
        l.name_len = @intCast(@min(name_.len, l.name_buf.len));
        @memcpy(l.name_buf[0..l.name_len], name_[0..l.name_len]);
        l.code_len = @intCast(@min(code_.len, l.code_buf.len));
        @memcpy(l.code_buf[0..l.code_len], code_[0..l.code_len]);
        return l;
    }

    /// Its name, or "" if no keymap has been given.
    pub fn name(l: *const Layout) []const u8 {
        return l.name_buf[0..l.name_len];
    }

    pub fn code(l: *const Layout) []const u8 {
        return l.code_buf[0..l.code_len];
    }
};

test {
    _ = clipboard;
    _ = wayland;
    _ = xkb;
}
