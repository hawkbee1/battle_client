import 'dart:async';
import 'dart:math' as math;

import 'package:battle_client/src/adapters/appwrite_host_finder.dart';
import 'package:battle_client/src/backoff.dart';
import 'package:battle_client/src/credential.dart';
import 'package:battle_client/src/held_view.dart';
import 'package:battle_client/src/ports/clock.dart';
import 'package:battle_client/src/ports/transport.dart';
import 'package:battle_client/src/request_ids.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:logging/logging.dart';

/// {@template client_settings}
/// A client's timings (stack decision 3): the host closes a socket silent
/// for 60 s, so the client sends a heartbeat every 20 s; a client that
/// lost its host waits [backoff] between attempts.
/// {@endtemplate}
final class ClientSettings {
  /// {@macro client_settings}
  const new({
    this.heartbeat = const Duration(seconds: 20),
    this.backoff = const Backoff(
      first: Duration(milliseconds: 500),
      max: Duration(seconds: 30),
    ),
  });

  /// How often a signed-in client sends a heartbeat.
  final Duration heartbeat;

  /// The waits between attempts to reach the host.
  final Backoff backoff;
}

/// Where a client stands.
enum ClientStatus {
  /// Not started.
  idle,

  /// Opening a socket and signing in.
  connecting,

  /// Signed in: commands go out, the view is kept up to date.
  signedIn,

  /// Lost its host; waiting before it tries again.
  waiting,

  /// Stopped for good: closed, or stopped by the host
  /// ([BattleClient.stoppedBy]).
  stopped,
}

/// The account and section a client signed in as.
typedef Seat = ({String accountId, String sectionId, String team});

/// {@template command_answer}
/// The host's answer to a command: accepted with its sequence number, or
/// refused with the refusal code of M5.11.
/// {@endtemplate}
final class CommandAnswer {
  /// {@macro command_answer}
  const new({required this.requestId, this.seq, this.refusal});

  /// The command's request ID.
  final int requestId;

  /// Its sequence number in the battle, when accepted.
  final int? seq;

  /// Why it was refused, when refused.
  final String? refusal;

  /// Whether the host accepted it.
  bool get accepted => seq != null;
}

/// {@template client_stopped}
/// What an unanswered command fails with when its client stops for good:
/// [stoppedBy] is the host's last word, [lookupRefused] the answer that
/// gave no host, or both null when the client was closed.
/// {@endtemplate}
final class ClientStoppedException implements Exception {
  /// {@macro client_stopped}
  const new(this.stoppedBy, {this.lookupRefused});

  /// The refused sign-in or the goodbye that stopped the client.
  final HostMessage? stoppedBy;

  /// The lasting refusal to give the host's address.
  final HostLookupException? lookupRefused;

  @override
  String toString() => 'ClientStoppedException(${stoppedBy ?? lookupRefused})';
}

/// {@template battle_client}
/// The client side of a connection to a battle's host (M6 Issue 7), for the
/// app (M7) and AI agents written in Dart, on every target, the web
/// included.
///
/// It asks for a credential, then for the address of the battle's host
/// with it (`AppwriteHostFinder.socketOf`, M6 Issue 6), opens a socket
/// there, signs in to [battleId], keeps the section's [view] from its
/// whole view and updates, and sends commands, each answered by its
/// request ID.
/// When it loses the host it waits ([ClientSettings.backoff]), asks for a
/// credential and the address again (the battle may have moved to another
/// host), signs in again, takes its whole view, and resends every command
/// that got no answer with its request ID: the host carries each out once
/// (M6 Issue 5).
///
/// It stops for good on a refused sign-in (but a battle not on this host,
/// which may have moved), on a lasting refusal to give the address
/// ([HostLookupException.lasting]), on a goodbye for a battle that ended,
/// a revoked key or a protocol version the host does not speak, and on
/// [close]. A slow or idle client's goodbye is a lost host.
///
/// The client checks nothing: the host checks every order (stack
/// decision 8). The order pre-check with `battle_rules` is M7's.
///
/// It logs its lifecycle on the `battle_client.BattleClient` logger: attempts,
/// credential kind, host address, socket and sign-in, refusals, the end of a
/// socket and the wait before the next attempt. Never a secret, and nothing
/// of what the section does not see (decision 237): no message's content.
/// The library only logs; the app sets the levels and prints.
/// {@endtemplate}
final class BattleClient {
  /// {@macro battle_client}
  new({
    required this.battleId,
    required this._transport,
    required this._address,
    required this._credential,
    required this._clock,
    required this._random,
    this.settings = const ClientSettings(),
  }) : _ids = RequestIds(_clock, _random);

  /// The battle.
  final String battleId;

  /// Its timings.
  final ClientSettings settings;

  final Transport _transport;
  final Future<Uri> Function(Credential credential) _address;
  final Future<Credential> Function() _credential;
  final Clock _clock;
  final math.Random _random;
  final RequestIds _ids;

