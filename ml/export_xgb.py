#!/usr/bin/env python3
"""Export a trained XGBoost step model (train_xgb.py) to C for the board.

Usage: export_xgb.py runs/tablet/xgb [--features runs/tablet/features.csv]
                     [-o ../firmware/dance_node/src/xgb_model.h]

Writes xgb_model.h, read by firmware/dance_node/src/xgb.c (build with
`make CLASSIFIER=xgb`). Layout, 8 bytes a node, in flash:

  xgb_nodes[]  {float v; uint16_t left; uint8_t feat; uint8_t miss_left}
               feat < XGB_N_INPUTS: an internal node, go to `left` when
               input[feat] < v (XGBoost's rule), else to left + 1 (children
               are stored side by side); a missing (NaN) input goes left when
               miss_left. feat == 0xFF: a leaf worth v.
  xgb_root[]   first node of each stored tree, xgb_class[] its class.
  xgb_base[]   each class's starting score (margin).

A tree that is a single leaf adds the same to its class for every step: it is
folded into xgb_base and not stored (the classes with no training examples
are all like that). xgb_base is measured, not read: the model's own margins
minus the stored trees' sums, checked to be the same for every step given.

Probabilities = softmax(margins); the board takes the top class, limits it to
the routine's steps (rules_vocab_neighbour) and reports probability × 255 as
the confidence.
"""
import argparse
import json
from collections import deque
from pathlib import Path

import numpy as np
import pandas as pd
import xgboost as xgb

from dt.protocol import CLASS_NAMES

LEAF = 0xFF
NODE_BYTES = 8


def trees_of(booster: xgb.Booster) -> tuple[list[dict], list[int], dict]:
    j = json.loads(booster.save_raw("json"))
    gb = j["learner"]["gradient_booster"]["model"]
    return gb["trees"], gb["tree_info"], j["learner"]


def flatten(tree: dict, base_index: int) -> list[tuple]:
    """One tree as (value, left, feat, miss_left) rows, breadth first, with
    each node's two children side by side (yes child first)."""
    left, right = tree["left_children"], tree["right_children"]
    cond, split, default_left = tree["split_conditions"], tree["split_indices"], tree["default_left"]
    out: list[list] = []
    pos = {0: 0}
    order = deque([0])
    out.append(None)
    while order:
        n = order.popleft()
        i = pos[n]
        if left[n] == -1:
            out[i] = [float(cond[n]), 0, LEAF, 0]          # leaf: split_conditions holds its value
            continue
        li = len(out)
        pos[left[n]], pos[right[n]] = li, li + 1
        out += [None, None]
        order += [left[n], right[n]]
        out[i] = [float(cond[n]), base_index + li, int(split[n]), int(bool(default_left[n]))]
    return [tuple(r) for r in out]


def eval_tree(nodes: list[tuple], root: int, x: np.ndarray) -> float:
    i = root
    while nodes[i][2] != LEAF:
        v, left, feat, miss_left = nodes[i]
        xv = x[feat]
        go_left = bool(miss_left) if np.isnan(xv) else np.float32(xv) < np.float32(v)
        i = left if go_left else left + 1
    return nodes[i][0]


# The board's routine limit (rules.c rules_vocab_neighbour) for a model's call:
# a class outside the routine may be replaced by an allowed travelling class
# within 67.5° of its direction, the likelier one; in place, kick and none never
# are. Then never sure (confidence capped at 159). Mirrors xgb.c xgb_classify.
_CROSS_OFF = 2250
_DIRS = [(int(CLASS_NAMES[n]), a) for n, a in [
    ("forward", 0), ("forward_out", 4500), ("side_out", 9000), ("back_out", 13500), ("back", 18000),
    ("back_in", -13500), ("side_in", -9000), ("forward_in", -4500),
    ("cross", -9000 + _CROSS_OFF), ("cross_behind", -9000 - _CROSS_OFF)]]
_REACH = 6750


def _adiff(a: int, b: int) -> int:
    return abs(((a - b + 18000) % 36000 + 36000) % 36000 - 18000)


def board_call(probs: np.ndarray, vocab: int) -> tuple[int, int]:
    """(class, confidence 0..255) as xgb.c reports them, from class probabilities."""
    best = int(np.argmax(probs))
    conf = int(np.float32(probs[best]) * np.float32(255) + np.float32(0.5))
    if not vocab or (vocab >> best) & 1:
        return best, conf
    nom = dict(_DIRS).get(best)
    if nom is None:
        return best, conf
    pick = -1
    for c, a in _DIRS:
        if (vocab >> c) & 1 and _adiff(nom, a) <= _REACH and (pick < 0 or probs[c] > probs[pick]):
            pick = c
    if pick < 0:
        return best, conf
    return pick, min(conf, 159)


