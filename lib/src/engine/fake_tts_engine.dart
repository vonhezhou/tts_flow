import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/tts_contracts.dart';
import '../core/tts_models.dart';

final class FakeTtsEngine implements TtsEngine {
  FakeTtsEngine({
    required this.engineId,
    required this.supportsStreaming,
    this.chunkCount = 1,
  }) : assert(chunkCount > 0);

  @override
  final String engineId;

  @override
  final bool supportsStreaming;

  @override
  bool get supportsPause => true;

  @override
  Set<TtsAudioFormat> get supportedFormats => {
        TtsAudioFormat.pcm16,
        TtsAudioFormat.wav,
        TtsAudioFormat.mp3,
      };

  final int chunkCount;

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    TtsControlToken controlToken,
    TtsAudioFormat resolvedFormat,
  ) async* {
    final payload = utf8.encode(request.text);
    final total = payload.length;
    final size = (total / chunkCount).ceil();

    for (var i = 0; i < chunkCount; i++) {
      if (controlToken.isStopped) {
        break;
      }
      while (controlToken.isPaused) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      final start = i * size;
      if (start >= total) {
        break;
      }
      final end = (start + size > total) ? total : start + size;
      final chunkBytes = Uint8List.fromList(payload.sublist(start, end));

      yield TtsChunk(
        requestId: request.requestId,
        sequenceNumber: i,
        bytes: chunkBytes,
        format: resolvedFormat,
        isLastChunk: end >= total,
        timestamp: DateTime.now().toUtc(),
      );
    }
  }

  @override
  Future<void> dispose() async {}
}
