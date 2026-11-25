#!/usr/bin/env python3
"""Browse recorded sessions one after another: plot_steps.py for every session
under a folder (nested folders too), as linked web pages with Prev / Next.

Usage: browse_sessions.py [data] [-o runs/plots] [--foot L|R] [--force] [--no-open]

Finds every folder with a session.json below the given one (any depth), in path
order (= recording order, the names start with the date), plots each into
<out>/<same relative path>/ and writes there an index.html:

  ← / →  (or the Prev / Next links)  previous / next session, across folders
  ↑      (or "All sessions")         <out>/index.html, sessions grouped by folder

Plots are cached: a session is re-plotted only when its files or the model
changed (or with --force). Opens the first page in the browser unless --no-open.
"""
import argparse
import html
import json
import os
import subprocess
import sys
from pathlib import Path

import plot_steps as P

STAMP = ".plotted.json"


def sessions(root: Path) -> list[Path]:
    return sorted(p.parent for p in root.rglob("session.json"))


def stale(d: Path, out: Path) -> bool:
    stamp = out / STAMP
    if not stamp.exists():
        return True
    inputs = [d / n for n in ("session.json", "events.csv", "L.csv", "R.csv")] + [P.MODEL / "model.json", Path(P.__file__)]
    newest = max(f.stat().st_mtime for f in inputs if f.exists())
    return newest > stamp.stat().st_mtime


def plot(d: Path, out: Path, feet: list[str]) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    for f in out.glob("*.png"):
        f.unlink()
    meta = json.loads((d / "session.json").read_text())
    info = {"session": meta.get("session_id", d.name), "routine": meta.get("preset_name", "?"),
            "bpm": meta.get("bpm"), "dancer": meta.get("dancer", ""), "feet": {}}
    for foot in feet:
        if not (d / f"{foot}.csv").exists():
            continue
        try:
            meta, name, t, fa, gyro, st = P.steps(d, foot)
        except Exception as e:                                # a broken recording: say so, keep browsing
            info["feet"][foot] = {"error": f"{type(e).__name__}: {e}"}
            continue
        files = P.timeline(meta, name, t, fa, gyro, st, foot, 10.0, out) + P.gallery(meta, name, st, foot, out)
        lab = [s for s in st if s["label"] >= 0]
        info["feet"][foot] = {"classifier": name, "steps": len(st), "labelled": len(lab),
                              "right": sum(s["call"] == s["label"] for s in lab), "images": [f.name for f in files]}
    (out / STAMP).write_text(json.dumps(info, indent=1))
    return info


def rel(a: Path, b: Path) -> str:
    """Link from page a to file b."""
    return Path(os.path.relpath(b, a.parent)).as_posix()


