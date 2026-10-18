# Facet

**Facet** is a standalone, zero-dependency, declarative Material 3 UI toolkit for Zig.

An application describes its UI as a tree of plain Zig structs rebuilt each frame from its state. Facet preserves widget state and layout across frames, lays the tree out with fault-tolerant constraints (highlighting any overflow rather than failing), tracks damage rectangles so only changed regions are redrawn, and renders via pluggable backends.

## Features

- **Declarative Material 3 Widget Set:**
  - Layout: `Row`, `Column`, `Flex`, `Expanded`, `Grid`, `LazyGrid`, `ScrollView`, `Overlay`, `Padding`, `Align`, `Center`, `SizedBox`, `ConstrainedBox`
  - Controls & Buttons: `FilledButton`, `TonalButton`, `OutlinedButton`, `TextButton`, `IconButton`, `PillBar`, `Checkbox`, `Radio`, `Switch`, `Slider`, `DropdownMenu`, `Select`
  - Containers & Navigation: `Card`, `ListItem`, `Chip`, `Badge`, `Divider`, `NavigationRail`, `TabBar`, `Dialog`, `Snackbar`, `Tooltip`, `Menu`, `TitleBar`
  - Text, Media & 3D: `Text`, `TextField`, `TextArea` (`TextDocument` with syntax highlighting), `Icon`, `Image`, `QrCode`, `Spinner`, `ProgressBar`, `OpenGlArea`, `VulkanArea`
- **Pluggable Rendering Backends (`facet.gfx`):**
  - **Software (`SoftwareRenderer`):** Zero-dependency CPU rasterizer for all 2D SDF shapes, polygons, alpha/color glyphs, and bilinear images.
  - **OpenGL (`OpenGlRenderer`, `OpenGlContext`):** OpenGL 3.3+ backend and offscreen 3D widget framework using runtime `GetProcAddress` function loading (no C headers required).
  - **Vulkan (`VulkanRenderer`, `VulkanContext`):** Vulkan 1.1+ backend and offscreen 3D widget framework using runtime `GetDeviceProcAddr` loading and Zig-compiled SPIR-V shaders.
  - **Custom Backends:** Implement `prepare` and `render` and wrap with `facet.Renderer.of(&my_backend)`.
- **Windowing (`facet.window`):**
  - Built-in **Wayland Client Window (`WaylandWindow`)** using `xdg-shell`, `zxdg_decoration_manager_v1` (automatic client-side title bar & shadows or server-side decorations), `wl_shm` shared-memory buffers, `wp_cursor_shape_v1`, `wl_data_device` clipboard & drag-and-drop, `zwp_text_input_v3` IME support, and `wp_presentation`.
  - Generic **`Window` interface (`facet.Window.of(&my_window)`)** for custom windowing backends (and future macOS/Windows support).
- **Bundled Fonts & Icons (`facet.font`, `facet.icons`):**
  - Pure-Zig OpenType/TrueType parser, shaper, and rasterizer (`kern`/`GPOS`, `liga`/`GSUB`, `COLR`/`CPAL` color emoji).
  - Includes **Fira Sans** (`font.default_font_data`), **Twemoji Mozilla** (`font.emoji_font_data`), and build-time subsetted **Material Icons** out of the box via `Ui.createDefault(gpa)`, while allowing custom fonts or `null` via `Ui.create(gpa, my_font)`.

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
    greeting: []const u8 = "Hello, Facet!",

    pub const State = struct {
        count: i32 = 0,

        pub fn increment(s: *State) void {
            s.count += 1;
        }

        pub fn decrement(s: *State) void {
            s.count -= 1;
        }
    };

    pub fn build(self: *const Counter, cx: *facet.Context, state: *State) facet.Widget {
        const t = cx.theme();
        return cx.make(facet.Center{
            .child = cx.make(facet.Card{
                .variant = .elevated,
                .padding = .all(24),
                .child = cx.make(facet.Column{
                    .main_axis_size = .min,
                    .cross_axis_alignment = .center,
                    .spacing = 16,
                    .children = &.{
                        cx.make(facet.Text{
                            .text = self.greeting,
                            .style = .{ .size = t.title_size, .color = t.on_surface },
                        }),
                        cx.make(facet.Text{
                            .text = cx.fmt("Count: {d}", .{state.count}),
                            .style = .{ .size = 32, .color = t.primary },
                        }),
                        cx.make(facet.Row{
                            .main_axis_size = .min,
                            .spacing = 12,
                            .children = &.{
                                cx.make(facet.OutlinedButton{
                                    .label = "−1",
                                    .on_press = .of(state, State.decrement),
                                }),
                                cx.make(facet.FilledButton{
                                    .label = "+1",
                                    .icon = .add,
                                    .on_press = .of(state, State.increment),
                                }),
                            },
                        }),
                    },
                }),
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
| `zig build run-controls` | `examples/controls.zig` | Interactive form controls and theme switcher |
| `zig build run-navigation` | `examples/navigation.zig` | Inbox application with navigation rail, tabs, confirmation dialog, and undo snackbar |
| `zig build run-lists` | `examples/lists_and_drag.zig` | Grid of 500 items that can be dragged and dropped into a pinned list |
| `zig build run-editor` | `examples/editor.zig` | Multi-line code editor with Zig syntax highlighting |
| `zig build run-canvas` | `examples/canvas_and_qr.zig` | Animated harmonic wave viewer and live QR code generator |
| `zig build run-opengl` | `examples/opengl.zig` | Interactive 3D Platonic solid viewer rendered with OpenGL |
| `zig build run-vulkan` | `examples/vulkan.zig` | Interactive 3D Platonic solid viewer rendered with Vulkan |
| `zig build run-showcase` | `examples/showcase.zig` | Interactive gallery of Material 3 widgets across four pages |

