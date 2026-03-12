const std = @import("std");
const keyboard = @import("drivers/keyboard.zig");
const drivers = @import("drivers.zig");
const c = @import("drivers/serial.zig");
const pci = @import("drivers/pci.zig");
const pmm = @import("pmm.zig");
const mb = @import("multiboot.zig");
const vmm = @import("vmm.zig");
const timer = @import("drivers/timer.zig");
const thread = @import("thread.zig");
const sync = @import("sync.zig");

pub export fn outb(port: u16, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [data] "{al}" (data),
          [port] "{dx}" (port),
    );
}

export fn timerHandler() callconv(.{ .x86_interrupt = .{} }) void {
    timer.ticks += 1;

    outb(0x20, 0x20);
}

pub export fn outl(port: u16, data: u32) void {
    asm volatile ("outl %[data], %[port]"
        :
        : [data] "{eax}" (data),
          [port] "{dx}" (port),
    );
}

pub export fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub export fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    zero: u8 = 0,
    type_attr: u8,
    offset_high: u16,
};

const IdtPtr = packed struct {
    limit: u16,
    base: u32,
};

export var idt: [256]IdtEntry align(16) = undefined;
var idt_ptr: IdtPtr = undefined;

fn exceptionHandler(vector: u8) void {
    terminal.color = 0x4F;
    terminal.clear();
    terminal.writer().print("CPU EXCEPTION: {d}\nHALTING SYSTEM", .{vector}) catch {};
    // std.log.info("CPU EXCEPTION: {d}\n HAULTING SYSTEM", .{vector});
    while (true) {
        asm volatile ("cli;hlt");
    }
}

inline fn genHeader(comptime i: u8) (fn () callconv(.{ .x86_interrupt = .{} }) void) {
    return struct {
        fn handler() callconv(.{ .x86_interrupt = .{} }) void {
            exceptionHandler(i);
        }
    }.handler;
}

fn setIdtGate(n: u8, handler: u32) void {
    idt[n].offset_low = @as(u16, @truncate(handler));
    idt[n].selector = 0x08;
    idt[n].type_attr = 0x8E;
    idt[n].offset_high = @as(u16, @truncate(handler >> 16));
}

export fn keyboardHandler() callconv(.{ .x86_interrupt = .{} }) void {
    const scancode = inb(0x60);
    if (scancode < 0x80) {
        const ascii = keyboard.scancodeToAscii(scancode);
        if (ascii != 0) {
            keyboard.push(ascii);
        }
    }
    outb(0x20, 0x20);
}

export fn faultHandler() callconv(.{ .x86_interrupt = .{} }) void {
    while (true) asm volatile ("cli; hlt");
}

fn initPic() void {
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    outb(0x21, 0x20);
    outb(0xA1, 0x28);
    outb(0x21, 0x04);
    outb(0xA1, 0x02);
    outb(0x21, 0x01);
    outb(0xA1, 0x01);
    outb(0x21, 0xFF);
    outb(0xA1, 0xFF);
}

fn initIdt() void {
    @memset(std.mem.asBytes(&idt), 0);

    inline for (0..32) |i| {
        setIdtGate(@intCast(i), @intFromPtr(&genHeader(@intCast(i))));
    }

    setIdtGate(14, @intFromPtr(&pageFaultHandler));
    setIdtGate(32, @intFromPtr(&timerInterruptStub));
    setIdtGate(33, @intFromPtr(&keyboardHandler));

    idt_ptr = IdtPtr{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idt_ptr),
    );
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    terminal.color = 0x1F;
    terminal.clear();

    const writer = terminal.writer();
    _ = writer.write("\n!!! KERNEL PANIC !!!\n") catch {};
    _ = writer.print("Reason: {s}\n", .{msg}) catch {};

    const serial = c.Serial.writer();
    _ = serial.print("\n!!! KERNEL PANIC {s} ---\r\n", .{msg}) catch {};

    while (true) asm volatile ("cli; hlt");
}

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var terminal_ready: bool = false;
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    sync.log_lock.aquire();
    defer sync.log_lock.release();

    const prefix = "[" ++ @tagName(scope) ++ "]" ++ @tagName(level) ++ ": ";

    if (terminal_ready) {
        terminal.writer().print(prefix ++ format ++ "\n", args) catch {};
    }

    const serial_writer = c.Serial.writer();
    serial_writer.print(prefix ++ format ++ "\r\n", args) catch {};
}

const InterruptFrame = extern struct {
    eip: usize,
    cs: usize,
    eflags: usize,
    esp: usize,
    ss: usize,
};

pub fn pageFaultHandler(frame: *const InterruptFrame, error_code: usize) callconv(.{ .x86_interrupt = .{} }) void {
    var cr2: usize = undefined;
    asm volatile ("mov %%cr2, %[res]"
        : [res] "=r" (cr2),
    );
    terminal.color = 0x4F;
    terminal.clear();

    // We only want to "fix" faults caused by page not being present (Bit 0 of error_code is 0)
    if (error_code & 0x1 == 0) {
        std.log.info("Demanding Page: Mapping 0x{X} on the fly...", .{cr2});

        const phys = pmm.allocPage() orelse {
            std.log.err("OUT OF MEMORY during page fault.", .{});
            while (true) asm volatile ("cli;hlt");
        };

        vmm.mapPage(cr2, phys, 0x3);

        return;
    }

    const writer = terminal.writer();
    writer.print("---- PAGE FAULT ---", .{}) catch {};
    writer.print("FAULTING ADDRESS: 0x{X}\n", .{cr2}) catch {};
    writer.print("ERROR CODE: 0x{X}\n", .{error_code}) catch {};

    if (error_code & 0x1 == 0) _ = writer.write("Not Present ") catch {};
    if (error_code & 0x2 != 0) _ = writer.write("Write ") catch {};
    if (error_code & 0x4 != 0) _ = writer.write("User ") catch {};
    if (error_code & 0x10 != 0) _ = writer.write("Instruction Fetch") catch {};
    _ = writer.write(")\n") catch {};

    writer.print("EIP: 0x{X}\n", .{frame.eip}) catch {};

    std.log.err("PAGE FAULT at 0x{X}, Code: 0x{X}, EIP: 0x{X}", .{ cr2, error_code, frame.eip });

    while (true) asm volatile ("cli; hlt");
}

