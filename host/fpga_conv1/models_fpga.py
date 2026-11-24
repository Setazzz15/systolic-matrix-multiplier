"""The same network as ../models.py, with the multiply-adds of conv1 done on the FPGA.

    Net       (../models.py)  conv1 runs in PyTorch on this PC
    NetFPGA   (this file)     conv1 runs on the Cmod A7 through fpga_link.FpgaLink

Everything after conv1 (ReLU, pooling, conv2, the two linear layers) is inherited unchanged.
"""
import os
import sys

import numpy as np
import torch as t
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from models import Net  # noqa: E402  (the original model, one folder up)

from fpga_link import MODE_ENGINE, CLOCK_HZ  # noqa: E402


class FpgaConv1(nn.Module):
    """Replaces nn.Conv2d(3, 32, 5) for inputs in the range 0..1.

    The FPGA works with 8-bit integers, so:
      weights  w  ->  round(w / w_scale),  w_scale = max|w| / 127      (-127..127)
      pixels   x  ->  round(127 * x)                                    (0..127)
    The board returns exact integer sums S. The floating-point result is then
      conv1(x) ~= S * w_scale / 127 + bias
    """

    def __init__(self, conv1, link, mode=MODE_ENGINE):
        super().__init__()
        w = conv1.weight.detach()
        self.register_buffer("bias", conv1.bias.detach().clone())
        self.w_scale = float(w.abs().max()) / 127.0
        self.w_q = t.round(w / self.w_scale).clamp(-127, 127).to(t.int8)
        self.link, self.mode = link, mode
        self.link.load_weights(self.w_q.numpy())      # once: the weights stay on the board
        self.cycles = 0                               # clocks the board spent computing, last forward()
        self.last_output = None                       # conv1 output of the last forward(), for comparing

    @staticmethod
    def quantize_image(img):
        return t.round(127 * img).clamp(0, 127).to(t.int8)

    def forward(self, x):
        outputs, self.cycles = [], 0
        for img in x:                                  # the board handles one image at a time
            sums, cycles = self.link.conv1(self.quantize_image(img).numpy(), mode=self.mode)
            self.cycles += cycles
            y = t.from_numpy(sums.astype(np.float32)) * (self.w_scale / 127.0) + self.bias[:, None, None]
            outputs.append(y)
        self.last_output = t.stack(outputs)
        return self.last_output

    @property
    def seconds_on_board(self):
        return self.cycles / CLOCK_HZ


class NetFPGA(Net):
    def __init__(self, link, mode=MODE_ENGINE, state_dict=None):
        super().__init__()
        if state_dict is not None:
            self.load_state_dict(state_dict)
        self.conv1_fpga = FpgaConv1(self.conv1, link, mode)

    def forward(self, x):
        x = self.pool(F.relu(self.conv1_fpga(x)))      # the only line that differs from Net.forward
        x = self.pool(F.relu(self.conv2(x)))
        x = t.flatten(x, 1)
        x = F.relu(self.fc1(x))
        x = self.fc2(x)
        return x
