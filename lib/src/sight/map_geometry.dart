import 'package:battle_pathfinding/battle_pathfinding.dart' as nav;
import 'package:battle_protocol/battle_protocol.dart';

/// The cell under [position] on [map], by the host's own rule (`World`'s
/// `cellAt`): on a floating island when one covers it and the position is
/// nearer its surface than the ground's; null off the map.
nav.CellRef? cellUnder(nav.NavigationMap map, Position position) {
  final x = (position.x / map.cellSizeM).floor();
  final y = (position.y / map.cellSizeM).floor();
  final ground = map.cellAt(nav.CellRef(x, y));
  if (ground == null) return null;
  for (final MapEntry(key: name, value: cells) in map.islands.entries) {
    final island = cells[(x, y)];
    if (island != null &&
        (position.z - island.height).abs() <
            (position.z - ground.height).abs()) {
      return nav.CellRef(x, y, surface: name);
    }
  }
  return nav.CellRef(x, y);
}
