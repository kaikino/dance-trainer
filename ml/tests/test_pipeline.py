"""label.py / windows.py on app-format sessions built in a tmp dir.

Covers: quaternions stored as int × 16384, session.json segments (rewind and
slow-down), the node's u32 µs clock wrapping mid-session, and skipping of
non-capture sessions and non-strike rows (step_class none, verdict missed), and
the newer export (t_app_ms column per row, clock_syncs, node reboot mid-session).
"""
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ml"))

import label  # noqa: E402
import synth  # noqa: E402
import windows as windows_script  # noqa: E402
from dt import windows as W  # noqa: E402
from dt.session import segments  # noqa: E402
from dt.protocol import StepClass, Verdict  # noqa: E402

U32 = 1 << 32
T0 = 1_794_489_273_171          # app ms of beat 1, first segment
BEAT96 = 60000 / 96
TILT = np.radians(25.0)         # board pitched on the strap: a non-identity quaternion
Q = (np.cos(TILT / 2), np.sin(TILT / 2), 0.0, 0.0)

# Preset 3 (presets/basic_step.json, 8-beat loop): L 1 forward, 2 R in_place,
# 3 L back, 5 R back, 6 L in_place, 7 R forward.
FWD, INP, BACK = int(StepClass.FORWARD), int(StepClass.IN_PLACE), int(StepClass.BACK)


def seg(from_beat, t0, bpm):
    return {"from_beat": float(from_beat), "t0_app_ms": t0, "bpm": bpm}


def beat_t(s, beat):
    return s["t0_app_ms"] + (beat - 1) * 60000 / s["bpm"]


def ev(foot, t_app_ms, step_class, label_class=-1, label_source="", verdict=Verdict.UNJUDGED):
    return dict(foot=foot, t_app_ms=t_app_ms, step_class=int(step_class), verdict=int(verdict),
                label_class=label_class, label_source=label_source)


