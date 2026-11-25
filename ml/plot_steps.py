#!/usr/bin/env python3
"""Plot a recorded session's foot-frame acceleration with each step's window as
the classifier sees it: where the detector fired, the landing it found, and the
start and end ZUPTs it integrates between (dt/baseline.py = rules.c).

Usage: plot_steps.py data/<training>/<run> [--foot L|R] [--page-s 10] [-o runs/plots/<run>]

Writes, per foot:
  timeline_<foot>_NN.png  the session in pages of --page-s seconds. Top: foot-frame
                          accel (+x toe, +y outward, +z up, gravity removed); bottom:
                          |gyro|. Each step's start..end ZUPT is shaded (green: the
                          call matches the label, red: it does not, grey: no label),
                          solid line = landing, dotted = where the detector fired,
                          text = label -> call and the measured displacement.
  steps_<foot>_NN.png     one panel per step: forward / outward accel over its
                          window, the start..end span, and the displacement those
                          integrate to (velocity de-drifted to zero at both ends,
                          as the classifier does; without its small shank-lever
                          term) — the curve whose end decides the direction.

The call shown is XGBoost's (runs/tablet/xgb, with the routine filter as in
dance mode) if a trained model is there, else the rule classifier's; the node's
own live call (events.csv step_class) is shown beside it.
"""
import argparse
import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

import label as L  # noqa: E402
from dt import baseline as B  # noqa: E402
from dt import windows as W  # noqa: E402
from dt.protocol import CLASS_NAMES  # noqa: E402
from features import FEATURES  # noqa: E402

NAMES = {int(v): k for k, v in CLASS_NAMES.items()}
HERE = Path(__file__).resolve().parent
MODEL = HERE / "runs/tablet/xgb"
G = 9.80665
DT = 1.0 / W.RATE_HZ
LSB_G = 8.0 / 127                       # foot-frame accel channels: 8 g full scale
COLORS = {"x": "#2563eb", "y": "#ea580c", "z": "#16a34a"}


def short(c: int) -> str:
    return NAMES.get(int(c), "?").replace("forward", "fwd").replace("_", " ") if c >= 0 else "-"


def displacement(w: np.ndarray, ch: int, s: int, e: int) -> np.ndarray:
    """Position (cm) from s to e: accel integrated twice, velocity de-drifted to 0 at e."""
    a = w[s + 1:e + 1, ch].astype(float) * LSB_G * G
    v = np.cumsum(a) * DT
    v -= np.arange(1, len(v) + 1) / len(v) * v[-1]
    return np.r_[0.0, np.cumsum(v) * DT * 100]


def classifier(preset_mask: int):
    """(name, fn(window, features, right) -> class) for the current model, else the rules."""
    try:
        import xgboost as xgb
        import export_xgb as E
        if not (MODEL / "model.json").exists():
            raise FileNotFoundError
        b = xgb.Booster()
        b.load_model(MODEL / "model.json")
        inputs = json.loads((MODEL / "meta.json").read_text())["inputs"]

        def call(w, f, right):
            x = np.array([[float(f[k]) for k in FEATURES.values()] + [float(right)]], dtype=np.float32)
            return E.board_call(b.predict(xgb.DMatrix(x, feature_names=inputs))[0], preset_mask)[0]
        return "xgb", call
    except (ImportError, FileNotFoundError):
        return "rules", lambda w, f, right: int(B.decide(f, vocab=preset_mask)[0])


