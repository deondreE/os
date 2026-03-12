const std = @import("std");
const mb = @import("multiboot.zig");
const log = std.log.scoped(.mem);

pub const PAGE_SIZE = 4096;
// 32768 bits == 4096 bytes == 128 MB
const MAX_PAGES = 32768;
var bitmap: [MAX_PAGES / 8]u8 = [_]u8{0xFF} ** (MAX_PAGES / 8);
var total_pages: usize = 0;
var used_pages: usize = 0;

pub fn init(info: *const mb.Info) void {
    if (info.flags & 0x40 == 0) {
        log.err("No memory map from bootloader!", .{});
        return;
    }

    const mmap_start: [*]mb.MemoryMapEntry = @ptrFromInt(info.mmap_addr);
    const mmap_end = info.mmap_addr + info.mmap_length;
    var current = mmap_start;

    while (@intFromPtr(current) < mmap_end) {
        const entry = &current[0];
        if (entry.type == 1) {
            var addr = entry.base_addr;
            const end_addr = addr + entry.length;
            while (addr < end_addr and addr < (128 * 1024 * 1024)) : (addr += PAGE_SIZE) {
                freePage(@intCast(addr));
                total_pages += 1;
            }
        }
        current = @ptrFromInt(@intFromPtr(current) + entry.size + 4);
    }

    // RESERVE FIRST 1MB (BIOS, VGA, KERNEL)
    for (0..256) |i| reservePage(i * PAGE_SIZE);

    log.info("PMM ready: {d} KB free of {d} KB total", .{
        freePages() * PAGE_SIZE / 1024,
        total_pages * PAGE_SIZE / 1024,
    });
}

pub fn printMemoryMap(info: *const mb.Info) void {
    if (info.flags & 0x40 == 0) return;

    log.info("=== Memory Map ===", .{});
    const mmap_start: [*]mb.MemoryMapEntry = @ptrFromInt(info.mmap_addr);
    const mmap_end = info.mmap_addr + info.mmap_length;
    var current = mmap_start;

    while (@intFromPtr(current) < mmap_end) {
        const entry = &current[0];
        const type_str: []const u8 = switch (entry.type) {
            1 => "Available",
            2 => "Reserved",
            3 => "ACPI Reclaimable",
            4 => "ACPI NVS",
            5 => "Bad RAM",
            else => "Unknown",
        };
        log.info("  0x{X:0>8} - 0x{X:0>8} {s} ({d} KB)", .{
            entry.base_addr,
            entry.base_addr + entry.length,
            type_str,
            entry.length / 1024,
        });
        current = @ptrFromInt(@intFromPtr(current) + entry.size + 4);
    }
    log.info("  Free: {d} KB | Used: {d} KB", .{
        freePages() * PAGE_SIZE / 1024,
        used_pages * PAGE_SIZE / 1024,
    });
}

fn reservePage(addr: usize) void {
    const page = addr / PAGE_SIZE;
    if (page >= MAX_PAGES) return;
    const was_free = bitmap[page / 8] & (@as(u8, 1) << @intCast(page % 8)) == 0;
    bitmap[page / 8] |= (@as(u8, 1) << @intCast(page % 8));
    if (was_free) used_pages += 1;
}

fn freePage(addr: usize) void {
    const page = addr / PAGE_SIZE;
    if (page >= MAX_PAGES) return;
    bitmap[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
}

pub fn freePages() usize {
    return total_pages - used_pages;
}

pub fn allocPage() ?usize {
    for (bitmap, 0..) |byte, i| {
        if (byte == 0xFF) continue;
        for (0..8) |bit| {
            if (byte & (@as(u8, 1) << @intCast(bit)) == 0) {
                const addr = (i * 8 + bit) * PAGE_SIZE;
                reservePage(addr);
                return addr;
            }
        }
    }
    return null;
}

pub fn deallocPage(addr: usize) void {
    freePage(addr);
    if (used_pages > 0) used_pages -= 1;
}
