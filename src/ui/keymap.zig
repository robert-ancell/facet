//! Linux key codes (input-event-codes.h) the toolkit handles itself. What
//! character a key types depends on the keyboard (`Ui.keyboard`).

const std = @import("std");
const window = @import("window");

pub const Keyboard = window.Keyboard;
pub const Key = window.Key;

pub const escape = 1;
pub const backspace = 14;
pub const tab = 15;
pub const enter = 28;
pub const left_ctrl = 29;
pub const right_ctrl = 97;
pub const key_a = 30;
pub const left_shift = 42;
pub const key_x = 45;
pub const key_c = 46;
pub const key_v = 47;
pub const right_shift = 54;
pub const caps_lock = 58;
pub const home = 102;
pub const up = 103;
pub const page_up = 104;
pub const down = 108;
pub const page_down = 109;
pub const left = 105;
pub const right = 106;
pub const end = 107;
pub const delete = 111;
pub const keypad_enter = 96;
pub const right_alt = 100;

test "US and UK keyboard layouts map characters and modifiers" {
    try std.testing.expectEqual(@as(?u21, 'a'), Keyboard.us.char(30, false, false, false));
    try std.testing.expectEqual(@as(?u21, 'A'), Keyboard.us.char(30, true, false, false));
    try std.testing.expectEqual(@as(?u21, 'A'), Keyboard.us.char(30, false, true, false));
    try std.testing.expectEqual(@as(?u21, 'a'), Keyboard.us.char(30, true, true, false));
    try std.testing.expectEqual(@as(?u21, '@'), Keyboard.us.char(3, true, false, false));
    try std.testing.expectEqual(@as(?u21, '"'), Keyboard.gb.char(3, true, false, false));
    try std.testing.expectEqual(@as(?u21, '£'), Keyboard.gb.char(4, true, false, false));
    try std.testing.expectEqual(@as(?u21, '€'), Keyboard.gb.char(5, false, false, true));
}
