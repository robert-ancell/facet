//! Win32Window: a native Windows window (a Win32 `HWND`, with the system's
//! own title bar, buttons, resizing and full screen).

const std = @import("std");
const window = @import("window.zig");

pub const Win32Window = struct {
    pub const platform: window.Platform = .windows;
    pub const decorations: window.Decorations = .server;

    pub const Options = struct {
        title: []const u8,
        app_id: ?[]const u8 = null,
        size: [2]u32 = .{ 960, 640 },
        min_size: ?[2]u32 = null,
        maximized: bool = false,
    };

    pub fn open(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !*Win32Window {
        _ = .{ gpa, io, environ, options };
        return error.Unsupported;
    }

    pub fn close(_: *Win32Window) void {}

    pub fn size(_: *const Win32Window) [2]u32 {
        return .{ 0, 0 };
    }
};