  static const _codec = BinaryProtocolCodec();
  static final _log = Logger('battle_client.BattleClient');

  /// The section's view.
  final view = HeldView();

  final _messages = StreamController<HostMessage>.broadcast(sync: true);
  final _statuses = StreamController<ClientStatus>.broadcast(sync: true);
  final _pending = <int, _Pending>{};
  final _stopped = Completer<void>();

  TransportSocket? _socket;
  Timer? _heartbeat;
  Timer? _wait;
  Completer<void>? _waited;
  (Duration, DateTime)? _anchor;

  /// Every message of the host, once the [view] holds it.
  Stream<HostMessage> get messages => _messages.stream;

  /// Each change of [status].
  Stream<ClientStatus> get statuses => _statuses.stream;

  /// Where it stands.
  ClientStatus get status => _status;
  ClientStatus _status = ClientStatus.idle;

  /// The account and section it signed in as, from its first sign-in.
  Seat? get seat => _seat;
  Seat? _seat;

  /// The refused sign-in or goodbye that stopped it.
  HostMessage? get stoppedBy => _stoppedBy;
  HostMessage? _stoppedBy;

  /// The lasting refusal to give the host's address that stopped it.
  HostLookupException? get lookupRefused => _lookupRefused;
  HostLookupException? _lookupRefused;

  /// Completes once it stopped for good.
  Future<void> get stopped => _stopped.future;

  /// The request IDs of the commands sent and not answered yet, in order.
  List<int> get unanswered => _pending.keys.toList();

  /// The battle time now: the time of the host's last message, plus the
  /// wall time since it came (stack decision 8). Null before the first.
  Duration? get battleTime => switch (_anchor) {
    (final at, final heard) => at + _clock.now().difference(heard),
    null => null,
  };

  /// The AP of [ap] now, as the client shows it between updates (stack
  /// decision 8); null before the host's first message.
  double? apNow(ApView ap) => switch (battleTime) {
    final time? => apAt(ap, time),
    null => null,
  };

  /// Starts: opens a socket, signs in, and keeps the connection until it
  /// stops.
  ///
  /// Throws a [StateError] unless it is [ClientStatus.idle].
  void start() {
    if (_status != ClientStatus.idle) {
      throw StateError('a client starts once');
    }
    unawaited(_run());
  }

  /// Sends [order] as the signed-in account and its section, now in battle
  /// time. It goes out at once when signed in, else when the client signs
  /// in again; the future completes with the host's answer.
  ///
  /// Throws a [StateError] before the first sign-in or once stopped.
  Future<CommandAnswer> send(Order order) {
    final seat = _seat;
    if (_status == ClientStatus.stopped) {
      throw StateError('the client stopped');
    }
    if (seat == null) throw StateError('not signed in yet');
    final message = SendCommand(
      requestId: _ids.next(),
      command: Command(
        sender: Sender(accountId: seat.accountId, sectionId: seat.sectionId),
        sentAt: battleTime!,
        order: order,
      ),
    );
    final pending = _Pending(message);
    _pending[message.requestId] = pending;
    if (_status == ClientStatus.signedIn) {
      _log.info('command ${message.requestId} sent: ${order.runtimeType}');
      _send(message);
    } else {
      _log.info(
        'command ${message.requestId} held until sign-in: '
        '${order.runtimeType}',
      );
    }
    return pending.answer.future;
  }

  /// Asks the host for the section's whole view again, when the client lost
  /// track of it.
  void resync() {
    if (_status == ClientStatus.signedIn) _send(const ResyncRequest());
  }

  /// Closes the socket and stops for good.
  Future<void> close() async {
    if (_status == ClientStatus.stopped) return;
    final socket = _socket;
    _stop(null);
    await socket?.close();
  }

  Future<void> _run() async {
    var attempt = 0;
    var attempts = 0;
    while (_status != ClientStatus.stopped) {
      _setStatus(ClientStatus.connecting);
      _log.info('connecting (attempt ${++attempts})');
      if (await _session()) attempt = 0;
      if (_status == ClientStatus.stopped) return;
      _setStatus(ClientStatus.waiting);
      final waited = _waited = Completer<void>();
      final delay = settings.backoff.delay(attempt++, _random);
      _log.info('host lost, retry in ${delay.inMilliseconds / 1000} s');
      _wait = Timer(delay, waited.complete);
      await waited.future;
    }
  }

