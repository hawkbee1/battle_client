import 'dart:math' as math;

import 'package:battle_client/src/held_view.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:battle_rules/battle_rules.dart'
    show CombatData, StorageSettings, UnitsData, WeaponType;
import 'package:equatable/equatable.dart';

/// Why the client expects the host to refuse an order. Every [code] is the
/// refusal code the host would answer with (`CommandRefused.reason`), so that
/// a pre-check and the host's own answer are shown the same way.
enum PreCheckRefusal {
  /// The unit is not on the field (it is stored, carried or a prisoner).
  notOnField('not_on_field'),

  /// The unit has no weapon (COMBAT-13, UNIT-38).
  noWeapon('no_weapon'),

  /// The target is not in the section's view (COMBAT-11).
  targetNotSeen('target_not_seen'),

  /// The weapon cannot hit a flying target (COMBAT-25).
  cannotHitFlying('cannot_hit_flying'),

  /// The target is further than the weapon's range (COMBAT-11).
  outOfRange('out_of_range'),

  /// The weapon does not fire at a position (COMBAT-12, COMBAT-55).
  notIndirect('not_indirect'),

  /// The weapon is not aimed in first person (decision 183).
  notAimed('not_aimed'),

  /// The magazine is empty: reload first (COMBAT-33).
  emptyMagazine('empty_magazine'),

  /// A shot costs more AP than the pool can ever hold (COMBAT-06).
  costAboveApMax('cost_above_ap_max'),

  /// The unit's type may not use that weapon type (COMBAT-26).
  notAllowed('not_allowed'),

  /// The section's storage holds no such weapon (decision 151).
  notInStorage('not_in_storage'),

  /// The unit is not next to its storage place (COMBAT-28).
  notAtStorage('not_at_storage'),

  /// Only a stored unit deploys (HQ-33).
  notStored('not_stored'),

  /// A prisoner buys nothing and is not deployed (COMBAT-43).
  isPrisoner('is_prisoner'),

  /// The section is under its full storage lock (HQ-35).
  sectionLocked('section_locked'),

  /// An enemy the section sees is near the storage place (HQ-36, HQ-39).
  blockedByEnemy('blocked_by_enemy'),

  /// The guild camp is never stored by order (HQ-30, HQ-47).
  neverStored('never_stored'),

  /// A transport is stored empty: unload it first (HQ-49).
  carriesUnits('carries_units'),

  /// The unit's recall runs already (HQ-32).
  alreadyRecalled('already_recalled');

  new(this.code);

  /// The host's refusal code.
  final String code;
}

/// {@template pre_checked}
/// What the client expects of an order before it sends it. The host decides:
/// a pre-checked order the host refuses shows the host's refusal.
/// {@endtemplate}
sealed class PreChecked extends Equatable {
  /// {@macro pre_checked}
  const new();
}

/// {@template pre_check_passed}
/// The client sees nothing against the order. A shot that needs more AP than
/// the unit has waits for them and is never refused for it (COMBAT-06):
/// [apWait] is how long.
/// {@endtemplate}
final class PreCheckPassed extends PreChecked {
  /// {@macro pre_check_passed}
  const new({this.apWait = Duration.zero});

  /// How long the order waits for AP; zero when the unit has enough now.
  final Duration apWait;

  @override
  List<Object?> get props => [apWait];
}

/// {@template pre_check_refused}
/// The client expects the host to refuse the order, for [reason].
/// {@endtemplate}
final class PreCheckRefused extends PreChecked {
  /// {@macro pre_check_refused}
  const new(this.reason);

  /// Why.
  final PreCheckRefusal reason;

  @override
  List<Object?> get props => [reason];
}

/// {@template store_plan}
/// What a store order does, as the client expects it (HQ-31, HQ-32): the
/// button says which before the order is sent.
/// {@endtemplate}
sealed class StorePlan extends Equatable {
  /// {@macro store_plan}
  const new();
}

/// {@template stored_at_once}
/// The unit is next to its storage place: it is stored at once (HQ-31).
/// {@endtemplate}
final class StoredNow extends StorePlan {
  /// {@macro stored_at_once}
  const new();

  @override
  List<Object?> get props => [];
}

/// {@template recalled_after}
/// The unit is elsewhere: it is recalled and stored after [takes] (HQ-32).
/// Nothing stops a recall once started.
/// {@endtemplate}
final class RecalledAfter extends StorePlan {
  /// {@macro recalled_after}
  const new(this.takes);

  /// How long the recall takes.
  final Duration takes;

  @override
  List<Object?> get props => [takes];
}

/// {@template store_not_possible}
/// The client expects the host to refuse the order, for [reason].
/// {@endtemplate}
final class StoreNotPossible extends StorePlan {
  /// {@macro store_not_possible}
  const new(this.reason);

  /// Why.
  final PreCheckRefusal reason;

  @override
  List<Object?> get props => [reason];
}

