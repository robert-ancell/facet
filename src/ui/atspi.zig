//! The UI's accessibility tree (`accessibility.zig`) offered over AT-SPI,
//! the Linux desktop's accessibility bus, as GTK and Qt apps offer theirs:
//! the app registers with the bus's registry, assistive technologies ask
//! it about its objects (as D-Bus objects, with AT-SPI's interfaces:
//! Accessible, Component, Action, Value, Text and, for the app,
//! Application), and it tells them what changes (events: states, names,
//! values, children, focus).
//!
//! The app is the root (`/org/a11y/atspi/accessible/root`), its window a
//! frame in it, and each object `/org/a11y/atspi/accessible/<id>`.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("window").dbus;
const a11y = @import("accessibility.zig");

const Tree = a11y.Tree;
const Object = a11y.Object;
const Writer = dbus.Writer;
const Reader = dbus.Reader;

const root_path = "/org/a11y/atspi/accessible/root";
const object_prefix = "/org/a11y/atspi/accessible/";
const null_path = "/org/a11y/atspi/null";

pub const Bridge = struct {
    gpa: std.mem.Allocator,
    conn: *dbus.Connection,
    /// The registry's root, the app's parent.
    parent_bus: []u8 = &.{},
    parent_path: []u8 = &.{},
    /// What the app is called (its window's title, at first).
    app_name: []u8 = &.{},
    /// The id the registry gave it.
    app_id: i32 = 0,
    /// The tree it answers from: the last frame's.
    tree: ?*const Tree = null,
    /// Whether the window has been said to be active.
    activated: bool = false,

    /// Connects to the accessibility bus (`$AT_SPI_BUS_ADDRESS`, or the
    /// one the session bus says) and registers the app with its registry.
    pub fn connect(gpa: std.mem.Allocator, environ: std.process.Environ, app_name: []const u8) !*Bridge {
        const address = if (environ.getPosix("AT_SPI_BUS_ADDRESS")) |a| try gpa.dupe(u8, a) else try busAddress(gpa, environ);
        defer gpa.free(address);
        return connectTo(gpa, address, app_name);
    }

    /// Connects to the accessibility bus at `address`, and registers.
    pub fn connectTo(gpa: std.mem.Allocator, address: []const u8, app_name: []const u8) !*Bridge {
        const conn = try dbus.Connection.open(gpa, address);
        errdefer conn.close();
        const b = try gpa.create(Bridge);
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .conn = conn, .app_name = try gpa.dupe(u8, app_name) };
        errdefer gpa.free(b.app_name);
        // Embedded in the registry: it gives its root, the app's parent.
        var w: Writer = .{ .gpa = gpa };
        defer w.deinit();
        w.beginStruct();
        w.string(conn.unique_name);
        w.objectPath(root_path);
        if (w.failed) return error.OutOfMemory;
        const reply = try conn.callWait("org.a11y.atspi.Registry", root_path, "org.a11y.atspi.Socket", "Embed", "(so)", w.buf.items, 5000);
        defer gpa.free(reply);
        const m = try dbus.decode(reply);
        var r = m.reader();
        try r.beginStruct();
        b.parent_bus = try gpa.dupe(u8, try r.string());
        b.parent_path = try gpa.dupe(u8, try r.string());
        return b;
    }

    pub fn close(b: *Bridge) void {
        b.conn.close();
        b.gpa.free(b.parent_bus);
        b.gpa.free(b.parent_path);
        b.gpa.free(b.app_name);
        b.gpa.destroy(b);
    }

    /// The fd to wait on for calls.
    pub fn fd(b: *const Bridge) linux.fd_t {
        return b.conn.fd;
    }

    /// Answers the calls that have come (from `tree`, the last frame's);
    /// true if one did something (pressed a button, moved a slider), so
    /// the UI needs a frame.
    pub fn dispatch(b: *Bridge) bool {
        var acted = false;
        while (true) {
            const bytes = (b.conn.next() catch return acted) orelse return acted;
            defer b.gpa.free(bytes);
            const m = dbus.decode(bytes) catch continue;
            if (m.header.type != .method_call) continue;
            acted = b.handle(&m) or acted;
        }
    }

    // --- Events ---------------------------------------------------------------

    /// Says what changed from `old` to `new` (a new frame's tree, which it
    /// answers from now on).
    pub fn update(b: *Bridge, old: ?*const Tree, new: *const Tree) void {
        b.tree = new;
        if (!b.activated) {
            b.activated = true;
            b.event(a11y.window_id, "org.a11y.atspi.Event.Window", "Activate", "", 0, .{ .string = new.objects[0].info.name });
            b.event(a11y.window_id, "org.a11y.atspi.Event.Object", "StateChanged", "active", 1, .none);
        }
        const prev = old orelse return;
        for (new.objects) |*o| {
            const was = prev.find(o.id) orelse continue;
            // Names, descriptions, values.
            if (!std.mem.eql(u8, was.info.name, o.info.name)) b.event(o.id, "org.a11y.atspi.Event.Object", "PropertyChange", "accessible-name", 0, .{ .string = o.info.name });
            if (!std.mem.eql(u8, was.info.description, o.info.description)) b.event(o.id, "org.a11y.atspi.Event.Object", "PropertyChange", "accessible-description", 0, .{ .string = o.info.description });
            const v0 = if (was.info.value) |v| v.current else 0;
            const v1 = if (o.info.value) |v| v.current else 0;
            if (v0 != v1) b.event(o.id, "org.a11y.atspi.Event.Object", "PropertyChange", "accessible-value", 0, .{ .double = v1 });
            if (was.info.text != null and o.info.text != null and !std.mem.eql(u8, was.info.text.?, o.info.text.?)) {
                b.event(o.id, "org.a11y.atspi.Event.Object", "TextChanged", "delete", 0, .{ .string = was.info.text.? });
                b.event(o.id, "org.a11y.atspi.Event.Object", "TextChanged", "insert", 0, .{ .string = o.info.text.? });
            }
            // States.
            const s0: u16 = @bitCast(was.info.states);
            const s1: u16 = @bitCast(o.info.states);
            if (s0 != s1) inline for (a11y.States.atspi) |st| {
                const before = @field(was.info.states, st[0]);
                const after = @field(o.info.states, st[0]);
                if (before != after) {
                    b.event(o.id, "org.a11y.atspi.Event.Object", "StateChanged", st[2], @intFromBool(after), .none);
                    if (std.mem.eql(u8, st[0], "focused") and after) b.event(o.id, "org.a11y.atspi.Event.Focus", "Focus", "", 0, .none);
                }
            };
            if (was.info.states.disabled != o.info.states.disabled) {
                b.event(o.id, "org.a11y.atspi.Event.Object", "StateChanged", "enabled", @intFromBool(!o.info.states.disabled), .none);
                b.event(o.id, "org.a11y.atspi.Event.Object", "StateChanged", "sensitive", @intFromBool(!o.info.states.disabled), .none);
            }
            // Children gone, and come.
            for (was.children, 0..) |ci, i| {
                const child = prev.objects[ci];
                if (!hasChild(new, o, child.id)) b.event(o.id, "org.a11y.atspi.Event.Object", "ChildrenChanged", "remove", @intCast(i), .{ .object = child.id });
            }
            for (o.children, 0..) |ci, i| {
                const child = new.objects[ci];
                if (!hasChild(prev, was, child.id)) b.event(o.id, "org.a11y.atspi.Event.Object", "ChildrenChanged", "add", @intCast(i), .{ .object = child.id });
            }
        }
        // Those gone are defunct.
        for (prev.objects) |*o| if (new.find(o.id) == null) {
            b.event(o.id, "org.a11y.atspi.Event.Object", "StateChanged", "defunct", 1, .none);
        };
        // The focus come to an object that was not there before.
        if (new.focused) |fi| {
            const f = &new.objects[fi];
            if (prev.find(f.id) == null) {
                b.event(f.id, "org.a11y.atspi.Event.Object", "StateChanged", "focused", 1, .none);
                b.event(f.id, "org.a11y.atspi.Event.Focus", "Focus", "", 0, .none);
            }
        }
    }

    fn hasChild(t: *const Tree, o: *const Object, id: u32) bool {
        for (o.children) |ci| if (t.objects[ci].id == id) return true;
        return false;
    }

    const Any = union(enum) { none, string: []const u8, double: f64, object: u32 };

    /// An AT-SPI event: a signal from object `id`, (`kind`, `detail1`, 0,
    /// `any`, no properties).
    fn event(b: *Bridge, id: u32, interface: []const u8, member: []const u8, kind: []const u8, detail1: i32, any: Any) void {
        var path_buf: [64]u8 = undefined;
        var w: Writer = .{ .gpa = b.gpa };
        defer w.deinit();
        w.string(kind);
        w.int32(detail1);
        w.int32(0);
        switch (any) {
            .none => {
                w.variant("i");
                w.int32(0);
            },
            .string => |s| {
                w.variant("s");
                w.string(s);
            },
            .double => |d| {
                w.variant("d");
                w.double(d);
            },
            .object => |o| {
                w.variant("(so)");
                b.reference(&w, o);
            },
        }
        const props = w.beginArray(8);
        w.endArray(props);
        if (w.failed) return;
        _ = b.conn.sendMessage(.{
            .type = .signal,
            .serial = 0,
            .path = pathOf(id, &path_buf),
            .interface = interface,
            .member = member,
            .signature = "siiva{sv}",
        }, w.buf.items) catch {};
    }

    // --- Calls ----------------------------------------------------------------

    /// What a call is to: the app, or an object of the tree.
    const Target = union(enum) { app, object: *const Object };

    fn targetOf(b: *const Bridge, path: []const u8) ?Target {
        if (std.mem.eql(u8, path, root_path)) return .app;
        if (!std.mem.startsWith(u8, path, object_prefix)) return null;
        const id = std.fmt.parseInt(u32, path[object_prefix.len..], 10) catch return null;
        const t = b.tree orelse return null;
        return .{ .object = t.find(id) orelse return null };
    }

    /// Answers a call; true if it acted on the UI.
    fn handle(b: *Bridge, m: *const dbus.Message) bool {
        const h = m.header;
        const member = h.member orelse return false;
        const interface = h.interface orelse "";
        var w: Writer = .{ .gpa = b.gpa };
        defer w.deinit();
        var acted = false;
        const sig: ?[]const u8 = blk: {
            if (std.mem.eql(u8, interface, "org.freedesktop.DBus.Peer")) {
                if (std.mem.eql(u8, member, "Ping")) break :blk "";
                break :blk null;
            }
            // AT-SPI's cache of everything at once: none kept (each object
            // is asked about as it is needed).
            if (std.mem.eql(u8, interface, "org.a11y.atspi.Cache")) {
                if (!std.mem.eql(u8, member, "GetItems")) break :blk null;
                const arr = w.beginArray(8);
                w.endArray(arr);
                break :blk "a((so)(so)(so)iiassusau)";
            }
            const target = b.targetOf(h.path orelse "") orelse {
                b.fail(m, "org.freedesktop.DBus.Error.UnknownObject", "No such object");
                return false;
            };
            var r = m.reader();
            break :blk b.call(target, interface, member, &r, &w, &acted) catch null;
        };
        if (sig) |s| {
            if (w.failed) return acted;
            if (h.flags & dbus.no_reply_expected != 0) return acted;
            _ = b.conn.sendMessage(.{ .type = .method_return, .serial = 0, .reply_serial = h.serial, .destination = h.sender, .signature = s }, w.buf.items) catch {};
        } else b.fail(m, "org.freedesktop.DBus.Error.UnknownMethod", member);
        return acted;
    }

    fn fail(b: *Bridge, m: *const dbus.Message, name: []const u8, message: []const u8) void {
        if (m.header.flags & dbus.no_reply_expected != 0) return;
        var w: Writer = .{ .gpa = b.gpa };
        defer w.deinit();
        w.string(message);
        if (w.failed) return;
        _ = b.conn.sendMessage(.{ .type = .@"error", .serial = 0, .reply_serial = m.header.serial, .destination = m.header.sender, .error_name = name, .signature = "s" }, w.buf.items) catch {};
    }

    /// Writes a reference to object `id` (the app's, if 0).
    fn reference(b: *const Bridge, w: *Writer, id: u32) void {
        var buf: [64]u8 = undefined;
        w.beginStruct();
        w.string(b.conn.unique_name);
        w.objectPath(if (id == 0) root_path else pathOf(id, &buf));
    }

    fn nullReference(w: *Writer) void {
        w.beginStruct();
        w.string("");
        w.objectPath(null_path);
    }

    /// Answers a method of `target`: what it returns (its signature),
    /// written in `w`; null if there is no such method.
    fn call(b: *Bridge, target: Target, interface: []const u8, member: []const u8, r: *Reader, w: *Writer, acted: *bool) !?[]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, interface, "org.freedesktop.DBus.Properties")) {
            if (eq(u8, member, "Get")) {
                const iface = try r.string();
                const name = try r.string();
                return if (b.property(target, iface, name, w, true)) "v" else null;
            }
            if (eq(u8, member, "GetAll")) {
                const iface = try r.string();
                const all = w.beginArray(8);
                for (propertiesOf(iface)) |name| {
                    var probe: Writer = .{ .gpa = b.gpa };
                    defer probe.deinit();
                    if (!b.property(target, iface, name, &probe, false)) continue;
                    w.beginStruct();
                    w.string(name);
                    _ = b.property(target, iface, name, w, true);
                }
                w.endArray(all);
                return "a{sv}";
            }
            if (eq(u8, member, "Set")) {
                const iface = try r.string();
                const name = try r.string();
                const vsig = try r.signature();
                if (eq(u8, iface, "org.a11y.atspi.Application") and eq(u8, name, "Id") and eq(u8, vsig, "i")) {
                    b.app_id = try r.int32();
                    return "";
                }
                if (eq(u8, iface, "org.a11y.atspi.Value") and eq(u8, name, "CurrentValue") and target == .object) {
                    const v: f64 = if (eq(u8, vsig, "d")) try r.double() else if (eq(u8, vsig, "i")) @floatFromInt(try r.int32()) else return null;
                    const set = target.object.info.set_value orelse return null;
                    set.call(v);
                    acted.* = true;
                    return "";
                }
                return null;
            }
            return null;
        }
        if (eq(u8, interface, "org.freedesktop.DBus.Introspectable")) {
            if (!eq(u8, member, "Introspect")) return null;
            w.string(introspection);
            return "s";
        }
        if (eq(u8, interface, "org.a11y.atspi.Accessible")) return b.accessible(target, member, r, w);
        if (eq(u8, interface, "org.a11y.atspi.Application")) {
            if (target != .app) return null;
            if (eq(u8, member, "GetLocale")) {
                w.string("");
                return "s";
            }
            if (eq(u8, member, "RegisterEventListener") or eq(u8, member, "DeregisterEventListener")) return "";
            if (eq(u8, member, "GetApplicationBusAddress")) {
                w.string("");
                return "s";
            }
            return null;
        }
        const o = switch (target) {
            .object => |o| o,
            .app => return null,
        };
        if (eq(u8, interface, "org.a11y.atspi.Component")) return b.component(o, member, r, w, acted);
        if (eq(u8, interface, "org.a11y.atspi.Action")) return action(o, member, r, w, acted);
        if (eq(u8, interface, "org.a11y.atspi.Text")) return text(o, member, r, w);
        return null;
    }

    fn accessible(b: *Bridge, target: Target, member: []const u8, r: *Reader, w: *Writer) !?[]const u8 {
        const eq = std.mem.eql;
        const t = b.tree orelse return null;
        // The app has one child: the window.
        const children: []const u32 = switch (target) {
            .app => &.{0},
            .object => |o| o.children,
        };
        if (eq(u8, member, "GetChildAtIndex")) {
            const i = try r.int32();
            if (i < 0 or i >= children.len) nullReference(w) else b.reference(w, t.objects[children[@intCast(i)]].id);
            return "(so)";
        }
        if (eq(u8, member, "GetChildren")) {
            const arr = w.beginArray(8);
            for (children) |ci| b.reference(w, t.objects[ci].id);
            w.endArray(arr);
            return "a(so)";
        }
        if (eq(u8, member, "GetIndexInParent")) {
            w.int32(switch (target) {
                .app => -1,
                .object => |o| if (o.parent) |p| blk: {
                    for (t.objects[p].children, 0..) |ci, i| if (t.objects[ci].id == o.id) break :blk @intCast(i);
                    break :blk -1;
                } else 0,
            });
            return "i";
        }
        if (eq(u8, member, "GetRelationSet")) {
            const arr = w.beginArray(8);
            w.endArray(arr);
            return "a(ua(so))";
        }
        if (eq(u8, member, "GetRole")) {
            w.uint32(@backingInt(roleOf(target)));
            return "u";
        }
        if (eq(u8, member, "GetRoleName") or eq(u8, member, "GetLocalizedRoleName")) {
            var buf: [32]u8 = undefined;
            w.string(roleOf(target).name(&buf));
            return "s";
        }
        if (eq(u8, member, "GetState")) {
            const bits: [2]u32 = switch (target) {
                .app => .{ 0, 0 },
                .object => |o| blk: {
                    var bits = o.info.states.bits();
                    // The window: active.
                    if (o.id == a11y.window_id) bits[0] |= 1 << 1;
                    break :blk bits;
                },
            };
            const arr = w.beginArray(4);
            w.uint32(bits[0]);
            w.uint32(bits[1]);
            w.endArray(arr);
            return "au";
        }
        if (eq(u8, member, "GetAttributes")) {
            const arr = w.beginArray(8);
            if (target == .app) {
                w.beginStruct();
                w.string("toolkit");
                w.string("facet");
            }
            w.endArray(arr);
            return "a{ss}";
        }
        if (eq(u8, member, "GetApplication")) {
            b.reference(w, 0);
            return "(so)";
        }
        if (eq(u8, member, "GetInterfaces")) {
            const arr = w.beginArray(4);
            for (interfacesOf(target)) |name| w.string(name);
            w.endArray(arr);
            return "as";
        }
        return null;
    }

    fn roleOf(target: Target) a11y.Role {
        return switch (target) {
            .app => .application,
            .object => |o| o.info.role,
        };
    }

    /// The interfaces `target` has (as `GetInterfaces` gives them).
    fn interfacesOf(target: Target) []const []const u8 {
        const o = switch (target) {
            .app => return &.{ "org.a11y.atspi.Accessible", "org.a11y.atspi.Application" },
            .object => |o| o,
        };
        const base = "org.a11y.atspi.Accessible";
        const comp = "org.a11y.atspi.Component";
        const act = "org.a11y.atspi.Action";
        const val = "org.a11y.atspi.Value";
        const txt = "org.a11y.atspi.Text";
        const has_action = o.info.activate != null;
        const has_value = o.info.value != null;
        const has_text = o.info.text != null;
        // Every mix of the three.
        return switch (@as(u3, @intFromBool(has_action)) | @as(u3, @intFromBool(has_value)) << 1 | @as(u3, @intFromBool(has_text)) << 2) {
            0 => &.{ base, comp },
            1 => &.{ base, comp, act },
            2 => &.{ base, comp, val },
            3 => &.{ base, comp, act, val },
            4 => &.{ base, comp, txt },
            5 => &.{ base, comp, act, txt },
            6 => &.{ base, comp, val, txt },
            7 => &.{ base, comp, act, val, txt },
        };
    }

    fn propertiesOf(iface: []const u8) []const []const u8 {
        const eq = std.mem.eql;
        if (eq(u8, iface, "org.a11y.atspi.Accessible")) return &.{ "Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId", "HelpText" };
        if (eq(u8, iface, "org.a11y.atspi.Application")) return &.{ "ToolkitName", "Version", "AtspiVersion", "Id", "InterfaceVersion" };
        if (eq(u8, iface, "org.a11y.atspi.Value")) return &.{ "MinimumValue", "MaximumValue", "MinimumIncrement", "CurrentValue", "Text" };
        if (eq(u8, iface, "org.a11y.atspi.Text")) return &.{ "CharacterCount", "CaretOffset" };
        if (eq(u8, iface, "org.a11y.atspi.Action")) return &.{"NActions"};
        return &.{};
    }

    /// Writes a property's value (as a variant, if `as_variant`); false if
    /// it has no such property.
    fn property(b: *Bridge, target: Target, iface: []const u8, name: []const u8, w: *Writer, as_variant: bool) bool {
        const eq = std.mem.eql;
        const t = b.tree;
        const Out = struct {
            w: *Writer,
            v: bool,
            fn s(o: @This(), x: []const u8) bool {
                if (o.v) o.w.variant("s");
                o.w.string(x);
                return true;
            }
            fn i(o: @This(), x: i32) bool {
                if (o.v) o.w.variant("i");
                o.w.int32(x);
                return true;
            }
            fn d(o: @This(), x: f64) bool {
                if (o.v) o.w.variant("d");
                o.w.double(x);
                return true;
            }
            fn u(o: @This(), x: u32) bool {
                if (o.v) o.w.variant("u");
                o.w.uint32(x);
                return true;
            }
        };
        const out: Out = .{ .w = w, .v = as_variant };
        if (eq(u8, iface, "org.a11y.atspi.Accessible")) {
            if (eq(u8, name, "Name")) return out.s(switch (target) {
                .app => b.app_name,
                .object => |o| o.info.name,
            });
            if (eq(u8, name, "Description")) return out.s(switch (target) {
                .app => "",
                .object => |o| o.info.description,
            });
            if (eq(u8, name, "HelpText") or eq(u8, name, "AccessibleId") or eq(u8, name, "Locale")) return out.s("");
            if (eq(u8, name, "ChildCount")) return out.i(switch (target) {
                .app => 1,
                .object => |o| @intCast(o.children.len),
            });
            if (eq(u8, name, "Parent")) {
                if (as_variant) w.variant("(so)");
                switch (target) {
                    .app => {
                        w.beginStruct();
                        w.string(b.parent_bus);
                        w.objectPath(b.parent_path);
                    },
                    .object => |o| if (o.parent) |p| b.reference(w, t.?.objects[p].id) else b.reference(w, 0),
                }
                return true;
            }
            return false;
        }
        if (eq(u8, iface, "org.a11y.atspi.Application")) {
            if (target != .app) return false;
            if (eq(u8, name, "ToolkitName")) return out.s("facet");
            if (eq(u8, name, "Version")) return out.s("0.1");
            if (eq(u8, name, "AtspiVersion")) return out.s("2.1");
            if (eq(u8, name, "Id")) return out.i(b.app_id);
            if (eq(u8, name, "InterfaceVersion")) return out.u(1);
            return false;
        }
        const o = switch (target) {
            .object => |o| o,
            .app => return false,
        };
        if (eq(u8, iface, "org.a11y.atspi.Value")) {
            const v = o.info.value orelse return false;
            if (eq(u8, name, "MinimumValue")) return out.d(v.min);
            if (eq(u8, name, "MaximumValue")) return out.d(v.max);
            if (eq(u8, name, "MinimumIncrement")) return out.d(v.step);
            if (eq(u8, name, "CurrentValue")) return out.d(v.current);
            if (eq(u8, name, "Text")) return out.s(v.text);
            return false;
        }
        if (eq(u8, iface, "org.a11y.atspi.Text")) {
            const tx = o.info.text orelse return false;
            if (eq(u8, name, "CharacterCount")) return out.i(@intCast(std.unicode.utf8CountCodepoints(tx) catch tx.len));
            if (eq(u8, name, "CaretOffset")) return out.i(if (o.info.caret) |c| @intCast(c) else -1);
            return false;
        }
        if (eq(u8, iface, "org.a11y.atspi.Action")) {
            if (eq(u8, name, "NActions")) return out.i(@intFromBool(o.info.activate != null));
            return false;
        }
        return false;
    }

    fn component(b: *Bridge, o: *const Object, member: []const u8, r: *Reader, w: *Writer, acted: *bool) !?[]const u8 {
        const eq = std.mem.eql;
        const box = o.bounds;
        const x: i32 = @intFromFloat(@round(box.x));
        const y: i32 = @intFromFloat(@round(box.y));
        const bw: i32 = @intFromFloat(@round(box.w));
        const bh: i32 = @intFromFloat(@round(box.h));
        // Window coordinates for all (where the window is on the screen is
        // not known on Wayland).
        if (eq(u8, member, "GetExtents")) {
            _ = try r.uint32();
            w.beginStruct();
            w.int32(x);
            w.int32(y);
            w.int32(bw);
            w.int32(bh);
            return "(iiii)";
        }
        if (eq(u8, member, "GetPosition")) {
            _ = try r.uint32();
            w.int32(x);
            w.int32(y);
            return "ii";
        }
        if (eq(u8, member, "GetSize")) {
            w.int32(bw);
            w.int32(bh);
            return "ii";
        }
        if (eq(u8, member, "Contains")) {
            const px = try r.int32();
            const py = try r.int32();
            w.boolean(px >= x and py >= y and px < x + bw and py < y + bh);
            return "b";
        }
        if (eq(u8, member, "GetAccessibleAtPoint")) {
            const px = try r.int32();
            const py = try r.int32();
            const t = b.tree.?;
            if (t.at(.{ @floatFromInt(px), @floatFromInt(py) })) |i| b.reference(w, t.objects[i].id) else nullReference(w);
            return "(so)";
        }
        if (eq(u8, member, "GetLayer")) {
            // A window's, or a widget's.
            w.uint32(if (o.id == a11y.window_id) 7 else 3);
            return "u";
        }
        if (eq(u8, member, "GetMDIZOrder")) {
            w.int16(0);
            return "n";
        }
        if (eq(u8, member, "GetAlpha")) {
            w.double(1);
            return "d";
        }
        if (eq(u8, member, "GrabFocus")) {
            // The first widget in it that takes the focus has it.
            const focus = @import("focus.zig");
            const target = if (o.node) |n| focus.first(n) else null;
            if (target) |f| {
                focus.show(f.ui, f);
                acted.* = true;
            }
            w.boolean(target != null);
            return "b";
        }
        if (eq(u8, member, "ScrollTo") or eq(u8, member, "ScrollToPoint") or eq(u8, member, "SetExtents") or eq(u8, member, "SetPosition") or eq(u8, member, "SetSize")) {
            w.boolean(false);
            return "b";
        }
        return null;
    }

    fn action(o: *const Object, member: []const u8, r: *Reader, w: *Writer, acted: *bool) !?[]const u8 {
        const eq = std.mem.eql;
        const has = o.info.activate != null;
        if (eq(u8, member, "GetActions")) {
            const arr = w.beginArray(8);
            if (has) {
                w.beginStruct();
                w.string(o.info.action);
                w.string("");
                w.string("");
            }
            w.endArray(arr);
            return "a(sss)";
        }
        if (eq(u8, member, "GetName") or eq(u8, member, "GetLocalizedName")) {
            const i = try r.int32();
            w.string(if (has and i == 0) o.info.action else "");
            return "s";
        }
        if (eq(u8, member, "GetDescription") or eq(u8, member, "GetKeyBinding")) {
            _ = try r.int32();
            w.string("");
            return "s";
        }
        if (eq(u8, member, "DoAction")) {
            const i = try r.int32();
            const ok = has and i == 0;
            if (ok) {
                o.info.activate.?.call();
                acted.* = true;
            }
            w.boolean(ok);
            return "b";
        }
        return null;
    }

    fn text(o: *const Object, member: []const u8, r: *Reader, w: *Writer) !?[]const u8 {
        const eq = std.mem.eql;
        const tx = o.info.text orelse return null;
        const count: i32 = @intCast(std.unicode.utf8CountCodepoints(tx) catch tx.len);
        if (eq(u8, member, "GetText")) {
            const start = try r.int32();
            const end = try r.int32();
            w.string(slice(tx, start, if (end < 0) count else end));
            return "s";
        }
        if (eq(u8, member, "GetCharacterAtOffset")) {
            const at = try r.int32();
            const s = slice(tx, at, at + 1);
            w.int32(if (s.len > 0) @intCast(std.unicode.utf8Decode(s) catch 0) else 0);
            return "i";
        }
        if (eq(u8, member, "GetStringAtOffset") or eq(u8, member, "GetTextAtOffset") or eq(u8, member, "GetTextBeforeOffset") or eq(u8, member, "GetTextAfterOffset")) {
            const at = try r.int32();
            const unit = try r.uint32();
            // Characters (granularity 0, or boundary 0) as they are;
            // words and the rest: the word, or all of it.
            var start: i32 = 0;
            var end: i32 = count;
            if (unit == 0 and eq(u8, member, "GetStringAtOffset")) {
                start = at;
                end = at + 1;
            } else if (unit == 1 or (unit == 2 and !eq(u8, member, "GetStringAtOffset"))) {
                const bounds = wordAt(tx, at);
                start = bounds[0];
                end = bounds[1];
            }
            w.string(slice(tx, start, end));
            w.int32(start);
            w.int32(end);
            return "sii";
        }
        if (eq(u8, member, "GetNSelections")) {
            w.int32(0);
            return "i";
        }
        if (eq(u8, member, "GetSelection")) {
            _ = try r.int32();
            w.int32(0);
            w.int32(0);
            return "ii";
        }
        if (eq(u8, member, "GetCaretOffset")) {
            w.int32(if (o.info.caret) |c| @intCast(c) else -1);
            return "i";
        }
        if (eq(u8, member, "GetCharacterExtents") or eq(u8, member, "GetRangeExtents")) {
            // The whole of it (where each character is is not kept).
            const box = o.bounds;
            w.int32(@intFromFloat(@round(box.x)));
            w.int32(@intFromFloat(@round(box.y)));
            w.int32(@intFromFloat(@round(box.w)));
            w.int32(@intFromFloat(@round(box.h)));
            return "iiii";
        }
        if (eq(u8, member, "GetOffsetAtPoint")) {
            w.int32(-1);
            return "i";
        }
        if (eq(u8, member, "GetAttributes") or eq(u8, member, "GetAttributeRun")) {
            const at = try r.int32();
            const arr = w.beginArray(8);
            w.endArray(arr);
            w.int32(@max(at, 0));
            w.int32(count);
            return "a{ss}ii";
        }
        if (eq(u8, member, "GetDefaultAttributes") or eq(u8, member, "GetDefaultAttributeSet")) {
            const arr = w.beginArray(8);
            w.endArray(arr);
            return "a{ss}";
        }
        return null;
    }
};