def steps(d: Path, foot: str):
    meta = json.loads((d / "session.json").read_text())
    segs = L.segments(meta)
    ev = pd.read_csv(d / "events.csv", dtype={"foot": str, "label_source": str}, keep_default_na=False)
    ev["label_class"] = pd.to_numeric(ev["label_class"], errors="coerce").fillna(-1).astype(int)
    raw = W.load_stream(d / f"{foot}.csv")
    by_app = W.has_app_time(raw)
    if by_app:                       # newer exports: rows and strikes on the app's clock (ms)
        df = W.load_stream_frame(raw)
        t = df["t_app_ms"].to_numpy(float)
        t_ev = L.strike_app_ms(ev, meta, segs[0].t0_app_ms)
    else:                            # older / synthetic: the node's clock only (µs), as windows.py falls back to
        df = W._monotonic(raw).reset_index(drop=True)
        t_us = df["t_node_us"].to_numpy(np.int64)
        t = t_us / 1000.0
        rows = ev["foot"] == foot
        t_ev = pd.Series(float("nan"), index=ev.index)
        t_ev[rows] = W.unwrap_near(ev.loc[rows, "t_strike_node_us"].to_numpy(), int(t_us[0])) / 1000.0
    fa = W.foot_accel(df, foot)
    gyro = np.linalg.norm(df[["gx", "gy", "gz"]].to_numpy(float) / 10.0, axis=1)
    mask = 0
    for _, _, c in L.expand(L.load_preset(meta["preset_id"])):
        mask |= 1 << int(c)
    name, call = classifier(mask)
    out = []
    for i in ev.index[ev["foot"] == foot]:
        if pd.isna(t_ev[i]):
            continue
        w = W.cut_app(df, float(t_ev[i]), foot) if by_app else W.cut(df, int(round(t_ev[i] * 1000)), foot)
        if w is None:
            continue
        k = int(np.searchsorted(t, float(t_ev[i])))           # stream row of the strike = window row WIN_PRE
        f = B.features(w)
        row0 = k - W.WIN_PRE
        out.append(dict(w=w, f=f, t_strike=t[k], t_s=t[row0 + f["s"]], t_e=t[row0 + f["e"]], t_imp=t[row0 + f["imp"]],
                        t0=t[row0], label=int(ev.label_class[i]), node=int(pd.to_numeric(ev.step_class[i], errors="coerce")),
                        call=call(w, f, foot == "R")))
    return meta, name, t, fa, gyro, out


def timeline(meta, name, t, fa, gyro, st, foot, page_s, outdir):
    t_rel = (t - t[0]) / 1000
    pages = max(1, int(np.ceil(t_rel[-1] / page_s)))
    files = []
    for p in range(pages):
        lo, hi = p * page_s, (p + 1) * page_s
        k = (t_rel >= lo) & (t_rel < hi)
        if not k.any():
            continue
        fig, (ax, gx) = plt.subplots(2, 1, figsize=(16, 6.5), sharex=True, gridspec_kw={"height_ratios": [3, 1]})
        for j, c in enumerate("xyz"):
            ax.plot(t_rel[k], fa[k, j], lw=1, color=COLORS[c], label={"x": "forward (+toe)", "y": "outward", "z": "up"}[c])
        gx.plot(t_rel[k], gyro[k], lw=1, color="#555")
        ax.axhline(0, color="#999", lw=0.5)
        top = ax.get_ylim()[1]
        last_text, drop = -1e9, 0
        for s in st:
            a, b = (s["t_s"] - t[0]) / 1000, (s["t_e"] - t[0]) / 1000
            if b < lo or a > hi:
                continue
            col = "#9ca3af" if s["label"] < 0 else ("#22c55e" if s["call"] == s["label"] else "#ef4444")
            for axx in (ax, gx):
                axx.axvspan(a, b, color=col, alpha=0.18, lw=0)
                axx.axvline((s["t_imp"] - t[0]) / 1000, color=col, lw=1.2)
                axx.axvline((s["t_strike"] - t[0]) / 1000, color=col, lw=1, ls=":")
            drop = 0 if a - last_text > 0.9 or drop else 1      # stagger labels of close steps
            last_text = a
            ax.text(a, top - drop * 0.3 * (top - ax.get_ylim()[0]), f"{short(s['label'])} → {short(s['call'])}\nnode {short(s['node'])}\n"
                    f"dx {s['f']['dx_cm']:+.0f} dy {s['f']['dy_cm']:+.0f} cm",
                    fontsize=7.5, va="top", ha="left", color="#111")
        ax.set_ylabel("foot-frame accel (g)")
        gx.set_ylabel("|gyro| (dps)")
        gx.set_xlabel("seconds from the start of the recording")
        ax.set_xlim(lo, hi)
        ax.legend(loc="lower left", fontsize=8, ncol=3)
        ax.set_title(f"{meta['session_id']}  {meta['preset_name']}  {meta['bpm']:g} bpm  foot {foot}   "
                     f"shaded = start..end ZUPT (green right, red wrong, grey unlabelled), solid = landing, "
                     f"dotted = detector; label → {name} call", fontsize=9)
        fig.tight_layout()
        f = outdir / f"timeline_{foot}_{p + 1:02d}.png"
        fig.savefig(f, dpi=110)
        plt.close(fig)
        files.append(f)
    return files


