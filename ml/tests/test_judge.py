"""judge.c timing: a step is not reported missed before its strike can arrive, and a
step already reported missed is not matched afterwards.

Compiles firmware/dance_node/src/judge.c for the host against stub FreeRTOS headers
(the test includes judge.c to reach its static functions), then drives it with the
strike times and detection latency the firmware has: the strike detector emits each
window exactly WIN_POST samples after the landing (checked on simulated routines
from both simulators here too).
"""
import ctypes
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml"))

from dt import node  # noqa: E402
from dt.protocol import StepClass  # noqa: E402
import realsim  # noqa: E402

SRC = ROOT / "firmware/dance_node/src"
CORRECT, OFF_BEAT, WRONG, MISSED, EXTRA = 1, 2, 3, 4, 5

STUBS = {
    "FreeRTOS.h": "#pragma once\n#include <stdint.h>\ntypedef void *QueueHandle_t;\n#define pdTRUE 1\n"
                  "#define pdMS_TO_TICKS(x) (x)\n",
    "task.h": "#pragma once\n",
    "queue.h": "#pragma once\nint xQueueSend(QueueHandle_t q, const void *item, uint32_t ticks);\n"
               "int xQueueReceive(QueueHandle_t q, void *item, uint32_t ticks);\n",
    "harness.c": r'''
#include "judge.c"
QueueHandle_t window_q = (void *)1, haptic_q = (void *)2, event_q = (void *)3;
dt_step_event_t ev[512]; int n_ev = 0;
uint32_t now_us = 0; uint8_t next_cls = 0, next_conf = 0;
int xQueueSend(QueueHandle_t q, const void *item, uint32_t t) {
    if (q == event_q && n_ev < 512) memcpy(&ev[n_ev++], item, sizeof(dt_step_event_t));
    return 1; }
int xQueueReceive(QueueHandle_t q, void *item, uint32_t t) { return 0; }
uint32_t dt_now_us(void) { return now_us; }
void dt_log(char level, const char *tag, const char *fmt, ...) {}
uint16_t last_vocab;
dt_step_class_t classify(const step_window_t *w, uint16_t vocab, uint8_t *c) { last_vocab = vocab; *c = next_conf; return next_cls; }
void h_schedule(int n, const uint16_t *beat_x100, const uint8_t *cls, uint16_t bpm_x10, uint32_t t0) {
    dt_sched_header_t h = {0}; h.bpm_x10 = bpm_x10; h.n_steps = n;
    judge_init(); judge_schedule_begin(&h);
    for (int i = 0; i < n; i++) { dt_sched_step_t s = { beat_x100[i], cls[i] }; judge_schedule_add(&s, 1); }
    judge_start(DT_MODE_DANCE, t0); }
void h_tick(uint32_t now) { now_us = now; check_missed(); }
void h_strike(uint32_t now, uint32_t t_strike, uint8_t cls, uint8_t conf) {
    now_us = now; static step_window_t w; w.t_strike_us = t_strike; next_cls = cls; next_conf = conf;
    judge_step(&w); }
int h_latency_ms(void) { return DETECT_LATENCY_MS; }
''',
}


def build():
    d = Path(tempfile.mkdtemp())
    for name, text in STUBS.items():
        (d / name).write_text(text)
    out = d / "judge.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-O1", "-o", str(out), str(d / "harness.c"), f"-I{d}", f"-I{SRC}"],
                   check=True)
    lib = ctypes.CDLL(str(out))
    lib.h_schedule.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint16, ctypes.c_uint32]
    lib.h_tick.argtypes = [ctypes.c_uint32]
    lib.h_strike.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint8, ctypes.c_uint8]
    return lib


class Ev(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("seq", ctypes.c_uint16), ("t", ctypes.c_uint32), ("cls", ctypes.c_uint8), ("conf", ctypes.c_uint8),
                ("expected", ctypes.c_uint8), ("err", ctypes.c_int16), ("verdict", ctypes.c_uint8)]


def events(lib):
    n = ctypes.c_int.in_dll(lib, "n_ev").value
    arr = (Ev * 512).in_dll(lib, "ev")
    return [(arr[i].verdict, arr[i].expected, arr[i].t, arr[i].err) for i in range(n)]


