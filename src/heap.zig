const std = @import("std");
const pmm = @import("pmm.zig");
const log = std.log.scoped(.heap);

const FreeBlock = struct {
    size: usize,
    next: ?*FreeBlock,
};

const HEAP_PAGES = 64;
var heap_start: usize = 0;
var free_list: ?*FreeBlock = null;
var initialized: bool = false;

pub fn init() void {
    const first_page = pmm.allocPage() orelse {
        log.err("failed to allocate heap pages!", .{});
        return;
    };
    heap_start = first_page;

    var i: usize = 0;
    while (i < HEAP_PAGES - 1) : (i += 1) {
        _ = pmm.allocPage();
    }

    const heap_size = HEAP_PAGES * pmm.PAGE_SIZE;
    free_list = @ptrFromInt(heap_start);
    free_list.?.* = .{
        .size = heap_size,
        .next = null,
    };

    log.info("Heap initialized: {d} KB at 0x{X}", .{ heap_size / 1024, heap_start });
    initialized = true;
}

fn alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const needed = @max(len + @sizeOf(FreeBlock), @sizeOf(FreeBlock) * 2);
    const aligned = (needed + 7) & ~@as(usize, 7); // align to 8 bytes

    const prev: ?*FreeBlock = null;
    const cur = free_list;

    // first-fit search
    while (cur) |block| {
        if (block.size >= aligned) {
            const remaining = block.size - aligned;

            if (remaining > @sizeOf(FreeBlock)) {
                const new_block: *FreeBlock = @ptrFromInt(@intFromPtr(block) + aligned);
                new_block.* = .{
                    .size = remaining,
                    .next = block.next,
                };
                if (prev) |p|
                    p.next = new_block
                else
                    free_list = new_block;
            } else {
                if (prev) |p|
                    p.next = block.next
                else
                    free_list = block.next;
            }
        }

        block.size = aligned;
        return @ptrFromInt(@intFromPtr(block) + @sizeOf(FreeBlock));
    }

    log.err("Out of heap memory! Requested {d} bytes ", .{len});
    return null;
}

fn free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    const block: *FreeBlock = @ptrFromInt(@intFromPtr(buf.ptr) - @sizeOf(FreeBlock));
    var prev: ?*FreeBlock = null;
    var cur = free_list;

    while (cur) |c| {
        if (@intFromPtr(c) > @intFromPtr(block)) break;
        prev = cur;
        cur = c.next;
    }

    block.next = cur;
    if (prev) |p| p.next = block else free_list = block;

    // Coalesce with next block if adjacent
    if (block.next) |next| {
        if (@intFromPtr(block) + block.size == @intFromPtr(next)) {
            block.size += next.size;
            block.next = next.next;
        }
    }

    // Coalesce with previous block if adjacent
    if (prev) |p| {
        if (@intFromPtr(p) + p.size == @intFromPtr(block)) {
            p.size += block.size;
            p.next = block.next;
        }
    }
}

fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false; // Keep it simple, no in-place resize
}

fn remap(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    // We don't support remapping, return existing pointer if shrinking/same size
    if (new_len <= buf.len) return buf.ptr;
    return null;
}

pub const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .free = free,
    .resize = resize,
    .remap = remap,
};

pub var heap_allocator_state: u8 = 0; // dummy state, allocator is global
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = &heap_allocator_state, .vtable = &vtable };
}

pub fn stats() void {
    var free_bytes: usize = 0;
    var blocks: usize = 0;
    var cur = free_list;
    while (cur) |block| {
        free_bytes += block.size;
        blocks += 1;
        cur = block.next;
    }
    log.info("Heap: {d} KB free in {d} blocks", .{ free_bytes / 1024, blocks });
}