/// Characters `start` to `end` of `s` (UTF-8), clamped to it.
fn slice(s: []const u8, start: i32, end: i32) []const u8 {
    var i: usize = 0;
    var ci: i32 = 0;
    var from: usize = s.len;
    var to: usize = s.len;
    while (i <= s.len) {
        if (ci == @max(start, 0) and from == s.len) from = i;
        if (ci == end) {
            to = i;
            break;
        }
        if (i == s.len) break;
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        ci += 1;
    }
    if (from > to) return "";
    return s[from..to];
}

/// The word at character `at` of `s` (its start and end, in characters).
fn wordAt(s: []const u8, at: i32) [2]i32 {
    var ci: i32 = 0;
    var i: usize = 0;
    var in_word = false;
    var word_start: i32 = 0;
    while (i < s.len) : (ci += 1) {
        const space = s[i] == ' ' or s[i] == '\n' or s[i] == '\t';
        if (!space and !in_word) {
            word_start = ci;
            in_word = true;
        }
        if (space and in_word) {
            in_word = false;
            if (at < ci) return .{ word_start, ci };
        }
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    return .{ if (in_word) word_start else ci, ci };
}

/// The object path of object `id`.
fn pathOf(id: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, object_prefix ++ "{d}", .{id}) catch unreachable;
}

