# Dance Trainer: step-by-step plan

Course weeks 4–10, Autumn 2026. Final demo Dec 10, report Dec 15.
Leads: Zoe = firmware + hardware, Aaron = app, Kai = ML + integration. Everyone
helps on every part; the lead just keeps the list.

Each step says who, what, and what "done" looks like. Do them in order within
a track; tracks run in parallel. The one hard gate is step 7 (end of week 7).

---

## 0. Order the remaining parts (this week, Oct 22–23)

Boards (2) and motors (3) are ordered. Still needed, per `hardware/BOM.md`:

| Part | Qty | Where |
| --- | --- | --- |
| Grove 4-pin cable (one end gets cut) | 3 | Seeed / Amazon / Digi-Key |
| LiPo 3.7 V, 150–250 mAh, **protected**, bare leads (e.g. 502030) | 3 | Adafruit, Amazon |
| Mini slide switch, SPDT | 3 | Amazon, lab parts bin |
| 28 AWG silicone wire, assorted | 1 | Amazon, lab |
| Elastic strap 25 mm with hook-and-loop | 2–3 | Amazon |
| Third XIAO nRF52840 Sense Plus (spare) | 1 | Seeed |

- Who: Zoe orders, Kai double-checks the cart.
- Done when: order confirmations posted in the group chat, with arrival dates.
- Check the lab parts bin first for the switch and wire. Pick 2-day shipping;
  these must be in hand by week 5.

---

## 1. Firmware bring-up on one board (week 4–5)

Lead: Zoe. Code: `firmware/`. Nothing here needs the battery or motor yet.

1. Install `arduino-cli`, then `make setup` in `firmware/` (installs the
   Seeed nRF52 core). Then `make` to confirm the project compiles for the
   XIAO. If `make` fails on the toolchain, fix that before touching code.
2. Plug the first board in over USB-C. `make flash PORT=<port>`. If it does
   not enumerate, double-tap reset and drop the `.uf2` on the `XIAO-SENSE`
   drive. Done when: `make monitor` shows the boot banner.
3. Serial console `status`: confirm role, battery voltage (will read 0 or
   USB level), and that the IMU was found (WHO_AM_I 0x6A). If the IMU is
   missing, check `imu.cpp` power pin P1.08 and `Wire1`.
4. Console `cal` with the board flat and still. Then shake the board and
   watch logging; confirm samples at ~104 Hz and fusion output changes.
5. Console `selftest`: compare against `python ml/export.py --selftest` in
   `ml/`. Classes must match, confidence within ±2. This proves the CNN
   runs on the chip. Note inference time (`us` column) in the notebook.
6. BLE: use nRF Connect on a phone. Done when `DT-L` advertises, you can
   connect, read Status, and see Stream notifications when the board moves.
7. Second board: `make flash ROLE=R`. Confirm `DT-R` advertises. Done.

Deliverable for the Oct 29 rapid prototype: a board that streams IMU over
BLE to nRF Connect, plus the selftest numbers.

---

## 2. Hardware build, three nodes (week 5–6)

Lead: Zoe. Reference: `hardware/wiring.md`. Build one node completely
first, test it, then do the other two the same way.

1. **Motor.** Cut one end off a Grove cable. Solder red → 3V3, black → GND,
   yellow (SIG) → D0. White is unused; tape it. Console `buzz 1`, `buzz 2`,
   `buzz 3` must vibrate. Done when all three patterns feel different.
2. **Battery.** Solder the LiPo − lead to the BAT− pad on the underside.
   Solder the switch between LiPo + and the BAT+ pad. Heat-shrink both
   joints. Switch on, unplug USB: board boots on battery. Console `status`
   shows a sane voltage (3.5–4.2 V). Switch off: board dies. Plug USB with
   the switch on: charge LED comes on.
3. **Blanking check.** Set the board on a table, `buzz 3`. Logging must show
   no step detected during or just after the buzz. If it does, raise the
   120 ms settling time in `haptic.cpp`.
4. **Case v1.** Anything that holds board + cell + switch to a strap with the
   USB-C port reachable and the antenna end clear of the buckle. A printed
   box from the lab 3D printer is nice; a small project box with foam tape
   is acceptable for the MVP. Mount long axis along the foot, USB-C toward
   the toe, component side up (the firmware assumes this).
5. **Straps.** Try the elastic strap on three ankles. It must not rotate
   when the wearer kicks. Note what works in `hardware/`.
