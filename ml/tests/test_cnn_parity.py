"""cnn.c must reproduce the Keras model it was exported from.

Compiles firmware/dance_node/src/cnn.c for the host, loads it through ctypes,
and compares class and softmax output against runs/model.keras on every window
in runs/windows.npz. Skips if those artifacts are absent.
"""
import ctypes
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml"))

from dt.protocol import N_CLASSES  # noqa: E402
from dt.windows import CHANNELS, WIN_LEN  # noqa: E402

SRC = ROOT / "firmware/dance_node/src"
MODEL = ROOT / "ml/runs/model.keras"
NPZ = ROOT / "ml/runs/windows.npz"


def build_cnn() -> ctypes.CDLL:
    out = Path(tempfile.mkdtemp()) / "cnn.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-o", str(out), str(SRC / "cnn.c"), f"-I{SRC}"], check=True)
    lib = ctypes.CDLL(str(out))
    lib.cnn_forward.restype = ctypes.c_int
    lib.cnn_forward.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float)]
    return lib


def c_forward(lib: ctypes.CDLL, w: np.ndarray) -> tuple[int, np.ndarray]:
    buf = np.ascontiguousarray(w, dtype=np.int8)
    probs = (ctypes.c_float * N_CLASSES)()
    cls = lib.cnn_forward(buf.ctypes.data, probs)
    return cls, np.array(probs, dtype=np.float32)


@pytest.mark.skipif(not (MODEL.exists() and NPZ.exists()), reason="train.py artifacts absent")
def test_parity():
    import tensorflow as tf

    lib = build_cnn()
    x = np.load(NPZ)["x"]
    model = tf.keras.models.load_model(MODEL)
    ref = model.predict(x.astype(np.float32), verbose=0)
    worst = 0.0
    for i in range(len(x)):
        cls, probs = c_forward(lib, x[i])
        assert cls == int(ref[i].argmax()), f"window {i}: C class {cls}, Keras {ref[i].argmax()}"
        worst = max(worst, float(np.abs(probs - ref[i]).max()))
    assert worst < 1e-4, f"max softmax deviation {worst}"


if __name__ == "__main__":
    test_parity()
    print("cnn.c == model.keras")
