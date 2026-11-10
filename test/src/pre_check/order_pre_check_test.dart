import 'dart:io';

import 'package:battle_client/battle_client.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart'
    show BattleSettings, CombatData, UnitsData;
import 'package:test/test.dart';

/// The plan's own files, read from the hawkbee checkout (stack decision 7).
String _plan(String file) =>
    File('../../apps/battle_team/plan/data/$file').readAsStringSync();

/// A unit on the field at [x] and [y] metres east and south, with its weapon,
/// [rounds] in the magazine and an AP pool of [ap] AP at hour 1.
UnitView unit(
  String id, {
  String type = 'soldier',
  String? weapon = 'rifle',
  double x = 100,
  double y = 100,
  int rounds = 10,
  double ap = 30,
  double apMax = 30,
  double apPerHour = 1,
  bool flying = false,
  UnitPlace place = UnitPlace.deployed,
}) => UnitView(
  unitId: id,
  unitType: type,
  sectionId: 's-blue',
  team: 'blue',
  hp: 100,
  maxHp: 100,
  position: place == UnitPlace.deployed ? Position.metres(x, y, 0) : null,
  flying: flying,
  weapon: weapon,
  private: UnitPrivate(
    place: place,
    ap: ApView(
      value: ap,
      at: const Duration(hours: 1),
      perHour: apPerHour,
      max: apMax,
    ),
    morale: 50,
    rounds: rounds,
    xpEarned: 0,
    xpUnspent: 0,
  ),
);

/// An enemy the section sees at [x] and [y] metres.
UnitView enemy({double x = 200, double y = 100, bool flying = false}) =>
    UnitView(
      unitId: 'r-1',
      unitType: 'soldier',
      sectionId: 's-red',
      team: 'red',
      hp: 100,
      maxHp: 100,
      position: Position.metres(x, y, 0),
      flying: flying,
      weapon: 'rifle',
    );

const _now = Duration(hours: 1);

/// The section's storage place: its HQ.
const _hq = Position(0, 0, 0);

