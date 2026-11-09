import 'dart:typed_data';

import 'package:battle_client/src/ports/transport.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

/// {@template web_socket_transport}
/// The [Transport] on `web_socket_channel`: `dart:io` on native targets,
/// the browser's WebSocket through `package:web` on the web, under
/// JavaScript and Wasm alike (stack decision 3).
/// {@endtemplate}
final class WebSocketTransport implements Transport {
  /// {@macro web_socket_transport}
  const new();

  @override
  Future<TransportSocket> connect(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    return _ChannelSocket(channel);
  }
}

final class _ChannelSocket implements TransportSocket {
  new(this._channel);

  final WebSocketChannel _channel;
  var _closed = false;

  @override
  Stream<Uint8List> get frames => _channel.stream.map(
    (frame) => switch (frame) {
      final Uint8List bytes => bytes,
      _ => throw const ProtocolException('a text frame on a binary socket'),
    },
  );

  @override
  void send(Uint8List frame) {
    // A frame sent after the client closed the socket goes nowhere.
    if (!_closed) _channel.sink.add(frame);
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _channel.sink.close(status.normalClosure);
  }
}
