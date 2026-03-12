const std = @import("std");
const main = @import("../main.zig");
const log = std.log.scoped(.ata);

// Primary ATA bus ports
const ATA_DATA = 0x1F0;
const ATA_ERROR = 0x1F1;
const ATA_SECTOR_COUNT = 0x1F2;
const ATA_LBA_LOW = 0x1F3;
const ATA_LBA_MID = 0x1F4;
const ATA_LBA_HIGH = 0x1F5;
const ATA_DRIVE_HEAD = 0x1F6;
const ATA_STATUS = 0x1F7;
const ATA_COMMAND = 0x1F7;

// Status register bits
const STATUS_BSY = 0x80; // Busy
const STATUS_DRDY = 0x40; // Drive ready
const STATUS_DRQ = 0x08; // Data request (ready to transfer)
const STATUS_ERR = 0x01; // Error

// Commands
const CMD_READ_SECTORS = 0x20;
const CMD_WRITE_SECTORS = 0x30;
const CMD_IDENTIFY = 0xEC;

pub const SECTOR_SIZE = 512;

pub const AtaError = error{
    Timeout,
    DriveError,
    NoDrive,
};

// Wait until BSY clears, return final status
fn waitReady() AtaError!u8 {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = main.inb(ATA_STATUS);
        if (status & STATUS_BSY == 0) return status;
    }
    return AtaError.Timeout;
}

// Wait until DRQ sets (data ready to read/write)
fn waitDrq() AtaError!void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        const status = main.inb(ATA_STATUS);
        if (status & STATUS_ERR != 0) return AtaError.DriveError;
        if (status & STATUS_DRQ != 0) return;
    }
    return AtaError.Timeout;
}

// 400ns delay — read status port 4 times (each read ~100ns on real hw)
fn ataDelay() void {
    _ = main.inb(ATA_STATUS);
    _ = main.inb(ATA_STATUS);
    _ = main.inb(ATA_STATUS);
    _ = main.inb(ATA_STATUS);
}

pub fn identify() AtaError!void {
    // Select master drive
    main.outb(ATA_DRIVE_HEAD, 0xA0);
    ataDelay();

    // Zero out LBA/count registers
    main.outb(ATA_SECTOR_COUNT, 0);
    main.outb(ATA_LBA_LOW, 0);
    main.outb(ATA_LBA_MID, 0);
    main.outb(ATA_LBA_HIGH, 0);

    main.outb(ATA_COMMAND, CMD_IDENTIFY);
    ataDelay();

    const status = main.inb(ATA_STATUS);
    if (status == 0) {
        log.err("ATA: No drive detected", .{});
        return AtaError.NoDrive;
    }

    try waitDrq();

    // Read 256 words of identify data
    var data: [256]u16 = undefined;
    for (&data) |*word| {
        word.* = main.inw(ATA_DATA);
    }

    // Words 27-46 contain model string (40 bytes, byte-swapped)
    var model: [41]u8 = undefined;
    for (0..20) |i| {
        const word = data[27 + i];
        model[i * 2] = @truncate(word >> 8);
        model[i * 2 + 1] = @truncate(word & 0xFF);
    }
    model[40] = 0;

    // Total LBA28 sectors at word 60-61
    const total_sectors = @as(u32, data[61]) << 16 | data[60];

    log.info("ATA Drive: {s}", .{model[0..40]});
    log.info("ATA Size: {d} MB", .{total_sectors / 2048});
}

// Read `count` sectors starting at LBA `lba` into `buf`
// buf must be at least count * SECTOR_SIZE bytes
pub fn readSectors(lba: u32, count: u8, buf: []u8) AtaError!void {
    std.debug.assert(buf.len >= @as(usize, count) * SECTOR_SIZE);

    const status = try waitReady();
    if (status & STATUS_ERR != 0) return AtaError.DriveError;

    // LBA28 mode, master drive
    main.outb(ATA_DRIVE_HEAD, @as(u8, 0xE0) | @as(u8, @truncate((lba >> 24) & 0x0F)));
    main.outb(ATA_SECTOR_COUNT, count);
    main.outb(ATA_LBA_LOW, @truncate(lba & 0xFF));
    main.outb(ATA_LBA_MID, @truncate((lba >> 8) & 0xFF));
    main.outb(ATA_LBA_HIGH, @truncate((lba >> 16) & 0xFF));
    main.outb(ATA_COMMAND, CMD_READ_SECTORS);

    var sector: usize = 0;
    while (sector < count) : (sector += 1) {
        try waitDrq();

        const offset = sector * SECTOR_SIZE;
        var i: usize = 0;
        while (i < SECTOR_SIZE) : (i += 2) {
            const word = main.inw(ATA_DATA);
            buf[offset + i] = @truncate(word & 0xFF);
            buf[offset + i + 1] = @truncate(word >> 8);
        }
    }
}

// Write `count` sectors starting at LBA `lba` from `buf`
pub fn writeSectors(lba: u32, count: u8, buf: []const u8) AtaError!void {
    std.debug.assert(buf.len >= @as(usize, count) * SECTOR_SIZE);

    const status = try waitReady();
    if (status & STATUS_ERR != 0) return AtaError.DriveError;

    main.outb(ATA_DRIVE_HEAD, @as(u8, 0xE0) | @as(u8, @truncate((lba >> 24) & 0x0F)));
    main.outb(ATA_SECTOR_COUNT, count);
    main.outb(ATA_LBA_LOW, @truncate(lba & 0xFF));
    main.outb(ATA_LBA_MID, @truncate((lba >> 8) & 0xFF));
    main.outb(ATA_LBA_HIGH, @truncate((lba >> 16) & 0xFF));
    main.outb(ATA_COMMAND, CMD_WRITE_SECTORS);

    var sector: usize = 0;
    while (sector < count) : (sector += 1) {
        try waitDrq();

        const offset = sector * SECTOR_SIZE;
        var i: usize = 0;
        while (i < SECTOR_SIZE) : (i += 2) {
            const word = @as(u16, buf[offset + i + 1]) << 8 | buf[offset + i];
            main.outw(ATA_DATA, word);
        }
    }

    // Flush cache
    main.outb(ATA_COMMAND, 0xE7);
    _ = try waitReady();
}