def make_session(d: Path, events, segments, *, node_start_us=5_000_000, mode="capture",
                 scaled=True, seed=0, app_time=False, reboot_at_ms=None) -> Path:
    """An app-export session dir. Node clocks are written as raw u32 (wrapping when
    node_start_us + duration crosses 2^32); offset_us = node − app, as the app does.
    app_time: newer export with a t_app_ms column on stream and event rows and
    session.json clock_syncs. reboot_at_ms: both nodes reboot then (clock restarts
    at 2 s, no rows for 1 s, then a new sync and offset)."""
    d.mkdir(parents=True)
    rng = np.random.default_rng(seed)
    t_lo = min(e["t_app_ms"] for e in events) - 3000
    t_hi = max(e["t_app_ms"] for e in events) + 3000
    n = int((t_hi - t_lo) / 1000 * W.RATE_HZ)
    t_app = t_lo + np.arange(n) * 1000 / W.RATE_HZ
    nodes, syncs, offs = {}, [], {}
    for k, foot in enumerate(("L", "R")):
        start = node_start_us + k * 123_457
        off1 = int(start - round(t_lo * 1000))
        offs[foot] = [(t_lo, off1)]
        syncs.append({"foot": foot, "offset_us": off1, "fw_version": 3, "synced_at_app_ms": int(t_lo)})
        if reboot_at_ms is not None:
            off2 = int(2_000_000 + 7 * k - round(reboot_at_ms * 1000))
            offs[foot].append((reboot_at_ms, off2))
            syncs.append({"foot": foot, "offset_us": off2, "fw_version": 3, "synced_at_app_ms": int(reboot_at_ms + 1000)})
        off_at = lambda t, f=foot: [o for t0, o in offs[f] if t0 <= t][-1]
        t_node = np.array([round(ta * 1000) + off_at(ta) for ta in t_app], dtype=np.int64)
        # sensor accel = R^T g (mg), so the foot frame is ~0 once gravity is removed
        w, x, y, z = Q
        g = W._rotate(np.full(n, w), np.full(n, -x), np.full(n, -y), np.full(n, -z),
                      np.tile([[0.0, 0.0, 1000.0]], (n, 1)))
        g += rng.normal(0, 15, g.shape)
        for e in events:
            if e["foot"] == foot:
                i = int((e["t_app_ms"] - t_lo) / 1000 * W.RATE_HZ)
                g[i, 2] += 1500
        q = np.tile(np.array(Q), (n, 1))
        df = pd.DataFrame({
            "t_node_us": t_node % U32,
            "ax": g[:, 0].round().astype(int), "ay": g[:, 1].round().astype(int), "az": g[:, 2].round().astype(int),
            "gx": rng.integers(-50, 50, n), "gy": rng.integers(-50, 50, n), "gz": rng.integers(-50, 50, n),
        })
        for c, j in zip(("qw", "qx", "qy", "qz"), range(4)):
            df[c] = (q[:, j] * 16384).round().astype(int) if scaled else q[:, j]
        if app_time:
            df["t_app_ms"] = np.round(t_app, 1)
        if reboot_at_ms is not None:
            df = df[(t_app < reboot_at_ms) | (t_app >= reboot_at_ms + 1000)]
        df.to_csv(d / f"{foot}.csv", index=False)
        nodes[foot] = {"offset_us": offs[foot][-1][1], "fw_version": 3}
    rows = []
    for e in events:
        off = [o for t0, o in offs[e["foot"]] if t0 <= e["t_app_ms"]][-1]
        r = {"t_strike_node_us": (round(e["t_app_ms"] * 1000) + off) % U32, "foot": e["foot"],
             "step_class": e["step_class"], "confidence": 200, "expected_class": 0, "timing_err_ms": 0,
             "verdict": e["verdict"], "label_class": e["label_class"], "label_source": e["label_source"]}
        if app_time:
            r["t_app_ms"] = round(e["t_app_ms"], 1)
        rows.append(r)
    pd.DataFrame(rows).to_csv(d / "events.csv", index=False)
    meta = {
        "session_id": d.name, "dancer": "t", "preset_id": 3, "preset_name": "Basic forward and back",
        "bpm": 96.0, "mode": mode, "t0_app_ms": segments[0]["t0_app_ms"], "segments": segments,
        "nodes": nodes, "app_version": "test", "protocol_version": 1}
    if app_time:
        meta["clock_syncs"] = syncs
    (d / "session.json").write_text(json.dumps(meta))
    return d


def labels(d: Path) -> list[int]:
    return pd.read_csv(d / "events.csv")["label_class"].tolist()


# --- three segments: start, practice rewind to beat 9, slow-down from beat 13 ----
SEGS = [seg(1, T0, 96.0), seg(9, T0 + 5300, 96.0), seg(13, T0 + 15000 - 12 * 781.25, 76.8)]
SEG_EVENTS = [
    ev("L", beat_t(SEGS[0], 1) + 20, FWD), ev("R", beat_t(SEGS[0], 2) - 30, INP), ev("L", beat_t(SEGS[0], 3), BACK),
    ev("L", beat_t(SEGS[1], 9) + 10, FWD), ev("R", beat_t(SEGS[1], 10), INP), ev("L", beat_t(SEGS[1], 11) - 40, BACK),
    ev("R", beat_t(SEGS[2], 13) - 20, BACK), ev("L", beat_t(SEGS[2], 14) + 30, INP), ev("R", beat_t(SEGS[2], 15), FWD),
]
SEG_TRUTH = [FWD, INP, BACK, FWD, INP, BACK, BACK, INP, FWD]


# ---------------------------------------------------------------- bug 1 ----------
def test_foot_accel_reads_int_x16384_quaternions(tmp_path):
    d = make_session(tmp_path / "s", SEG_EVENTS[:3], SEGS[:1])
    df = pd.read_csv(d / "L.csv")
    assert df["qw"].abs().max() > 10000   # really the app's int format
    fa = W.foot_accel(df, "L")
    assert np.abs(fa).mean() < 0.05       # gravity removed, nothing saturated
    unit = df.assign(**{c: df[c] / 16384.0 for c in ("qw", "qx", "qy", "qz")})
    np.testing.assert_allclose(fa, W.foot_accel(unit, "L"), atol=1e-4)