6. Repeat 1–5 for nodes 2 and 3. Label them L, R, spare on the case.
7. **Battery test.** Full charge, switch on, streaming to the app, timer.
   Record the hours in the notebook. Target is 2 h; if it is short, that is
   the first power task in week 9 (TIMER4 → RTC2 in `port.cpp`).

---

## 3. App, first working version (week 4–6)

Lead: Aaron. Code: `app/`. Contracts: `docs/ble-protocol.md`,
`docs/preset-format.md`, `docs/data-format.md`. Build in this order; each
screen is testable on its own against a real node.

1. `flutter pub get`, `flutter analyze`, `flutter test`, `flutter run` on
   an Android phone. Done when the existing app launches and finds `DT-L`.
2. **Connect screen.** Scan, connect to both `DT-L` and `DT-R`, show role,
   firmware version, battery from Status. Reconnect on drop.
3. **Time sync + calibrate.** Buttons that write the Time sync and Control
   characteristics. Show the measured offset per node. Re-sync on a timer
   every few seconds.
4. **Session store + export.** Write `session.json`, `L.csv`, `R.csv`,
   `events.csv` exactly as in `docs/data-format.md`. Share-sheet export so
   the folder can be copied to a laptop. This unblocks data collection,
   so it comes before anything visual.
5. **Presets + music + beat clock.** Load `presets/*.json`, play a music
   file with `just_audio`, keep a beat clock from `t0` and `bpm`. Count-in.
6. **Capture mode.** Pick dancer name + preset, send mode = capture,
   stream at 100 Hz, record to the session store. This is the data
   collection tool; it must exist by the start of week 6.
7. **Dance screen.** Push the schedule to each node, mode = dance, draw the
   step chart (`chart/step_chart.dart`) scrolling to the music, mark each
   Step event correct / wrong as it arrives.
8. **Performance mode + score.** Keep going on errors; count them.
9. **Practice mode.** On an error, pause music and the chart, rewind to the
   start of the measure, resume.
10. **Session summary, first version.** Totals from the live verdicts:
    accuracy, mean timing error, errors by foot. From `events.csv`.
11. **Retrospective scoring (after the MVP gate).** Two passes over the
    stored session, both on the phone:
    - *Sequence alignment.* Edit-distance alignment of the detected step
      list against the schedule. Separates one skipped step that shifted
      everything from a string of genuinely wrong steps. Produces the
      wrong / missed / extra markers.
    - *Whole-performance similarity.* Dynamic time warping of the full
      IMU streams against a reference recording of the routine (a
      teammate who can dance it cleanly). The local distance along the
      warped path, inverted to a percentage, is the accuracy-over-time
      curve: x = song time, y = similarity, step markers from the
      alignment on the same axis. This chart is the summary screen.

Big screen: mirror the phone with Chromecast or a USB-C to HDMI cable. Do
not build the laptop web client; it was cut.

---

## 4. Rule-based judge end to end (week 6)

Lead: Kai with Zoe. Step classification is the design that ships: each
foot strike is cut into a window and classified as one of the step types.
The rule classifier is the MVP and the fallback; the trained model (step 6)
replaces it when it wins on held-out dancers.

1. Build the firmware with `make CLASSIFIER=rules`. Dance the box step with
   both nodes on; watch verdicts in the app.
2. Tune the strike detector thresholds in `stepdet.c` on real feet, not on
   synthetic data. Check that each real step produces exactly one strike.
   Everything below depends on this.
3. Tune the rules in `rules.c` until forward / back / side / in place are
   right most of the time for the three of us. Keep `ml/dt/baseline.py`
   identical (`ml/tests/test_rules_parity.py` checks this).
4. Tune the judge timing window in `judge.c` so correct dancing at 100 bpm
   does not buzz. Start lenient. A wrong buzz is worse than a missed one.
5. Measure strike-to-buzz latency from node timestamps. Record it.

Done when: wrong foot, wrong direction, or a badly late step buzzes the
right ankle, and dancing it correctly does not buzz. Show this at the
Nov 3 status presentation if ready, otherwise the stream + motor demo.

## 5. Data collection (week 6–8)

Lead: Kai. Everyone recruits two dancers by week 6.

1. Dry-run the pipeline on synthetic data once so nothing surprises you:
   `ml/synth.py -o data`, `label.py`, `windows.py`, `baseline.py`,
   `train.py`, `export.py`. Done when the exported weights compile and
   `selftest` matches.
2. Capture protocol: each dancer does the box step and the grapevine,
   each at two tempos, each 8 repeats. About 10 minutes per dancer. Count-in
   before every take; calibration pose at the start of every session.
3. Target: 6+ dancers, 1,000+ labeled steps by end of week 7. Copy session
   folders into `ml/data/` on one laptop (they are git-ignored; back them up
   to Drive).