/// The accessibility bus's address, as the session bus's `org.a11y.Bus`
/// says.
fn busAddress(gpa: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const session = environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse return error.ConnectFailed;
    const conn = try dbus.Connection.open(gpa, session);
    defer conn.close();
    const reply = try conn.callWait("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", "", "", 3000);
    defer gpa.free(reply);
    const m = try dbus.decode(reply);
    var r = m.reader();
    return gpa.dupe(u8, try r.string());
}

const introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.a11y.atspi.Accessible"/>
    \\  <interface name="org.a11y.atspi.Component"/>
    \\  <interface name="org.a11y.atspi.Action"/>
    \\  <interface name="org.a11y.atspi.Value"/>
    \\  <interface name="org.a11y.atspi.Text"/>
    \\</node>
;

const testing = std.testing;

test "text is cut by characters, and words found" {
    try testing.expectEqualStrings("é", slice("héllo", 1, 2));
    try testing.expectEqualStrings("llo", slice("héllo", 2, 99));
    try testing.expectEqualStrings("", slice("héllo", 4, 2));
    try testing.expectEqual([2]i32{ 6, 11 }, wordAt("hello world again", 7));
    try testing.expectEqual([2]i32{ 0, 5 }, wordAt("hello world", 2));
}

/// A peer of the bridge in tests: the other end of its connection.
const TestPeer = struct {
    fd: linux.fd_t,
    serial: u32 = 100,
    buf: std.ArrayList(u8) = .empty,

    fn call(p: *TestPeer, path: []const u8, interface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !void {
        p.serial += 1;
        const bytes = try dbus.encode(testing.allocator, .{ .type = .method_call, .serial = p.serial, .path = path, .interface = interface, .member = member, .sender = ":1.99", .signature = sig }, body);
        defer testing.allocator.free(bytes);
        _ = linux.write(p.fd, bytes.ptr, bytes.len);
    }

    /// The next message the bridge sent (its bytes, to free).
    fn next(p: *TestPeer) ![]u8 {
        while (true) {
            if (try dbus.messageLength(p.buf.items)) |len| if (p.buf.items.len >= len) {
                const m = try testing.allocator.dupe(u8, p.buf.items[0..len]);
                std.mem.copyForwards(u8, p.buf.items, p.buf.items[len..]);
                p.buf.shrinkRetainingCapacity(p.buf.items.len - len);
                return m;
            };
            var tmp: [4096]u8 = undefined;
            const rc = linux.read(p.fd, &tmp, tmp.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return error.Closed;
            try p.buf.appendSlice(testing.allocator, tmp[0..rc]);
        }
    }
};

test "the bridge answers AT-SPI's calls from the tree, and says what changed" {
    const gpa = testing.allocator;
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)));
    _ = linux.fcntl(fds[0], linux.F.SETFL, linux.SOCK.NONBLOCK);
    const conn = try gpa.create(dbus.Connection);
    conn.* = .{ .gpa = gpa, .fd = fds[0], .unique_name = try gpa.dupe(u8, ":1.5") };
    const b = try gpa.create(Bridge);
    b.* = .{ .gpa = gpa, .conn = conn, .app_name = try gpa.dupe(u8, "App"), .parent_bus = try gpa.dupe(u8, ":1.0"), .parent_path = try gpa.dupe(u8, root_path) };
    defer b.close();
    var peer: TestPeer = .{ .fd = fds[1] };
    defer {
        peer.buf.deinit(gpa);
        _ = linux.close(fds[1]);
    }

    var pressed: u32 = 0;
    var level: f64 = 0;
    const Acts = struct {
        fn press(c: *u32) void {
            c.* += 1;
        }
        fn set(l: *f64, v: f64) void {
            l.* = v;
        }
    };
    // A window with a button, a check box and a slider.
    const makeTree = struct {
        fn f(checked: bool, pressed_ptr: *u32, level_ptr: *f64) !*Tree {
            const t = try testing.allocator.create(Tree);
            t.* = .{ .arena = .init(testing.allocator) };
            const a = t.arena.allocator();
            const kids = try a.dupe(u32, &.{ 1, 2, 3 });
            t.objects = try a.dupe(Object, &.{
                .{ .id = 1, .info = .{ .role = .frame, .name = "Window" }, .bounds = .{ .x = 0, .y = 0, .w = 300, .h = 200 }, .parent = null, .children = kids, .node = null },
                .{ .id = 7, .info = .{ .role = .push_button, .name = "OK", .activate = .of(pressed_ptr, Acts.press) }, .bounds = .{ .x = 10, .y = 10, .w = 80, .h = 40 }, .parent = 0, .children = &.{}, .node = null },
                .{ .id = 8, .info = .{ .role = .check_box, .name = "Wi-Fi", .states = .{ .checkable = true, .checked = checked } }, .bounds = .{ .x = 10, .y = 60, .w = 80, .h = 40 }, .parent = 0, .children = &.{}, .node = null },
                .{ .id = 9, .info = .{ .role = .slider, .value = .{ .current = 2, .max = 10 }, .set_value = .of(level_ptr, Acts.set) }, .bounds = .{ .x = 10, .y = 110, .w = 200, .h = 40 }, .parent = 0, .children = &.{}, .node = null },
            });
            for (t.objects, 0..) |o, i| try t.by_id.put(a, o.id, @intCast(i));
            return t;
        }
    }.f;
    const first = try makeTree(false, &pressed, &level);
    defer {
        first.deinit();
        gpa.destroy(first);
    }
    b.update(null, first);
    // The window said active.
    for (0..2) |_| gpa.free(try peer.next());

    const Reply = struct {
        bytes: []u8,
        fn msg(r: @This()) dbus.Message {
            return dbus.decode(r.bytes) catch unreachable;
        }
    };
    const ask = struct {
        fn f(p: *TestPeer, br: *Bridge, path: []const u8, interface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !Reply {
            try p.call(path, interface, member, sig, body);
            _ = br.dispatch();
            return .{ .bytes = try p.next() };
        }
    }.f;
    var w: Writer = .{ .gpa = gpa };
    defer w.deinit();

    // The app's child is the window; the window's are the three.
    {
        const r = try ask(&peer, b, root_path, "org.a11y.atspi.Accessible", "GetChildren", "", "");
        defer gpa.free(r.bytes);
        var rd = r.msg().reader();
        const end = try rd.array(8);
        try rd.beginStruct();
        try testing.expectEqualStrings(":1.5", try rd.string());
        try testing.expectEqualStrings(object_prefix ++ "1", try rd.string());
        try testing.expectEqual(end, rd.at);
    }
    {
        const r = try ask(&peer, b, object_prefix ++ "1", "org.a11y.atspi.Accessible", "GetChildren", "", "");
        defer gpa.free(r.bytes);
        var rd = r.msg().reader();
        const end = try rd.array(8);
        var n: usize = 0;
        while (rd.at < end) : (n += 1) {
            try rd.beginStruct();
            _ = try rd.string();
            _ = try rd.string();
        }
        try testing.expectEqual(@as(usize, 3), n);
    }
    // Roles, names and states.
    {
        const r = try ask(&peer, b, object_prefix ++ "7", "org.a11y.atspi.Accessible", "GetRole", "", "");
        defer gpa.free(r.bytes);
        var rd = r.msg().reader();
        try testing.expectEqual(@as(u32, 43), try rd.uint32());
    }
    {
        w.buf.clearRetainingCapacity();
        w.string("org.a11y.atspi.Accessible");
        w.string("Name");
        const r = try ask(&peer, b, object_prefix ++ "8", "org.freedesktop.DBus.Properties", "Get", "ss", w.buf.items);
        defer gpa.free(r.bytes);
        var rd = r.msg().reader();
        try testing.expectEqualStrings("s", try rd.signature());
        try testing.expectEqualStrings("Wi-Fi", try rd.string());
    }
    {
        const r = try ask(&peer, b, object_prefix ++ "8", "org.a11y.atspi.Accessible", "GetState", "", "");
        defer gpa.free(r.bytes);
        var rd = r.msg().reader();
        _ = try rd.array(4);
        const lo = try rd.uint32();
        // Not checked, but checkable (41: the second word's 9th bit).
        try testing.expect(lo & (1 << 4) == 0);
        try testing.expect(try rd.uint32() & (1 << 9) != 0);
    }
    // Pressing the button, and setting the slider's value.
    {
        w.buf.clearRetainingCapacity();
        w.int32(0);
        const r = try ask(&peer, b, object_prefix ++ "7", "org.a11y.atspi.Action", "DoAction", "i", w.buf.items);
        defer gpa.free(r.bytes);
        var rd = r.msg().reader();
        try testing.expect(try rd.boolean());
        try testing.expectEqual(@as(u32, 1), pressed);
    }
    {
        w.buf.clearRetainingCapacity();
        w.string("org.a11y.atspi.Value");
        w.string("CurrentValue");
        w.variant("d");
        w.double(6.5);
        const r = try ask(&peer, b, object_prefix ++ "9", "org.freedesktop.DBus.Properties", "Set", "ssv", w.buf.items);
        gpa.free(r.bytes);
        try testing.expectEqual(@as(f64, 6.5), level);
    }
    // What is at a point, and something that is not there.
    {
        w.buf.clearRetainingCapacity();
        w.int32(20);
        w.int32(70);
        w.uint32(1);
        const r = try ask(&peer, b, object_prefix ++ "1", "org.a11y.atspi.Component", "GetAccessibleAtPoint", "iiu", w.buf.items);
        defer gpa.free(r.bytes);
        var rd = r.msg().reader();
        try rd.beginStruct();
        _ = try rd.string();
        try testing.expectEqualStrings(object_prefix ++ "8", try rd.string());
    }
    {
        const r = try ask(&peer, b, object_prefix ++ "99", "org.a11y.atspi.Accessible", "GetRole", "", "");
        defer gpa.free(r.bytes);
        try testing.expectEqual(dbus.MessageType.@"error", r.msg().header.type);
    }
    // Checked in the next frame: said.
    const second = try makeTree(true, &pressed, &level);
    defer {
        second.deinit();
        gpa.destroy(second);
    }
    b.update(first, second);
    const sig = try peer.next();
    defer gpa.free(sig);
    const m = try dbus.decode(sig);
    try testing.expectEqual(dbus.MessageType.signal, m.header.type);
    try testing.expectEqualStrings("StateChanged", m.header.member.?);
    try testing.expectEqualStrings(object_prefix ++ "8", m.header.path.?);
    var rd = m.reader();
    try testing.expectEqualStrings("checked", try rd.string());
    try testing.expectEqual(@as(i32, 1), try rd.int32());
}
