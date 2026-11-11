// The tests run in fake time, where futures complete on flushes, not awaits.

import 'dart:async';
import 'dart:math';

import 'package:battle_client/battle_client.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import '../../helpers/fakes.dart';

const _private = UnitPrivate(
  sightRangeM: 60,
  place: UnitPlace.deployed,
  ap: ApView(value: 30, at: Duration.zero, perHour: 4, max: 30),
  morale: 1,
  rounds: 10,
  xpEarned: 0,
  xpUnspent: 0,
);

UnitView _unit(
  String id,
  int x, {
  String section = 's-9',
  String team = 'team-2',
  double hp = 100,
  String? weapon = 'rifle',
  UnitPrivate? private,
  bool onField = true,
}) => UnitView(
  unitId: id,
  unitType: 'soldier',
  sectionId: section,
  team: team,
  hp: hp,
  maxHp: 100,
  position: onField ? Position(x, 0, 0) : null,
  weapon: weapon,
  private: private,
);

UnitView _own(
  String id,
  int x, {
  String? weapon = 'rifle',
  UnitPrivate? private,
}) => _unit(
  id,
  x,
  section: 's-1',
  team: 'team-1',
  weapon: weapon,
  private: private ?? _private,
);

SectionView _view(List<UnitView> units) => SectionView(
  weather: 'clear',
  at: Duration.zero,
  section: const SectionPrivate(money: 0, xp: 0),
  units: units,
  hqs: const [],
  relics: const [],
  world: const [],
);

HeldView _held(List<UnitView> units) => HeldView()..apply(_view(units));

void main() {
  group(NearestEnemyAgent, () {
    group('orders', () {
      test('AI-03 each of its units on the field with a weapon fires at the '
          'nearest enemy its section sees', () {
        final view = _held([
          _own('a', 0),
          _own('b', 1000),
          _own('unarmed', 0, weapon: null),
          _own(
            'stored',
            0,
            private: const UnitPrivate(
              sightRangeM: 60,
              place: UnitPlace.stored,
              ap: ApView(value: 30, at: Duration.zero, perHour: 4, max: 30),
              morale: 1,
              rounds: 10,
              xpEarned: 0,
              xpUnspent: 0,
            ),
          ),
          _unit('ally', 10, section: 's-2', team: 'team-1'),
          _unit('near', 100),
          _unit('far', 900),
          _unit('dead', 1, hp: 0),
          _unit('prisoner', 1, onField: false),
        ]);

        expect(NearestEnemyAgent.orders(view, 's-1', 'team-1'), [
          const Fire(unitId: 'a', targetId: 'near'),
          const Fire(unitId: 'b', targetId: 'far'),
        ]);
      });

      test('nothing while its section sees no enemy', () {
        final view = _held([_own('a', 0), _unit('ally', 1, team: 'team-1')]);

        expect(NearestEnemyAgent.orders(view, 's-1', 'team-1'), isEmpty);
      });

      test('a dead unit of its own does not fire', () {
        final view = _held([
          const UnitView(
            unitId: 'a',
            unitType: 'soldier',
            sectionId: 's-1',
            team: 'team-1',
            hp: 0,
            maxHp: 100,
            position: Position(0, 0, 0),
            weapon: 'rifle',
            private: _private,
          ),
          _unit('enemy', 5),
        ]);

        expect(NearestEnemyAgent.orders(view, 's-1', 'team-1'), isEmpty);
      });
    });

    test('AI-03 AI-04 fires on each view and update, and a unit waits for '
        'its answer before it fires again', () {
      fakeAsync((async) {
        final transport = FakeTransport();
        final client = BattleClient(
          battleId: 'b-1',
          transport: transport,
          address: (_) async => Uri.parse('ws://h/v1/socket'),
          credential: () async => const Credential.apiKey('btk_x'),
          clock: FakeClock(async),
          random: Random(1),
        );
        final agent = NearestEnemyAgent(client);
        final subscription = agent.start();
        client.start();
        async.flushMicrotasks();
        transport.last
          ..deliver(
            const SignInAccepted(
              accountId: 'a-1',
              sectionId: 's-1',
              team: 'team-1',
              battleTime: Duration.zero,
            ),
          )
          ..deliver(_view([_own('a', 0), _unit('enemy', 50)]));
        async.flushMicrotasks();

        final [first] = transport.last.commands;
        expect(first.command.order, const Fire(unitId: 'a', targetId: 'enemy'));

        transport.last.deliver(const TickUpdate(at: Duration(seconds: 1)));
        async.flushMicrotasks();
        expect(transport.last.commands, hasLength(1));

        transport.last.deliver(
          CommandRefused(requestId: first.requestId, reason: 'out_of_range'),
        );
        async.flushMicrotasks();
        transport.last.deliver(const TickUpdate(at: Duration(seconds: 2)));
        async.flushMicrotasks();

        expect(transport.last.commands, hasLength(2));
        expect(agent.answers.single.$2.refusal, equals('out_of_range'));

        transport.last.deliver(const Goodbye(GoodbyeReason.battleEnded));
        async.flushMicrotasks();

        expect(agent.answers, hasLength(1), reason: 'a stopped order fails');
        unawaited(subscription.cancel());
      });
    });
  });
}
