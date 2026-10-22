//! Theme: a Material 3 colour scheme (the baseline light and dark ones),
//! text sizes, and persistent appearance settings.

const std = @import("std");
const gfx = @import("gfx");

const Color = gfx.Color;

/// Default path where persistent appearance settings can be stored.
pub const settings_file = "/data/apps/.appearance";

/// Whether the system uses the dark or light Material 3 colour scheme.
pub const ThemeMode = enum {
    /// The dark scheme.
    dark,
    /// The light scheme.
    light,

    pub fn name(m: ThemeMode) []const u8 {
        return switch (m) {
            .dark => "Dark",
            .light => "Light",
        };
    }

    pub fn code(m: ThemeMode) []const u8 {
        return @tagName(m);
    }

    pub fn fromCode(text: []const u8) ?ThemeMode {
        return std.meta.stringToEnum(ThemeMode, text);
    }

    pub fn scheme(m: ThemeMode) Theme {
        return switch (m) {
            .dark => .dark,
            .light => .light,
        };
    }
};

/// Persistent appearance settings stored in `settings_file`.
pub const Settings = struct {
    theme: ThemeMode = .dark,

    pub fn parse(text: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var tok = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = tok.next() orelse continue;
            const val = tok.next() orelse continue;
            if (std.mem.eql(u8, key, "theme")) {
                if (ThemeMode.fromCode(val)) |m| s.theme = m;
            }
        }
        return s;
    }

    pub fn formatBuf(s: Settings, buf: []u8) []const u8 {
        return std.mem.print(buf, "theme {s}\n", .{s.theme.code()}) catch "";
    }
};

/// The settings in `settings_file` (read through `io`), or the defaults.
pub fn loadSettings(io: std.Io) Settings {
    return loadSettingsFrom(io, settings_file);
}

pub fn loadSettingsFrom(io: std.Io, path: []const u8) Settings {
    var buf: [128]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, path, &buf) catch return .{};
    return Settings.parse(text);
}

pub fn saveSettings(io: std.Io, s: Settings) void {
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(settings_file).?) catch {};
    saveSettingsTo(io, settings_file, s);
}

pub fn saveSettingsTo(io: std.Io, path: []const u8, s: Settings) void {
    var buf: [128]u8 = undefined;
    const content = s.formatBuf(&buf);
    if (content.len == 0) return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content }) catch {};
}

/// Notices `path` (defaulting to `settings_file`) being created, replaced, or
/// modified (looked at through `io`).
pub const Watch = struct {
    path: []const u8 = settings_file,
    stamp: ?Stamp = null,
    initialized: bool = false,

    /// What tells one version of the file from another.
    const Stamp = struct { inode: std.Io.File.INode, size: u64, mtime: i96 };

    /// Whether `path` changed since the last call (false on the first call).
    pub fn changed(w: *Watch, io: std.Io) bool {
        const now: ?Stamp = if (std.Io.Dir.cwd().statFile(io, w.path, .{})) |st|
            .{ .inode = st.inode, .size = st.size, .mtime = st.mtime.nanoseconds }
        else |_|
            null;
        defer {
            w.stamp = now;
            w.initialized = true;
        }
        if (!w.initialized) return false;
        if (w.stamp == null and now == null) return false;
        const before = w.stamp orelse return true;
        const after = now orelse return true;
        return !std.meta.eql(before, after);
    }
};

/// Whether a scheme is light (dark on light) or dark (light on dark).
pub const ThemeBrightness = enum {
    /// Dark on light.
    light,
    /// Light on dark.
    dark,
};

