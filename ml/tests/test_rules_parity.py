"""rules.c and dt/baseline.py must classify identically.

Compiles firmware/dance_node/src/rules.c for the host with the system C
compiler, loads it through ctypes, and compares against dt.baseline.classify on
random and hand-built windows. Run: python3 -m pytest tests/  (or python3 tests/test_rules_parity.py)
"""
import ctypes
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml"))

from dt.baseline import classify as py_classify  # noqa: E402
from dt.windows import CHANNELS, WIN_LEN  # noqa: E402

RULES_C = ROOT / "firmware/dance_node/src/rules.c"
INCLUDES = [ROOT / "firmware/dance_node/src"]


def build_rules() -> ctypes.CDLL:
    out = Path(tempfile.mkdtemp()) / "rules.so"
    cmd = ["cc", "-shared", "-fPIC", "-O2", "-o", str(out), str(RULES_C)] + [f"-I{i}" for i in INCLUDES]
    subprocess.run(cmd, check=True)
    lib = ctypes.CDLL(str(out))
    lib.rules_classify.restype = ctypes.c_int
    lib.rules_classify.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8)]
    return lib


class StepWindow(ctypes.Structure):
    _fields_ = [("t_strike_us", ctypes.c_uint32), ("x", (ctypes.c_int8 * len(CHANNELS)) * WIN_LEN)]


def c_classify(lib: ctypes.CDLL, w: np.ndarray) -> tuple[int, int]:
    sw = StepWindow()
    for i in range(WIN_LEN):
        for c in range(len(CHANNELS)):
            sw.x[i][c] = int(w[i, c])
    conf = ctypes.c_uint8(0)
    cls = lib.rules_classify(ctypes.byref(sw), ctypes.byref(conf))
    return cls, conf.value


def windows() -> list[np.ndarray]:
    rng = np.random.default_rng(475)
    ws = [rng.integers(-128, 128, size=(WIN_LEN, len(CHANNELS)), dtype=np.int8) for _ in range(500)]
    # Shaped cases: a clear forward push, a clear outward push, nothing.
    for ax, ay in [(40, 0), (-40, 0), (0, 40), (0, -40), (2, 1), (120, 5), (0, 0)]:
        w = np.zeros((WIN_LEN, len(CHANNELS)), dtype=np.int8)
        w[:40, 6] = ax
        w[:40, 7] = ay
        ws.append(w)
    return ws


def test_parity():
    lib = build_rules()
    mismatches = []
    for i, w in enumerate(windows()):
        c = c_classify(lib, w)
        p = py_classify(w)
        if c != (int(p[0]), p[1]):
            mismatches.append((i, c, (int(p[0]), p[1])))
    assert not mismatches, f"{len(mismatches)} mismatches, first: {mismatches[:5]}"


if __name__ == "__main__":
    test_parity()
    print("rules.c == baseline.py on", len(windows()), "windows")
