import 'dart:typed_data';

/// How a client reaches a host (a port, stack decision 7): the WebSocket
/// adapter implements it, and tests feed the client recorded streams
/// through fakes.
abstract interface class Transport {
  /// Opens a socket to [uri]; throws when the host cannot be reached.
  Future<TransportSocket> connect(Uri uri);
}

/// One open socket to a host. The client speaks the binary encoding of
/// `battle_protocol`, one message per frame.
abstract interface class TransportSocket {
  /// The frames the host sends, in order. The stream ends when the socket
  /// closes, and ends with an error when it breaks.
  Stream<Uint8List> get frames;

  /// Sends [frame] to the host.
  void send(Uint8List frame);

  /// Closes the socket.
  Future<void> close();
}
