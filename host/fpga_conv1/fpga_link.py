"""Serial link to the matrix_soc firmware (version 2) running on the Cmod A7.

Protocol (see soc/fw2/main.c in the Vivado project):
    'P'                    -> b"MXC2"
    'W' + 2400 bytes       -> 'K' + checksum      weights  [filter][channel*25 + dy*5 + dx], int8
    'I' + 3072 bytes       -> 'K' + checksum      image    [channel][row][col], int8 0..127
    'R' + mode + row + nfp -> 'D' + mode + row + cycles(4) + 896 int32 results + checksum

Only numpy is needed here; pyserial is imported when a real port is opened.
"""
import time
import numpy as np

MODE_SOFTWARE, MODE_CPU_FED, MODE_ENGINE = 0, 1, 2
MODE_NAMES = {0: "CPU only (software)", 1: "array fed by the CPU", 2: "conv1 engine"}
N_FILTERS, OUT_H, OUT_W, K_TERMS = 32, 28, 28, 75
ROW_REPLY_LEN = 1 + 1 + 1 + 4 + N_FILTERS * OUT_W * 4 + 1
CLOCK_HZ = 48_000_000      # the design runs at 48 MHz (Clocking Wizard from the 12 MHz crystal)


# ---------------------------------------------------------------- message building / parsing
def cmd_weights(w_q):
    w = np.asarray(w_q, dtype=np.int8).reshape(N_FILTERS, K_TERMS)
    return b"W" + w.tobytes()


def cmd_image(img_q):
    img = np.asarray(img_q, dtype=np.int8).reshape(3, 32, 32)
    return b"I" + img.tobytes()


def cmd_row(mode, row, nfp=16):
    return bytes([ord("R"), mode, row, nfp])


def check_ack(reply, command):
    """'K' + (sum of the payload bytes) & 0xff."""
    if len(reply) != 2 or reply[0:1] != b"K":
        raise IOError(f"expected an acknowledge, got {reply!r}")
    if reply[1] != sum(command[1:]) & 0xFF:
        raise IOError("checksum mismatch: the board did not receive the data correctly")


def parse_row(reply):
    """-> (mode, row, cycles, results[32][28] as int32)."""
    if len(reply) != ROW_REPLY_LEN or reply[0:1] != b"D":
        raise IOError(f"bad row reply: {len(reply)} bytes, starts with {reply[:1]!r}")
    body = reply[7:-1]
    if sum(body) & 0xFF != reply[-1]:
        raise IOError("checksum mismatch in the row results")
    cycles = int.from_bytes(reply[3:7], "little")
    results = np.frombuffer(body, dtype="<i4").reshape(N_FILTERS, OUT_W)
    return reply[1], reply[2], cycles, results


# ---------------------------------------------------------------- the link itself
class FpgaLink:
    """Talks to the board. `port` is a name such as "COM4", or any object with read/write/flush."""

    def __init__(self, port="COM4", baud=230400, timeout=120.0):
        if isinstance(port, str):
            import serial  # pyserial
            self.ser = serial.Serial(port, baud, timeout=timeout)
            time.sleep(0.05)
            self.ser.reset_input_buffer()
        else:
            self.ser = port
        self.bytes_sent = self.bytes_received = 0

    def close(self):
        if hasattr(self.ser, "close"):
            self.ser.close()

    def _write(self, data):
        self.ser.write(data)
        self.ser.flush()
        self.bytes_sent += len(data)

    def _read(self, n):
        data = bytearray()
        while len(data) < n:
            chunk = self.ser.read(n - len(data))
            if not chunk:
                raise IOError(f"timed out: got {len(data)} of {n} bytes from the board")
            data += chunk
        self.bytes_received += n
        return bytes(data)

    def ping(self, tries=5):
        """True once the firmware answers. The first tries can land in the boot message."""
        for _ in range(tries):
            if hasattr(self.ser, "reset_input_buffer"):
                self.ser.reset_input_buffer()
            self._write(b"P")
            old = getattr(self.ser, "timeout", None)
            try:
                if old is not None:
                    self.ser.timeout = 1.0
                data = self.ser.read(4)
            finally:
                if old is not None:
                    self.ser.timeout = old
            if data == b"MXC2":
                return True
            time.sleep(0.3)
        return False

    def load_weights(self, w_q):
        cmd = cmd_weights(w_q)
        self._write(cmd)
        check_ack(self._read(2), cmd)

    def load_image(self, img_q):
        cmd = cmd_image(img_q)
        self._write(cmd)
        check_ack(self._read(2), cmd)

    def run_row(self, row, mode=MODE_ENGINE, nfp=16):
        self._write(cmd_row(mode, row, nfp))
        got_mode, got_row, cycles, results = parse_row(self._read(ROW_REPLY_LEN))
        if (got_mode, got_row) != (mode, row):
            raise IOError("the board answered for a different row or mode")
        return results, cycles

    def conv1(self, img_q, mode=MODE_ENGINE, rows=range(OUT_H), nfp=16):
        """Integer conv1 of one image. Returns (sums[32][28][28], clock cycles spent computing).
        Rows not listed are left at zero."""
        self.load_image(img_q)
        out = np.zeros((N_FILTERS, OUT_H, OUT_W), dtype=np.int32)
        cycles = 0
        for y in rows:
            res, c = self.run_row(y, mode, nfp)
            out[:, y, :] = res
            cycles += c
        return out, cycles
