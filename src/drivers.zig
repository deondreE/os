const std = @import("std");

extern fn outb(port: u16, data: u8) void;
extern fn inb(port: u16) u8;

pub const Color = enum(u8) {
    Black = 0,
    Blue = 1,
    Green = 2,
    Cyan = 3,
    Red = 4,
    Magenta = 5,
    Brown = 6,
    LightGray = 7,
    DarkGray = 8,
    LightBlue = 9,
    LightGreen = 10,
    LightCyan = 11,
    LightRed = 12,
    Pink = 13,
    Yellow = 14,
    White = 15,
};

pub const VgaTerminal = struct {
    const width = 80;
    const height = 25;
    const vga_address: [*]volatile u16 = @ptrFromInt(0xB8000);

    row: usize = 0,
    column: usize = 0,
    color: u8,

    pub fn init(fg: Color, bg: Color) VgaTerminal {
        return .{
            .color = (@as(u8, @intFromEnum(bg)) << 4 | @as(u8, @intFromEnum(fg))),
        };
    }

    pub fn clear(self: *VgaTerminal) void {
        const space = @as(u16, ' ') | @as(u16, self.color) << 8;
        for (0..height * width) |i| {
            vga_address[i] = space;
        }
        self.row = 0;
        self.column = 0;
    }

    fn updateCursor(self: *VgaTerminal) void {
        const pos = @as(u16, @intCast(self.row * width + self.column));
        outb(0x3D4, 0x0F);
        outb(0x3D5, @as(u8, @intCast(pos & 0xFF)));
        outb(0x3D4, 0x0E);
        outb(0x3D5, @as(u8, @intCast((pos >> 8) & 0xFF)));
    }

    pub fn putChar(self: *VgaTerminal, c: u8) void {
        if (c == '\n') {
            self.column = 0;
            self.row += 1;
        } else if (c == 0x08) // backspace {}
        {
            if (self.column > 0) {
                self.column -= 1;
            } else if (self.row > 0) {
                self.row -= 1;
                self.column = width - 1;
            }
            const index = self.row * width + self.column;
            vga_address[index] = @as(u16, ' ') | (@as(u16, self.color) << 8);
        } else {
            const index = self.row * width + self.column;
            vga_address[index] = @as(u16, c) | (@as(u16, self.color) << 8);
            self.column += 1;
        }

        if (self.column >= width) {
            self.column = 0;
            self.row += 1;
        }

        if (self.row >= height) {
            self.scroll();
        }
        self.updateCursor();
    }

    fn scroll(self: *VgaTerminal) void {
        const screen_size = height * width;
        const line_size = width;
        const src_ptr = vga_address + line_size;
        const dst_ptr = vga_address;

        const dst_slice: []u16 = @as([*]u16, @ptrCast(@volatileCast(dst_ptr)))[0 .. screen_size - line_size];
        const src_slice: []const u16 = @as([*]u16, @ptrCast(@volatileCast(src_ptr)))[0 .. screen_size - line_size];

        std.mem.copyForwards(u16, dst_slice, src_slice);

        const last_line_ptr = vga_address + (height - 1) * width;
        const last_line_slice: []u16 = @as([*]u16, @ptrCast(@volatileCast(last_line_ptr)))[0..line_size];

        const space = @as(u16, ' ') | (@as(u16, self.color) << 8);
        @memset(last_line_slice, space);
        self.row = height - 1;
    }

    pub fn write(self: *VgaTerminal, msg: []const u8) void {
        for (msg) |c| {
            self.putChar(c);
        }
    }

    pub const VgaWriter = std.io.GenericWriter(*VgaTerminal, error{}, writeFn);

    pub fn writer(self: *VgaTerminal) VgaWriter {
        return .{ .context = self };
    }

    pub fn writeFn(self: *VgaTerminal, msg: []const u8) error{}!usize {
        self.write(msg);
        return msg.len;
    }
};
