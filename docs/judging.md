# Judging by reference motion

Decision (Oct 30): the dancer is judged by how closely their ankle motion
follows a recorded reference performance of the routine, continuously,
in time with the music. There is no step vocabulary, no strike detector in
the judging path, and no labeled training set. Any routine that can be
danced once by a reference dancer is supported, including routines that
travel across the room, because everything is measured as motion relative
to the foot, never as position in the room.

The strike-based classifier (`stepdet.c`, `rules.c`, `cnn.c`) stays in the
repo as an optional analysis tool for the summary. It is no longer what
decides a buzz.

## 1. The reference

- A reference dancer performs the routine to its music with both nodes on,
  in Capture mode. The app records, per foot, the foot-frame signals at
  100 Hz, time-stamped against the music clock: gravity-removed
  acceleration (forward, outward, up) and rotation rate (three axes).
- Two or three takes are recorded. Their mean is the reference; their
  spread per moment is the baseline tolerance.
- The reference is stored next to the preset: `presets/<name>.ref.npz`
  (or a compact int8 file for the node). A 3-minute routine is about
  100 KB per foot as int8, which fits the XIAO's 2 MB flash with room to
  spare.
- The preset JSON keeps `bpm`, `count_in_beats`, and the music file. The
  `steps` list becomes optional; it is only used to draw the chart.

"Record a routine by dancing it" therefore stops being a stretch feature
and becomes how every routine is created.

## 2. The signals, and why they are relative

Everything is expressed in the foot frame after calibration: forward is
toward the toe, outward is away from the other foot, up is against
gravity. The frame travels with the foot, so

- walking across the room is a forward-motion pattern, identical anywhere
  in the room and in any direction the dancer faces;
- turns show up in the vertical gyro channel, not as a change of frame;
- nothing is ever integrated to position, so there is no drift and no
  need to know where the dancer is.

Per-dancer amplitude is normalised at calibration: the dancer does the
first eight counts of the routine once, and the node computes a gain so
their signal energy matches the reference's. Tall and short dancers then
compare on shape, not size. Size is scored separately where a preset asks
for it (section 5).

## 3. Live judging

Both sides share the music clock, so the dancer's stream and the reference
are already roughly aligned. What remains is local timing slop, which is
handled by a bounded search rather than full dynamic time warping.

Every 100 ms, for each foot:

1. Take the last 250 ms of the dancer's six channels (25 samples × 6).
2. Compare it with the reference at the same music time, shifted by
   every offset in ±150 ms (31 offsets). Distance is mean squared
   difference per channel, weighted (gyro and acceleration each sum to
   one).
3. The best offset is the dancer's timing error for that moment; the
   distance at the best offset is the deviation.
4. Deviation is divided by the reference's own spread at that moment, so
   a moment the reference dancer did differently in each take is
   automatically lenient.

That is 31 × 25 × 6 = 4,650 multiply-adds every 100 ms per foot. The node
does this in well under a millisecond.

Buzz rule, with hysteresis so it does not chatter:

- deviation above the threshold for 300 ms continuously → one buzz on
  that foot (motion is wrong);
- deviation fine but timing error beyond ±120 ms for 300 ms → short
  buzz (right motion, wrong time);
- no new buzz on the same foot for 600 ms after a buzz, and the motor
  blanking window still applies to the IMU.

Thresholds come from calibration: the dancer's own eight-count
calibration pass gives the deviation they produce when trying, and the
threshold is set a margin above that. Practice mode can widen it.

Where it runs: phase one on the phone, because Dart iterates faster and
the reference is already there. The nodes stream at 100 Hz (about 1.2 kB/s
per node, fine for BLE) and the phone sends a buzz command back; this
adds 30–60 ms, still inside the target. Phase two, once the rule is
stable, moves the same arithmetic into the node with the reference loaded
over BLE before the song starts, and the phone only listens.

## 4. Retrospective scoring

After the song, the phone runs full dynamic time warping of the whole
session against the reference, per foot. The warped path gives

- a deviation value for every moment of the song → the accuracy-over-time
  curve, x = song time, y = similarity;
- the timing error curve, from how far the path strays from the diagonal;
- per-beat and per-measure scores, by averaging along the beat grid;
- the worst measures, which become the "drill these" button.

The live judge and the retrospective score use the same distance, so the
curve explains every buzz that happened.

## 5. Attributes a preset can ask for

Optional, per beat range, checked as numbers with tolerances:

- `size`: displacement magnitude over the beat, from double-integrating
  foot-frame acceleration between two still moments. "Wide right" vs
  "small right."
- `turn`: heading change over the beat, from the vertical gyro.
- `height`: peak vertical displacement, for kicks and hops.

These are the only places integration is used, and each is reset at a
still moment so drift cannot accumulate.

## 6. What this does not do, said plainly

- It teaches the reference dancer's version. A different but valid style
  reads as deviation. Mitigation: record references from the person who
  will teach the routine, and keep thresholds generous.
- It needs the dancer to dance to the music at the reference tempo.
  Practice mode at 80% tempo stretches the reference in time, which
  distorts the dynamics slightly; acceptable to about ±20%, beyond that
  record a slow reference.
- It cannot say what the dancer did instead, only that it differed. The
  summary shows the reference and the dancer's motion for the flagged
  beat side by side instead of naming a step. If naming is wanted, the
  old classifier can label the dancer's window in the summary.
- It still cannot see hips, arms or posture. Ankle motion only.

## 7. Where machine learning fits now

Nothing above needs training data, which is the point: it works on day
one with a single reference take. ML improves it later, in this order:

1. **Learned tolerance.** Collect sessions from several dancers who are
   judged correct by eye; fit per-moment thresholds from their spread
   instead of the reference's spread alone.
2. **Learned distance.** Train a small embedding network so that windows
   of the same move from different dancers are close and windows of
   different moves are far (contrastive loss on captured sessions).
   Replace mean squared difference with distance in the embedding. This
   is the dancer-invariance problem solved properly, and it exports to
   the node the same way `cnn.c` does.
3. **Mistake naming.** The strike-based classifier, trained as before, on
   flagged beats only, for the summary.

## 8. Changes to the code

- `docs/ble-protocol.md`: Stream at 100 Hz in Dance mode (was 50);
  a Reference characteristic to load the reference in chunks (phase two);
  Step event becomes a Deviation event: beat index, foot, deviation,
  timing error, verdict.
- `presets/`: add `<name>.ref.npz`; `steps` becomes optional.
- Firmware: `judge.c` becomes the deviation judge (phase two); `stepdet.c`
  is used only for the attributes in section 5 and the still-moment reset.
- App: Capture mode records the reference; a `judge/` module with the
  bounded-shift distance; the summary's DTW and the curve.
- ML: `ml/reference.py` builds the reference from takes; `ml/dtw.py`
  for the retrospective pass; later `ml/embed.py` for the learned distance.
