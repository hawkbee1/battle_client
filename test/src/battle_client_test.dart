// The tests run in fake time, where futures complete on flushes, not awaits.
// ignore_for_file: discarded_futures

import 'dart:async';
import 'dart:math';

import 'package:battle_client/battle_client.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import '../helpers/fakes.dart';

const _accepted = SignInAccepted(
  accountId: 'a-1',
  sectionId: 's-1',
  team: 'team-1',
  battleTime: Duration(hours: 3),
);

const _view = SectionView(
  weather: 'clear',
  at: Duration(hours: 3),
  section: SectionPrivate(money: 5, xp: 0),
  units: [],
  hqs: [],
  relics: [],
  world: [],
);

const _reload = Reload(unitId: 'u-1');

/// A client on [transport] and fake time, signing in with a fresh JWT each
/// time ('jwt-1', 'jwt-2', ...).
final class _Harness {
  new(this.async, {this.settings = const ClientSettings()}) {
    client = BattleClient(
      battleId: 'b-1',
      transport: transport,
      address: (credential) async {
        lookedUpWith.add(credential.secret);
        if (lookup case final lookup?) return await lookup.future;
        if (refusal case final refusal?) throw refusal;
        if (addressFails) throw StateError('no placement');
        return Uri.parse('ws://host-$addresses/v1/socket');
      },
      credential: () async => Credential.jwt('jwt-${++credentials}'),
      clock: FakeClock(async),
      random: Random(7),
      settings: settings,
    );
    client.messages.listen(messages.add);
    client.statuses.listen(statuses.add);
  }

  final FakeAsync async;
  final ClientSettings settings;
  final transport = FakeTransport();
  late final BattleClient client;
  final messages = <HostMessage>[];
  final statuses = <ClientStatus>[];
  int credentials = 0;
  int addresses = 1;
  bool addressFails = false;
  HostLookupException? refusal;
  Completer<Uri>? lookup;
  final lookedUpWith = <String>[];

  FakeSocket get socket => transport.last;

  /// Starts the client and signs it in with its whole view.
  void signIn() {
    client.start();
    async.flushMicrotasks();
    accept();
  }

  /// The host accepts the sign-in on the last socket and sends the view.
  void accept() {
    socket
      ..deliver(_accepted)
      ..deliver(_view);
    async.flushMicrotasks();
  }

  /// Waits the longest backoff, so the client tries again.
  void waitBackoff() => async.elapse(settings.backoff.max);
}

