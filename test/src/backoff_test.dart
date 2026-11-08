import 'dart:math';

import 'package:battle_client/battle_client.dart';
import 'package:test/test.dart';

void main() {
  group(Backoff, () {
    const backoff = Backoff(
      first: Duration(milliseconds: 500),
      max: Duration(seconds: 30),
    );

    test('doubles at each attempt, between half and all of it', () {
      final random = Random(3);
      for (var attempt = 0; attempt < 6; attempt++) {
        final ceiling = const Duration(milliseconds: 500) * (1 << attempt);
        for (var i = 0; i < 50; i++) {
          final wait = backoff.delay(attempt, random);
          expect(wait, greaterThanOrEqualTo(ceiling ~/ 2));
          expect(wait, lessThanOrEqualTo(ceiling));
        }
      }
    });

    test('stops at its maximum, however many attempts failed', () {
      final random = Random(3);

      for (final attempt in [7, 30, 1000]) {
        final wait = backoff.delay(attempt, random);
        expect(wait, greaterThanOrEqualTo(const Duration(seconds: 15)));
        expect(wait, lessThanOrEqualTo(const Duration(seconds: 30)));
      }
    });
  });
}
