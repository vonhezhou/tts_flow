import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/src/just_audio/chunk_audio_source.dart';

void main() {
  group('ChunkAudioSource', () {
    test('freezes its bytes once the platform requests the source', () async {
      var starts = 0;
      final source = ChunkAudioSource(
        audioSpec: const TtsAudioSpec.mp3(),
        playbackId: 'playback-1',
        requestId: 'request-1',
        index: 0,
        isTerminalSegment: false,
        onStarted: () => starts += 1,
      );

      expect(source.addChunk(Uint8List.fromList([1, 2, 3])), isTrue);

      final response = await source.request();
      final bytes = await response.stream.expand((chunk) => chunk).toList();

      expect(source.hasStarted, isTrue);
      expect(starts, 1);
      expect(source.addChunk(Uint8List.fromList([4, 5])), isFalse);
      expect(response.contentType, 'audio/mpeg');
      expect(response.contentLength, 3);
      expect(bytes, <int>[1, 2, 3]);

      await source.request();
      expect(starts, 1);

      final rangeResponse = await source.request(1, 3);
      final rangeBytes = await rangeResponse.stream
          .expand((chunk) => chunk)
          .toList();
      expect(rangeResponse.rangeRequestsSupported, isTrue);
      expect(rangeResponse.sourceLength, 3);
      expect(rangeResponse.contentLength, 2);
      expect(rangeResponse.offset, 1);
      expect(rangeBytes, <int>[2, 3]);
    });
  });
}
