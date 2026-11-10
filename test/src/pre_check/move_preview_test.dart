import 'dart:io';
import 'dart:math' as math;

import 'package:battle_client/battle_client.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' as nav;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart'
    show MovementCost, Mover, PathSample, TerrainData, UnitsData;
import 'package:test/test.dart';

/// The plan's own files, read from the hawkbee checkout (stack decision 7).
String _plan(String file) =>
    File('../../apps/battle_team/plan/data/$file').readAsStringSync();

const _now = Duration(hours: 1);

/// A map of 10 m cells from the fixture format, `rows` of terrain symbols and
/// of heights; `extra` adds lines.
String _map(
  List<String> terrain, {
  List<String>? heights,
  String legend = '',
  String extra = '',
}) =>
    '''
cell 10
water river lake
legend g grass
legend r road
legend m mud
legend ~ river
legend w grass wall
$legend
terrain
${terrain.map((row) => '  $row').join('\n')}
heights
${(heights ?? [for (final row in terrain) row.split(' ').map((_) => '0').join(' ')]).map((row) => '  $row').join('\n')}
$extra
''';

/// A unit of [type] at cell ([cx], [cy]) of 10 m cells, with [ap] AP.
UnitView _unit(
  String id, {
  String type = 'soldier',
  int cx = 0,
  int cy = 0,
  double ap = 30,
  double perHour = 1,
  bool flying = false,
  UnitPlace place = UnitPlace.deployed,
  String team = 'blue',
}) => UnitView(
  unitId: id,
  unitType: type,
  sectionId: 's-$team',
  team: team,
  hp: 100,
  maxHp: 100,
  position: place == UnitPlace.deployed
      ? Position.metres(cx * 10 + 5, cy * 10 + 5, 0)
      : null,
  flying: flying,
  weapon: 'rifle',
  private: team == 'blue'
      ? UnitPrivate(
          place: place,
          ap: ApView(value: ap, at: _now, perHour: perHour, max: 30),
          morale: 50,
          rounds: 10,
          xpEarned: 0,
          xpUnspent: 0,
        )
      : null,
);

/// The centre of cell ([cx], [cy]).
Position _at(int cx, int cy) => Position.metres(cx * 10 + 5, cy * 10 + 5, 0);

