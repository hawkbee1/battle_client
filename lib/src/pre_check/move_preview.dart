import 'package:battle_client/src/pre_check/order_pre_check.dart';
import 'package:battle_client/src/pre_check/path_planner.dart';
import 'package:battle_pathfinding/battle_pathfinding.dart' as nav;
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart'
    show ApPool, MovementCost, Mover, TerrainData, UnitsData;
import 'package:equatable/equatable.dart';

/// {@template move_plan}
/// What the client expects of a move order before it sends it (stack
/// decision 8): display only, the host decides and its answer wins.
/// {@endtemplate}
sealed class MovePlan extends Equatable {
  /// {@macro move_plan}
  const new();
}

/// {@template move_preview}
/// The move as the client would send it: the [cells] of its path (the order's
/// `path`, which the host checks cell by cell), the [points] to draw, its AP
/// [costAp] (COMBAT-03), when it [arrivesAt] on the battle clock, and how
/// long of that is [apWait], the wait for AP the unit lacks (COMBAT-06,
/// MAP-20).
/// {@endtemplate}
final class MovePreview extends MovePlan {
  /// {@macro move_preview}
  const new({
    required this.destination,
    required this.cells,
    required this.points,
    required this.costAp,
    required this.lengthM,
    required this.arrivesAt,
    required this.apWait,
  });

  /// Where the order goes, as the player chose it.
  final Position destination;

  /// The path for the order, from the unit's cell to the destination's.
  final List<Cell> cells;

  /// The points of the path, to draw it.
  final List<Position> points;

  /// The AP the path costs.
  final double costAp;

  /// The path's length, in metres.
  final double lengthM;

  /// The battle time the unit arrives.
  final Duration arrivesAt;

  /// How much of the trip is waiting for AP; zero when the unit has them.
  final Duration apWait;

  @override
  List<Object?> get props => [
    destination,
    cells,
    points,
    costAp,
    lengthM,
    arrivesAt,
    apWait,
  ];
}

/// {@template move_refused}
/// The client expects the host to refuse the move, for [reason]: nothing is
/// sent.
/// {@endtemplate}
final class MoveRefused extends MovePlan {
  /// {@macro move_refused}
  const new(this.reason);

  /// Why.
  final PreCheckRefusal reason;

  @override
  List<Object?> get props => [reason];
}

/// {@template move_unplanned}
/// The client cannot tell (a unit type its data does not know): the order
/// goes without a path and the host searches one.
/// {@endtemplate}
final class MoveUnplanned extends MovePlan {
  /// {@macro move_unplanned}
  const new();

  @override
  List<Object?> get props => [];
}

/// {@template move_previewer}
/// The move preview of M7 Issue 8 (stack decision 8): the path and its AP
/// cost before the order is sent, from the map ([planner]) and the rules'
/// own movement cost (`battle_rules`, no table copied here), the way the host
/// prices the same order. A destination a seen unit takes the place of is
/// refused (MAP-50, friend or enemy, flying units apart); an unseen one gives
/// no clue (decision 237) and only the host says so.
///
/// For display only: the host checks the path cell by cell and prices it
/// itself, and its answer wins; a difference is shown, not argued
/// (decision 3).
/// {@endtemplate}
final class MovePreviewer {
  /// {@macro move_previewer}
  const new({
    required this.planner,
    required this.units,
    required this.terrain,
  });

  /// The map.
  final PathPlanner planner;

  /// The unit types (`units.yaml`): movement class, speed, hit volume.
  final UnitsData units;

  /// The terrain tables (`terrain.yaml`), which price the path.
  final TerrainData terrain;

  /// [unit] moves to [destination] at battle time [time] (COMBAT-03,
  /// COMBAT-06, MAP-47, MAP-50). [seen] are the units its section sees.
  MovePlan preview({
    required UnitView unit,
    required Position destination,
    required Iterable<UnitView> seen,
    required Duration time,
  }) {
    final private = unit.private;
    final position = unit.position;
    if (position == null || private?.place != UnitPlace.deployed) {
      return const MoveRefused(PreCheckRefusal.notOnField);
    }
    final type = units.unitTypes[unit.unitType];
    if (type == null || (unit.flying && !type.canFly)) {
      return const MoveUnplanned();
    }
    final from = planner.cellAt(position);
    if (from == null) return const MoveUnplanned();
    final goal = planner.cellAt(destination);
    if (goal == null) return const MoveRefused(PreCheckRefusal.offMap);
    if (!unit.flying && _taken(unit, type.hitBox.width, goal, seen)) {
      return const MoveRefused(PreCheckRefusal.occupied);
    }
    final mover = Mover.unit(type, flying: unit.flying);
    final planned = planner.find(mover: mover, from: from, to: goal);
    if (planned == null) return const MoveRefused(PreCheckRefusal.noPath);
    final ap = private!.ap;
    final movement = MovementCost(terrain).move(
      mover: mover,
      pool: ApPool(
        max: ap.max,
        recoveryDelayS: (Duration.secondsPerHour / ap.perHour).round().clamp(
          1,
          1 << 30,
        ),
        value: ap.value.clamp(0, ap.max),
        updatedAt: ap.at,
      ),
      start: time,
      path: planned.samples,
    );
    if (movement == null) return const MoveRefused(PreCheckRefusal.noPath);
    final lengthM = [for (final sample in planned.samples) sample.lengthM]
        .fold<double>(0, (sum, length) => sum + length);
    final walking = Duration(
      microseconds: (lengthM / mover.speedMps * Duration.microsecondsPerSecond)
          .round(),
    );
    final trip = movement.arrivesAt - time;
    return MovePreview(
      destination: destination,
      cells: [
        for (final cell in planned.cells)
          Cell(
            cell.x,
            cell.y,
            island: cell.surface == nav.groundSurface ? null : cell.surface,
          ),
      ],
      points: [
        for (final cell in planned.cells)
          planner.pointOf(cell, flying: unit.flying),
      ],
      costAp: planned.cost,
      lengthM: lengthM,
      arrivesAt: movement.arrivesAt,
      apWait: trip > walking ? trip - walking : Duration.zero,
    );
  }

  /// MAP-50: the width the units [seen] standing in [goal] take out of the
  /// cell leaves less than the [width] of the mover.
  bool _taken(
    UnitView mover,
    double width,
    nav.CellRef goal,
    Iterable<UnitView> seen,
  ) {
    var left = planner.cellSizeM;
    for (final other in seen) {
      final at = other.position;
      if (other.unitId == mover.unitId || at == null || other.flying) continue;
      if (planner.cellAt(at) == goal) {
        left -= units.unitTypes[other.unitType]?.hitBox.width ?? 0;
      }
    }
    return left < width;
  }
}
