//! Composing: dead keys and the Compose key. A dead key (an accent: AltGr+#
//! on a UK keyboard is a dead grave), or Compose then some keys, combine
//! with the key or keys after into one character: dead acute then e is é;
//! Compose, ', e is é too. The sequences are those of the user's Compose
//! file, found as libxkbcommon finds it (`load`), or of a small built-in
//! table of the common dead keys if none can be read.
//!
//! A sequence that goes nowhere types nothing, as with xkbcommon.

const std = @import("std");
const sys = @import("sys.zig");
const xkb = @import("xkb.zig");

pub const multi_key: u32 = 0xff20;

/// Whether a keysym starts composing: a dead key or Compose.
pub fn starts(sym: u32) bool {
    return sym == multi_key or (sym >= 0xfe50 and sym <= 0xfe8f);
}

/// What composing makes.
pub const Result = struct {
    /// UTF-8.
    text: []const u8,
};

/// The sequences, as a tree: each node a keysym after its parent's.
pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const Node,

    const Node = struct {
        keysym: u32,
        /// The first node after it, and the next node after its parent
        /// (indexes; 0 for none, as the root is node 0).
        first: u32 = 0,
        next: u32 = 0,
        result: ?Result = null,
    };

    /// The user's sequences, from their Compose file or the locale's (see
    /// `Env`); null if none can be read.
    pub fn load(gpa: std.mem.Allocator, env: Env) ?Table {
        var b: Builder = .init(gpa, env);
        const user_files = [_]?[]const u8{
            env.xcomposefile,
            if (env.xdg_config_home) |d| b.join(&.{ d, "/XCompose" }) else if (env.home) |h| b.join(&.{ h, "/.config/XCompose" }) else null,
            if (env.home) |h| b.join(&.{ h, "/.XCompose" }) else null,
        };
        const found = for (user_files) |f| {
            if (f) |path| if (b.file(path, 0)) break true;
        } else if (b.localeFile()) |path| b.file(path, 0) else false;
        if (found) if (b.finish()) |t| return t else |_| {};
        b.arena.deinit();
        return null;
    }

    /// The common dead keys' sequences.
    pub fn builtin(gpa: std.mem.Allocator) !Table {
        var b: Builder = .init(gpa, .{});
        errdefer b.arena.deinit();
        b.text(@embedFile("builtin.compose"), 0);
        return b.finish();
    }

    /// The sequences in `text` (a Compose file's), for tests.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8, env: Env) !Table {
        var b: Builder = .init(gpa, env);
        errdefer b.arena.deinit();
        b.text(text, 0);
        return b.finish();
    }

    pub fn deinit(t: *Table) void {
        t.arena.deinit();
    }

    fn child(t: *const Table, node: u32, sym: u32) ?u32 {
        var i = t.nodes[node].first;
        while (i != 0) : (i = t.nodes[i].next) if (t.nodes[i].keysym == sym) return i;
        return null;
    }
};

/// Where to look for Compose files: from the environment.
pub const Env = struct {
    xcomposefile: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    /// LC_ALL, LC_CTYPE or LANG, the first that is set.
    locale: ?[]const u8 = null,
    /// Where the locales' Compose files are (XLOCALEDIR).
    localedir: []const u8 = "/usr/share/X11/locale",

    pub fn from(environ: std.process.Environ) Env {
        const get = struct {
            fn f(e: std.process.Environ, name: []const u8) ?[]const u8 {
                const v = std.process.Environ.getPosix(e, name) orelse return null;
                return if (v.len > 0) v else null;
            }
        }.f;
        return .{
            .xcomposefile = get(environ, "XCOMPOSEFILE"),
            .xdg_config_home = get(environ, "XDG_CONFIG_HOME"),
            .home = get(environ, "HOME"),
            .locale = get(environ, "LC_ALL") orelse get(environ, "LC_CTYPE") orelse get(environ, "LANG"),
            .localedir = get(environ, "XLOCALEDIR") orelse "/usr/share/X11/locale",
        };
    }
};

