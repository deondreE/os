const std = @import("std");

extern fn outb(port: u16, value: u8) void;
extern fn inb(port: u16) u8;

pub const Serial = struct {
    const COM1 = 0x3F8;

    pub fn init() void {
        outb(COM1 + 1, 0x00);
        outb(COM1 + 3, 0x80);
        outb(COM1 + 0, 0x03);
        outb(COM1 + 1, 0x00);
        outb(COM1 + 3, 0x03);
        outb(COM1 + 2, 0xC7);
        outb(COM1 + 4, 0x08);
    }

    fn isTransmitEmpty() bool {
        return (inb(COM1 + 5) & 0x20) != 0;
    }

    pub fn writeChar(c: u8) void {
        while (!isTransmitEmpty()) {
            asm volatile ("pause");
        }
        outb(COM1, c);
    }

    pub fn write(msg: []const u8) void {
        for (msg) |c| {
            writeChar(c);
        }
    }

    pub const Writer = std.io.GenericWriter(void, error{}, writeFn);

    fn writeFn(_: void, msg: []const u8) error{}!usize {
        write(msg);
        return msg.len;
    }

    pub fn writer() Writer {
        return .{ .context = {} };
    }
};
