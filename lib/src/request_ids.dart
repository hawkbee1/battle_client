import 'dart:math' as math;

import 'package:battle_client/src/ports/clock.dart';

/// {@template request_ids}
/// The request IDs of a client's commands. The host keeps an answer 15
/// minutes by battle, account and request ID (stack decision 3), so an ID
/// must not repeat within them, across the client's restarts too: each is
/// the wall time in milliseconds times 1,024 plus a random number below
/// 1,024, and above the one before. A restarted client starts from a later
/// millisecond; two clients of one account (an app and an agent) collide
/// only on the same millisecond and the same random number.
///
/// The IDs stay below 2^52, the limit of the protocol's integers, until the
/// year 2109.
/// {@endtemplate}
final class RequestIds {
  /// {@macro request_ids}
  new(this._clock, this._random);

  final Clock _clock;
  final math.Random _random;
  var _last = 0;

  /// How many random IDs share a millisecond.
  static const perMillisecond = 1024;

  /// The next request ID.
  int next() {
    final fromTime =
        _clock.now().millisecondsSinceEpoch * perMillisecond +
        _random.nextInt(perMillisecond);
    return _last = math.max(fromTime, _last + 1);
  }
}