/// Where composing is: in a sequence (after its first keys), or not.
pub const State = struct {
    node: u32 = 0,

    pub const Step = union(enum) {
        /// Not composing: the key types as it would.
        none,
        /// In a sequence: the key types nothing yet.
        composing,
        /// The sequence is done.
        composed: Result,
        /// The key does not go on with the sequence: it is over, and types
        /// nothing.
        cancelled,
    };

    /// A key giving `sym` went down.
    pub fn feed(s: *State, table: *const Table, sym: u32) Step {
        // Modifiers do not take part (Shift for a capital, say).
        if (isModifier(sym)) return if (s.node == 0) .none else .composing;
        const next = table.child(s.node, sym) orelse {
            if (s.node == 0) return .none;
            s.node = 0;
            return .cancelled;
        };
        const n = table.nodes[next];
        if (n.first == 0) {
            s.node = 0;
            return if (n.result) |r| .{ .composed = r } else .cancelled;
        }
        s.node = next;
        return .composing;
    }

    pub fn composing(s: State) bool {
        return s.node != 0;
    }

    pub fn reset(s: *State) void {
        s.node = 0;
    }

    fn isModifier(sym: u32) bool {
        return (sym >= 0xffe1 and sym <= 0xffee) or (sym >= 0xfe01 and sym <= 0xfe0f) or sym == 0xff7e or sym == 0xff7f;
    }
};

