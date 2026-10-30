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

## 4. Live judge: deviation from a reference performance (week 6)

Lead: Kai with Zoe. Decision (Oct 30, supersedes Oct 29): the live buzz
is a continuous *deviation score* against a recorded reference
performance of the routine, compared in time with the music. No step
vocabulary, no strike detector in the judging path. Full design in
`docs/judging.md`. The step list below is the old template plan and is
kept only for the attribute and timing items; read judging.md first.

1. First get timing-only judging working: a strike on the right foot
   inside the beat window is correct, no classifier at all. This is the
   floor and the Nov 3 demo if nothing else is ready.
2. Tune the strike detector thresholds in `stepdet.c` on real feet, not on
   synthetic data. Check that each real step produces exactly one strike.
   Everything below depends on this.
3. Templates. Extend calibration: after the still pose and the forward
   slide, the dancer does each step in the chosen routine three times on
   cue from the app. The node stores the mean window per step per foot in
   flash. Keep this under a minute and let a stored profile carry over
   between sessions, or people will skip it.
4. Distance. Start with Euclidean distance on the normalised window; move
   to dynamic time warping if early/late steps score as wrong. Both fit
   the node's budget for a 60×9 window. Store the per-dancer threshold
   from the spread of the calibration windows.
5. Attributes outside the distance: displacement magnitude (step size)
   and turn angle from the gyro, judged as numbers with tolerances set
   at calibration. This is how "wide right vs small right" is scored.
6. Fallback for an uncalibrated dancer: the rule classifier in `rules.c`
   (`make CLASSIFIER=rules`), matched against the expected class.
7. Tune the judge timing window in `judge.c` so correct dancing at 100 bpm
   does not buzz. Start lenient. A wrong buzz is worse than a missed one.
8. Measure strike-to-buzz latency from node timestamps. Record it.

Done when: wrong foot, wrong direction, or a badly late step buzzes the
right ankle, and dancing it correctly does not buzz.

---

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

## 6. The learned classifier (week 7–8)

Lead: Kai. With deviation scoring doing the live buzz, the classifier's
jobs are (a) naming the mistake in the summary and (b) the comparison
section of the report. The collected windows serve both.

1. `train.py runs/windows.npz`: leave-one-dancer-out cross-validation.
   Read the confusion matrix. Merge classes the data cannot separate
   (cross vs side, kick vs none) rather than fighting them.
2. Also try hand-made features (displacement per axis, peak accel, swing
   duration, turn angle, landing hardness) with a decision tree or random
   forest. With a few hundred windows this will likely beat the CNN and
   is easier to explain in the report.
3. Report rules vs features vs CNN vs nearest-template on the same
   held-out dancers. That table is the ML section of the final report.
4. If one beats the rules clearly, export it to the node as the fallback
   classifier: `export.py runs/model.keras runs/windows.npz` writes
   `firmware/dance_node/src/model_weights.h` and selftest vectors. `make`,
   flash, `selftest` must match `export.py --selftest`;
   `ml/tests/test_cnn_parity.py` passes.
5. The summary's "you did X instead of Y" uses nearest-template on the
   phone, with the trained classifier as a cross-check.
6. Repeat from step 1 as more data arrives through week 8.

---

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

1. Week 8: retrospective scoring (step 3.11: alignment and the
   similarity-over-time chart), Practice mode, classifier comparison
   (step 6). Record the reference performance for each preset. Second
   preset (grapevine) working.
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

- Oct 30: judging is by continuous comparison against a recorded
  reference performance, in the foot frame, aligned to the music clock
  with a bounded timing search; retrospective scoring is full DTW against
  the same reference. No step classes, no strike detector in the judging
  path, no labeled training set required. Any routine with a reference
  take is supported, including routines that travel. See
  `docs/judging.md`. Record-by-demonstration is now core, not stretch.
- Oct 29 (superseded on the live side, kept for the summary): live
  feedback = deviation from a per-dancer template of the
  expected step, plus size and turn as numbers with tolerances. Timing-only
  judging is the floor. Retrospective scoring on the phone = sequence
  alignment (step markers) + whole-performance DTW against a reference
  recording (accuracy-over-time curve). The trained classifier names
  mistakes in the summary and is compared in the report; it is not what
  triggers the buzz.

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
