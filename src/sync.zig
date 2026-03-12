const std = @import("std");
const Atomic = std.atomic.Value;

pub const SpinLock = struct {
    state: Atomic(u32) = Atomic(u32).init(0),

    pub fn aquire(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(
            0,
            1,
            .acquire,
            .monotonic,
        ) != null) {
            //@Optimization: tell the CPU we are in spin lock.
            asm volatile ("pause");
        }
    }

    pub fn aquireSafe(self: *SpinLock) void {
        asm volatile ("cli");
        self.aquire();
    }

    pub fn releaseSafe(self: *SpinLock) void {
        self.release();
        asm volatile ("sti");
    }

    pub fn release(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

pub var log_lock = SpinLock{};
