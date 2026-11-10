// The tests run in fake time, where futures complete on flushes, not awaits.
// ignore_for_file: discarded_futures

import 'dart:async';
import 'dart:math';

import 'package:battle_client/battle_client.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../helpers/fakes.dart';
import '../helpers/streams.dart';

const _accepted = SignInAccepted(
  accountId: 'a-1',
  sectionId: 's-1',
  team: 'team-1',
  battleTime: Duration(hours: 3),
);

const _view = SectionView(
  at: Duration(hours: 3),
  section: SectionPrivate(money: 5, xp: 0),
  units: [],
  hqs: [],
  relics: [],
  world: [],
);

/// A client on fake time with its log records captured.
final class _Harness {
  new(this.async) {
    client = BattleClient(
      battleId: 'b-1',
      transport: transport,
      address: (_) async {
        if (lookupRefusal case final refusal?) throw refusal;
        return Uri.parse('ws://host-1/v1/socket');
      },
      credential: () async => const Credential.jwt('jwt-secret-value'),
      clock: FakeClock(async),
      random: Random(7),
    );
  }

  final FakeAsync async;
  final transport = FakeTransport();
  late final BattleClient client;
  HostLookupException? lookupRefusal;

  FakeSocket get socket => transport.last;

  void signIn() {
    client.start();
    async.flushMicrotasks();
    socket
      ..deliver(_accepted)
      ..deliver(_view);
    async.flushMicrotasks();
  }
}

