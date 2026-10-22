//! Linux's key codes (input-event-codes.h), which Wayland's keyboard events
//! and xkb keymaps use, and the `KeyboardKey`s they are. The macOS and
//! Windows backends say what they have in these too, before the keys
//! reach the app as `KeyboardKey`s.

const std = @import("std");
const window = @import("window.zig");

const KeyboardKey = window.KeyboardKey;

const table = [_]struct { u32, KeyboardKey }{
    .{ 1, .escape },
    .{ 2, .digit_1 },
    .{ 3, .digit_2 },
    .{ 4, .digit_3 },
    .{ 5, .digit_4 },
    .{ 6, .digit_5 },
    .{ 7, .digit_6 },
    .{ 8, .digit_7 },
    .{ 9, .digit_8 },
    .{ 10, .digit_9 },
    .{ 11, .digit_0 },
    .{ 12, .minus },
    .{ 13, .equal },
    .{ 14, .backspace },
    .{ 15, .tab },
    .{ 16, .q },
    .{ 17, .w },
    .{ 18, .e },
    .{ 19, .r },
    .{ 20, .t },
    .{ 21, .y },
    .{ 22, .u },
    .{ 23, .i },
    .{ 24, .o },
    .{ 25, .p },
    .{ 26, .left_bracket },
    .{ 27, .right_bracket },
    .{ 28, .enter },
    .{ 29, .left_ctrl },
    .{ 30, .a },
    .{ 31, .s },
    .{ 32, .d },
    .{ 33, .f },
    .{ 34, .g },
    .{ 35, .h },
    .{ 36, .j },
    .{ 37, .k },
    .{ 38, .l },
    .{ 39, .semicolon },
    .{ 40, .apostrophe },
    .{ 41, .grave },
    .{ 42, .left_shift },
    .{ 43, .backslash },
    .{ 44, .z },
    .{ 45, .x },
    .{ 46, .c },
    .{ 47, .v },
    .{ 48, .b },
    .{ 49, .n },
    .{ 50, .m },
    .{ 51, .comma },
    .{ 52, .period },
    .{ 53, .slash },
    .{ 54, .right_shift },
    .{ 55, .keypad_multiply },
    .{ 56, .left_alt },
    .{ 57, .space },
    .{ 58, .caps_lock },
    .{ 59, .f1 },
    .{ 60, .f2 },
    .{ 61, .f3 },
    .{ 62, .f4 },
    .{ 63, .f5 },
    .{ 64, .f6 },
    .{ 65, .f7 },
    .{ 66, .f8 },
    .{ 67, .f9 },
    .{ 68, .f10 },
    .{ 69, .num_lock },
    .{ 70, .scroll_lock },
    .{ 71, .keypad_7 },
    .{ 72, .keypad_8 },
    .{ 73, .keypad_9 },
    .{ 74, .keypad_minus },
    .{ 75, .keypad_4 },
    .{ 76, .keypad_5 },
    .{ 77, .keypad_6 },
    .{ 78, .keypad_plus },
    .{ 79, .keypad_1 },
    .{ 80, .keypad_2 },
    .{ 81, .keypad_3 },
    .{ 82, .keypad_0 },
    .{ 83, .keypad_decimal },
    .{ 86, .intl_backslash },
    .{ 87, .f11 },
    .{ 88, .f12 },
    .{ 96, .keypad_enter },
    .{ 97, .right_ctrl },
    .{ 98, .keypad_divide },
    .{ 99, .print_screen },
    .{ 100, .right_alt },
    .{ 102, .home },
    .{ 103, .up },
    .{ 104, .page_up },
    .{ 105, .left },
    .{ 106, .right },
    .{ 107, .end },
    .{ 108, .down },
    .{ 109, .page_down },
    .{ 110, .insert },
    .{ 111, .delete },
    .{ 117, .keypad_equal },
    .{ 119, .pause },
    .{ 125, .left_super },
    .{ 126, .right_super },
    .{ 127, .menu },
    .{ 183, .f13 },
    .{ 184, .f14 },
    .{ 185, .f15 },
    .{ 186, .f16 },
    .{ 187, .f17 },
    .{ 188, .f18 },
    .{ 189, .f19 },
    .{ 190, .f20 },
    .{ 191, .f21 },
    .{ 192, .f22 },
    .{ 193, .f23 },
    .{ 194, .f24 },
};

const by_code = blk: {
    var a: [256]KeyboardKey = @splat(.other);
    for (table) |e| a[e[0]] = e[1];
    break :blk a;
};

const key_count = std.meta.fieldNames(KeyboardKey).len;

/// The Linux code of each key, 0 where it has none.
const by_key = blk: {
    var a: [key_count]u32 = @splat(0);
    for (table) |e| a[@backingInt(e[1])] = e[0];
    break :blk a;
};

/// The key a Linux key code is (`.other` if it is not one the toolkit
/// knows).
pub fn keyOf(code: u32) KeyboardKey {
    return if (code < by_code.len) by_code[code] else .other;
}

/// The Linux key code of `key`, or null for `.other`.
pub fn codeOf(key: KeyboardKey) ?u32 {
    const code = by_key[@backingInt(key)];
    return if (code == 0) null else code;
}

test "key codes and keys map both ways" {
    for (table) |e| {
        try std.testing.expectEqual(e[1], keyOf(e[0]));
        try std.testing.expectEqual(@as(?u32, e[0]), codeOf(e[1]));
    }
    try std.testing.expectEqual(KeyboardKey.other, keyOf(0));
    try std.testing.expectEqual(KeyboardKey.other, keyOf(1000));
    try std.testing.expectEqual(@as(?u32, null), codeOf(.other));
    try std.testing.expectEqual(KeyboardKey.a, keyOf(30));
    try std.testing.expectEqual(@as(?u32, 105), codeOf(.left));
}

test "no key has two codes" {
    for (table, 0..) |a, i| for (table[i + 1 ..]) |b| try std.testing.expect(a[1] != b[1] and a[0] != b[0]);
}
