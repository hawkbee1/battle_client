import 'package:battle_protocol/battle_protocol.dart';

/// {@template credential}
/// What a client signs in with (stack decision 6): a player's short-lived
/// Appwrite JWT, or an AI agent's API key (AI-04). Its [toString] hides
/// the secret.
/// {@endtemplate}
final class Credential {
  /// A player's Appwrite JWT, valid 15 minutes: a client asks for a fresh
  /// one each time it signs in.
  const new jwt(this.secret) : kind = CredentialKind.jwt;

  /// An AI agent's API key.
  const new apiKey(this.secret) : kind = CredentialKind.apiKey;

  /// Which kind it is.
  final CredentialKind kind;

  /// The JWT or the key.
  final String secret;

  @override
  String toString() => 'Credential(${kind.name})';
}
