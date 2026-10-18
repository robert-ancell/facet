//! XKB keymaps: what each key types, as the compositor describes it (the
//! text keymap format xkbcommon and xkbcomp write, sent with
//! `wl_keyboard.keymap`), and the modifiers' state.
//!
//! A keymap has, for each key, one or more groups (layouts: US and Russian,
//! say), each with a type and a keysym for each of its levels. The type says
//! which modifiers choose which level (Shift the second, AltGr the third,
//! and so on). Modifiers are real (Shift, Lock, Control, Mod1 to Mod5) or
//! virtual (Alt, LevelThree, NumLock...), the virtual ones standing for
//! real ones: those of the keys the compatibility section's interprets
//! give them to. A keysym is turned into the character it types with the
//! table made from X11's keysymdef.h (keysyms.zig).
//!
//! Not handled: dead keys and composing (they type nothing), keys' own
//! `actions`, and changing group from the keyboard where the compositor
//! does not report it.

const std = @import("std");
const keysyms = @import("keysyms.zig");

/// Real modifiers' masks, as `State` has them.
pub const shift_mask: u32 = 1 << 0;
pub const lock_mask: u32 = 1 << 1;
pub const control_mask: u32 = 1 << 2;

const real_mods = [_][]const u8{ "Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5" };
const max_mods = 32;
const max_groups = 4;

/// The modifiers in effect, and the group (layout): from the compositor
/// (`wl_keyboard.modifiers`), or kept by `Keymap.update`.
pub const State = struct {
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
    /// Keys held that set modifiers while they are (for `Keymap.update`).
    held: [8]struct { code: u32, mask: u32 } = undefined,
    held_len: u8 = 0,

    pub fn mods(s: State) u32 {
        return s.depressed | s.latched | s.locked;
    }
};

pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    /// By XKB key code (the Linux one plus 8).
    keys: []Key,
    types: []Type,
    interprets: []Interpret,
    /// Each modifier's mask: real ones their own bit, virtual ones the real
    /// modifiers they stand for.
    masks: [max_mods]u32,
    /// The layouts' names ("English (US)") and codes ("us"), by group.
    names: [max_groups][]const u8,
    codes: [max_groups][]const u8,

    const Key = struct {
        groups: []Group = &.{},
        /// The real modifiers it is in the modifier map for.
        modmap: u32 = 0,
    };

    const Group = struct {
        type: ?u16,
        syms: []const u32,
    };

    const Type = struct {
        name: []const u8,
        mods: Mods,
        entries: []const Entry,
        mask: u32 = 0,

        const Entry = struct {
            mods: Mods,
            level: u16,
            mask: u32 = 0,
            /// Whether it can match: not if its modifiers are virtual ones
            /// that stand for none.
            active: bool = true,
        };
    };

    const Interpret = struct {
        /// null for `Any`.
        sym: ?u32,
        match: Match = .any_of_or_none,
        match_mods: u32 = 0xff,
        vmod: ?u5 = null,
        level_one_only: bool = false,
        action: Action = .none,
        action_mods: Mods = .{},
        use_modmap: bool = false,

        const Match = enum { none_of, any_of_or_none, any_of, all_of, exactly };
        const Action = enum { none, set, latch, lock };

        fn matches(i: Interpret, sym: u32, modmap: u32, level: usize) bool {
            if (i.sym) |s| if (s != sym) return false;
            const mods = if (i.level_one_only and level != 0) 0 else modmap;
            return switch (i.match) {
                .none_of => mods & i.match_mods == 0,
                .any_of_or_none => true,
                .any_of => mods & i.match_mods != 0,
                .all_of => mods & i.match_mods == i.match_mods,
                .exactly => mods == i.match_mods,
            };
        }
    };

    /// A set of modifiers by index (bit i is modifier i), or all of them.
    const Mods = struct {
        set: u32 = 0,
        all: bool = false,
    };

    /// Parses a keymap's text (which it does not keep).
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Keymap {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var p: Parser = .{ .a = arena.allocator(), .tok = .{ .text = text } };
        try p.keymap();
        var km: Keymap = .{
            .arena = undefined,
            .keys = &.{},
            .types = p.types.items,
            .interprets = &.{},
            .masks = @splat(0),
            .names = p.names,
            .codes = layoutCodes(p.a, p.symbols_name),
        };
        try km.finish(&p);
        km.arena = arena;
        return km;
    }

    pub fn deinit(km: *Keymap) void {
        km.arena.deinit();
    }

    /// The keysym a key (by Linux key code) gives in `state`; 0 for none.
    pub fn keysym(km: *const Keymap, code: u32, state: State) u32 {
        const level, _ = km.levelOf(code, state) orelse return 0;
        const g = km.groupOf(code, state).?;
        return if (level < g.syms.len) g.syms[level] else 0;
    }

    /// The character a key (by Linux key code) types in `state`, if any.
    /// Caps Lock capitalizes it where the key's type does not use Lock.
    pub fn char(km: *const Keymap, code: u32, state: State) ?u21 {
        const level, const lock_used = km.levelOf(code, state) orelse return null;
        const g = km.groupOf(code, state).?;
        if (level >= g.syms.len) return null;
        const c = keysymChar(g.syms[level]) orelse return null;
        return if (state.mods() & lock_mask != 0 and !lock_used) upper(c) else c;
    }

    /// The layout `state` is in: its name and code.
    pub fn layoutName(km: *const Keymap, state: State) []const u8 {
        const g = @min(state.group, max_groups - 1);
        return if (km.names[g].len > 0) km.names[g] else km.codes[g];
    }

    pub fn layoutCode(km: *const Keymap, state: State) []const u8 {
        return km.codes[@min(state.group, max_groups - 1)];
    }

    /// Keeps `state` as a key (by Linux key code) goes down or up, as the
    /// keymap says it changes the modifiers (for when nothing reports
    /// them: the compositor does, where there is one).
    pub fn update(km: *const Keymap, state: *State, code: u32, pressed: bool) void {
        if (!pressed) {
            var i: usize = 0;
            while (i < state.held_len) {
                if (state.held[i].code == code) {
                    state.held[i] = state.held[state.held_len - 1];
                    state.held_len -= 1;
                } else i += 1;
            }
            state.depressed = 0;
            for (state.held[0..state.held_len]) |h| state.depressed |= h.mask;
            return;
        }
        const key = km.keyOf(code) orelse return;
        const g = km.groupOf(code, state.*) orelse return;
        if (g.syms.len == 0) return;
        const interp = km.interpretFor(g.syms[0], key.modmap, 0) orelse return;
        const mask = if (interp.use_modmap) key.modmap else km.maskOf(interp.action_mods);
        switch (interp.action) {
            .none => {},
            .set, .latch => if (state.held_len < state.held.len) {
                state.held[state.held_len] = .{ .code = code, .mask = mask };
                state.held_len += 1;
                state.depressed |= mask;
            },
            .lock => state.locked ^= mask,
        }
    }

    fn keyOf(km: *const Keymap, code: u32) ?*const Key {
        const xkb = code + 8;
        if (xkb >= km.keys.len) return null;
        return &km.keys[xkb];
    }

    fn groupOf(km: *const Keymap, code: u32, state: State) ?*const Group {
        const key = km.keyOf(code) orelse return null;
        if (key.groups.len == 0) return null;
        return &key.groups[state.group % key.groups.len];
    }

    /// The level a key is at in `state`, and whether its type uses Lock.
    fn levelOf(km: *const Keymap, code: u32, state: State) ?struct { usize, bool } {
        const g = km.groupOf(code, state) orelse return null;
        const t = &km.types[g.type orelse return .{ 0, false }];
        const mods = state.mods() & t.mask;
        for (t.entries) |e| if (e.active and e.mask == mods) return .{ e.level, t.mask & lock_mask != 0 };
        return .{ 0, t.mask & lock_mask != 0 };
    }

    fn maskOf(km: *const Keymap, mods: Mods) u32 {
        if (mods.all) return 0xffffffff;
        var mask: u32 = 0;
        var set = mods.set;
        while (set != 0) : (set &= set - 1) mask |= km.masks[@ctz(set)];
        return mask;
    }

    fn interpretFor(km: *const Keymap, sym: u32, modmap: u32, level: usize) ?*const Interpret {
        for (km.interprets) |*i| if (i.matches(sym, modmap, level)) return i;
        return null;
    }

    /// After parsing: keys' groups and types, the interprets in the order
    /// they apply, and what virtual modifiers stand for.
    fn finish(km: *Keymap, p: *Parser) !void {
        const a = p.a;
        // Specific keysyms' interprets before `Any`'s.
        const interps = try a.alloc(Interpret, p.interprets.items.len);
        var n: usize = 0;
        for (p.interprets.items) |i| if (i.sym != null) {
            interps[n] = i;
            n += 1;
        };
        for (p.interprets.items) |i| if (i.sym == null) {
            interps[n] = i;
            n += 1;
        };
        km.interprets = interps;

        var max_code: usize = 0;
        for (p.drafts.items) |d| max_code = @max(max_code, d.code);
        km.keys = try a.alloc(Key, max_code + 1);
        @memset(km.keys, .{});
        for (p.drafts.items) |d| {
            var count: usize = 0;
            for (d.groups, 0..) |g, i| if (g.syms != null) {
                count = i + 1;
            };
            const groups = try a.alloc(Group, count);
            for (groups, d.groups[0..count]) |*g, dg| {
                const syms = dg.syms orelse &.{};
                const type_name = dg.type orelse d.all_type orelse automaticType(syms);
                g.* = .{ .syms = syms, .type = p.typeIndex(type_name) };
            }
            km.keys[d.code].groups = groups;
        }
        for (p.modmap.items) |m| switch (m.target) {
            .code => |c| if (c < km.keys.len) {
                km.keys[c].modmap |= m.mask;
            },
            .sym => |sym| for (km.keys) |*k| {
                if (k.groups.len > 0 and std.mem.indexOfScalar(u32, k.groups[0].syms, sym) != null) {
                    k.modmap |= m.mask;
                    break;
                }
            },
        };

        // What virtual modifiers stand for: the modifier map of the keys
        // whose keysyms' interprets give them to them (unless the keymap
        // says).
        for (0..p.mod_count) |i| km.masks[i] = if (i < real_mods.len) @as(u32, 1) << @intCast(i) else 0;
        for (p.explicit_masks, 0..) |e, i| if (e) |mask| {
            km.masks[i] = mask;
        };
        for (km.keys, 0..) |*k, code| {
            var vmods: u32 = 0;
            for (p.drafts.items) |d| if (d.code == code and d.vmods != null) {
                vmods = d.vmods.?.set;
            };
            if (vmods == 0) for (k.groups) |g| for (g.syms, 0..) |sym, level| {
                if (km.interpretFor(sym, k.modmap, level)) |i| if (i.vmod) |v| {
                    vmods |= @as(u32, 1) << v;
                };
            };
            var set = vmods;
            while (set != 0) : (set &= set - 1) {
                const v = @ctz(set);
                if (v >= real_mods.len and p.explicit_masks[v] == null) km.masks[v] |= k.modmap;
            }
        }
        for (km.types) |*t| {
            t.mask = km.maskOf(t.mods);
            const entries = try a.dupe(Type.Entry, t.entries);
            for (entries) |*e| {
                e.mask = km.maskOf(e.mods);
                e.active = e.mods.set == 0 or e.mask != 0;
            }
            t.entries = entries;
        }
    }
};

