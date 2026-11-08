import 'dart:async';
import 'dart:typed_data';

import 'package:battle_client/battle_client.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:fake_async/fake_async.dart';

const _codec = BinaryProtocolCodec();

/// The wall time the tests start at.
final testStart = DateTime.utc(2026, 11, 8, 9);

/// A clock on fake time: [testStart] plus the time elapsed.
final class FakeClock implements Clock {
  /// A clock on [async].
  new(this.async);

  /// The fake time.
  final FakeAsync async;

  @override
  DateTime now() => testStart.add(async.elapsed);
}

/// A clock that moves only when told.
final class ManualClock implements Clock {
  /// A clock at [now].
  new(this.time);

  /// The time.
  DateTime time;

  @override
  DateTime now() => time;
}

/// A host in memory: each connection is a [FakeSocket] the test speaks
/// through.
final class FakeTransport implements Transport {
  /// The sockets opened, in order.
  final sockets = <FakeSocket>[];

  /// The addresses connected to, in order.
  final uris = <Uri>[];

  /// How many connections fail before one opens.
  int failures = 0;

  /// Holds the next connections until it completes.
  Completer<void>? held;

  /// The last socket.
  FakeSocket get last => sockets.last;

  @override
  Future<TransportSocket> connect(Uri uri) async {
    uris.add(uri);
    if (held case final hold?) await hold.future;
    if (failures > 0) {
      failures--;
      throw StateError('connection refused');
    }
    final socket = FakeSocket();
    sockets.add(socket);
    return socket;
  }
}

/// One socket of a [FakeTransport].
final class FakeSocket implements TransportSocket {
  final _frames = StreamController<Uint8List>();

  /// What the client sent, decoded.
  final sent = <ClientMessage>[];

  /// Whether the client closed it.
  bool closed = false;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  void send(Uint8List frame) => sent.add(_codec.decodeClientMessage(frame));

  @override
  Future<void> close() async {
    closed = true;
    if (!_frames.isClosed) unawaited(_frames.close());
  }

  /// The host sends [message].
  void deliver(HostMessage message) =>
      _frames.add(_codec.encodeHostMessage(message));

  /// The host sends [bytes].
  void deliverBytes(List<int> bytes) => _frames.add(Uint8List.fromList(bytes));

  /// The socket breaks with [error].
  void fail(Object error) => _frames.addError(error);

  /// The host closes the socket.
  void drop() {
    if (!_frames.isClosed) unawaited(_frames.close());
  }

  /// The commands the client sent.
  List<SendCommand> get commands => sent.whereType<SendCommand>().toList();
}