def run(lib, beats_s, strikes, bpm=60.0, t0=1_000_000, tick_ms=10):
    """beats_s: scheduled times (s, from t0) of class FORWARD; strikes: [(t_strike_s, t_arrive_s)]."""
    n = len(beats_s)
    beat_x100 = np.array([round((b * bpm / 60 + 1) * 100) for b in beats_s], dtype=np.uint16)
    cls = np.full(n, int(StepClass.FORWARD), dtype=np.uint8)
    lib.h_schedule(n, beat_x100.ctypes.data, cls.ctypes.data, int(bpm * 10), t0)
    ctypes.c_int.in_dll(lib, "n_ev").value = 0
    pending = sorted(strikes, key=lambda s: s[1])
    end = max([b for b in beats_s] + [s[1] for s in strikes]) + 2.0
    t = 0.0
    while t < end:
        while pending and pending[0][1] <= t:
            ts, _ = pending.pop(0)
            lib.h_strike(t0 + int(t * 1e6), t0 + int(ts * 1e6), int(StepClass.FORWARD), 200)
        lib.h_tick(t0 + int(t * 1e6))
        t += tick_ms / 1000
    return events(lib)


def test_late_strike_is_not_missed():
    lib = build()
    lat = lib.h_latency_ms() / 1000
    win2 = 0.300                                  # 2 × the default 150 ms window
    # Strike at the very edge of the match window, delivered with the full detection latency.
    for late in (0.0, 0.15, 0.29):
        ev = run(lib, [1.0], [(1.0 + late, 1.0 + late + lat - 0.06)])
        v = [e[0] for e in ev]
        assert MISSED not in v, (late, ev)
        assert v.count(CORRECT) + v.count(OFF_BEAT) == 1, (late, ev)
    # No strike at all: missed once, after 2 windows + the latency.
    ev = run(lib, [1.0], [])
    assert [e[0] for e in ev] == [MISSED]
    # ... and not before: a strike arriving just inside 2 windows + latency still counts.
    ev = run(lib, [1.0], [(1.0 + win2 - 0.005, 1.0 + win2 + lat - 0.015)])
    assert [e[0] for e in ev] == [OFF_BEAT], ev


def test_missed_step_is_not_matched_again():
    lib = build()
    lat = lib.h_latency_ms() / 1000
    # A strike arriving after the step was already given up is an extra, not a second verdict.
    ev = run(lib, [1.0], [(1.2, 1.0 + 0.3 + lat + 0.2)])
    assert [e[0] for e in ev] == [MISSED, EXTRA], ev


def test_classifier_gets_the_routine_classes():
    """Dance mode passes the schedule's classes to the classifier as a bit mask."""
    lib = build()
    classes = [StepClass.FORWARD_OUT, StepClass.BACK_IN, StepClass.FORWARD_OUT, StepClass.IN_PLACE]
    beat_x100 = np.array([100, 200, 300, 400], dtype=np.uint16)
    cls = np.array([int(c) for c in classes], dtype=np.uint8)
    lib.h_schedule(len(cls), beat_x100.ctypes.data, cls.ctypes.data, 600, 1_000_000)
    lib.h_strike(1_100_000, 1_000_000, int(StepClass.FORWARD_OUT), 200)
    want = sum(1 << int(c) for c in set(classes))
    assert ctypes.c_uint16.in_dll(lib, "last_vocab").value == want


def test_simulated_strikes_get_one_verdict_each():
    """Beats = the true landings of simulated routines (both simulators); strikes = the
    detector's anchors, delivered when the detector emits them. Every scheduled step
    gets exactly one verdict, and a step with a matching strike is never MISSED."""
    lib = build()
    emit_lag = node.NEW_DETECTOR.win_post / 104 + 0.01
    for k in range(3):
        sts = realsim.gen_routine((300 + k, realsim.AUD_REAL, {}, "judge"))
        for st in sts:
            fu = st["fused"]
            beats = [e["t_c"] - 1.0 for e in st["events"]]          # schedule starts at t0 (= stream 1.0 s)
            anchors = node.detect_swing(fu, node.NEW_DETECTOR)
            strikes = [(fu["t"][a] - 1.0, fu["t"][a] - 1.0 + emit_lag) for a in anchors if fu["t"][a] > 1.0]
            ev = run(lib, beats, strikes)
            per_step = {}
            for v, exp, t, err in ev:
                if v != EXTRA:
                    key = t - err * 1000 if v != MISSED else t
                    per_step.setdefault(round(key / 1e4), []).append(v)
            assert all(len(v) == 1 for v in per_step.values()), per_step
            assert len(per_step) == len(beats), (len(per_step), len(beats))


if __name__ == "__main__":
    test_late_strike_is_not_missed()
    test_missed_step_is_not_matched_again()
    test_simulated_strikes_get_one_verdict_each()
    print("judge ok")