  /// One socket, from its opening to its end; true when it signed in.
  Future<bool> _session() async {
    final TransportSocket socket;
    final Credential credential;
    try {
      credential = await _credential();
      _log.info('credential ${credential.kind.name}');
      final uri = await _address(credential);
      _log.info('host address $uri');
      socket = await _transport.connect(uri);
      _log.info('socket open');
    } on HostLookupException catch (refused) {
      _log.warning('host lookup refused: $refused');
      if (refused.lasting && _status != ClientStatus.stopped) {
        _stop(null, lookup: refused);
      }
      return false;
    } on Object catch (error, stackTrace) {
      _log.severe('connecting failed', error, stackTrace);
      return false;
    }
    if (_status == ClientStatus.stopped) {
      await socket.close();
      return false;
    }
    _socket = socket;
    var signedIn = false;
    final ended = Completer<void>();
    var reason = '';
    void end(String why) {
      if (ended.isCompleted) return;
      reason = why;
      ended.complete();
    }

    // A broken socket, a frame the client does not read, or a message that
    // ends the socket: the host is lost, or the client stops.
    final frames = socket.frames.listen(
      (frame) {
        if (ended.isCompleted) return;
        final HostMessage message;
        try {
          message = _codec.decodeHostMessage(frame);
        } on ProtocolException catch (error) {
          _log.warning('unreadable frame: $error');
          end('unreadable frame');
          return;
        }
        if (message is SignInAccepted) signedIn = true;
        if (_handle(message)) return;
        end(switch (message) {
          SignInRefused(reason: final why) => 'sign-in refused ${why.name}',
          Goodbye(reason: final why) => 'goodbye ${why.name}',
          _ => 'client stopped',
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        _log.severe('socket failed', error, stackTrace);
        end('socket failed');
      },
      onDone: () => end(
        _status == ClientStatus.stopped
            ? 'client closed'
            : 'closed by the host',
      ),
      cancelOnError: true,
    );
    socket.send(
      _codec.encodeClientMessage(
        SignIn(
          battleId: battleId,
          kind: credential.kind,
          credential: credential.secret,
        ),
      ),
    );
    await ended.future;
    _log.info('socket closed: $reason');
    unawaited(frames.cancel());
    _heartbeat?.cancel();
    if (identical(_socket, socket)) _socket = null;
    await socket.close();
    return signedIn;
  }

  /// Handles [message]; false ends the socket.
  bool _handle(HostMessage message) {
    if (_status == ClientStatus.stopped) return false;
    view.apply(message);
    var keep = true;
    switch (message) {
      case SignInAccepted(:final accountId, :final sectionId, :final team):
        _log.info('sign-in accepted');
        _seat = (accountId: accountId, sectionId: sectionId, team: team);
        _heard(message.battleTime);
        // Before the status changes, so that a command its listeners send
        // goes out once.
        for (final pending in _pending.values) {
          _log.info('command ${pending.message.requestId} resent');
          _send(pending.message);
        }
        _setStatus(ClientStatus.signedIn);
        _heartbeat = Timer.periodic(
          settings.heartbeat,
          (_) => _send(const Heartbeat()),
        );
      case SignInRefused(:final reason):
        _log.warning('sign-in refused ${reason.name}');
        keep = false;
        if (reason != SignInRefusal.battleNotFound) _stop(message);
      case SectionView(:final at) || TickUpdate(:final at):
        _heard(at);
      case RelicAlert(:final at):
        _heard(at);
      case CommandAccepted(:final requestId, :final seq):
        _log.info('command $requestId accepted');
        _answer(CommandAnswer(requestId: requestId, seq: seq));
      case CommandRefused(:final requestId, :final reason):
        _log.warning('command $requestId refused $reason');
        _answer(CommandAnswer(requestId: requestId, refusal: reason));
      case Goodbye(:final reason):
        keep = false;
        switch (reason) {
          case GoodbyeReason.battleEnded ||
              GoodbyeReason.keyRevoked ||
              GoodbyeReason.unsupportedVersion:
            _stop(message);
          case GoodbyeReason.slowClient || GoodbyeReason.idle:
            break;
        }
    }
    _messages.add(message);
    return keep;
  }

  void _heard(Duration at) => _anchor = (at, _clock.now());

  void _answer(CommandAnswer answer) =>
      _pending.remove(answer.requestId)?.answer.complete(answer);

  void _send(ClientMessage message) =>
      _socket?.send(_codec.encodeClientMessage(message));

  void _setStatus(ClientStatus status) {
    if (_status == status) return;
    _status = status;
    _statuses.add(status);
  }

  void _stop(HostMessage? by, {HostLookupException? lookup}) {
    _log.info('stopped');
    _stoppedBy = by;
    _lookupRefused = lookup;
    _heartbeat?.cancel();
    _wait?.cancel();
    if (_waited case final waited? when !waited.isCompleted) waited.complete();
    _setStatus(ClientStatus.stopped);
    for (final pending in _pending.values) {
      pending.answer.completeError(
        ClientStoppedException(by, lookupRefused: lookup),
      );
    }
    _pending.clear();
    _stopped.complete();
    // After the message being handled, if any, has reached its listeners.
    scheduleMicrotask(() {
      unawaited(_messages.close());
      unawaited(_statuses.close());
    });
  }
}

final class _Pending {
  new(this.message);

  final SendCommand message;
  final answer = Completer<CommandAnswer>();
}
