@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:battle_client/battle_client.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:test/test.dart';

/// The adapter against a WebSocket server on the loopback interface (M6
/// conventions).
void main() {
  group(WebSocketTransport, () {
    late HttpServer server;
    late StreamController<WebSocket> accepted;

    setUp(() async {
      accepted = StreamController();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.transform(WebSocketTransformer()).listen(accepted.add);
    });

    tearDown(() async {
      await server.close(force: true);
      unawaited(accepted.close());
    });

    Uri at() => Uri.parse('ws://127.0.0.1:${server.port}/v1/socket');

    test(
      'stack decision 3 carries binary frames both ways and closes',
      () async {
        final socket = await const WebSocketTransport().connect(at());
        final host = await accepted.stream.first;
        final received = StreamIterator(host);
        final frames = StreamIterator(socket.frames);

        socket.send(Uint8List.fromList([1, 2, 3]));
        expect(await received.moveNext(), isTrue);
        expect(received.current, equals([1, 2, 3]));

        host.add(Uint8List.fromList([4, 5]));
        expect(await frames.moveNext(), isTrue);
        expect(frames.current, equals([4, 5]));

        await socket.close();
        socket.send(Uint8List.fromList([6]));
        expect(await received.moveNext(), isFalse);
        expect(host.closeCode, equals(1000));
      },
    );

    test('a text frame is an error on the stream', () async {
      final socket = await const WebSocketTransport().connect(at());
      final host = await accepted.stream.first;

      host.add('{"v": 1}');

      await expectLater(socket.frames, emitsError(isA<ProtocolException>()));
      await host.close();
    });

    test('a host that cannot be reached is an error', () async {
      final port = server.port;
      await server.close(force: true);

      await expectLater(
        const WebSocketTransport().connect(
          Uri.parse('ws://127.0.0.1:$port/v1/socket'),
        ),
        throwsA(anything),
      );
    });
  });
}
