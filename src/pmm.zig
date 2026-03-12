const std = @import("std");
const mb = @import("multiboot.zig");
const log = std.log.scoped(.mem);

pub const PAGE_SIZE = 4096;
// 32768 bits == 4096 bytes == 128 MB
const MAX_PAGES = 32768;
var bitmap: [MAX_PAGES / 8]u8 = [_]u8{0xFF} ** (MAX_PAGES / 8);

pub fn init(info: *const mb.Info) void {
    if (info.flags & 0x40 == 0) return;

    const mmap_start: [*]mb.MemoryMapEntry = @ptrFromInt(info.mmap_addr);
    const mmap_end = info.mmap_addr + info.mmap_length;
    var current = mmap_start;

    while (@intFromPtr(current) < mmap_end) {
        if (current[0].type == 1) {
            var addr = current[0].base_addr;
            const end_addr = addr + current[0].length;
            while (addr < end_addr and addr < (128 * 1024 * 1024)) : (addr += PAGE_SIZE) {
                freePage(@intCast(addr));
            }
        }
        current = @ptrFromInt(@intFromPtr(current) + current[0].size + 4);
    }

    // RESERVE FIRST 1MB (BIOS, VGA, KERNEL)
    for (0..256) |i| reservePage(i * PAGE_SIZE);
}

fn reservePage(addr: usize) void {
    const page = addr / PAGE_SIZE;
    bitmap[page / 8] |= (@as(u8, 1) << @intCast(page % 8));
}

fn freePage(addr: usize) void {
    const page = addr / PAGE_SIZE;
    bitmap[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
}

pub fn allocPage() ?usize {
    for (bitmap, 0..) |byte, i| {
        if (byte == 0xFF) continue;
        for (0..8) |bit| {
            if ((byte & (@as(u8, 1) << @intCast(byte)) == 0)) {
                const addr = (i * 8 + bit) * PAGE_SIZE;
                reservePage(addr);
                return addr;
            }
        }
    }
    return null;
}
