#!/usr/bin/env python3
"""Fill label_class in events.csv from the preset schedule (capture sessions).

Usage: label.py data/<session> [data/<session> ...]

The beat timeline comes from session.json `segments` (one per start of the
nodes: practice rewind, slow-down, resume). Each strike belongs to the last
segment that started before it (a segment starts at its from_beat, less MAX_MS)
and is matched to the nearest scheduled beat for that foot with beat >= the
segment's from_beat, at the segment's bpm, within ±MAX_MS. No match → -1.

Existing labels:
- label_source == manual: never touched.
- label_source == capture (the app labelled it live): kept when it agrees with
  the schedule here. When it disagrees the row is set to -1 with label_source
  = conflict (the app labels against whichever segment was current when the
  event arrived, so a disagreement means an ambiguous strike near a segment
  change); conflict rows are left alone on later runs.
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


def schedule_label(sched, segs, foot: str, t_app_ms: float) -> int:
    seg = segment_at(segs, t_app_ms, MAX_MS)
    best, best_d = -1, None
    for beat, f, cls in sched:
        if f != foot or beat < seg.from_beat:
            continue
        d_ms = abs(t_app_ms - seg.beat_time_ms(beat))
        if d_ms <= MAX_MS and (best_d is None or d_ms < best_d):
            best, best_d = int(cls), d_ms
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

    n_conflict = 0
    for i, row in ev.iterrows():
        src = row.get("label_source", "")
        if src in ("manual", "conflict") or not usable[i] or pd.isna(t_app[i]):
            continue
        ours = schedule_label(sched, segs, row["foot"], t_app[i])
        if src == "capture" and row["label_class"] >= 0:
            if ours != row["label_class"]:
                ev.at[i, "label_class"] = -1
                ev.at[i, "label_source"] = "conflict"
                n_conflict += 1
            continue
        ev.at[i, "label_class"] = ours
        ev.at[i, "label_source"] = "capture" if ours >= 0 else ""

    ev.to_csv(d / "events.csv", index=False)
    n_ok = (ev["label_class"] >= 0).sum()
    print(f"{d.name}: {n_ok}/{len(ev)} labeled" + (f", {n_conflict} disagree with the app's label (set -1)" if n_conflict else ""))


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        label_session(Path(arg))
