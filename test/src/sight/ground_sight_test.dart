import 'dart:io';

import 'package:battle_client/battle_client.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' as nav;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart' show TerrainData, UnitsData;
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
terrain
  ${terrain.split('').join(' ')}
heights
  ${heights ?? List.filled(terrain.length, '0').join(' ')}
''';

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
