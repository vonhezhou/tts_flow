import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

const _pcmDescriptor = PcmDescriptor(
  sampleRateHz: 24000,
  bitsPerSample: 16,
  channels: 1,
);

const _pcmSpec = TtsAudioSpec.pcm(_pcmDescriptor);
const _mp3Spec = TtsAudioSpec.mp3();

void main() {
  group('M5 speaker output', () {
    test('finalize returns playback artifact with metadata', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.initSession(
        const TtsOutputSession(
          requestId: 'spk-1',
          audioSpec: _mp3Spec,
          voice: null,
          options: null,
        ),
      );
      await output.consumeChunk(_chunk('spk-1', [1, 2], TtsAudioFormat.mp3));
      await output.consumeChunk(_chunk('spk-1', [3], TtsAudioFormat.mp3));

      final artifact = await output.finalizeSession();
      expect(artifact, isA<PlaybackAudioArtifact>());

      final speaker = artifact as PlaybackAudioArtifact;
      expect(speaker.requestId, 'spk-1');
      expect(speaker.audioSpec.format, TtsAudioFormat.mp3);
      expect(speaker.playbackId, 'playback-spk-1');
      expect(speaker.playbackDuration, const Duration(milliseconds: 3));
      expect(backend.writtenBytes['playback-spk-1'], [1, 2, 3]);
      expect(
        backend.startedSpecs['playback-spk-1']?.format,
        TtsAudioFormat.mp3,
      );
    });

    test('onCancelSession stops active playback', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.initSession(
        const TtsOutputSession(
          requestId: 'spk-2',
          audioSpec: _pcmSpec,
          voice: null,
          options: null,
        ),
      );
      await output.consumeChunk(_chunk('spk-2', [9], TtsAudioFormat.pcm));
      final control = SynthesisControl()
        ..cancel(CancelReason.stopCurrent, message: 'manual-stop');
      await output.onCancelSession(control);

      expect(backend.stoppedPlaybackIds, contains('playback-spk-2'));
      expect(backend.stopReasons['playback-spk-2'], 'manual-stop');
    });

    test('session data is isolated per request', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.initSession(
        const TtsOutputSession(
          requestId: 'spk-a',
          audioSpec: _mp3Spec,
          voice: null,
          options: null,
        ),
      );
      await output.consumeChunk(_chunk('spk-a', [4], TtsAudioFormat.mp3));
      await output.finalizeSession();

      await output.initSession(
        const TtsOutputSession(
          requestId: 'spk-b',
          audioSpec: _pcmSpec,
          voice: null,
          options: null,
        ),
      );
      await output.consumeChunk(_chunk('spk-b', [7, 8], TtsAudioFormat.pcm));
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
    audioSpec: _audioSpecForFormat(format),
    isLastChunk: false,
    timestamp: DateTime.now().toUtc(),
  );
}

TtsAudioSpec _audioSpecForFormat(TtsAudioFormat format) {
  switch (format) {
    case TtsAudioFormat.pcm:
      return _pcmSpec;
    case TtsAudioFormat.mp3:
      return _mp3Spec;
    case TtsAudioFormat.opus:
      return const TtsAudioSpec.opus();
    case TtsAudioFormat.aac:
      return const TtsAudioSpec.aac();
  }
}

final class _FakeSpeakerBackend implements SpeakerBackend {
  final Map<String, List<int>> writtenBytes = <String, List<int>>{};
  final List<String> stoppedPlaybackIds = <String>[];
  final Map<String, String?> stopReasons = <String, String?>{};

  @override
  Set<AudioCapability> get supportedCapabilities => {
        const Mp3Capability(),
        PcmCapability.wav(),
      };

  final Map<String, TtsAudioSpec> startedSpecs = <String, TtsAudioSpec>{};

  @override
  Future<String> startPlayback({
    required String requestId,
    required TtsAudioSpec audioSpec,
  }) async {
    final playbackId = 'playback-$requestId';
    writtenBytes[playbackId] = <int>[];
    startedSpecs[playbackId] = audioSpec;
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
