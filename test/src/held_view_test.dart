import 'package:battle_client/battle_client.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

import '../helpers/streams.dart';

const _ap = ApView(value: 10, at: Duration(hours: 1), perHour: 4, max: 30);

UnitView _unit(
  String id, {
  String section = 's-2',
  String team = 'team-2',
  double hp = 100,
  Position? position = const Position(100, 200, 0),
  UnitPrivate? private,
}) => UnitView(
  unitId: id,
  unitType: 'soldier',
  sectionId: section,
  team: team,
  hp: hp,
  maxHp: 100,
  position: position,
  weapon: 'rifle',
  private: private,
);

const _private = UnitPrivate(
  place: UnitPlace.deployed,
  ap: _ap,
  morale: 1,
  rounds: 10,
  xpEarned: 0,
  xpUnspent: 0,
);

const _section = SectionPrivate(money: 100, xp: 0);

Impact _impact(String target, double damage) => Impact(
  targetId: target,
  targetType: 'soldier',
  damage: damage,
  friendly: false,
  result: ImpactResult.damaged,
);

TickUpdate _tick({
  Duration at = const Duration(hours: 2),
  List<UnitPosition> moved = const [],
  List<UnitView> appeared = const [],
  List<String> gone = const [],
  List<BattleEvent> events = const [],
  List<Burst> bursts = const [],
  List<UnseenHit> unseenHits = const [],
  List<Fired> fired = const [],
  List<UnitView> ownUnits = const [],
  SectionPrivate? section,
  List<HqView> hqs = const [],
  List<String> hqsGone = const [],
  List<RelicView> relics = const [],
}) => TickUpdate(
  at: at,
  moved: moved,
  appeared: appeared,
  gone: gone,
  events: events,
  bursts: bursts,
  unseenHits: unseenHits,
  fired: fired,
  ownUnits: ownUnits,
  section: section,
  hqs: hqs,
  hqsGone: hqsGone,
  relics: relics,
);

SectionView _whole({
  List<UnitView>? units,
  List<BattleEvent> world = const [],
  HoldView? hold,
}) => SectionView(
  at: const Duration(hours: 1),
  section: _section,
  units: units ?? [_unit('own', section: 's-1', private: _private)],
  hqs: const [
    HqView(team: 'team-1', position: Position(0, 0, 0), hp: 1, maxHp: 1),
  ],
  relics: const [RelicView(relicId: 'r-1', position: Position(5, 5, 0))],
  hold: hold,
  world: world,
);

const _wall = [Cell(1, 2)];

