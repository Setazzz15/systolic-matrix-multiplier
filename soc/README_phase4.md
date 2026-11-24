# Phase 4: all of conv1 on the board, three ways

Added on 2026-11-22. Phases 1 to 3 are described in `README.md`.

## Result on the Cmod A7-35T (one 32x32 image, all 28x28x32 = 25,088 conv1 outputs)

Every value returned by the board matches the integer reference.

| How the board computes conv1 | 12 MHz clocks | Time | Measured |
|---|---|---|---|
| PicoRV32 alone, in software | about 3.2 billion | about 267 s | 1 filter pair of 1 row, scaled up |
| Systolic array, operands written by the CPU (AXIMatrix) | about 303 million | about 25 s | 2 filter pairs of 1 row, scaled up |
| conv1 engine, operands read from block RAM (AXIConv) | 489,384 | 40.8 ms | whole image |

The engine is 619x faster than the CPU-fed array and about 6,500x faster than software on the same board.
Sending the results to the PC at 125,000 baud takes about 9 s per image, far longer than computing them.

## What was added

| Where | What |
|---|---|
| `Matrix_multiplier.srcs/sources_1/new/conv1_engine.sv` | Image, weight and result block RAMs plus the counters that feed `Systolic_NxN` one operand per lane per clock. |
| `.../AXIConv.sv`, `AXIConv_bd.v` | AXI4-Lite registers for the engine, and the plain-Verilog shim the block design needs. |
| Block design | `AXIConv_bd_0` on SmartConnect M03 at `0x3000_0000`. UART Lite set to "128000" (really 125,000 baud). Block RAM loads `soc/fw2/firmware_v2.coe`. |
| `soc/fw2/` | Firmware version 2: serial protocol, three compute modes, power-on self-test. |
| `soc/tcl/06_add_conv_engine.tcl` | Makes the block-design changes. Backup of the previous state is in `soc/backup_before_phase4/`. |
| `soc/tcl/07_board_test.tcl` | Uploads `soc/test/*.bin`, runs every row, saves the replies to `soc/logs/board_rows.bin`. |
| `host/fpga_conv1/` | The Python side: `NetFPGA` and `compare_speed.py`. |

Not changed: `pe.sv`, `Systolic_NxN.sv`, `systolic_controller.sv`, `AXIMatrix.sv`.

## Register map of AXIConv (offsets from 0x3000_0000)

`00` CONTROL (write 1 = start row; read bit0 BUSY, bit1 DONE) · `04` ROW · `08` IMG_ADDR · `0C` IMG_DATA (4 pixels per write)
· `10` WGT_ADDR · `14` WGT_DATA · `18` RES_ADDR · `1C` RES_DATA · `20` CYCLES · `24` ID

## Resources and timing after Phase 4

7,169 LUTs (34%), 10,635 flip-flops (26%), 19 of 50 block RAMs. Slack 65.8 ns on the 83.3 ns clock.

## Where the remaining time goes, and what would help next

1. Serial transfer: 9 s per image against 41 ms of computing. A faster system clock would allow a faster UART;
   doing ReLU and pooling on the board would cut the data sent back by 4x.
2. Clock: the slack suggests the design could run several times faster than 12 MHz with a Clocking Wizard.
3. Array size: 4 PEs today. The board has 90 unused DSP multipliers.