def page(out_root: Path, outs: list[Path], infos: list[dict], k: int) -> None:
    here = outs[k] / "index.html"
    info = infos[k]
    prev = rel(here, outs[k - 1] / "index.html") if k > 0 else ""
    nxt = rel(here, outs[k + 1] / "index.html") if k + 1 < len(outs) else ""
    top = rel(here, out_root / "index.html")
    where = outs[k].relative_to(out_root).as_posix()

    def link(href: str, text: str) -> str:
        return f'<a href="{href}">{text}</a>' if href else f'<span class="off">{text}</span>'

    feet = []
    for foot, f in info["feet"].items():
        if "error" in f:
            feet.append(f"<h2>{foot} foot</h2><p class='err'>could not plot: {html.escape(f['error'])}</p>")
            continue
        acc = f"{f['right']}/{f['labelled']} labelled steps called right ({f['classifier']})" if f["labelled"] else "no labelled steps"
        imgs = "".join(f'<img src="{html.escape(i)}" loading="lazy" alt="{html.escape(i)}">' for i in f["images"])
        feet.append(f"<h2>{foot} foot <small>{f['steps']} steps · {acc}</small></h2>{imgs}")
    body = f"""<!doctype html><meta charset="utf-8"><title>{html.escape(info['session'])}</title>
<style>body{{font:14px system-ui,sans-serif;margin:0;background:#fafafa;color:#111}}
nav{{position:sticky;top:0;background:#111;color:#eee;padding:8px 16px;display:flex;gap:18px;align-items:center;z-index:1}}
nav a{{color:#d4f04c;text-decoration:none;font-weight:600}} .off{{color:#666}} nav .where{{margin-left:auto;color:#aaa}}
main{{padding:12px 16px}} img{{max-width:100%;display:block;margin:8px 0;background:#fff}} small{{color:#666;font-weight:400}}
.err{{color:#b91c1c}}</style>
<nav>{link(prev, "← Prev")}<span>{k + 1} / {len(outs)}</span>{link(nxt, "Next →")}<a href="{top}">All sessions ↑</a>
<span class="where">{html.escape(where)}</span></nav>
<main><h1>{html.escape(info['routine'])} <small>{info['bpm']} bpm · {html.escape(str(info['dancer']))} · {html.escape(info['session'])}</small></h1>
{''.join(feet)}</main>
<script>addEventListener('keydown',e=>{{const t={{ArrowLeft:{json.dumps(prev)},ArrowRight:{json.dumps(nxt)},ArrowUp:{json.dumps(top)}}}[e.key];
if(t)location.href=t}});</script>"""
    here.write_text(body)


def index(out_root: Path, outs: list[Path], infos: list[dict]) -> Path:
    here = out_root / "index.html"
    rows, last = [], None
    for o, info in zip(outs, infos):
        folder = o.parent.relative_to(out_root).as_posix()
        if folder != last:
            rows.append(f"<h2>{html.escape(folder or '.')}</h2>")
            last = folder
        acc = " · ".join(f"{ft} {f['right']}/{f['labelled']}" for ft, f in info["feet"].items() if "right" in f and f["labelled"])
        rows.append(f'<p><a href="{rel(here, o / "index.html")}">{html.escape(o.name)}</a> {html.escape(info["routine"])}'
                    f' <small>{info["bpm"]} bpm · {html.escape(str(info["dancer"]))}{" · " + acc if acc else ""}</small></p>')
    here.write_text(f"""<!doctype html><meta charset="utf-8"><title>Sessions</title>
<style>body{{font:14px system-ui,sans-serif;margin:16px;color:#111}} h2{{font-size:15px;margin:18px 0 4px;color:#555}}
p{{margin:3px 0}} small{{color:#666}} a{{font-weight:600}}</style>
<h1>{len(outs)} sessions</h1>{''.join(rows)}
<script>addEventListener('keydown',e=>{{if(e.key==='ArrowRight')location.href={json.dumps(rel(here, outs[0] / 'index.html'))}}});</script>""")
    return here


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=str(P.HERE / "data"), help="folder to search for sessions (any depth)")
    ap.add_argument("-o", "--out", default=str(P.HERE / "runs/plots"))
    ap.add_argument("--foot", choices=["L", "R"])
    ap.add_argument("--force", action="store_true", help="re-plot every session")
    ap.add_argument("--no-open", action="store_true")
    a = ap.parse_args()
    root, out_root = Path(a.root).resolve(), Path(a.out).resolve()
    found = sessions(root)
    if not found:
        sys.exit(f"no session.json under {root}")
    feet = [a.foot] if a.foot else ["L", "R"]
    outs, infos = [], []
    for d in found:
        out = out_root / d.relative_to(root)
        if a.force or stale(d, out):
            print(f"plotting {d.relative_to(root)}", flush=True)
            infos.append(plot(d, out, feet))
        else:
            infos.append(json.loads((out / STAMP).read_text()))
        outs.append(out)
    for k in range(len(outs)):
        page(out_root, outs, infos, k)
    first = outs[0] / "index.html"
    print(f"{len(outs)} sessions → {index(out_root, outs, infos)}  (first: {first})")
    if not a.no_open and sys.platform == "darwin":
        subprocess.run(["open", str(first)], check=False)


if __name__ == "__main__":
    main()
