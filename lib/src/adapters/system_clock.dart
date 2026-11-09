import 'package:battle_client/src/ports/clock.dart';

/// The system's clock: the adapter of [Clock] that apps and agents run on.
final class SystemClock implements Clock {
  /// The system's clock.
  const new();

  @override
  DateTime now() => DateTime.now().toUtc();
}
