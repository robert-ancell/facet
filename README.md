# Facet

**Facet** is a standalone, zero-dependency, declarative Material 3 UI toolkit for Zig.

An application describes its UI as a tree of plain Zig structs rebuilt each frame from its state. Facet preserves widget state and layout across frames, lays the tree out with fault-tolerant constraints (highlighting any overflow rather than failing), tracks damage rectangles so only changed regions are redrawn, and renders via pluggable backends.

## Features

- **Declarative Material 3 Widget Set:**
  - Layout: `Row`, `Column`, `Flex`, `Expanded`, `Grid`, `LazyGrid`, `ScrollView`, `Overlay`, `Padding`, `Align`, `Center`, `SizedBox`, `ConstrainedBox`
  - Controls & Buttons: `FilledButton`, `TonalButton`, `OutlinedButton`, `TextButton`, `IconButton`, `PillBar`, `Checkbox`, `Radio`, `Switch`, `Slider`, `DropdownMenu`, `Select`
  - Containers & Navigation: `Card`, `ListItem`, `Chip`, `Badge`, `Divider`, `NavigationRail`, `TabBar`, `Dialog`, `Snackbar`, `Tooltip`, `Menu`
  - Text, Media & 3D: `Text`, `TextField`, `TextArea` (`TextDocument` with syntax highlighting), `Icon`, `Image` (PNG, JPEG, GIF or WebP, decoded in pure Zig, from memory, files or URLs, loaded in the background with an optional placeholder; or a part of one, of which only that part is decoded, a JPEG's other blocks not even turned into pixels), `QrCode`, `Spinner`, `ProgressBar`, `OpenGlArea`, `VulkanArea`, `MetalArea` (macOS)
  - Maps: `MapView`, a slippy map that is a globe zoomed out and the flat (Web Mercator) map zoomed in, dragged, flung and zoomed with the wheel. Its tiles come from the app's `MapSource` (facet ships none): pictures (anything an `Image` shows, URLs too, loaded in the background) or shapes (`VectorTile`: points, lines and polygons with holes, with properties), drawn in a `MapStyle` (layers of fills, lines, dots and labels, picked by filters and zoom, or drawn by the app's own function with a `TilePainter`). Tiles not there yet are drawn from those further out, and a source can wake the UI when one comes (`Waker`). The globe can have a glow (its atmosphere), and night shaded where the sun has set (`subsolarPoint` gives where it is overhead at a time).
  - Keyboard: Tab and Shift+Tab move the focus through every control (within the open menu or dialog), shown with Material's focus ring; Space and Enter press, the arrow keys move sliders, radio buttons, menus and maps, Escape closes menus and dialogs (`pub fn focusable(self, n) bool` makes a widget of the app's own take the focus)
  - Accessibility: the widgets say what they are in WAI-ARIA 1.2's terms (its roles, states and properties: `button`, `checkbox`, `label`, `checked`, `expanded`, `valuenow`…), as the web does; `Accessible` describes the app's own widgets in them, names those that have only an icon, or hides decoration. They are offered to screen readers and other assistive technologies over AT-SPI as the W3C's Core Accessibility API Mappings say (with a small pure-Zig D-Bus client, `window.dbus`), and kept up to date as they change. On Linux, `App.open` offers them if the desktop has an AT-SPI bus (not with `NO_AT_BRIDGE=1`); `Ui.enableAccessibility` does for other windows.
  - Theming: Material 3's baseline light and dark schemes, following the system's setting, and `Themed` to give the widgets below it a theme of their own (`cx.theme()` is the one a widget is in)
  - Animation: `AnimatedWidget` (a child made each frame from the animation's progress) and `tween` (easing functions, including Material's, and `lerp`)
