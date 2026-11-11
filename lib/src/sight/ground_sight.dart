import 'dart:math' as math;

import 'package:battle_client/src/sight/map_geometry.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' as nav;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart'
    show
        GroundObstacle,
        ObjectObstacle,
        SightLine,
        SightObstacle,
        TerrainData,
        TerrainObstacle,
        Vision;

/// {@template ground_sight}
/// The ground a unit sees, for display (M7 Issue 9, MAP-26 to MAP-35,
/// decision 235): `battle_rules`' [Vision], the host's own code, over the
/// battle's map, with the sight line the host makes (`World.sightLine`):
/// from the top of the observer's hit volume to the ground, where a hill, a
/// building or a mountain between blocks it and a wood conceals.
///
/// It starts from the map as built; [withWorld] applies the delta layer the
/// host sent (MAP-06 to MAP-10): the walls built, the trees and buildings
/// destroyed, the craters dug. What a unit sees is the host's to decide
/// (stack decision 8): this is for display.
/// {@endtemplate}
final class GroundSight {
  /// {@macro ground_sight}
  new({required nav.NavigationMap map, required TerrainData terrain})
    : this._(
        map,
        terrain,
        // The altitude limit of decision 142, of the map as built: the host
        // keeps it, craters or not.
        [
              ...map.ground.map((cell) => cell.height),
              for (final island in map.islands.values)
                ...island.values.map((cell) => cell.height),
            ].reduce(math.max) +
            terrain.flyingMaxAboveHighestTerrainM,
      );

  new _(this._map, this._terrain, this._altitudeLimitM)
    : _vision = Vision(_terrain);

  final nav.NavigationMap _map;
  final TerrainData _terrain;
  final Vision _vision;
  final double _altitudeLimitM;

  /// This sight on the map with the delta layer [world] applied, in the
  /// host's order (craters, structures built, objects destroyed): only what
  /// a sight line reads, that is the ground's height and the objects that
  /// block sight or conceal. A bridge, a road, a ladder, a trap or damage
  /// changes nothing it reads.
  GroundSight withWorld(Iterable<BattleEvent> world) {
    var map = _map;
    nav.CellRef cellOf(Cell cell) =>
        nav.CellRef(cell.x, cell.y, surface: cell.island ?? nav.groundSurface);
    bool reads(String type) {
      final object = _terrain.objects[type];
      return object != null && (object.blocksLos || object.conceals != null);
    }

    for (final event in world) {
      switch (event) {
        case CraterDug(:final at, :final radiusM, :final depthM):
          map = map.withCrater(
            nav.Crater(
              centreXM: at.x,
              centreYM: at.y,
              radiusM: radiusM,
              depthM: depthM,
            ),
          );
        case StructureBuilt(:final structure, :final cells)
            when reads(structure):
          for (final cell in cells) {
            map = nav
                .applyChange(map, nav.ObjectBuilt(cellOf(cell), structure))
                .$1;
          }
        case ObjectDestroyed(:final object, :final cells) when reads(object):
          for (final cell in cells) {
            map = nav
                .applyChange(map, nav.ObjectDestroyed(cellOf(cell), object))
                .$1;
          }
        default:
          break;
      }
    }
    return GroundSight._(map, _terrain, _altitudeLimitM);
  }

  /// The side of a cell, in metres.
  double get cellSizeM => _map.cellSizeM;

  /// The columns of the map.
  int get width => _map.width;

  /// The rows of the map.
  int get depth => _map.depth;

  /// The cell under [position]; null off the map (the host's rule).
  nav.CellRef? cellAt(Position position) => cellUnder(_map, position);