var heap_buffer: []u8 = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;
pub var allocator: std.mem.Allocator = undefined;
var terminal: drivers.VgaTerminal = undefined;

fn initHeap() void {
    const heap_start = pmm.allocPage() orelse return;
    for (0..15) |_| _ = pmm.allocPage();

    heap_buffer = @as([*]u8, @ptrFromInt(heap_start))[0..(16 * pmm.PAGE_SIZE)];
    fba = std.heap.FixedBufferAllocator.init(heap_buffer);
    allocator = fba.allocator();
}

pub export fn switchContext(old_stack_ptr: *u32, new_stack_ptr: u32) callconv(.c) void {
    asm volatile (
        \\pushl %%ebp
        \\pushl %%ebx
        \\pushl %%esi
        \\pushl %%edi
        \\movl %%esp, (%[old_ptr])
        \\movl %[new_ptr], %%esp
        \\popl %%edi
        \\popl %%esi
        \\popl %%ebx
        \\popl %%ebp
        \\ret
        :
        : [old_ptr] "r" (old_stack_ptr),
          [new_ptr] "r" (new_stack_ptr),
        : .{ .memory = true });
}

export fn schedule(old_esp: u32) u32 {
    thread.current_thread.stack_ptr = old_esp;
    thread.current_thread = thread.getNext();
    return thread.current_thread.stack_ptr;
}

pub fn timerInterruptStub() callconv(.naked) void {
    asm volatile (
        \\pushal
        \\
        \\pushl %%esp
        \\call schedule
        \\addl $4, %%esp
        \\
        \\movl %%eax, %%esp
        \\
        \\movb $0x20, %%al
        \\outb %%al, $0x20
        \\
        \\popal
        \\iretl
    );
}

var main_thread: thread.Thread = undefined;
var secondary_thread: *thread.Thread = undefined;

fn taskA() void {
    while (true) {
        std.log.info("[Task A] Processing...", .{});
        // Artificial delay loop
        var i: u32 = 0;
        while (i < 5000000) : (i += 1) asm volatile ("nop");
    }
}

fn taskB() void {
    while (true) {
        std.log.info("[Task B] Monitoring...", .{});
        var i: u32 = 0;
        while (i < 5000000) : (i += 1) asm volatile ("nop");
    }
}

fn shellTask() void {
    std.log.info("Shell Task Started. Type Something!", .{});

    while (true) {
        if (keyboard.pop()) |ascii| {
            terminal.putChar(ascii);

            if (ascii == '\n') {
                std.log.info("User submitted a command!", .{});
            }
        } else {
            var i: u32 = 0;
            while (i < 10000) : (i += 1) asm volatile ("pause");
        }
    }
}

pub export fn kernelMain(magic: u32, mb_info_addr: usize) noreturn {
    c.Serial.init();
    const info: *mb.Info = @ptrFromInt(mb_info_addr);
    if (magic != 0x2BADB002) {
        std.log.err("Invalid Multiboot magic 0x{X}", .{magic});
    } else {
        std.log.info("multiboot check passed", .{});
    }

    pmm.init(info);
    std.log.info("PMM initialized...", .{});

    vmm.init();
    std.log.info("Paging Enabled: Identity mapped 0-4MB", .{});

    initHeap();
    std.log.info("Heap Allocator Online...", .{});

    pci.enumerate();

    const my_list = allocator.alloc(u32, 5) catch unreachable;
    defer allocator.free(my_list);

    my_list[0] = 42;
    std.log.info("Allocated array at 0x{X}, first value: {d}", .{ @intFromPtr(my_list.ptr), my_list[0] });

    // @TODO: Fault handler is not working...

    initPic();
    initIdt();

    std.log.info("Serial subsystem initialized...", .{});

    terminal = drivers.VgaTerminal.init(.Yellow, .Black);
    terminal.clear();
    terminal.write("Zig OS: Booted and Ready\n");
    terminal_ready = true;

    // std.log.info("testing demand page...", .{});

    // const magic_ptr: *volatile u32 = @ptrFromInt(0x500000);
    // magic_ptr.* = 0xABCDE123;

    // std.log.info("Successfully wrote 0x{X} to 0x500000 via Demand Paging!", .{magic_ptr.*});

    var kthread = thread.Thread{ .stack_ptr = 0, .stack_mem = &.{}, .id = 1, .status = .Running };
    thread.init(&kthread);

    // const t1 = thread.spawn(allocator, @intFromPtr(&taskA)) catch unreachable;
    // const t2 = thread.spawn(allocator, @intFromPtr(&taskB)) catch unreachable;
    // thread.addThread(t1);
    // thread.addThread(t2);

    const shell_thread = thread.spawn(allocator, @intFromPtr(&shellTask)) catch unreachable;
    thread.addThread(shell_thread);

    timer.init(100);
    outb(0x21, 0xFD); // Enable Keyboard IRQ
    outb(0x21, 0b11111100);
    asm volatile ("sti");

    while (true) asm volatile ("hlt");
}