def test_windows_foot_channels_not_saturated(tmp_path):
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS)
    label.label_session(d)
    xs, ys, _ = windows_script.session_windows(d)
    x = np.stack(xs)
    assert len(xs) == len(SEG_EVENTS)
    assert (np.abs(x[:, :, 6:9]) >= 127).mean() < 0.01


def test_synth_writes_app_format(tmp_path):
    preset = json.loads((ROOT / "presets/basic_step.json").read_text())
    synth.synth_session("d0", preset, 0, np.random.default_rng(0), tmp_path)
    d = next(tmp_path.iterdir())
    df = pd.read_csv(d / "L.csv")
    assert pd.api.types.is_integer_dtype(df["qw"]) and (df["qw"] == 16384).all()
    assert np.median(np.diff(df["t_node_us"])) == pytest.approx(1e6 / W.RATE_HZ, abs=1)
    label.label_session(d)
    xs, _, _ = windows_script.session_windows(d)
    assert len(xs) > 10 and (np.abs(np.stack(xs)[:, :, 6:9]) >= 127).mean() < 0.01


# ---------------------------------------------------------------- bug 2 ----------
def test_label_follows_segments(tmp_path):
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS)
    label.label_session(d)
    assert labels(d) == SEG_TRUTH


def test_label_ignoring_segments_would_be_wrong(tmp_path):
    """Guards the fixture: with only the first segment the rewind/slow-down strikes mislabel."""
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS[:1])
    label.label_session(d)
    assert labels(d) != SEG_TRUTH


def test_label_only_matches_beats_from_segment_start(tmp_path):
    # Rewind to beat 9 at a tempo where an L strike just after the restart is
    # 100 ms from beat 3 (L back) on the new timeline but the segment starts at 9.
    segs = [seg(1, T0, 96.0), seg(9, T0 + 6000, 96.0)]
    t = beat_t(segs[1], 9) - 200       # inside the segment (start = beat 9 − 250 ms)
    evs = [ev("L", beat_t(segs[0], 1), FWD), ev("L", t, FWD)]
    d = make_session(tmp_path / "s", evs, segs)
    label.label_session(d)
    assert labels(d) == [FWD, FWD]


def test_label_recomputes_app_capture_labels(tmp_path):
    """The app labels live without the dancer's lag: its labels are recomputed
    from the schedule (here, too few strikes to measure a lag: lag 0, ±MAX_MS).
    Manual labels are never touched."""
    evs = [dict(e) for e in SEG_EVENTS]
    evs[0].update(label_class=FWD, label_source="capture")     # agrees: stays
    evs[3].update(label_class=INP, label_source="capture")     # disagrees: corrected
    evs[4].update(label_class=BACK, label_source="manual")     # manual: untouched
    d = make_session(tmp_path / "s", evs, SEGS)
    label.label_session(d)
    e = pd.read_csv(d / "events.csv", keep_default_na=False)
    want = list(SEG_TRUTH)
    want[4] = BACK
    assert e["label_class"].tolist() == want
    assert e["label_source"].tolist()[:5] == ["capture", "capture", "capture", "capture", "manual"]
    label.label_session(d)                                       # idempotent
    assert labels(d) == want


# ---------------------------------------------------------------- bug 3 ----------
def test_unwrap_u32():
    t = np.array([U32 - 20, U32 - 10, 0, 10, 5, U32 - 5, 3])
    u = W.unwrap_u32(t)
    # a late pre-wrap sample (U32 - 5) stays before the wrap rather than jumping 2^32 ahead
    assert u.tolist() == [U32 - 20, U32 - 10, U32, U32 + 10, U32 + 5, U32 - 5, U32 + 3]
    # simple monotonic wrap
    assert W.unwrap_u32([U32 - 2, U32 - 1, 0, 1]).tolist() == [U32 - 2, U32 - 1, U32, U32 + 1]
    # idempotent on unwrapped data
    assert W.unwrap_u32([U32 - 1, U32, U32 + 1]).tolist() == [U32 - 1, U32, U32 + 1]