4. After every two dancers: `label.py` then `windows.py`, then
   `baseline.py` to see what the rules get. If labeling flags many
   unusable steps, the problem is time sync or strap slip; fix that before
   collecting more.

---

## 6. Train and ship the model (week 7–8)

Lead: Kai. The model is trained on windows of each step type, collected
from several dancers, and replaces the rules on the node if it wins.

1. `train.py runs/windows.npz`: leave-one-dancer-out cross-validation.
   Read the confusion matrix. Merge classes the data cannot separate
   (cross vs side, kick vs none) rather than fighting them.
2. Also try hand-made features (displacement per axis, peak accel, swing
   duration, turn angle, landing hardness) with a decision tree or random
   forest. With a few hundred windows this may beat the CNN and is easier
   to explain in the report. Report rules vs features vs CNN on the same
   held-out dancers.
3. Ship only if the model beats the rule baseline on held-out dancers.
   Otherwise the rules stay and you collect more data.
4. `export.py runs/model.keras runs/windows.npz` writes
   `firmware/dance_node/src/model_weights.h` and selftest vectors. Commit
   both with the training run's numbers in the message.
5. `make` (CNN build), flash, `selftest` matches `export.py --selftest`.
   `ml/tests/test_cnn_parity.py` passes.
6. Dance it. Compare buzz behaviour to the rules build on the same routine.
   Set the confidence threshold so correct steps are not flagged.
7. Repeat from step 1 as more data arrives through week 8.

## 7. MVP gate, end of week 7 (Nov 13)

The whole team, at a real rehearsal with music on a big screen:

- Two battery-powered nodes on straps, connected to the app.
- Box step with music and the step chart; a deliberate wrong step buzzes
  the right ankle; Performance mode scores it.
- Latency, battery, and skew numbers written down.
- A video of this, kept as the backup demo.

If this does not pass, nothing new starts: every hour goes here until it does.
If it passes, weeks 8–10 add the trained model, Practice mode, the summary,
and polish, in that order.

---

## 8. Finish and evaluate (week 8–10)

1. Week 8: trained model on the node (step 6), Practice mode, session
   summary, retrospective scoring if time (step 3.11). Second preset
   (grapevine) working.
2. Week 9 (short week): film three dancers who were not in the training
   data. Compute accuracy, timing error, false-buzz rate from their
   `events.csv`. These are the numbers for the report. Battery run-down
   test on the final firmware. Case v2 only if v1 fell off or broke.
3. Week 10: freeze firmware and app. Two full demo rehearsals, one per
   dancer who will demo. Re-film the backup video with the final build.
   Charge all three nodes the night before every rehearsal and the demo.

---

## 9. Course deliverables along the way

| Date | Deliverable | Content |
| --- | --- | --- |
| Oct 22 | PRD | Done; keep updated on the site |
| Oct 29 | Rapid prototype | Board streaming IMU over BLE; motor buzzing from the console |
| Nov 3 | Status presentation | Nodes built; app connecting; rule judge demo or video |
| Nov 10 | Peer review 1 | |
| Weekly | Notebook | Each lead writes their track's entry Friday |
| Dec 10 | Final demo | Step 7 plus trained model, Practice mode, summary |
| Dec 15 | Final report + peer review 2 | Numbers from step 8.2; start the outline in week 9 |

---

## Decisions so far

- Oct 30 (current): ship step classification. Each foot strike is cut
  into a window and classified as a step type; the rule classifier is the
  MVP, a model trained on windows of each step type from several dancers
  replaces it if it wins on held-out dancers. The reference-motion method
  in `docs/judging.md` (continuous comparison against a recorded
  performance, no step vocabulary, supports any routine) is the documented
  next direction once the step pipeline works, not the current plan.
- Retrospective scoring on the phone (sequence alignment for step markers,
  DTW against a reference take for the accuracy-over-time curve) stays in
  step 3.11, after the MVP gate.

## Rules of the road

- `docs/ble-protocol.md`, `docs/preset-format.md`, `docs/data-format.md`
  are frozen. A change to one is a commit that also changes the firmware
  and app that implement it, in the same PR.
- Step class ids live in `dt_protocol.h`, `protocol.dart`, `dt/protocol.py`.
  Keep them identical.
- Cut list, already decided: replay screen, laptop step chart, wrist
  nodes, case v2 unless needed. Do not start these before step 7 passes.
- Small commits, pushed daily, to `main`. If something is half-done, leave
  it behind a flag rather than on a branch nobody merges.
