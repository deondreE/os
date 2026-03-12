const std = @import("std");

pub fn RingBuffer(comptime T: type, comptime size: usize) type {
    return struct {
        buffer: [size]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, item: T) bool {
            if (self.count == size) return false;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % size;
            self.count += 1;
            return true;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % size;
            self.count -= 1;
            return item;
        }

        pub fn isFull(self: *Self) bool {
            return self.count == size;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.count == 0;
        }
    };
}
