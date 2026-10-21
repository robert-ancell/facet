const std = @import("std");

const IconFont = struct {
    ttf: std.Build.LazyPath,
    codepoints: std.Build.LazyPath,
};

fn addIconFont(b: *std.Build) IconFont {
    const tool = b.addExecutable(.{
        .name = "subset_icons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/subset_icons.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const host_font = b.createModule(.{
        .root_source_file = b.path("src/font/font.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    host_font.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    host_font.addAnonymousImport("TwemojiMozilla.ttf", .{ .root_source_file = b.path("fonts/TwemojiMozilla.ttf") });
    tool.root_module.addImport("font", host_font);
    tool.root_module.addImport("icon_names", b.createModule(.{
        .root_source_file = b.path("src/icons/names.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    }));
    const run = b.addRunArtifact(tool);
    run.addFileArg(b.path("fonts/MaterialIcons-Regular.ttf"));
    run.addFileArg(b.path("fonts/MaterialIcons-Regular.codepoints"));
    const ttf = run.addOutputFileArg("MaterialIcons.ttf");
    const codepoints = run.addOutputFileArg("icon_codepoints.zig");
    return .{ .ttf = ttf, .codepoints = codepoints };
}

fn addSpirv(b: *std.Build, name: []const u8, source: []const u8, os_tag: std.Target.Os.Tag) std.Build.LazyPath {
    const spirv_target = b.resolveTargetQuery(.{ .cpu_arch = .spirv64, .os_tag = os_tag, .ofmt = .spirv });
    const gpu = b.createModule(.{
        .root_source_file = b.path("src/gfx/shaders/gpu.zig"),
        .target = spirv_target,
        .optimize = .fast,
    });
    const obj = b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = spirv_target,
            .optimize = .fast,
            .imports = &.{.{ .name = "gpu", .module = gpu }},
        }),
        .use_llvm = false,
    });
    return obj.getEmittedBin();
}

pub const Modules = struct {
    facet: *std.Build.Module,
    ui: *std.Build.Module,
    gfx: *std.Build.Module,
    font: *std.Build.Module,
    icons: *std.Build.Module,
    window: *std.Build.Module,
    wayland: *std.Build.Module,
};

pub fn createModules(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    icon_font: IconFont,
) Modules {
    const wayland = b.createModule(.{
        .root_source_file = b.path("src/wayland/wayland.zig"),
        .target = target,
        .optimize = optimize,
    });

    const font = b.createModule(.{
        .root_source_file = b.path("src/font/font.zig"),
        .target = target,
        .optimize = optimize,
    });
    font.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    font.addAnonymousImport("TwemojiMozilla.ttf", .{ .root_source_file = b.path("fonts/TwemojiMozilla.ttf") });

    const icons = b.createModule(.{
        .root_source_file = b.path("src/icons/icons.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "font", .module = font },
            .{ .name = "icon_codepoints", .module = b.createModule(.{
                .root_source_file = icon_font.codepoints,
                .target = target,
                .optimize = optimize,
            }) },
        },
    });
    icons.addAnonymousImport("MaterialIcons.ttf", .{ .root_source_file = icon_font.ttf });

    const gfx = b.createModule(.{
        .root_source_file = b.path("src/gfx/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "font", .module = font },
        },
    });
    for ([_][]const u8{ "shape", "solid", "text", "image", "window" }) |shader_name| {
        const spv = addSpirv(b, shader_name, b.fmt("src/gfx/shaders/{s}.zig", .{shader_name}), .vulkan);
        gfx.addAnonymousImport(b.fmt("{s}.spv", .{shader_name}), .{ .root_source_file = spv });
        const gl_spv = addSpirv(b, b.fmt("{s}_gl", .{shader_name}), b.fmt("src/gfx/shaders/{s}.zig", .{shader_name}), .opengl);
        gfx.addAnonymousImport(b.fmt("{s}_gl.spv", .{shader_name}), .{ .root_source_file = gl_spv });
    }

    const window = b.createModule(.{
        .root_source_file = b.path("src/window/window.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayland", .module = wayland },
            .{ .name = "gfx", .module = gfx },
        },
    });

    const ui = b.createModule(.{
        .root_source_file = b.path("src/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gfx", .module = gfx },
            .{ .name = "font", .module = font },
            .{ .name = "icons", .module = icons },
            .{ .name = "window", .module = window },
        },
    });

    const facet = b.addModule(name, .{
        .root_source_file = b.path("src/facet.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ui", .module = ui },
            .{ .name = "gfx", .module = gfx },
            .{ .name = "font", .module = font },
            .{ .name = "icons", .module = icons },
            .{ .name = "window", .module = window },
            .{ .name = "wayland", .module = wayland },
        },
    });

    return .{
        .facet = facet,
        .ui = ui,
        .gfx = gfx,
        .font = font,
        .icons = icons,
        .window = window,
        .wayland = wayland,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const icon_font = addIconFont(b);
    const mods = createModules(b, "facet", target, optimize, icon_font);
    const polyhedron_gl_spv = addSpirv(b, "polyhedron_gl", "examples/shaders/polyhedron.zig", .opengl);
    const polyhedron_vk_spv = addSpirv(b, "polyhedron_vk", "examples/shaders/polyhedron.zig", .vulkan);

    const examples = [_]struct {
        name: []const u8,
        source: []const u8,
        desc: []const u8,
        polyhedron_spv: ?std.Build.LazyPath = null,
        /// Not built for Windows (it uses an API facet has only elsewhere).
        not_windows: bool = false,
    }{
        .{ .name = "hello", .source = "examples/hello.zig", .desc = "Run the interactive counter example" },
        .{ .name = "navigation", .source = "examples/navigation.zig", .desc = "Run the inbox navigation, dialog, and snackbar example" },
        .{ .name = "lists", .source = "examples/lists_and_drag.zig", .desc = "Run the 500-item grid and drag-and-drop example" },
        .{ .name = "editor", .source = "examples/editor.zig", .desc = "Run the syntax-highlighted code editor example" },
        .{ .name = "canvas", .source = "examples/canvas_and_qr.zig", .desc = "Run the animated wave viewer and QR code generator example" },
        .{ .name = "fetch", .source = "examples/fetch.zig", .desc = "Run the example fetching over HTTP in the background on the app's std.Io" },
        .{ .name = "opengl", .source = "examples/opengl.zig", .desc = "Run the OpenGL 3D Platonic solid viewer example", .polyhedron_spv = polyhedron_gl_spv, .not_windows = true },
        .{ .name = "vulkan", .source = "examples/vulkan.zig", .desc = "Run the Vulkan 3D Platonic solid viewer example", .polyhedron_spv = polyhedron_vk_spv, .not_windows = true },
        .{ .name = "metal", .source = "examples/metal.zig", .desc = "Run the Metal 3D Platonic solid viewer example (macOS)", .not_windows = true },
    };

    const examples_step = b.step("examples", "Build all example applications");
    const test_step = b.step("test", "Run all unit tests");

    for (examples) |ex| {
        if (ex.not_windows and target.result.os.tag == .windows) continue;
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "facet", .module = mods.facet }},
        });
        if (ex.polyhedron_spv) |spv| {
            mod.addAnonymousImport("polyhedron.spv", .{ .root_source_file = spv });
        }
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = mod,
        });
        const install_exe = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install_exe.step);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{ex.name}), ex.desc);
        run_step.dependOn(&run_cmd.step);

        const ex_test = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(ex_test).step);
    }

    // Tools: one reporting the backends facet picks on this system, and a
    // tour of every widget.
    const tools = [_]struct {
        name: []const u8,
        step: []const u8,
        source: []const u8,
        desc: []const u8,
        cube: bool = false,
    }{
        .{ .name = "facet-info", .step = "info", .source = "tools/info.zig", .desc = "Show the windowing, buffer, sync and rendering backends in use" },
        .{ .name = "facet-showcase", .step = "showcase", .source = "tools/showcase.zig", .desc = "Run the tour of every widget", .cube = true },
    };
    const cube_vulkan_spv = addSpirv(b, "cube_vulkan", "tools/showcase/shaders/cube.zig", .vulkan);
    const cube_opengl_spv = addSpirv(b, "cube_opengl", "tools/showcase/shaders/cube.zig", .opengl);
    for (tools) |tool| {
        const mod = b.createModule(.{
            .root_source_file = b.path(tool.source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "facet", .module = mods.facet }},
        });
        if (tool.cube) {
            mod.addAnonymousImport("cube_vulkan.spv", .{ .root_source_file = cube_vulkan_spv });
            mod.addAnonymousImport("cube_opengl.spv", .{ .root_source_file = cube_opengl_spv });
        }
        const exe = b.addExecutable(.{
            .name = tool.name,
            .root_module = mod,
        });
        b.installArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{tool.step}), tool.desc);
        run_step.dependOn(&b.addRunArtifact(exe).step);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

    for ([_]*std.Build.Module{
        mods.font,
        mods.icons,
        mods.wayland,
        mods.gfx,
        mods.window,
        mods.ui,
        mods.facet,
    }) |m| {
        // Wayland's wire protocol has no use (or fds) on Windows.
        if (m == mods.wayland and target.result.os.tag == .windows) continue;
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
