//! Selection: checkboxes, radio buttons, switches, sliders, dropdowns and
//! chips.

const std = @import("std");
const facet = @import("facet");
const common = @import("common.zig");

pub const Size = enum { small, medium, large };
pub const Quality = enum { low, balanced, high, ultra };

const topping_names = [_][]const u8{ "Cheese", "Mushroom", "Olives" };
const filter_names = [_][]const u8{ "Unread", "Starred", "Files", "From me" };
const filter_icons = [_]facet.IconName{ .mail, .star, .folder, .person };
const tag_names = [_][]const u8{ "zig", "wayland", "vulkan" };
const resolutions = [_][]const u8{ "3840 × 2160", "2560 × 1440", "1920 × 1080", "1280 × 720" };

pub const State = struct {
    toppings: [topping_names.len]bool = .{ true, false, true },
    terms: bool = false,
    size: Size = .medium,
    wifi: bool = true,
    bluetooth: bool = false,
    airplane: bool = false,
    volume: f32 = 0.6,
    brightness: f32 = 40,
    resolution: usize = 2,
    quality: Quality = .balanced,
    filters: [filter_names.len]bool = .{ true, false, false, false },
    tags: [tag_names.len]bool = @splat(true),
    log: common.Log = .{},
    agreed: common.Log = .{},

    fn setTerms(s: *State, v: bool) void {
        s.terms = v;
    }
    fn setSize(s: *State, v: Size) void {
        s.size = v;
    }
    fn setWifi(s: *State, v: bool) void {
        s.wifi = v;
    }
    fn setBluetooth(s: *State, v: bool) void {
        s.bluetooth = v;
    }
    fn setAirplane(s: *State, v: bool) void {
        s.airplane = v;
        if (v) {
            s.wifi = false;
            s.bluetooth = false;
        }
    }
    fn setVolume(s: *State, v: f32) void {
        s.volume = v;
    }
    fn setBrightness(s: *State, v: f32) void {
        s.brightness = v;
    }
    fn setResolution(s: *State, v: usize) void {
        s.resolution = v;
    }
    fn setQuality(s: *State, v: Quality) void {
        s.quality = v;
    }
    fn resetTags(s: *State) void {
        s.tags = @splat(true);
    }
};

/// A callback flipping `flag`.
fn toggle(flag: *bool) facet.Callback {
    const T = struct {
        fn flip(f: *bool) void {
            f.* = !f.*;
        }
    };
    return .of(flag, T.flip);
}

/// A callback for a checkbox setting `flag`.
fn setter(flag: *bool) facet.ValueCallback(bool) {
    const T = struct {
        fn set(f: *bool, v: bool) void {
            f.* = v;
        }
    };
    return .of(flag, T.set);
}

/// A callback clearing `flag`.
fn clear(flag: *bool) facet.Callback {
    const T = struct {
        fn clear(f: *bool) void {
            f.* = false;
        }
    };
    return .of(flag, T.clear);
}