/// {@template order_pre_check}
/// The order pre-check of M7 Issue 5 (stack decision 8): range, rounds, AP
/// and the weapon handling rules, from `battle_rules`' data and the section's
/// own view, so that a button can say "out of range" before the order goes.
/// For display only: the host checks every order, and its answer wins
/// (decision 3). It cannot see what the host sees — whether the unit itself
/// sees its target (COMBAT-11), a position its section does not see
/// (COMBAT-12) — so it passes those and leaves them to the host.
///
/// Range is the host's: the horizontal distance between the cells' centres,
/// which two views' positions are (`World.distanceM` in `battle_host`);
/// decision 235's 3D lines are for sight, not for range.
/// {@endtemplate}
final class OrderPreCheck {
  /// {@macro order_pre_check}
  const new({required this.combat, required this.units, required this.storage});

  /// The weapons (`combat.yaml`).
  final CombatData combat;

  /// The unit types (`units.yaml`).
  final UnitsData units;

  /// The storage numbers (`storage` of `battle.yaml`): the radius within
  /// which a unit is stored at once and swaps its weapon (HQ-31, COMBAT-28),
  /// the recall time, the deploy cost and the radius an enemy blocks.
  final StorageSettings storage;

  /// How close to its storage place a unit swaps its weapon, in metres.
  double get storeRadiusM => storage.storeRadiusM;

  /// The weapon type [id] of `combat.yaml`; null for none or one this client's
  /// data does not know.
  WeaponType? weaponType(String? id) => combat.weaponTypes[id];

  /// [shooter] fires at [target], a unit of the section's view, at battle time
  /// [time] (COMBAT-11).
  PreChecked fire({
    required UnitView shooter,
    required UnitView? target,
    required Duration time,
  }) {
    final early = _armed(shooter);
    if (early != null) return early;
    final at = target?.position;
    if (target == null || at == null) {
      return const PreCheckRefused(PreCheckRefusal.targetNotSeen);
    }
    final weapon = weaponType(shooter.weapon);
    // A weapon this client does not know: the host decides.
    if (weapon == null) return const PreCheckPassed();
    if (target.flying && weapon.airborneFactor == 0) {
      return const PreCheckRefused(PreCheckRefusal.cannotHitFlying);
    }
    if (_distanceM(shooter.position!, at) > weapon.rangeM) {
      return const PreCheckRefused(PreCheckRefusal.outOfRange);
    }
    return _shot(shooter, weapon, time);
  }

  /// [shooter] fires at the ground position [target]: indirect fire or the
  /// explosive charge (COMBAT-12, COMBAT-55).
  PreChecked fireAtPosition({
    required UnitView shooter,
    required Position target,
    required Duration time,
  }) {
    final early = _armed(shooter);
    if (early != null) return early;
    final weapon = weaponType(shooter.weapon);
    if (weapon == null) return const PreCheckPassed();
    if (!weapon.indirectFire && weapon.splashRadiusM == null) {
      return const PreCheckRefused(PreCheckRefusal.notIndirect);
    }
    if (_distanceM(shooter.position!, target) > weapon.rangeM) {
      return const PreCheckRefused(PreCheckRefusal.outOfRange);
    }
    return _shot(shooter, weapon, time);
  }

  /// [shooter] fires toward an aim of the player, from inside the unit
  /// (COMBAT-14, decision 183).
  PreChecked fireAimed({required UnitView shooter, required Duration time}) {
    final early = _armed(shooter);
    if (early != null) return early;
    final weapon = weaponType(shooter.weapon);
    if (weapon == null) return const PreCheckPassed();
    if (weapon.projectileSpeedMps == null) {
      return const PreCheckRefused(PreCheckRefusal.notAimed);
    }
    return _shot(shooter, weapon, time);
  }

  /// [unit] reloads its weapon (COMBAT-33): time only, no AP (COMBAT-05).
  PreChecked reload(UnitView unit) => _armed(unit) ?? const PreCheckPassed();

  /// The spare weapons of the section's storage [stored] that [unit]'s type
  /// may use (COMBAT-26), each type once, in name order.
  List<String> swappable(UnitView unit, Iterable<String> stored) {
    final allowed = units.unitTypes[unit.unitType]?.weapons.allowed;
    return {
      for (final weapon in stored)
        if (allowed == null || allowed.contains(weapon)) weapon,
    }.toList()..sort();
  }

  /// [unit] takes [weapon] from the section's storage [stored] (COMBAT-27,
  /// COMBAT-28). [storage] is the position of its storage place, its team's
  /// HQ, when the section sees it.
  PreChecked swap({
    required UnitView unit,
    required String weapon,
    required Iterable<String> stored,
    required Position? storage,
  }) {
    if (!_onField(unit)) {
      return const PreCheckRefused(PreCheckRefusal.notOnField);
    }
    if (storage == null || _distanceM(unit.position!, storage) > storeRadiusM) {
      return const PreCheckRefused(PreCheckRefusal.notAtStorage);
    }
    if (!swappable(unit, [weapon]).contains(weapon)) {
      return const PreCheckRefused(PreCheckRefusal.notAllowed);
    }
    if (!stored.contains(weapon)) {
      return const PreCheckRefused(PreCheckRefusal.notInStorage);
    }
    return const PreCheckPassed();
  }