- **Pluggable Rendering Backends (`facet.gfx`):**
  - **Software (`SoftwareRenderer`):** Zero-dependency CPU rasterizer for all 2D SDF shapes, polygons, alpha/color glyphs, and bilinear images.
  - **Metal (`MetalRenderer`):** the GPU renderer on macOS, its shaders in the Metal Shading Language compiled when it starts (`shaders/canvas.metal`), Metal loaded at run time. In a window it draws only what changed into a frame it keeps on the GPU, copies that into the window's `CAMetalLayer` and presents it, with no copy through the CPU; it can also draw into images on the CPU. `MetalArea` scenes (`MetalContext`: pipelines of the scene's own Metal shaders, buffers and uniforms, multisampled with depth) are drawn into its frame on its GPU.
  - **OpenGL (`OpenGlRenderer`, `OpenGlContext`):** OpenGL 3.3+ backend and offscreen 3D widget framework using runtime `GetProcAddress` function loading (no C headers required).
  - **Vulkan (`VulkanRenderer`, `VulkanContext`):** Vulkan 1.1+ backend and offscreen 3D widget framework using runtime `GetDeviceProcAddr` loading and Zig-compiled SPIR-V shaders. On Wayland it draws frames straight into the window's `linux_dmabuf` buffers when the GPU can import them (`VK_EXT_external_memory_dma_buf`, `VK_EXT_image_drm_format_modifier`), and into the buffers through the CPU otherwise. `VulkanArea` scenes then draw on the renderer's device, and `OpenGlArea` scenes are exported as dmabufs (`EGL_MESA_image_dma_buf_export`), so both go into the frame on the GPU.
  - **Custom Backends:** Implement `prepare` and `record` and wrap with `facet.Renderer.of(&my_backend)`. Rendering into a pointer to anything but the backend's target type returns `error.WrongTarget`.