/// The type XKB gives a key's group that names none, from its keysyms.
fn automaticType(syms: []const u32) []const u8 {
    const isLower = struct {
        fn f(sym: u32) bool {
            const c = keysymChar(sym) orelse return false;
            return upper(c) != c;
        }
    }.f;
    const isUpper = struct {
        fn f(sym: u32) bool {
            const c = keysymChar(sym) orelse return false;
            return lower(c) != c;
        }
    }.f;
    const isKeypad = struct {
        fn f(sym: u32) bool {
            return sym >= 0xff80 and sym <= 0xffbd;
        }
    }.f;
    const at = struct {
        fn f(s: []const u32, i: usize) u32 {
            return if (i < s.len) s[i] else 0;
        }
    }.f;
    if (syms.len <= 1) return "ONE_LEVEL";
    if (syms.len == 2) {
        if (isLower(syms[0]) and isUpper(syms[1])) return "ALPHABETIC";
        if (isKeypad(syms[0]) or isKeypad(syms[1])) return "KEYPAD";
        return "TWO_LEVEL";
    }
    if (isLower(syms[0]) and isUpper(syms[1])) {
        return if (isLower(at(syms, 2)) and isUpper(at(syms, 3))) "FOUR_LEVEL_ALPHABETIC" else "FOUR_LEVEL_SEMIALPHABETIC";
    }
    if (isKeypad(syms[0]) or isKeypad(syms[1])) return "FOUR_LEVEL_KEYPAD";
    return "FOUR_LEVEL";
}

/// The character a keysym types, if any (not control characters).
pub fn keysymChar(sym: u32) ?u21 {
    const c: u32 = switch (sym) {
        0x20...0x7e, 0xa0...0xff => sym,
        // The keypad: space, operators, the decimal point and digits.
        0xff80 => ' ',
        0xffaa...0xffb9 => sym & 0x7f,
        0xffbd => '=',
        0x01000100...0x0110ffff => sym - 0x01000000,
        else => blk: {
            var lo: usize = 0;
            var hi: usize = keysyms.chars.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (keysyms.chars[mid][0] < sym) lo = mid + 1 else hi = mid;
            }
            if (lo < keysyms.chars.len and keysyms.chars[lo][0] == sym) break :blk keysyms.chars[lo][1];
            return null;
        },
    };
    if (c < 0x20 or (c >= 0x7f and c < 0xa0) or (c >= 0xd800 and c < 0xe000) or c > 0x10ffff) return null;
    return @intCast(c);
}

/// A keysym by name ("sterling", "Cyrillic_ef", "U20AC", "0x20ac"); 0 if
/// unknown.
pub fn keysymNamed(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "NoSymbol")) return 0;
    if (std.mem.startsWith(u8, name, "0x") or std.mem.startsWith(u8, name, "0X")) return std.fmt.parseInt(u32, name[2..], 16) catch 0;
    var lo: usize = 0;
    var hi: usize = keysyms.names.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (std.mem.order(u8, keysyms.names[mid][0], name) == .lt) lo = mid + 1 else hi = mid;
    }
    if (lo < keysyms.names.len and std.mem.eql(u8, keysyms.names[lo][0], name)) return keysyms.names[lo][1];
    if (name.len > 1 and name[0] == 'U') if (std.fmt.parseInt(u32, name[1..], 16)) |c| {
        return if (c >= 0x20 and c < 0x100) c else 0x01000000 + c;
    } else |_| {};
    return std.fmt.parseInt(u32, name, 10) catch 0;
}

/// Simple case mapping for the alphabets keyboards type most: Latin
/// (Basic, Latin-1 and Extended-A), Greek, Cyrillic and Armenian.
pub fn upper(c: u21) u21 {
    return switch (c) {
        'a'...'z' => c - 32,
        0xe0...0xf6, 0xf8...0xfe => c - 32,
        0xff => 0x178,
        0x100...0x137, 0x14a...0x177 => if (c & 1 == 1) c - 1 else c,
        0x139...0x148, 0x179...0x17e => if (c & 1 == 0) c - 1 else c,
        0x3b1...0x3c1, 0x3c3...0x3cb => c - 32,
        0x3c2 => 0x3a3,
        0x3ac => 0x386,
        0x3ad...0x3af => c - 37,
        0x3cc => 0x38c,
        0x3cd...0x3ce => c - 63,
        0x430...0x44f => c - 32,
        0x450...0x45f => c - 80,
        0x461...0x481, 0x48b...0x4bf, 0x4d1...0x52f => if (c & 1 == 1) c - 1 else c,
        0x561...0x586 => c - 48,
        else => c,
    };
}

pub fn lower(c: u21) u21 {
    return switch (c) {
        'A'...'Z' => c + 32,
        0xc0...0xd6, 0xd8...0xde => c + 32,
        0x178 => 0xff,
        0x100...0x137, 0x14a...0x177 => if (c & 1 == 0) c + 1 else c,
        0x139...0x148, 0x179...0x17e => if (c & 1 == 1) c + 1 else c,
        0x391...0x3a1, 0x3a3...0x3ab => c + 32,
        0x386 => 0x3ac,
        0x388...0x38a => c + 37,
        0x38c => 0x3cc,
        0x38e...0x38f => c + 63,
        0x410...0x42f => c + 32,
        0x400...0x40f => c + 80,
        0x460...0x480, 0x48a...0x4be, 0x4d0...0x52e => if (c & 1 == 0) c + 1 else c,
        0x531...0x556 => c + 48,
        else => c,
    };
}

