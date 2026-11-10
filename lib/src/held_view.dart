import 'dart:collection';
import 'dart:math' as math;

import 'package:battle_protocol/battle_protocol.dart';

/// The AP of [ap] at battle time [time] (COMBAT-02): AP recovers at its
/// constant rate from its last value up to its maximum, so the client shows
/// it between updates without the host (stack decision 8). Before the
/// value's time (a payment that waits for its AP dates the pool ahead), it
/// is what the pool can spare then, never below 0.
double apAt(ApView ap, Duration time) {
  final hours = (time - ap.at).inMicroseconds / Duration.microsecondsPerHour;
  return hours < 0
      ? math.max(0, ap.value + hours * ap.perHour)
      : math.min(ap.max, ap.value + hours * ap.perHour);
}

/// {@template held_view}
/// A section's view as its client holds it (M6 Issue 7): the whole view
/// the host sends at sign-in, then each tick's update applied to it. It
/// holds what the host's view of the section holds (`SectionView`): the
/// units the section knows, the HQs it sees, the relics, the victory
/// countdown, its private state and the delta layer (MAP-08); and the
/// `Roster` the host sends after it (M7.7).
///
/// A unit is replaced whole when the host sends it whole (it came into
/// sight, or its private state changed); a unit the section sees changes
/// position with the moves, and hit points with the events: hits, heals
/// and repairs. Interpolation and drawing are M7's.
/// {@endtemplate}
final class HeldView {
  /// {@macro held_view}
  new();

  final _units = <String, UnitView>{};
  final _hqs = <String, HqView>{};
  final _relics = <String, RelicView>{};
  final _craters = <CraterDug>[];
  final _built = <String, StructureBuilt>{};
  final _damaged = <String, ObjectDamaged>{};
  final _destroyed = <String, ObjectDestroyed>{};
  final _recalls = <String, Duration>{};

  /// The battle time of the last view or update.
  Duration? get at => _at;
  Duration? _at;

  /// Whether a whole view came: until then the view holds nothing.
  bool get isWhole => _section != null;

  /// The section's own state.
  SectionPrivate? get section => _section;
  SectionPrivate? _section;

  /// The recalls the section's units run (HQ-32): the battle time each is
  /// stored, by unit ID. The host tells it once, with `RecallBegan`, and the
  /// whole view does not hold it: a recall begun before the client's last
  /// sign-in is not known.
  Map<String, Duration> get recalls => UnmodifiableMapView(_recalls);

  /// What the battle lets the section buy, as the host sent it after the
  /// whole view (ECO-04, COMBAT-27, M7.7); null until it came. A resync
  /// sends it again, and it replaces the one held.
  Roster? get roster => _roster;
  Roster? _roster;

  /// The running victory countdown (RELIC-16).
  HoldView? get hold => _hold;
  HoldView? _hold;

  /// The units the section knows, its own included, by ID.
  Map<String, UnitView> get units => UnmodifiableMapView(_units);

  /// The HQs it sees, by team.
  Map<String, HqView> get hqs => UnmodifiableMapView(_hqs);

  /// The relics, by ID.
  Map<String, RelicView> get relics => UnmodifiableMapView(_relics);

  /// The delta layer as world events (MAP-08), in the host's order: the
  /// craters in the order they were dug, the structures built, the objects
  /// damaged, and those destroyed.
  List<BattleEvent> get world => [
    ..._craters,
    ..._built.values,
    ..._damaged.values,
    ..._destroyed.values,
  ];

  /// The view as the host's whole view of the section.
  ///
  /// Throws a [StateError] before the first whole view.
  SectionView get asSectionView {
    final section = _section;
    if (section == null) throw StateError('no whole view yet');
    return SectionView(
      at: _at!,
      section: section,
      units: _units.values.toList(),
      hqs: _hqs.values.toList(),
      relics: _relics.values.toList(),
      hold: _hold,
      world: world,
    );
  }

  /// Applies [message]: a whole view replaces everything, an update changes
  /// what it names. Other messages change nothing.
  void apply(HostMessage message) {
    switch (message) {
      case SectionView():
        _whole(message);
      case TickUpdate():
        _update(message);
      case Roster():
        _roster = message;
      case SignInAccepted() ||
          SignInRefused() ||
          CommandAccepted() ||
          CommandRefused() ||
          RelicAlert() ||
          Goodbye():
        break;
    }
  }