def test_pipeline_across_clock_wrap(tmp_path):
    # Node clock 3 s before the u32 wrap at the start of the stream: it wraps mid-session.
    a = make_session(tmp_path / "a", SEG_EVENTS, SEGS, node_start_us=1_000_000)
    b = make_session(tmp_path / "b", SEG_EVENTS, SEGS, node_start_us=U32 - 3_000_000)
    tb = pd.read_csv(b / "L.csv")["t_node_us"]
    assert (np.diff(tb) < 0).any()   # really wraps
    for d in (a, b):
        label.label_session(d)
    assert labels(a) == labels(b) == SEG_TRUTH
    xa, ya, _ = windows_script.session_windows(a)
    xb, yb, _ = windows_script.session_windows(b)
    assert len(xa) == len(xb) == len(SEG_EVENTS) and ya == yb
    np.testing.assert_array_equal(np.stack(xa), np.stack(xb))


def test_cut_raw_strike_on_wrapped_stream(tmp_path):
    b = make_session(tmp_path / "b", SEG_EVENTS, SEGS, node_start_us=U32 - 3_000_000)
    df = pd.read_csv(b / "R.csv")
    raw = pd.read_csv(b / "events.csv").query("foot == 'R'")["t_strike_node_us"].iloc[-1]
    assert raw < U32 // 2   # after the wrap
    w = W.cut(df, int(raw), "R")
    assert w is not None and w.shape == (W.WIN_LEN, 9)


def test_windows_main_no_windows(tmp_path, monkeypatch):
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS, mode="dance")
    monkeypatch.setattr(sys, "argv", ["windows.py", str(d), "-o", str(tmp_path / "w.npz")])
    with pytest.raises(SystemExit, match="no windows"):
        windows_script.main()


# ---------------------------------------------------------------- bug 5 ----------
def test_skip_non_capture_session(tmp_path):
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS, mode="dance")
    before = (d / "events.csv").read_text()
    label.label_session(d)
    assert (d / "events.csv").read_text() == before
    xs, _, _ = windows_script.session_windows(d)
    assert xs == []


def test_skip_missed_rows_keep_none_strikes(tmp_path):
    evs = [dict(e) for e in SEG_EVENTS]
    evs[1].update(step_class=StepClass.NONE)
    evs[2].update(step_class=StepClass.NONE, verdict=Verdict.MISSED)
    evs[5].update(verdict=Verdict.MISSED)
    d = make_session(tmp_path / "s", evs, SEGS)
    label.label_session(d)
    got = labels(d)
    # A strike the node called "none" is real and keeps its schedule label; missed beats are skipped.
    assert got[1] == SEG_TRUTH[1]
    assert [got[i] for i in (2, 5)] == [-1, -1]
    xs, ys, _ = windows_script.session_windows(d)
    keep = [i for i in range(len(evs)) if i not in (2, 5)]
    assert sorted(ys) == sorted(SEG_TRUTH[i] for i in keep)   # windows come grouped by foot


# ------------------------------------- newer export: t_app_ms column, clock_syncs ----------
def test_app_time_columns_match_old_format(tmp_path):
    a = make_session(tmp_path / "a", SEG_EVENTS, SEGS, node_start_us=U32 - 3_000_000)
    b = make_session(tmp_path / "b", SEG_EVENTS, SEGS, node_start_us=U32 - 3_000_000, app_time=True)
    assert "t_app_ms" in pd.read_csv(b / "events.csv").columns
    for d in (a, b):
        label.label_session(d)
    assert labels(a) == labels(b) == SEG_TRUTH
    assert "t_app_ms" in pd.read_csv(b / "events.csv").columns   # label.py keeps the column
    xa, ya, _ = windows_script.session_windows(a)
    xb, yb, _ = windows_script.session_windows(b)
    assert ya == yb and len(xb) == len(SEG_EVENTS)
    np.testing.assert_array_equal(np.stack(xa), np.stack(xb))


