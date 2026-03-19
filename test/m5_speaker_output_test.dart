import 'dart:typed_data';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';
import 'package:test/test.dart';

void main() {
  group('M5 speaker output', () {
    test('finalize returns playback artifact with metadata', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.initSession(
        const TtsOutputSession(
          requestId: 'spk-1',
          resolvedFormat: TtsAudioFormat.mp3,
        ),
      );
      await output.consumeChunk(_chunk('spk-1', [1, 2], TtsAudioFormat.mp3));
      await output.consumeChunk(_chunk('spk-1', [3], TtsAudioFormat.mp3));

      final artifact = await output.finalizeSession();
      expect(artifact, isA<SpeakerOutputArtifact>());

      final speaker = artifact as SpeakerOutputArtifact;
      expect(speaker.requestId, 'spk-1');
      expect(speaker.resolvedFormat, TtsAudioFormat.mp3);
      expect(speaker.playbackId, 'playback-spk-1');
      expect(speaker.playbackDuration, const Duration(milliseconds: 3));
      expect(backend.writtenBytes['playback-spk-1'], [1, 2, 3]);
    });

    test('onStop stops active playback', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.initSession(
        const TtsOutputSession(
          requestId: 'spk-2',
          resolvedFormat: TtsAudioFormat.wav,
        ),
      );
      await output.consumeChunk(_chunk('spk-2', [9], TtsAudioFormat.wav));
      await output.onStop('manual-stop');

      expect(backend.stoppedPlaybackIds, contains('playback-spk-2'));
      expect(backend.stopReasons['playback-spk-2'], 'manual-stop');
    });

    test('session data is isolated per request', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.initSession(
        const TtsOutputSession(
          requestId: 'spk-a',
          resolvedFormat: TtsAudioFormat.mp3,
        ),
      );
      await output.consumeChunk(_chunk('spk-a', [4], TtsAudioFormat.mp3));
      await output.finalizeSession();

      await output.initSession(
        const TtsOutputSession(
          requestId: 'spk-b',
          resolvedFormat: TtsAudioFormat.wav,
        ),
      );
      await output.consumeChunk(_chunk('spk-b', [7, 8], TtsAudioFormat.wav));
      await output.finalizeSession();

      expect(backend.writtenBytes['playback-spk-a'], [4]);
      expect(backend.writtenBytes['playback-spk-b'], [7, 8]);
    });
  });
}

TtsChunk _chunk(String requestId, List<int> bytes, TtsAudioFormat format) {
  return TtsChunk(
    requestId: requestId,
    sequenceNumber: 0,
    bytes: Uint8List.fromList(bytes),
    format: format,
    isLastChunk: false,
    timestamp: DateTime.now().toUtc(),
  );
}

final class _FakeSpeakerBackend implements SpeakerBackend {
  final Map<String, List<int>> writtenBytes = <String, List<int>>{};
  final List<String> stoppedPlaybackIds = <String>[];
  final Map<String, String?> stopReasons = <String, String?>{};

  @override
  Set<TtsAudioFormat> get supportedFormats => {
        TtsAudioFormat.mp3,
        TtsAudioFormat.wav,
      };

  @override
  Future<String> startPlayback({
    required String requestId,
    required TtsAudioFormat format,
  }) async {
    final playbackId = 'playback-$requestId';
    writtenBytes[playbackId] = <int>[];
    return playbackId;
  }

  @override
  Future<void> appendAudio({
    required String playbackId,
    required List<int> bytes,
  }) async {
    writtenBytes.putIfAbsent(playbackId, () => <int>[]).addAll(bytes);
  }

  @override
  Future<Duration> completePlayback({required String playbackId}) async {
    final length = writtenBytes[playbackId]?.length ?? 0;
    return Duration(milliseconds: length);
  }

  @override
  Future<void> stopPlayback(
      {required String playbackId, String? reason}) async {
    stoppedPlaybackIds.add(playbackId);
    stopReasons[playbackId] = reason;
  }

  @override
  Future<void> pausePlayback({required String playbackId}) async {}

  @override
  Future<void> resumePlayback({required String playbackId}) async {}

  @override
  Future<void> dispose() async {}
}