/// The layouts' codes, by group, from the symbols section's name: as
/// xkbcomp writes it ("pc+gb+ru:2+inet(evdev)") or newer xkbcommon does
/// ("pc_us_ru_2_inet(evdev)").
fn layoutCodes(a: std.mem.Allocator, name: []const u8) [max_groups][]const u8 {
    var codes: [max_groups][]const u8 = @splat("");
    var parts: [16][]const u8 = undefined;
    var count: usize = 0;
    var depth: usize = 0;
    var start: usize = 0;
    for (name, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        '+', '_' => if (depth == 0 and count < parts.len) {
            parts[count] = name[start..i];
            count += 1;
            start = i + 1;
        },
        else => {},
    };
    if (count < parts.len and start < name.len) {
        parts[count] = name[start..];
        count += 1;
    }
    var next: usize = 0;
    for (parts[0..count], 0..) |part, i| {
        if (i == 0 and std.mem.eql(u8, part, "pc")) continue;
        // The options come after the layouts.
        if (std.mem.startsWith(u8, part, "inet") or std.mem.startsWith(u8, part, "group")) break;
        if (part.len == 0) continue;
        // "_2" after a layout (newer xkbcommon) says its group.
        if (std.fmt.parseInt(usize, part, 10)) |g| {
            if (next > 0 and g >= 1 and g <= max_groups and g - 1 != next - 1) {
                codes[g - 1] = codes[next - 1];
                codes[next - 1] = "";
                next = g;
            }
            continue;
        } else |_| {}
        var code = part;
        var group = next;
        if (std.mem.indexOfScalar(u8, part, ':')) |colon| {
            code = part[0..colon];
            group = (std.fmt.parseInt(usize, part[colon + 1 ..], 10) catch next + 1) -| 1;
        }
        if (group < max_groups) codes[group] = a.dupe(u8, code) catch "";
        next = group + 1;
    }
    return codes;
}

const Tokenizer = struct {
    text: []const u8,
    i: usize = 0,

    const Kind = enum { ident, string, key_name, punct, eof };
    const Token = struct { kind: Kind, text: []const u8 };

    fn next(t: *Tokenizer) Token {
        while (t.i < t.text.len) {
            const c = t.text[t.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                t.i += 1;
            } else if (c == '/' and t.i + 1 < t.text.len and t.text[t.i + 1] == '/' or c == '#') {
                t.i = std.mem.indexOfScalarPos(u8, t.text, t.i, '\n') orelse t.text.len;
            } else if (c == '/' and t.i + 1 < t.text.len and t.text[t.i + 1] == '*') {
                t.i = if (std.mem.indexOfPos(u8, t.text, t.i + 2, "*/")) |e| e + 2 else t.text.len;
            } else break;
        }
        if (t.i >= t.text.len) return .{ .kind = .eof, .text = "" };
        const start = t.i;
        const c = t.text[t.i];
        if (c == '"' or c == '<') {
            const close: u8 = if (c == '"') '"' else '>';
            const end = std.mem.indexOfScalarPos(u8, t.text, t.i + 1, close) orelse t.text.len;
            t.i = @min(end + 1, t.text.len);
            return .{ .kind = if (c == '"') .string else .key_name, .text = t.text[start + 1 .. end] };
        }
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            while (t.i < t.text.len and (std.ascii.isAlphanumeric(t.text[t.i]) or t.text[t.i] == '_')) t.i += 1;
            return .{ .kind = .ident, .text = t.text[start..t.i] };
        }
        t.i += 1;
        return .{ .kind = .punct, .text = t.text[start..t.i] };
    }
};

