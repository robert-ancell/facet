# Facet

**Facet** is a standalone, zero-dependency, declarative Material 3 UI toolkit for Zig.

An application describes its UI as a tree of plain Zig structs rebuilt each frame from its state. Facet preserves widget state and layout across frames, lays the tree out with fault-tolerant constraints (highlighting any overflow rather than failing), tracks damage rectangles so only changed regions are redrawn, and renders via pluggable backends.

## Features

- **Declarative Material 3 Widget Set:**
  - Layout: `Row`, `Column`, `Flex`, `Expanded`, `Grid`, `LazyGrid`, `ScrollView`, `Overlay`, `Padding`, `Align`, `Center`, `SizedBox`, `ConstrainedBox`
  - Controls & Buttons: `FilledButton`, `TonalButton`, `OutlinedButton`, `TextButton`, `IconButton`, `PillBar`, `Checkbox`, `Radio`, `Switch`, `Slider`, `DropdownMenu`, `Select`
  - Containers & Navigation: `Card`, `ListItem`, `Chip`, `Badge`, `Divider`, `NavigationRail`, `TabBar`, `Dialog`, `Snackbar`, `Tooltip`, `Menu`, `TitleBar`
  - Text & Media: `Text`, `TextField`, `TextArea` (`TextDocument` with syntax highlighting), `Icon`, `Image`, `QrCode`, `Spinner`, `ProgressBar`
- **Pluggable Rendering Backends (`facet.gfx`):**
  - **Software (`SoftwareRenderer`):** Zero-dependency CPU rasterizer for all 2D SDF shapes, polygons, alpha/color glyphs, and bilinear images.
  - **OpenGL (`OpenGlRenderer`):** OpenGL 3.3+ backend using runtime `GetProcAddress` function loading (no C headers required).
  - **Vulkan (`VulkanRenderer`):** Vulkan 1.0+ backend using runtime `GetDeviceProcAddr` loading and Zig-compiled SPIR-V shaders.
  - **Custom Backends:** Implement `prepare` and `render` and wrap with `facet.Renderer.of(&my_backend)`.
- **Windowing (`facet.window`):**
  - Built-in **Wayland Client Window (`WaylandWindow`)** using `xdg-shell`, `wl_shm` shared-memory buffers, `wp_cursor_shape_v1`, `wl_data_device` clipboard & drag-and-drop, `zwp_text_input_v3` IME support, and `wp_presentation`.
  - Generic **`Window` interface (`facet.Window.of(&my_window)`)** for custom windowing backends (and future macOS/Windows support).
- **Bundled Fonts & Icons (`facet.font`, `facet.icons`):**
  - Pure-Zig OpenType/TrueType parser, shaper, and rasterizer (`kern`/`GPOS`, `liga`/`GSUB`, `COLR`/`CPAL` color emoji).
  - Includes **Fira Sans** (`font.default_font_data`), **Twemoji Mozilla** (`font.emoji_font_data`), and build-time subsetted **Material Icons** out of the box via `Ui.createDefault(gpa)`, while allowing custom fonts or `null` via `Ui.create(gpa, my_font)`.

## Running Tests

```sh
zig build test
```
