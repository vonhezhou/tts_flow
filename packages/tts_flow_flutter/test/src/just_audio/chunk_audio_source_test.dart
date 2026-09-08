import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/src/just_audio/chunk_audio_source.dart';

void main() {
  group('ChunkAudioSource', () {
    test('freezes its bytes once the platform requests the source', () async {
      final source = ChunkAudioSource(
        audioSpec: const TtsAudioSpec.mp3(),
        playbackId: 'playback-1',
        requestId: 'request-1',
        index: 0,
        isTerminalSegment: false,
      );

      expect(source.addChunk(Uint8List.fromList([1, 2, 3])), isTrue);

      final response = await source.request();
      final bytes = await response.stream.expand((chunk) => chunk).toList();

      expect(source.hasStarted, isTrue);
      expect(source.addChunk(Uint8List.fromList([4, 5])), isFalse);
      expect(response.contentType, 'audio/mpeg');
      expect(response.contentLength, 3);
      expect(bytes, <int>[1, 2, 3]);
    });
  });
}