def gallery(meta, name, st, foot, outdir, per_page=24):
    files = []
    x = (np.arange(W.WIN_LEN) - W.WIN_PRE) * DT * 1000
    for p in range(0, len(st), per_page):
        chunk = st[p:p + per_page]
        cols = 6
        rows = int(np.ceil(len(chunk) / cols))
        fig, axs = plt.subplots(rows, cols, figsize=(cols * 3.1, rows * 2.6), squeeze=False)
        for ax, s in zip(axs.ravel(), chunk):
            w, f = s["w"], s["f"]
            ax.plot(x, w[:, 6] * LSB_G, color=COLORS["x"], lw=1)
            ax.plot(x, w[:, 7] * LSB_G, color=COLORS["y"], lw=1)
            ax.axvspan(x[f["s"]], x[f["e"]], color="#facc15", alpha=0.2, lw=0)
            ax.axvline(x[f["imp"]], color="#111", lw=1)
            ax.axvline(0, color="#111", lw=0.8, ls=":")
            ax.set_ylim(-2, 2)
            ax2 = ax.twinx()
            xs = x[f["s"]:f["e"] + 1]
            ax2.plot(xs, displacement(w, 6, f["s"], f["e"]), color=COLORS["x"], lw=2.2, alpha=0.6)
            ax2.plot(xs, displacement(w, 7, f["s"], f["e"]), color=COLORS["y"], lw=2.2, alpha=0.6)
            ax2.axhline(0, color="#bbb", lw=0.5)
            ax2.set_ylim(-60, 60)
            ok = s["label"] < 0 or s["call"] == s["label"]
            ax.set_title(f"{short(s['label'])} → {short(s['call'])}   dx {f['dx_cm']:+.0f} dy {f['dy_cm']:+.0f}",
                         fontsize=8, color="#111" if ok else "#dc2626")
            ax.tick_params(labelsize=6)
            ax2.tick_params(labelsize=6)
        for ax in axs.ravel()[len(chunk):]:
            ax.axis("off")
        fig.suptitle(f"{meta['session_id']}  {meta['preset_name']}  foot {foot}: thin = accel forward (blue) / outward "
                     f"(orange), g, left axis; thick = displacement, cm, right axis; yellow = start..end ZUPT; "
                     f"solid = landing; dotted = detector; ms from the detector", fontsize=9)
        fig.tight_layout()
        out = outdir / f"steps_{foot}_{p // per_page + 1:02d}.png"
        fig.savefig(out, dpi=100)
        plt.close(fig)
        files.append(out)
    return files


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("session", help="a recorded run: data/<training>/<run> (session.json, events.csv, L.csv, R.csv)")
    ap.add_argument("--foot", choices=["L", "R"], help="one foot (default both)")
    ap.add_argument("--page-s", type=float, default=10.0)
    ap.add_argument("-o", "--out")
    a = ap.parse_args()
    d = Path(a.session)
    outdir = Path(a.out) if a.out else HERE / "runs/plots" / d.name
    outdir.mkdir(parents=True, exist_ok=True)
    for foot in [a.foot] if a.foot else ["L", "R"]:
        if not (d / f"{foot}.csv").exists():
            continue
        meta, name, t, fa, gyro, st = steps(d, foot)
        files = timeline(meta, name, t, fa, gyro, st, foot, a.page_s, outdir) + gallery(meta, name, st, foot, outdir)
        labelled = [s for s in st if s["label"] >= 0]
        right = sum(s["call"] == s["label"] for s in labelled)
        print(f"{foot}: {len(st)} steps, {right}/{len(labelled)} labelled steps called right ({name}); "
              f"{len(files)} images in {outdir}")


if __name__ == "__main__":
    sys.exit(main())