- **Windowing (`facet.window`):**
  - Built-in **Wayland Client Window (`WaylandWindow`)** using `xdg-shell` (with menus and tooltips in `xdg_popup` surfaces), `zxdg_decoration_manager_v1` (automatic client-side title bar & shadows or server-side decorations), `wl_shm` shared-memory buffers, `wp_cursor_shape_v1`, `wl_data_device` clipboard & drag-and-drop, `zwp_text_input_v3` IME support, `wp_presentation`, the compositor's XKB keymap (any layout, with its groups, levels and modifiers, read in pure Zig by `window.xkb`), and dead keys and the Compose key (the user's or locale's Compose file, found as libxkbcommon finds it, by `window.compose`).
  - Built-in **macOS Window (`MacWindow`)**: an AppKit `NSWindow` with the system's own title bar, buttons, resizing and full screen, frames drawn on the GPU into its view's `CAMetalLayer` (or on the CPU, shown as its layer's contents), the system's clipboard, cursors, Retina scaling and light or dark appearance (which the theme follows), and Quit in the app's menu (Command and Q). AppKit and the Objective-C runtime are loaded at run time (`gfx.objc`), so facet builds for macOS without its SDK, from Linux too (`zig build -Dtarget=aarch64-macos`). Command works as Control does elsewhere (Command and C copies).
  - `facet.NativeWindow` is the backend for the system being built for, chosen at compile time (`MacWindow` on macOS, `WaylandWindow` elsewhere), and the one `App.open` opens.
  - **`std.Io` throughout:** an app gives facet its `std.Io` (`init.io`, from `std.process.Init`) as it gives its allocator, and facet does its I/O, waits and tells the time through it, with no threads or `Io` of its own: the window's connection, the clipboard's pipes and the accessibility bus, image files and URLs (`std.http.Client` on the app's `Io`), and the theme's settings. What `App.step` waits on is read in one `std.Io.Batch`, so other tasks on the `Io` (a fetch started with `io.async`, say) go on while the UI waits, and `step` returns `error.Canceled` if its task is canceled. Images load in `Io.Group.concurrent` tasks. Work done elsewhere wakes the UI with `Ui.waker()` (from any thread or task: it neither blocks nor allocates). On macOS, AppKit's loop is run on the main thread, and the `Io`'s work wakes it. With Zig 0.17, the threaded `Io` (`std.Io.Threaded`, what `std.process.Init` gives) does all of this; the io_uring one does not yet batch socket reads, which Wayland's connection needs (for the file descriptors that come with them; see [ziglang/zig#31723](https://codeberg.org/ziglang/zig/issues/31723)). facet also works around two bugs there: abstract Unix socket addresses get a NUL too many ([ziglang/zig#35919](https://codeberg.org/ziglang/zig/issues/35919)), so the accessibility bus is connected to directly when its address is one, and `std.http.Client.fetch` can panic when a body's read fails or is canceled ([ziglang/zig#36296](https://codeberg.org/ziglang/zig/issues/36296)), so images are fetched without it. What `std.Io` has no equivalent of, a wake any thread can signal, is in `window.sys`.
  - Generic, platform-neutral **`Window` interface (`facet.Window.of(&my_window)`)** for custom windowing backends (and future Windows support); run an app in one with `facet.App.openIn(gpa, io, &my_window, options)`; what the window waits on as well as its own events (`window.Source`s, read through `std.Io`) it is given with `watch`.
- **Bundled Fonts & Icons (`facet.font`, `facet.icons`):**
  - Pure-Zig OpenType/TrueType parser, shaper, and rasterizer (`kern`/`GPOS`, `liga`/`GSUB`, `COLR`/`CPAL` color emoji).
  - Includes **Fira Sans** (`font.default_font_data`), **Twemoji Mozilla** (`font.emoji_font_data`), and build-time subsetted **Material Icons** out of the box via `Ui.createDefault(gpa, io)`, while allowing custom fonts via `Ui.createWithFontData(gpa, io, ttf_bytes)` (or `App.Options.font_data`), or `Ui.create(gpa, io, my_font)` (`null` for no text font).

## Getting Started

### 1. Add Facet to Your Project

Fetch Facet into your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/robert-ancell/facet
```

Then import the `facet` module in your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const facet_dep = b.dependency("facet", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "facet", .module = facet_dep.module("facet") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
```

### 2. Hello World Example

In Facet, any struct with a `build` method is a composite widget, and declaring `pub const State = struct { ... }` makes it stateful across frames.

```zig
const std = @import("std");
const facet = @import("facet");

pub const Counter = struct {
    pub const State = struct {
        count: i32 = 0,

        pub fn increment(s: *State) void {
            s.count += 1;
        }

        pub fn decrement(s: *State) void {
            s.count -= 1;
        }
    };

    pub fn build(_: *const Counter, cx: *facet.Context, state: *State) facet.Widget {
        return cx.make(facet.Center{
            .child = cx.make(facet.Column{
                .main_axis_size = .min,
                .cross_axis_alignment = .center,
                .spacing = 16,
                .children = &.{
                    cx.make(facet.Text{
                        .text = "Hello, Facet!",
                    }),
                    cx.make(facet.Text{
                        .text = cx.fmt("Count: {d}", .{state.count}),
                    }),
                    cx.make(facet.Row{
                        .main_axis_size = .min,
                        .spacing = 12,
                        .children = &.{
                            cx.make(facet.OutlinedButton{
                                .icon = .remove,
                                .on_press = .of(state, State.decrement),
                            }),
                            cx.make(facet.FilledButton{
                                .icon = .add,
                                .on_press = .of(state, State.increment),
                            }),
                        },
                    }),
                },
            }),
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.open(init.gpa, init.io, init.minimal.environ, .{
        .title = "Hello Facet",
        .size = .{ 480, 320 },
    });
    defer app.close();

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try app.draw(Counter{});
    }
}
```

## Examples

Run any of the included examples from the repository root:

| Command | Source | Description |
| --- | --- | --- |
| `zig build run-hello` | `examples/hello.zig` | Interactive counter application |
| `zig build run-navigation` | `examples/navigation.zig` | Inbox application with navigation rail, tabs, confirmation dialog, and undo snackbar |
| `zig build run-lists` | `examples/lists_and_drag.zig` | Grid of 500 items that can be dragged and dropped into a pinned list |
| `zig build run-editor` | `examples/editor.zig` | Multi-line code editor with Zig syntax highlighting |
| `zig build run-canvas` | `examples/canvas_and_qr.zig` | Animated harmonic wave viewer and live QR code generator |
| `zig build run-fetch` | `examples/fetch.zig` | An HTTP fetch in the background with `io.async`, on the app's `std.Io`, waking the UI when it is done |
| `zig build run-opengl` | `examples/opengl.zig` | Interactive 3D Platonic solid viewer rendered with OpenGL |
| `zig build run-vulkan` | `examples/vulkan.zig` | Interactive 3D Platonic solid viewer rendered with Vulkan |
| `zig build run-metal` | `examples/metal.zig` | Interactive 3D Platonic solid viewer rendered with Metal (macOS) |

## Tools

| Command | Source | Description |
| --- | --- | --- |
| `zig build run-showcase` | `tools/showcase.zig` | A tour of every widget, a page each for buttons, selection, text, feedback, containers, layout, images (each format, from memory, bytes and URLs, and a part of one), icons (all of them, searchable), maps (a globe of tiles made by the showcase, as vector tiles or images, in a choice of styles), 3D (Vulkan and OpenGL on Linux, Metal on macOS), and special widgets (QR codes, custom painting, accessibility and animation) |
| `zig build run-info` | `tools/info.zig` | The windowing, buffer, synchronization and rendering backends facet picks on your system |

