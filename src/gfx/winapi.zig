//! The Windows API: kernel32's functions (linked, as every program has
//! them), and the other system DLLs' (user32, gdi32, dwmapi, d3d11, dxgi,
//! ...) loaded when first used (as facet loads Vulkan, EGL and AppKit), so
//! nothing else is linked. COM objects (Direct3D's, DXGI's) are called
//! through their vtables (`Com`).

const std = @import("std");

/// The calling convention of the Windows API (and COM), on Windows (the C
/// one elsewhere, where none of it is called, so that it still compiles).
pub const cc: std.builtin.CallingConvention = if (@import("builtin").os.tag == .windows) .winapi else .c;

pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = c_long;
pub const HRESULT = c_long;
pub const WCHAR = u16;
pub const HANDLE = *anyopaque;
pub const HMODULE = *opaque {};
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HDC = *opaque {};
pub const HCURSOR = *opaque {};
pub const HMONITOR = *opaque {};
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const FARPROC = *const anyopaque;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const INFINITE: DWORD = 0xffffffff;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 0x102;
pub const WAIT_FAILED: DWORD = 0xffffffff;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    /// From its usual text: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
    pub fn parse(comptime s: []const u8) GUID {
        return comptime blk: {
            std.debug.assert(s.len == 36);
            const hex = struct {
                fn f(t: []const u8) u64 {
                    return std.fmt.parseInt(u64, t, 16) catch unreachable;
                }
            }.f;
            var g: GUID = .{
                .data1 = @intCast(hex(s[0..8])),
                .data2 = @intCast(hex(s[9..13])),
                .data3 = @intCast(hex(s[14..18])),
                .data4 = undefined,
            };
            g.data4[0] = @intCast(hex(s[19..21]));
            g.data4[1] = @intCast(hex(s[21..23]));
            for (0..6) |i| g.data4[2 + i] = @intCast(hex(s[24 + i * 2 ..][0..2]));
            break :blk g;
        };
    }
};

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

// --- kernel32 ---------------------------------------------------------------------

pub extern "kernel32" fn LoadLibraryW(name: [*:0]const WCHAR) callconv(cc) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(cc) ?FARPROC;
pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const WCHAR) callconv(cc) ?HMODULE;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(cc) BOOL;
pub extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const WCHAR) callconv(cc) ?HANDLE;
pub extern "kernel32" fn SetEvent(h: HANDLE) callconv(cc) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(cc) DWORD;
pub extern "kernel32" fn CreateWaitableTimerExW(attrs: ?*anyopaque, name: ?[*:0]const WCHAR, flags: DWORD, access: DWORD) callconv(cc) ?HANDLE;
pub extern "kernel32" fn SetWaitableTimer(h: HANDLE, due: *const i64, period: LONG, routine: ?*const anyopaque, arg: ?*anyopaque, resume_: BOOL) callconv(cc) BOOL;
pub extern "kernel32" fn CancelWaitableTimer(h: HANDLE) callconv(cc) BOOL;
pub extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(cc) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(cc) BOOL;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(cc) ?HANDLE;
pub extern "kernel32" fn GlobalFree(h: HANDLE) callconv(cc) ?HANDLE;
pub extern "kernel32" fn GlobalLock(h: HANDLE) callconv(cc) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(h: HANDLE) callconv(cc) BOOL;
pub extern "kernel32" fn GlobalSize(h: HANDLE) callconv(cc) usize;

pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: DWORD = 0x2;
pub const TIMER_ALL_ACCESS: DWORD = 0x1f0003;
pub const GMEM_MOVEABLE: UINT = 0x2;

/// The performance counter in nanoseconds (the clock DXGI's and DWM's
/// timings are on, as `QueryPerformanceCounter` gives them).
pub fn qpcToNs(qpc: i64) u64 {
    const S = struct {
        var freq: i64 = 0;
    };
    if (S.freq == 0) _ = QueryPerformanceFrequency(&S.freq);
    const f: u128 = @intCast(@max(S.freq, 1));
    const q: u128 = @intCast(@max(qpc, 0));
    return @intCast(q * std.time.ns_per_s / f);
}

pub fn nowQpc() i64 {
    var q: i64 = 0;
    _ = QueryPerformanceCounter(&q);
    return q;
}

// --- Loading DLLs -------------------------------------------------------------------

/// A system DLL, loaded once (null if it is not there).
pub fn dll(comptime name: []const u8) ?HMODULE {
    const S = struct {
        var loaded = false;
        var module: ?HMODULE = null;
    };
    if (!S.loaded) {
        S.loaded = true;
        S.module = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral(name));
    }
    return S.module;
}