/// A Material 3 colour scheme, and text sizes in pixels. The app's (`WindowUi`'s)
/// is the light or dark baseline, as the system asks; `Themed` gives the
/// widgets below it another (changing a colour or two of `cx.theme()`, say).
pub const Theme = struct {
    brightness: ThemeBrightness,
    primary: Color,
    on_primary: Color,
    primary_container: Color,
    on_primary_container: Color,
    secondary_container: Color,
    surface: Color,
    surface_container: Color,
    surface_container_highest: Color,
    on_surface: Color,
    on_surface_variant: Color,
    outline: Color,
    outline_variant: Color,
    /// For problems and destructive actions: text, and fills (badges).
    @"error": Color,
    /// Text and icons on `error`.
    on_error: Color,
    /// The colours of code's parts (see `SyntaxHighlight`).
    syntax: Syntax,
    body_size: f32 = 14,
    label_size: f32 = 14,
    title_size: f32 = 22,

    /// The baseline light scheme.
    pub const light: Theme = .{
        .brightness = .light,
        .primary = .rgb(0x6750a4),
        .on_primary = .rgb(0xffffff),
        .primary_container = .rgb(0xeaddff),
        .on_primary_container = .rgb(0x21005d),
        .secondary_container = .rgb(0xe8def8),
        .surface = .rgb(0xfef7ff),
        .surface_container = .rgb(0xf3edf7),
        .surface_container_highest = .rgb(0xe6e0e9),
        .on_surface = .rgb(0x1d1b20),
        .on_surface_variant = .rgb(0x49454f),
        .outline = .rgb(0x79747e),
        .outline_variant = .rgb(0xcac4d0),
        .@"error" = .rgb(0xb3261e),
        .on_error = .rgb(0xffffff),
        .syntax = .{
            .keyword = .rgb(0x8e24aa),
            .type = .rgb(0x00796b),
            .function = .rgb(0x1565c0),
            .builtin = .rgb(0xad1457),
            .string = .rgb(0x2e7d32),
            .number = .rgb(0xc65400),
            .constant = .rgb(0xc65400),
            .property = .rgb(0x1565c0),
            .comment = .rgb(0x79747e),
        },
    };

    /// The baseline dark scheme.
    pub const dark: Theme = .{
        .brightness = .dark,
        .primary = .rgb(0xd0bcff),
        .on_primary = .rgb(0x381e72),
        .primary_container = .rgb(0x4f378b),
        .on_primary_container = .rgb(0xeaddff),
        .secondary_container = .rgb(0x4a4458),
        .surface = .rgb(0x141218),
        .surface_container = .rgb(0x211f26),
        .surface_container_highest = .rgb(0x36343b),
        .on_surface = .rgb(0xe6e0e9),
        .on_surface_variant = .rgb(0xcac4d0),
        .outline = .rgb(0x938f99),
        .outline_variant = .rgb(0x49454f),
        .@"error" = .rgb(0xf2b8b5),
        .on_error = .rgb(0x601410),
        .syntax = .{
            .keyword = .rgb(0xd0a8ff),
            .type = .rgb(0x80cbc4),
            .function = .rgb(0x90caf9),
            .builtin = .rgb(0xf48fb1),
            .string = .rgb(0xa5d6a7),
            .number = .rgb(0xffb74d),
            .constant = .rgb(0xffb74d),
            .property = .rgb(0x90caf9),
            .comment = .rgb(0x938f99),
        },
    };
};

/// What a piece of code is, for its colour (plain text is `on_surface`).
pub const SyntaxHighlight = enum(u8) {
    /// Anything else: it has no colour of its own.
    plain,
    /// A word the language reserves: `if`, `fn`, `const`.
    keyword,
    /// The name of a type.
    type,
    /// The name of a function, where it is declared or called.
    function,
    /// Built into the language: Zig's @functions, Python's print and len.
    builtin,
    /// A string or character literal.
    string,
    /// A number literal.
    number,
    /// true, false, null and the like.
    constant,
    /// A JSON object's names.
    property,
    /// A comment.
    comment,
};

/// The colours of code, by what it is.
pub const Syntax = struct {
    keyword: Color,
    type: Color,
    function: Color,
    builtin: Color,
    string: Color,
    number: Color,
    constant: Color,
    property: Color,
    comment: Color,

    pub fn color(s: *const Syntax, h: SyntaxHighlight, plain: Color) Color {
        return switch (h) {
            .plain => plain,
            inline else => |tag| @field(s, @tagName(tag)),
        };
    }
};

const testing = std.testing;

test "appearance settings parse, format, save and load" {
    try testing.expectEqual(ThemeMode.dark, Settings.parse("").theme);
    try testing.expectEqual(ThemeMode.light, Settings.parse("theme light\n").theme);
    try testing.expectEqual(ThemeMode.dark, Settings.parse("theme dark\n").theme);
    try testing.expectEqual(ThemeMode.dark, Settings.parse("theme invalid\n").theme);

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = dir_buf[0..try tmp.dir.realPathFile(io, ".", &dir_buf)];
    var path_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/appearance", .{root});

    var watch: Watch = .{ .path = path };
    try testing.expect(!watch.changed(io));
    try testing.expectEqual(ThemeMode.dark, loadSettingsFrom(io, path).theme);

    saveSettingsTo(io, path, .{ .theme = .light });
    try testing.expect(watch.changed(io));
    try testing.expect(!watch.changed(io));
    try testing.expectEqual(ThemeMode.light, loadSettingsFrom(io, path).theme);

    try io.sleep(.fromMilliseconds(20), .awake);
    saveSettingsTo(io, path, .{ .theme = .dark });
    try testing.expect(watch.changed(io));
    try testing.expectEqual(ThemeMode.dark, loadSettingsFrom(io, path).theme);
}