const Parser = struct {
    a: std.mem.Allocator,
    tok: Tokenizer,
    peeked: ?Tokenizer.Token = null,

    codes: std.StringHashMapUnmanaged(u32) = .empty,
    mod_names: [max_mods][]const u8 = real_mods ++ @as([max_mods - real_mods.len][]const u8, @splat("")),
    mod_count: usize = real_mods.len,
    explicit_masks: [max_mods]?u32 = @splat(null),
    types: std.ArrayList(Keymap.Type) = .empty,
    interprets: std.ArrayList(Keymap.Interpret) = .empty,
    use_modmap_level_one: bool = false,
    drafts: std.ArrayList(Draft) = .empty,
    modmap: std.ArrayList(ModMap) = .empty,
    names: [max_groups][]const u8 = @splat(""),
    symbols_name: []const u8 = "",

    const Draft = struct {
        code: u32,
        all_type: ?[]const u8 = null,
        groups: [max_groups]struct { type: ?[]const u8 = null, syms: ?[]const u32 = null } = @splat(.{}),
        vmods: ?Keymap.Mods = null,
    };

    const ModMap = struct {
        mask: u32,
        target: union(enum) { code: u32, sym: u32 },
    };

    const Error = error{ OutOfMemory, BadKeymap };

    fn peek(p: *Parser) Tokenizer.Token {
        if (p.peeked == null) p.peeked = p.tok.next();
        return p.peeked.?;
    }

    fn take(p: *Parser) Tokenizer.Token {
        const t = p.peek();
        p.peeked = null;
        return t;
    }

    fn isPunct(t: Tokenizer.Token, c: u8) bool {
        return t.kind == .punct and t.text[0] == c;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (!isPunct(p.peek(), c)) return false;
        _ = p.take();
        return true;
    }

    fn expect(p: *Parser, c: u8) Error!void {
        if (!p.eat(c)) return error.BadKeymap;
    }

    /// Skips to the end of the statement: past its `;`, or up to the `}`
    /// closing the block it is in.
    fn skipStatement(p: *Parser) void {
        var depth: usize = 0;
        while (true) {
            const t = p.peek();
            if (t.kind == .eof) return;
            if (t.kind == .punct) switch (t.text[0]) {
                '{', '[', '(' => depth += 1,
                '}', ']', ')' => {
                    if (depth == 0) return;
                    depth -= 1;
                },
                ';' => if (depth == 0) {
                    _ = p.take();
                    return;
                },
                else => {},
            };
            _ = p.take();
        }
    }

    fn keymap(p: *Parser) Error!void {
        const t = p.take();
        if (t.kind != .ident or !std.mem.eql(u8, t.text, "xkb_keymap")) return error.BadKeymap;
        if (p.peek().kind == .string) _ = p.take();
        try p.expect('{');
        while (true) {
            const s = p.take();
            if (isPunct(s, '}') or s.kind == .eof) break;
            if (s.kind != .ident) continue;
            const name = if (p.peek().kind == .string) p.take().text else "";
            if (!p.eat('{')) {
                p.skipStatement();
                continue;
            }
            if (std.mem.eql(u8, s.text, "xkb_keycodes")) {
                try p.block(keycodeStatement);
            } else if (std.mem.eql(u8, s.text, "xkb_types")) {
                try p.block(typesStatement);
            } else if (std.mem.startsWith(u8, s.text, "xkb_compat")) {
                try p.block(compatStatement);
            } else if (std.mem.eql(u8, s.text, "xkb_symbols")) {
                p.symbols_name = name;
                try p.block(symbolsStatement);
            } else {
                p.skipBlock();
            }
            _ = p.eat(';');
        }
    }

    /// Statements up to the block's `}`.
    fn block(p: *Parser, comptime statement: fn (*Parser) Error!void) Error!void {
        while (true) {
            const t = p.peek();
            if (t.kind == .eof) return;
            if (isPunct(t, '}')) {
                _ = p.take();
                return;
            }
            if (isPunct(t, ';')) {
                _ = p.take();
                continue;
            }
            try statement(p);
        }
    }

    fn skipBlock(p: *Parser) void {
        var depth: usize = 1;
        while (depth > 0) {
            const t = p.take();
            if (t.kind == .eof) return;
            if (isPunct(t, '{')) depth += 1;
            if (isPunct(t, '}')) depth -= 1;
        }
    }

    fn number(text: []const u8) ?u32 {
        if (std.mem.startsWith(u8, text, "0x")) return std.fmt.parseInt(u32, text[2..], 16) catch null;
        return std.fmt.parseInt(u32, text, 10) catch null;
    }

    fn keycodeStatement(p: *Parser) Error!void {
        const t = p.take();
        if (t.kind == .key_name and p.eat('=')) {
            const v = p.take();
            if (number(v.text)) |code| try p.codes.put(p.a, t.text, code);
        } else if (t.kind == .ident and std.mem.eql(u8, t.text, "alias")) {
            const from = p.take();
            if (p.eat('=')) {
                const to = p.take();
                if (p.codes.get(to.text)) |code| try p.codes.put(p.a, from.text, code);
            }
        }
        p.skipStatement();
    }

    fn virtualModifiers(p: *Parser) Error!void {
        while (true) {
            const n = p.take();
            if (n.kind != .ident) break;
            const i = p.modIndex(n.text) orelse blk: {
                if (p.mod_count == max_mods) break :blk null;
                p.mod_names[p.mod_count] = n.text;
                p.mod_count += 1;
                break :blk p.mod_count - 1;
            };
            if (p.eat('=')) {
                const v = p.take();
                if (i) |idx| p.explicit_masks[idx] = number(v.text) orelse (if (p.modIndex(v.text)) |m| @as(u32, 1) << @intCast(m) else null);
            }
            if (!p.eat(',')) break;
        }
        p.skipStatement();
    }

    fn modIndex(p: *const Parser, name: []const u8) ?usize {
        for (p.mod_names[0..p.mod_count], 0..) |m, i| if (std.ascii.eqlIgnoreCase(m, name)) return i;
        return null;
    }

    /// `Shift+Lock`, `none`, `all`.
    fn mods(p: *Parser) Keymap.Mods {
        var out: Keymap.Mods = .{};
        while (true) {
            const t = p.peek();
            if (t.kind != .ident) break;
            _ = p.take();
            if (std.ascii.eqlIgnoreCase(t.text, "all")) {
                out.all = true;
            } else if (p.modIndex(t.text)) |i| {
                out.set |= @as(u32, 1) << @intCast(i);
            }
            if (!p.eat('+')) break;
        }
        return out;
    }

    /// A level: `2` or `Level2`.
    fn level(text: []const u8) ?u16 {
        const digits = if (std.ascii.startsWithIgnoreCase(text, "level")) text[5..] else text;
        const n = std.fmt.parseInt(u16, digits, 10) catch return null;
        return if (n >= 1) n - 1 else null;
    }

    /// A group: `2` or `Group2`.
    fn groupIndex(text: []const u8) ?usize {
        const digits = if (std.ascii.startsWithIgnoreCase(text, "group")) text[5..] else text;
        const n = std.fmt.parseInt(usize, digits, 10) catch return null;
        return if (n >= 1 and n <= max_groups) n - 1 else null;
    }

    fn typesStatement(p: *Parser) Error!void {
        const t = p.take();
        if (t.kind != .ident) return p.skipStatement();
        if (std.mem.eql(u8, t.text, "virtual_modifiers")) return p.virtualModifiers();
        if (!std.mem.eql(u8, t.text, "type") or p.peek().kind != .string) return p.skipStatement();
        const name = p.take().text;
        try p.expect('{');
        var ty: Keymap.Type = .{ .name = name, .mods = .{}, .entries = &.{} };
        var entries: std.ArrayList(Keymap.Type.Entry) = .empty;
        while (true) {
            const s = p.peek();
            if (s.kind == .eof) break;
            if (isPunct(s, '}')) {
                _ = p.take();
                break;
            }
            _ = p.take();
            if (s.kind != .ident) continue;
            if (std.ascii.eqlIgnoreCase(s.text, "modifiers") and p.eat('=')) {
                ty.mods = p.mods();
            } else if (std.ascii.eqlIgnoreCase(s.text, "map") and p.eat('[')) {
                const m = p.mods();
                if (p.eat(']') and p.eat('=')) if (level(p.take().text)) |l| {
                    try entries.append(p.a, .{ .mods = m, .level = l });
                };
            }
            p.skipStatement();
        }
        ty.entries = entries.items;
        try p.types.append(p.a, ty);
        p.skipStatement();
    }

    fn compatStatement(p: *Parser) Error!void {
        const t = p.take();
        if (t.kind != .ident) return p.skipStatement();
        if (std.mem.eql(u8, t.text, "virtual_modifiers")) return p.virtualModifiers();
        if (!std.mem.eql(u8, t.text, "interpret")) return p.skipStatement();
        // Defaults: `interpret.useModMapMods= level1;`
        if (p.eat('.')) {
            const field = p.take();
            if (std.ascii.eqlIgnoreCase(field.text, "useModMapMods") and p.eat('=')) {
                p.use_modmap_level_one = std.ascii.startsWithIgnoreCase(p.take().text, "level");
            }
            return p.skipStatement();
        }
        const sym = p.take();
        var i: Keymap.Interpret = .{
            .sym = if (std.ascii.eqlIgnoreCase(sym.text, "Any")) null else keysymNamed(sym.text),
            .level_one_only = p.use_modmap_level_one,
        };
        if (p.eat('+')) {
            const cond = p.take().text;
            i.match = if (std.ascii.eqlIgnoreCase(cond, "NoneOf"))
                .none_of
            else if (std.ascii.eqlIgnoreCase(cond, "AnyOf"))
                .any_of
            else if (std.ascii.eqlIgnoreCase(cond, "AllOf"))
                .all_of
            else if (std.ascii.eqlIgnoreCase(cond, "Exactly"))
                .exactly
            else
                .any_of_or_none;
            if (p.eat('(')) {
                const m = p.mods();
                i.match_mods = if (m.all) 0xff else m.set & 0xff;
                _ = p.eat(')');
            }
        }
        if (p.eat('{')) while (true) {
            const s = p.peek();
            if (s.kind == .eof) break;
            if (isPunct(s, '}')) {
                _ = p.take();
                break;
            }
            _ = p.take();
            if (s.kind != .ident) continue;
            if (std.ascii.eqlIgnoreCase(s.text, "virtualModifier") and p.eat('=')) {
                if (p.modIndex(p.take().text)) |v| i.vmod = @intCast(v);
            } else if (std.ascii.eqlIgnoreCase(s.text, "useModMapMods") and p.eat('=')) {
                i.level_one_only = std.ascii.startsWithIgnoreCase(p.take().text, "level");
            } else if (std.ascii.eqlIgnoreCase(s.text, "action") and p.eat('=')) {
                const action = p.take().text;
                i.action = if (std.ascii.eqlIgnoreCase(action, "SetMods"))
                    .set
                else if (std.ascii.eqlIgnoreCase(action, "LatchMods"))
                    .latch
                else if (std.ascii.eqlIgnoreCase(action, "LockMods"))
                    .lock
                else
                    .none;
                if (i.action != .none and p.eat('(')) while (true) {
                    const arg = p.take();
                    if (arg.kind == .eof or isPunct(arg, ')')) break;
                    if (arg.kind == .ident and (std.ascii.eqlIgnoreCase(arg.text, "modifiers") or std.ascii.eqlIgnoreCase(arg.text, "mods")) and p.eat('=')) {
                        if (std.ascii.eqlIgnoreCase(p.peek().text, "modMapMods")) {
                            _ = p.take();
                            i.use_modmap = true;
                        } else i.action_mods = p.mods();
                    }
                };
            }
            p.skipStatement();
        };
        try p.interprets.append(p.a, i);
        p.skipStatement();
    }

    fn symbolsStatement(p: *Parser) Error!void {
        const t = p.take();
        if (t.kind != .ident) return p.skipStatement();
        if (std.mem.eql(u8, t.text, "name") and p.eat('[')) {
            const g = groupIndex(p.take().text);
            if (p.eat(']') and p.eat('=')) {
                const n = p.take();
                if (g) |idx| if (n.kind == .string) {
                    p.names[idx] = try p.a.dupe(u8, n.text);
                };
            }
            return p.skipStatement();
        }
        if (std.mem.eql(u8, t.text, "key") and p.peek().kind == .key_name) return p.keyStatement();
        if (std.mem.eql(u8, t.text, "modifier_map")) {
            const target = p.modIndex(p.take().text);
            if (p.eat('{')) while (true) {
                const item = p.take();
                if (item.kind == .eof or isPunct(item, '}')) break;
                const mask: u32 = if (target) |m| (if (m < real_mods.len) @as(u32, 1) << @intCast(m) else 0) else 0;
                if (mask == 0) continue;
                if (item.kind == .key_name) {
                    if (p.codes.get(item.text)) |code| try p.modmap.append(p.a, .{ .mask = mask, .target = .{ .code = code } });
                } else if (item.kind == .ident) {
                    try p.modmap.append(p.a, .{ .mask = mask, .target = .{ .sym = keysymNamed(item.text) } });
                }
            };
            return p.skipStatement();
        }
        p.skipStatement();
    }

    fn keyStatement(p: *Parser) Error!void {
        const name = p.take().text;
        const code = p.codes.get(name);
        var d: Draft = .{ .code = code orelse 0 };
        var bare: usize = 0;
        if (p.eat('{')) while (true) {
            const s = p.peek();
            if (s.kind == .eof) break;
            if (isPunct(s, '}')) {
                _ = p.take();
                break;
            }
            if (isPunct(s, ',')) {
                _ = p.take();
                continue;
            }
            if (isPunct(s, '[')) {
                _ = p.take();
                if (bare < max_groups) d.groups[bare].syms = try p.symList();
                bare += 1;
                continue;
            }
            _ = p.take();
            if (s.kind != .ident) continue;
            var g: ?usize = null;
            if (p.eat('[')) {
                g = groupIndex(p.take().text);
                _ = p.eat(']');
            }
            if (!p.eat('=')) continue;
            if (std.ascii.eqlIgnoreCase(s.text, "symbols") and p.eat('[')) {
                const syms = try p.symList();
                if (g) |idx| d.groups[idx].syms = syms;
            } else if (std.ascii.eqlIgnoreCase(s.text, "type")) {
                const ty = p.take();
                if (ty.kind == .string) {
                    const copy = try p.a.dupe(u8, ty.text);
                    if (g) |idx| d.groups[idx].type = copy else d.all_type = copy;
                }
            } else if (std.ascii.eqlIgnoreCase(s.text, "virtualMods") or std.ascii.eqlIgnoreCase(s.text, "vmods")) {
                d.vmods = p.mods();
            } else {
                p.skipItem();
            }
        };
        p.skipStatement();
        if (code != null) try p.drafts.append(p.a, d);
    }

    /// Keysyms up to the `]` (after its `[`).
    fn symList(p: *Parser) Error![]const u32 {
        var syms: std.ArrayList(u32) = .empty;
        while (true) {
            const t = p.take();
            if (t.kind == .eof or isPunct(t, ']')) break;
            if (isPunct(t, ',')) continue;
            if (isPunct(t, '{')) {
                // More than one keysym at a level: none we can type.
                p.skipBlock();
                try syms.append(p.a, 0);
                continue;
            }
            if (t.kind == .ident) try syms.append(p.a, keysymNamed(t.text));
        }
        return syms.items;
    }

    /// Skips a key's item: up to the `,` or `}` after it.
    fn skipItem(p: *Parser) void {
        var depth: usize = 0;
        while (true) {
            const t = p.peek();
            if (t.kind == .eof) return;
            if (t.kind == .punct) switch (t.text[0]) {
                '{', '[', '(' => depth += 1,
                '}', ']', ')' => {
                    if (depth == 0) return;
                    depth -= 1;
                },
                ',' => if (depth == 0) return,
                else => {},
            };
            _ = p.take();
        }
    }

    fn typeIndex(p: *const Parser, name: []const u8) ?u16 {
        for (p.types.items, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return @intCast(i);
        return null;
    }
};

/// Keymaps for tests: the one GNOME Shell sends for two US layouts (newer
/// xkbcommon, keysyms in hex), and xkbcomp's for UK and Russian (keysyms
/// by name).
pub const testdata = struct {
    pub const us = @embedFile("testdata/us.xkb");
    pub const gb_ru = @embedFile("testdata/gb_ru.xkb");
};

const testing = std.testing;

fn evdev(comptime name: []const u8) u32 {
    // The Linux key codes the tests use.
    const codes = .{ .{ "1", 2 }, .{ "2", 3 }, .{ "3", 4 }, .{ "4", 5 }, .{ "a", 30 }, .{ "q", 16 }, .{ "grave", 41 }, .{ "backslash", 43 }, .{ "lsgt", 86 }, .{ "lshift", 42 }, .{ "caps", 58 }, .{ "ralt", 100 }, .{ "lctrl", 29 }, .{ "kp1", 79 }, .{ "numlock", 69 }, .{ "space", 57 }, .{ "esc", 1 } };
    inline for (codes) |c| if (comptime std.mem.eql(u8, c[0], name)) return c[1];
    @compileError("no key " ++ name);
}

test "keysyms by name and the characters they type" {
    try testing.expectEqual(@as(u32, 0xa3), keysymNamed("sterling"));
    try testing.expectEqual(@as(u32, 0x6c6), keysymNamed("Cyrillic_ef"));
    try testing.expectEqual(@as(u32, 0x31), keysymNamed("1"));
    try testing.expectEqual(@as(u32, 0x20ac), keysymNamed("0x20ac"));
    try testing.expectEqual(@as(u32, 0x10020ac), keysymNamed("U20AC"));
    try testing.expectEqual(@as(u32, 0), keysymNamed("NoSymbol"));
    try testing.expectEqual(@as(?u21, '£'), keysymChar(0xa3));
    try testing.expectEqual(@as(?u21, 'ф'), keysymChar(0x6c6));
    try testing.expectEqual(@as(?u21, '€'), keysymChar(0x20ac));
    try testing.expectEqual(@as(?u21, '€'), keysymChar(0x10020ac));
    try testing.expectEqual(@as(?u21, '1'), keysymChar(0xffb1));
    // Keys that type no character: Escape, Shift, a dead key.
    try testing.expectEqual(@as(?u21, null), keysymChar(0xff1b));
    try testing.expectEqual(@as(?u21, null), keysymChar(0xffe1));
    try testing.expectEqual(@as(?u21, null), keysymChar(0xfe50));
    try testing.expectEqual(@as(u21, 'Ф'), upper('ф'));
    try testing.expectEqual(@as(u21, 'é'), lower('É'));
}

test "the layouts are named in the symbols section" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const old = layoutCodes(a.allocator(), "pc+gb+ru:2+inet(evdev)+group(alt_shift_toggle)");
    try testing.expectEqualStrings("gb", old[0]);
    try testing.expectEqualStrings("ru", old[1]);
    const new = layoutCodes(a.allocator(), "pc_us_ru_2_inet(evdev)");
    try testing.expectEqualStrings("us", new[0]);
    try testing.expectEqualStrings("ru", new[1]);
    const variant = layoutCodes(a.allocator(), "pc+fr(oss_latin9)+inet(evdev)");
    try testing.expectEqualStrings("fr(oss_latin9)", variant[0]);
}

