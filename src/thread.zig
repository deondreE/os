const std = @import("std");

pub const Context = extern struct {
    edi: u32,
    esi: u32,
    ebx: u32,
    ebp: u32,
    eip: u32,
};

pub const Thread = struct {
    stack_ptr: u32,
    stack_mem: []u8,
    id: u32,
    status: enum { Ready, Running, Dead },
};

var thread_queue: [4]?*Thread = [_]?*Thread{null} ** 4;
var current_idx: usize = 0;
pub var current_thread: *Thread = undefined;

pub fn init(first_thread: *Thread) void {
    thread_queue[0] = first_thread;
    current_thread = first_thread;
}

pub fn addThread(t: *Thread) void {
    for (&thread_queue) |*slot| {
        if (slot.* == null) {
            slot.* = t;
            return;
        }
    }
}

pub fn getNext() *Thread {
    current_idx = (current_idx + 1) % thread_queue.len;
    while (thread_queue[current_idx] == null) {
        current_idx = (current_idx + 1) % thread_queue.len;
    }
    return thread_queue[current_idx].?;
}

pub fn spawn(allocator: std.mem.Allocator, entry: usize) !*Thread {
    const stack = try allocator.alloc(u8, 4096);

    var stack_top = @intFromPtr(stack.ptr) + stack.len;

    stack_top -= 4;
    @as(*u32, @ptrFromInt(stack_top)).* = 0x202;
    stack_top -= 4;
    @as(*u32, @ptrFromInt(stack_top)).* = 0x08;
    stack_top -= 4;
    @as(*u32, @ptrFromInt(stack_top)).* = @intCast(entry);

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        stack_top -= 4;
        @as(*u32, @ptrFromInt(stack_top)).* = 0;
    }

    const t = try allocator.create(Thread);
    t.stack_mem = stack;
    t.stack_ptr = @intCast(stack_top);
    t.status = .Ready;
    return t;
}
