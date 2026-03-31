import 'dart:typed_data';

import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';

final class NonStreamingBridge {
  const NonStreamingBridge._();

  static Stream<TtsChunk> toChunkStream({
    required String requestId,
    required TtsAudioSpec audioSpec,
    required Uint8List audioBytes,
    int chunkSizeBytes = 4096,
    DateTime Function()? clock,
  }) async* {
    if (audioBytes.isEmpty) {
      yield TtsAudioChunk(
        requestId: requestId,
        sequenceNumber: 0,
        bytes: Uint8List(0),
        audioSpec: audioSpec,
        isLastChunk: true,
        timestamp: (clock ?? DateTime.now).call().toUtc(),
      );
      return;
    }

    var sequence = 0;
    for (var start = 0; start < audioBytes.length; start += chunkSizeBytes) {
      final end = (start + chunkSizeBytes > audioBytes.length)
          ? audioBytes.length
          : start + chunkSizeBytes;
      final bytes = Uint8List.sublistView(audioBytes, start, end);
      yield TtsAudioChunk(
        requestId: requestId,
        sequenceNumber: sequence,
        bytes: bytes,
        audioSpec: audioSpec,
        isLastChunk: end >= audioBytes.length,
        timestamp: (clock ?? DateTime.now).call().toUtc(),
      );
      sequence++;
    }
  }
}
