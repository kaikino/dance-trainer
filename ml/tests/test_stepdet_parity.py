"""swingdet.c (the firmware strike detector) and dt/node.py detect_swing() must
emit the same strike anchors.

Compiles firmware/dance_node/src/swingdet.c for the host and feeds it, sample by
sample, the same simulated fused streams (dt/footsim.py, dt/legsim.py) the Python
port sees.
"""
import ctypes
import subprocess
import sys
import tempfile
from dataclasses import replace
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml"))

from dt import node  # noqa: E402
from dt import footsim as F  # noqa: E402
import realsim  # noqa: E402

SRC = ROOT / "firmware/dance_node/src"


def build() -> ctypes.CDLL:
    out = Path(tempfile.mkdtemp()) / "swingdet.so"
    # No FMA contraction: the Python port rounds every product, so must the C.
    subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-ffp-contract=off", "-o", str(out),
                    str(SRC / "swingdet.c"), f"-I{SRC}", "-lm"], check=True)
    lib = ctypes.CDLL(str(out))
    lib.swingdet_feed.restype = ctypes.c_int32
    lib.swingdet_feed.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                  ctypes.c_void_p, ctypes.c_void_p, ctypes.c_bool, ctypes.c_int]
    return lib


def c_detect(lib, fused: dict, win_post: int) -> list[int]:
    state = ctypes.create_string_buffer(4096)   # > sizeof(swingdet_t)
    lib.swingdet_init(state)
    acc = np.ascontiguousarray(fused["acc"], dtype=np.float32)
    gyr = np.ascontiguousarray(fused["gyr"], dtype=np.float32)
    foot = np.ascontiguousarray(fused["foot"], dtype=np.float32)
    out = []
    for i in range(len(acc)):
        a = lib.swingdet_feed(state, i, int(fused["t_us"][i]) & 0xFFFFFFFF, acc[i].ctypes.data, gyr[i].ctypes.data,
                              foot[i].ctypes.data, False, win_post)
        if a >= 0:
            out.append(a)
    return out


def test_parity():
    lib = build()
    det = node.NEW_DETECTOR
    settings = [F.Realism(), replace(F.Realism(), p_soft=1.0, lazy_p=1.0, crosstalk_g=1.2, edge=frozenset({"crosstalk_g"}))]
    n = mism = 0
    for si, R in enumerate(settings):
        for c in F.CLASSES:
            for k in range(15):
                rng = np.random.default_rng(5000 + 1000 * si + 50 * int(c) + k)
                tr = F.simulate(c, rng, R, foot="LR"[k % 2])
                fu = dict(tr.fused)
                for key in ("acc", "gyr", "foot"):
                    fu[key] = fu[key].astype(np.float32)
                py = node.detect_swing(fu, det)
                cc = c_detect(lib, fu, det.win_post)
                n += 1
                if py != cc:
                    mism += 1
                    print(c.name, k, "py", py, "c", cc)
    # The auditor's two-leg simulator: whole routines, both feet, stress settings.
    for k, over in enumerate([{}, dict(p_slide=1.0), dict(lift=(0.01, 0.03)), dict(p_land={"ball": 1.0}),
                              dict(hz_smooth=0.0)]):
        rkw = dict(bpm=140, eighth=True) if k == 2 else {}
        for st in realsim.gen_routine((700 + k, {**realsim.AUD_REAL, **over}, rkw, "test")):
            fu = dict(st["fused"])
            for key in ("acc", "gyr", "foot"):
                fu[key] = fu[key].astype(np.float32)
            py = node.detect_swing(fu, det)
            cc = c_detect(lib, fu, det.win_post)
            n += 1
            if py != cc:
                mism += 1
                print("legsim", k, "py", py, "c", cc)
    assert mism == 0, f"{mism} of {n} streams differ"


if __name__ == "__main__":
    test_parity()
    print("swingdet.c == node.detect_swing")
