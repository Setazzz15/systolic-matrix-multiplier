# matrix_soc: PicoRV32 driving the systolic matrix multiplier

Everything in this folder was added on 2026-11-22 to take the project through Phases 1 to 3:
the CPU runs the multiplier, real C firmware, and one CNN conv1 tile that matches Python.

## Result on the Cmod A7-35T (captured over USB serial, COM4, 57600 baud)

    SMOKE C = [[22, 28], [9, 10]] PASS hw_cycles=3288 sw_cycles=9440
    CONV1 C = [[-1512, -20605], [-1689, -20555]] PASS hw_cycles=45900 sw_cycles=868614
    END ALL PASS

The same lines come out of the Vivado behavioral simulation (`logs/` and the xsim folder).

## How the pieces fit

    PicoRV32 --AXI4-Lite--> SmartConnect --+--> AXI BRAM Controller --> 64 KB block RAM   0x0000_0000 (program + data + stack)
                                           +--> AXIMatrix_bd (your systolic array)         0x1000_0000
                                           +--> AXI UART Lite (USB serial, 57600 baud)     0x2000_0000

AXIMatrix registers (offsets from 0x1000_0000): 0x00 START / status (bit0 BUSY, bit1 DONE),
0x04 K_LEN, 0x08 TERM_INDEX, 0x0C TERM_DATA (bytes low to high: A[0][k], A[1][k], B[k][0], B[k][1]),
0x10..0x1C results C00, C01, C10, C11.

## Folders

| Folder | Contents |
|---|---|
| `fw/`  | Firmware: `start.S` (stack, clear .bss), `link.ld` (memory layout), `main.c` (driver + tests), `matrix.h` (register map), `conv_tile.h` (generated CNN test data), `firmware.coe` (what the block RAM is initialised with). `matrix_smoke.S` / `smoke.coe` are the first hand-written assembly test. |
| `py/`  | `conv1_tile_np.py`: reads `model.pt` from the Adv_Attack CNN project (see `host/`), quantizes two patches and two conv1 filters to 8 bits, prints the expected sums and writes `conv_tile.h`. Needs only numpy. |
| `sim/` | `tb_matrix_soc.sv`: full-system testbench. Drives clock and reset, decodes the UART pin, passes when it sees `END ALL PASS`. |
| `tcl/` | Scripts run from the Vivado Tcl Console with `source C:/Users/Sebastian/Matrix_multiplier/soc/tcl/<name>.tcl`. |
| `logs/` | Output of each script, plus `uart.txt` (raw capture from the board). |
| `backup/` | `matrix_soc.bd` and the `.xpr` as they were before any change. |

## Scripts

1. `01_update_bd.tcl` changes the block design (see below). Safe to run again.
2. `02_sim.tcl` runs the behavioral simulation in batch mode. Result: `Matrix_multiplier.sim/sim_1/behav/xsim/soc_xsim.log`.
3. `03_build.tcl` synthesis, implementation, bitstream. `03b_status.tcl` reports run status.
4. `04_program.tcl` loads the bitstream into the board (volatile; flash untouched).
5. `05_listen.tcl` captures six seconds of serial output into `logs/uart.txt`.

## What changed in the Vivado project

- Block RAM generator: Stand Alone mode, 32-bit x 16384 words (64 KB), initialised from `fw/firmware.coe`. Address range 8K -> 64K.
- Added AXI UART Lite (57600 baud) on SmartConnect M02 at 0x2000_0000; new ports `uart_rxd_out` (J18) and `uart_txd_in` (J17).
- `matrix_soc_wrapper` created and set as the design top. Simulation top is `tb_matrix_soc`.
- `soc/cmod_soc.xdc` added; `cmod_matrix.xdc` (the button demo's pins) is disabled, not deleted.
- `Systolic_NxN.vh` was copied to `Systolic_NxN.sv` and the project now uses the `.sv`. The `.vh` is still on disk, unused.
- Your RTL (`pe.sv`, `Systolic_NxN`, `systolic_controller.sv`, `AXIMatrix.sv`) was not edited.

### Going back to the button demo (fpga_top)

In the Tcl Console:

    set_property top fpga_top [get_filesets sources_1]
    set_property is_enabled true  [get_files cmod_matrix.xdc]
    set_property is_enabled false [get_files cmod_soc.xdc]

Swap the three values to return to the CPU design.

## Changing the firmware

`fw/build.sh` compiles with clang + lld for `rv32i` (it was built on a separate Linux machine; there is no
RISC-V compiler on this PC yet). After producing a new `firmware.coe`, run scripts 1, 3 and 4 again:
the program is part of the bitstream.

## Things to know before Phase 4

- Of the 45,900 cycles for the CONV1 job, the array computes for 78. The rest is the CPU writing 75
  operand words one at a time (about 600 cycles each through SmartConnect). Data movement is the bottleneck.
- The test image is a synthetic pattern, not a CIFAR-10 photo.
- `cifar10_training.py` feeds the model images with rows and columns swapped (`transpose(1,3)`),
  scaled 0..1 with no mean/std normalisation. Real images must be fed the same way.
- This Vivado install has no `bin/xsim.bat`; `02_sim.tcl` starts the simulator through `loader.bat`.
- `validate_bd_design` failed once with "Spawn failed" and worked on the second try.
