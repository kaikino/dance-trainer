#!/usr/bin/env python3
"""Train the CNN on simulated feet until real recordings exist.

Both simulators (dt/footsim.py, the author's; dt/legsim.py, the auditor's,
routines and stress conditions) are run through the firmware pipeline
(dt/node.py: Madgwick, bias tracking, foot frame, swing detector, int8 window),
so the CNN sees exactly the windows the node would cut. Each window is labelled
with the step it matches (realsim.py's rule: anchor within -0.15..+0.25 s of
the landing, kicks from lift-off); a window matching no step is labelled none.

Training seeds (11..) never overlap realsim's dev (1) and held-out (2) seeds.
Reported:
  - leave-one-simulator-out: train on one simulator, test on the other. This is
    the honest number: real feet are a third, unseen "simulator".
  - realsim scoring on held-out seed 2 (author, auditor, stress, mixed), CNN vs
    the rule, same detector, so only classification differs.

THE RESULT IS A SIMULATION-TRAINED MODEL. Replace it with ml/train.py on real
windows as soon as recordings exist (docs/bench-check.md, Capture mode).

Result (30 epochs, 4773 windows), held-out seed 2, mixed sets:
  both simulators in training     rule 80.7%  cnn 81.8%  hybrid 84.8%
  CNN never saw that simulator    rule 75.2%  cnn 51.0%  hybrid 70.5%
Real feet are the second case, so the firmware default stays the rule.

Usage:
  simtrain.py [--epochs 30] [--scale 1]     writes runs/sim_windows.npz, runs/model_sim.keras
  cp runs/model_sim.keras runs/model.keras; cp runs/sim_windows.npz runs/windows.npz
  export.py runs/model.keras runs/windows.npz   (then make CLASSIFIER=cnn)
"""
import argparse
import os
from multiprocessing import Pool

import numpy as np

import realsim as RS
from dt import baseline, node
from dt.protocol import StepClass

NONE = int(StepClass.NONE)
TRAIN_SEEDS = (11, 12, 13)
HELD_OUT_SEED = 2


def windows_of(s):
    """(x int8 windows, labels, anchor times) for one stream; cls None events are skipped."""
    fu, right = s["fused"], s["right"]
    t = fu["t"]
    det = node.NEW_DETECTOR
    anchors = node.detect_swing(fu, det)
    wins = [node.cut(fu, a, right, det.win_pre, det.win_post) for a in anchors]
    label = [None] * len(anchors)
    used = set()
    for ev in sorted(s["events"], key=lambda e: e["t_c"]):
        cand = [i for i, a in enumerate(anchors) if i not in used and ev["lo"] <= t[a] <= ev["t_c"] + 0.25]
        if cand:
            i = min(cand, key=lambda i: abs(t[anchors[i]] - ev["t_c"]))
            used.add(i)
            label[i] = "skip" if ev["cls"] is None else ev["cls"]
    xs, ys = [], []
    for i, (a, w) in enumerate(zip(anchors, wins)):
        if w is None or label[i] == "skip":
            continue
        if label[i] is None:
            if t[a] <= s["extra_from"]:
                continue
            label[i] = NONE
        xs.append(w)
        ys.append(label[i])
    return xs, ys


def dataset(pool, sets):
    """sets: [(name, n, seed)] -> x (N,140,9) int8, y, sim ('foot'|'leg')."""
    X, Y, G = [], [], []
    for name, n, seed in sets:
        st = RS.streams(pool, name, n, seed)
        for xs, ys in pool.map(windows_of, st, chunksize=2):
            X += xs
            Y += ys
            G += ["foot" if name == "author" else "leg"] * len(xs)
        print(f"  {name} n={n} seed={seed}: {len(X)} windows so far", flush=True)
    return np.stack(X).astype(np.int8), np.array(Y), np.array(G)


def fit(x, y, epochs):
    import tensorflow as tf
    import train as T
    tf.keras.utils.set_random_seed(0)
    m = T.build()
    # Balance: none and the common classes must not drown the rare ones.
    counts = np.bincount(y, minlength=8).astype(float)
    cw = {c: (len(y) / (8 * counts[c])) if counts[c] else 0.0 for c in range(8)}
    xf = x.astype(np.float32)
    for _ in range(epochs):
        m.fit(T.augment(xf), y, epochs=1, batch_size=64, verbose=0, class_weight=cw)
    return m


def predict(m, x):
    p = m.predict(x.astype(np.float32), verbose=0, batch_size=256)
    return p.argmax(1), np.round(p.max(1) * 255).astype(int)


