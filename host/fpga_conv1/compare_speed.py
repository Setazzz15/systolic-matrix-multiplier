"""Run the original network and the FPGA-backed one on the same images and compare them.

    python compare_speed.py                  board on COM4, 3 CIFAR-10 test images
    python compare_speed.py --images 10
    python compare_speed.py --emulate        no board needed: a software stand-in answers instead
    python compare_speed.py --synthetic      no CIFAR-10 needed: generated test images

What it prints
  1. Do both networks predict the same class, and how far apart are their conv1 outputs?
  2. How long conv1 takes: PyTorch on this PC, and three ways on the FPGA board.
"""
import argparse
import glob
import os
import pickle
import sys
import time

import numpy as np
import torch as t

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, REPO)

from models import Net  # noqa: E402
from fpga_link import (FpgaLink, MODE_SOFTWARE, MODE_CPU_FED, MODE_ENGINE, CLOCK_HZ, OUT_H)  # noqa: E402
from models_fpga import NetFPGA  # noqa: E402

CIFAR_URL = "https://www.cs.toronto.edu/~kriz/cifar-10-python.tar.gz"
CLASSES = ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]


def find_model(path):
    if path:
        return path
    for name in ["model.pt", "model (2).pt", "model_2.pt"]:
        if os.path.exists(os.path.join(REPO, name)):
            return os.path.join(REPO, name)
    found = sorted(glob.glob(os.path.join(REPO, "*.pt")))
    if not found:
        sys.exit("No model .pt file found next to models.py. Pass one with --model.")
    return found[0]


def load_test_images(count, data_dir, synthetic):
    """Images exactly as cifar10_training.py feeds them to the model: scaled 0..1, then transpose(1, 3)."""
    if synthetic:
        g = t.Generator().manual_seed(0)
        return t.rand(count, 3, 32, 32, generator=g), None
    batch = os.path.join(data_dir, "cifar-10-batches-py", "test_batch")
    archive = os.path.join(data_dir, "cifar-10-python.tar.gz")
    if not os.path.exists(batch):
        if not os.path.exists(archive):
            print(f"CIFAR-10 test data not found at {batch}")
            answer = input(f"Download it (163 MB) from {CIFAR_URL} into {data_dir}? [y/N] ").strip().lower()
            if answer != "y":
                sys.exit("Stopped. Run again with --synthetic to use generated images instead.")
            import urllib.request
            os.makedirs(data_dir, exist_ok=True)
            print("Downloading ...")
            try:
                urllib.request.urlretrieve(CIFAR_URL, archive + ".part")
                os.replace(archive + ".part", archive)
            except Exception as error:
                if os.path.exists(archive + ".part"):
                    os.remove(archive + ".part")
                sys.exit(f"\nThe download failed: {error}\n\n"
                         f"Two ways forward:\n"
                         f"  1. Download the file in your web browser from\n       {CIFAR_URL}\n"
                         f"     and save it, without unpacking, as\n       {archive}\n"
                         f"     then run this script again.\n"
                         f"  2. Run with --synthetic to use generated images. The timings are the same.")
        import tarfile
        print(f"Unpacking {archive} ...")
        with tarfile.open(archive) as tar:
            members = [m for m in tar.getmembers()
                       if m.name.startswith("cifar-10-batches-py/") and ".." not in m.name and (m.isfile() or m.isdir())]
            try:
                tar.extractall(data_dir, members=members, filter="data")
            except TypeError:                      # Python older than 3.12 has no filter argument
                tar.extractall(data_dir, members=members)
        if not os.path.exists(batch):
            sys.exit(f"{archive} did not contain cifar-10-batches-py/test_batch. Is it the 'CIFAR-10 python version' archive?")
    with open(batch, "rb") as f:
        data = pickle.load(f, encoding="bytes")
    ims = data[b"data"][:count].reshape(count, 3, 32, 32).transpose(0, 2, 3, 1).astype(np.float32) / 255.0
    labels = list(data[b"labels"][:count])
    return t.from_numpy(ims).transpose(1, 3).contiguous(), labels


def time_call(fn, repeats):
    samples = []
    for _ in range(repeats):
        t0 = time.perf_counter()
        fn()
        samples.append(time.perf_counter() - t0)
    return float(np.median(samples))


