const std = @import("std");
const sync = @import("../sync.zig");
const fifo = @import("fifo.zig");
const c = @import("serial.zig");

var keyboard_buffer = fifo.RingBuffer(u8, 256).init();
var kb_lock = sync.SpinLock{};

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

pub const layouts = [128]u8{
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

pub fn scancodeToAscii(scancode: u8) u8 {
    if (scancode >= 128) return 0;
    return layouts[scancode];
}