REBOOT = T0 + 8000   # between beat 3 (first segment) and beat 9 (after the rewind)


def test_node_reboot_with_app_time(tmp_path):
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS, app_time=True, reboot_at_ms=REBOOT)
    t = pd.read_csv(d / "L.csv")["t_node_us"]
    assert (np.diff(t) < 0).any()   # the node clock restarted
    label.label_session(d)
    assert labels(d) == SEG_TRUTH
    xs, ys, _ = windows_script.session_windows(d)
    assert sorted(ys) == sorted(SEG_TRUTH)   # grouped by foot, so compare as multisets
    assert (np.abs(np.stack(xs)[:, :, 6:9]) >= 127).mean() < 0.01


def test_label_falls_back_to_clock_syncs(tmp_path):
    """Rows without t_app_ms are timed from the node clock with the offset of the
    clock sync current at the time, not the last offset in nodes."""
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS, app_time=True, reboot_at_ms=REBOOT)
    e = pd.read_csv(d / "events.csv")
    e["t_app_ms"] = np.nan
    e.to_csv(d / "events.csv", index=False)
    label.label_session(d)
    assert labels(d) == SEG_TRUTH


def test_cut_app_rejects_window_over_gap(tmp_path):
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS, app_time=True, reboot_at_ms=REBOOT)
    df = W.load_stream(d / "L.csv")
    assert W.cut_app(df, REBOOT + 1000 + 200, "L") is None   # window reaches back into the gap
    assert W.cut_app(df, REBOOT + 1000 + 2000, "L") is not None


def test_window_with_empty_gyro_cells_skipped(tmp_path):
    """Older exports flushed half batches (accel, empty gyro): no NaN windows."""
    d = make_session(tmp_path / "s", SEG_EVENTS, SEGS)
    df = pd.read_csv(d / "L.csv")
    t = W.unwrap_near(pd.read_csv(d / "events.csv").query("foot == 'L'")["t_strike_node_us"], int(df["t_node_us"][0]))[0]
    i = int(np.searchsorted(df["t_node_us"], t))
    assert W.cut(df, int(t), "L") is not None
    df.loc[i - 3 : i + 1, ["gx", "gy", "gz"]] = np.nan
    assert W.cut(df, int(t), "L") is None


# ------------------------------------------------- session that never started -----
def test_session_that_never_started_is_skipped(tmp_path, capsys):
    """An app session ended before the music started: t0_app_ms null, no segments."""
    from dt.session import segments
    meta = {"session_id": "x", "mode": "capture", "preset_id": 3, "bpm": 96.0,
            "t0_app_ms": None, "segments": []}
    assert segments(meta) == []
    assert segments({**meta, "segments": [{"from_beat": 1, "t0_app_ms": None, "bpm": 96}]}) == []
    d = tmp_path / "s"
    d.mkdir()
    (d / "session.json").write_text(json.dumps(meta))
    header = ("t_strike_node_us,foot,step_class,confidence,expected_class,timing_err_ms,verdict,"
              "label_class,label_source,t_app_ms\n")
    (d / "events.csv").write_text(header)
    label.label_session(d)
    assert "skipped" in capsys.readouterr().out
    assert (d / "events.csv").read_text() == header



# ---------------------------------------------------------------- late dancers ---
# basic_step.json (id 3): L forward 1, R in_place 2, L back 3, R back 5,
# L in_place 6, R forward 7; 8 beats a loop. At 96 bpm a beat is 625 ms.
BASIC = [(1, "L", FWD), (2, "R", INP), (3, "L", BACK), (5, "R", BACK), (6, "L", INP), (7, "R", FWD)]