const Builder = struct {
    arena: std.heap.ArenaAllocator,
    env: Env,
    nodes: std.ArrayList(Table.Node) = .empty,

    fn init(gpa: std.mem.Allocator, env: Env) Builder {
        return .{ .arena = .init(gpa), .env = env };
    }

    fn a(b: *Builder) std.mem.Allocator {
        return b.arena.allocator();
    }

    fn finish(b: *Builder) !Table {
        if (b.nodes.items.len == 0) try b.nodes.append(b.a(), .{ .keysym = 0 });
        return .{ .arena = b.arena, .nodes = b.nodes.items };
    }

    fn join(b: *Builder, parts: []const []const u8) ?[]const u8 {
        return std.mem.concat(b.a(), u8, parts) catch null;
    }

    /// Reads a Compose file's sequences; false if it cannot be read.
    fn file(b: *Builder, path: []const u8, depth: usize) bool {
        const data = readFile(b.a(), path) orelse return false;
        b.text(data, depth);
        return true;
    }

    fn text(b: *Builder, data: []const u8, depth: usize) void {
        if (b.nodes.items.len == 0) b.nodes.append(b.a(), .{ .keysym = 0 }) catch return;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| b.parseLine(l, depth) catch {};
    }

    /// `include "%L"`, or `<dead_acute> <e> : "é" eacute`.
    fn parseLine(b: *Builder, l: []const u8, depth: usize) !void {
        var rest = std.mem.trim(u8, l, " \t\r");
        if (rest.len == 0 or rest[0] == '#') return;
        if (std.mem.startsWith(u8, rest, "include")) {
            if (depth >= 4) return;
            const s = quoted(b.a(), rest["include".len..]) orelse return;
            const path = b.expand(s.text) orelse return;
            _ = b.file(path, depth + 1);
            return;
        }
        var seq: [8]u32 = undefined;
        var len: usize = 0;
        while (true) {
            rest = std.mem.trimStart(u8, rest, " \t");
            if (rest.len == 0 or rest[0] != '<') break;
            const end = std.mem.indexOfScalar(u8, rest, '>') orelse return;
            const sym = xkb.keysymNamed(rest[1..end]);
            if (sym == 0 or len == seq.len) return;
            seq[len] = sym;
            len += 1;
            rest = rest[end + 1 ..];
        }
        // Lines with modifiers (`!Ctrl <a>`) or that are not sequences.
        if (len == 0 or rest.len == 0 or rest[0] != ':') return;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
        var result: []const u8 = "";
        if (quoted(b.a(), rest)) |s| {
            result = s.text;
            rest = std.mem.trimStart(u8, rest[s.len..], " \t");
        }
        if (result.len == 0) {
            // Only a keysym: what it types.
            const name_end = std.mem.indexOfAny(u8, rest, " \t#") orelse rest.len;
            const c = xkb.keysymChar(xkb.keysymNamed(rest[0..name_end])) orelse return;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &buf) catch return;
            result = try b.a().dupe(u8, buf[0..n]);
        }
        try b.add(seq[0..len], result);
    }

    /// Adds a sequence. A later one replaces an earlier one; one that goes
    /// on past another's end replaces it, and one that ends where others go
    /// on is ignored (as xkbcommon does).
    fn add(b: *Builder, seq: []const u32, result: []const u8) !void {
        var node: u32 = 0;
        for (seq, 0..) |sym, i| {
            var found: ?u32 = null;
            var c = b.nodes.items[node].first;
            while (c != 0) : (c = b.nodes.items[c].next) if (b.nodes.items[c].keysym == sym) {
                found = c;
                break;
            };
            const next = found orelse blk: {
                const idx: u32 = @intCast(b.nodes.items.len);
                try b.nodes.append(b.a(), .{ .keysym = sym, .next = b.nodes.items[node].first });
                b.nodes.items[node].first = idx;
                break :blk idx;
            };
            node = next;
            if (i + 1 < seq.len) b.nodes.items[node].result = null;
        }
        if (b.nodes.items[node].first != 0) return;
        b.nodes.items[node].result = .{ .text = result };
    }

    /// An include's path: `%H` home, `%L` the locale's Compose file, `%S`
    /// the locales' directory, `%%` a `%`.
    fn expand(b: *Builder, path: []const u8) ?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] != '%' or i + 1 == path.len) {
                out.append(b.a(), path[i]) catch return null;
                continue;
            }
            i += 1;
            const part = switch (path[i]) {
                'H' => b.env.home orelse return null,
                'L' => b.localeFile() orelse return null,
                'S' => b.env.localedir,
                '%' => "%",
                else => return null,
            };
            out.appendSlice(b.a(), part) catch return null;
        }
        return out.items;
    }

    /// The locale's Compose file: its name (or what locale.alias says it
    /// is short for) looked up in compose.dir.
    fn localeFile(b: *Builder) ?[]const u8 {
        const dir = b.env.localedir;
        var name = b.env.locale orelse "C";
        if (b.join(&.{ dir, "/locale.alias" })) |alias_path| if (readFile(b.a(), alias_path)) |aliases| {
            if (lookup(aliases, name, .second)) |n| name = n;
        };
        const compose_dir = readFile(b.a(), b.join(&.{ dir, "/compose.dir" }) orelse return null) orelse return null;
        const rel = lookup(compose_dir, name, .first) orelse return null;
        return b.join(&.{ dir, "/", rel });
    }

    /// In a file of lines of two words (the first maybe ending in `:`),
    /// the other word of the first line with `key` as the `.first` or
    /// `.second`... that is, the word paired with it.
    fn lookup(data: []const u8, key: []const u8, want: enum { first, second }) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            if (l.len == 0 or l[0] == '#') continue;
            var words = std.mem.tokenizeAny(u8, l, " \t\r");
            const w1 = std.mem.trimEnd(u8, words.next() orelse continue, ":");
            const w2 = words.next() orelse continue;
            switch (want) {
                // compose.dir: "file locale".
                .first => if (std.mem.eql(u8, w2, key)) return w1,
                // locale.alias: "alias locale".
                .second => if (std.mem.eql(u8, w1, key)) return w2,
            }
        }
        return null;
    }
};

