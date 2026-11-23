import 'dart:io';
import 'dart:math' as math;

import 'package:battle_client/battle_client.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' as nav;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart'
    show TerrainData, UnitsData, Vision;
import 'package:test/test.dart';

/// The plan's own files, read from the hawkbee checkout (stack decision 7).
String _plan(String file) =>
    File('../../apps/battle_team/plan/data/$file').readAsStringSync();

/// A map of one row of 10 m cells: `terrain` symbols (`g` grass, `t` grass
/// with a tree, `b` grass with a building), and the ground `heights`.
String _row(String terrain, {String? heights}) =>
    '''
cell 10
legend g grass
legend t grass tree
legend b grass building
legend m mountain
terrain
  ${terrain.split('').join(' ')}
heights
  ${heights ?? List.filled(terrain.length, '0').join(' ')}
''';

/// A valley of 16 × 12 cells of [cell] metres with every ground a sight line
/// reads, drawn by a seeded random: hills, woods (a tree on grass or on the
/// forest floor), buildings, a mountain, a road, a town street, a river, and
/// a floating island over it all.
String _valley({double cell = 10}) {
  final random = math.Random(241);
  const width = 16;
  const depth = 12;
  final rows = [
    for (var y = 0; y < depth; y++)
      [
        for (var x = 0; x < width; x++)
          switch (random.nextInt(20)) {
            0 || 1 => 't',
            2 || 3 => 'f',
            4 => 'b',
            5 => 'm',
            6 => 'r',
            7 => 's',
            8 => '~',
            _ => 'g',
          },
      ].join(' '),
  ];
  final heights = [
    for (var y = 0; y < depth; y++)
      [
        for (var x = 0; x < width; x++)
          (12 * math.sin(x / 3) * math.cos(y / 4) +
                  12 +
                  random.nextInt(30) / 10)
              .toStringAsFixed(1),
      ].join(' '),
  ];
  return '''
cell $cell
water river
legend g grass
legend t grass tree
legend f forest_floor tree
legend b grass building
legend m mountain
legend r road
legend s town_street
legend ~ river
terrain
${rows.map((row) => '  $row').join('\n')}
heights
${heights.map((row) => '  $row').join('\n')}
island sky 40 floating_island_ground 6,5 7,5 8,5
''';
}