void main() {
  late OrderPreCheck check;

  setUpAll(() {
    check = OrderPreCheck(
      combat: CombatData.parse(_plan('combat.yaml')),
      units: UnitsData.parse(_plan('units.yaml')),
      storage: BattleSettings.parse(_plan('battle.yaml')).storage,
    );
  });

  group(OrderPreCheck, () {
    group('fire', () {
      test('COMBAT-11 passes at a seen target within range', () {
        expect(
          check.fire(shooter: unit('u-1'), target: enemy(), time: _now),
          const PreCheckPassed(),
        );
      });

      test('COMBAT-11 a target the section does not see is refused', () {
        expect(
          check.fire(shooter: unit('u-1'), target: null, time: _now),
          const PreCheckRefused(PreCheckRefusal.targetNotSeen),
        );
      });

      test('COMBAT-11 a unit that is not on the field is no target', () {
        final stored = unit('r-1', place: UnitPlace.stored);
        expect(
          check.fire(shooter: unit('u-1'), target: stored, time: _now),
          const PreCheckRefused(PreCheckRefusal.targetNotSeen),
        );
      });

      test('COMBAT-11 a target beyond the weapon range is out of range', () {
        // The rifle reaches 400 m.
        final far = enemy(x: 100 + 401);
        expect(
          check.fire(shooter: unit('u-1'), target: far, time: _now),
          const PreCheckRefused(PreCheckRefusal.outOfRange),
        );
        final edge = enemy(x: 100 + 399);
        expect(
          check.fire(shooter: unit('u-1'), target: edge, time: _now),
          const PreCheckPassed(),
        );
      });

      test('COMBAT-11 range is the horizontal distance, height apart', () {
        // 300 m east and 300 m south is 424 m, beyond the rifle's 400 m.
        final diagonal = enemy(x: 100 + 300, y: 100 + 300);
        expect(
          check.fire(shooter: unit('u-1'), target: diagonal, time: _now),
          const PreCheckRefused(PreCheckRefusal.outOfRange),
        );
      });

      test('COMBAT-25 a weapon that cannot hit flying refuses a flier', () {
        // Artillery has an airborne factor of 0; the rifle's is 0.2.
        final gun = unit('u-1', type: 'artillery', weapon: 'artillery');
        expect(
          check.fire(shooter: gun, target: enemy(flying: true), time: _now),
          const PreCheckRefused(PreCheckRefusal.cannotHitFlying),
        );
        expect(
          check.fire(
            shooter: unit('u-1'),
            target: enemy(flying: true),
            time: _now,
          ),
          const PreCheckPassed(),
        );
      });

      test('COMBAT-13 a unit with no weapon cannot fire', () {
        final radio = unit('u-1', type: 'radio', weapon: null);
        expect(
          check.fire(shooter: radio, target: enemy(), time: _now),
          const PreCheckRefused(PreCheckRefusal.noWeapon),
        );
      });

      test('UNIT-38 a unit that is not on the field cannot fire', () {
        final stored = unit('u-1', place: UnitPlace.stored);
        expect(
          check.fire(shooter: stored, target: enemy(), time: _now),
          const PreCheckRefused(PreCheckRefusal.notOnField),
        );
      });

      test('COMBAT-33 an empty magazine must be reloaded first', () {
        expect(
          check.fire(
            shooter: unit('u-1', rounds: 0),
            target: enemy(),
            time: _now,
          ),
          const PreCheckRefused(PreCheckRefusal.emptyMagazine),
        );
      });

      test('COMBAT-04 a shot with the AP passes at once', () {
        expect(
          check.fire(shooter: unit('u-1', ap: 2), target: enemy(), time: _now),
          const PreCheckPassed(),
        );
      });

      test('COMBAT-06 a shot without the AP waits for them, not refused', () {
        // The rifle costs 2 AP; the unit has 0.5 and regains 1 an hour: it
        // waits 1.5 h.
        expect(
          check.fire(
            shooter: unit('u-1', ap: 0.5),
            target: enemy(),
            time: _now,
          ),
          const PreCheckPassed(apWait: Duration(hours: 1, minutes: 30)),
        );
      });

      test('COMBAT-06 the AP regained since the update count', () {
        // 0.5 AP at hour 1 and 1.5 h later it is 2.0: nothing to wait for.
        expect(
          check.fire(
            shooter: unit('u-1', ap: 0.5),
            target: enemy(),
            time: const Duration(hours: 2, minutes: 30),
          ),
          const PreCheckPassed(),
        );
      });

      test(
        'COMBAT-06 a shot dearer than the pool can ever hold is refused',
        () {
          // The anti-tank weapon costs 10 AP.
          final shooter = unit('u-1', weapon: 'anti_tank', apMax: 5);
          expect(
            check.fire(shooter: shooter, target: enemy(), time: _now),
            const PreCheckRefused(PreCheckRefusal.costAboveApMax),
          );
        },
      );

      test('a weapon this client does not know is left to the host', () {
        final odd = unit('u-1', weapon: 'death_ray');
        expect(
          check.fire(shooter: odd, target: enemy(), time: _now),
          const PreCheckPassed(),
        );
        // A target is still needed: the section's view is the client's own.
        expect(
          check.fire(shooter: odd, target: null, time: _now),
          const PreCheckRefused(PreCheckRefusal.targetNotSeen),
        );
        expect(check.weaponType('death_ray'), isNull);
        expect(check.weaponType('rifle')?.rangeM, 400);
      });
    });

    group('fire at a position', () {
      final gun = unit('u-1', type: 'artillery', weapon: 'artillery');

      test('COMBAT-12 indirect fire aims at a ground position in range', () {
        expect(
          check.fireAtPosition(
            shooter: gun,
            target: Position.metres(100 + 1000, 100, 0),
            time: _now,
          ),
          const PreCheckPassed(),
        );
      });

      test('COMBAT-12 a position beyond the range is out of range', () {
        expect(
          check.fireAtPosition(
            shooter: gun,
            target: Position.metres(100 + 1201, 100, 0),
            time: _now,
          ),
          const PreCheckRefused(PreCheckRefusal.outOfRange),
        );
      });

      test('COMBAT-12 a direct-fire weapon cannot fire at a position', () {
        expect(
          check.fireAtPosition(
            shooter: unit('u-1'),
            target: Position.metres(150, 100, 0),
            time: _now,
          ),
          const PreCheckRefused(PreCheckRefusal.notIndirect),
        );
      });

      test('COMBAT-55 the explosive charge may aim at a point near it', () {
        final engineer = unit('u-1', type: 'engineer', weapon: 'explosive');
        expect(
          check.fireAtPosition(
            shooter: engineer,
            target: Position.metres(103, 100, 0),
            time: _now,
          ),
          const PreCheckPassed(),
        );
        expect(
          check.fireAtPosition(
            shooter: engineer,
            target: Position.metres(106, 100, 0),
            time: _now,
          ),
          const PreCheckRefused(PreCheckRefusal.outOfRange),
        );
      });

      test('COMBAT-13 a unit with no weapon cannot fire at a position', () {
        expect(
          check.fireAtPosition(
            shooter: unit('u-1', type: 'radio', weapon: null),
            target: Position.metres(150, 100, 0),
            time: _now,
          ),
          const PreCheckRefused(PreCheckRefusal.noWeapon),
        );
      });

      test('a weapon this client does not know is left to the host', () {
        expect(
          check.fireAtPosition(
            shooter: unit('u-1', weapon: 'death_ray'),
            target: Position.metres(150, 100, 0),
            time: _now,
          ),
          const PreCheckPassed(),
        );
      });
    });

    group('fire aimed', () {
      test('COMBAT-14 a weapon whose shots fly is aimed in first person', () {
        expect(
          check.fireAimed(shooter: unit('u-1'), time: _now),
          const PreCheckPassed(),
        );
      });

      test('decision 183 artillery does not fly: it is not aimed', () {
        expect(
          check.fireAimed(
            shooter: unit('u-1', type: 'artillery', weapon: 'artillery'),
            time: _now,
          ),
          const PreCheckRefused(PreCheckRefusal.notAimed),
        );
      });

      test('COMBAT-13 a unit with no weapon cannot fire aimed', () {
        expect(
          check.fireAimed(
            shooter: unit('u-1', type: 'radio', weapon: null),
            time: _now,
          ),
          const PreCheckRefused(PreCheckRefusal.noWeapon),
        );
      });

      test('COMBAT-33 an empty magazine must be reloaded first', () {
        expect(
          check.fireAimed(shooter: unit('u-1', rounds: 0), time: _now),
          const PreCheckRefused(PreCheckRefusal.emptyMagazine),
        );
      });

      test('a weapon this client does not know is left to the host', () {
        expect(
          check.fireAimed(
            shooter: unit('u-1', weapon: 'death_ray'),
            time: _now,
          ),
          const PreCheckPassed(),
        );
      });
    });

    group('reload', () {
      test('COMBAT-33 an armed unit reloads, with no AP', () {
        expect(check.reload(unit('u-1', ap: 0)), const PreCheckPassed());
      });

      test('COMBAT-13 a unit with no weapon has nothing to reload', () {
        expect(
          check.reload(unit('u-1', type: 'radio', weapon: null)),
          const PreCheckRefused(PreCheckRefusal.noWeapon),
        );
      });

      test('UNIT-38 a unit that is not on the field does not reload', () {
        expect(
          check.reload(unit('u-1', place: UnitPlace.stored)),
          const PreCheckRefused(PreCheckRefusal.notOnField),
        );
      });
    });

    group('swap', () {
      const hq = Position(10000, 10000, 0);

      test('COMBAT-28 swaps at the storage place with a spare weapon', () {
        expect(
          check.swap(
            unit: unit('u-1', x: 105),
            weapon: 'machine_gun',
            stored: const ['machine_gun'],
            storage: hq,
          ),
          const PreCheckPassed(),
        );
      });

      test('COMBAT-28 away from the storage place it is refused', () {
        expect(
          check.swap(
            unit: unit('u-1', x: 150),
            weapon: 'machine_gun',
            stored: const ['machine_gun'],
            storage: hq,
          ),
          const PreCheckRefused(PreCheckRefusal.notAtStorage),
        );
      });

      test('COMBAT-28 a section that sees no storage place cannot swap', () {
        expect(
          check.swap(
            unit: unit('u-1'),
            weapon: 'machine_gun',
            stored: const ['machine_gun'],
            storage: null,
          ),
          const PreCheckRefused(PreCheckRefusal.notAtStorage),
        );
      });

      test('COMBAT-26 a weapon the unit type may not use is refused', () {
        expect(
          check.swap(
            unit: unit('u-1'),
            weapon: 'artillery',
            stored: const ['artillery'],
            storage: hq,
          ),
          const PreCheckRefused(PreCheckRefusal.notAllowed),
        );
      });

      test('decision 151 a weapon the storage does not hold is refused', () {
        expect(
          check.swap(
            unit: unit('u-1'),
            weapon: 'machine_gun',
            stored: const ['rifle'],
            storage: hq,
          ),
          const PreCheckRefused(PreCheckRefusal.notInStorage),
        );
      });

      test('UNIT-38 a unit that is not on the field cannot swap', () {
        expect(
          check.swap(
            unit: unit('u-1', place: UnitPlace.stored),
            weapon: 'machine_gun',
            stored: const ['machine_gun'],
            storage: hq,
          ),
          const PreCheckRefused(PreCheckRefusal.notOnField),
        );
      });

      test('COMBAT-26 lists the spare weapons the unit type may use', () {
        // A soldier uses rifles and machine guns, not artillery.
        expect(
          check.swappable(unit('u-1'), const [
            'rifle',
            'machine_gun',
            'artillery',
            'rifle',
          ]),
          ['machine_gun', 'rifle'],
        );
      });

      test(
        'a unit type this client does not know takes every spare weapon',
        () {
          expect(check.swappable(unit('u-1', type: 'ufo'), const ['rifle']), [
            'rifle',
          ]);
        },
      );
    });

    test('every refusal code is a host refusal code', () {
      expect(
        PreCheckRefusal.values.map((reason) => reason.code),
        everyElement(matches(r'^[a-z]+(_[a-z]+)*$')),
      );
      expect(PreCheckRefusal.outOfRange.code, 'out_of_range');
    });

    test('results compare by what they say', () {
      expect(
        const PreCheckPassed(apWait: Duration(seconds: 1)),
        isNot(const PreCheckPassed()),
      );
      // Built at run time, so that they are two objects, not one constant.
      final wait = Duration(seconds: int.parse('1'));
      expect(
        PreCheckPassed(apWait: wait).hashCode,
        PreCheckPassed(apWait: wait).hashCode,
      );
      final reason = PreCheckRefusal.values.byName('noWeapon');
      expect(
        PreCheckRefused(reason).hashCode,
        PreCheckRefused(reason).hashCode,
      );
      expect(PreCheckRefused(reason), PreCheckRefused(reason));
      expect(
        const PreCheckRefused(PreCheckRefusal.noWeapon),
        isNot(const PreCheckRefused(PreCheckRefusal.outOfRange)),
      );
    });

    group('store', () {
      StorePlan store(
        UnitView subject, {
        Position? portal = _hq,
        Iterable<UnitView> others = const [],
        Duration? recalledUntil,
      }) => check.store(
        unit: subject,
        portal: portal,
        units: [subject, ...others],
        time: _now,
        recalledUntil: recalledUntil,
      );

      test('HQ-31 a unit within store_radius_m of its portal is stored at '
          'once', () {
        // The radius is 10 m.
        expect(store(unit('u-1', x: 9, y: 0)), const StoredNow());
        expect(store(unit('u-1', x: 10, y: 0)), const StoredNow());
      });

      test('HQ-32 a unit farther is recalled for recall_s', () {
        expect(
          store(unit('u-1', x: 11, y: 0)),
          const RecalledAfter(Duration(hours: 6)),
        );
      });

      test('HQ-32 a portal the section does not see leaves the recall', () {
        expect(
          store(unit('u-1', x: 1, y: 0), portal: null),
          const RecalledAfter(Duration(hours: 6)),
        );
      });

      test('HQ-32 a recall that runs is not ordered again', () {
        expect(
          store(
            unit('u-1', x: 50, y: 0),
            recalledUntil: _now + const Duration(hours: 2),
          ),
          const StoreNotPossible(PreCheckRefusal.alreadyRecalled),
        );
        // An end in the past is no recall.
        expect(
          store(unit('u-1', x: 50, y: 0), recalledUntil: Duration.zero),
          const RecalledAfter(Duration(hours: 6)),
        );
        // Within the radius it is stored at once, recall or not.
        expect(
          store(
            unit('u-1', x: 1, y: 0),
            recalledUntil: _now + const Duration(hours: 2),
          ),
          const StoredNow(),
        );
      });

      test('HQ-30 the guild camp is never stored by order', () {
        expect(
          store(unit('u-1', type: 'encampment', x: 1, y: 0)),
          const StoreNotPossible(PreCheckRefusal.neverStored),
        );
      });

      test('HQ-49 a transport that carries units is not stored', () {
        final passenger = unit('u-2', place: UnitPlace.carried);
        final carried = UnitView(
          unitId: passenger.unitId,
          unitType: passenger.unitType,
          sectionId: passenger.sectionId,
          team: passenger.team,
          hp: 100,
          maxHp: 100,
          private: UnitPrivate(
            place: UnitPlace.carried,
            ap: passenger.private!.ap,
            morale: 50,
            rounds: 0,
            xpEarned: 0,
            xpUnspent: 0,
            transportId: 'u-1',
          ),
        );
        expect(
          store(unit('u-1', x: 1, y: 0), others: [carried]),
          const StoreNotPossible(PreCheckRefusal.carriesUnits),
        );
      });

      test('HQ-31 a unit not on the field is refused', () {
        expect(
          store(unit('u-1', place: UnitPlace.stored)),
          const StoreNotPossible(PreCheckRefusal.notOnField),
        );
      });

      test('store plans compare by what they say', () {
        expect(
          const RecalledAfter(Duration(hours: 1)),
          isNot(const RecalledAfter(Duration(hours: 2))),
        );
        // Built at run time, so that they are two objects, not one constant.
        // ignore: prefer_const_constructors
        expect(StoredNow(), StoredNow());
        expect(const StoredNow(), isNot(const RecalledAfter(Duration.zero)));
        final reason = PreCheckRefusal.values.byName('neverStored');
        expect(StoreNotPossible(reason), StoreNotPossible(reason));
        expect(
          StoreNotPossible(reason).hashCode,
          StoreNotPossible(reason).hashCode,
        );
      });
    });

    group('deploy', () {
      PreChecked deploy(
        UnitView subject, {
        Position? portal = _hq,
        Iterable<UnitView> seen = const [],
        Duration? lockedUntil,
        Duration time = _now,
      }) => check.deploy(
        unit: subject,
        portal: portal,
        seen: seen,
        time: time,
        lockedUntil: lockedUntil,
      );

      test('HQ-33 a stored unit with 10 AP deploys', () {
        expect(
          deploy(unit('u-1', place: UnitPlace.stored)),
          const PreCheckPassed(),
        );
      });

      test('HQ-33 a unit short of the deploy AP waits for them', () {
        // 4 AP at 1 AP an hour: 6 AP short, 6 hours.
        expect(
          deploy(unit('u-1', place: UnitPlace.stored, ap: 4)),
          const PreCheckPassed(apWait: Duration(hours: 6)),
        );
        // A recovered pool does not wait, an hour later.
        expect(
          deploy(
            unit('u-1', place: UnitPlace.stored, ap: 9),
            time: _now + const Duration(hours: 1),
          ),
          const PreCheckPassed(),
        );
      });

      test('HQ-33 a pool that never holds deploy_ap refuses', () {
        expect(
          deploy(unit('u-1', place: UnitPlace.stored, ap: 5, apMax: 5)),
          const PreCheckRefused(PreCheckRefusal.costAboveApMax),
        );
      });

      test('HQ-33 only a stored unit deploys', () {
        expect(
          deploy(unit('u-1')),
          const PreCheckRefused(PreCheckRefusal.notStored),
        );
        expect(
          deploy(enemy()),
          const PreCheckRefused(PreCheckRefusal.notStored),
        );
      });

      test('COMBAT-43 a prisoner is not deployed', () {
        expect(
          deploy(unit('u-1', place: UnitPlace.prisoner)),
          const PreCheckRefused(PreCheckRefusal.isPrisoner),
        );
      });

      test('HQ-35 a locked section does not deploy until the lock ends', () {
        final stored = unit('u-1', place: UnitPlace.stored);
        expect(
          deploy(stored, lockedUntil: _now + const Duration(hours: 1)),
          const PreCheckRefused(PreCheckRefusal.sectionLocked),
        );
        expect(deploy(stored, lockedUntil: _now), const PreCheckPassed());
        expect(
          deploy(stored, lockedUntil: Duration.zero),
          const PreCheckPassed(),
        );
      });

      test('HQ-36 a seen enemy within 20 m of the portal blocks', () {
        final stored = unit('u-1', place: UnitPlace.stored);
        expect(
          deploy(stored, seen: [enemy(x: 20, y: 0)]),
          const PreCheckRefused(PreCheckRefusal.blockedByEnemy),
        );
        expect(
          deploy(stored, seen: [enemy(x: 21, y: 0)]),
          const PreCheckPassed(),
        );
      });

      test('HQ-36 a friend near the portal, or an enemy off the field, '
          'blocks nothing', () {
        final stored = unit('u-1', place: UnitPlace.stored);
        expect(
          deploy(stored, seen: [unit('u-2', x: 5, y: 0)]),
          const PreCheckPassed(),
        );
        expect(
          deploy(stored, seen: [unit('u-2', place: UnitPlace.stored)]),
          const PreCheckPassed(),
        );
      });

      test('HQ-39 a portal the section does not see blocks nothing here', () {
        expect(
          deploy(
            unit('u-1', place: UnitPlace.stored),
            portal: null,
            seen: [enemy(x: 1, y: 0)],
          ),
          const PreCheckPassed(),
        );
      });
    });

    group('buy', () {
      const soldier = RosterUnit(
        unitType: 'soldier',
        category: 'soldier',
        price: 100,
      );
      const rifle = RosterWeapon(weapon: 'rifle', price: 100);

      SectionPrivate section({int money = 500, Duration? lockedUntil}) =>
          SectionPrivate(money: money, xp: 0, lockedUntil: lockedUntil);

      /// [field] units on the field and [stored] in storage.
      List<UnitView> owned({int field = 1, int stored = 0}) => [
        for (var i = 0; i < field; i++) unit('f-$i'),
        for (var i = 0; i < stored; i++) unit('s-$i', place: UnitPlace.stored),
      ];

      PreChecked buy(
        RosterUnit type, {
        SectionPrivate? holding,
        Iterable<UnitView>? own,
        Position? portal = _hq,
        Iterable<UnitView> seen = const [],
      }) => check.buyUnit(
        unit: type,
        section: holding ?? section(),
        owned: own ?? owned(),
        team: 'blue',
        portal: portal,
        seen: seen,
        time: _now,
      );

      test('ECO-04 a section with the money and the room buys a unit', () {
        expect(buy(soldier), const PreCheckPassed());
      });

      test('ECO-04 a price above the money is refused, the price itself '
          'is paid', () {
        expect(
          buy(soldier, holding: section(money: 99)),
          const PreCheckRefused(PreCheckRefusal.notEnoughMoney),
        );
        expect(
          buy(soldier, holding: section(money: 100)),
          isA<PreCheckPassed>(),
        );
      });

      test('ECO-04 UNIT-39 a section with as many units on the field as its '
          'cap has no room', () {
        expect(buy(soldier, own: owned(field: 4)), isA<PreCheckPassed>());
        expect(
          buy(soldier, own: owned(field: 5)),
          const PreCheckRefused(PreCheckRefusal.noRoom),
        );
      });

      test('ECO-04 UNIT-40 units in storage count toward the units a section '
          'may own, not toward its cap', () {
        expect(
          buy(soldier, own: owned(field: 4, stored: 5)),
          isA<PreCheckPassed>(),
        );
        expect(
          buy(soldier, own: owned(field: 4, stored: 6)),
          const PreCheckRefused(PreCheckRefusal.noRoom),
        );
      });

      test('UNIT-39 a carried unit is on the field; a prisoner is owned but '
          'not active', () {
        final carried = unit('c-1', place: UnitPlace.carried);
        final captive = unit('p-1', place: UnitPlace.prisoner);

        expect(
          buy(soldier, own: [...owned(field: 4), carried]),
          const PreCheckRefused(PreCheckRefusal.noRoom),
        );
        expect(
          buy(soldier, own: [...owned(field: 4), captive]),
          isA<PreCheckPassed>(),
        );
      });

      test('HQ-47 the guild camp counts in no cap and takes no room', () {
        const camp = RosterUnit(
          unitType: 'encampment',
          category: 'encampment',
          price: 500,
        );

        expect(
          buy(
            camp,
            own: [
              ...owned(field: 4),
              unit('e-1', type: 'encampment'),
            ],
          ),
          isA<PreCheckPassed>(),
        );
        expect(
          buy(
            soldier,
            own: [
              ...owned(field: 4),
              unit('e-1', type: 'encampment'),
            ],
          ),
          isA<PreCheckPassed>(),
        );
      });

      test('HQ-35 HQ-46 a locked section buys nothing until the lock ends', () {
        expect(
          buy(
            soldier,
            holding: section(lockedUntil: _now + const Duration(hours: 1)),
          ),
          const PreCheckRefused(PreCheckRefusal.sectionLocked),
        );
        expect(
          buy(soldier, holding: section(lockedUntil: _now)),
          isA<PreCheckPassed>(),
        );
      });

      test('HQ-36 HQ-46 an enemy the section sees within 20 m of the portal '
          'blocks the arrival; a friend, or one further, does not', () {
        expect(
          buy(soldier, seen: [enemy(x: 20, y: 0)]),
          const PreCheckRefused(PreCheckRefusal.arrivalBlocked),
        );
        expect(buy(soldier, seen: [enemy(x: 21, y: 0)]), isA<PreCheckPassed>());
        expect(
          buy(soldier, seen: [unit('u-9', x: 5, y: 0)]),
          isA<PreCheckPassed>(),
        );
        expect(
          buy(soldier, portal: null, seen: [enemy(x: 1, y: 0)]),
          isA<PreCheckPassed>(),
        );
      });

      test('HQ-46 the host order of refusals: room, lock, enemy, money', () {
        final locked = section(
          money: 0,
          lockedUntil: _now + const Duration(hours: 1),
        );
        final near = [enemy(x: 1, y: 0)];

        expect(
          buy(soldier, holding: locked, own: owned(field: 5), seen: near),
          const PreCheckRefused(PreCheckRefusal.noRoom),
        );
        expect(
          buy(soldier, holding: locked, seen: near),
          const PreCheckRefused(PreCheckRefusal.sectionLocked),
        );
        expect(
          buy(soldier, holding: section(money: 0), seen: near),
          const PreCheckRefused(PreCheckRefusal.arrivalBlocked),
        );
        expect(
          buy(soldier, holding: section(money: 0)),
          const PreCheckRefused(PreCheckRefusal.notEnoughMoney),
        );
      });

      test('COMBAT-27 a weapon needs the money only: no room, no lock', () {
        expect(
          check.buyWeapon(weapon: rifle, section: section(money: 100)),
          const PreCheckPassed(),
        );
        expect(
          check.buyWeapon(weapon: rifle, section: section(money: 99)),
          const PreCheckRefused(PreCheckRefusal.notEnoughMoney),
        );
      });
    });
  });
}
