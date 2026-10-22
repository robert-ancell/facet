//! Windows keys as Linux key codes (`KEY_A`, ...), which `window.evdev`
//! makes `KeyboardKey`s of for kete's input events: from the scan code
//! Windows gives with each key message (set 1, with its extended flag),
//! which for most keys is the Linux code itself.

const std = @import("std");

pub const vk_pause = 0x13;

/// The Linux key code of the key with scan code `scan` (`extended` if its
/// message says so), whose virtual key is `vk`; 0 if it has none.
pub fn linuxKey(scan: u32, extended: bool, vk: u32) u32 {
    // Pause comes as Num Lock's scan code, without the extended flag.
    if (vk == vk_pause) return 119; // KEY_PAUSE
    if (!extended) {
        return switch (scan) {
            // Escape to F10, the main block, the keypad, F11, F12 and the
            // key left of Z: the same codes.
            0x01...0x58 => scan,
            0x64...0x6e => 183 + (scan - 0x64), // F13 to F23
            0x76 => 194, // F24
            else => 0,
        };
    }
    return switch (scan) {
        0x1c => 96, // KEY_KPENTER
        0x1d => 97, // KEY_RIGHTCTRL
        0x35 => 98, // KEY_KPSLASH
        0x37 => 99, // KEY_SYSRQ (Print Screen)
        0x38 => 100, // KEY_RIGHTALT
        0x45 => 69, // KEY_NUMLOCK
        0x47 => 102, // KEY_HOME
        0x48 => 103, // KEY_UP
        0x49 => 104, // KEY_PAGEUP
        0x4b => 105, // KEY_LEFT
        0x4d => 106, // KEY_RIGHT
        0x4f => 107, // KEY_END
        0x50 => 108, // KEY_DOWN
        0x51 => 109, // KEY_PAGEDOWN
        0x52 => 110, // KEY_INSERT
        0x53 => 111, // KEY_DELETE
        0x5b => 125, // KEY_LEFTMETA
        0x5c => 126, // KEY_RIGHTMETA
        0x5d => 127, // KEY_COMPOSE (the menu key)
        else => 0,
    };
}

/// What a key message's `lParam` says of its key: its scan code, and
/// whether it is extended.
pub fn scanOf(lparam: isize) struct { scan: u32, extended: bool } {
    const bits: usize = @bitCast(lparam);
    return .{ .scan = @intCast((bits >> 16) & 0xff), .extended = (bits >> 24) & 1 != 0 };
}

test "Windows keys become Linux key codes" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 1), linuxKey(0x01, false, 0x1b)); // Escape
    try t.expectEqual(@as(u32, 30), linuxKey(0x1e, false, 'A')); // KEY_A
    try t.expectEqual(@as(u32, 28), linuxKey(0x1c, false, 0x0d)); // KEY_ENTER
    try t.expectEqual(@as(u32, 96), linuxKey(0x1c, true, 0x0d)); // KEY_KPENTER
    try t.expectEqual(@as(u32, 29), linuxKey(0x1d, false, 0x11)); // KEY_LEFTCTRL
    try t.expectEqual(@as(u32, 97), linuxKey(0x1d, true, 0x11)); // KEY_RIGHTCTRL
    try t.expectEqual(@as(u32, 103), linuxKey(0x48, true, 0x26)); // KEY_UP
    try t.expectEqual(@as(u32, 72), linuxKey(0x48, false, 0x68)); // KEY_KP8
    try t.expectEqual(@as(u32, 111), linuxKey(0x53, true, 0x2e)); // KEY_DELETE
    try t.expectEqual(@as(u32, 87), linuxKey(0x57, false, 0x7a)); // KEY_F11
    try t.expectEqual(@as(u32, 69), linuxKey(0x45, true, 0x90)); // KEY_NUMLOCK
    try t.expectEqual(@as(u32, 119), linuxKey(0x45, false, vk_pause)); // KEY_PAUSE
    try t.expectEqual(@as(u32, 125), linuxKey(0x5b, true, 0x5b)); // KEY_LEFTMETA
    try t.expectEqual(@as(u32, 0), linuxKey(0x7f, false, 0));

    // A key message's lParam: repeat count 1, scan code 0x48, extended.
    const k = scanOf(@bitCast(@as(usize, 1 | (0x48 << 16) | (1 << 24))));
    try t.expectEqual(@as(u32, 0x48), k.scan);
    try t.expect(k.extended);
}