test "a US keymap from the compositor types what a US keyboard does" {
    var km = try Keymap.parse(testing.allocator, testdata.us);
    defer km.deinit();
    const none: State = .{};
    const shifted: State = .{ .depressed = shift_mask };
    const caps: State = .{ .locked = lock_mask };
    try testing.expectEqualStrings("English (US)", km.layoutName(none));
    try testing.expectEqualStrings("us", km.layoutCode(none));
    try testing.expectEqual(@as(?u21, 'a'), km.char(evdev("a"), none));
    try testing.expectEqual(@as(?u21, 'A'), km.char(evdev("a"), shifted));
    try testing.expectEqual(@as(?u21, 'A'), km.char(evdev("a"), caps));
    try testing.expectEqual(@as(?u21, 'a'), km.char(evdev("a"), .{ .depressed = shift_mask, .locked = lock_mask }));
    try testing.expectEqual(@as(?u21, '2'), km.char(evdev("2"), caps));
    try testing.expectEqual(@as(?u21, '@'), km.char(evdev("2"), shifted));
    try testing.expectEqual(@as(?u21, '\\'), km.char(evdev("backslash"), none));
    try testing.expectEqual(@as(?u21, ' '), km.char(evdev("space"), none));
    try testing.expectEqual(@as(?u21, null), km.char(evdev("esc"), none));
    // The keypad: digits with Num Lock (Mod2), not without.
    try testing.expectEqual(@as(?u21, null), km.char(evdev("kp1"), none));
    try testing.expectEqual(@as(?u21, '1'), km.char(evdev("kp1"), .{ .locked = 1 << 4 }));
}

