//! Win32Window: a native Windows window (a Win32 `HWND`, with the system's
//! own title bar, buttons, resizing and full screen), and facet's
//! `InputEvent`s from its messages: Windows' scan codes become the Linux
//! key codes the toolkit uses, and each key's character is the `WM_CHAR`
//! that `TranslateMessage` makes of it (so dead keys and the keyboard's
//! layout work as everywhere else on Windows).
//!
//! It is single-threaded, and is built not to drop frames:
//!
//! * One wait for everything (`wait`): `MsgWaitForMultipleObjectsEx` on
//!   the window's messages, the watched sources' handles, and a
//!   high-resolution waitable timer for the frame's deadline (not the
//!   default 15.6 ms tick).
//! * Frames drawn on the GPU go to a flip-model swap chain with a frame
//!   latency waitable object (see `gfx.d3d11.SwapChain`), which the wait
//!   includes: a frame is drawn as soon as a buffer is free (just after a
//!   refresh), with the input read just before, and `Present` never
//!   blocks. The frames say what changed (dirty rectangles), so that DWM
//!   composes only that; out of sight (occluded or minimized), none are
//!   drawn.
//! * Frames are timed by the display: DWM's composition timing says when
//!   the next refresh is, and how long each is (for frames drawn on the
//!   CPU, which have no swap chain to say).
//! * Windows' modal loops (resizing or moving the window, holding its
//!   title bar, the system menu) hold the app's loop until they end; while
//!   they run, frames are drawn from inside them (`Window.setRedraw`): at
//!   each new size, and at each refresh from a message posted to itself
//!   that waits for the refresh (but returns at once for input).
//!
//! The Windows API is loaded at run time (see `gfx.winapi`), so nothing is
//! linked but kernel32.

const std = @import("std");
const gfx = @import("gfx");
const window = @import("window.zig");
const clipboard = @import("clipboard.zig");
const keys = @import("win32_keys.zig");

const w32 = gfx.winapi;
const InputEvent = window.InputEvent;
const HWND = w32.HWND;
const UINT = w32.UINT;
const WPARAM = w32.WPARAM;
const LPARAM = w32.LPARAM;
const LRESULT = w32.LRESULT;

const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;
const btn_side = 0x113;
const btn_extra = 0x114;

// Messages.
const WM_DESTROY = 0x0002;
const WM_SIZE = 0x0005;
const WM_KILLFOCUS = 0x0008;
const WM_PAINT = 0x000f;
const WM_CLOSE = 0x0010;
const WM_ERASEBKGND = 0x0014;
const WM_SETTINGCHANGE = 0x001a;
const WM_SETCURSOR = 0x0020;
const WM_GETMINMAXINFO = 0x0024;
const WM_DISPLAYCHANGE = 0x007e;
const WM_NCCREATE = 0x0081;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_CHAR = 0x0102;
const WM_DEADCHAR = 0x0103;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_SYSCHAR = 0x0106;
const WM_TIMER = 0x0113;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEWHEEL = 0x020a;
const WM_XBUTTONDOWN = 0x020b;
const WM_XBUTTONUP = 0x020c;
const WM_MOUSEHWHEEL = 0x020e;
const WM_ENTERMENULOOP = 0x0211;
const WM_EXITMENULOOP = 0x0212;
const WM_ENTERSIZEMOVE = 0x0231;
const WM_EXITSIZEMOVE = 0x0232;
const WM_CAPTURECHANGED = 0x0215;
const WM_MOUSELEAVE = 0x02a3;
const WM_DPICHANGED = 0x02e0;
/// Posted to itself while a modal loop runs: draw the next frame.
const WM_APP_FRAME = 0x8000 + 1;

const WS_OVERLAPPEDWINDOW: w32.DWORD = 0x00cf0000;
const WS_POPUP: w32.DWORD = 0x80000000;
const WS_VISIBLE: w32.DWORD = 0x10000000;
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
const GWLP_USERDATA: c_int = -21;
const GWL_STYLE: c_int = -16;
const SW_SHOW = 5;
const SW_MAXIMIZE = 3;
const SW_MINIMIZE = 6;
const SW_RESTORE = 9;
const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;
const SWP_FRAMECHANGED: UINT = 0x0020;
const SWP_NOOWNERZORDER: UINT = 0x0200;
const SWP_NOMOVE: UINT = 0x0002;
const PM_REMOVE: UINT = 1;
const PM_NOREMOVE: UINT = 0;
const QS_ALLINPUT: w32.DWORD = 0x04ff;
const QS_INPUT: UINT = 0x0407;
const MWMO_INPUTAVAILABLE: w32.DWORD = 0x0004;
const HTCLIENT = 1;
const TME_LEAVE: w32.DWORD = 2;
const CF_UNICODETEXT: UINT = 13;
const SPI_GETWHEELSCROLLLINES: UINT = 0x68;
const MONITOR_DEFAULTTONEAREST: w32.DWORD = 2;
const DWMWA_USE_IMMERSIVE_DARK_MODE: w32.DWORD = 20;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const MAPVK_VK_TO_VSC_EX: UINT = 4;
const WHEEL_DELTA = 120;
const SIZE_MINIMIZED = 1;
const frame_timer_id: usize = 1;
const max_watched = 8;