def late_session(tmp_path, lag_ms: dict, loops: int = 3, called=None):
    """Every step danced `lag_ms[foot]` late, with a little jitter."""
    segs = [seg(1, T0, 96.0)]
    rng = np.random.default_rng(1)
    evs, truth = [], []
    for k in range(loops):
        for b, f, cls in BASIC:
            t = beat_t(segs[0], b + 8 * k) + lag_ms[f] + rng.uniform(-40, 40)
            evs.append(ev(f, t, called if called is not None else cls))
            truth.append(cls)
    order = np.argsort([e["t_app_ms"] for e in evs], kind="stable")
    return make_session(tmp_path / "s", [evs[i] for i in order], segs), [truth[i] for i in order]


def test_late_dancer_is_labelled_against_the_measured_lag(tmp_path):
    # 300 ms late is outside the ±250 ms window round the beat: before the lag
    # was measured these all came out -1.
    d, truth = late_session(tmp_path, {"L": 300, "R": 300})
    label.label_session(d)
    assert labels(d) == truth


def test_lag_is_measured_per_foot(tmp_path):
    # One foot late, the other on time (separately synced clocks, say).
    d, truth = late_session(tmp_path, {"L": 280, "R": 0})
    label.label_session(d)
    assert labels(d) == truth


def test_lag_comes_from_timing_not_from_what_the_node_called(tmp_path):
    # The node calls every step "kick": the labels still follow the schedule.
    d, truth = late_session(tmp_path, {"L": 250, "R": 250}, called=int(StepClass.KICK))
    label.label_session(d)
    assert labels(d) == truth


def test_estimate_lag_finds_the_shift(tmp_path):
    segs = segments({"segments": [seg(1, T0, 96.0)], "bpm": 96.0})
    sched = [(b + 8 * k, f, c) for k in range(3) for b, f, c in BASIC]
    times = [beat_t(seg(1, T0, 96.0), b) + 220 for b, f, _ in sched if f == "L"]
    assert label.estimate_lag(sched, segs, "L", times) == pytest.approx(220, abs=LAG_STEP)
    assert label.estimate_lag(sched, segs, "L", times[:3]) is None   # too few to measure


LAG_STEP = label.LAG_STEP_MS


# ---------------------------------------------------------------- uneven streams ---
def stream_csv(path: Path, t_ms: np.ndarray) -> Path:
    """A capture stream sampled at the given app times: smooth accel and gyro,
    a quaternion turning slowly about z, in the app's integer units."""
    s = t_ms / 1000.0
    ang = 0.3 * np.sin(2 * np.pi * 0.5 * s)
    df = pd.DataFrame({
        "t_node_us": np.rint(5_000_000 + (t_ms - t_ms[0]) * 1000).astype(np.int64),
        "ax": np.rint(300 * np.sin(2 * np.pi * 2 * s)).astype(int),
        "ay": np.rint(200 * np.cos(2 * np.pi * 3 * s)).astype(int),
        "az": np.rint(1000 + 50 * np.sin(2 * np.pi * s)).astype(int),
        "gx": np.rint(800 * np.sin(2 * np.pi * 1.5 * s)).astype(int),
        "gy": np.rint(600 * np.cos(2 * np.pi * 2.5 * s)).astype(int),
        "gz": np.rint(400 * np.sin(2 * np.pi * 0.7 * s)).astype(int),
        "qw": np.rint(16384 * np.cos(ang / 2)).astype(int), "qx": 0, "qy": 0,
        "qz": np.rint(16384 * np.sin(ang / 2)).astype(int),
        "t_app_ms": np.round(T0 + t_ms, 1),
    })
    df.to_csv(path, index=False)
    return path


PERIOD = 1000.0 / W.RATE_HZ


def test_dropped_samples_are_filled_so_windows_survive(tmp_path):
    # The right node on the tablet lost about one sample in twenty: every window
    # spanned too long and cut_app() dropped all of them.
    full = np.arange(0, 6000, PERIOD)
    kept = np.delete(full, np.arange(10, len(full), 20))
    df = W.load_stream(stream_csv(tmp_path / "R.csv", kept))
    t = df["t_app_ms"].to_numpy()
    assert df.attrs.get("resampled_from_hz")
    assert np.allclose(np.diff(t), PERIOD, atol=0.05)              # evenly spaced again
    raw = pd.read_csv(tmp_path / "R.csv")
    assert W.cut_app(raw, T0 + 3000, "R") is None                   # as recorded: rejected
    w = W.cut_app(df, T0 + 3000, "R")
    assert w is not None
    ref = W.load_stream(stream_csv(tmp_path / "full.csv", full))   # what it would have been
    np.testing.assert_allclose(w.astype(int), W.cut_app(ref, T0 + 3000, "R").astype(int), atol=2)


