#!/usr/bin/env python3
"""Fill label_class in events.csv from the preset schedule (capture sessions).

Usage: label.py data/<session> [data/<session> ...]

The beat timeline comes from session.json `segments` (one per start of the
nodes: practice rewind, slow-down, resume). Each strike belongs to the last
segment that started before it (a segment starts at its from_beat, less MAX_MS)
and is matched to the nearest scheduled beat for that foot with beat >= the
segment's from_beat, at the segment's bpm. No match → -1.

Dancers land late, and by a steady amount: on the tablet recordings the left
foot's strikes came 175–290 ms after the beat, run after run (the sound comes
out later than the app assumes, and people land just behind what they hear).
A fixed window round the beat then drops the late steps and, where one foot
steps on consecutive beats, can give a strike the next beat's step. So each
foot's lag is measured per session first (estimate_lag: the shift that lines
up the most strikes with their beats, from timing alone, never from what the
node called) and strikes are matched within ±LAG_TOL_MS of beat + lag. With
fewer than LAG_MIN_STRIKES strikes for a foot there is too little to measure:
lag 0 and ±MAX_MS, as before.

Existing labels:
- label_source == manual: never touched.
- label_source == capture or conflict (the app's live label, or an older run
  of this script): recomputed here. The app labels live against the nearest
  beat without knowing the dancer's lag, so where the two differ the schedule
  match with the measured lag is the one to trust.
- Node-synthesised missed beats (verdict == missed) are left as they are;
  windows.py skips them. A strike the node called "none" is still labelled.
Sessions whose mode is not capture are skipped. A strike's app time is the
events.csv t_app_ms column when present (newer exports); otherwise it is
rebuilt from the u32 node time (wrap-safe) and the clock offset.
"""
import json
import sys
from pathlib import Path

import pandas as pd

from dt.protocol import CLASS_NAMES
from dt.session import is_capture, offset_us, segment_at, segments, usable_events
from dt.windows import u32_delta

MAX_MS = 250

# Per-session lag (see the module doc): searched over LAG_RANGE_MS in
# LAG_STEP_MS steps, matched within ±LAG_TOL_MS of beat + lag.
LAG_RANGE_MS = (-200, 400)
LAG_STEP_MS = 5
LAG_TOL_MS = 150
LAG_MIN_STRIKES = 6
PRESETS = Path(__file__).resolve().parent.parent / "presets"


def load_preset(preset_id: int) -> dict:
    for p in PRESETS.glob("*.json"):
        j = json.loads(p.read_text())
        if j["id"] == preset_id:
            return j
    raise SystemExit(f"preset {preset_id} not found in {PRESETS}")


def expand(preset: dict) -> list[tuple[float, str, int]]:
    steps = preset["steps"]
    span = preset.get("length_beats") or max(s["beat"] for s in steps)
    reps = preset.get("repeats", 1) if preset.get("loop") else 1
    return [(s["beat"] + r * span, s["foot"], CLASS_NAMES[s["class"]]) for r in range(reps) for s in steps]


def strike_app_ms(ev: pd.DataFrame, meta: dict, ref_app_ms: float) -> pd.Series:
    """App time (ms) of each strike. Newer exports give it per row (t_app_ms,
    timed by the app with the node's offset at that moment); rows without it, and
    older sessions, are reconstructed from the node time: per foot, in file order
    (the app writes events sorted by app time), through the signed u32 difference
    from the previous strike (wrap-safe), with the offset from clock_syncs that
    was current then (or nodes.<foot>.offset_us)."""
    given = (pd.to_numeric(ev["t_app_ms"], errors="coerce") if "t_app_ms" in ev.columns
             else pd.Series(float("nan"), index=ev.index))
    out = given.astype(float).copy()
    for foot, rows in ev.groupby("foot", sort=False):
        ref = float(ref_app_ms)
        for i, t in rows["t_strike_node_us"].items():
            if pd.notna(given[i]):
                ref = float(given[i])
                continue
            t_app = _node_to_app_ms(meta, foot, int(t), ref)
            if t_app is None:
                continue
            ref = out[i] = t_app
    return out


def _node_to_app_ms(meta: dict, foot: str, t_node_us: int, ref_app_ms: float) -> float | None:
    """App time of a node time, placed within ±35 min of ref_app_ms (the previous
    strike of this foot). With several clock_syncs for the foot (a reconnect,
    maybe after a reboot that restarted the node clock), each sync's offset gives
    a candidate; the earliest one that is not before the previous strike (1 s
    slack) and not before its own sync is taken. Without clock_syncs:
    nodes.<foot>.offset_us."""
    syncs = [s for s in meta.get("clock_syncs") or [] if s.get("foot") == foot and s.get("offset_us") is not None]
    cands = []
    for k, s in enumerate(syncs):
        t = _shift(t_node_us, ref_app_ms, int(s["offset_us"]))
        if t >= ref_app_ms - 1000 and (k == 0 or t >= s.get("synced_at_app_ms", float("-inf"))):
            cands.append(t)
    if cands:
        return min(cands)
    off = offset_us(meta, foot)
    return None if off is None else _shift(t_node_us, ref_app_ms, off)


