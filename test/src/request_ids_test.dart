import 'dart:math';

import 'package:battle_client/battle_client.dart';
import 'package:test/test.dart';

import '../helpers/fakes.dart';

void main() {
  group(RequestIds, () {
    test('stack decision 3 come from the wall time in milliseconds', () {
      final clock = ManualClock(DateTime.utc(2026, 11, 8, 9));
      final id = RequestIds(clock, Random(1)).next();
      final millisecond = clock.time.millisecondsSinceEpoch;

      expect(id ~/ RequestIds.perMillisecond, equals(millisecond));
    });

    test('stack decision 3 never repeat within one millisecond', () {
      final ids = RequestIds(ManualClock(DateTime.utc(2026)), Random(1));
      final drawn = [for (var i = 0; i < 5000; i++) ids.next()];

      expect(drawn.toSet(), hasLength(drawn.length));
      for (var i = 1; i < drawn.length; i++) {
        expect(drawn[i], greaterThan(drawn[i - 1]));
      }
    });

    test('stack decision 3 a client restarted later starts above the IDs it '
        'used before', () {
      final clock = ManualClock(DateTime.utc(2026));
      final before = RequestIds(clock, Random(1));
      final last = [for (var i = 0; i < 100; i++) before.next()].last;
      clock.time = clock.time.add(const Duration(milliseconds: 1));

      expect(RequestIds(clock, Random(1)).next(), greaterThan(last));
    });

    test('stay below 2^52, the limit of the protocol integers, until 2109', () {
      final ids = RequestIds(ManualClock(DateTime.utc(2109)), Random(1));

      expect(ids.next(), lessThan(1 << 52));
    });
  });
}