pub fn build(cx: *facet.Context, s: *State) facet.Widget {
    const t = cx.theme();

    var toppings: [topping_names.len]facet.Widget = undefined;
    for (&toppings, topping_names, &s.toppings) |*w, name, *on| {
        w.* = cx.make(facet.CheckboxRow{ .value = on.*, .on_changed = setter(on), .label = name });
    }

    const sizes = [_]struct { Size, []const u8 }{ .{ .small, "Small" }, .{ .medium, "Medium" }, .{ .large, "Large" } };
    var radios: [sizes.len]facet.Widget = undefined;
    for (&radios, sizes) |*w, sz| {
        w.* = cx.make(facet.RadioRow(Size){ .value = sz[0], .group_value = s.size, .on_changed = .of(s, State.setSize), .label = sz[1] });
    }

    var filters: [filter_names.len]facet.Widget = undefined;
    for (&filters, filter_names, filter_icons, &s.filters) |*w, name, icon, *on| {
        w.* = cx.make(facet.Chip{ .label = name, .icon = icon, .selected = on.*, .on_press = toggle(on) });
    }

    var tags: [tag_names.len + 1]facet.Widget = undefined;
    var tag_count: usize = 0;
    for (tag_names, &s.tags) |name, *shown| {
        if (!shown.*) continue;
        tags[tag_count] = cx.make(facet.Chip{ .label = name, .on_remove = clear(shown) });
        tag_count += 1;
    }
    tags[tag_count] = cx.make(facet.TextButton{ .label = "Reset", .icon = .refresh, .on_press = .of(s, State.resetTags) });
    tag_count += 1;

    const qualities = [_]facet.Select(Quality).Option{
        .{ .value = .low, .label = "Low" },
        .{ .value = .balanced, .label = "Balanced" },
        .{ .value = .high, .label = "High" },
        .{ .value = .ultra, .label = "Ultra" },
    };

    return common.page(cx, &.{
        common.section(cx, "Checkboxes", "Any number of options from a set, each on or off", &.{
            common.labelled(cx, "Toppings", &toppings),
            common.labelled(cx, "Disabled", cx.makeAll(.{
                facet.CheckboxRow{ .value = true, .label = "Always on" },
                facet.CheckboxRow{ .value = false, .label = "Never on" },
            })),
            common.labelled(cx, "Agreement", cx.makeAll(.{
                facet.CheckboxRow{ .value = s.terms, .on_changed = .of(s, State.setTerms), .label = "I agree to the terms" },
                facet.FilledButton{ .label = "Continue", .on_press = if (s.terms) common.pressed(cx, &s.agreed, "Continue") else null },
            })),
            common.status(cx, s.agreed.text("Agree to the terms to continue")),
        }),
        common.section(cx, "Radio buttons", "Exactly one option from a set, here of an enum", &.{
            common.labelled(cx, "Size", &radios),
            common.labelled(cx, "Disabled", cx.makeAll(.{
                facet.RadioRow(u8){ .value = 0, .group_value = 0, .label = "Chosen" },
                facet.RadioRow(u8){ .value = 1, .group_value = 0, .label = "Not chosen" },
            })),
            common.status(cx, cx.fmt("Size is {s}", .{@tagName(s.size)})),
        }),
        common.section(cx, "Switches", "A setting turned on or off straight away", &.{
            common.labelled(cx, "Radios", cx.makeAll(.{
                facet.SwitchRow{ .value = s.wifi, .on_changed = if (s.airplane) null else .of(s, State.setWifi), .label = "Wi-Fi" },
                facet.SwitchRow{ .value = s.bluetooth, .on_changed = if (s.airplane) null else .of(s, State.setBluetooth), .label = "Bluetooth" },
            })),
            common.labelled(cx, "Override", cx.makeAll(.{
                facet.SwitchRow{ .value = s.airplane, .on_changed = .of(s, State.setAirplane), .label = "Airplane mode (turns the others off)" },
            })),
        }),
        common.section(cx, "Sliders", "A value from a range, continuous or in steps", &.{
            common.labelled(cx, cx.fmt("Volume {d:.0}%", .{s.volume * 100}), cx.makeAll(.{
                facet.Icon{ .icon = .remove, .size = 20, .color = t.on_surface_variant },
                facet.Expanded{ .child = cx.make(facet.Slider{ .value = s.volume, .on_changed = .of(s, State.setVolume) }) },
                facet.Icon{ .icon = .add, .size = 20, .color = t.on_surface_variant },
            })),
            common.labelled(cx, cx.fmt("Brightness {d:.0}", .{s.brightness}), cx.makeAll(.{
                facet.Expanded{ .child = cx.make(facet.Slider{ .value = s.brightness, .min = 0, .max = 100, .divisions = 10, .on_changed = .of(s, State.setBrightness) }) },
            })),
            common.labelled(cx, "Disabled", cx.makeAll(.{
                facet.Expanded{ .child = cx.make(facet.Slider{ .value = 0.3 }) },
            })),
        }),
        common.section(cx, "Dropdown menus", "One option from a list shown in a menu: by index, or of a type with Select", &.{
            common.labelled(cx, "Resolution", cx.makeAll(.{
                facet.DropdownMenu{ .options = &resolutions, .selected = s.resolution, .on_selected = .of(s, State.setResolution), .icon = .image, .width = 200 },
            })),
            common.labelled(cx, "Quality", cx.makeAll(.{
                facet.Select(Quality){ .options = &qualities, .value = s.quality, .on_changed = .of(s, State.setQuality), .icon = .tune, .width = 200 },
            })),
            common.labelled(cx, "Disabled", cx.makeAll(.{
                facet.DropdownMenu{ .options = &resolutions, .selected = null, .placeholder = "Not available", .width = 200 },
            })),
        }),
        common.section(cx, "Chips", "Filter chips turned on and off, and input chips that can be removed", &.{
            common.labelled(cx, "Filters", &filters),
            common.labelled(cx, "Tags", tags[0..tag_count]),
            common.labelled(cx, "Assist", cx.makeAll(.{
                facet.Chip{ .label = "Add to calendar", .icon = .add, .on_press = common.pressed(cx, &s.log, "Add to calendar") },
            })),
            common.status(cx, s.log.text("Choose an assist chip")),
        }),
    });
}