/// Function `name` of DLL `lib` (null if either is not there).
pub fn proc(comptime T: type, comptime lib: []const u8, name: [*:0]const u8) ?T {
    const m = dll(lib) orelse return null;
    const p = GetProcAddress(m, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Functions of DLL `lib`, as the fields of `T` (function pointers named
/// as the DLL's functions), looked up once: null if any is missing.
pub fn procs(comptime T: type, comptime lib: []const u8) ?*const T {
    const S = struct {
        var looked = false;
        var table: ?T = null;
    };
    if (!S.looked) {
        S.looked = true;
        var t: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |f| {
            @field(t, f.name) = proc(f.type, lib, f.name ++ "") orelse return null;
        }
        S.table = t;
    }
    return if (S.table) |*t| t else null;
}

// --- COM ------------------------------------------------------------------------

/// A COM object's method in slot `slot` of its vtable (counting
/// IUnknown's three), of type `F` (`fn (*anyopaque, ...) callconv(cc) R`),
/// called on it with `args`.
pub fn call(obj: anytype, comptime slot: usize, comptime F: type, args: anytype) @typeInfo(F).@"fn".return_type.? {
    const self: *anyopaque = @ptrCast(obj);
    const vtable: [*]const *const anyopaque = @as(*const [*]const *const anyopaque, @ptrCast(@alignCast(self))).*;
    const f: *const F = @ptrCast(@alignCast(vtable[slot]));
    return @call(.auto, f, .{self} ++ args);
}

const QueryInterface = fn (*anyopaque, *const GUID, *?*anyopaque) callconv(cc) HRESULT;
const AddRefRelease = fn (*anyopaque) callconv(cc) u32;

/// IUnknown's `QueryInterface` (slot 0): the object as interface `iid`.
pub fn query(obj: anytype, iid: *const GUID) ?*anyopaque {
    var out: ?*anyopaque = null;
    if (!succeeded(call(obj, 0, QueryInterface, .{ iid, &out }))) return null;
    return out;
}

/// IUnknown's `Release` (slot 2), if there is an object.
pub fn release(obj: anytype) void {
    const o: ?*anyopaque = @ptrCast(obj);
    if (o) |p| _ = call(p, 2, AddRefRelease, .{});
}

// --- UTF-16 ------------------------------------------------------------------------

/// `text` (UTF-8) as UTF-16 with a 0 at its end, in `buf` (cut short if it
/// does not fit).
pub fn wide(buf: []u16, text: []const u8) [:0]const u16 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        var units: [2]u16 = undefined;
        const len: usize = if (cp >= 0x10000) blk: {
            const v = cp - 0x10000;
            units = .{ @intCast(0xd800 + (v >> 10)), @intCast(0xdc00 + (v & 0x3ff)) };
            break :blk 2;
        } else blk: {
            units[0] = @intCast(cp);
            break :blk 1;
        };
        if (n + len + 1 > buf.len) break;
        @memcpy(buf[n..][0..len], units[0..len]);
        n += len;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

test "UTF-8 becomes UTF-16, with a 0 at its end, cut short to fit" {
    var buf: [8]u16 = undefined;
    const w = wide(&buf, "a\u{e9}\u{1f600}");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xe9, 0xd83d, 0xde00 }, w);
    try std.testing.expectEqual(@as(u16, 0), w.ptr[w.len]);
    var small: [3]u16 = undefined;
    // The emoji's two units do not fit after "a\u{e9}" and the 0.
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xe9 }, wide(&small, "a\u{e9}\u{1f600}"));
}

test "a COM method is called through its object's vtable" {
    const Impl = struct {
        var released: u32 = 0;
        fn qi(_: *anyopaque, _: *const GUID, out: *?*anyopaque) callconv(cc) HRESULT {
            out.* = null;
            return -1;
        }
        fn addRef(_: *anyopaque) callconv(cc) u32 {
            return 1;
        }
        fn rel(_: *anyopaque) callconv(cc) u32 {
            released += 1;
            return 0;
        }
    };
    const vt = [3]*const anyopaque{ @ptrCast(&Impl.qi), @ptrCast(&Impl.addRef), @ptrCast(&Impl.rel) };
    var obj: extern struct { vt: *const [3]*const anyopaque } = .{ .vt = &vt };
    release(&obj);
    try std.testing.expectEqual(@as(u32, 1), Impl.released);
    try std.testing.expect(query(&obj, &comptime GUID.parse("00000000-0000-0000-c000-000000000046")) == null);
}

test "GUIDs are read from their text" {
    const g = GUID.parse("db6f6ddb-ac77-4e88-8253-819df9bbf140");
    try std.testing.expectEqual(@as(u32, 0xdb6f6ddb), g.data1);
    try std.testing.expectEqual(@as(u16, 0xac77), g.data2);
    try std.testing.expectEqual(@as(u16, 0x4e88), g.data3);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 }, &g.data4);
}
