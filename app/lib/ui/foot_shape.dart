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
  double base(double x) {
    final u = 2 * x; // −1 heel … +1 toe
    return (0.13 + 0.05 * (u + 1) / 2) * sqrt(max(0.0, 1 - u * u));
  }

  double innerHalf(double x) => base(x) * (1 - 0.3 * g(x, -0.02, 0.14)) * (1 + 0.12 * g(x, 0.24, 0.12));
  double outerHalf(double x) => base(x) * (1 - 0.1 * g(x, 0.34, 0.14));
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