void main() {
  group(BattleClient, () {
    test('stack decision 3 signs in to its battle with a JWT on its first '
        'message and keeps its seat', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();

        expect(h.transport.uris, equals([Uri.parse('ws://host-1/v1/socket')]));
        expect(
          h.socket.sent.first,
          equals(
            const SignIn(
              battleId: 'b-1',
              kind: CredentialKind.jwt,
              credential: 'jwt-1',
            ),
          ),
        );
        expect(h.client.status, equals(ClientStatus.signedIn));
        expect(
          h.statuses,
          equals([ClientStatus.connecting, ClientStatus.signedIn]),
        );
        expect(
          h.client.seat,
          equals((accountId: 'a-1', sectionId: 's-1', team: 'team-1')),
        );
        expect(h.client.view.isWhole, isTrue);
        expect(h.messages, equals([_accepted, _view]));
      });
    });

    test('AI-04 signs in with an API key', () {
      fakeAsync((async) {
        final transport = FakeTransport();
        BattleClient(
          battleId: 'b-1',
          transport: transport,
          address: (_) async => Uri.parse('ws://h/v1/socket'),
          credential: () async => const Credential.apiKey('btk_secret'),
          clock: FakeClock(async),
          random: Random(1),
        ).start();
        async.flushMicrotasks();

        expect(
          transport.last.sent.single,
          equals(
            const SignIn(
              battleId: 'b-1',
              kind: CredentialKind.apiKey,
              credential: 'btk_secret',
            ),
          ),
        );
      });
    });

    test('starts once', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();

        expect(h.client.start, throwsStateError);
      });
    });

    test('stack decision 8 the battle time and the AP shown run on from the '
        "host's last message", () {
      fakeAsync((async) {
        final h = _Harness(async);
        const ap = ApView(
          value: 4,
          at: Duration(hours: 3),
          perHour: 2,
          max: 30,
        );

        expect(h.client.battleTime, isNull);
        expect(h.client.apNow(ap), isNull);

        h.signIn();
        async.elapse(const Duration(minutes: 90));

        expect(
          h.client.battleTime,
          equals(const Duration(hours: 4, minutes: 30)),
        );
        expect(h.client.apNow(ap), equals(7));

        h.socket.deliver(
          const RelicAlert(at: Duration(hours: 10), relicId: 'r', team: 't'),
        );
        async.flushMicrotasks();

        expect(h.client.battleTime, equals(const Duration(hours: 10)));
      });
    });

    test('ECO-04 M7.7 the roster is held and passed on, and says nothing of '
        'the battle time', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        const roster = Roster(
          units: [
            RosterUnit(unitType: 'soldier', category: 'soldier', price: 100),
          ],
          weapons: [RosterWeapon(weapon: 'rifle', price: 100)],
        );
        final before = h.client.battleTime;

        h.socket.deliver(roster);
        async.flushMicrotasks();

        expect(h.client.view.roster, equals(roster));
        expect(h.messages.last, equals(roster));
        expect(h.client.battleTime, equals(before));
      });
    });

    test('MAP-08 keeps the view from the whole view and the updates', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        h.socket.deliver(
          const TickUpdate(
            at: Duration(hours: 4),
            section: SectionPrivate(money: 9, xp: 1),
          ),
        );
        async.flushMicrotasks();

        expect(h.client.view.section!.money, equals(9));
        expect(h.client.battleTime, equals(const Duration(hours: 4)));
      });
    });

    group('commands', () {
      test('are refused before the first sign-in', () {
        fakeAsync((async) {
          final h = _Harness(async);

          expect(() => h.client.send(_reload), throwsStateError);
        });
      });

      test('go out as the signed-in section at the battle time and get their '
          'answers by request ID', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          async.elapse(const Duration(seconds: 2));
          final answers = <CommandAnswer>[];

          h.client.send(_reload).then(answers.add);
          h.client.send(const Reload(unitId: 'u-2')).then(answers.add);
          async.flushMicrotasks();
          final [first, second] = h.socket.commands;

          expect(
            first.command,
            equals(
              const Command(
                sender: Sender(accountId: 'a-1', sectionId: 's-1'),
                sentAt: Duration(hours: 3, seconds: 2),
                order: _reload,
              ),
            ),
          );
          expect(second.requestId, greaterThan(first.requestId));
          expect(h.client.unanswered, [first.requestId, second.requestId]);

          h.socket
            ..deliver(
              CommandRefused(requestId: second.requestId, reason: 'no_ap'),
            )
            ..deliver(CommandAccepted(requestId: first.requestId, seq: 41))
            ..deliver(const CommandAccepted(requestId: 999, seq: 42));
          async.flushMicrotasks();

          expect(answers, hasLength(2));
          expect(answers.first.requestId, equals(second.requestId));
          expect(answers.first.accepted, isFalse);
          expect(answers.first.refusal, equals('no_ap'));
          expect(answers.last.accepted, isTrue);
          expect(answers.last.seq, equals(41));
          expect(h.client.unanswered, isEmpty);
        });
      });

      test('AI-02 sent while the host is lost go out once the client signs '
          'in again', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          h.socket.drop();
          async.flushMicrotasks();

          expect(h.client.status, equals(ClientStatus.waiting));

          final answer = h.client.send(_reload);
          h
            ..waitBackoff()
            ..accept();

          final [sent] = h.socket.commands;
          expect(sent.command.order, equals(_reload));
          var done = false;
          answer.then((_) => done = true);
          h.socket.deliver(CommandAccepted(requestId: sent.requestId, seq: 1));
          async.flushMicrotasks();
          expect(done, isTrue);
        });
      });

      test('stack decision 3 a socket dropped with a command in flight: the '
          'client signs in again, takes its whole view and resends the '
          'command with its request ID; the answer comes once', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          final answers = <CommandAnswer>[];
          h.client.send(_reload).then(answers.add);
          async.flushMicrotasks();
          final [inFlight] = h.socket.commands;
          final first = h.socket..drop();
          async.flushMicrotasks();
          h.waitBackoff();

          expect(first.closed, isTrue);
          expect(h.transport.sockets, hasLength(2));
          expect(
            (h.socket.sent.single as SignIn).credential,
            equals('jwt-2'),
            reason: 'a fresh JWT at each sign-in',
          );

          h.accept();

          expect(h.socket.commands, equals([inFlight]));
          expect(h.client.view.isWhole, isTrue);

          h.socket.deliver(
            CommandAccepted(requestId: inFlight.requestId, seq: 7),
          );
          h.socket.deliver(
            CommandAccepted(requestId: inFlight.requestId, seq: 7),
          );
          async.flushMicrotasks();

          expect(answers, hasLength(1));
          expect(answers.single.seq, equals(7));
        });
      });

      test('sent by a listener as the client signs in again go out once, '
          'after the unanswered ones', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          h.client.send(_reload);
          async.flushMicrotasks();
          h.socket.drop();
          async.flushMicrotasks();
          h.client.statuses.listen((status) {
            if (status == ClientStatus.signedIn) {
              h.client.send(const Reload(unitId: 'u-2'));
            }
          });
          h
            ..waitBackoff()
            ..accept();

          expect(
            h.socket.commands.map((sent) => sent.command.order),
            equals([_reload, const Reload(unitId: 'u-2')]),
          );
        });
      });

      test('fail when the client stops with them unanswered', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          Object? error;
          h.client.send(_reload).catchError((Object e) {
            error = e;
            return const CommandAnswer(requestId: 0);
          });
          async.flushMicrotasks();
          h.socket.deliver(const Goodbye(GoodbyeReason.battleEnded));
          async.flushMicrotasks();

          expect(
            error,
            isA<ClientStoppedException>().having(
              (e) => e.stoppedBy,
              'stoppedBy',
              equals(const Goodbye(GoodbyeReason.battleEnded)),
            ),
          );
          expect(error.toString(), contains('battleEnded'));
          expect(() => h.client.send(_reload), throwsStateError);
        });
      });
    });

    test('stack decision 3 sends a heartbeat every 20 s while signed in', () {
      fakeAsync((async) {
        final h = _Harness(async)..signIn();
        async.elapse(const Duration(seconds: 61));

        expect(h.socket.sent.whereType<Heartbeat>(), hasLength(3));

        h.socket.drop();
        async.flushMicrotasks();
        final socket = h.socket;
        async.elapse(const Duration(seconds: 1));

        expect(socket.sent.whereType<Heartbeat>(), hasLength(3));
      });
    });

    test('MAP-08 asks for its whole view again when signed in', () {
      fakeAsync((async) {
        final h = _Harness(async)
          ..client.resync()
          ..signIn()
          ..client.resync();
        async.flushMicrotasks();

        expect(h.socket.sent.last, equals(const ResyncRequest()));
        expect(h.socket.sent.whereType<ResyncRequest>(), hasLength(1));
      });
    });

    group('reconnection', () {
      test('waits longer after each failed attempt, up to its maximum, and '
          'from the start again once signed in', () {
        fakeAsync((async) {
          const settings = ClientSettings(
            backoff: Backoff(
              first: Duration(seconds: 1),
              max: Duration(seconds: 8),
            ),
          );
          final h = _Harness(async, settings: settings);
          h.transport.failures = 6;
          final attempts = <Duration>[];
          h.client.statuses.listen((status) {
            if (status == ClientStatus.connecting) attempts.add(async.elapsed);
          });

          h.client.start();
          async.elapse(const Duration(minutes: 1));
          final waits = [
            for (var i = 1; i < attempts.length; i++)
              attempts[i] - attempts[i - 1],
          ];

          expect(h.transport.uris, hasLength(7));
          expect(waits, hasLength(6));
          for (final (attempt, wait) in waits.indexed) {
            final ceiling = Duration(seconds: min(8, 1 << attempt));
            expect(wait, greaterThanOrEqualTo(ceiling ~/ 2));
            expect(wait, lessThanOrEqualTo(ceiling));
          }

          h.accept();
          h.socket.drop();
          async.flushMicrotasks();
          final dropped = async.elapsed;
          async.elapse(const Duration(seconds: 2));

          expect(h.transport.uris, hasLength(8));
          expect(
            attempts.last - dropped,
            lessThanOrEqualTo(const Duration(seconds: 1)),
          );
        });
      });

      test('M6 Issue 6 asks for the address and a credential again at each '
          'attempt, and survives their failures', () {
        fakeAsync((async) {
          final h = _Harness(async)..addressFails = true;
          h.client.start();
          async.flushMicrotasks();

          expect(h.transport.uris, isEmpty);

          h
            ..addressFails = false
            ..addresses = 2
            ..waitBackoff();

          expect(
            h.transport.uris.single,
            equals(Uri.parse('ws://host-2/v1/socket')),
          );
        });
      });

      test('M6 Issue 6 asks for the address with the credential of the '
          'attempt, again while no host runs the battle', () {
        fakeAsync((async) {
          final h = _Harness(async)
            ..refusal = const HostLookupException('no_host', status: 503);
          h.client.start();
          async.flushMicrotasks();
          h.waitBackoff();

          expect(h.client.status, equals(ClientStatus.waiting));
          expect(h.transport.uris, isEmpty);

          h
            ..refusal = null
            ..waitBackoff();

          // Each attempt asks with the fresh JWT it got.
          expect(h.lookedUpWith.length, greaterThan(2));
          expect(
            h.lookedUpWith,
            equals([for (var i = 1; i <= h.lookedUpWith.length; i++) 'jwt-$i']),
          );
          expect(h.credentials, equals(h.lookedUpWith.length));
          expect(h.transport.uris, hasLength(1));
        });
      });

      test('comes back after a broken socket or a frame it does not read', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          h.socket.fail(StateError('reset by peer'));
          async.flushMicrotasks();

          expect(h.client.status, equals(ClientStatus.waiting));

          h
            ..waitBackoff()
            ..accept();
          h.socket.deliverBytes([0xff, 0xff]);
          async.flushMicrotasks();

          expect(h.client.status, equals(ClientStatus.waiting));
          expect(h.transport.sockets, hasLength(2));
          expect(h.transport.sockets.every((s) => s.closed), isTrue);
        });
      });

      for (final reason in [GoodbyeReason.slowClient, GoodbyeReason.idle]) {
        test('stack decision 3 a goodbye for a ${reason.name} client is a '
            'lost host', () {
          fakeAsync((async) {
            final h = _Harness(async)..signIn();
            h.socket.deliver(Goodbye(reason));
            async.flushMicrotasks();

            expect(h.client.status, equals(ClientStatus.waiting));
            expect(h.messages.last, equals(Goodbye(reason)));

            h
              ..waitBackoff()
              ..accept();

            expect(h.client.status, equals(ClientStatus.signedIn));
          });
        });
      }

      test('M6 Issue 6 a battle not on this host is looked for again', () {
        fakeAsync((async) {
          final h = _Harness(async);
          h.client.start();
          async.flushMicrotasks();
          h.socket.deliver(const SignInRefused(SignInRefusal.battleNotFound));
          async.flushMicrotasks();

          expect(h.client.status, equals(ClientStatus.waiting));

          h
            ..waitBackoff()
            ..accept();

          expect(h.client.status, equals(ClientStatus.signedIn));
        });
      });
    });

    group('SOC-30 a section the host has not admitted yet', () {
      test('is asked for again after a backoff, and the client signs in once '
          'the host has admitted it', () {
        fakeAsync((async) {
          final h = _Harness(async);
          h.client.start();
          async.flushMicrotasks();
          h.socket.deliver(const SignInRefused(SignInRefusal.noSection));
          async.flushMicrotasks();

          expect(h.client.status, equals(ClientStatus.waiting));
          expect(h.client.stoppedBy, isNull);

          h
            ..waitBackoff()
            ..accept();

          expect(h.client.status, equals(ClientStatus.signedIn));
          expect(h.transport.sockets, hasLength(2));
        });
      });

      test('is asked for [ClientSettings.seatRetries] times, then the client '
          'stops', () {
        fakeAsync((async) {
          final h = _Harness(
            async,
            settings: const ClientSettings(seatRetries: 2),
          );
          h.client.start();
          async.flushMicrotasks();
          for (var refusal = 1; refusal <= 3; refusal++) {
            h.socket.deliver(const SignInRefused(SignInRefusal.noSection));
            async.flushMicrotasks();
            if (refusal < 3) {
              expect(h.client.status, equals(ClientStatus.waiting));
              h.waitBackoff();
            }
          }

          expect(h.client.status, equals(ClientStatus.stopped));
          expect(
            h.client.stoppedBy,
            equals(const SignInRefused(SignInRefusal.noSection)),
          );
          expect(h.transport.sockets, hasLength(3));
        });
      });

      test('is counted again after a sign-in, not for the life of the '
          'client', () {
        fakeAsync((async) {
          final h = _Harness(
            async,
            settings: const ClientSettings(seatRetries: 1),
          )..signIn();
          h.socket.deliver(const Goodbye(GoodbyeReason.idle));
          async.flushMicrotasks();
          h
            ..waitBackoff()
            ..socket.deliver(const SignInRefused(SignInRefusal.noSection));
          async.flushMicrotasks();

          // One refusal in a row is within the one retry allowed.
          expect(h.client.status, equals(ClientStatus.waiting));
        });
      });

      test('with no seat retry, the refusal stops the client at once', () {
        fakeAsync((async) {
          final h = _Harness(
            async,
            settings: const ClientSettings(seatRetries: 0),
          );
          h.client.start();
          async.flushMicrotasks();
          h.socket.deliver(const SignInRefused(SignInRefusal.noSection));
          async.elapse(const Duration(minutes: 5));

          expect(h.client.status, equals(ClientStatus.stopped));
          expect(h.transport.sockets, hasLength(1));
        });
      });
    });

    group('stops for good', () {
      for (final refusal in [SignInRefusal.invalidCredential]) {
        test('on a sign-in refused for ${refusal.name}', () {
          fakeAsync((async) {
            final h = _Harness(async);
            var stopped = false;
            h.client.stopped.then((_) => stopped = true);
            h.client.start();
            async.flushMicrotasks();
            h.socket.deliver(SignInRefused(refusal));
            async.elapse(const Duration(minutes: 5));

            expect(stopped, isTrue);
            expect(h.client.status, equals(ClientStatus.stopped));
            expect(h.client.stoppedBy, equals(SignInRefused(refusal)));
            expect(h.transport.sockets, hasLength(1));
          });
        });
      }

      for (final reason in [
        GoodbyeReason.battleEnded,
        GoodbyeReason.keyRevoked,
        GoodbyeReason.unsupportedVersion,
      ]) {
        test('decision 161 on a goodbye for ${reason.name}', () {
          fakeAsync((async) {
            final h = _Harness(async)..signIn();
            h.socket.deliver(Goodbye(reason));
            async.elapse(const Duration(minutes: 5));

            expect(h.client.status, equals(ClientStatus.stopped));
            expect(h.client.stoppedBy, equals(Goodbye(reason)));
            expect(h.socket.closed, isTrue);
            expect(h.transport.sockets, hasLength(1));
            expect(h.statuses.last, equals(ClientStatus.stopped));
          });
        });
      }

      for (final (code, status) in [
        ('not_your_battle', 403),
        ('not_running', 409),
        ('unknown_battle', 404),
        ('user_jwt_invalid', 401),
      ]) {
        test('M6 Issue 6 when the address is refused for $code, failing its '
            'unanswered commands', () {
          fakeAsync((async) {
            final h = _Harness(async)..signIn();
            Object? failed;
            h.client
                .send(_reload)
                .then(
                  (_) {},
                  onError: (Object e) {
                    failed = e;
                  },
                );
            h.refusal = HostLookupException(code, status: status);
            h.socket.fail(StateError('reset by peer'));
            async
              ..flushMicrotasks()
              ..elapse(const Duration(minutes: 5));

            expect(h.client.status, equals(ClientStatus.stopped));
            expect(h.client.stoppedBy, isNull);
            expect(h.client.lookupRefused!.code, equals(code));
            expect(
              failed,
              isA<ClientStoppedException>().having(
                (e) => e.lookupRefused?.status,
                'lookupRefused',
                status,
              ),
            );
            expect('$failed', contains(code));
            expect(h.transport.sockets, hasLength(1));
          });
        });
      }

      test('when closed while it asks for the address', () {
        fakeAsync((async) {
          final h = _Harness(async)..lookup = Completer();
          h.client.start();
          async.flushMicrotasks();
          h.client.close();
          h.lookup!.completeError(
            const HostLookupException('not_your_battle', status: 403),
          );
          async.elapse(const Duration(minutes: 5));

          expect(h.client.status, equals(ClientStatus.stopped));
          expect(h.client.lookupRefused, isNull);
          expect(h.transport.sockets, isEmpty);
        });
      });

      test('when closed while signed in: the socket closes', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          h.client.close();
          async.elapse(const Duration(minutes: 5));

          expect(h.client.status, equals(ClientStatus.stopped));
          expect(h.client.stoppedBy, isNull);
          expect(h.socket.closed, isTrue);
          expect(h.transport.sockets, hasLength(1));

          h.client.close();
          async.flushMicrotasks();
        });
      });

      test('when closed while waiting to try again', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          h.socket.drop();
          async.flushMicrotasks();
          h.client.close();
          async.elapse(const Duration(minutes: 5));

          expect(h.client.status, equals(ClientStatus.stopped));
          expect(h.transport.sockets, hasLength(1));
        });
      });

      test('when closed while a socket opens: the socket closes once open', () {
        fakeAsync((async) {
          final h = _Harness(async);
          h.transport.held = Completer();
          h.client.start();
          async.flushMicrotasks();
          h.client.close();
          h.transport.held!.complete();
          async.elapse(const Duration(minutes: 5));

          expect(h.transport.sockets.single.closed, isTrue);
          expect(h.transport.sockets.single.sent, isEmpty);
        });
      });

      test('when closed before a frame is handled: the frame is dropped', () {
        fakeAsync((async) {
          final h = _Harness(async)..signIn();
          h.client.messages.listen((message) {
            if (message is TickUpdate) h.client.close();
          });
          h.socket
            ..deliver(const TickUpdate(at: Duration(hours: 4)))
            ..deliver(const TickUpdate(at: Duration(hours: 5)));
          async.flushMicrotasks();

          expect(h.client.view.at, equals(const Duration(hours: 4)));
        });
      });
    });
  });

  group(Credential, () {
    test('hides its secret', () {
      expect(
        const Credential.jwt('a.b.c').toString(),
        equals('Credential(jwt)'),
      );
      expect(
        const Credential.apiKey('btk_x').toString(),
        equals('Credential(apiKey)'),
      );
    });
  });

  group(CommandAnswer, () {
    test('is accepted with a sequence number', () {
      expect(const CommandAnswer(requestId: 1, seq: 2).accepted, isTrue);
      expect(const CommandAnswer(requestId: 1, refusal: 'x').accepted, isFalse);
    });
  });
}
