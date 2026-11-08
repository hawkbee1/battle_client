/// The client side of a Battle Team connection (M6 Issue 7), for the app
/// and AI agents written in Dart: sign-in, commands answered by their
/// request ID, the section's view kept up to date, and reconnection.
///
/// Pure Dart; runs on every target, the web included. The transport is a
/// port: `WebSocketTransport` is its adapter, and tests feed recorded
/// streams through fakes.
library;

export 'src/adapters/system_clock.dart';
export 'src/adapters/web_socket_transport.dart';
export 'src/agent/nearest_enemy.dart';
export 'src/backoff.dart';
export 'src/battle_client.dart';
export 'src/credential.dart';
export 'src/held_view.dart';
export 'src/ports/clock.dart';
export 'src/ports/transport.dart';
export 'src/request_ids.dart';
