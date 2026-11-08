import 'dart:convert';

import 'package:battle_client/battle_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// An execution of `bt_battle_host` that answered [status] with [body].
String _execution(int? status, String body) =>
    jsonEncode({'responseStatusCode': ?status, 'responseBody': body});

void main() {
  group(AppwriteHostFinder, () {
    late List<http.Request> requests;

    AppwriteHostFinder finder(
      int status,
      String body, {
      String endpoint = 'http://appwrite-traefik/v1',
    }) => AppwriteHostFinder(
      endpoint: Uri.parse(endpoint),
      project: 'hawkbee',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(body, status);
      }),
    );

    setUp(() => requests = []);

    test('M6 Issue 6 a player asks with their JWT and gets the socket of '
        "the battle's host", () async {
      final socket = await finder(
        201,
        _execution(200, '{"address": "https://h1.example"}'),
      ).socketOf('b-1', const Credential.jwt('jwt-1'));

      expect(socket, equals(Uri.parse('wss://h1.example/v1/socket')));
      final request = requests.single;
      expect(request.method, equals('POST'));
      expect(
        request.url,
        equals(
          Uri.parse(
            'http://appwrite-traefik/v1/functions/bt_battle_host/executions',
          ),
        ),
      );
      expect(request.headers['x-appwrite-project'], equals('hawkbee'));
      expect(request.headers['x-appwrite-jwt'], equals('jwt-1'));
      expect(jsonDecode(request.body), {
        'body': '{"battle":"b-1"}',
        'async': false,
      });
    });

    test('AI-04 an agent sends its key in the body, not in a header', () async {
      final socket = await finder(
        201,
        _execution(200, '{"address": "http://host-saint-lo:8080"}'),
        endpoint: 'http://localhost/v1/',
      ).socketOf('b-1', const Credential.apiKey('btk_k'));

      expect(socket, equals(Uri.parse('ws://host-saint-lo:8080/v1/socket')));
      final request = requests.single;
      expect(
        request.url.path,
        equals('/v1/functions/bt_battle_host/executions'),
      );
      expect(request.headers.containsKey('x-appwrite-jwt'), isFalse);
      expect(
        jsonDecode(
          (jsonDecode(request.body) as Map<String, Object?>)['body']! as String,
        ),
        {'battle': 'b-1', 'key': 'btk_k'},
      );
    });

    test('M6 Issue 6 a refusal of the function is lasting, but no host '
        'running the battle yet', () async {
      Future<HostLookupException> refusal(int status, String body) async {
        try {
          await finder(
            201,
            _execution(status, body),
          ).socketOf('b-1', const Credential.jwt('j'));
        } on HostLookupException catch (refused) {
          return refused;
        }
        fail('no refusal');
      }

      final mine = await refusal(403, '{"error": "not_your_battle"}');
      expect(
        (mine.code, mine.status, mine.lasting),
        ('not_your_battle', 403, true),
      );
      final none = await refusal(503, '{"error": "no_host"}');
      expect((none.code, none.lasting), ('no_host', false));
      final failed = await refusal(500, '');
      expect((failed.code, failed.lasting), ('function_failed', false));
      expect('$failed', equals('HostLookupException(500 function_failed)'));
    });

    test("a refusal of Appwrite's, and an execution with no status", () async {
      await expectLater(
        finder(
          401,
          '{"type": "user_jwt_invalid"}',
        ).socketOf('b-1', const Credential.jwt('old')),
        throwsA(
          isA<HostLookupException>()
              .having((e) => e.code, 'code', 'user_jwt_invalid')
              .having((e) => e.lasting, 'lasting', isTrue),
        ),
      );
      await expectLater(
        finder(502, 'Bad Gateway').socketOf('b-1', const Credential.jwt('j')),
        throwsA(
          isA<HostLookupException>()
              .having((e) => e.code, 'code', 'appwrite_error')
              .having((e) => e.lasting, 'lasting', isFalse),
        ),
      );
      await expectLater(
        finder(
          201,
          jsonEncode({'status': 'failed'}),
        ).socketOf('b-1', const Credential.jwt('j')),
        throwsA(
          isA<HostLookupException>().having((e) => e.status, 'status', 500),
        ),
      );
    });

    test('an answer with no address is not read', () async {
      for (final body in ['{}', '[1]', '{"address": 3}']) {
        await expectLater(
          finder(
            201,
            _execution(200, body),
          ).socketOf('b-1', const Credential.jwt('j')),
          throwsFormatException,
        );
      }
    });

    test('closes its HTTP client', () {
      var closed = false;
      final mock = _Closing(() => closed = true);
      AppwriteHostFinder(
        endpoint: Uri.parse('http://a/v1'),
        project: 'p',
        client: mock,
      ).close();
      AppwriteHostFinder(
        endpoint: Uri.parse('http://a/v1'),
        project: 'p',
      ).close();

      expect(closed, isTrue);
    });
  });

  group('socketAddress', () {
    test('stack decision 3 the socket of a public address', () {
      expect(
        socketAddress('https://h1.example'),
        equals(Uri.parse('wss://h1.example/v1/socket')),
      );
      expect(
        socketAddress('https://proxy.example/hosts/h1/'),
        equals(Uri.parse('wss://proxy.example/hosts/h1/v1/socket')),
      );
      expect(
        socketAddress('http://127.0.0.1:8081'),
        equals(Uri.parse('ws://127.0.0.1:8081/v1/socket')),
      );
      expect(() => socketAddress('ws://h1'), throwsFormatException);
    });
  });
}

final class _Closing extends http.BaseClient {
  new(this._onClose);

  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() => _onClose();
}
