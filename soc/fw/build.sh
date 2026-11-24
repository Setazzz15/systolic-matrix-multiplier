#!/bin/sh
# Build firmware.elf -> firmware.bin -> firmware.hex ($readmemh) and firmware.coe (Vivado BRAM init).
set -e
OUT=${1:-../build}
CFLAGS="--target=riscv32-unknown-elf -march=rv32i -mabi=ilp32 -Os -ffreestanding -fno-builtin -nostdlib -Wall -Wextra"
clang $CFLAGS -c start.S -o $OUT/start.o
clang $CFLAGS -c main.c -o $OUT/main.o
ld.lld -T link.ld $OUT/start.o $OUT/main.o -o $OUT/firmware.elf
llvm-objcopy -O binary $OUT/firmware.elf $OUT/firmware.bin
python3 bin2mem.py $OUT/firmware.bin $OUT/firmware.hex $OUT/firmware.coe 16384