# realsim-style scoring. Windows are cut and the rule run in workers (same
# matching as realsim.eval_stream); the CNN is batched here.
#   cnn     the CNN alone
#   rule    rules.c alone
#   hybrid  the rule when it is sure (conf >= RULE_SURE), else the CNN (unless it
#           says none): physics where it is clear, the learned model where the rule
#           already admits it cannot tell (cross vs close, low kicks, tiny steps).
RULE_SURE = RS.CONF_THR


def _cut_all(s):
    fu, right = s["fused"], s["right"]
    det = node.NEW_DETECTOR
    out = []
    for a in node.detect_swing(fu, det):
        w = node.cut(fu, a, right, det.win_pre, det.win_post)
        if w is not None:
            rc, rconf = baseline.decide(baseline.features(w))
            out.append((a, w, int(rc), int(rconf)))
    return out


def combine(mode, rc, rconf, cc, cconf):
    if mode == "rule" or (mode == "hybrid" and (rconf >= RULE_SURE or cc == NONE)):
        return rc, rconf
    # realsim has no "none" column: a step called none is not counted correct
    # (judge.c would report it as a wrong step when confident).
    return (RS.MISSED if cc == NONE else cc), cconf


def score_modes(pool, m, st, modes=("cnn", "rule", "hybrid")):
    cuts = pool.map(_cut_all, st, chunksize=2)
    flat = [w for c in cuts for _, w, _, _ in c]
    cls, conf = predict(m, np.stack(flat)) if flat else ([], [])
    out = {}
    for mode in modes:
        k = 0
        rows, extras = [], 0
        for s, c in zip(st, cuts):
            res = []
            for a, _, rc, rconf in c:
                pc, pconf = combine(mode, rc, rconf, int(cls[k]), int(conf[k]))
                res.append((a, pc, pconf, {}))
                k += 1
            RS.PIPES["_precomputed"] = lambda fu, right, res=res: res
            r, e = RS.eval_stream((s, "_precomputed"))
            rows += r
            extras += e
        out[mode] = (rows, extras)
    return out


HELD = {"author": 60, "auditor": 40, "stress": 42}


def report(pool, m, names, title):
    print(f"\n{title}", flush=True)
    pooled = {}
    for name in names:
        st = RS.streams(pool, name, HELD[name], HELD_OUT_SEED)
        for mode, (rows, ex) in score_modes(pool, m, st).items():
            print(RS.summary_line(f"{name} {mode}", RS.score(rows, ex)), flush=True)
            pr, pe = pooled.get(mode, ([], 0))
            pooled[mode] = (pr + rows, pe + ex)
    if len(names) > 1:
        for mode, (rows, ex) in pooled.items():
            print(RS.summary_line(f"pooled {mode}", RS.score(rows, ex)), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=30)
    ap.add_argument("--scale", type=float, default=1.0, help="multiply the training set size")
    ap.add_argument("--reuse", action="store_true", help="skip cross-validation, reuse runs/model_sim.keras")
    ap.add_argument("--procs", type=int, default=os.cpu_count())
    a = ap.parse_args()
    out = RS.CACHE.parent

    with Pool(a.procs) as pool:
        sets = []
        for sd in TRAIN_SEEDS:
            sets += [("author", int(60 * a.scale), sd), ("auditor", int(40 * a.scale), sd),
                     ("stress", int(42 * a.scale), sd)]
        print("training data", flush=True)
        x, y, g = dataset(pool, sets)
        np.savez_compressed(out / "sim_windows.npz", x=x, y=y, dancer=g, session=np.zeros(len(y), int))
        print("classes", {RS.NAMES[c]: int((y == c).sum()) for c in range(8)}, "total", len(y), flush=True)

        import tensorflow as tf
        if not a.reuse:
            # Leave one simulator out: the CNN never saw this simulator's feet, as it
            # will never have seen real ones. The hybrid must not lose to the rule here.
            for held, names in (("foot", ["author"]), ("leg", ["auditor", "stress"])):
                mx = fit(x[g != held], y[g != held], a.epochs)
                report(pool, mx, names, f"CNN trained WITHOUT the {held} simulator, tested on it (held-out seed)")

        if a.reuse and (out / "model_sim.keras").exists():
            m = tf.keras.models.load_model(out / "model_sim.keras")
        else:
            m = fit(x, y, a.epochs)
            m.save(out / "model_sim.keras")
        print("\nsaved", out / "model_sim.keras", "params", m.count_params())
        report(pool, m, ["author", "auditor", "stress"], "final model, held-out seed (both simulators seen in training)")


if __name__ == "__main__":
    main()
