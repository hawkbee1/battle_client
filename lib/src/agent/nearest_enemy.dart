import 'dart:async';

import 'package:battle_client/src/battle_client.dart';
import 'package:battle_client/src/held_view.dart';
import 'package:battle_protocol/battle_protocol.dart';

/// {@template nearest_enemy_agent}
/// The example AI agent of M6 Issue 7: each time its section's view
/// changes, each of its units on the field with a weapon fires at the
/// nearest enemy its section sees. A unit waits for the answer to its
/// order before it fires again.
///
/// It checks nothing the host checks (stack decision 8): a target out of
/// range or a unit short of AP is refused by the host, and the unit fires
/// again at the next change.
/// {@endtemplate}
final class NearestEnemyAgent {
  /// {@macro nearest_enemy_agent}
  new(this.client);

  /// Its client.
  final BattleClient client;

  final _waiting = <String>{};

  /// The orders sent and the answers they got, in order.
  final answers = <(Fire, CommandAnswer)>[];

  /// Starts: acts on each whole view and each update.
  StreamSubscription<HostMessage> start() => client.messages.listen((message) {
    if (message is SectionView || message is TickUpdate) act();
  });

  /// Fires each of its idle units at the nearest enemy.
  void act() {
    final seat = client.seat!;
    for (final fire in orders(client.view, seat.sectionId, seat.team)) {
      if (!_waiting.add(fire.unitId)) continue;
      unawaited(
        client
            .send(fire)
            .then((answer) => answers.add((fire, answer)), onError: (_) {})
            .whenComplete(() => _waiting.remove(fire.unitId)),
      );
    }
  }

  /// The shots of [sectionId]'s units of [team] at the nearest enemy in
  /// [view]: one per unit on the field with a weapon, while the section
  /// sees an enemy.
  static List<Fire> orders(HeldView view, String sectionId, String team) {
    final enemies = [
      for (final unit in view.units.values)
        if (unit.team != team && unit.hp > 0 && unit.position != null) unit,
    ];
    if (enemies.isEmpty) return const [];
    return [
      for (final unit in view.units.values)
        if (unit.sectionId == sectionId &&
            unit.private?.place == UnitPlace.deployed &&
            unit.weapon != null &&
            unit.hp > 0)
          if (unit.position case final from?)
            Fire(unitId: unit.unitId, targetId: _nearest(from, enemies).unitId),
    ];
  }

  static UnitView _nearest(Position from, List<UnitView> enemies) {
    int distance(UnitView unit) {
      final to = unit.position!;
      final dx = to.xCm - from.xCm;
      final dy = to.yCm - from.yCm;
      final dz = to.zCm - from.zCm;
      return dx * dx + dy * dy + dz * dz;
    }

    return enemies.reduce((a, b) => distance(b) < distance(a) ? b : a);
  }
}