void main() {
  final terrain = TerrainData.parse(_plan('terrain.yaml'));
  final soldier = UnitsData.parse(_plan('units.yaml')).unitTypes['soldier']!;
  final eyes = soldier.hitBox.height;

  GroundSight sightOver(String map) =>
      GroundSight(map: nav.NavigationFixture.parse(map), terrain: terrain);

  /// The columns of the row the observer at column 0 sees.
  Set<int> seenColumns(
    GroundSight sight, {
    double range = 100,
    String weather = 'clear',
    bool flying = false,
    int from = 0,
  }) => sight
      .seenFrom(
        from: nav.CellRef(from, 0),
        flying: flying,
        heightM: eyes,
        rangeM: range,
        weather: weather,
      )
      .toSet();

  group(GroundSight, () {
    test('MAP-27 on open ground it sees its own cell and every cell within '
        'its range, and none beyond', () {
      final sight = sightOver(_row('gggggggggggg'));

      expect(seenColumns(sight, range: 50), {0, 1, 2, 3, 4, 5});
    });

    test('MAP-26 decision 235 a hill between an own unit and a cell leaves '
        'it dark, and the hill itself lit', () {
      final sight = sightOver(_row('gggggggg', heights: '0 0 0 30 0 0 0 0'));

      expect(seenColumns(sight), {0, 1, 2, 3});
    });

    test('MAP-26 a building blocks the line behind it; its own cell is '
        'lit', () {
      final sight = sightOver(_row('ggbggggg'));

      expect(seenColumns(sight), {0, 1, 2});
    });

    test(
      'MAP-26 a mountain blocks the line behind it; its own cell is lit',
      () {
        final sight = sightOver(_row('ggmggggg'));

        expect(seenColumns(sight), {0, 1, 2});
      },
    );

    test('MAP-27 each metre of forest the line crosses reduces the '
        'effective vision', () {
      final open = seenColumns(sightOver(_row('gggggggggggg')));
      final oneTree = seenColumns(sightOver(_row('gtgggggggggg')));
      final copse = seenColumns(sightOver(_row('gtttgggggggg')));
      final cost = terrain.vision.forestVisionCostPerM;

      // A tree cell is 10 m of forest on the line: 10 × cost metres lost,
      // for the cells behind it.
      expect(open, {for (var x = 0; x <= 10; x++) x});
      expect(oneTree, {for (var x = 0; x * 10 <= 100 - 10 * cost; x++) x});
      expect(copse, {0, 1, 2});
    });

    test('MAP-31 weather shortens the range by its factor', () {
      final sight = sightOver(_row('gggggggggg'));

      expect(seenColumns(sight), hasLength(10));
      expect(seenColumns(sight, weather: 'fog'), {
        for (var x = 0; x * 10 <= 100 * terrain.weather['fog']!; x++) x,
      });
    });

    test('MAP-33 an observer standing higher sees farther, up to a cap', () {
      final low = seenColumns(
        sightOver(_row('gggggggggggggggggggg')),
        range: 50,
      );
      final high = seenColumns(
        sightOver(
          _row(
            'gggggggggggggggggggg',
            heights: '30 ${List.filled(19, '0').join(' ')}',
          ),
        ),
        range: 50,
      );
      final bonus = 30 * terrain.vision.heightBonusMPerM;

      expect(low, {0, 1, 2, 3, 4, 5});
      expect(high, {for (var x = 0; x * 10 <= 50 + bonus; x++) x});
    });

    test('MAP-26 a flying observer line passes over the hill', () {
      final sight = sightOver(_row('gggggggg', heights: '0 0 0 30 0 0 0 0'));

      expect(seenColumns(sight, flying: true), hasLength(8));
    });

    test('decision 142 a flyer altitude is the highest point of the map, '
        'a floating island included, plus the limit', () {
      final flat = _row('gggggggggggggggg');
      final withIsland = '$flat\nisland sky 40 floating_island_ground 15,0\n';
      final limit = terrain.flyingMaxAboveHighestTerrainM;
      int reach(double altitude) =>
          ((50 + altitude * terrain.vision.heightBonusMPerM) / 10).floor();

      expect(seenColumns(sightOver(flat), range: 50, flying: true), {
        for (var x = 0; x <= reach(limit); x++) x,
      });
      expect(seenColumns(sightOver(withIsland), range: 50, flying: true), {
        for (var x = 0; x <= reach(40 + limit); x++) x,
      });
    });

    group('withWorld applies the delta layer the host sent', () {
      const wall = [Cell(3, 0)];

      test('MAP-06 a wall built blocks the line behind it; a bridge or a '
          'trap built changes nothing a sight line reads', () {
        final sight = sightOver(_row('gggggggg'));

        expect(
          seenColumns(
            sight.withWorld([
              const StructureBuilt(
                siteId: 'w-1',
                structure: 'wall',
                cells: wall,
              ),
            ]),
          ),
          {0, 1, 2, 3},
        );
        expect(
          seenColumns(
            sight.withWorld([
              const StructureBuilt(
                siteId: 'b-1',
                structure: 'bridge',
                cells: wall,
              ),
              const StructureBuilt(
                siteId: 't-1',
                structure: 'trap',
                cells: wall,
              ),
            ]),
          ),
          seenColumns(sight),
        );
      });

      test('MAP-28 a building destroyed stops blocking, and a tree destroyed '
          'stops concealing', () {
        final building = sightOver(_row('ggbggggg'));
        final wood = sightOver(_row('gtttgggggg'));

        expect(seenColumns(building), {0, 1, 2});
        expect(
          seenColumns(
            building.withWorld([
              const ObjectDestroyed(object: 'building', cells: [Cell(2, 0)]),
            ]),
          ),
          seenColumns(sightOver(_row('gggggggg'))),
        );
        expect(
          seenColumns(
            wood.withWorld([
              for (final x in [1, 2, 3])
                ObjectDestroyed(object: 'tree', cells: [Cell(x, 0)]),
            ]),
          ),
          seenColumns(sightOver(_row('gggggggggg'))),
        );
      });

      test('MAP-07 a crater lowers the ground: a unit in it looks up at the '
          'rim, and a hill dug away stops blocking', () {
        final hill = sightOver(_row('gggggggg', heights: '0 0 0 30 0 0 0 0'));
        final dug = hill.withWorld([
          CraterDug(at: Position.metres(35, 5, 30), radiusM: 6, depthM: 30),
        ]);

        expect(seenColumns(hill), {0, 1, 2, 3});
        expect(seenColumns(dug), hasLength(8));
      });

      test('damage changes nothing, and a wall on a floating island does not '
          'block the lines of the ground', () {
        final sight = sightOver(_row('gggggggg'));
        final same = sight.withWorld([
          const ObjectDamaged(object: 'tree', cells: [Cell(2, 0)], hp: 10),
          const StructureBuilt(
            siteId: 'w-2',
            structure: 'wall',
            cells: [Cell(2, 0, island: 'sky')],
          ),
        ]);

        expect(seenColumns(same), seenColumns(sight));
      });
    });

    group('seenFrom says what the rule says of every cell', () {
      // The rule itself: `Vision.sees` on the sight line to each cell of the
      // map, row by row. `seenFrom` reads flat arrays of the map and leaves a
      // line at the first cell that blocks it, so that a sight of 300 m on
      // cells of 2 m is fast; it must give the same cells, in the same order.
      List<int> byTheRule(
        GroundSight sight,
        nav.CellRef from, {
        required bool flying,
        required double range,
        required String weather,
      }) => [
        for (var y = 0; y < sight.depth; y++)
          for (var x = 0; x < sight.width; x++)
            if (Vision(terrain).sees(
              visionRange: range,
              weather: weather,
              line: sight.sightLine(
                from,
                nav.CellRef(x, y),
                fromFlying: flying,
                fromHeightM: eyes,
              ),
            ))
              y * sight.width + x,
      ];

      void expectTheRule(
        GroundSight sight,
        Iterable<nav.CellRef> observers, {
        bool flying = false,
        double range = 100,
        String weather = 'clear',
      }) {
        for (final from in observers) {
          expect(
            sight.seenFrom(
              from: from,
              flying: flying,
              heightM: eyes,
              rangeM: range,
              weather: weather,
            ),
            byTheRule(
              sight,
              from,
              flying: flying,
              range: range,
              weather: weather,
            ),
            reason: 'seen from $from',
          );
        }
      }

      Iterable<nav.CellRef> everyCell(GroundSight sight) => [
        for (var y = 0; y < sight.depth; y++)
          for (var x = 0; x < sight.width; x++) nav.CellRef(x, y),
      ];

      for (final (weather, range, flying) in [
        ('clear', 60.0, false),
        ('clear', 300.0, false),
        ('fog', 150.0, false),
        ('clear', 60.0, true),
      ]) {
        test('MAP-26 to MAP-34 from every cell of a valley, $weather, range '
            '$range${flying ? ', flying' : ''}', () {
          final sight = sightOver(_valley());

          expectTheRule(
            sight,
            everyCell(sight),
            flying: flying,
            range: range,
            weather: weather,
          );
        });
      }

      test('on cells of 2 m, and from a floating island', () {
        final sight = sightOver(_valley(cell: 2));

        expectTheRule(sight, everyCell(sight), range: 20);
        expectTheRule(sight, [
          for (final x in [6, 7, 8]) nav.CellRef(x, 5, surface: 'sky'),
        ], range: 20);
      });

      test('MAP-06 MAP-07 MAP-28 with the delta layer: a crater, a wall, a '
          'building and a tree destroyed', () {
        final valley = sightOver(_valley());
        final changed = valley.withWorld([
          CraterDug(at: Position.metres(55, 45, 0), radiusM: 12, depthM: 8),
          const StructureBuilt(
            siteId: 'w-1',
            structure: 'wall',
            cells: [Cell(9, 3), Cell(9, 4), Cell(9, 5)],
          ),
          const ObjectDestroyed(
            object: 'building',
            cells: [Cell(2, 0), Cell(10, 7)],
          ),
          const ObjectDestroyed(object: 'tree', cells: [Cell(4, 4)]),
        ]);

        expectTheRule(changed, everyCell(changed), range: 120);
      });

      test('MAP-07 on a map dug already', () {
        final dug = GroundSight(
          map: nav.NavigationFixture.parse(_valley()).withCrater(
            const nav.Crater(
              centreXM: 55,
              centreYM: 45,
              radiusM: 12,
              depthM: 8,
            ),
          ),
          terrain: terrain,
        );

        expectTheRule(dug, everyCell(dug), range: 120);
      });

      test('an object off the map blocks no line, nor a wall built there', () {
        final map = nav.NavigationFixture.parse(_row('gggggg'));
        final sight = GroundSight(
          map: map.copyWith(
            objects: {
              // Read as cells of the map, these would be (0, 1) and (5, 0).
              const nav.CellRef(6, 0): {'building'},
              const nav.CellRef(-1, 1): {'building'},
            },
          ),
          terrain: terrain,
        );
        final walled = sight.withWorld([
          const StructureBuilt(
            siteId: 'w-9',
            structure: 'wall',
            cells: [Cell(-1, 1), Cell(2, 3)],
          ),
        ]);

        expect(seenColumns(sight), {0, 1, 2, 3, 4, 5});
        expect(seenColumns(walled), {0, 1, 2, 3, 4, 5});
      });

      test('a change of the delta layer reads again only the cells it '
          'changes: the sight before it is left as it was', () {
        final sight = sightOver(_row('gggggggg'));
        final before = seenColumns(sight);
        final walled = sight.withWorld([
          const StructureBuilt(
            siteId: 'w-1',
            structure: 'wall',
            cells: [Cell(3, 0)],
          ),
        ]);

        expect(seenColumns(walled), {0, 1, 2, 3});
        expect(seenColumns(sight), before);
        expect(
          seenColumns(
            walled.withWorld([
              const ObjectDestroyed(object: 'wall', cells: [Cell(3, 0)]),
            ]),
          ),
          before,
        );
      });
    });

    test('MAP-27 the range is cut at the edge of the map', () {
      final sight = sightOver(_row('gggg'));

      expect(seenColumns(sight, from: 3, range: 500), {0, 1, 2, 3});
    });

    test('the index of a cell is its row times the width plus its column', () {
      final sight = sightOver('''
cell 10
legend g grass
terrain
  g g g
  g g g
heights
  0 0 0
  0 0 0
''');

      expect(sight.width, 3);
      expect(sight.depth, 2);
      expect(
        sight.seenFrom(
          from: const nav.CellRef(2, 1),
          flying: false,
          heightM: eyes,
          rangeM: 10,
          weather: 'clear',
        ),
        unorderedEquals([5, 4, 2]),
      );
    });

    test('an unknown weather is refused', () {
      expect(
        () => seenColumns(sightOver(_row('gg')), weather: 'blizzard'),
        throwsArgumentError,
      );
    });

    test('a position is under the host cell, null off the map', () {
      final sight = sightOver(_row('gggg'));

      expect(sight.cellSizeM, 10);
      expect(sight.cellAt(Position.metres(25, 5, 0)), const nav.CellRef(2, 0));
      expect(sight.cellAt(Position.metres(45, 5, 0)), isNull);
    });
  });
}
