# battle_client

[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: MIT][license_badge]][license_link]

The **client side of a connection to a Battle Team host**: Battle Team is a 3D, massive, persistent, real-time team battle game. This package is shared by the app (M7) and by AI agents written in Dart, and runs on every target, the web included (JavaScript and Wasm). It follows stack decisions 3 (networking), 7 (ports and adapters) and 8 (what the client computes) of the plan.

- **`BattleClient`**: opens a socket to the battle's host, signs in with an Appwrite JWT or an API key, and sends commands. Each command gets its answer by its request ID. When it loses the host, it waits with a backoff, asks again where the battle runs (it may have moved to another host), signs in again, takes its whole view, and resends the commands that got no answer. The host carries each of them out once.
- **`AppwriteHostFinder`**: where a battle's host is, from its ID alone: it asks the `bt_battle_host` Appwrite function with the client's JWT or API key, over `package:http`, and gives the host's socket.
- **`HeldView`**: the section's view, built from the whole view, then each tick's update. It holds the units the section knows, the HQs it sees, the relics, the victory countdown, its private state and the delta layer. `apAt` and `BattleClient.apNow` compute the AP shown between updates.
- **Ports and adapters**: `Transport` (the socket) with `WebSocketTransport` on `web_socket_channel`, and `Clock` with `SystemClock`. Tests feed recorded streams of the host through fakes.
- **`NearestEnemyAgent`**: an example AI agent. Each unit of its section fires at the nearest enemy the section sees. Run it with:

  ```sh
  BT_API_KEY=btk_... dart run battle_client:nearest_enemy_agent \
    --appwrite http://localhost/v1 --battle <battle ID>
  ```

The client checks nothing: the host checks every order. The order pre-check with `battle_rules` comes in M7.

## Part of hawkbee

This package lives in its own repository but builds only inside the hawkbee workspace (`resolution: workspace`, sibling packages such as `battle_protocol`):

```sh
git clone --recurse-submodules https://github.com/hawkbee1/hawkbee.git
```

The recorded streams in `test/fixtures/streams/` come from `battle_host`'s `tool/record_streams.dart`.

[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
