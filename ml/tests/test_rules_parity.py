"""rules.c and dt/baseline.py must classify identically.

Compiles firmware/dance_node/src/rules.c for the host with the system C
compiler, loads it through ctypes, and compares class, confidence and the
integer features against dt.baseline on random windows, hand-built edge cases
and windows cut from simulated steps (dt/footsim.py through the firmware
pipeline in dt/node.py) across all classes, both feet and the stressed ends of
the adversarial ranges, and from the auditor's two-leg simulator (dt/legsim.py). Also checks that every threshold #define in rules.c
equals the value dt.baseline.thresholds() derives from the physical constants.
Run: python -m pytest tests/  (or python tests/test_rules_parity.py)
"""
import ctypes
import re
import subprocess
import sys
import tempfile
from dataclasses import replace
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml"))

from dt import baseline, node  # noqa: E402
import realsim  # noqa: E402
from dt import footsim as F  # noqa: E402
from dt.windows import CHANNELS, WIN_LEN  # noqa: E402

SRC = ROOT / "firmware/dance_node/src"
RULES_C = SRC / "rules.c"


def build_rules() -> ctypes.CDLL:
    out = Path(tempfile.mkdtemp()) / "rules.so"
    cmd = ["cc", "-shared", "-fPIC", "-O2", "-o", str(out), str(RULES_C), f"-I{SRC}", "-lm"]
    subprocess.run(cmd, check=True)
    lib = ctypes.CDLL(str(out))
    lib.rules_classify_ex.restype = ctypes.c_int
    lib.rules_classify_ex.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.POINTER(ctypes.c_uint8), ctypes.c_void_p]
    return lib


class StepWindow(ctypes.Structure):
    _fields_ = [("t_strike_us", ctypes.c_uint32), ("x", (ctypes.c_int8 * len(CHANNELS)) * WIN_LEN)]


class Features(ctypes.Structure):   # rules.h rules_features_t
    _fields_ = [("imp", ctypes.c_int16), ("e", ctypes.c_int16), ("s", ctypes.c_int16), ("how", ctypes.c_uint8), ("how_e", ctypes.c_uint8),
                ("dx_cm", ctypes.c_float), ("dy_cm", ctypes.c_float), ("dz_cm", ctypes.c_float),
                ("zmax_cm", ctypes.c_float), ("pitch_min_deg", ctypes.c_float), ("pitch_range_deg", ctypes.c_float),
                ("roll_deg", ctypes.c_float), ("swing_ms", ctypes.c_float)]


def c_classify(lib: ctypes.CDLL, w: np.ndarray, vocab: int = 0) -> tuple:
    sw = StepWindow()
    ctypes.memmove(ctypes.addressof(sw.x), np.ascontiguousarray(w, dtype=np.int8).ctypes.data, WIN_LEN * len(CHANNELS))
    conf = ctypes.c_uint8(0)
    f = Features()
    cls = lib.rules_classify_ex(ctypes.byref(sw), vocab, ctypes.byref(conf), ctypes.byref(f))
    return cls, conf.value, (f.imp, f.e, f.s, f.how, f.how_e)


def py_classify(w: np.ndarray, vocab: int = 0) -> tuple:
    f = baseline.features(w)
    cls, conf = baseline.decide(f, vocab=vocab)
    return int(cls), int(conf), (f["imp"], f["e"], f["s"], f["how"], f["how_e"])