  void _whole(SectionView view) {
    _at = view.at;
    _section = view.section;
    _hold = view.hold;
    _units
      ..clear()
      ..addEntries(view.units.map((unit) => MapEntry(unit.unitId, unit)));
    _hqs
      ..clear()
      ..addEntries(view.hqs.map((hq) => MapEntry(hq.team, hq)));
    _relics
      ..clear()
      ..addEntries(view.relics.map((relic) => MapEntry(relic.relicId, relic)));
    _recalls.clear();
    _craters.clear();
    _built.clear();
    _damaged.clear();
    _destroyed.clear();
    view.world.forEach(_world);
  }

  void _update(TickUpdate update) {
    _at = update.at;
    for (final UnitPosition(:unitId, :position) in update.moved) {
      if (_units[unitId] case final unit?) {
        _units[unitId] = _with(unit, position: position);
      }
    }
    // A unit sent whole already holds this tick's hits and heals.
    final whole = <String>{};
    for (final unit in [...update.appeared, ...update.ownUnits]) {
      _units[unit.unitId] = unit;
      whole.add(unit.unitId);
    }
    update.gone.forEach(_units.remove);
    _recalls.removeWhere((unitId, _) => !_units.containsKey(unitId));
    for (final event in update.events) {
      _event(event, update.at, whole);
    }
    for (final burst in update.bursts) {
      _hits(burst.impacts, whole);
    }
    for (final fired in update.fired) {
      _hits(fired.impacts, whole);
    }
    for (final hit in update.unseenHits) {
      _damage(hit.targetId, hit.damage, whole);
    }
    _section = update.section ?? _section;
    for (final hq in update.hqs) {
      _hqs[hq.team] = hq;
    }
    update.hqsGone.forEach(_hqs.remove);
    for (final relic in update.relics) {
      _relics[relic.relicId] = relic;
    }
  }

  void _event(BattleEvent event, Duration at, Set<String> whole) {
    switch (event) {
      case Attacked(:final impacts):
        _hits(impacts, whole);
      case UnitHealed(targetId: final id, :final hp) ||
          Repaired(targetId: final id, :final hp):
        if (_units[id] case final unit? when !whole.contains(id)) {
          _units[id] = _with(unit, hp: hp);
        }
      case RecallBegan(:final unitId, :final storedAt):
        _recalls[unitId] = storedAt;
      case UnitStored(:final unitId) || UnitDeployed(:final unitId):
        _recalls.remove(unitId);
      case VictoryHoldStarted(:final team, :final winsAt):
        _hold = HoldView(team: team, since: at, winsAt: winsAt);
      case VictoryHoldReset():
        _hold = null;
      case StructureBuilt() ||
          ObjectDamaged() ||
          ObjectDestroyed() ||
          CraterDug():
        _world(event);
      default:
        break;
    }
  }

  void _hits(List<Impact> impacts, Set<String> whole) {
    for (final impact in impacts) {
      _damage(impact.targetId, impact.damage, whole);
    }
  }

  void _damage(String unitId, double damage, Set<String> whole) {
    final unit = _units[unitId];
    // The host sends its own units whole when they change.
    if (unit == null || unit.private != null || whole.contains(unitId)) {
      return;
    }
    _units[unitId] = _with(unit, hp: math.max(0, unit.hp - damage));
  }

  void _world(BattleEvent event) {
    switch (event) {
      case CraterDug():
        _craters.add(event);
      case StructureBuilt(:final siteId):
        _built[siteId] = event;
      case ObjectDamaged(:final object, :final cells):
        _damaged[_key(object, cells)] = event;
      case ObjectDestroyed(:final object, :final cells):
        final key = _key(object, cells);
        _damaged.remove(key);
        _destroyed[key] = event;
      default:
        throw ArgumentError.value(event, 'event', 'not a world event');
    }
  }

  static String _key(String object, List<Cell> cells) => [
    object,
    for (final cell in cells) '${cell.x},${cell.y},${cell.island}',
  ].join(' ');

  static UnitView _with(UnitView unit, {Position? position, double? hp}) =>
      UnitView(
        unitId: unit.unitId,
        unitType: unit.unitType,
        sectionId: unit.sectionId,
        team: unit.team,
        hp: hp ?? unit.hp,
        maxHp: unit.maxHp,
        position: position ?? unit.position,
        flying: unit.flying,
        weapon: unit.weapon,
        private: unit.private,
      );
}
