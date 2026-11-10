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

void main() {
  late OrderPreCheck check;

  setUpAll(() {
    check = OrderPreCheck(
      combat: CombatData.parse(_plan('combat.yaml')),
      units: UnitsData.parse(_plan('units.yaml')),
      storeRadiusM: BattleSettings.parse(_plan('battle.yaml'))
          .storage
          .storeRadiusM,
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
  });
}