def random_windows() -> list[np.ndarray]:
    rng = np.random.default_rng(475)
    ws = [rng.integers(-128, 128, size=(WIN_LEN, len(CHANNELS)), dtype=np.int8) for _ in range(300)]
    # Small-amplitude noise reaches the quiet/planted branches that full-range noise never does.
    ws += [rng.integers(-4, 5, size=(WIN_LEN, len(CHANNELS))).astype(np.int8) for _ in range(200)]
    # Hand-built: still foot, pushes in each direction, a lone impact, saturated rails.
    still = np.zeros((WIN_LEN, len(CHANNELS)), dtype=np.int8)
    still[:, 2] = 16                                       # 1 g up in the sensor frame (8 g scale)
    ws.append(still)
    for ax, ay in [(10, 0), (-10, 0), (0, 10), (0, -10), (2, 1), (60, 5)]:
        w = still.copy()
        w[40:90, 6] = ax; w[90:100, 6] = -ax
        w[40:90, 7] = ay; w[90:100, 7] = -ay
        w[40:100, 4] = 20
        w[100, 2] = 60
        ws.append(w)
    rail = np.full((WIN_LEN, len(CHANNELS)), 127, dtype=np.int8)
    rail[::2] = -128
    ws.append(rail)
    return ws


def simulated_windows() -> list[np.ndarray]:
    """Windows the firmware would cut for simulated steps, realistic and stressed."""
    settings = [F.Realism(),
                replace(F.Realism(), edge=frozenset({"heading_deg", "tilt_dyn_deg", "acc_bias_g"})),
                replace(F.Realism(), lazy_p=1.0, lazy_scale=(0.4, 0.4), p_soft=1.0)]
    ws = []
    for si, R in enumerate(settings):
        for c in F.CLASSES:
            for k in range(12):
                rng = np.random.default_rng(1000 * si + 100 * int(c) + k)
                tr = F.simulate(c, rng, R, foot="LR"[k % 2])
                for a in node.detect_swing(tr.fused, node.NEW_DETECTOR):
                    ws.append(node.cut(tr.fused, a, tr.foot == "R", node.NEW_DETECTOR.win_pre,
                                       node.NEW_DETECTOR.win_post))
    # The auditor's two-leg simulator (dt/legsim.py): both feet, a few stress settings.
    for k, over in enumerate([{}, dict(p_slide=1.0), dict(p_land={"ball": 1.0}), dict(kick_phi=(20, 35)),
                              dict(cal_w=0.05), dict(hz_smooth=0.0)]):
        for st in realsim.gen_routine((900 + k, {**realsim.AUD_REAL, **over}, {}, "test")):
            for a in node.detect_swing(st["fused"], node.NEW_DETECTOR):
                ws.append(node.cut(st["fused"], a, st["right"], node.NEW_DETECTOR.win_pre,
                                   node.NEW_DETECTOR.win_post))
    return ws


# No routine, and each dance's classes (judge.c passes the schedule's classes in dance mode).
VOCABS = [0] + [realsim.vocab_mask(v) for v in realsim.DANCES.values()]


def check(lib, ws) -> list:
    bad = []
    for i, w in enumerate(ws):
        for v in VOCABS:
            c, p = c_classify(lib, w, v), py_classify(w, v)
            if c != p:
                bad.append((i, v, c, p))
    return bad


def test_thresholds_match():
    text = RULES_C.read_text()
    c_defs = {m.group(1): int(m.group(2)) for m in re.finditer(r"#define RULE_(\w+)\s+(-?\d+)", text)}
    py = baseline.thresholds()
    assert set(py) <= set(c_defs), f"missing in rules.c: {set(py) - set(c_defs)}"
    diff = {k: (c_defs[k], v) for k, v in py.items() if c_defs[k] != v}
    assert not diff, f"rules.c vs thresholds() (C, Python): {diff}"


def test_parity_random():
    bad = check(build_rules(), random_windows())
    assert not bad, f"{len(bad)} mismatches, first: {bad[:5]}"


def test_parity_simulated():
    ws = simulated_windows()
    assert len(ws) > 300
    bad = check(build_rules(), ws)
    assert not bad, f"{len(bad)} of {len(ws)} mismatches, first: {bad[:5]}"


if __name__ == "__main__":
    test_thresholds_match()
    test_parity_random()
    test_parity_simulated()
    print("rules.c == baseline.py")
