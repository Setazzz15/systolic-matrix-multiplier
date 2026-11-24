"""A stand-in for the board, so the scripts can be tried without the FPGA (`--emulate`).

It speaks the same serial protocol as the firmware and returns the same integer sums, computed
with numpy. The clock counts it reports are the ones measured on the real design, per output row.
"""
import numpy as np
from fpga_link import N_FILTERS, OUT_W, K_TERMS

ENGINE_CYCLES_PER_ROW = 1_506             # 8 x 8 array: 16 jobs x 90 clocks + 66 to store the last results
CPU_FED_CYCLES_PER_PAIR_ROW = 676_205     # measured on the board for one filter pair, one row
SOFTWARE_CYCLES_PER_PAIR_ROW = 7_158_937  # measured on the board for one filter pair, one row


class EmulatedBoard:
    timeout = None

    def __init__(self):
        self.rx = bytearray()      # bytes waiting to be parsed (PC -> board)
        self.tx = bytearray()      # bytes waiting to be read   (board -> PC)
        self.w = np.zeros((N_FILTERS, 3, 5, 5), dtype=np.int64)
        self.img = np.zeros((3, 32, 32), dtype=np.int64)

    def reset_input_buffer(self):
        self.tx.clear()

    def flush(self):
        pass

    def write(self, data):
        self.rx += data
        while self._step():
            pass

    def read(self, n):
        out, self.tx = bytes(self.tx[:n]), self.tx[n:]
        return out

    def _step(self):
        if not self.rx:
            return False
        cmd = chr(self.rx[0])
        need = {"P": 1, "W": 1 + N_FILTERS * K_TERMS, "I": 1 + 3072, "R": 4}.get(cmd, 1)
        if len(self.rx) < need:
            return False
        msg, self.rx = bytes(self.rx[:need]), self.rx[need:]
        if cmd == "P":
            self.tx += b"MXC2"
        elif cmd == "W":
            self.w = np.frombuffer(msg[1:], dtype=np.int8).reshape(N_FILTERS, 3, 5, 5).astype(np.int64)
            self.tx += bytes([ord("K"), sum(msg[1:]) & 0xFF])
        elif cmd == "I":
            self.img = np.frombuffer(msg[1:], dtype=np.int8).reshape(3, 32, 32).astype(np.int64)
            self.tx += bytes([ord("K"), sum(msg[1:]) & 0xFF])
        elif cmd == "R":
            mode, row, nfp = msg[1], msg[2], msg[3]
            res = np.zeros((N_FILTERS, OUT_W), dtype=np.int64)
            nf = N_FILTERS if mode == 2 else 2 * nfp
            window = self.img[:, row:row + 5, :]                       # the 5 image rows this output row uses
            for dx in range(5):
                res[:nf] += np.einsum("fcd,cdx->fx", self.w[:nf, :, :, dx], window[:, :, dx:dx + OUT_W])
            cycles = {2: ENGINE_CYCLES_PER_ROW, 1: CPU_FED_CYCLES_PER_PAIR_ROW * nfp,
                      0: SOFTWARE_CYCLES_PER_PAIR_ROW * nfp}[mode]
            body = res.astype("<i4").tobytes()
            self.tx += bytes([ord("D"), mode, row]) + cycles.to_bytes(4, "little") + body + bytes([sum(body) & 0xFF])
        return True