/// A `"..."` string at the start of `s` (after spaces), with its escapes
/// (`\"`, `\\`, `\n`, octal `\123` and hex `\x41`) undone, and how much of
/// `s` it took.
fn quoted(a: std.mem.Allocator, s: []const u8) ?struct { text: []const u8, len: usize } {
    const start = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    if (std.mem.trim(u8, s[0..start], " \t").len != 0) return null;
    var out: std.ArrayList(u8) = .empty;
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') return .{ .text = out.items, .len = i + 1 };
        if (c != '\\' or i + 1 == s.len) {
            out.append(a, c) catch return null;
            continue;
        }
        i += 1;
        const e = s[i];
        switch (e) {
            'n' => out.append(a, '\n') catch return null,
            't' => out.append(a, '\t') catch return null,
            'x', 'X' => {
                var v: u8 = 0;
                var n: usize = 0;
                while (n < 2 and i + 1 < s.len and std.ascii.isHex(s[i + 1])) : (n += 1) {
                    i += 1;
                    v = v * 16 + (std.fmt.charToDigit(s[i], 16) catch 0);
                }
                out.append(a, v) catch return null;
            },
            '0'...'7' => {
                var v: u16 = e - '0';
                var n: usize = 1;
                while (n < 3 and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '7') : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                out.append(a, @truncate(v)) catch return null;
            },
            else => out.append(a, e) catch return null,
        }
    }
    return null;
}

fn readFile(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    return sys.readFile(a, path, 8 << 20);
}

const testing = std.testing;

fn ks(comptime name: []const u8) u32 {
    return xkb.keysymNamed(name);
}

test "a sequence composes, one that goes nowhere types nothing, and modifiers take no part" {
    var t = try Table.parse(testing.allocator,
        \\# A comment.
        \\<dead_acute> <e>        : "é" eacute # LATIN SMALL LETTER E WITH ACUTE
        \\<dead_acute> <space>    : "'"
        \\<Multi_key> <apostrophe> <e> : "é"
        \\<Multi_key> <C> <C> <C> <P> : "☭"
        \\<Multi_key> <o> <c>     : copyright
        \\<Multi_key> <q> <q>     : "\"q\x41\101"
        \\<Multi_key> <exclam> <exclam> : "¡"
        \\!Ctrl <a> : "ignored"
    , .{});
    defer t.deinit();
    var s: State = .{};
    try testing.expectEqual(State.Step.none, s.feed(&t, ks("a")));
    try testing.expectEqual(State.Step.composing, s.feed(&t, ks("dead_acute")));
    try testing.expectEqualStrings("é", s.feed(&t, ks("e")).composed.text);
    try testing.expect(!s.composing());
    try testing.expectEqualStrings("'", (blk: {
        _ = s.feed(&t, ks("dead_acute"));
        break :blk s.feed(&t, ks("space"));
    }).composed.text);
    // Compose and three keys, Shift held for the capitals.
    try testing.expectEqual(State.Step.composing, s.feed(&t, multi_key));
    for ([_]u32{ ks("Shift_L"), ks("C"), ks("C"), ks("C") }) |k| try testing.expectEqual(State.Step.composing, s.feed(&t, k));
    try testing.expectEqualStrings("☭", s.feed(&t, ks("P")).composed.text);
    // A keysym for a result, and escapes.
    _ = s.feed(&t, multi_key);
    _ = s.feed(&t, ks("o"));
    try testing.expectEqualStrings("©", s.feed(&t, ks("c")).composed.text);
    _ = s.feed(&t, multi_key);
    _ = s.feed(&t, ks("q"));
    try testing.expectEqualStrings("\"qAA", s.feed(&t, ks("q")).composed.text);
    // Going nowhere: cancelled, and the next key types as usual.
    _ = s.feed(&t, multi_key);
    try testing.expectEqual(State.Step.cancelled, s.feed(&t, ks("z")));
    try testing.expectEqual(State.Step.none, s.feed(&t, ks("z")));
    // Lines with modifiers are not sequences.
    try testing.expectEqual(State.Step.none, s.feed(&t, ks("a")));
}

