const std = @import("std");
const sync = @import("../sync.zig");
const fifo = @import("fifo.zig");
const c = @import("serial.zig");

var keyboard_buffer = fifo.RingBuffer(u8, 256).init();
var kb_lock = sync.SpinLock{};

var shift_held: bool = false;
var caps_lock: bool = false;

const LSHIFT_PRESS = 0x2A;
const RSHIFT_PRESS = 0x36;
const LSHIFT_RELEASE = 0xAA;
const RSHIFT_RELEASE = 0xB6;
const CAPS_LOCK = 0x3A;

pub fn push(key: u8) void {
    kb_lock.aquireSafe();
    defer kb_lock.releaseSafe();
    _ = keyboard_buffer.push(key);
}

pub fn pop() ?u8 {
    kb_lock.aquireSafe();
    const item = keyboard_buffer.pop();
    defer kb_lock.releaseSafe();
    if (item != null) c.Serial.writeChar(item.?);
    return item;
}

pub const normal_layout = [128]u8{
    0,    27,  '1', '2', '3', '4', '5', '6', '7', '8', '9',  '0', '-', '=',  0x08,
    '\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p',  '[', ']', '\n', 0,
    'a',  's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0,   '\\', 'z',
    'x',  'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0,   '*',  0,   ' ', 0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,   0,   0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,   0,   0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,   0,   0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,   0,   0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,
};

pub const shifted_layout = [128]u8{
    0,    27,  '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+',  0x08,
    '\t', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0,
    'A',  'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0,   '|',  'Z',
    'X',  'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0,   '*', 0,   ' ', 0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
    0,    0,   0,   0,   0,   0,   0,   0,
};

pub fn handleScancode(scancode: u8) void {
    switch (scancode) {
        LSHIFT_PRESS, RSHIFT_PRESS => {
            shift_held = true;
            return;
        },
        LSHIFT_RELEASE, RSHIFT_RELEASE => {
            shift_held = false;
            return;
        },
        CAPS_LOCK => {
            caps_lock = !caps_lock;
            return;
        },
        else => {},
    }

    // Ignore key releases (bit 7 set)
    if (scancode & 0x80 != 0) return;

    const ascii = scancodeToAscii(scancode);
    if (ascii != 0) push(ascii);
}

pub fn scancodeToAscii(scancode: u8) u8 {
    if (scancode >= 128) return 0;

    const base = normal_layout[scancode];

    // Non-alpha: shift toggles symbols
    // Alpha: caps_lock XOR shift toggles case
    const is_alpha = (base >= 'a' and base <= 'z');

    const use_shift = if (is_alpha)
        shift_held != caps_lock // XOR: either shift or caps, not both
    else
        shift_held;

    return if (use_shift) shifted_layout[scancode] else base;
}
