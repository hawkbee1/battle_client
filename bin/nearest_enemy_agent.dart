// The example AI agent of M6 Issue 7: it signs in to a battle with an API
// key and fires each of its units at the nearest enemy it sees. It finds
// the battle's host through Appwrite (M6 Issue 6), or uses --host.
//
//   BT_API_KEY=btk_... dart run battle_client:nearest_enemy_agent \
//     --appwrite http://localhost/v1 --battle <battle ID>
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:battle_client/battle_client.dart';
import 'package:battle_protocol/battle_protocol.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'appwrite',
      defaultsTo: 'http://localhost/v1',
      help: 'The Appwrite API that knows where the battle runs.',
    )
    ..addOption('project', defaultsTo: 'hawkbee', help: 'Its project.')
    ..addOption('host', help: "The host's socket, ws:// or wss://, if known.")
    ..addOption('battle', help: 'The battle ID.');
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    print('${error.message}\n${parser.usage}');
    exit(64);
  }
  final host = options.option('host');
  final battle = options.option('battle');
  final key = Platform.environment['BT_API_KEY'];
  if (battle == null || key == null) {
    print('Set BT_API_KEY and --battle.\n${parser.usage}');
    exit(64);
  }
  final finder = AppwriteHostFinder(
    endpoint: Uri.parse(options.option('appwrite')!),
    project: options.option('project')!,
  );

  final client = BattleClient(
    battleId: battle,
    transport: const WebSocketTransport(),
    address: (credential) async => host == null
        ? await finder.socketOf(battle, credential)
        : Uri.parse(host),
    credential: () async => Credential.apiKey(key),
    clock: const SystemClock(),
    random: Random.secure(),
  );
  final agent = NearestEnemyAgent(client);
  client.statuses.listen((status) => print('status: ${status.name}'));
  client.messages.listen((message) {
    switch (message) {
      case SignInAccepted(:final sectionId, :final team):
        print('signed in as $sectionId of $team');
      case CommandAccepted(:final requestId, :final seq):
        print('order $requestId accepted, #$seq');
      case CommandRefused(:final requestId, :final reason):
        print('order $requestId refused: $reason');
      case _:
        break;
    }
  });
  agent.start();
  ProcessSignal.sigint.watch().first.then((_) => client.close()).ignore();
  client.start();
  await client.stopped;
  finder.close();
  print('stopped: ${client.stoppedBy ?? client.lookupRefused ?? 'closed'}');
}
