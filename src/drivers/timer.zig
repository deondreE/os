const main = @import("../main.zig");

pub var ticks: u64 = 0;

pub fn init(hz: u32) void {
    const divisor = 1193180 / hz;

    main.outb(0x43, 0x36);

    main.outb(0x40, @truncate(divisor & 0xFF));
    main.outb(0x40, @truncate((divisor >> 8) & 0xFF));
}
