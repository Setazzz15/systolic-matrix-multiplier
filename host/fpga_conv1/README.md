# fpga_conv1: the same CNN, with conv1 computed on the FPGA

Nothing in the parent folder is changed. This folder adds a second version of the model so the
two can be compared side by side.

| | Original | FPGA version |
|---|---|---|
| Model class | `Net` in `../models.py` | `NetFPGA` in `models_fpga.py` |
| conv1 (3 -> 32 channels, 5x5) | PyTorch on this PC | systolic array on the Cmod A7 |
| Everything after conv1 | PyTorch | PyTorch, inherited unchanged |

## Run it

    pip install pyserial            (once)
    python compare_speed.py         board on COM4, 3 CIFAR-10 test images

Useful options: `--images 10`, `--port COM5`, `--emulate` (no board), `--synthetic` (no CIFAR-10),
`--full-baselines` (time the slow modes on a whole image, a bit over a minute).

The board must be programmed with the current bitstream (48 MHz, 8x8 engine) from the Vivado project
(`Matrix_multiplier`, scripts `soc/tcl/03_build.tcl` and `04_program.tcl`). Close anything else
that has the serial port open, including a listener in the Vivado Tcl Console.

The first run offers to download the CIFAR-10 test set (163 MB) into `../Data`, which is where
`cifar10_training.py` expects it.

## Files

| File | What it does |
|---|---|
| `models_fpga.py` | `FpgaConv1` (drop-in for `conv1`) and `NetFPGA`. Read this one first. |
| `fpga_link.py` | The serial protocol: upload weights, upload an image, ask for output rows. |
| `compare_speed.py` | Runs both models, checks they agree, prints the timing table. |
| `fpga_emulator.py` | Software stand-in for the board, used by `--emulate`. |

## How conv1 gets onto the board

The FPGA multiplies 8-bit integers, so `FpgaConv1` converts in both directions:

    weights   w -> round(w / w_scale)      w_scale = max|w| / 127     sent once, kept on the board
    pixels    x -> round(127 * x)          x is 0..1, as in cifar10_training.py
    board returns exact integer sums S
    conv1(x) ~= S * w_scale / 127 + bias

The image is sent exactly as the model sees it, that is after the `transpose(1, 3)` in
`cifar10_training.py`.

## The three ways the board can compute conv1

| Mode | Who fetches the operands | Clocks per output row | Whole image at 48 MHz |
|---|---|---|---|
| 0 | No array at all: the PicoRV32 CPU multiplies and adds in software | about 114,500,000 | about 67 s |
| 1 | The CPU writes every operand to a 2x2 systolic array over the AXI bus | about 10,800,000 | about 6.3 s |
| 2 | The conv1 engine reads operands from block RAM and drives an 8x8 array | 1,506 | 0.88 ms |

conv1 has 28 output rows. Sending the image and the 25,088 results over USB serial at 230,400 baud
takes about 5 s per image, far longer than the engine needs to compute them.

A desktop CPU is still faster than all three (about 0.1 ms). The comparison that means something is
on the board itself: the same small CPU with and without the accelerator.
