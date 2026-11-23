import 'dart:math' as math;
import 'dart:typed_data';

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

  new _(this._map, this._terrain, this._altitudeLimitM, [this._lineCells])
    : _vision = Vision(_terrain);

  final nav.NavigationMap _map;
  final TerrainData _terrain;
  final Vision _vision;
  final double _altitudeLimitM;
  _LineCells? _lineCells;

  /// What the lines of [seenFrom] read of each ground cell, made on first
  /// use. A sight with the delta layer applied ([withWorld]) has its base's,
  /// with only the cells the layer changed read again.
  _LineCells get _cells => _lineCells ??= _LineCells(_map, _terrain);

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

    // The cells whose ground or objects the layer changes.
    final changed = <nav.CellRef>[];
    for (final event in world) {
      switch (event) {
        case CraterDug(:final at, :final radiusM, :final depthM):
          final crater = nav.Crater(
            centreXM: at.x,
            centreYM: at.y,
            radiusM: radiusM,
            depthM: depthM,
          );
          map = map.withCrater(crater);
          for (final (x, y) in crater.cells(cellSizeM, width, depth)) {
            changed.add(nav.CellRef(x, y));
          }
        case StructureBuilt(:final structure, :final cells)
            when reads(structure):
          for (final cell in cells) {
            map = nav
                .applyChange(map, nav.ObjectBuilt(cellOf(cell), structure))
                .$1;
            changed.add(cellOf(cell));
          }
        case ObjectDestroyed(:final object, :final cells) when reads(object):
          for (final cell in cells) {
            map = nav
                .applyChange(map, nav.ObjectDestroyed(cellOf(cell), object))
                .$1;
            changed.add(cellOf(cell));
          }
        default:
          break;
      }
    }
    return GroundSight._(
      map,
      _terrain,
      _altitudeLimitM,
      changed.isEmpty ? _cells : _cells.after(map, _terrain, changed),
    );
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
  /// The same decision as the host's `FogOfWar.seesGround` for each cell:
  /// the line of [sightLine] and the range of [Vision.sees], read from flat
  /// arrays of the map's cells and left at the first cell that blocks it.
  /// On a map of 2 m cells a sight of 300 m is about 70,000 lines.
  ///
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
    final observer = _map.cellAt(from)!;
    final standing = _terrain.terrainTypes[observer.terrain]!;
    final rules = _terrain.vision;
    // The farthest a cell can be seen from: the effective vision before the
    // forest the line crosses, which only shortens it (MAP-31 to MAP-33).
    final baseM = rangeM * factor * standing.visionFactor;
    final reach = ((baseM + rules.heightBonusMaxM) / cellSizeM).ceil();
    final eyesZ = _pointZ(from, flying: flying);
    // Where [sightLine] starts its line: the top of the observer's hit
    // volume over its cell, flying or not (a flyer's line has no cell
    // between to rise above it).
    final lineFromZ = observer.height + heightM;
    final cells = _cells..reach(reach);
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
        // Cheap first: the distance against the most the height can add.
        final distanceM = cells.metres((x - from.x).abs(), (y - from.y).abs());
        if (distanceM > baseM + rules.heightBonusMaxM) continue;
        final index = y * width + x;
        final toZ = cells.heights[index];
        final bonusM = math.min(
          rules.heightBonusMaxM,
          math.max(0, eyesZ - toZ) * rules.heightBonusMPerM,
        );
        if (distanceM > baseM + bonusM) continue;
        final forestM = flying
            ? 0.0
            : cells.forestOnLine(
                from,
                x,
                y,
                fromZ: lineFromZ,
                toZ: toZ,
                lengthM: distanceM,
              );
        if (forestM == null) continue;
        final line = SightLine(
          distanceM: distanceM,
          observerTerrain: observer.terrain,
          heightAboveTargetM: eyesZ - toZ,
          forestCrossedM: forestM,
        );
        if (_vision.sees(visionRange: rangeM, weather: weather, line: line)) {
          seen.add(index);
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
      final ground = _map.cellAt(cell)!;
      final share = _distanceM(from, cell) / length;
      hill = hill || ground.height > fromZ + (toZ - fromZ) * share;
      // Only what can block goes on the line: the rest never changes the
      // answer, and the line is made for every cell in range.
      if (_terrain.terrainTypes[ground.terrain]?.blocksLos ?? false) {
        obstacles.add(TerrainObstacle(ground.terrain));
      }
      for (final object in _map.objectsAt(cell)) {
        final type = _terrain.objects[object];
        if (type?.blocksLos ?? false) obstacles.add(ObjectObstacle(object));
        if (type?.conceals == 'forest') forest += cellSizeM;
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

/// {@template line_cells}
/// What a sight line reads of each ground cell of a map, in flat arrays
/// (`y × width + x`): its height with the craters dug, whether its terrain
/// or an object on it blocks the line (MAP-26), and how many objects on it
/// conceal as a forest (MAP-32). The map answers the same one cell at a
/// time, through hashed lookups; a sight walks tens of thousands of lines,
/// so `GroundSight.seenFrom` reads these instead.
/// {@endtemplate}
final class _LineCells {
  /// {@macro line_cells}
  new(nav.NavigationMap map, TerrainData terrain)
    : width = map.width,
      cellSizeM = map.cellSizeM,
      heights = Float64List(map.width * map.depth),
      blocks = Uint8List(map.width * map.depth),
      forests = Uint8List(map.width * map.depth) {
    // Made again for each change of the delta layer, on maps of millions of
    // cells: read in bulk, and through the map's lookups only where a
    // crater changed the ground.
    final ground = map.ground;
    String? terrainBefore;
    var blocksBefore = false;
    for (var index = 0; index < ground.length; index++) {
      final cell = ground[index];
      heights[index] = cell.height;
      // Neighbours mostly share their terrain, and its name.
      if (!identical(cell.terrain, terrainBefore)) {
        terrainBefore = cell.terrain;
        blocksBefore = terrain.terrainTypes[cell.terrain]?.blocksLos ?? false;
      }
      if (blocksBefore) blocks[index] = 1;
    }
    for (final crater in map.craters) {
      for (final (x, y) in crater.cells(cellSizeM, width, map.depth)) {
        heights[y * width + x] = map.cellAt(nav.CellRef(x, y))!.height;
      }
    }
    for (final MapEntry(key: cell, value: names) in map.objects.entries) {
      // A line reads the ground's cells only: an island's objects or one
      // off the map are on none of them.
      if (cell.surface != nav.groundSurface ||
          cell.x < 0 ||
          cell.y < 0 ||
          cell.x >= width ||
          cell.y >= map.depth) {
        continue;
      }
      final index = cell.y * width + cell.x;
      for (final name in names) {
        final type = terrain.objects[name];
        if (type?.blocksLos ?? false) blocks[index] = 1;
        if (type?.conceals == 'forest') forests[index]++;
      }
    }
  }

  new _copy(_LineCells cells)
    : width = cells.width,
      cellSizeM = cells.cellSizeM,
      heights = Float64List.fromList(cells.heights),
      blocks = Uint8List.fromList(cells.blocks),
      forests = Uint8List.fromList(cells.forests),
      _metres = cells._metres,
      _side = cells._side;

  /// These cells on [map], a later state of this one's map where only the
  /// cells [changed] differ: a copy, with those read again. A change of the
  /// delta layer touches a few cells of a map of millions.
  _LineCells after(
    nav.NavigationMap map,
    TerrainData terrain,
    Iterable<nav.CellRef> changed,
  ) {
    final next = _LineCells._copy(this);
    for (final cell in changed) {
      // An island's cell, or one off the map, is on no line.
      final ground = cell.surface == nav.groundSurface
          ? map.cellAt(cell)
          : null;
      if (ground == null) continue;
      final index = cell.y * width + cell.x;
      next.heights[index] = ground.height;
      var blocking = terrain.terrainTypes[ground.terrain]?.blocksLos ?? false;
      var forest = 0;
      for (final name in map.objectsAt(cell)) {
        final type = terrain.objects[name];
        if (type?.blocksLos ?? false) blocking = true;
        if (type?.conceals == 'forest') forest++;
      }
      next.blocks[index] = blocking ? 1 : 0;
      next.forests[index] = forest;
    }
    return next;
  }

  /// The columns of the map.
  final int width;

  /// The side of a cell, in metres.
  final double cellSizeM;

  /// The ground's height on each cell, the craters dug.
  final Float64List heights;

  /// 1 on a cell whose terrain or an object blocks a line, 0 elsewhere.
  final Uint8List blocks;

  /// How many objects on each cell conceal as a forest.
  final Uint8List forests;

  // The metres between the centres of two cells, by the columns and rows
  // between them, up to [_side] - 1 of each: a line reads one for each cell
  // it crosses.
  Float64List _metres = Float64List(0);
  int _side = 0;

  /// Makes [metres] answer up to [cells] columns and rows apart.
  void reach(int cells) {
    if (cells < _side) return;
    _side = cells + 1;
    _metres = Float64List(_side * _side);
    for (var dy = 0; dy < _side; dy++) {
      for (var dx = 0; dx < _side; dx++) {
        _metres[dy * _side + dx] = math.sqrt(dx * dx + dy * dy) * cellSizeM;
      }
    }
  }

  /// The metres between the centres of two cells [dx] columns and [dy] rows
  /// apart (neither negative, nor past [reach]), as `GroundSight` measures
  /// them.
  double metres(int dx, int dy) => _metres[dy * _side + dx];

  /// The metres of forest the line from [from] to the cell at column [x],
  /// row [y] crosses ([lengthM] long, from [fromZ] to [toZ] high), or null
  /// when a cell between blocks it: the ground rises above the line, or
  /// its terrain or an object blocks sight. The cells between and the
  /// arithmetic are those of `GroundSight.sightLine`, in the same order, so
  /// the answer is the same to the bit.
  double? forestOnLine(
    nav.CellRef from,
    int x,
    int y, {
    required double fromZ,
    required double toZ,
    required double lengthM,
  }) {
    var cx = from.x;
    var cy = from.y;
    final dx = (x - cx).abs();
    final dy = -(y - cy).abs();
    final sx = cx < x ? 1 : -1;
    final sy = cy < y ? 1 : -1;
    // How far the walk is from [from], in columns and rows: each step of
    // the line goes away from it.
    var across = 0;
    var down = 0;
    var error = dx + dy;
    var forest = 0.0;
    while (cx != x || cy != y) {
      final twice = 2 * error;
      if (twice >= dy) {
        error += dy;
        cx += sx;
        across++;
      }
      if (twice <= dx) {
        error += dx;
        cy += sy;
        down++;
      }
      if (cx == x && cy == y) break;
      final index = cy * width + cx;
      final share = _metres[down * _side + across] / lengthM;
      if (heights[index] > fromZ + (toZ - fromZ) * share ||
          blocks[index] != 0) {
        return null;
      }
      for (var n = forests[index]; n > 0; n--) {
        forest += cellSizeM;
      }
    }
    return forest;
  }
}