test "a UK and Russian keymap types each layout's characters, with AltGr" {
    var km = try Keymap.parse(testing.allocator, testdata.gb_ru);
    defer km.deinit();
    const mod5: u32 = 1 << 7;
    const uk: State = .{};
    const ru: State = .{ .group = 1 };
    try testing.expectEqualStrings("English (UK)", km.layoutName(uk));
    try testing.expectEqualStrings("gb", km.layoutCode(uk));
    try testing.expectEqualStrings("Russian", km.layoutName(ru));
    try testing.expectEqualStrings("ru", km.layoutCode(ru));
    try testing.expectEqual(@as(?u21, '"'), km.char(evdev("2"), .{ .depressed = shift_mask }));
    try testing.expectEqual(@as(?u21, '£'), km.char(evdev("3"), .{ .depressed = shift_mask }));
    // AltGr (LevelThree, which the keymap puts on Mod5).
    try testing.expectEqual(@as(?u21, '€'), km.char(evdev("4"), .{ .depressed = mod5 }));
    try testing.expectEqual(@as(?u21, '¼'), km.char(evdev("4"), .{ .depressed = mod5 | shift_mask }));
    try testing.expectEqual(@as(?u21, 'æ'), km.char(evdev("a"), .{ .depressed = mod5 }));
    try testing.expectEqual(@as(?u21, '#'), km.char(evdev("backslash"), uk));
    try testing.expectEqual(@as(?u21, '¬'), km.char(evdev("grave"), .{ .depressed = shift_mask }));
    // The second group.
    try testing.expectEqual(@as(?u21, 'ф'), km.char(evdev("a"), ru));
    try testing.expectEqual(@as(?u21, 'Ф'), km.char(evdev("a"), .{ .group = 1, .depressed = shift_mask }));
    try testing.expectEqual(@as(?u21, 'Ф'), km.char(evdev("a"), .{ .group = 1, .locked = lock_mask }));
    try testing.expectEqual(@as(?u21, 'й'), km.char(evdev("q"), ru));
    try testing.expectEqual(@as(?u21, '№'), km.char(evdev("3"), .{ .group = 1, .depressed = shift_mask }));
}

