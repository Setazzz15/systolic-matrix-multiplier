    .section .text
    .globl _start
_start:
    # PicoRV32 boots here at byte address 0. This test needs no stack.
    li t0, 0x10000000       # AXIMatrix base from the Vivado Address Editor
    li t1, 3
    sw t1, 4(t0)            # K_LEN = 3
    sw zero, 8(t0)          # TERM_INDEX = 0

    # A = [[1,2,3],[-1,0,2]], B = [[1,2],[3,4],[5,6]].
    # Each word, high to low: B[k][1], B[k][0], A[1][k], A[0][k].
    li t1, 0x0201ff01
    sw t1, 12(t0)
    li t1, 0x04030002
    sw t1, 12(t0)
    li t1, 0x06050203
    sw t1, 12(t0)
    li t1, 1
    sw t1, 0(t0)            # START
poll:
    lw t1, 0(t0)
    andi t1, t1, 2          # DONE is bit 1
    beqz t1, poll

    # Save the four result words in BRAM at 0x100..0x10c.
    lw t1, 16(t0)
    sw t1, 0x100(zero)
    lw t1, 20(t0)
    sw t1, 0x104(zero)
    lw t1, 24(t0)
    sw t1, 0x108(zero)
    lw t1, 28(t0)
    sw t1, 0x10c(zero)
finished:
    j finished
