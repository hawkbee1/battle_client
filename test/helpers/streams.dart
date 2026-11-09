import 'dart:io';
import 'dart:typed_data';

import 'package:battle_protocol/battle_protocol.dart';

const _codec = BinaryProtocolCodec();

/// The recorded streams of `battle_host`'s `tool/record_streams.dart`: what
/// the host sent each section over M5.15's scripted battle.
final List<String> recordedStreams = [
  for (final weather in ['clear', 'fog'])
    for (final section in ['s-1', 's-2'])
      for (final from in ['', '_late']) '${weather}_$section$from',
];

/// The host messages of the recorded stream [name].
List<HostMessage> readStream(String name) =>
    File('test/fixtures/streams/$name.hex')
        .readAsLinesSync()
        .where((line) => line.isNotEmpty)
        .map(decodeHex)
        .toList();

/// The host's whole view at the end of the recorded stream [name].
SectionView hostViewOf(String name) =>
    readStream('${name.replaceAll('_late', '')}_host').single as SectionView;

/// The host message of the hexadecimal [line].
HostMessage decodeHex(String line) => _codec.decodeHostMessage(
  Uint8List.fromList([
    for (var i = 0; i < line.length; i += 2)
      int.parse(line.substring(i, i + 2), radix: 16),
  ]),
);
