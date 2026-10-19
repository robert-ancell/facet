# Facet

**Facet** is a standalone, zero-dependency, declarative Material 3 UI toolkit for Zig.

An application describes its UI as a tree of plain Zig structs rebuilt each frame from its state. Facet preserves widget state and layout across frames, lays the tree out with fault-tolerant constraints (highlighting any overflow rather than failing), tracks damage rectangles so only changed regions are redrawn, and renders via pluggable backends.

## Features

- **Declarative Material 3 Widget Set:**
  - Layout: `Row`, `Column`, `Flex`, `Expanded`, `Grid`, `LazyGrid`, `ScrollView`, `Overlay`, `Padding`, `Align`, `Center`, `SizedBox`, `ConstrainedBox`
  - Controls & Buttons: `FilledButton`, `TonalButton`, `OutlinedButton`, `TextButton`, `IconButton`, `PillBar`, `Checkbox`, `Radio`, `Switch`, `Slider`, `DropdownMenu`, `Select`
  - Containers & Navigation: `Card`, `ListItem`, `Chip`, `Badge`, `Divider`, `NavigationRail`, `TabBar`, `Dialog`, `Snackbar`, `Tooltip`, `Menu`, `TitleBar`
  - Text, Media & 3D: `Text`, `TextField`, `TextArea` (`TextDocument` with syntax highlighting), `Icon`, `Image` (PNG, JPEG, GIF or WebP, decoded in pure Zig, from memory, files or URLs, loaded in the background with an optional placeholder), `QrCode`, `Spinner`, `ProgressBar`, `OpenGlArea`, `VulkanArea`
  - Theming: Material 3's baseline light and dark schemes, following the system's setting, and `Themed` to give the widgets below it a theme of their own (`cx.theme()` is the one a widget is in)
  - Animation: `AnimatedWidget` (a child made each frame from the animation's progress) and `tween` (easing functions, including Material's, and `lerp`)
- **Pluggable Rendering Backends (`facet.gfx`):**
  - **Software (`SoftwareRenderer`):** Zero-dependency CPU rasterizer for all 2D SDF shapes, polygons, alpha/color glyphs, and bilinear images.
  - **OpenGL (`OpenGlRenderer`, `OpenGlContext`):** OpenGL 3.3+ backend and offscreen 3D widget framework using runtime `GetProcAddress` function loading (no C headers required).
  - **Vulkan (`VulkanRenderer`, `VulkanContext`):** Vulkan 1.1+ backend and offscreen 3D widget framework using runtime `GetDeviceProcAddr` loading and Zig-compiled SPIR-V shaders. On Wayland it draws frames straight into the window's `linux_dmabuf` buffers when the GPU can import them (`VK_EXT_external_memory_dma_buf`, `VK_EXT_image_drm_format_modifier`), and into the buffers through the CPU otherwise. `VulkanArea` scenes then draw on the renderer's device, and `OpenGlArea` scenes are exported as dmabufs (`EGL_MESA_image_dma_buf_export`), so both go into the frame on the GPU.
  - **Custom Backends:** Implement `prepare` and `record` and wrap with `facet.Renderer.of(&my_backend)`. Rendering into a pointer to anything but the backend's target type returns `error.WrongTarget`.
- **Windowing (`facet.window`):**
  - Built-in **Wayland Client Window (`WaylandWindow`)** using `xdg-shell` (with menus and tooltips in `xdg_popup` surfaces), `zxdg_decoration_manager_v1` (automatic client-side title bar & shadows or server-side decorations), `wl_shm` shared-memory buffers, `wp_cursor_shape_v1`, `wl_data_device` clipboard & drag-and-drop, `zwp_text_input_v3` IME support, `wp_presentation`, the compositor's XKB keymap (any layout, with its groups, levels and modifiers, read in pure Zig by `window.xkb`), and dead keys and the Compose key (the user's or locale's Compose file, found as libxkbcommon finds it, by `window.compose`).
  - Generic, platform-neutral **`Window` interface (`facet.Window.of(&my_window)`)** for custom windowing backends (and future macOS/Windows support); run an app in one with `facet.App.openIn(gpa, &my_window, options)`.
- **Bundled Fonts & Icons (`facet.font`, `facet.icons`):**
  - Pure-Zig OpenType/TrueType parser, shaper, and rasterizer (`kern`/`GPOS`, `liga`/`GSUB`, `COLR`/`CPAL` color emoji).
  - Includes **Fira Sans** (`font.default_font_data`), **Twemoji Mozilla** (`font.emoji_font_data`), and build-time subsetted **Material Icons** out of the box via `Ui.createDefault(gpa)`, while allowing custom fonts via `Ui.createWithFontData(gpa, ttf_bytes)` (or `App.Options.font_data`), or `Ui.create(gpa, my_font)` (`null` for no text font).

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
    const app = try facet.App.open(init.gpa, init.minimal.environ, .{
        .title = "Hello Facet",
        .size = .{ 480, 320 },
    });
    defer app.close();

    while (try app.step(std.math.maxInt(u64))) {
        app.takeInput();
        try app.draw(facet.window.nowNs(), Counter{});
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
| `zig build run-opengl` | `examples/opengl.zig` | Interactive 3D Platonic solid viewer rendered with OpenGL |
| `zig build run-vulkan` | `examples/vulkan.zig` | Interactive 3D Platonic solid viewer rendered with Vulkan |

## Tools

| Command | Source | Description |
| --- | --- | --- |
| `zig build run-showcase` | `tools/showcase.zig` | A tour of every widget, a page each for buttons, selection, text, feedback, containers, layout, images (each format, from memory, bytes and URLs), icons (all of them, searchable), 3D (Vulkan and OpenGL), and special widgets (QR codes, custom painting, animation and the title bar) |
| `zig build run-info` | `tools/info.zig` | The windowing, buffer, synchronization and rendering backends facet picks on your system |

