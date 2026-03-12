const std = @import("std");
const log = std.log.scoped(.thread);
const timer = @import("drivers/timer.zig");

pub const Priority = enum(u8) {
    Low = 1,
    Normal = 2,
    High = 4,
};

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
    status: enum { Ready, Running, Sleeping, Dead },
    priority: Priority,
    ticks_remaining: u32 = 0,
    wake_tick: u32 = 0,
};

// @TODO: get that from maximum hardware????
const MAX_THREADS = 16;

var thread_queue: [MAX_THREADS]?*Thread = [_]?*Thread{null} ** MAX_THREADS;
var current_idx: usize = 0;
pub var current_thread: *Thread = undefined;
var next_id: u32 = 2;

pub fn init(first_thread: *Thread) void {
    thread_queue[0] = first_thread;
    current_thread = first_thread;
    current_thread.ticks_remaining = @intFromEnum(current_thread.priority);
}

pub fn addThread(t: *Thread) void {
    for (&thread_queue) |*slot| {
        if (slot.* == null) {
            slot.* = t;
            t.ticks_remaining = @intFromEnum(t.priority);
            return;
        }
    }
    log.err("Thread queue full! Could not add thread {d}", .{t.id});
}

pub fn removeThread(id: u32) void {
    for (&thread_queue) |*slot| {
        if (slot.*) |t| {
            if (t.id == id) {
                slot.* = null;
                return;
            }
        }
    }
}

pub fn getNext() *Thread {
    for (thread_queue) |slot| {
        if (slot) |t| {
            if (t.status == .Sleeping and timer.ticks >= t.wake_tick) {
                t.status = .Ready;
                t.ticks_remaining = @intFromEnum(t.priority);
            }
        }
    }

    // If current thread still has ticks AND is running, keep it (priority timeslice)
    if (current_thread.status == .Running and current_thread.ticks_remaining > 0) {
        current_thread.ticks_remaining -= 1;
        return current_thread;
    }

    // Mark current as ready (unless sleeping/dead)
    if (current_thread.status == .Running) {
        current_thread.status = .Ready;
    }

    // Find highest priority ready thread (round-robin among equals)
    var best: ?*Thread = null;
    var best_idx: usize = 0;
    var search_idx = (current_idx + 1) % MAX_THREADS;
    var checked: usize = 0;

    while (checked < MAX_THREADS) : (checked += 1) {
        if (thread_queue[search_idx]) |t| {
            if (t.status == .Ready) {
                if (best == null or @intFromEnum(t.priority) > @intFromEnum(best.?.priority)) {
                    best = t;
                    best_idx = search_idx;
                }
            }
        }
        search_idx = (search_idx + 1) % MAX_THREADS;
    }

    if (best) |t| {
        current_idx = best_idx;
        t.status = .Running;
        t.ticks_remaining = @intFromEnum(t.priority);
        return t;
    }

    // Nothing ready — return current (idle spin)
    current_thread.status = .Running;
    return current_thread;
}

pub fn yield() void {
    current_thread.ticks_remaining = 0;
    asm volatile ("int $0x20"); // Trigger IRQ manually;
}

/// Sleep for `ms` milliseconds (requires timer frequency set)
pub fn sleep(ms: u32) void {
    const ticks_per_ms = timer.frequency / 1000;
    current_thread.wake_tick = @intCast(timer.ticks + ticks_per_ms * ms);
    current_thread.status = .Sleeping;
    yield();
}

pub fn exit() noreturn {
    current_thread.status = .Dead;
    yield();
    unreachable;
}

pub fn reapDead(alloc: std.mem.Allocator) void {
    for (&thread_queue) |*slot| {
        if (slot.*) |t| {
            if (t.status == .Dead and t.id != current_thread.id) {
                if (t.stack_mem.len > 0) alloc.free(t.stack_mem);
                alloc.destroy(t);
                slot.* = null;
                log.info("Reaped dead thread", .{});
            }
        }
    }
}

pub fn spawn(allocator: std.mem.Allocator, entry: usize, priority: Priority) !*Thread {
    const stack = try allocator.alloc(u8, 8192);
    @memset(stack, 0);

    var stack_top = @intFromPtr(stack.ptr) + stack.len;

    // Push a return address to exit() so threads clean up automatically
    stack_top -= 4;
    @as(*u32, @ptrFromInt(stack_top)).* = @intFromPtr(&exit);

    // iret frame: EFLAGS, CS, EIP
    stack_top -= 4;
    @as(*u32, @ptrFromInt(stack_top)).* = 0x202;
    stack_top -= 4;
    @as(*u32, @ptrFromInt(stack_top)).* = 0x08;
    stack_top -= 4;
    @as(*u32, @ptrFromInt(stack_top)).* = @intCast(entry);

    // pushal: edi, esi, ebp, esp, ebx, edx, ecx, eax
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        stack_top -= 4;
        @as(*u32, @ptrFromInt(stack_top)).* = 0;
    }

    const t = try allocator.create(Thread);
    t.* = .{
        .stack_mem = stack,
        .stack_ptr = @intCast(stack_top),
        .id = next_id,
        .status = .Ready,
        .priority = priority,
        .ticks_remaining = @intFromEnum(priority),
    };
    next_id += 1;
    return t;
}