def export(model_dir: Path, features_csv: Path | None) -> tuple[str, dict]:
    meta = json.loads((model_dir / "meta.json").read_text())
    booster = xgb.Booster()
    booster.load_model(model_dir / "model.json")
    trees, tree_info, _ = trees_of(booster)
    n_class, inputs = int(meta["num_class"]), list(meta["inputs"])

    nodes: list[tuple] = []
    roots, classes = [], []
    folded = np.zeros(n_class)
    for t, c in zip(trees, tree_info):
        if t["left_children"][0] == -1:              # a single leaf: a constant for its class
            folded[c] += float(t["split_conditions"][0])
            continue
        roots.append(len(nodes))
        classes.append(int(c))
        nodes += flatten(t, len(nodes))
    if len(nodes) >= 1 << 16:
        raise SystemExit(f"{len(nodes)} nodes: more than a uint16 index reaches")

    # Base margins, measured on real inputs (or a few probes) and checked constant.
    if features_csv and features_csv.exists():
        df = pd.read_csv(features_csv)
        df["is_right"] = (df["foot"] == "R").astype(float)
        x = df[inputs].to_numpy(dtype=np.float32)
    else:
        x = np.random.default_rng(0).normal(0, 30, size=(64, len(inputs))).astype(np.float32)
    margin = booster.predict(xgb.DMatrix(x, feature_names=inputs), output_margin=True)
    sums = np.zeros_like(margin)
    for k in range(len(x)):
        for r, c in zip(roots, classes):
            sums[k, c] += eval_tree(nodes, r, x[k])
    base_all = margin - sums
    base = base_all.mean(0)
    spread = float(np.abs(base_all - base).max())
    if spread > 1e-4:
        raise SystemExit(f"base margin differs between steps by {spread}: the trees were not reproduced")

    def f32(v: float) -> str:
        s = repr(float(np.float32(v)))
        return (s if ("e" in s or "." in s) else s + ".0") + "f"

    lines = [
        "// Generated by ml/export_xgb.py from " + str(model_dir / "model.json") + ". Do not edit.",
        f"// {meta.get('steps', '?')} training steps; held-out accuracy {meta.get('cv_accuracy', 0):.1%},"
        f" {meta.get('cv_accuracy_routine', 0):.1%} limited to the routine (train_xgb.py).",
        "#pragma once",
        "#include <stdint.h>",
        "",
        f"#define XGB_N_INPUTS {len(inputs)}   // " + ", ".join(inputs),
        f"#define XGB_N_CLASSES {n_class}",
        f"#define XGB_N_TREES {len(roots)}    // of {len(trees)}: single-leaf trees are folded into xgb_base",
        f"#define XGB_N_NODES {len(nodes)}",
        f"#define XGB_LEAF 0x{LEAF:02X}",
        "",
        "typedef struct { float v; uint16_t left; uint8_t feat; uint8_t miss_left; } xgb_node_t;",
        "",
        "static const float xgb_base[XGB_N_CLASSES] = {" + ", ".join(f32(b) for b in base) + "};",
        "",
        "static const uint16_t xgb_root[XGB_N_TREES] = {",
    ]
    for i in range(0, len(roots), 16):
        lines.append("    " + ", ".join(str(r) for r in roots[i:i + 16]) + ",")
    lines += ["};", "", "static const uint8_t xgb_class[XGB_N_TREES] = {"]
    for i in range(0, len(classes), 32):
        lines.append("    " + ", ".join(str(c) for c in classes[i:i + 32]) + ",")
    lines += ["};", "", "static const xgb_node_t xgb_nodes[XGB_N_NODES] = {"]
    for v, left, feat, miss in nodes:
        lines.append(f"    {{{f32(v)}, {left}, {feat}, {miss}}},")
    lines += ["};", ""]
    size = {"trees": len(trees), "stored_trees": len(roots), "nodes": len(nodes),
            "bytes": len(nodes) * NODE_BYTES + len(roots) * 3 + n_class * 4, "base_spread": spread}
    return "\n".join(lines), size


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir", help="train_xgb.py output folder (model.json, meta.json)")
    ap.add_argument("--features", help="features.csv the model was trained on (checks the export on it)")
    ap.add_argument("-o", "--out", default=str(Path(__file__).resolve().parent.parent
                                               / "firmware/dance_node/src/xgb_model.h"))
    a = ap.parse_args()
    feats = Path(a.features) if a.features else Path(a.model_dir).parent / "features.csv"
    text, size = export(Path(a.model_dir), feats)
    Path(a.out).write_text(text)
    print(f"{size['stored_trees']} of {size['trees']} trees stored, {size['nodes']} nodes, "
          f"{size['bytes'] / 1024:.1f} KB of tables → {a.out}")


if __name__ == "__main__":
    main()