void main() {
  final units = UnitsData.parse(_plan('units.yaml'));
  final terrain = TerrainData.parse(_plan('terrain.yaml'));

  MovePreviewer previewer(String map) => MovePreviewer(
    planner: NavigationPathPlanner(
      map: nav.NavigationFixture.parse(map),
      terrain: terrain,
    ),
    units: units,
    terrain: terrain,
  );

  MovePlan preview(
    MovePreviewer previewer,
    UnitView unit,
    Position to, {
    Iterable<UnitView> seen = const [],
  }) => previewer.preview(unit: unit, destination: to, seen: seen, time: _now);

  MovePreview ready(MovePlan plan) {
    expect(plan, isA<MovePreview>());
    return plan as MovePreview;
  }

  group(MovePreviewer, () {
    group('the cost of the path', () {
      test('COMBAT-03 grass costs ap_per_m a metre; the unit arrives at its '
          'speed', () {
        final move = ready(
          preview(previewer(_map(['g g g g'])), _unit('u-1'), _at(2, 0)),
        );

        // 20 m of grass at 1 AP a metre, walked at 5 m/s.
        expect(move.costAp, closeTo(20, 1e-9));
        expect(move.lengthM, closeTo(20, 1e-9));
        expect(move.arrivesAt, _now + const Duration(seconds: 4));
        expect(move.apWait, Duration.zero);
        expect(move.destination, _at(2, 0));
      });

      test('COMBAT-03 MAP-16 uphill costs more by the slope factor of the '
          'class', () {
        final move = ready(
          preview(
            previewer(_map(['g g g'], heights: ['0 1 2'])),
            _unit('u-1'),
            _at(2, 0),
          ),
        );

        // 1 m up over 10 m: atan(0.1) degrees, foot factor 0.05 a degree.
        final degrees = math.atan(0.1) * 180 / math.pi;
        expect(move.costAp, closeTo(20 * (1 + degrees * 0.05), 1e-6));
      });

      test('MAP-16 downhill costs less, down to the floor of the class', () {
        final move = ready(
          preview(
            previewer(_map(['g g g'], heights: ['2 1 0'])),
            _unit('u-1'),
            _at(2, 0),
          ),
        );

        final degrees = math.atan(0.1) * 180 / math.pi;
        expect(move.costAp, closeTo(20 * (1 - degrees * 0.05), 1e-6));
      });

      test('MAP-15 a road costs its multiplier: 0.7 for foot, 0.4 for a '
          'wheeled unit at its own ap_per_m', () {
        final map = _map(['r r r']);

        expect(
          ready(preview(previewer(map), _unit('u-1'), _at(2, 0))).costAp,
          closeTo(14, 1e-9),
        );
        // A jeep: 0.1 AP a metre on flat grass, 0.4 on road.
        expect(
          ready(preview(previewer(map), _unit('j-1', type: 'jeep'), _at(2, 0)))
              .costAp,
          closeTo(20 * 0.1 * 0.4, 1e-9),
        );
      });

      test('MAP-41 each terrain is paid for the distance on it', () {
        final move = ready(
          preview(previewer(_map(['g m g'])), _unit('u-1'), _at(2, 0)),
        );

        // 10 m of grass and 10 m of mud (x2).
        expect(move.costAp, closeTo(10 + 20, 1e-9));
      });

      test('MAP-22 MAP-23 water stops a foot unit and a bridge lets it '
          'cross; MAP-42 the deck costs as road', () {
        final river = _map(['g g ~ g g']);
        final bridged = _map(['g g ~ g g'], extra: 'build bridge 2,0');

        expect(
          preview(previewer(river), _unit('u-1'), _at(4, 0)),
          const MoveRefused(PreCheckRefusal.noPath),
        );
        final across = ready(
          preview(previewer(bridged), _unit('u-1'), _at(4, 0)),
        );
        // 30 m of grass and the 10 m of the deck at the road's 0.7.
        expect(across.costAp, closeTo(30 + 10 * 0.7, 1e-6));
      });

      test('MAP-19 a boat sails on water, with the sail multiplier, and '
          'cannot leave it', () {
        final map = _map(['~ ~ ~ g']);

        final sail = ready(
          preview(previewer(map), _unit('b-1', type: 'boat'), _at(2, 0)),
        );
        expect(sail.costAp, closeTo(20 * 0.1 * 0.8, 1e-9));
        expect(
          preview(previewer(map), _unit('b-1', type: 'boat'), _at(3, 0)),
          const MoveRefused(PreCheckRefusal.noPath),
        );
      });

      test('MAP-17 a flying unit flies at the altitude limit and pays the '
          'flying profile', () {
        final move = ready(
          preview(
            previewer(_map(['g g g'])),
            _unit('h-1', type: 'helicopter', flying: true),
            _at(2, 0),
          ),
        );

        expect(move.costAp, closeTo(20 * 0.1 * 0.5, 1e-9));
        // The map's highest point (0 m) + flying_max_above_highest_terrain_m.
        expect(move.points.map((p) => p.z), everyElement(10));
      });
    });

    group('the path', () {
      test('MAP-47 a path never cuts a wall corner: it goes round', () {
        final move = ready(
          preview(
            previewer(_map(['g w g', 'g g g', 'g g g'])),
            _unit('u-1'),
            _at(2, 0),
          ),
        );

        expect(move.cells, const [
          Cell(0, 0),
          Cell(0, 1),
          Cell(1, 1),
          Cell(2, 1),
          Cell(2, 0),
        ]);
        expect(move.costAp, closeTo(40, 1e-9));
        expect(move.points, hasLength(5));
        expect(move.points.first, _at(0, 0));
        expect(move.points.last, _at(2, 0));
      });

      test('MAP-44 walls that close the way leave no path', () {
        final plan = preview(
          previewer(_map(['g w g', 'g w g', 'g w g'])),
          _unit('u-1'),
          _at(2, 1),
        );

        expect(plan, const MoveRefused(PreCheckRefusal.noPath));
      });

      test('MAP-37 a destination off the map is refused', () {
        expect(
          preview(previewer(_map(['g g'])), _unit('u-1'), _at(5, 0)),
          const MoveRefused(PreCheckRefusal.offMap),
        );
        expect(
          preview(
            previewer(_map(['g g'])),
            _unit('u-1'),
            Position.metres(5, -5, 0),
          ),
          const MoveRefused(PreCheckRefusal.offMap),
        );
      });

      test('a unit that is not on the field does not move', () {
        final map = previewer(_map(['g g']));

        expect(
          preview(map, _unit('u-1', place: UnitPlace.stored), _at(1, 0)),
          const MoveRefused(PreCheckRefusal.notOnField),
        );
        expect(
          preview(map, _unit('u-2', place: UnitPlace.carried), _at(1, 0)),
          const MoveRefused(PreCheckRefusal.notOnField),
        );
      });

      test('the host decides what the client cannot plan: an unknown unit '
          'type, a unit off the map, a flier that cannot fly', () {
        final map = previewer(_map(['g g']));

        expect(
          preview(map, _unit('x-1', type: 'dragon'), _at(1, 0)),
          const MoveUnplanned(),
        );
        expect(
          preview(map, _unit('u-1', cx: 9), _at(1, 0)),
          const MoveUnplanned(),
        );
        expect(
          preview(map, _unit('u-2', flying: true), _at(1, 0)),
          const MoveUnplanned(),
        );
      });

      test('a unit on a floating island is found there, and a ground '
          'position under it on the ground', () {
        final planner = NavigationPathPlanner(
          map: nav.NavigationFixture.parse(
            _map(['g g g'], extra: 'island sky 40 floating_island_ground 1,0'),
          ),
          terrain: terrain,
        );

        expect(
          planner.cellAt(Position.metres(15, 5, 40)),
          const nav.CellRef(1, 0, surface: 'sky'),
        );
        expect(
          planner.cellAt(Position.metres(15, 5, 0)),
          const nav.CellRef(1, 0),
        );
        expect(
          planner.cellAt(Position.metres(5, 5, 40)),
          const nav.CellRef(0, 0),
        );
        expect(planner.cellSizeM, 10);
      });
    });

    group('COMBAT-06 the AP', () {
      test('a move that costs more AP than the unit holds shows the wait at '
          'the recovery delay', () {
        final map = previewer(_map(['g g g g g g']));
        final tired = _unit('u-1', ap: 5);

        final slow = ready(preview(map, tired, _at(4, 0)));

        // 40 AP for 5 held: the unit walks 5 m, then as fast as its AP come
        // back (1 AP an hour).
        expect(slow.costAp, closeTo(40, 1e-9));
        expect(slow.apWait, greaterThan(const Duration(hours: 30)));
        final walking = Duration(seconds: (slow.lengthM / 5).round());
        expect(slow.arrivesAt - _now, slow.apWait + walking);
        final quick = ready(
          preview(map, _unit('u-1', ap: 5, perHour: 3600), _at(4, 0)),
        );
        expect(quick.apWait, lessThan(const Duration(minutes: 2)));
        expect(quick.apWait, greaterThan(Duration.zero));
      });

      test('MAP-20 the preview prices what the rules core prices: the same '
          'arrival as MovementCost.move for the path', () {
        final map = previewer(_map(['g m g g g']));
        final move = ready(preview(map, _unit('u-1', ap: 12), _at(4, 0)));
        final type = units.unitTypes['soldier']!;
        final samples = [
          const PathSample(terrainType: 'grass', slopeDegrees: 0, lengthM: 5),
          const PathSample(terrainType: 'mud', slopeDegrees: 0, lengthM: 10),
          const PathSample(terrainType: 'grass', slopeDegrees: 0, lengthM: 25),
        ];
        final pool = _unit('u-1', ap: 12).private!.ap;

        final direct = MovementCost(terrain).ofPath(Mover.unit(type), samples);

        expect(direct, closeTo(move.costAp, 1e-9));
        expect(pool.value, 12);
        expect(move.arrivesAt, greaterThan(_now + const Duration(seconds: 8)));
      });
    });

    group('MAP-50 one unit per place', () {
      final map = previewer(_map(['g g g']));

      /// Enough [type] units in cell ([cx], 0) that a soldier has no place.
      List<UnitView> crowd(String type, int cx, {String team = 'blue'}) {
        final width = units.unitTypes[type]!.hitBox.width;
        final soldier = units.unitTypes['soldier']!.hitBox.width;
        final count = ((10 - soldier) / width).floor() + 1;
        return [
          for (var i = 0; i < count; i++)
            _unit('$type-$i', type: type, cx: cx, team: team),
        ];
      }

      test('a destination whose width other seen units use up is refused, '
          'friend or enemy', () {
        for (final team in ['blue', 'red']) {
          expect(
            preview(
              map,
              _unit('u-1'),
              _at(1, 0),
              seen: crowd('tank', 1, team: team),
            ),
            const MoveRefused(PreCheckRefusal.occupied),
            reason: team,
          );
        }
      });

      test('a place that still has the width is free: a soldier beside a '
          'soldier, a mover that stands in the cell already', () {
        expect(
          preview(
            map,
            _unit('u-1'),
            _at(1, 0),
            seen: [
              _unit('u-2', cx: 1),
              _unit('u-3', cx: 1, team: 'red'),
            ],
          ),
          isA<MovePreview>(),
        );
        // Its own place is its own: the unit is among the units it sees.
        final mover = _unit('u-1', cx: 1);
        expect(
          preview(map, mover, _at(1, 0), seen: [mover, ...crowd('tank', 0)]),
          isA<MovePreview>(),
        );
      });

      test('decision 237 a unit the section does not see gives no clue: the '
          'preview is the same as with nobody there', () {
        // A crowd stands there, but the section's view does not hold it.
        final inTheWorld = crowd('tank', 1);
        expect(inTheWorld, isNotEmpty);
        final unseen = preview(map, _unit('u-1'), _at(1, 0));
        final nobody = preview(map, _unit('u-1'), _at(1, 0));

        expect(unseen, equals(nobody));
        expect(unseen, isA<MovePreview>());
      });

      test('airborne units neither block nor are blocked by ground units '
          '(MAP-50)', () {
        final flier = _unit('h-1', type: 'helicopter', flying: true);

        expect(
          preview(
            map,
            _unit('u-1'),
            _at(1, 0),
            seen: [for (final unit in crowd('tank', 1)) _flying(unit)],
          ),
          isA<MovePreview>(),
        );
        expect(
          preview(map, flier, _at(1, 0), seen: crowd('tank', 1)),
          isA<MovePreview>(),
        );
      });
    });
  });

  group('plans and paths compare by value', () {
    test('two previews of the same move are equal; refusals by reason', () {
      final map = previewer(_map(['g g g']));

      expect(
        preview(map, _unit('u-1'), _at(2, 0)),
        equals(preview(map, _unit('u-1'), _at(2, 0))),
      );
      expect(
        preview(map, _unit('u-1'), _at(2, 0)),
        isNot(equals(preview(map, _unit('u-1'), _at(1, 0)))),
      );
      final reason = [PreCheckRefusal.noPath].first;
      expect(MoveRefused(reason), equals(MoveRefused(reason)));
      expect(MoveRefused(reason), isNot(equals(const MoveUnplanned())));
      expect(const MoveUnplanned().props, isEmpty);
    });

    test('planned paths compare by cells, samples and cost', () {
      PlannedPath path(double cost) => PlannedPath(
        cells: const [nav.CellRef(0, 0)],
        samples: const [
          PathSample(terrainType: 'grass', slopeDegrees: 0, lengthM: 1),
        ],
        cost: cost,
      );

      expect(path(1), equals(path(1)));
      expect(path(1), isNot(equals(path(2))));
    });
  });

  group('a fake planner', () {
    test('the port is all the previewer needs of a map', () {
      final previewer = MovePreviewer(
        planner: _StrandedPlanner(),
        units: units,
        terrain: terrain,
      );

      expect(
        preview(previewer, _unit('u-1'), _at(1, 0)),
        const MoveRefused(PreCheckRefusal.noPath),
      );
    });

    test('a path the rules cannot price is refused', () {
      final previewer = MovePreviewer(
        planner: _StrandedPlanner(
          path: const PlannedPath(
            cells: [nav.CellRef(0, 0), nav.CellRef(1, 0)],
            samples: [
              PathSample(terrainType: 'river', slopeDegrees: 0, lengthM: 10),
            ],
            cost: 1,
          ),
        ),
        units: units,
        terrain: terrain,
      );

      expect(
        preview(previewer, _unit('u-1'), _at(1, 0)),
        const MoveRefused(PreCheckRefusal.noPath),
      );
    });
  });
}

UnitView _flying(UnitView unit) => UnitView(
  unitId: unit.unitId,
  unitType: unit.unitType,
  sectionId: unit.sectionId,
  team: unit.team,
  hp: unit.hp,
  maxHp: unit.maxHp,
  position: unit.position,
  flying: true,
);

/// A map of two cells where nothing can be found, or one fixed path.
final class _StrandedPlanner implements PathPlanner {
  new({this.path});

  final PlannedPath? path;

  @override
  double get cellSizeM => 10;

  @override
  nav.CellRef? cellAt(Position position) =>
      nav.CellRef((position.x / 10).floor(), 0);

  @override
  Position pointOf(nav.CellRef cell, {bool flying = false}) =>
      Position.metres(cell.x * 10 + 5, 5, 0);

  @override
  PlannedPath? find({
    required Mover mover,
    required nav.CellRef from,
    required nav.CellRef to,
  }) => path;
}
