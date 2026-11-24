/* PicoRV32 firmware layout: one 64 KB block RAM at address 0 holds code, data and stack. */
MEMORY { ram (rwx) : ORIGIN = 0x00000000, LENGTH = 0x10000 }
ENTRY(_start)
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > ram
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ram
    .data : { *(.data .data.* .sdata .sdata.*) } > ram
    .bss (NOLOAD) : { __bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(4); __bss_end = .; } > ram
    __stack_top = ORIGIN(ram) + LENGTH(ram);
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note.*) }
}
