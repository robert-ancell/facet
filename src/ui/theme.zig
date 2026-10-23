//! Theme: a colour scheme (the light and dark ones, with the colour roles
//! of Material 3) and text sizes.

const std = @import("std");
const gfx = @import("gfx");

const Color = gfx.Color;

/// Whether the system uses the dark or light colour scheme.
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

/// Whether a scheme is light (dark on light) or dark (light on dark).
pub const ThemeBrightness = enum {
    /// Dark on light.
    light,
    /// Light on dark.
    dark,
};

/// A colour scheme, and text sizes in pixels. The colours are named for the
/// roles in Material 3's colour system (`primary`, `surface_container`,
/// `on_surface`...): the colour of something, and `on_` the colour of what is
/// drawn on it. The app's (`WindowUi`'s) is the light or dark one, as the
/// system asks; `Themed` gives the widgets below it another (changing a colour
/// or two of `cx.theme()`, say).
pub const Theme = struct {
    /// Whether a theme is light or dark.
    pub const Brightness = ThemeBrightness;

    /// Whether the scheme is light or dark.
    brightness: ThemeBrightness,
    /// The main colour: filled buttons, selected controls, focus.
    primary: Color,
    /// Text and icons on `primary`.
    on_primary: Color,
    /// A lighter (or, when dark, darker) fill of the main colour.
    primary_container: Color,
    /// Text and icons on `primary_container`.
    on_primary_container: Color,
    /// The fill of tonal buttons, selected chips and navigation items.
    secondary_container: Color,
    /// The background of the window and of dialogs.
    surface: Color,
    /// A step above `surface`: elevated cards, menus.
    surface_container: Color,
    /// The highest step above `surface`: filled cards, text fields.
    surface_container_highest: Color,
    /// Text and icons on the surfaces.
    on_surface: Color,
    /// Less important text and icons on the surfaces.
    on_surface_variant: Color,
    /// Outlines: of outlined buttons, text fields and dividers.
    outline: Color,
    /// Fainter outlines: of cards, between list items.
    outline_variant: Color,
    /// For problems and destructive actions: text, and fills (badges).
    @"error": Color,
    /// Text and icons on `error`.
    on_error: Color,
    /// The colours of code's parts (see `TextArea.Highlight`).
    syntax: Syntax,
    /// The size of body text, in pixels.
    body_size: f32 = 14,
    /// The size of labels, in pixels.
    label_size: f32 = 14,
    /// The size of titles, in pixels.
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