def fmt_time(seconds):
    if seconds < 1e-3:
        return f"{seconds * 1e6:8.1f} us"
    if seconds < 1.0:
        return f"{seconds * 1e3:8.2f} ms"
    return f"{seconds:8.2f} s "


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="COM4", help="serial port of the Cmod A7 (default COM4)")
    ap.add_argument("--baud", type=int, default=230400, help="UART speed of the bitstream (default 230400)")
    ap.add_argument("--images", type=int, default=3, help="how many test images to run (default 3)")
    ap.add_argument("--model", default=None, help="state dict saved by cifar10_training.py")
    ap.add_argument("--data", default=os.path.join(REPO, "Data"), help="folder containing cifar-10-batches-py")
    ap.add_argument("--synthetic", action="store_true", help="use generated images instead of CIFAR-10")
    ap.add_argument("--emulate", action="store_true", help="use a software stand-in for the board")
    ap.add_argument("--full-baselines", action="store_true",
                    help="time the two slow board modes on a whole image (a bit over a minute) instead of a sample")
    args = ap.parse_args()

    model_path = find_model(args.model)
    state = t.load(model_path, map_location="cpu", weights_only=True)
    images, labels = load_test_images(args.images, args.data, args.synthetic)
    print(f"model: {model_path}")
    print(f"images: {len(images)} " + ("generated" if args.synthetic else "from the CIFAR-10 test set"))

    original = Net()
    original.load_state_dict(state)
    original.eval()

    if args.emulate:
        from fpga_emulator import EmulatedBoard
        link = FpgaLink(EmulatedBoard())
        print("board: EMULATED in software (clock counts are the ones measured on the real design)")
    else:
        link = FpgaLink(args.port, args.baud)
        print(f"board: {args.port} at {args.baud} baud")
    if not link.ping():
        sys.exit("The board did not answer. Is it programmed with the current bitstream, and are the port and --baud right?")
    fpga = NetFPGA(link, MODE_ENGINE, state)
    fpga.eval()

    # ------------------------------------------------------------ 1. same answers?
    print("\n1. Do the two networks agree?\n")
    print("   image  label        original     FPGA conv1   max |conv1 difference|   board compute   with transfer")
    agree, engine_seconds, wall_seconds = 0, [], []
    with t.no_grad():
        for i in range(len(images)):
            x = images[i:i + 1]
            ref_conv = original.conv1(x)
            ref_pred = int(original(x).argmax())
            t0 = time.perf_counter()
            fpga_pred = int(fpga(x).argmax())
            wall = time.perf_counter() - t0
            fpga_conv = fpga.conv1_fpga.last_output
            diff = float((fpga_conv - ref_conv).abs().max())
            agree += ref_pred == fpga_pred
            engine_seconds.append(fpga.conv1_fpga.seconds_on_board)
            wall_seconds.append(wall)
            label = CLASSES[labels[i]] if labels else "-"
            print(f"   {i:5d}  {label:11s}  {CLASSES[ref_pred]:11s}  {CLASSES[fpga_pred]:11s}  {diff:12.4f}"
                  f"             {fmt_time(engine_seconds[-1])}     {'(emulated)' if args.emulate else fmt_time(wall)}")
    print(f"\n   same prediction on {agree} of {len(images)} images")
    print("   (differences come from rounding pixels and weights to 8 bits; the board's integer sums are exact)")

    # ------------------------------------------------------------ 2. how fast?
    x = images[0:1]
    with t.no_grad():
        pc_conv1 = time_call(lambda: original.conv1(x), 200)
        pc_net = time_call(lambda: original(x), 200)
    img_q = fpga.conv1_fpga.quantize_image(x[0]).numpy()
    link.load_image(img_q)
    if args.full_baselines:
        cpu_fed = sum(link.run_row(y, MODE_CPU_FED)[1] for y in range(OUT_H)) / CLOCK_HZ
        software = sum(link.run_row(y, MODE_SOFTWARE)[1] for y in range(OUT_H)) / CLOCK_HZ
        how = "measured on the whole image"
    else:
        # One row, a few of the 16 filter pairs, scaled up. Every row and pair costs the same.
        cpu_fed = link.run_row(0, MODE_CPU_FED, nfp=2)[1] * 8 * OUT_H / CLOCK_HZ
        software = link.run_row(0, MODE_SOFTWARE, nfp=1)[1] * 16 * OUT_H / CLOCK_HZ
        how = "scaled up from a sample; use --full-baselines to measure all of it"
    engine = float(np.mean(engine_seconds))
    wall = float(np.mean(wall_seconds))

    print("\n2. How long does conv1 take for one image?\n")
    print(f"   On this PC, PyTorch                              {fmt_time(pc_conv1)}   (whole network: {fmt_time(pc_net).strip()})")
    print(f"   On the FPGA board, {CLOCK_HZ // 1_000_000} MHz clock:")
    print(f"     a) PicoRV32 CPU alone, in software             {fmt_time(software)}   {software / engine:8.0f}x the engine's time")
    print(f"     b) 2x2 array, operands fed by the CPU          {fmt_time(cpu_fed)}   {cpu_fed / engine:8.0f}x")
    print(f"     c) conv1 engine: 8x8 array fed from block RAM  {fmt_time(engine)}          1x")
    if not args.emulate:
        print(f"   Engine plus sending the image and results over USB serial: {fmt_time(wall).strip()}")
    print(f"   (a and b: {how})")
    link.close()


if __name__ == "__main__":
    main()
