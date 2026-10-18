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

fn addSpirv(b: *std.Build, name: []const u8, source: []const u8) std.Build.LazyPath {
    const spirv_target = b.resolveTargetQuery(.{ .cpu_arch = .spirv64, .os_tag = .vulkan, .ofmt = .spirv });
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
        .imports = &.{
            .{ .name = "font", .module = font },
        },
    });
    gfx.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    gfx.addAnonymousImport("TwemojiMozilla.ttf", .{ .root_source_file = b.path("fonts/TwemojiMozilla.ttf") });
    for ([_][]const u8{ "shape", "solid", "text", "image" }) |shader_name| {
        const spv = addSpirv(b, shader_name, b.fmt("src/gfx/shaders/{s}.zig", .{shader_name}));
        gfx.addAnonymousImport(b.fmt("{s}.spv", .{shader_name}), .{ .root_source_file = spv });
    }

    const window = b.createModule(.{
        .root_source_file = b.path("src/window/window.zig"),
        .target = target,
        .optimize = optimize,
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
    ui.addAnonymousImport("FiraSans-Regular.ttf", .{ .root_source_file = b.path("fonts/FiraSans-Regular.ttf") });
    ui.addAnonymousImport("TwemojiMozilla.ttf", .{ .root_source_file = b.path("fonts/TwemojiMozilla.ttf") });

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

    const examples = [_]struct {
        name: []const u8,
        source: []const u8,
        desc: []const u8,
    }{
        .{ .name = "hello", .source = "examples/hello.zig", .desc = "Run the Hello World counter example" },
        .{ .name = "controls", .source = "examples/controls.zig", .desc = "Run the Material 3 controls example" },
        .{ .name = "navigation", .source = "examples/navigation.zig", .desc = "Run the navigation, dialog, and snackbar example" },
        .{ .name = "lists", .source = "examples/lists_and_drag.zig", .desc = "Run the LazyGrid and drag-and-drop example" },
        .{ .name = "editor", .source = "examples/editor.zig", .desc = "Run the syntax-highlighted TextArea editor example" },
        .{ .name = "canvas", .source = "examples/canvas_and_qr.zig", .desc = "Run the custom 2D canvas and QR code example" },
        .{ .name = "showcase", .source = "examples/showcase.zig", .desc = "Run the interactive Material 3 widget showcase" },
    };

    const examples_step = b.step("examples", "Build all example applications");
    const test_step = b.step("test", "Run all unit tests");

    for (examples) |ex| {
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "facet", .module = mods.facet }},
        });
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

    for ([_]*std.Build.Module{
        mods.font,
        mods.icons,
        mods.wayland,
        mods.gfx,
        mods.window,
        mods.ui,
        mods.facet,
    }) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
