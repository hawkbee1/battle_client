import 'dart:convert';

import 'package:battle_client/src/credential.dart';
import 'package:battle_protocol/battle_protocol.dart';
import 'package:hawkbee_schema/hawkbee_schema.dart';
import 'package:http/http.dart' as http;

/// {@template host_lookup_exception}
/// Why a client got no address for its battle's host (M6 Issue 6): the
/// [code] Appwrite or the `bt_battle_host` function answered, with its
/// HTTP [status].
/// {@endtemplate}
final class HostLookupException implements Exception {
  /// {@macro host_lookup_exception}
  const new(this.code, {required this.status});

  /// Why, as a code: `not_your_battle`, `no_host`, …
  final String code;

  /// The HTTP status.
  final int status;

  /// Whether asking again cannot help: a credential refused, an account
  /// with no section in the battle, a battle unknown, planned or over.
  /// `no_host` (503, no host runs it right now) and a server that failed
  /// (5xx) are asked again.
  bool get lasting => status < 500;

  @override
  String toString() => 'HostLookupException($status $code)';
}

/// The socket of the host at the public [address] (`bt_hosts`): `wss://`
/// for `https://`, `ws://` for `http://`, at `/v1/socket` (stack
/// decision 3).
///
/// Throws a [FormatException] for an address that is neither.
Uri socketAddress(String address) {
  final uri = Uri.parse(address);
  final scheme = switch (uri.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    _ => throw FormatException('not an http or https address', address),
  };
  final base = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;
  return uri.replace(scheme: scheme, path: '$base/v1/socket');
}

/// {@template appwrite_host_finder}
/// Where a battle's host is, asked of the `bt_battle_host` function of the
/// Appwrite project [project] at [endpoint] (Adapter, M6 Issue 6): a
/// player's JWT goes as Appwrite's JWT header, an agent's API key in the
/// body, which Appwrite does not keep with the execution.
///
/// Pure Dart over `package:http`, so it runs on every target, the web
/// included, beside `WebSocketTransport`.
/// {@endtemplate}
final class AppwriteHostFinder {
  /// {@macro appwrite_host_finder}
  new({required this.endpoint, required this.project, http.Client? client})
    : _client = client ?? http.Client();

  /// The Appwrite API, `…/v1`.
  final Uri endpoint;

  /// The Appwrite project.
  final String project;

  final http.Client _client;

  /// The socket of the host that runs [battleId], for [credential].
  ///
  /// Throws a [HostLookupException] when Appwrite or the function answers
  /// with no address, and a [FormatException] for an answer it does not
  /// read.
  Future<Uri> socketOf(String battleId, Credential credential) async {
    final base = endpoint.toString();
    final response = await _client.post(
      Uri.parse(
        '${base.endsWith('/') ? base : '$base/'}functions/'
        '${AppwriteIds.battleHostFunctionId}/executions',
      ),
      headers: {
        'content-type': 'application/json',
        'x-appwrite-project': project,
        if (credential.kind == CredentialKind.jwt)
          'x-appwrite-jwt': credential.secret,
      },
      body: jsonEncode({
        'body': jsonEncode({
          'battle': battleId,
          if (credential.kind == CredentialKind.apiKey)
            'key': credential.secret,
        }),
        'async': false,
      }),
    );
    final answer = _object(response.body);
    if (response.statusCode >= 300) {
      throw HostLookupException(
        answer['type'] as String? ?? 'appwrite_error',
        status: response.statusCode,
      );
    }
    final status = answer['responseStatusCode'];
    final body = _object(answer['responseBody'] as String? ?? '');
    if (status != 200) {
      throw HostLookupException(
        body['error'] as String? ?? 'function_failed',
        status: status is int ? status : 500,
      );
    }
    return switch (body['address']) {
      final String address => socketAddress(address),
      _ => throw FormatException('no address', answer['responseBody']),
    };
  }

  /// Closes its HTTP client.
  void close() => _client.close();

  static Map<String, Object?> _object(String text) {
    try {
      return switch (jsonDecode(text)) {
        final Map<String, Object?> object => object,
        _ => const {},
      };
    } on FormatException {
      return const {};
    }
  }
}
