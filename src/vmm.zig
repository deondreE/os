const std = @import("std");
const pmm = @import("pmm.zig");

pub const PAGE_SIZE = 4096;

const PRESENT = 0x1;
const WRITABLE = 0x2;
const USER = 0x4;

/// Helper to get the Page Directory index (top 10 bits)
fn pdIdx(v_addr: usize) usize {
    return v_addr >> 22;
}
/// Helper to get the Page Table index (middle 10 bits)
fn ptIdx(v_addr: usize) usize {
    return (v_addr >> 12) & 0x3FF;
}

pub var page_directory: [1024]u32 align(4096) = [_]u32{0} ** 1024;
pub var first_page_table: [1024]u32 align(4096) = [_]u32{0} ** 1024;

pub fn init() void {
    var i: u32 = 0;
    while (i < 1024) : (i += 1) {
        first_page_table[i] = (i * PAGE_SIZE) | PRESENT | WRITABLE;
    }

    // puts the first page table as the first entry of the directory;
    page_directory[0] = @intFromPtr(&first_page_table) | PRESENT | WRITABLE;

    page_directory[1023] = @intFromPtr(&page_directory) | PRESENT | WRITABLE;

    enablePaging(@intFromPtr(&page_directory));
}

pub fn mapPage(v_addr: usize, p_addr: usize, flags: u32) void {
    const pdi = pdIdx(v_addr);
    const pti = ptIdx(v_addr);

    if (page_directory[pdi] & 0x1 == 0) {
        const new_pt_phsy = pmm.allocPage() orelse unreachable;

        @memset(@as([*]u8, @ptrFromInt(new_pt_phsy))[0..4096], 0);

        page_directory[pdi] = @as(u32, @intCast(new_pt_phsy)) | 0x3;
    }

    const pt_phys = page_directory[pdi] & ~@as(u32, 0xFFFF);
    const pt: [*]u32 = @ptrFromInt(pt_phys);

    pt[pti] = @as(u32, @intCast(p_addr & ~@as(u32, 0xFFFF))) | flags;

    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (v_addr),
        : .{ .memory = true });
}

fn enablePaging(pd_addr: usize) void {
    return asm volatile (
        \\mov %[pd], %%cr3
        \\mov %%cr0, %%eax
        \\or $0x80000000, %%eax
        \\mov %%eax, %%cr0
        :
        : [pd] "r" (pd_addr),
        : .{ .eax = true, .memory = true });
}
