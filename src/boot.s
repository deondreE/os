.set MAGIC,    0x1BADB002
.set FLAGS,    0x00000003
.set CHECKSUM, -(0x1BADB002 + 0x00000003)

.section .multiboot
.align 4
.long MAGIC
.long FLAGS
.long CHECKSUM

.section .data
.align 16
gdt_start:
    .quad 0x0000000000000000 # Null
    .quad 0x00cf9a000000ffff # Code
    .quad 0x00cf92000000ffff # Data
gdt_end:

.global gdt_ptr
gdt_ptr:
    .short gdt_end - gdt_start - 1
    .long gdt_start

.section .bss
.align 16
stack_bottom:
.skip 16384
stack_top:

.section .text
.global _start
_start:
    cli
    mov %eax, %edi
    mov %ebx, %esi
    mov $stack_top, %esp
    mov %esp, %ebp

    # --- ENABLE SSE & FPU ---
    mov %cr0, %eax
    and $0xFFFB, %ax
    or $0x2, %ax
    mov %eax, %cr0

    mov %cr4, %eax
    or $0x600, %eax
    mov %eax, %cr4

    # --- LOAD GDT ---
    lgdt (gdt_ptr)
    ljmp $0x08, $reload_cs
reload_cs:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    # Push NULL to stop stack traces
    pushl $0
    popf

    push %esi
    push %edi

    call kernelMain

_hang:
    hlt
    jmp _hang
