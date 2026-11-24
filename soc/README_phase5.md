# After Phase 4: 48 MHz clock and an 8x8 array

Added on 2026-11-22. Earlier work is described in `README.md` and `README_phase4.md`.

## Result on the Cmod A7-35T (conv1 of one image, 25,088 outputs, every value checked against the reference)

| Step | Engine clocks per image | Clock | Engine time |
|---|---|---|---|
| Phase 4: 2x2 array, fed from block RAM | 489,384 | 12 MHz | 40.8 ms |
| 48 MHz clock | 489,384 | 48 MHz | 10.2 ms |
| 8x8 array | 42,168 | 48 MHz | 0.88 ms |

For comparison on the same board at 48 MHz: array fed by the CPU about 6.3 s, CPU alone in software about 67 s.
One image including serial transfer at 230,400 baud: about 5 s.

## What changed

| Where | What |
|---|---|
| Block design | `clk_wiz_0` (Clocking Wizard, 12 -> 48 MHz) feeds every block; its `locked` output drives `proc_sys_reset_0/dcm_locked`. UART Lite at 230400 baud. |
| `Matrix_multiplier.srcs/sources_1/new/conv1_engine.sv` | Rewritten for `N` lanes (default 8). Instantiates `Systolic_NxN #(.N(8))`. The 2x2 version is in `soc/backup_before_8x8/`. |
| `soc/tcl/08_clock_48mhz.tcl`, `09_engine_8x8.tcl` | The scripts that made the two changes. Block-design backup in `soc/backup_before_48mhz/`. |
| `host/fpga_conv1/` | `CLOCK_HZ` is 48 MHz and the default baud rate is 230400. |

Not changed: `pe.sv`, `Systolic_NxN.sv`, `AXIConv.sv`, the firmware binary, the register map.

## Resources and timing

| | Before (2x2, 12 MHz) | Now (8x8, 48 MHz) | Available |
|---|---|---|---|
| LUTs | 7,169 | 13,800 (66%) | 20,800 |
| Flip-flops | 10,635 | 15,521 (37%) | 41,600 |
| Block RAM tiles | 19 | 23 | 50 |
| DSP multipliers | 0 | 0 | 90 |
| Timing slack | 65.8 ns of 83.3 | 5.5 ns of 20.8 | |

The 64 multipliers are built from LUTs. Adding `(* use_dsp = "yes" *)` in `pe.sv` would move them into the
unused DSP blocks and free a few thousand LUTs.

## Why 8x8 gives 11.6x and not 16x

A row is 16 jobs instead of 224 (14x fewer), but a job is 90 clocks instead of 78 because operands travel
further across the larger array, and storing the last 64 results adds 66 clocks per row.

## What limits it now

Transfer: about 5 s per image against 0.88 ms of computing. The results are 100 KB; doing ReLU and 2x2
pooling on the board would cut that 4x, and sending 8-bit values instead of 32-bit another 4x.
