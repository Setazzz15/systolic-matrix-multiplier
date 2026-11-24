#!/bin/sh
# Build firmware.elf -> firmware.bin -> firmware_v2.hex ($readmemh) and firmware_v2.coe (Vivado BRAM init).
# Needs clang and lld with the riscv32 target (or adapt to riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32).
set -e
OUT=${1:-.}
CFLAGS="--target=riscv32-unknown-elf -march=rv32i -mabi=ilp32 -Os -ffreestanding -fno-builtin -nostdlib -Wall -Wextra"
clang $CFLAGS -c start.S -o $OUT/start.o
clang $CFLAGS -c main.c -o $OUT/main.o
ld.lld -T link.ld $OUT/start.o $OUT/main.o -o $OUT/firmware_v2.elf
llvm-objcopy -O binary $OUT/firmware_v2.elf $OUT/firmware_v2.bin
python3 bin2mem.py $OUT/firmware_v2.bin $OUT/firmware_v2.hex $OUT/firmware_v2.coe 16384