def test_a_real_gap_is_kept_not_filled(tmp_path):
    t = np.concatenate([np.arange(0, 3000, PERIOD), np.arange(3400, 6000, PERIOD)])
    t = np.delete(t, [5, 50])                                       # two dropped samples too
    df = W.load_stream(stream_csv(tmp_path / "R.csv", t))
    tt = df["t_app_ms"].to_numpy() - T0
    assert not ((tt > 3000) & (tt < 3400)).any()                    # nothing invented in the gap
    assert W.cut_app(df, T0 + 3100, "R") is None                    # a window across it is dropped


def test_even_stream_is_left_alone(tmp_path):
    t = np.arange(0, 3000, PERIOD)
    path = stream_csv(tmp_path / "L.csv", t)
    df = W.load_stream(path)
    assert "resampled_from_hz" not in df.attrs
    pd.testing.assert_frame_equal(df.reset_index(drop=True)[["ax", "gz", "qw"]],
                                  pd.read_csv(path)[["ax", "gz", "qw"]])


def test_stream_at_another_rate_is_put_on_the_104_hz_grid(tmp_path):
    df = W.load_stream(stream_csv(tmp_path / "R.csv", np.arange(0, 3000, 10.0)))   # 100 Hz
    assert df.attrs["resampled_from_hz"] == pytest.approx(100, abs=0.5)
    assert W.stream_rate_hz(df) == pytest.approx(W.RATE_HZ, rel=0.001)
    q = df[["qw", "qx", "qy", "qz"]].to_numpy() / 16384.0
    assert np.allclose(np.linalg.norm(q, axis=1), 1, atol=2e-4)     # still unit quaternions


def test_features_table_has_one_row_per_window(tmp_path):
    import features
    preset = json.loads((ROOT / "presets/basic_step.json").read_text())
    synth.synth_session("d0", preset, 0, np.random.default_rng(0), tmp_path)
    d = next(tmp_path.iterdir())
    label.label_session(d)
    xs, ys, meta = windows_script.session_windows(d)
    assert len(meta["window_feet"]) == len(xs) and set(meta["window_feet"]) <= {"L", "R"}
    npz = {"x": np.stack(xs), "y": np.array(ys), "dancer": np.array(["d0"] * len(xs)),
           "session": np.array([d.name] * len(xs)), "foot": np.array(meta["window_feet"])}
    df = features.table(npz)
    assert len(df) == len(xs)
    assert list(df.columns[:8]) == list(features.FEATURES)
    assert df[list(features.FEATURES)].notna().all().all()
    assert set(df.label_name) <= {"forward", "back", "in_place"}       # basic step's classes
    assert set(df.foot) == {"L", "R"}


def test_routine_mask_has_one_bit_per_step_type():
    # Routines repeat their steps: adding 1 << class for each step carried into
    # the next bit (side to side came out as forward, cross, forward out).
    import train_xgb
    from dt.protocol import StepClass as S
    assert train_xgb.masked_argmax(np.array([0.1, 0.2, 0.7]), 0b011) == 1
    preset = json.loads((ROOT / "presets/side_step.json").read_text())
    want = (1 << int(S.SIDE_OUT)) | (1 << int(S.SIDE_IN)) | (1 << int(S.IN_PLACE))
    d = train_xgb.DATA / "_test_mask" / "s1"
    d.mkdir(parents=True, exist_ok=True)
    try:
        (d / "session.json").write_text(json.dumps({"preset_id": preset["id"]}))
        assert train_xgb.routine_mask("s1") == want
    finally:
        (d / "session.json").unlink()
        d.rmdir()
        d.parent.rmdir()