test "later sequences replace earlier ones, and longer ones shorter" {
    var t = try Table.parse(testing.allocator,
        \\<Multi_key> <a> : "1"
        \\<Multi_key> <a> : "2"
        \\<Multi_key> <b> : "3"
        \\<Multi_key> <b> <b> : "4"
        \\<Multi_key> <c> <c> : "5"
        \\<Multi_key> <c> : "6"
    , .{});
    defer t.deinit();
    var s: State = .{};
    _ = s.feed(&t, multi_key);
    try testing.expectEqualStrings("2", s.feed(&t, ks("a")).composed.text);
    _ = s.feed(&t, multi_key);
    try testing.expectEqual(State.Step.composing, s.feed(&t, ks("b")));
    try testing.expectEqualStrings("4", s.feed(&t, ks("b")).composed.text);
    _ = s.feed(&t, multi_key);
    try testing.expectEqual(State.Step.composing, s.feed(&t, ks("c")));
    try testing.expectEqualStrings("5", s.feed(&t, ks("c")).composed.text);
}

test "the built-in table has the common dead keys" {
    var t = try Table.builtin(testing.allocator);
    defer t.deinit();
    var s: State = .{};
    const pairs = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "dead_acute", "e", "é" },
        .{ "dead_grave", "A", "À" },
        .{ "dead_circumflex", "o", "ô" },
        .{ "dead_diaeresis", "u", "ü" },
        .{ "dead_tilde", "n", "ñ" },
        .{ "dead_cedilla", "c", "ç" },
        .{ "dead_caron", "s", "š" },
        .{ "dead_abovering", "a", "å" },
        .{ "dead_grave", "space", "`" },
        .{ "dead_acute", "dead_acute", "´" },
    };
    for (pairs) |p| {
        try testing.expectEqual(State.Step.composing, s.feed(&t, xkb.keysymNamed(p[0])));
        try testing.expectEqualStrings(p[2], s.feed(&t, xkb.keysymNamed(p[1])).composed.text);
    }
}

test "the Compose file is found as xkbcommon finds it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = dir_buf[0..try tmp.dir.realPathFile(std.testing.io, ".", &dir_buf)];
    const write = struct {
        fn f(d: std.Io.Dir, name: []const u8, data: []const u8) !void {
            const file = try d.createFile(std.testing.io, name, .{});
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, data);
        }
    }.f;
    try tmp.dir.createDirPath(std.testing.io, "locale/en_US.UTF-8");
    try write(tmp.dir, "locale/locale.alias", "en_US.utf8:\t\ten_US.UTF-8\n");
    try write(tmp.dir, "locale/compose.dir", "# comment\niso8859-1/Compose\t\tC\nen_US.UTF-8/Compose:\t\ten_US.UTF-8\n");
    try write(tmp.dir, "locale/en_US.UTF-8/Compose", "<dead_acute> <e> : \"é\"\n");
    try write(tmp.dir, "XCompose", "include \"%L\"\n<Multi_key> <h> <i> : \"hi\"\n");
    const localedir = try std.fmt.allocPrint(testing.allocator, "{s}/locale", .{root});
    defer testing.allocator.free(localedir);
    const user = try std.fmt.allocPrint(testing.allocator, "{s}/XCompose", .{root});
    defer testing.allocator.free(user);

    // The locale's file, by its alias.
    var t = Table.load(testing.allocator, .{ .locale = "en_US.utf8", .localedir = localedir }).?;
    var s: State = .{};
    _ = s.feed(&t, ks("dead_acute"));
    try testing.expectEqualStrings("é", s.feed(&t, ks("e")).composed.text);
    t.deinit();
    // The user's, which includes the locale's.
    t = Table.load(testing.allocator, .{ .xcomposefile = user, .locale = "en_US.UTF-8", .localedir = localedir }).?;
    _ = s.feed(&t, multi_key);
    _ = s.feed(&t, ks("h"));
    try testing.expectEqualStrings("hi", s.feed(&t, ks("i")).composed.text);
    _ = s.feed(&t, ks("dead_acute"));
    try testing.expectEqualStrings("é", s.feed(&t, ks("e")).composed.text);
    t.deinit();
    // A locale with no Compose file, and no user file: none.
    try testing.expect(Table.load(testing.allocator, .{ .locale = "xx_XX.UTF-8", .localedir = localedir }) == null);
}
