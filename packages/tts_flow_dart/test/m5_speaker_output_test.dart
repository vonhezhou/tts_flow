import 'dart:async';
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

      await output.startWrite(
        const TtsOutputWriteContext(
          requestKey: 'spk-1',
          audioSpec: _mp3Spec,
          voice: null,
          options: null,
        ),
      );
      await output.writeChunk(_chunk('spk-1', [1, 2], TtsAudioFormat.mp3));
      await output.writeChunk(_chunk('spk-1', [3], TtsAudioFormat.mp3));

      final artifact = await output.finishWrite();
      expect(artifact, isA<PlaybackAudioArtifact>());

      final speaker = artifact as PlaybackAudioArtifact;
      expect(speaker.requestKey, 'spk-1');
      expect(speaker.audioSpec.format, TtsAudioFormat.mp3);
      expect(speaker.playbackId, 'playback-spk-1');
      expect(backend.writtenBytes['playback-spk-1'], [1, 2, 3]);
      expect(
        backend.startedSpecs['playback-spk-1']?.format,
        TtsAudioFormat.mp3,
      );
    });

    test('cancelWrite stops active playback', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.startWrite(
        const TtsOutputWriteContext(
          requestKey: 'spk-2',
          audioSpec: _pcmSpec,
          voice: null,
          options: null,
        ),
      );
      await output.writeChunk(_chunk('spk-2', [9], TtsAudioFormat.pcm));
      final control = SynthesisControl()
        ..cancel(CancelReason.stopCurrent, message: 'manual-stop');
      await output.cancelWrite(control);

      expect(backend.stoppedPlaybackIds, contains('playback-spk-2'));
      expect(backend.stopReasons['playback-spk-2'], 'manual-stop');
    });

    test('session data is isolated per request', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.startWrite(
        const TtsOutputWriteContext(
          requestKey: 'spk-a',
          audioSpec: _mp3Spec,
          voice: null,
          options: null,
        ),
      );
      await output.writeChunk(_chunk('spk-a', [4], TtsAudioFormat.mp3));
      await output.finishWrite();

      await output.startWrite(
        const TtsOutputWriteContext(
          requestKey: 'spk-b',
          audioSpec: _pcmSpec,
          voice: null,
          options: null,
        ),
      );
      await output.writeChunk(_chunk('spk-b', [7, 8], TtsAudioFormat.pcm));
      await output.finishWrite();

      expect(backend.writtenBytes['playback-spk-a'], [4]);
      expect(backend.writtenBytes['playback-spk-b'], [7, 8]);
    });

    test('controls finalized playback until it is stopped', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend);

      await output.startWrite(
        const TtsOutputWriteContext(
          requestKey: 'spk-control',
          audioSpec: _mp3Spec,
          voice: null,
          options: null,
        ),
      );
      await output.finishWrite();

      expect(output.hasActivePlayback('spk-control'), isTrue);
      await output.pausePlayback('spk-control');
      await output.resumePlayback('spk-control');
      await output.stopPlayback('spk-control');

      expect(backend.pausedPlaybackIds, ['playback-spk-control']);
      expect(backend.resumedPlaybackIds, ['playback-spk-control']);
      expect(backend.stoppedPlaybackIds, ['playback-spk-control']);
      expect(output.hasActivePlayback('spk-control'), isFalse);

      await output.dispose();
    });

    test('MulticastOutput forwards physical playback controls', () async {
      final backend = _FakeSpeakerBackend();
      final output = MulticastOutput(
        outputs: [SpeakerOutput(backend: backend)],
      );

      await output.startWrite(
        const TtsOutputWriteContext(
          requestKey: 'spk-multicast-control',
          audioSpec: _mp3Spec,
          voice: null,
          options: null,
        ),
      );
      await output.finishWrite();

      expect(output.hasActivePlayback('spk-multicast-control'), isTrue);
      await output.pausePlayback('spk-multicast-control');
      await output.resumePlayback('spk-multicast-control');
      await output.stopPlayback('spk-multicast-control');

      expect(backend.pausedPlaybackIds, ['playback-spk-multicast-control']);
      expect(backend.resumedPlaybackIds, ['playback-spk-multicast-control']);
      expect(backend.stoppedPlaybackIds, ['playback-spk-multicast-control']);
      expect(output.hasActivePlayback('spk-multicast-control'), isFalse);

      await output.dispose();
    });

    test('forwards an optional backend playback failure', () async {
      final backend = _FakeSpeakerBackend();
      final output = SpeakerOutput(backend: backend, outputId: 'speaker');
      final events = <TtsOutputPlaybackFailedEvent>[];
      final sub = output.playbackFailedEvents.listen(events.add);
      addTearDown(sub.cancel);

      backend.playbackFailedController.add(
        const SpeakerPlaybackFailedEvent(
          requestKey: 'spk-failed',
          playbackId: 'playback-spk-failed',
          error: TtsError(
            code: TtsErrorCode.outputPlaybackFailed,
            message: 'decoder failed',
            requestKey: 'spk-failed',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.outputId, 'speaker');
      expect(events.single.playbackId, 'playback-spk-failed');
      expect(events.single.error.code, TtsErrorCode.outputPlaybackFailed);

      await output.dispose();
    });

    test('MulticastOutput forwards child playback failures', () async {
      final backend = _FakeSpeakerBackend();
      final speaker = SpeakerOutput(backend: backend, outputId: 'speaker');
      final output = MulticastOutput(outputs: [speaker]);
      final events = <TtsOutputPlaybackFailedEvent>[];
      final sub = output.playbackFailedEvents.listen(events.add);
      addTearDown(sub.cancel);

      backend.playbackFailedController.add(
        const SpeakerPlaybackFailedEvent(
          requestKey: 'multi-failed',
          playbackId: 'playback-multi-failed',
          error: TtsError(
            code: TtsErrorCode.outputPlaybackFailed,
            message: 'device failed',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.outputId, 'speaker');
      expect(events.single.playbackId, 'playback-multi-failed');

      await output.dispose();
    });

    test(
      'exposes an optional backend playback timeline without wrapping it',
      () async {
        final backend = _FakeSpeakerBackend();
        final output = SpeakerOutput(backend: backend);

        final reporter = output.timelineReporter;
        expect(reporter, same(backend));

        final events = <TtsPlaybackPositionEvent>[];
        final sub = reporter!.playbackPositionEvents.listen(events.add);
        addTearDown(sub.cancel);
        backend.playbackPositionController.add(
          const TtsPlaybackPositionEvent(
            requestKey: 'spk-timeline',
            playbackId: 'playback-spk-timeline',
            position: Duration(milliseconds: 420),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(1));
        expect(events.single.position, const Duration(milliseconds: 420));

        await output.dispose();
      },
    );
  });
}

TtsChunk _chunk(String requestKey, List<int> bytes, TtsAudioFormat format) {
  return TtsAudioChunk(
    requestKey: requestKey,
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

final class _FakeSpeakerBackend
    implements
        SpeakerBackend,
        SpeakerPlaybackFailureAwareBackend,
        PlaybackTimelineReporter {
  final Map<String, List<int>> writtenBytes = <String, List<int>>{};
  final List<String> stoppedPlaybackIds = <String>[];
  final List<String> pausedPlaybackIds = <String>[];
  final List<String> resumedPlaybackIds = <String>[];
  final Map<String, String?> stopReasons = <String, String?>{};
  final playbackFailedController =
      StreamController<SpeakerPlaybackFailedEvent>.broadcast();
  final playbackPositionController =
      StreamController<TtsPlaybackPositionEvent>.broadcast();

  @override
  Stream<SpeakerPlaybackCompletedEvent> get playbackCompletedEvents =>
      const Stream<SpeakerPlaybackCompletedEvent>.empty();

  @override
  Stream<SpeakerPlaybackFailedEvent> get playbackFailedEvents =>
      playbackFailedController.stream;

  @override
  Stream<TtsPlaybackPositionEvent> get playbackPositionEvents =>
      playbackPositionController.stream;

  @override
  Set<AudioCapability> get supportedCapabilities => {
    const Mp3Capability(),
    PcmCapability.wav(),
  };

  final Map<String, TtsAudioSpec> startedSpecs = <String, TtsAudioSpec>{};

  @override
  Future<void> init() async {}

  @override
  Future<String> startPlayback({
    required String requestKey,
    required TtsAudioSpec audioSpec,
  }) async {
    final playbackId = 'playback-$requestKey';
    writtenBytes[playbackId] = <int>[];
    startedSpecs[playbackId] = audioSpec;
    return playbackId;
  }

  @override
  Future<void> appendChunk({
    required String playbackId,
    required TtsChunk chunk,
  }) async {
    if (chunk is! TtsAudioChunk) {
      return;
    }

    writtenBytes.putIfAbsent(playbackId, () => <int>[]).addAll(chunk.bytes);
  }

  @override
  Future<void> finalizePlayback({required String playbackId}) async {}

  @override
  Future<void> stopPlayback({
    required String playbackId,
    String? reason,
  }) async {
    stoppedPlaybackIds.add(playbackId);
    stopReasons[playbackId] = reason;
  }

  @override
  Future<void> pausePlayback({required String playbackId}) async {
    pausedPlaybackIds.add(playbackId);
  }

  @override
  Future<void> resumePlayback({required String playbackId}) async {
    resumedPlaybackIds.add(playbackId);
  }

  @override
  Future<void> dispose() async {
    await playbackFailedController.close();
    await playbackPositionController.close();
  }
}
