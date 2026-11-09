import 'package:battle_client/battle_client.dart';
import 'package:test/test.dart';

void main() {
  group(SystemClock, () {
    test('gives the time now, in UTC', () {
      final before = DateTime.now().toUtc();
      final now = const SystemClock().now();

      expect(now.isUtc, isTrue);
      expect(now.isBefore(before), isFalse);
      expect(now.difference(before), lessThan(const Duration(seconds: 5)));
    });
  });
}