  /// The index (`y × width + x`) of the ground cells [from] sees: its own
  /// and every cell within its effective vision with nothing blocking the
  /// line. [heightM] is the top of the observer's hit volume above its
  /// feet, [rangeM] its sight range before weather and terrain
  /// (`UnitPrivate.sightRangeM`).
  ///
  /// The same decision as the host's `FogOfWar.seesGround` for each cell.
  /// Throws an [ArgumentError] for a [weather] the tables do not have.
  List<int> seenFrom({
    required nav.CellRef from,
    required bool flying,
    required double heightM,
    required double rangeM,
    required String weather,
  }) {
    final factor =
        _terrain.weather[weather] ??
        (throw ArgumentError.value(weather, 'weather', 'unknown'));
    final standing = _terrain.terrainTypes[_map.cellAt(from)!.terrain]!;
    final reachM =
        rangeM * factor * standing.visionFactor +
        _terrain.vision.heightBonusMaxM;
    final reach = (reachM / cellSizeM).ceil();
    final seen = <int>[];
    for (
      var y = math.max(0, from.y - reach);
      y <= math.min(depth - 1, from.y + reach);
      y++
    ) {
      for (
        var x = math.max(0, from.x - reach);
        x <= math.min(width - 1, from.x + reach);
        x++
      ) {
        final to = nav.CellRef(x, y);
        final line = sightLine(
          from,
          to,
          fromFlying: flying,
          fromHeightM: heightM,
        );
        if (_vision.sees(visionRange: rangeM, weather: weather, line: line)) {
          seen.add(y * width + x);
        }
      }
    }
    return seen;
  }

  /// The sight line from [from] to [to] (MAP-29): the host's
  /// `World.sightLine`, on the map as built.
  SightLine sightLine(
    nav.CellRef from,
    nav.CellRef to, {
    bool fromFlying = false,
    bool toFlying = false,
    double fromHeightM = 0,
    double toHeightM = 0,
  }) {
    final between = fromFlying || toFlying
        ? const <nav.CellRef>[]
        : _between(from, to);
    final fromZ = _pointZ(from) + fromHeightM;
    final toZ = _pointZ(to) + toHeightM;
    final length = _distanceM(from, to);
    var forest = 0.0;
    var hill = false;
    final obstacles = <SightObstacle>[];
    for (final cell in between) {
      final share = _distanceM(from, cell) / length;
      hill = hill || _map.cellAt(cell)!.height > fromZ + (toZ - fromZ) * share;
      obstacles.add(TerrainObstacle(_map.cellAt(cell)!.terrain));
      for (final object in _map.objectsAt(cell)) {
        obstacles.add(ObjectObstacle(object));
        if (_terrain.objects[object]?.conceals == 'forest') {
          forest += cellSizeM;
        }
      }
    }
    if (hill) obstacles.add(const GroundObstacle());
    return SightLine(
      distanceM: length,
      observerTerrain: _map.cellAt(from)!.terrain,
      heightAboveTargetM:
          _pointZ(from, flying: fromFlying) - _pointZ(to, flying: toFlying),
      forestCrossedM: forest,
      obstacles: obstacles,
    );
  }

  double _pointZ(nav.CellRef cell, {bool flying = false}) =>
      flying ? _altitudeLimitM : _map.cellAt(cell)!.height;

  double _distanceM(nav.CellRef a, nav.CellRef b) =>
      math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2)) * cellSizeM;

  /// The ground cells strictly between [from] and [to] (Bresenham).
  List<nav.CellRef> _between(nav.CellRef from, nav.CellRef to) {
    final cells = <nav.CellRef>[];
    var x = from.x;
    var y = from.y;
    final dx = (to.x - from.x).abs();
    final dy = -(to.y - from.y).abs();
    final sx = from.x < to.x ? 1 : -1;
    final sy = from.y < to.y ? 1 : -1;
    var error = dx + dy;
    while (true) {
      if (x == to.x && y == to.y) break;
      final twice = 2 * error;
      if (twice >= dy) {
        error += dy;
        x += sx;
      }
      if (twice <= dx) {
        error += dx;
        y += sy;
      }
      if (x == to.x && y == to.y) break;
      cells.add(nav.CellRef(x, y));
    }
    return cells;
  }
}
