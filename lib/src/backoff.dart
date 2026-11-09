import 'dart:math' as math;

/// {@template backoff}
/// The wait before a client tries to reach its host again: [first], then
/// twice as long at each failed attempt up to [max]. Each wait is between
/// half and all of that, at random, so clients dropped together (a host
/// that restarts) do not come back together.
/// {@endtemplate}
final class Backoff {
  /// {@macro backoff}
  const new({required this.first, required this.max});

  /// The longest first wait.
  final Duration first;

  /// The longest wait.
  final Duration max;

  /// The wait before attempt [attempt] (0 for the first retry), with
  /// [random].
  Duration delay(int attempt, math.Random random) {
    final ceiling = math.min(
      max.inMicroseconds,
      first.inMicroseconds * math.pow(2, math.min(attempt, 30)),
    );
    return Duration(
      microseconds: (ceiling / 2 + random.nextDouble() * ceiling / 2).round(),
    );
  }
}