  /// The refusal that stops every weapon order of [unit], or null.
  PreChecked? _armed(UnitView unit) {
    if (!_onField(unit)) {
      return const PreCheckRefused(PreCheckRefusal.notOnField);
    }
    if (unit.weapon == null) {
      return const PreCheckRefused(PreCheckRefusal.noWeapon);
    }
    return null;
  }

  static bool _onField(UnitView unit) =>
      unit.position != null && unit.private?.place == UnitPlace.deployed;

  /// The magazine and the AP of one shot (COMBAT-04, COMBAT-06, COMBAT-33).
  PreChecked _shot(UnitView shooter, WeaponType weapon, Duration time) {
    final private = shooter.private!;
    if (private.rounds == 0) {
      return const PreCheckRefused(PreCheckRefusal.emptyMagazine);
    }
    return _paid(private.ap, weapon.apPerShot, time);
  }

  /// A payment of [cost] AP from [ap] at [time]: refused when the pool can
  /// never hold it, else passed, with the wait for the AP it lacks
  /// (COMBAT-06).
  PreChecked _paid(ApView ap, double cost, Duration time) {
    if (cost > ap.max) {
      return const PreCheckRefused(PreCheckRefusal.costAboveApMax);
    }
    final missing = cost - apAt(ap, time);
    if (missing <= 0) return const PreCheckPassed();
    return PreCheckPassed(
      apWait: Duration(
        microseconds: (missing / ap.perHour * Duration.microsecondsPerHour)
            .round(),
      ),
    );
  }

  /// [unit] stored at once, or recalled from afar (HQ-31, HQ-32, HQ-49).
  /// [portal] is the position of its storage place when the section sees
  /// it; [units] the section's units, to know whether a transport carries
  /// any; [recalledUntil] the end of its recall when one runs.
  StorePlan store({
    required UnitView unit,
    required Position? portal,
    required Iterable<UnitView> units,
    required Duration time,
    Duration? recalledUntil,
  }) {
    if (!_onField(unit)) {
      return const StoreNotPossible(PreCheckRefusal.notOnField);
    }
    if (this.units.unitTypes[unit.unitType]?.storable == false) {
      return const StoreNotPossible(PreCheckRefusal.neverStored);
    }
    if (units.any((other) => other.private?.transportId == unit.unitId)) {
      return const StoreNotPossible(PreCheckRefusal.carriesUnits);
    }
    if (portal != null &&
        _distanceM(unit.position!, portal) <= storage.storeRadiusM) {
      return const StoredNow();
    }
    if (recalledUntil != null && recalledUntil > time) {
      return const StoreNotPossible(PreCheckRefusal.alreadyRecalled);
    }
    return RecalledAfter(
      Duration(microseconds: (storage.recallS * 1e6).round()),
    );
  }

  /// [unit], stored, deployed next to the storage place at [portal], for
  /// `deploy_ap` (HQ-33). [lockedUntil] is the end of the section's lock
  /// (HQ-35); [seen] the units its section sees, among which an enemy within
  /// `deploy_block_radius_m` of the portal blocks it (HQ-36, HQ-39). An
  /// enemy the section does not see blocks it all the same: the host's
  /// refusal then shows, and the client gives no clue before (decision 237).
  /// Like any paid action it waits for the AP it lacks (COMBAT-06).
  PreChecked deploy({
    required UnitView unit,
    required Position? portal,
    required Iterable<UnitView> seen,
    required Duration time,
    Duration? lockedUntil,
  }) {
    final private = unit.private;
    if (private?.place == UnitPlace.prisoner) {
      return const PreCheckRefused(PreCheckRefusal.isPrisoner);
    }
    if (private == null || private.place != UnitPlace.stored) {
      return const PreCheckRefused(PreCheckRefusal.notStored);
    }
    if (lockedUntil != null && time < lockedUntil) {
      return const PreCheckRefused(PreCheckRefusal.sectionLocked);
    }
    if (portal != null &&
        seen.any(
          (other) =>
              other.team != unit.team &&
              other.position != null &&
              _distanceM(other.position!, portal) <= storage.deployBlockRadiusM,
        )) {
      return const PreCheckRefused(PreCheckRefusal.blockedByEnemy);
    }
    return _paid(private.ap, storage.deployAp, time);
  }

  static double _distanceM(Position a, Position b) {
    final east = (a.xCm - b.xCm) / 100;
    final south = (a.yCm - b.yCm) / 100;
    return math.sqrt(east * east + south * south);
  }
}
