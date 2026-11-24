    .section .text.start
    .globl _start
_start:
    /* PicoRV32 begins executing at address 0 after reset. */
    la   sp, __stack_top          /* stack grows down from the top of the 64 KB RAM */
    la   t0, __bss_start          /* clear zero-initialised globals */
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  call main
3:  j    3b

    /* unsigned int read_cycle(void): PicoRV32's 32-bit cycle counter (rdcycle a0). */
    .globl read_cycle
read_cycle:
    .word 0xc0002573
    ret