test "the keymap's actions keep the modifiers when nothing reports them" {
    for ([_][]const u8{ testdata.us, testdata.gb_ru }) |text| {
        var km = try Keymap.parse(testing.allocator, text);
        defer km.deinit();
        var s: State = .{};
        // Shift is held, and let go.
        km.update(&s, evdev("lshift"), true);
        try testing.expectEqual(shift_mask, s.mods());
        try testing.expectEqual(@as(?u21, 'A'), km.char(evdev("a"), s));
        km.update(&s, evdev("lshift"), false);
        try testing.expectEqual(@as(u32, 0), s.mods());
        // Caps Lock locks, and unlocks.
        km.update(&s, evdev("caps"), true);
        km.update(&s, evdev("caps"), false);
        try testing.expectEqual(lock_mask, s.mods());
        try testing.expectEqual(@as(?u21, 'A'), km.char(evdev("a"), s));
        km.update(&s, evdev("caps"), true);
        km.update(&s, evdev("caps"), false);
        try testing.expectEqual(@as(u32, 0), s.mods());
        // Control.
        km.update(&s, evdev("lctrl"), true);
        try testing.expectEqual(control_mask, s.mods());
        km.update(&s, evdev("lctrl"), false);
    }
    // AltGr is the UK's third level.
    var km = try Keymap.parse(testing.allocator, testdata.gb_ru);
    defer km.deinit();
    var s: State = .{};
    km.update(&s, evdev("ralt"), true);
    try testing.expectEqual(@as(?u21, '€'), km.char(evdev("4"), s));
    km.update(&s, evdev("ralt"), false);
    try testing.expectEqual(@as(?u21, '4'), km.char(evdev("4"), s));
}

test "broken keymaps are refused or read as far as they make sense" {
    try testing.expectError(error.BadKeymap, Keymap.parse(testing.allocator, "not a keymap"));
    var km = try Keymap.parse(testing.allocator, "xkb_keymap { xkb_keycodes { <AC01> = 38; }; xkb_symbols { key <AC01> { [ a, A ] }; key <NONE> { [ b ] }; }; };");
    defer km.deinit();
    // No types: every key types its first level.
    try testing.expectEqual(@as(?u21, 'a'), km.char(30, .{ .depressed = shift_mask }));
    try testing.expectEqual(@as(?u21, null), km.char(31, .{}));
    try testing.expectEqual(@as(?u21, null), km.char(5000, .{}));
}
