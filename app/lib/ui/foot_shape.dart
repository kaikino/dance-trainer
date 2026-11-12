import 'dart:math';

/// A sole outline in foot coordinates: x from −0.5 (heel) to +0.5 (toe),
/// y positive toward the dancer's left; one foot length is 1.
///
/// Not symmetric, so left and right read as feet: the arch pinches in on the
/// inner side (toward the other foot), the ball is widest on the inner side,
/// and the toe tip leans toward the big toe. [left] mirrors it.
/// The points go heel → toe along the dancer's-left edge, then back.
List<(double, double)> soleOutline({required bool left, int n = 32}) {
  // Inner side: −y on the left foot, +y on the right.
  final inner = left ? -1.0 : 1.0;
  double g(double x, double c, double w) => exp(-((x - c) / w) * ((x - c) / w));
  double smooth(double a, double b, double x) {
    final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  // Round ends: a blunter curve at the heel than at the toe.
  double envelope(double u) {
    final p = u < 0 ? 2.6 : 2.0;
    return pow(max(0.0, 1 - pow(u.abs(), p)), 1 / p).toDouble();
  }

  // Half-width: the heel about 0.7 of the ball.
  double base(double x) => 0.16 * (0.7 + 0.3 * smooth(-0.3, 0.2, x)) * envelope(2 * x);
  // A shallow waist (the arch) on the inner side; the ball widest there.
  double innerHalf(double x) => base(x) * (1 - 0.12 * g(x, -0.02, 0.14)) * (1 + 0.08 * g(x, 0.24, 0.12));
  double outerHalf(double x) => base(x) * (1 - 0.06 * g(x, 0.34, 0.14));
  double lean(double x) => 0.22 * pow(max(0.0, x - 0.1), 2).toDouble();
  // y of the edge on side s (+1 dancer's left, −1 right).
  double edge(double x, double s) => s * (s == inner ? innerHalf(x) : outerHalf(x)) + inner * lean(x);

  // Denser near heel and toe so the ends come out round.
  final xs = [for (var i = 0; i <= n; i++) -0.5 * cos(pi * i / n)];
  return [
    for (final x in xs) (x, edge(x, 1)),
    for (final x in xs.reversed.skip(1).take(n - 1)) (x, edge(x, -1)),
  ];
}

/// The toe cap of [outline] (from [soleOutline]): the part toward the toe
/// from x = [from], closed by an arc that bows back toward the heel by
/// [bow] rather than a straight cut across. Live view and feet diagram share it.
List<(double, double)> toeCapOutline(List<(double, double)> outline, {double from = 0.3, double bow = 0.05}) {
  final cap = [
    for (final p in outline)
      if (p.$1 >= from) p
  ];
  if (cap.length < 2) return cap;
  // The outline runs heel → toe along +y and back along −y, so the cap runs
  // from the +y edge round the toe to the −y edge; the arc goes back.
  final a = cap.last, b = cap.first;
  const k = 8;
  return [
    ...cap,
    for (var i = 1; i < k; i++)
      (
        a.$1 + (b.$1 - a.$1) * i / k - bow * sin(pi * i / k),
        a.$2 + (b.$2 - a.$2) * i / k,
      ),
  ];
}