void main() {
  group('BattleClient logs', () {
    late List<LogRecord> records;
    late StreamSubscription<LogRecord> subscription;
    late Level previousLevel;

    setUp(() {
      records = [];
      previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      subscription = Logger.root.onRecord.listen(records.add);
    });

    tearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousLevel;
    });

    // The wait is jittered: its length is not what the tests check.
    final wait = RegExp(r'in [\d.]+ s');
    List<String> lines() => [
      for (final record in records)
        [
          record.level.name,
          record.message.replaceAll(wait, 'in N s'),
        ].join(' '),
    ];

    test('stack decision 7 its lifecycle, one record per step', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        h.socket.drop();
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 1));

        expect(
          lines().where((line) => !line.startsWith('FINE')),
          equals([
            'INFO connecting (attempt 1)',
            'INFO credential jwt',
            'INFO host address ws://host-1/v1/socket',
            'INFO socket open',
            'INFO sign-in accepted',
            'INFO socket closed: closed by the host',
            'INFO host lost, retry in N s',
            'INFO connecting (attempt 2)',
            'INFO credential jwt',
            'INFO host address ws://host-1/v1/socket',
            'INFO socket open',
          ]),
        );
        expect(
          records.map((record) => record.loggerName).toSet(),
          equals({'battle_client.BattleClient'}),
        );
      });
    });

    test('a refused command is a WARNING with its request ID and code', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        final answer = h.client.send(const Reload(unitId: 'u-1'));
        final requestId = h.socket.commands.single.requestId;
        h.socket.deliver(CommandRefused(requestId: requestId, reason: 'no_ap'));
        async.flushMicrotasks();

        unawaited(answer);
        final refused = records.singleWhere(
          (record) => record.level == Level.WARNING,
        );
        expect(refused.message, equals('command $requestId refused no_ap'));
        expect(refused.loggerName, equals('battle_client.BattleClient'));
      });
    });

    test('a command is logged sent, then accepted, by its request ID', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        unawaited(h.client.send(const Reload(unitId: 'u-1')));
        final requestId = h.socket.commands.single.requestId;
        h.socket.deliver(CommandAccepted(requestId: requestId, seq: 4));
        async.flushMicrotasks();

        expect(
          lines().where((line) => line.contains('command')),
          equals([
            'INFO command $requestId sent: Reload',
            'INFO command $requestId accepted',
          ]),
        );
      });
    });

    test('a command given while the host is lost is held, then resent', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        h.socket.drop();
        async.flushMicrotasks();
        unawaited(h.client.send(const Reload(unitId: 'u-1')));
        async.elapse(const Duration(seconds: 1));
        h.socket
          ..deliver(_accepted)
          ..deliver(_view);
        async.flushMicrotasks();

        final requestId = h.socket.commands.single.requestId;
        expect(
          lines().where((line) => line.contains('command')),
          equals([
            'INFO command $requestId held until sign-in: Reload',
            'INFO command $requestId resent',
          ]),
        );
      });
    });

    test('a refused sign-in is a WARNING, and the socket closes for it', () {
      fakeAsync((async) {
        final h = _Harness(async)..client.start();
        async.flushMicrotasks();
        h.socket.deliver(const SignInRefused(SignInRefusal.noSection));
        async.flushMicrotasks();

        expect(
          lines(),
          containsAllInOrder([
            'WARNING sign-in refused noSection',
            'INFO stopped',
            'INFO socket closed: sign-in refused noSection',
          ]),
        );
      });
    });

    test('a goodbye names its reason in the socket end', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        h.socket.deliver(const Goodbye(GoodbyeReason.battleEnded));
        async.flushMicrotasks();

        expect(lines(), contains('INFO socket closed: goodbye battleEnded'));
      });
    });

    test('a broken socket is SEVERE with its error and stack', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        h.socket.fail(StateError('reset by peer'));
        async.flushMicrotasks();

        final failed = records.singleWhere(
          (record) => record.level == Level.SEVERE,
        );
        expect(failed.message, equals('socket failed'));
        expect(failed.error, isA<StateError>());
        expect(failed.stackTrace, isNotNull);
        expect(lines(), contains('INFO socket closed: socket failed'));
      });
    });

    test('a frame it does not read is a WARNING', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        h.socket.deliverBytes([0xff, 0xff]);
        async.flushMicrotasks();

        expect(
          records
              .where((record) => record.level == Level.WARNING)
              .single
              .message,
          startsWith('unreadable frame'),
        );
        expect(lines(), contains('INFO socket closed: unreadable frame'));
      });
    });

    test('a host that cannot be reached is SEVERE, and it retries', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.transport.failures = 1;
        h.client.start();
        async.flushMicrotasks();

        final failed = records.singleWhere(
          (record) => record.level == Level.SEVERE,
        );
        expect(failed.message, equals('connecting failed'));
        expect(failed.error, isA<StateError>());
        expect(lines(), contains('INFO host lost, retry in N s'));
      });
    });

    test('a lasting refusal to give the address is a WARNING and a stop', () {
      fakeAsync((async) {
        const refusal = HostLookupException('not_your_battle', status: 403);
        final h = _Harness(async)..lookupRefusal = refusal;
        h.client.start();
        async.flushMicrotasks();

        expect(
          lines(),
          containsAllInOrder([
            'INFO connecting (attempt 1)',
            'INFO credential jwt',
            'WARNING host lookup refused: $refusal',
            'INFO stopped',
          ]),
        );
      });
    });

    test('closing the client ends its socket with "client closed"', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        h.client.close();
        async.elapse(const Duration(seconds: 1));

        expect(lines(), contains('INFO socket closed: client closed'));
      });
    });

    test('no record holds the credential secret', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        h.client.send(const Reload(unitId: 'u-1'));
        h.socket.drop();
        async.flushMicrotasks();

        expect(
          records.where(
            (record) => '${record.message} ${record.error}'.contains(
              'jwt-secret-value',
            ),
          ),
          isEmpty,
        );
      });
    });

    for (final weather in ['clear', 'fog']) {
      test('decision 237 ${weather}_s-2 with an unseen hit: logs name '
          'nothing the section does not see', () {
        fakeAsync((async) {
          final hidden = _hiddenUnitIds();
          final stream = _withUnseenHit('${weather}_s-2');
          final h = _Harness(async)..client.start();
          async.flushMicrotasks();
          stream.forEach(h.socket.deliver);
          async.flushMicrotasks();
          h.socket.drop();
          async.flushMicrotasks();

          expect(hidden, isNotEmpty);
          expect(stream.whereType<TickUpdate>().last.unseenHits, isNotEmpty);
          expect(records, isNotEmpty);
          for (final record in records) {
            final text =
                '${record.loggerName} ${record.message} '
                '${record.error} ${record.stackTrace}';
            for (final id in hidden) {
              expect(text, isNot(contains(id)), reason: record.message);
            }
          }
        });
      });
    }
  });
}

/// The recorded stream [name] and, last, a tick in which a unit the section
/// sees takes a hit from a shooter it does not see. No recording holds one,
/// so the tick is written by hand (COMBAT-57, decision 237).
List<HostMessage> _withUnseenHit(String name) {
  final messages = readStream(name);
  final seen = (messages.first as SectionView).units.first.unitId;
  return [
    ...messages,
    TickUpdate(
      at: messages.whereType<TickUpdate>().last.at,
      unseenHits: [
        UnseenHit(targetId: seen, damage: 12, result: ImpactResult.damaged),
      ],
    ),
  ];
}

/// The units the clear weather shows section `s-2` and the fog hides.
Set<String> _hiddenUnitIds() {
  HeldView held(String name) {
    final view = HeldView();
    readStream(name).forEach(view.apply);
    return view;
  }

  return held('clear_s-2').units.keys
      .toSet()
      .difference(held('fog_s-2').units.keys.toSet());
}