void main() {
  group(HeldView, () {
    group('fed a recorded stream of the host', () {
      for (final name in recordedStreams) {
        test('MAP-08 stack decision 3 $name ends equal to the host view of '
            'that section', () {
          final messages = readStream(name);
          final view = HeldView();
          messages.forEach(view.apply);
          final host = hostViewOf(name);

          expect(messages.first, isA<SectionView>());
          expect(view.isWhole, isTrue);
          expect(view.units, equals({for (final u in host.units) u.unitId: u}));
          expect(view.hqs, equals({for (final h in host.hqs) h.team: h}));
          expect(view.relics.values, orderedEquals(host.relics));
          expect(view.section, equals(host.section));
          expect(view.hold, equals(host.hold));
          expect(view.world, orderedEquals(host.world));
        });
      }
    });

    test('holds nothing before a whole view', () {
      final view = HeldView();

      expect(view.isWhole, isFalse);
      expect(view.at, isNull);
      expect(view.units, isEmpty);
      expect(() => view.asSectionView, throwsStateError);
    });

    test('MAP-08 a whole view replaces everything', () {
      final view = HeldView()
        ..apply(
          _whole(
            units: [_unit('old')],
            world: const [
              CraterDug(at: Position(1, 1, 1), radiusM: 2, depthM: 1),
            ],
          ),
        )
        ..apply(_whole());

      expect(view.units.keys, equals(['own']));
      expect(view.world, isEmpty);
      expect(view.asSectionView, equals(_whole()));
    });

    test('messages other than views change nothing', () {
      final view = HeldView()..apply(_whole());
      final before = view.asSectionView;

      <HostMessage>[
        const SignInAccepted(
          accountId: 'a-1',
          sectionId: 's-1',
          team: 'team-1',
          battleTime: Duration.zero,
        ),
        const SignInRefused(SignInRefusal.noSection),
        const CommandAccepted(requestId: 1, seq: 2),
        const CommandRefused(requestId: 1, reason: 'no_ap'),
        const RelicAlert(at: Duration.zero, relicId: 'r-1', team: 'team-2'),
        const Goodbye(GoodbyeReason.idle),
      ].forEach(view.apply);

      expect(view.asSectionView, equals(before));
    });

    test('decision 236 moves, units in and out of sight, HQs and relics', () {
      final view = HeldView()
        ..apply(_whole(units: [_unit('a'), _unit('b')]))
        ..apply(
          _tick(
            moved: const [
              UnitPosition('a', Position(7, 8, 9)),
              UnitPosition('unknown', Position(1, 1, 1)),
            ],
            appeared: [_unit('c')],
            gone: const ['b'],
            hqs: const [
              HqView(
                team: 'team-2',
                position: Position(9, 9, 9),
                hp: 5,
                maxHp: 5,
              ),
            ],
            hqsGone: const ['team-1'],
            relics: const [
              RelicView(
                relicId: 'r-1',
                position: Position(6, 6, 0),
                owner: 'team-2',
              ),
            ],
            section: _section,
          ),
        );

      expect(view.at, equals(const Duration(hours: 2)));
      expect(view.units['a']!.position, equals(const Position(7, 8, 9)));
      expect(view.units.keys, unorderedEquals(['a', 'c']));
      expect(view.hqs.keys, equals(['team-2']));
      expect(view.relics['r-1']!.owner, equals('team-2'));
    });

    test('COMBAT-57 COMBAT-58 hit points follow hits, bursts, shots of '
        'unknown outcome and unseen hits', () {
      final view = HeldView()
        ..apply(_whole(units: [_unit('a'), _unit('b'), _unit('c'), _unit('d')]))
        ..apply(
          _tick(
            events: [
              Attacked(
                attackerId: 'x',
                sectionId: 's-1',
                weapon: 'rifle',
                hit: true,
                impacts: [_impact('a', 10), _impact('nobody', 10)],
              ),
            ],
            bursts: [
              Burst(
                attackerId: 'x',
                sectionId: 's-1',
                weapon: 'machine_gun',
                shots: 3,
                hits: 1,
                impacts: [_impact('b', 120)],
              ),
            ],
            fired: [
              Fired(
                attackerId: 'x',
                sectionId: 's-1',
                weapon: 'rifle',
                shots: 1,
                impacts: [_impact('c', 5)],
              ),
            ],
            unseenHits: const [
              UnseenHit(targetId: 'd', damage: 7, result: ImpactResult.damaged),
            ],
          ),
        );

      expect(view.units['a']!.hp, equals(90));
      expect(view.units['b']!.hp, equals(0));
      expect(view.units['c']!.hp, equals(95));
      expect(view.units['d']!.hp, equals(93));
    });

    test('a unit sent whole, and its own units, already hold their hits and '
        'heals', () {
      final view = HeldView()
        ..apply(
          _whole(
            units: [_unit('own', section: 's-1', hp: 50, private: _private)],
          ),
        )
        ..apply(
          _tick(
            appeared: [_unit('seen', hp: 60)],
            events: [
              Attacked(
                attackerId: 'x',
                sectionId: 's-3',
                weapon: 'rifle',
                hit: true,
                impacts: [_impact('own', 10), _impact('seen', 10)],
              ),
              const UnitHealed(unitId: 'medic', targetId: 'seen', hp: 99),
            ],
          ),
        );

      expect(view.units['own']!.hp, equals(50));
      expect(view.units['seen']!.hp, equals(60));
    });

    test('heals and repairs set the hit points of a unit it sees', () {
      final view = HeldView()
        ..apply(_whole(units: [_unit('a', hp: 10), _unit('b', hp: 10)]))
        ..apply(
          _tick(
            events: const [
              UnitHealed(unitId: 'm', targetId: 'a', hp: 40),
              Repaired(targetId: 'b', hp: 70),
              Repaired(targetId: 'gone', hp: 70),
              UnitStored(unitId: 'a'),
            ],
          ),
        );

      expect(view.units['a']!.hp, equals(40));
      expect(view.units['b']!.hp, equals(70));
      expect(view.units, hasLength(2));
    });

    test('RELIC-16 the victory countdown starts at the update and resets', () {
      final view = HeldView()
        ..apply(_whole())
        ..apply(
          _tick(
            events: const [
              VictoryHoldStarted(team: 'team-1', winsAt: Duration(hours: 50)),
            ],
          ),
        );

      expect(
        view.hold,
        equals(
          const HoldView(
            team: 'team-1',
            since: Duration(hours: 2),
            winsAt: Duration(hours: 50),
          ),
        ),
      );

      view.apply(_tick(events: const [VictoryHoldReset(team: 'team-1')]));

      expect(view.hold, isNull);
    });

    test('MAP-08 the delta layer in the host order: craters, structures, '
        'damaged objects, destroyed ones', () {
      const crater = CraterDug(at: Position(1, 1, 1), radiusM: 2, depthM: 1);
      const built = StructureBuilt(
        siteId: 'w',
        structure: 'wall',
        cells: _wall,
      );
      const destroyed = ObjectDestroyed(object: 'wall', cells: _wall);
      final view = HeldView()
        ..apply(_whole(world: const [built]))
        ..apply(
          _tick(
            events: const [
              ObjectDamaged(object: 'wall', cells: _wall, hp: 30),
              ObjectDamaged(
                object: 'house',
                cells: [Cell(5, 5, island: 'deck')],
                hp: 9,
              ),
              ObjectDamaged(object: 'wall', cells: _wall, hp: 10),
              crater,
            ],
          ),
        );

      expect(view.world, [
        crater,
        built,
        const ObjectDamaged(object: 'wall', cells: _wall, hp: 10),
        const ObjectDamaged(
          object: 'house',
          cells: [Cell(5, 5, island: 'deck')],
          hp: 9,
        ),
      ]);

      view.apply(_tick(events: const [destroyed]));

      expect(view.world, [
        crater,
        built,
        const ObjectDamaged(
          object: 'house',
          cells: [Cell(5, 5, island: 'deck')],
          hp: 9,
        ),
        destroyed,
      ]);
    });

    test('a whole view whose delta layer holds another event is refused', () {
      expect(
        () => HeldView().apply(_whole(world: const [UnitStored(unitId: 'a')])),
        throwsArgumentError,
      );
    });
  });

  group('apAt', () {
    test('COMBAT-02 AP recovers at its rate from its last value', () {
      expect(apAt(_ap, const Duration(hours: 1)), equals(10));
      expect(apAt(_ap, const Duration(hours: 3, minutes: 30)), equals(20));
    });

    test('COMBAT-02 AP stops at its maximum', () {
      expect(apAt(_ap, const Duration(hours: 100)), equals(30));
    });

    test(
      'COMBAT-02 before its time, what the pool can spare, never below 0',
      () {
        expect(apAt(_ap, const Duration(minutes: 30)), equals(8));
        expect(apAt(_ap, Duration.zero), equals(6));
        expect(
          apAt(
            const ApView(value: 1, at: Duration(hours: 5), perHour: 4, max: 30),
            Duration.zero,
          ),
          equals(0),
        );
      },
    );
  });
}
