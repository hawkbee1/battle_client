import 'dart:math' as math;

import 'package:battle_client/src/sight/map_geometry.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' as nav;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart'
    show MovementCost, Mover, PathSample, TerrainData;
import 'package:equatable/equatable.dart';

/// The construction of `terrain.yaml` that makes a road (MAP-21): the host
/// (`battle_host`'s `SharedMap`) prices a cell it covers as road.
const roadConstruction = 'road_segment';

/// {@template planned_path}
/// A path the planner found: the [cells] from the mover's to the goal, its
/// [samples] as the rules core prices them, and its AP [cost].
/// {@endtemplate}
final class PlannedPath extends Equatable {
  /// {@macro planned_path}
  const new({required this.cells, required this.samples, required this.cost});

  /// The cells visited, start and goal included.
  final List<nav.CellRef> cells;

  /// The path as the rules core's samples (terrain, signed slope, length).
  final List<PathSample> samples;

  /// Its AP cost.
  final double cost;

  @override
  List<Object?> get props => [cells, samples, cost];
}

/// {@template path_planner}
/// What the move preview asks of the map (Strategy, stack decision 7): the
/// cell under a position, the point of a cell, and the cheapest path for a
/// mover. The app gives it the real one ([NavigationPathPlanner]); tests
/// give a fake. For display only: the host searches or checks its own path
/// and its answer wins (decision 3, stack decision 8).
/// {@endtemplate}
abstract interface class PathPlanner {
  /// The side of a cell, in metres.
  double get cellSizeM;

  /// The cell under [position]; null off the map. The host's rule: on a
  /// floating island when one covers it and the position is nearer its
  /// surface than the ground's.
  nav.CellRef? cellAt(Position position);

  /// The point of a unit standing on [cell] (flying or not).
  Position pointOf(nav.CellRef cell, {bool flying = false});

  /// The cheapest path of [mover] from [from] to [to]; null when there is
  /// none (MAP-37).
  PlannedPath? find({
    required Mover mover,
    required nav.CellRef from,
    required nav.CellRef to,
  });
}

/// {@template navigation_path_planner}
/// The real [PathPlanner]: `battle_pathfinding` on the navigation model the
/// loader makes of the built map, priced by `battle_rules`' movement cost,
/// searched the way the host searches (`SharedMap`, `command_handler`): the
/// ground search for a mover on the ground, the general search otherwise.
///
/// It knows the map as built: the structures built and destroyed during the
/// battle (the delta layer) are not applied to it, so after one a preview
/// can differ from the host's answer, which wins.
/// {@endtemplate}
final class NavigationPathPlanner implements PathPlanner {
  /// {@macro navigation_path_planner}
  new({required nav.NavigationMap map, required TerrainData terrain})
    : _map = map,
      _cost = MovementCost(terrain).call {
    final highest = [
      ...map.ground.map((cell) => cell.height),
      for (final island in map.islands.values)
        ...island.values.map((cell) => cell.height),
    ].reduce(math.max);
    _rules = nav.PathRules(
      roadConstruction: roadConstruction,
      altitudeLimitM: highest + terrain.flyingMaxAboveHighestTerrainM,
    );
    _grid = nav.GroundGrid(map: map, rules: _rules);
    _finder = nav.Pathfinder(map: map, cost: _cost, rules: _rules);
  }

  final nav.NavigationMap _map;
  final nav.MovementCostFunction _cost;
  late final nav.PathRules _rules;
  late final nav.GroundGrid _grid;
  late final nav.Pathfinder _finder;
  final _searches = <(double, String), nav.GroundSearch>{};

  @override
  double get cellSizeM => _map.cellSizeM;

  @override
  nav.CellRef? cellAt(Position position) => cellUnder(_map, position);

  @override
  Position pointOf(nav.CellRef cell, {bool flying = false}) => Position.metres(
    (cell.x + 0.5) * cellSizeM,
    (cell.y + 0.5) * cellSizeM,
    flying ? _rules.altitudeLimitM : _map.cellAt(cell)!.height,
  );

  @override
  PlannedPath? find({
    required Mover mover,
    required nav.CellRef from,
    required nav.CellRef to,
  }) {
    final pathMover = nav.PathMover(apPerM: mover.apPerM, modes: mover.modes);
    final onGround =
        from.surface == nav.groundSurface &&
        to.surface == nav.groundSurface &&
        !mover.modes.contains(_rules.flyingMode);
    final found = onGround
        ? _searches
              .putIfAbsent(
                (mover.apPerM, mover.modes.join(',')),
                () => nav.GroundSearch.on(_grid, cost: _cost, mover: pathMover),
              )
              .fast(from, to)
        : _finder.find(mover: pathMover, from: from, to: to);
    if (found == null) return null;
    return PlannedPath(
      cells: found.cells,
      samples: [
        for (final sample in found.samples)
          PathSample(
            terrainType: sample.terrainType,
            slopeDegrees: sample.slopeDegrees,
            lengthM: sample.lengthM,
          ),
      ],
      cost: found.cost,
    );
  }
}
