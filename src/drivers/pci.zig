const std = @import("std");

extern fn outb(port: u16, data: u8) void;
extern fn inb(port: u16) u8;
extern fn outl(port: u16, data: u32) void;
extern fn inl(port: u16) u32;

pub const PciDevice = struct {
    bus: u8,
    device: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,

    pub fn getClassName(self: PciDevice) []const u8 {
        return switch (self.class_code) {
            0x01 => "Mass Storage Controller",
            0x02 => "Network Controller",
            0x03 => "Display Controller",
            0x04 => "Multimedia Controller",
            0x06 => "Bridge Device",
            0x0C => "Serial Bus Controller ( USB/SATA)",
            else => "Unknown Device",
        };
    }
};

pub fn readConfig(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const address = (@as(u32, bus) << 16) | (@as(u32, slot) << 11) | (@as(u32, func) << 8) | (@as(u32, offset) & 0xFC) | @as(u32, 0x80000000);

    outl(0xCF8, address);
    return inl(0xCFC);
}

pub const BarType = enum {
    Memory,
    IO,
};

pub const Bar = struct {
    address: usize,
    size: usize,
    bar_type: BarType,
};

pub fn getBar(bus: u8, slot: u8, func: u8, bar_index: u8) ?Bar {
    if (bar_index >= 6) return null;
    const offset = 0x10 + (bar_index * 4);

    const bar_value = readConfig(bus, slot, func, offset);
    if (bar_value == 0) return null;

    if (bar_value & 0x1 == 1) {
        return Bar{
            .address = bar_value & 0xFFFFFFFC,
            .size = 0,
            .bar_type = .IO,
        };
    } else {
        return Bar{
            .address = bar_value & 0xFFFFFFF0,
            .size = 0,
            .bar_type = .Memory,
        };
    }
}

pub fn enumerate() void {
    std.log.info("---- Scanning PCI bus ---", .{});

    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) {
            const vendor_device = readConfig(@intCast(bus), slot, 0, 0);
            const vendor = @as(u16, @truncate(vendor_device));

            if (vendor == 0xFFFF) continue;

            const device = @as(u16, @truncate(vendor_device >> 16));
            const class_reg = readConfig(@intCast(bus), slot, 0, 0x08);
            const class_code = @as(u8, @truncate(class_reg >> 24));
            const subclass = @as(u8, @truncate(class_reg >> 16));

            const dev = PciDevice{
                .bus = @intCast(bus),
                .device = slot,
                .function = 0,
                .vendor_id = vendor,
                .device_id = device,
                .class_code = class_code,
                .subclass = subclass,
            };

            if (getBar(@intCast(bus), slot, 0, 0)) |bar| {
                std.log.info("BAR0 Address: 0x{X} ({s})", .{ bar.address, if (bar.bar_type == .Memory) "Memory Mapped" else "I/O Ports" });

                if (bar.bar_type == .Memory) {
                    // vmm.mapPage(bar.address, bar.address, 0x3);
                }
            }

            std.log.info("[{d}:{d}] {s} (ID: {X}:{X})", .{ dev.bus, dev.device, dev.getClassName(), dev.vendor_id, dev.device_id });
        }
    }
}
