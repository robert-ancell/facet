//! Window abstraction (`Window` vtable interface), input events (`InputEvent`),
//! text input state (`TextInputState`), window controls (`Controls`), keyboard
//! layout (`Keyboard`), and the built-in Wayland client window backend
//! (`WaylandWindow`).
//!
//! Apps can either use `WaylandWindow` directly or implement custom window
//! backends (e.g. X11, SDL, GLFW, macOS, Windows) via `Window.of(&impl)`.

const std = @import("std");
const wayland_proto = @import("wayland").protocol;

pub const clipboard = @import("clipboard.zig");
pub const wayland = @import("wayland.zig");

pub const Clipboard = clipboard.Clipboard;
pub const DroppedData = clipboard.DroppedData;
pub const WaylandWindow = wayland.WaylandWindow;
pub const CursorShape = wayland_proto.wp_cursor_shape_device_v1.shape;
pub const TextInputProtocol = wayland_proto.zwp_text_input_v3;
pub const nowNs = clipboard.nowNs;

pub const TextInputState = struct {
    surrounding_text: []const u8 = "",
    cursor: u32 = 0,
    anchor: u32 = 0,
    change_cause: u32 = TextInputProtocol.change_cause.input_method,
    content_hint: u32 = TextInputProtocol.content_hint.none,
    content_purpose: u32 = TextInputProtocol.content_purpose.normal,
    cursor_rect: [4]i32 = .{ 0, 0, 1, 20 },

    pub fn eql(a: TextInputState, b: TextInputState) bool {
        return a.cursor == b.cursor and
            a.anchor == b.anchor and
            a.change_cause == b.change_cause and
            a.content_hint == b.content_hint and
            a.content_purpose == b.content_purpose and
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
    key: struct { code: u32, pressed: bool },
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
};

/// Generic window interface (`Window.of(&impl)`).
pub const Window = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
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
        setCursor: *const fn (ptr: *anyopaque, shape: u32) void,
        setMinSize: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
        setMaximized: *const fn (ptr: *anyopaque, on: bool) void,
        setFullscreen: *const fn (ptr: *anyopaque, on: bool) void,
        startMove: *const fn (ptr: *anyopaque) void,
        setTextInput: *const fn (ptr: *anyopaque, state: ?TextInputState) void,
        startDrag: *const fn (ptr: *anyopaque, mime_type: []const u8, bytes: []const u8, actions: u32) bool,
        takeDrop: *const fn (ptr: *anyopaque) ?DroppedData,
        nextPresentationNs: *const fn (ptr: *anyopaque, now_ns: u64) u64,
        layout: *const fn (ptr: *anyopaque) Keyboard,
        copy: ?*const fn (ptr: *anyopaque, text: []const u8) void = null,
        paste: ?*const fn (ptr: *anyopaque, sink: clipboard.Sink) void = null,
    };

    pub fn of(impl: anytype) Window {
        const Ptr = @TypeOf(impl);
        const T = @typeInfo(Ptr).pointer.child;
        const gen = struct {
            fn self(p: *anyopaque) *T {
                return @ptrCast(@alignCast(p));
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
                if (@hasDecl(T, " getScale")) return s.getScale();
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
            fn setCursorFn(p: *anyopaque, shape: u32) void {
                if (@hasDecl(T, "setCursor")) self(p).setCursor(shape);
            }
            fn setMinSizeFn(p: *anyopaque, w: u32, h: u32) void {
                if (@hasDecl(T, "setMinSize")) self(p).setMinSize(w, h);
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
            fn nextPresentationNsFn(p: *anyopaque, now_ns: u64) u64 {
                if (@hasDecl(T, "nextPresentationNs")) return self(p).nextPresentationNs(now_ns);
                return now_ns;
            }
            fn layoutFn(p: *anyopaque) Keyboard {
                const s = self(p);
                if (@hasField(T, "layout")) return s.layout;
                return .us;
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
                .setCursor = setCursorFn,
                .setMinSize = setMinSizeFn,
                .setMaximized = setMaximizedFn,
                .setFullscreen = setFullscreenFn,
                .startMove = startMoveFn,
                .setTextInput = setTextInputFn,
                .startDrag = startDragFn,
                .takeDrop = takeDropFn,
                .nextPresentationNs = nextPresentationNsFn,
                .layout = layoutFn,
                .copy = if (@hasDecl(T, "copy") or @hasField(T, "clipboard")) copyFn else null,
                .paste = if (@hasDecl(T, "paste") or @hasField(T, "clipboard")) pasteFn else null,
            };
        };
        return .{ .ptr = @ptrCast(@constCast(impl)), .vtable = &gen.vt };
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
    pub fn setCursor(w: Window, shape: u32) void {
        w.vtable.setCursor(w.ptr, shape);
    }
    pub fn setMinSize(w: Window, width: u32, height: u32) void {
        w.vtable.setMinSize(w.ptr, width, height);
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
    pub fn nextPresentationNs(w: Window, now_ns: u64) u64 {
        return w.vtable.nextPresentationNs(w.ptr, now_ns);
    }
    pub fn layout(w: Window) Keyboard {
        return w.vtable.layout(w.ptr);
    }
};

/// What an app's title bar does to its window (for the toolkit's TitleBar:
/// `.on_close = .of(&controls, Controls.close)`, and so on).
pub const Controls = struct {
    win: ?Window = null,
    /// The close button was pressed: the app should end.
    quit: bool = false,

    pub fn init(impl: anytype) Controls {
        if (@TypeOf(impl) == Window) return .{ .win = impl };
        return .{ .win = Window.of(impl) };
    }

    pub fn close(c: *Controls) void {
        c.quit = true;
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

/// The keyboard layouts: which character each key types (by Linux key
/// code), alone, with Shift, and with AltGr (the right Alt).
pub const Keyboard = enum {
    us,
    gb,

    pub fn name(k: Keyboard) []const u8 {
        return switch (k) {
            .us => "English (US)",
            .gb => "English (UK)",
        };
    }

    /// Its XKB name.
    pub fn code(k: Keyboard) []const u8 {
        return @tagName(k);
    }

    pub fn fromCode(text_: []const u8) ?Keyboard {
        return std.meta.stringToEnum(Keyboard, text_);
    }

    /// The keys that type characters, and what they type.
    pub fn keys(k: Keyboard) []const Key {
        return switch (k) {
            .us => &us_keys,
            .gb => &gb_keys,
        };
    }

    /// The character a key types, if it types one. Caps Lock shifts
    /// letters only.
    pub fn char(k: Keyboard, key_code: u32, shift: bool, caps: bool, altgr: bool) ?u21 {
        for (k.keys()) |key| if (key.code == key_code) {
            if (altgr) return key.altgr;
            const letter = key.plain >= 'a' and key.plain <= 'z';
            const up = if (letter) shift != caps else shift;
            return if (up) key.shifted else key.plain;
        };
        if (altgr) return null;
        return switch (key_code) {
            55 => '*',
            71 => '7',
            72 => '8',
            73 => '9',
            74 => '-',
            75 => '4',
            76 => '5',
            77 => '6',
            78 => '+',
            79 => '1',
            80 => '2',
            81 => '3',
            82 => '0',
            83 => '.',
            98 => '/',
            117 => '=',
            else => null,
        };
    }
};

pub const Key = struct {
    code: u8,
    plain: u21,
    shifted: u21,
    altgr: ?u21 = null,
};

fn row(comptime first: u8, comptime plain: []const u8, comptime shifted: []const u8) [plain.len]Key {
    var out: [plain.len]Key = undefined;
    for (&out, plain, shifted, 0..) |*k, p, s, i| k.* = .{ .code = first + i, .plain = p, .shifted = s };
    return out;
}

const us_keys = row(2, "1234567890-=", "!@#$%^&*()_+") ++
    row(16, "qwertyuiop[]", "QWERTYUIOP{}") ++
    row(30, "asdfghjkl;'`", "ASDFGHJKL:\"~") ++
    [_]Key{.{ .code = 43, .plain = '\\', .shifted = '|' }} ++
    row(44, "zxcvbnm,./", "ZXCVBNM<>?") ++
    [_]Key{
        .{ .code = 57, .plain = ' ', .shifted = ' ' },
        .{ .code = 86, .plain = '<', .shifted = '>' },
    };

const gb_keys = blk: {
    var keys = us_keys;
    for (&keys) |*k| switch (k.code) {
        3 => k.shifted = '"',
        4 => k.shifted = '£',
        5 => k.altgr = '€',
        40 => k.shifted = '@',
        41 => {
            k.shifted = '¬';
            k.altgr = '¦';
        },
        43 => {
            k.plain = '#';
            k.shifted = '~';
        },
        86 => {
            k.plain = '\\';
            k.shifted = '|';
        },
        else => {},
    };
    break :blk keys;
};

test {
    _ = clipboard;
    _ = wayland;
}