def _shift(t_node_us: int, ref_app_ms: float, off: int) -> float:
    return ref_app_ms + float(u32_delta(t_node_us, round(ref_app_ms * 1000) + off)) / 1000.0


def nearest_beat(sched, segs, foot: str, t_app_ms: float) -> tuple[int, float | None]:
    """The class scheduled at the nearest beat for `foot` in the strike's
    segment, and its distance in ms (None when that foot has no beat there)."""
    seg = segment_at(segs, t_app_ms, MAX_MS)
    best, best_d = -1, None
    for beat, f, cls in sched:
        if f != foot or beat < seg.from_beat:
            continue
        d_ms = abs(t_app_ms - seg.beat_time_ms(beat))
        if best_d is None or d_ms < best_d:
            best, best_d = int(cls), d_ms
    return best, best_d


def schedule_label(sched, segs, foot: str, t_app_ms: float, lag_ms: float = 0.0, tol_ms: float = MAX_MS) -> int:
    """The scheduled class whose beat, `lag_ms` later, is within `tol_ms` of the strike; -1 if none."""
    cls, d = nearest_beat(sched, segs, foot, t_app_ms - lag_ms)
    return cls if d is not None and d <= tol_ms else -1


def estimate_lag(sched, segs, foot: str, times: list[float]) -> float | None:
    """How late `foot` lands after its beats in this session (ms, + = late):
    the shift that puts the most strikes within ±LAG_TOL_MS of a beat, ties
    going to the one with the smallest median distance. Timing only: what the
    node called is never used, so the labels do not inherit its mistakes.
    None with fewer than LAG_MIN_STRIKES strikes."""
    if len(times) < LAG_MIN_STRIKES:
        return None
    best, best_key = None, None
    for lag in range(LAG_RANGE_MS[0], LAG_RANGE_MS[1] + 1, LAG_STEP_MS):
        ds = [d for t in times if (d := nearest_beat(sched, segs, foot, t - lag)[1]) is not None]
        if not ds:
            continue
        key = (sum(d <= LAG_TOL_MS for d in ds), -sorted(ds)[len(ds) // 2])
        if best_key is None or key > best_key:
            best, best_key = float(lag), key
    return best


def label_session(d: Path) -> None:
    meta = json.loads((d / "session.json").read_text())
    if not is_capture(meta):
        print(f"{d.name}: mode {meta.get('mode')!r}, skipped")
        return
    segs = segments(meta)
    if not segs:
        print(f"{d.name}: no beat timeline (the session never started), skipped")
        return
    ev = pd.read_csv(d / "events.csv", dtype={"label_source": str, "foot": str}, keep_default_na=False)
    ev["label_class"] = pd.to_numeric(ev["label_class"], errors="coerce").fillna(-1).astype(int)
    sched = expand(load_preset(meta["preset_id"]))
    t_app = strike_app_ms(ev, meta, segs[0].t0_app_ms)
    usable = usable_events(ev)

    # Each foot's lag, from its usable strikes.
    lags: dict[str, float | None] = {}
    for foot in ("L", "R"):
        times = [t_app[i] for i in ev.index if ev.at[i, "foot"] == foot and usable[i] and not pd.isna(t_app[i])]
        lags[foot] = estimate_lag(sched, segs, foot, times)

    n_changed = 0
    for i, row in ev.iterrows():
        src = row.get("label_source", "")
        if src == "manual" or not usable[i] or pd.isna(t_app[i]):
            continue
        lag = lags.get(row["foot"])
        ours = (schedule_label(sched, segs, row["foot"], t_app[i]) if lag is None
                else schedule_label(sched, segs, row["foot"], t_app[i], lag, LAG_TOL_MS))
        if src in ("capture", "conflict") and row["label_class"] != ours:
            n_changed += 1
        ev.at[i, "label_class"] = ours
        ev.at[i, "label_source"] = "capture" if ours >= 0 else ""

    ev.to_csv(d / "events.csv", index=False)
    n_ok = (ev["label_class"] >= 0).sum()
    lag_txt = ", ".join(f"{f} {'n/a' if v is None else f'{v:+.0f} ms'}" for f, v in lags.items())
    print(f"{d.name}: {n_ok}/{len(ev)} labeled (lag {lag_txt})"
          + (f", {n_changed} app labels corrected" if n_changed else ""))


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        label_session(Path(arg))
