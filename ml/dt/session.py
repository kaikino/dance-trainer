"""Reading recorded sessions (docs/data-format.md): which sessions and events are
usable for training, and the beat timeline from session.json segments."""
from dataclasses import dataclass

import pandas as pd

from dt.protocol import StepClass, Verdict


def is_capture(meta: dict) -> bool:
    """Only capture sessions carry schedule labels; dance/idle sessions are skipped."""
    return meta.get("mode", "capture") == "capture"


def usable_events(ev: pd.DataFrame) -> pd.Series:
    """Rows that are real strikes: not a node-synthesised missed beat (verdict ==
    missed, at the scheduled time rather than a strike). A strike the node's
    classifier called "none" is still a real strike and keeps its schedule label."""
    vd = pd.to_numeric(ev["verdict"], errors="coerce").fillna(Verdict.UNJUDGED).astype(int)
    return vd != Verdict.MISSED


@dataclass(frozen=True)
class Segment:
    from_beat: float
    t0_app_ms: float   # app time of (virtual) beat 1 at this segment's tempo
    bpm: float

    @property
    def beat_ms(self) -> float:
        return 60000.0 / self.bpm

    def beat_time_ms(self, beat: float) -> float:
        return self.t0_app_ms + (beat - 1) * self.beat_ms

    def start_ms(self, margin_ms: float = 0.0) -> float:
        """When this segment takes over: its first beat, less a margin so an early
        strike on that beat still belongs to it."""
        return self.beat_time_ms(self.from_beat) - margin_ms


def segments(meta: dict) -> list[Segment]:
    """session.json `segments` (one per start: practice rewind, slow-down, resume),
    or a single segment from the top-level t0_app_ms/bpm for older sessions.
    Empty when the session never started (t0_app_ms null, no segments): callers
    skip such a session, it has no beat timeline."""
    segs = [Segment(float(s.get("from_beat", 1)), float(s["t0_app_ms"]), float(s.get("bpm", meta["bpm"])))
            for s in meta.get("segments") or [] if s.get("t0_app_ms") is not None]
    if not segs and meta.get("t0_app_ms") is not None:
        segs = [Segment(1.0, float(meta["t0_app_ms"]), float(meta["bpm"]))]
    return segs


def segment_at(segs: list[Segment], t_app_ms: float, margin_ms: float = 0.0) -> Segment:
    """The last segment starting at or before t_app_ms (the first if none has)."""
    cur = segs[0]
    for s in segs:
        if s.start_ms(margin_ms) <= t_app_ms:
            cur = s
    return cur


def offset_us(meta: dict, foot: str) -> int | None:
    """Last node clock offset (node µs − app µs) for `foot`: nodes.<foot>.offset_us,
    else the last clock_syncs entry for it."""
    node = (meta.get("nodes") or {}).get(foot) or {}
    if node.get("offset_us") is not None:
        return int(node["offset_us"])
    syncs = [s for s in meta.get("clock_syncs") or [] if s.get("foot") == foot and s.get("offset_us") is not None]
    return int(syncs[-1]["offset_us"]) if syncs else None
