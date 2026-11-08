/// The client's wall clock (a port, stack decision 7): it dates the battle
/// time between the host's messages and seeds request IDs, so tests move
/// time by hand.
abstract interface class Clock {
  /// The current time, in UTC.
  DateTime now();
}