pub const Win32Window = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    hwnd: HWND,
    title_buf: []u8,
    /// The client area in logical pixels (its pixels over `scale`, rounded
    /// up), and how many pixels each is (the monitor's DPI over 96, rounded:
    /// facet's scales are whole).
    width: u32,
    height: u32,
    scale: u32 = 1,
    /// The client area in pixels.
    pixel_size: [2]u32 = .{ 0, 0 },
    closed: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    minimized: bool = false,
    /// The placement and style to go back to from full screen.
    restore: w32.WINDOWPLACEMENT = .{},
    restore_style: isize = 0,
    min_size: [2]u32 = .{ 1, 1 },
    cursor: window.Cursor = .default,
    /// Whether the pointer is in the window (its leaving is tracked), and
    /// the buttons held (the window has the mouse while any is).
    pointer_in: bool = false,
    buttons_held: u32 = 0,
    /// Where the pointer last was in the window, in logical pixels (where
    /// the wheel turns: its messages say where on the screen).
    last_pointer: [2]f32 = .{ 0, 0 },
    /// The system's appearance, as last read (on open and when Settings
    /// changes it).
    dark: ?bool = null,
    /// A display refresh lasts this long, and the frame given last is shown
    /// at `presented_ns` (the refresh after it was given): the next waits
    /// until then.
    refresh_ns: u64 = std.time.ns_per_s / 60,
    frame_pending: bool = false,
    presented_ns: u64 = 0,
    /// What draws a frame from inside Windows' modal loops (see
    /// `window.Window.setRedraw`), and whether one is running.
    redraw: ?window.Redraw = null,
    in_modal: bool = false,
    /// A frame message is in the queue (there is never more than one).
    frame_posted: bool = false,
    /// Events since the last `takeInput`, and those it gave.
    input: std.ArrayList(InputEvent) = .empty,
    taken: std.ArrayList(InputEvent) = .empty,
    /// The swap chain the GPU's frames go to (made on the renderer's device
    /// when it first draws), its back buffer while a frame is drawn in it,
    /// whether it has a buffer free (its waitable object signalled, and so
    /// taken), and the size of the last frame drawn there (0 by 0: none
    /// yet), which the renderer keeps from one to the next. And whether
    /// the window is out of sight (its frames would not be seen).
    swap: ?gfx.d3d11.SwapChain = null,
    back: ?*anyopaque = null,
    swap_ready: bool = false,
    on_gpu: bool = false,
    gpu_size: [2]u32 = .{ 0, 0 },
    occluded: bool = false,
    /// The CPU's frame (pixels a row at a time, top first, 0xAARRGGBB),
    /// shown with GDI; and whether it has been shown at this size.
    pixels: []u32 = &.{},
    pixels_size: [2]u32 = .{ 0, 0 },
    pixels_shown: bool = false,
    /// What `wait` waits on as well as the window's messages, and the
    /// high-resolution timer for its deadline.
    watched: [max_watched]?window.Source = @splat(null),
    timer: ?w32.HANDLE = null,
    /// The pending high surrogate of a character `WM_CHAR` gives in two.
    high_surrogate: u16 = 0,

    pub const platform: window.Platform = .windows;
    pub const decorations: window.Decorations = .server;

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = .{ 960, 640 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
    };

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("FacetWindow");

    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !*Win32Window {
        _ = environ;
        const u = w32.user32() orelse return error.NoUser32;
        // Each monitor's own DPI, told as it changes (Windows 10 1703 on).
        _ = u.SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        const instance: ?w32.HINSTANCE = @ptrCast(w32.GetModuleHandleW(null));
        registerClass(u, instance);

        const w = try gpa.create(Win32Window);
        errdefer gpa.destroy(w);
        w.* = .{
            .gpa = gpa,
            .io = io,
            .hwnd = undefined,
            .title_buf = try gpa.dupe(u8, options.title),
            .width = options.size[0],
            .height = options.size[1],
        };
        errdefer gpa.free(w.title_buf);
        if (options.min_size) |m| w.min_size = m;

        var title_w: [256]u16 = undefined;
        // Sized for its DPI once it has one (WM_DPICHANGED, or below).
        const hwnd = u.CreateWindowExW(0, class_name, w32.wide(&title_w, options.title).ptr, WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, null, null, instance, w) orelse return error.CreateWindowFailed;
        w.hwnd = hwnd;
        w.updateScale(u);
        w.resizeTo(u, options.size);
        w.dark = w32.appsUseDark();
        w.applyDarkTitleBar();
        w.updateRefresh();
        w.timer = w32.CreateWaitableTimerExW(null, null, w32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, w32.TIMER_ALL_ACCESS);
        _ = u.ShowWindow(hwnd, if (options.maximized) SW_MAXIMIZE else SW_SHOW);
        _ = try w.applyConfigure();
        return w;
    }

    fn registerClass(u: *const w32.User32, instance: ?w32.HINSTANCE) void {
        const S = struct {
            var done = false;
        };
        if (S.done) return;
        S.done = true;
        const wc: w32.WNDCLASSEXW = .{
            // CS_HREDRAW | CS_VREDRAW: not needed (nothing is stretched),
            // and no background brush (WM_ERASEBKGND does nothing).
            .lpfnWndProc = wndProc,
            .hInstance = instance,
            .hCursor = u.LoadCursorW(null, 32512),
            .lpszClassName = class_name,
        };
        _ = u.RegisterClassExW(&wc);
    }

    pub fn close(w: *Win32Window) void {
        if (w32.user32()) |u| {
            _ = u.KillTimer(w.hwnd, frame_timer_id);
            _ = u.SetWindowLongPtrW(w.hwnd, GWLP_USERDATA, 0);
            _ = u.DestroyWindow(w.hwnd);
        }
        if (w.timer) |t| _ = w32.CloseHandle(t);
        w32.release(w.back);
        if (w.swap) |*sc| sc.deinit();
        w.gpa.free(w.pixels);
        w.input.deinit(w.gpa);
        w.taken.deinit(w.gpa);
        w.gpa.free(w.title_buf);
        w.gpa.destroy(w);
    }

    pub fn getTitle(w: *const Win32Window) []const u8 {
        return w.title_buf;
    }

    pub fn size(w: *const Win32Window) [2]u32 {
        return .{ w.width, w.height };
    }

    pub fn getScale(w: *const Win32Window) u32 {
        return w.scale;
    }

    pub fn refreshNs(w: *const Win32Window) u64 {
        return w.refresh_ns;
    }

    pub fn isSuspended(w: *const Win32Window) bool {
        return w.minimized or w.occluded;
    }

    pub fn prefersDark(w: *const Win32Window) ?bool {
        return w.dark;
    }

    /// Sets the window's size to `logical` (its client area, in logical
    /// pixels at its scale).
    fn resizeTo(w: *Win32Window, u: *const w32.User32, logical: [2]u32) void {
        var r: w32.RECT = .{ .right = @intCast(logical[0] * w.scale), .bottom = @intCast(logical[1] * w.scale) };
        const dpi = u.GetDpiForWindow(w.hwnd);
        _ = u.AdjustWindowRectExForDpi(&r, WS_OVERLAPPEDWINDOW, w32.FALSE, 0, if (dpi == 0) 96 else dpi);
        _ = u.SetWindowPos(w.hwnd, null, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    fn updateScale(w: *Win32Window, u: *const w32.User32) void {
        const dpi = u.GetDpiForWindow(w.hwnd);
        // 125% is 1, 150% and 175% are 2: facet's scales are whole.
        w.scale = if (dpi == 0) 1 else @max(1, (dpi + 48) / 96);
    }

    /// The display's refresh, from DWM.
    fn updateRefresh(w: *Win32Window) void {
        const t = w32.CompositionTiming.get() orelse return;
        const ns = w32.qpcToNs(@intCast(t.refresh_qpc));
        if (ns >= std.time.ns_per_ms) w.refresh_ns = ns;
    }

    /// The window's client area, and its state: its new logical size if
    /// it changed (or its scale did).
    pub fn applyConfigure(w: *Win32Window) !?[2]u32 {
        const u = w32.user32() orelse return null;
        var r: w32.RECT = .{};
        _ = u.GetClientRect(w.hwnd, &r);
        w.minimized = u.IsIconic(w.hwnd) != 0;
        if (w.occluded) if (w.swap) |*sc| {
            w.occluded = sc.occluded();
        };
        if (w.minimized) return null;
        w.maximized = !w.fullscreen and u.IsZoomed(w.hwnd) != 0;
        const old_scale = w.scale;
        w.updateScale(u);
        const pw: u32 = @intCast(@max(r.right - r.left, 1));
        const ph: u32 = @intCast(@max(r.bottom - r.top, 1));
        w.pixel_size = .{ pw, ph };
        // Rounded up: the frame covers the whole client area (its last row
        // and column cut off).
        const nw = (pw + w.scale - 1) / w.scale;
        const nh = (ph + w.scale - 1) / w.scale;
        if (nw == w.width and nh == w.height and old_scale == w.scale) return null;
        w.width = nw;
        w.height = nh;
        return .{ nw, nh };
    }

    // --- The window's messages ---------------------------------------------------------

    fn ofHwnd(hwnd: HWND) ?*Win32Window {
        const u = w32.user32() orelse return null;
        const p = u.GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (p == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(p)));
    }

    fn wndProc(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(w32.cc) LRESULT {
        const u = w32.user32().?;
        if (message == WM_NCCREATE) {
            // Its CREATESTRUCTW's first field: what CreateWindowExW was given.
            const create: *const ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = u.SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(create.*)));
            return u.DefWindowProcW(hwnd, message, wparam, lparam);
        }
        const w = ofHwnd(hwnd) orelse return u.DefWindowProcW(hwnd, message, wparam, lparam);
        if (w.handle(u, message, wparam, lparam)) |result| return result;
        return u.DefWindowProcW(hwnd, message, wparam, lparam);
    }

    /// Handles a message (null: as Windows does by default).
    fn handle(w: *Win32Window, u: *const w32.User32, message: UINT, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
        switch (message) {
            WM_CLOSE => {
                // The app closes it, when it has seen that it was asked to.
                w.closed = true;
                return 0;
            },
            WM_DESTROY => return 0,
            WM_ERASEBKGND => return 1,
            WM_PAINT => {
                var ps: w32.PAINTSTRUCT = undefined;
                if (u.BeginPaint(w.hwnd, &ps)) |hdc| {
                    // What was shown is shown again (it has not changed):
                    // DWM keeps the swap chain's, the CPU's is drawn again.
                    if (!w.on_gpu and w.pixels_shown) w.blit(hdc);
                    _ = u.EndPaint(w.hwnd, &ps);
                }
                return 0;
            },
            WM_SIZE => {
                w.minimized = wparam == SIZE_MINIMIZED;
                // While resized by its edge, each size is drawn at once.
                if (w.in_modal and !w.minimized) w.drawNow();
                return 0;
            },
            WM_GETMINMAXINFO => {
                const info: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                var r: w32.RECT = .{ .right = @intCast(w.min_size[0] * w.scale), .bottom = @intCast(w.min_size[1] * w.scale) };
                const dpi = u.GetDpiForWindow(w.hwnd);
                _ = u.AdjustWindowRectExForDpi(&r, WS_OVERLAPPEDWINDOW, w32.FALSE, 0, if (dpi == 0) 96 else dpi);
                info.ptMinTrackSize = .{ .x = r.right - r.left, .y = r.bottom - r.top };
                return 0;
            },
            WM_DPICHANGED => {
                // The size Windows suggests for the new DPI.
                const r: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = u.SetWindowPos(w.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
                return 0;
            },
            WM_DISPLAYCHANGE => {
                w.updateRefresh();
                return null;
            },
            WM_SETTINGCHANGE => {
                // "ImmersiveColorSet": light or dark may have changed.
                w.dark = w32.appsUseDark();
                w.applyDarkTitleBar();
                return null;
            },
            WM_SETCURSOR => {
                if ((@as(usize, @bitCast(lparam)) & 0xffff) != HTCLIENT) return null;
                _ = u.SetCursor(cursorHandle(u, w.cursor));
                return 1;
            },
            WM_ENTERSIZEMOVE, WM_ENTERMENULOOP => {
                w.enterModal(u);
                return null;
            },
            WM_EXITSIZEMOVE, WM_EXITMENULOOP => {
                w.exitModal(u);
                return null;
            },
            WM_APP_FRAME => {
                w.frame_posted = false;
                if (w.in_modal) w.modalFrame(u);
                return 0;
            },
            WM_TIMER => {
                if (wparam != frame_timer_id) return null;
                // Windows delivers timers only once input has been handled:
                // the frames go on from here if they stopped for input.
                if (w.in_modal and !w.frame_posted) w.modalFrame(u);
                return 0;
            },
            WM_CAPTURECHANGED => {
                w.buttons_held = 0;
                return null;
            },
            WM_KILLFOCUS => {
                w.high_surrogate = 0;
                return null;
            },
            WM_MOUSEMOVE => {
                if (!w.pointer_in) {
                    w.pointer_in = true;
                    var tme: w32.TRACKMOUSEEVENT = .{ .dwFlags = TME_LEAVE, .hwndTrack = w.hwnd };
                    _ = u.TrackMouseEvent(&tme);
                }
                w.last_pointer = w.pointAt(lparam);
                w.push(.{ .motion = w.last_pointer });
                return 0;
            },
            WM_MOUSELEAVE => {
                w.pointer_in = false;
                w.push(.leave);
                return 0;
            },
            WM_LBUTTONDOWN, WM_LBUTTONUP => return w.button(u, lparam, btn_left, message == WM_LBUTTONDOWN),
            WM_RBUTTONDOWN, WM_RBUTTONUP => return w.button(u, lparam, btn_right, message == WM_RBUTTONDOWN),
            WM_MBUTTONDOWN, WM_MBUTTONUP => return w.button(u, lparam, btn_middle, message == WM_MBUTTONDOWN),
            WM_XBUTTONDOWN, WM_XBUTTONUP => {
                const which = (wparam >> 16) & 0xffff;
                _ = w.button(u, lparam, if (which == 1) btn_side else btn_extra, message == WM_XBUTTONDOWN);
                return 1;
            },
            WM_MOUSEWHEEL, WM_MOUSEHWHEEL => {
                const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                var lines: UINT = 3;
                _ = u.SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
                // A notch is `lines` lines, of about ten pixels each (as on
                // macOS); up and right are positive.
                const px = @as(f32, @floatFromInt(delta)) / WHEEL_DELTA * @as(f32, @floatFromInt(@min(lines, 100))) * 10;
                // The wheel's position is on the screen: the pointer's last
                // in the window is used instead.
                const pos = w.last_pointer;
                if (message == WM_MOUSEWHEEL) {
                    w.push(.{ .scroll = .{ .pos = pos, .dx = 0, .dy = -px } });
                } else {
                    w.push(.{ .scroll = .{ .pos = pos, .dx = px, .dy = 0 } });
                }
                return 0;
            },
            WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP => {
                w.key(u, wparam, lparam, message == WM_KEYDOWN or message == WM_SYSKEYDOWN);
                // Alt and F10 keep their system meanings (Alt+F4, the
                // system menu).
                return if (message == WM_SYSKEYDOWN or message == WM_SYSKEYUP) null else 0;
            },
            WM_CHAR => {
                // A character with no key down before it (typed with Alt
                // and the keypad, or given by an input method).
                if (w.charOf(@intCast(wparam & 0xffff))) |ch| w.push(.{ .key = .{ .code = 0, .pressed = true, .char = ch } });
                return 0;
            },
            WM_SYSCHAR => {
                // Alt and a letter would beep (there is no menu bar); Alt
                // and Space opens the system menu.
                return if (wparam == ' ') null else 0;
            },
            else => return null,
        }
    }

    fn push(w: *Win32Window, e: InputEvent) void {
        w.input.append(w.gpa, e) catch {};
    }

    pub fn takeInput(w: *Win32Window) []const InputEvent {
        w.taken.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(InputEvent), &w.input, &w.taken);
        return w.taken.items;
    }

    /// Where a mouse message's pointer is, in logical pixels.
    fn pointAt(w: *const Win32Window, lparam: LPARAM) [2]f32 {
        const bits: usize = @bitCast(lparam);
        const x: i16 = @bitCast(@as(u16, @truncate(bits)));
        const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
        const s: f32 = @floatFromInt(w.scale);
        return .{ @as(f32, @floatFromInt(x)) / s, @as(f32, @floatFromInt(y)) / s };
    }

    fn button(w: *Win32Window, u: *const w32.User32, lparam: LPARAM, code: u32, pressed: bool) LRESULT {
        const pos = w.pointAt(lparam);
        w.last_pointer = pos;
        // The window has the mouse while a button is held (a drag goes on
        // outside it).
        const bit: u32 = @as(u32, 1) << @intCast(code - btn_left);
        if (pressed) {
            if (w.buttons_held == 0) _ = u.SetCapture(w.hwnd);
            w.buttons_held |= bit;
        } else {
            w.buttons_held &= ~bit;
            if (w.buttons_held == 0) _ = u.ReleaseCapture();
        }
        w.push(.{ .button = .{ .pos = pos, .code = code, .pressed = pressed } });
        return 0;
    }

    fn key(w: *Win32Window, u: *const w32.User32, wparam: WPARAM, lparam: LPARAM, pressed: bool) void {
        const vk: u32 = @intCast(wparam & 0xffff);
        var k = keys.scanOf(lparam);
        // Injected keys may come without a scan code.
        if (k.scan == 0) {
            const sc = u.MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX);
            k = .{ .scan = sc & 0xff, .extended = sc & 0xff00 == 0xe000 };
        }
        const code = keys.linuxKey(k.scan, k.extended, vk);
        const shift = u.GetKeyState(VK_SHIFT) < 0;
        const alt = u.GetKeyState(VK_MENU) < 0;
        // AltGr is Ctrl and Alt together: what it types is not a shortcut.
        const ctrl = u.GetKeyState(VK_CONTROL) < 0 and !alt;
        // What it types: the WM_CHAR TranslateMessage put after it.
        var char: ?u21 = null;
        if (pressed) {
            // Two, for a character beyond the Basic Multilingual Plane (a
            // surrogate pair).
            var m: w32.MSG = undefined;
            for (0..2) |_| {
                if (u.PeekMessageW(&m, w.hwnd, WM_CHAR, WM_DEADCHAR, PM_REMOVE) == 0) break;
                // A dead key types nothing yet (the next key does).
                if (m.message == WM_DEADCHAR) break;
                if (w.charOf(@intCast(m.wParam & 0xffff))) |ch| {
                    char = ch;
                    break;
                }
                if (w.high_surrogate == 0) break;
            }
        }
        if (code == 0 and (char == null or ctrl)) return;
        w.push(.{ .key = .{ .code = code, .pressed = pressed, .char = if (ctrl) null else char, .shift = shift, .ctrl = ctrl } });
    }

    /// The character of a `WM_CHAR`'s UTF-16 unit (null for controls, and
    /// for the first half of a pair, kept for the second).
    fn charOf(w: *Win32Window, unit: u16) ?u21 {
        if (unit >= 0xd800 and unit < 0xdc00) {
            w.high_surrogate = unit;
            return null;
        }
        var ch: u21 = unit;
        if (unit >= 0xdc00 and unit < 0xe000) {
            if (w.high_surrogate == 0) return null;
            ch = 0x10000 + ((@as(u21, w.high_surrogate) - 0xd800) << 10) + (unit - 0xdc00);
        }
        w.high_surrogate = 0;
        if (ch < 0x20 or ch == 0x7f) return null;
        return ch;
    }

    // --- Waiting -------------------------------------------------------------------

    /// Handles the messages that have come, without waiting.
    pub fn poll(w: *Win32Window) !void {
        w.pump();
        w.updatePending();
    }

    /// Waits up to `timeout_ns` for a message or a watched source (and not
    /// past when the next frame can be drawn), and handles what came.
    pub fn wait(w: *Win32Window, timeout_ns: u64) !void {
        const u = w32.user32() orelse return;
        var ns = timeout_ns;
        var handles: [max_watched + 2]w32.HANDLE = undefined;
        var n: w32.DWORD = 0;
        if (w.on_gpu and w.swap != null) {
            // The swap chain says when a buffer is free.
            if (!w.swap_ready) {
                handles[n] = w.swap.?.waitable;
                n += 1;
            }
        } else if (w.frame_pending) ns = @min(ns, w.presented_ns -| w.now());
        // Out of sight, it is asked again now and then whether it shows.
        if (w.occluded) ns = @min(ns, 100 * std.time.ns_per_ms);
        for (w.watched) |slot| if (slot) |s| {
            handles[n] = s.fd;
            n += 1;
        };
        // A deadline to the 100 ns, on a high-resolution timer, rather than
        // to the millisecond (and the scheduler's tick).
        var ms: w32.DWORD = w32.INFINITE;
        if (ns != std.math.maxInt(u64)) {
            if (w.timer) |t| {
                const due: i64 = -@as(i64, @intCast(@max(ns / 100, 1)));
                if (w32.SetWaitableTimer(t, &due, 0, null, null, w32.FALSE) != 0) {
                    handles[n] = t;
                    n += 1;
                } else ms = msCeil(ns);
            } else ms = msCeil(ns);
        }
        const woke = u.MsgWaitForMultipleObjectsEx(n, &handles, ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (w.timer) |t| _ = w32.CancelWaitableTimer(t);
        // The swap chain's object, if it was first, was taken by the wait.
        if (w.on_gpu and !w.swap_ready and n > 0 and woke == w32.WAIT_OBJECT_0 and w.swap != null and handles[0] == w.swap.?.waitable) w.swap_ready = true;
        w.pump();
        w.updatePending();
    }

    fn msCeil(ns: u64) w32.DWORD {
        return @intCast(@min((ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, w32.INFINITE - 1));
    }

    /// Dispatches the messages there are.
    fn pump(w: *Win32Window) void {
        _ = w;
        const u = w32.user32() orelse return;
        var m: w32.MSG = undefined;
        while (u.PeekMessageW(&m, null, 0, 0, PM_REMOVE) != 0) {
            _ = u.TranslateMessage(&m);
            _ = u.DispatchMessageW(&m);
        }
    }

    /// Waits on `source` too (or stops, if not `on`): signalled, it wakes
    /// `wait` (a `sys.Wake` is an event, taken by the wait itself).
    pub fn watch(w: *Win32Window, source: window.Source, on: bool) void {
        for (&w.watched) |*slot| if (slot.*) |s| if (s.eql(source)) {
            if (!on) slot.* = null;
            return;
        };
        if (!on) return;
        for (&w.watched) |*slot| if (slot.* == null) {
            slot.* = source;
            return;
        };
    }

    fn now(w: *const Win32Window) u64 {
        return window.nowNs(w.io);
    }

    fn updatePending(w: *Win32Window) void {
        if (w.on_gpu) if (w.swap) |sc| {
            // Taken now if it is signalled (and so kept as `swap_ready`).
            if (!w.swap_ready and w32.WaitForSingleObject(sc.waitable, 0) == w32.WAIT_OBJECT_0) w.swap_ready = true;
            w.frame_pending = !w.swap_ready;
            return;
        };
        if (w.frame_pending and w.now() >= w.presented_ns) w.frame_pending = false;
    }

    /// When a frame drawn now would be shown: at the display's next refresh
    /// (as DWM says it is), on facet's clock.
    pub fn nextPresentationNs(w: *const Win32Window, now_ns: u64) u64 {
        if (w32.CompositionTiming.get()) |t| {
            const period = w32.qpcToNs(@intCast(t.refresh_qpc));
            const qpc_now = w32.nowQpc();
            const vblank = w32.qpcToNs(@intCast(t.vblank_qpc));
            const qnow = w32.qpcToNs(qpc_now);
            if (period > 0) {
                // The next refresh after now, on the performance counter,
                // moved to facet's clock.
                const ahead = if (vblank > qnow) vblank - qnow else period - ((qnow - vblank) % period);
                return now_ns + ahead;
            }
        }
        if (w.presented_ns == 0 or now_ns >= w.presented_ns + w.refresh_ns) return now_ns;
        return w.presented_ns + w.refresh_ns;
    }

    /// A frame has been given to be shown: the next waits for the refresh
    /// it is shown at.
    fn shown(w: *Win32Window) void {
        const t = w.now();
        w.presented_ns = w.nextPresentationNs(t);
        w.frame_pending = true;
    }

    // --- Windows' modal loops ----------------------------------------------------------

    pub fn setRedraw(w: *Win32Window, redraw: ?window.Redraw) void {
        w.redraw = redraw;
    }

    fn drawNow(w: *Win32Window) void {
        const r = w.redraw orelse return;
        r.f(r.ctx);
    }

    /// A modal loop has begun (resizing or moving the window, its title bar
    /// held, the system menu): frames are drawn from inside it, at each
    /// refresh, until it ends. A message posted to itself does that; the
    /// loop takes posted messages before input, so it is not posted again
    /// while input waits (the loop handles that first), and a timer, which
    /// comes after input, starts it again.
    fn enterModal(w: *Win32Window, u: *const w32.User32) void {
        if (w.in_modal) return;
        w.in_modal = true;
        _ = u.SetTimer(w.hwnd, frame_timer_id, @intCast(@max(w.refresh_ns / std.time.ns_per_ms, 1)), null);
        w.postFrame(u);
    }

    fn postFrame(w: *Win32Window, u: *const w32.User32) void {
        if (w.frame_posted) return;
        w.frame_posted = u.PostMessageW(w.hwnd, WM_APP_FRAME, 0, 0) != 0;
    }

    fn exitModal(w: *Win32Window, u: *const w32.User32) void {
        if (!w.in_modal) return;
        w.in_modal = false;
        _ = u.KillTimer(w.hwnd, frame_timer_id);
    }

    /// In a modal loop: waits for the next refresh (returning at once for
    /// input, which the loop then handles), draws a frame if one is wanted,
    /// and posts itself again for the next, unless input waits. It waits
    /// whether or not the last drew anything, so that a loop with nothing
    /// to draw does not spin.
    fn modalFrame(w: *Win32Window, u: *const w32.User32) void {
        if (u.GetQueueStatus(QS_INPUT) >> 16 == 0) {
            const gpu_wait = w.on_gpu and w.swap != null and !w.swap_ready;
            // Until a buffer is free, on the GPU; else the next refresh.
            const ns = if (gpu_wait) 2 * w.refresh_ns else w.nextPresentationNs(w.now()) -| w.now();
            var handles: [2]w32.HANDLE = undefined;
            var n: w32.DWORD = 0;
            if (gpu_wait) {
                handles[n] = w.swap.?.waitable;
                n += 1;
            }
            var ms: w32.DWORD = msCeil(ns);
            if (!gpu_wait and ns > 0) if (w.timer) |t| {
                const due: i64 = -@as(i64, @intCast(@max(ns / 100, 1)));
                if (w32.SetWaitableTimer(t, &due, 0, null, null, w32.FALSE) != 0) {
                    handles[n] = t;
                    n += 1;
                    ms = w32.INFINITE;
                }
            };
            if (ns > 0) {
                const woke = u.MsgWaitForMultipleObjectsEx(n, &handles, ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
                if (gpu_wait and woke == w32.WAIT_OBJECT_0) w.swap_ready = true;
                if (!gpu_wait) if (w.timer) |t| {
                    _ = w32.CancelWaitableTimer(t);
                };
            }
        }
        w.updatePending();
        if (!w.frame_pending) w.drawNow();
        if (w.in_modal and u.GetQueueStatus(QS_INPUT) >> 16 == 0) w.postFrame(u);
    }

    // --- The window ------------------------------------------------------------------

    pub fn setMinSize(w: *Win32Window, width: u32, height: u32) void {
        if (w.min_size[0] == width and w.min_size[1] == height) return;
        w.min_size = .{ @max(width, 1), @max(height, 1) };
        // A window already smaller grows to it.
        if (w.fullscreen or w.maximized) return;
        if (w.width < width or w.height < height) {
            const u = w32.user32() orelse return;
            w.resizeTo(u, .{ @max(w.width, width), @max(w.height, height) });
        }
    }

    pub fn setMaximized(w: *Win32Window, on: bool) void {
        const u = w32.user32() orelse return;
        _ = u.ShowWindow(w.hwnd, if (on) SW_MAXIMIZE else SW_RESTORE);
    }

    pub fn setMinimized(w: *Win32Window) void {
        const u = w32.user32() orelse return;
        _ = u.ShowWindow(w.hwnd, SW_MINIMIZE);
    }

    /// Full screen: no frame, over the whole of its monitor (the taskbar
    /// too), which lets DWM show its frames straight to the display.
    pub fn setFullscreen(w: *Win32Window, on: bool) void {
        if (w.fullscreen == on) return;
        const u = w32.user32() orelse return;
        if (on) {
            w.restore = .{};
            _ = u.GetWindowPlacement(w.hwnd, &w.restore);
            w.restore_style = u.GetWindowLongPtrW(w.hwnd, GWL_STYLE);
            const monitor = u.MonitorFromWindow(w.hwnd, MONITOR_DEFAULTTONEAREST) orelse return;
            var mi: w32.MONITORINFO = .{};
            if (u.GetMonitorInfoW(monitor, &mi) == 0) return;
            const style: isize = @bitCast(@as(usize, (WS_POPUP | WS_VISIBLE)));
            _ = u.SetWindowLongPtrW(w.hwnd, GWL_STYLE, style);
            const r = mi.rcMonitor;
            _ = u.SetWindowPos(w.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
            w.fullscreen = true;
        } else {
            _ = u.SetWindowLongPtrW(w.hwnd, GWL_STYLE, w.restore_style);
            _ = u.SetWindowPlacement(w.hwnd, &w.restore);
            _ = u.SetWindowPos(w.hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | 0x0001 | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
            w.fullscreen = false;
        }
    }

    pub fn isFullscreen(w: *const Win32Window) bool {
        return w.fullscreen;
    }

    pub fn setCursor(w: *Win32Window, cursor: window.Cursor) void {
        if (w.cursor == cursor) return;
        w.cursor = cursor;
        if (!w.pointer_in) return;
        const u = w32.user32() orelse return;
        _ = u.SetCursor(cursorHandle(u, cursor));
    }

    fn cursorHandle(u: *const w32.User32, cursor: window.Cursor) ?w32.HCURSOR {
        const id: usize = switch (cursor) {
            .default => 32512, // IDC_ARROW
            .pointer => 32649, // IDC_HAND
            .text => 32513, // IDC_IBEAM
            .grab, .grabbing, .move => 32646, // IDC_SIZEALL
            .crosshair => 32515, // IDC_CROSS
            .not_allowed => 32648, // IDC_NO
            .wait => 32514, // IDC_WAIT
            .progress => 32650, // IDC_APPSTARTING
            .help => 32651, // IDC_HELP
            .ew_resize => 32644, // IDC_SIZEWE
            .ns_resize => 32645, // IDC_SIZENS
            .nwse_resize => 32642, // IDC_SIZENWSE
            .nesw_resize => 32643, // IDC_SIZENESW
        };
        return u.LoadCursorW(null, id);
    }

    /// The title bar dark or light, as the app's appearance.
    fn applyDarkTitleBar(w: *Win32Window) void {
        const d = w32.dwmapi() orelse return;
        const on: w32.BOOL = if (w.dark orelse false) w32.TRUE else w32.FALSE;
        _ = d.DwmSetWindowAttribute(w.hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &on, @sizeOf(w32.BOOL));
    }

    // --- Frames (on the CPU) -----------------------------------------------------------

    /// Frames drawn on the GPU go to the swap chain; the CPU's, in memory,
    /// are shown with GDI.
    pub fn bufferTransport(w: *const Win32Window) window.BufferTransport {
        return if (w.on_gpu) .swapchain else .memory;
    }

    /// The swap chain's back buffer, as big as the client area in pixels
    /// (made on `device` the first time), for the GPU to draw the next
    /// frame in.
    pub fn beginD3D11Frame(w: *Win32Window, device: *anyopaque) ?gfx.D3D11Target {
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        if (w.swap) |*sc| if (sc.device != device) {
            sc.deinit();
            w.swap = null;
        };
        if (w.swap == null) {
            w.swap = gfx.d3d11.SwapChain.create(device, w.hwnd, pw, ph) catch return null;
            w.swap_ready = false;
            w.gpu_size = .{ 0, 0 };
        }
        const sc = &w.swap.?;
        // A frame drawn before a buffer is free (at a new size, as the
        // window is resized) waits for one, so that `Present` does not.
        if (!w.swap_ready and w32.WaitForSingleObject(sc.waitable, msCeil(2 * w.refresh_ns)) == w32.WAIT_OBJECT_0) w.swap_ready = true;
        sc.resize(pw, ph) catch return null;
        w32.release(w.back);
        w.back = sc.backBuffer() catch return null;
        w.on_gpu = true;
        return .{ .texture = w.back.?, .width = pw, .height = ph };
    }

    /// The buffer to draw the next frame in, as big as the client area in
    /// pixels (its logical size at its scale).
    pub fn beginSoftwareFrame(w: *Win32Window) !gfx.software.Image {
        // Back to the CPU (the GPU could not draw): the swap chain goes, or
        // it would be shown over what GDI draws.
        if (w.swap) |*sc| {
            w32.release(w.back);
            w.back = null;
            sc.deinit();
            w.swap = null;
        }
        w.on_gpu = false;
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        if (w.pixels_size[0] != pw or w.pixels_size[1] != ph) {
            w.gpa.free(w.pixels);
            w.pixels = &.{};
            w.pixels = try w.gpa.alloc(u32, @as(usize, pw) * ph);
            @memset(w.pixels, 0xff000000);
            w.pixels_size = .{ pw, ph };
            w.pixels_shown = false;
        }
        return .{ .pixels = w.pixels, .width = pw, .height = ph };
    }

    /// The one buffer is drawn in again each frame: it has the last (as the
    /// renderer's frame does, while it is the same size).
    pub fn bufferAge(w: *const Win32Window) u32 {
        if (w.on_gpu) return if (w.gpu_size[0] == w.width * w.scale and w.gpu_size[1] == w.height * w.scale) 1 else 0;
        return if (w.pixels_shown) 1 else 0;
    }

    /// Shows the frame drawn: the swap chain's (presented at the next
    /// refresh, what changed said), or the CPU's buffer.
    pub fn showDamaged(w: *Win32Window, damage: ?[]const gfx.Viewport) !void {
        if (w.on_gpu) if (w.swap) |*sc| {
            w32.release(w.back);
            w.back = null;
            switch (sc.present(damage)) {
                .shown => {},
                .occluded => w.occluded = true,
                .failed => return error.PresentFailed,
            }
            w.gpu_size = .{ sc.width, sc.height };
            w.swap_ready = false;
            w.shown();
            return;
        };
        const u = w32.user32() orelse return error.NoUser32;
        const hdc = u.GetDC(w.hwnd) orelse return error.NoDeviceContext;
        defer _ = u.ReleaseDC(w.hwnd, hdc);
        w.blit(hdc);
        w.pixels_shown = true;
        w.shown();
    }

    fn blit(w: *const Win32Window, hdc: w32.HDC) void {
        const g = w32.gdi32() orelse return;
        if (w.pixels.len == 0) return;
        // Top row first (a negative height); 0xAARRGGBB is BGRA in memory,
        // as a 32-bit DIB's pixels are.
        const bmi: w32.BITMAPINFOHEADER = .{ .biWidth = @intCast(w.pixels_size[0]), .biHeight = -@as(w32.LONG, @intCast(w.pixels_size[1])) };
        _ = g.SetDIBitsToDevice(hdc, 0, 0, w.pixels_size[0], w.pixels_size[1], 0, 0, 0, w.pixels_size[1], w.pixels.ptr, &bmi, 0);
    }

    // --- The clipboard ---------------------------------------------------------------

    pub fn copy(w: *Win32Window, text: []const u8) void {
        const u = w32.user32() orelse return;
        if (!openClipboard(u, w.hwnd)) return;
        defer _ = u.CloseClipboard();
        _ = u.EmptyClipboard();
        // UTF-16, with a 0 at its end.
        const units = std.unicode.calcUtf16LeLen(text) catch return;
        const mem = w32.GlobalAlloc(w32.GMEM_MOVEABLE, (units + 1) * 2) orelse return;
        const p: [*]u16 = @ptrCast(@alignCast(w32.GlobalLock(mem) orelse {
            _ = w32.GlobalFree(mem);
            return;
        }));
        const n = std.unicode.utf8ToUtf16Le(p[0..units], text) catch 0;
        p[n] = 0;
        _ = w32.GlobalUnlock(mem);
        // The clipboard has it from now on (if it took it).
        if (u.SetClipboardData(CF_UNICODETEXT, mem) == null) _ = w32.GlobalFree(mem);
    }

    pub fn paste(w: *Win32Window, sink: clipboard.Sink) void {
        const u = w32.user32() orelse return sink.f(sink.ctx, null);
        if (!openClipboard(u, w.hwnd)) return sink.f(sink.ctx, null);
        defer _ = u.CloseClipboard();
        const mem = u.GetClipboardData(CF_UNICODETEXT) orelse return sink.f(sink.ctx, null);
        const p: [*]const u16 = @ptrCast(@alignCast(w32.GlobalLock(mem) orelse return sink.f(sink.ctx, null)));
        defer _ = w32.GlobalUnlock(mem);
        const max = w32.GlobalSize(mem) / 2;
        var len: usize = 0;
        while (len < max and p[len] != 0) len += 1;
        const text = std.unicode.utf16LeToUtf8Alloc(w.gpa, p[0..len]) catch return sink.f(sink.ctx, null);
        defer w.gpa.free(text);
        sink.f(sink.ctx, text);
    }

    /// Opens the clipboard, trying a few times (another app may have it
    /// for a moment).
    fn openClipboard(u: *const w32.User32, hwnd: HWND) bool {
        for (0..5) |_| {
            if (u.OpenClipboard(hwnd) != 0) return true;
        }
        return false;
    }
};

test {
    _ = keys;
}

test "frames are presented to a window through its swap chain, on WARP" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var dx = gfx.D3D11Renderer.initWarp(testing.allocator) catch |e| {
        if (e == error.NoShaders) return error.SkipZigTest;
        return e;
    };
    defer dx.deinit();
    const w = try Win32Window.open(testing.allocator, testing.io, .empty, .{ .title = "facet test", .size = .{ 200, 120 } });
    defer w.close();
    var canvas = gfx.Canvas.init(testing.allocator);
    defer canvas.deinit();
    var p: window.Presenter = .{ .renderer = dx.renderer() };
    for (0..3) |i| {
        try w.wait(std.time.ns_per_s / 10);
        _ = try w.applyConfigure();
        const pw = w.width * w.scale;
        const ph = w.height * w.scale;
        canvas.begin(pw, ph);
        canvas.fillRect(.{ .x = 0, .y = 0, .w = @floatFromInt(pw), .h = @floatFromInt(ph) }, .rgb(@intCast(0x203040 + i)));
        var f: gfx.Frame = .{ .canvases = &.{&canvas}, .segments = &.{.{ .canvas = &canvas }}, .clear = 0xff000000 };
        f.repaints[0].add(.{ .width = pw, .height = ph });
        f.damage.add(.{ .width = pw, .height = ph });
        try p.present(.from(w), &f);
        // Into the swap chain, on the GPU (not on the CPU).
        try testing.expect(w.on_gpu);
        try testing.expectEqual([2]u32{ pw, ph }, w.gpu_size);
    }
}
