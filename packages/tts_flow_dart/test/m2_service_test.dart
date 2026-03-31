import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('M2 service', () {
    test('processes requests in FIFO order', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        defaultOutput: NullOutput(),
      );

      final started = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestStarted) {
          started.add(event.requestId);
        }
      });

      await service.init();

      final streamA = service.speak('a', 'first request payload');
      final streamB = service.speak('b', 'second request payload');

      await streamA.toList();
      await streamB.toList();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(started, ['a', 'b']);
      await sub.cancel();
      await service.dispose();
    });

    test('clearQueue cancels pending requests only', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 3,
          chunkDelay: const Duration(milliseconds: 10),
        ),
        defaultOutput: NullOutput(),
      );

      await service.init();

      final active = service.speak('active', 'active request');
      final pending = service.speak('pending', 'pending request');

      await Future<void>.delayed(const Duration(milliseconds: 8));
      final clearedCount = await service.clearQueue();

      expect(clearedCount, 1);
      expect(await active.toList(), isNotEmpty);
      expect(await pending.toList(), isEmpty);

      await service.dispose();
    });

    test(
      'stopCurrent stops active request and next request proceeds',
      () async {
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 8,
            chunkDelay: const Duration(milliseconds: 5),
          ),
          defaultOutput: NullOutput(),
        );

        final events = <TtsRequestEvent>[];
        final sub = service.requestEvents.listen(events.add);

        await service.init();

        final longStream = service.speak(
          'long',
          'this is a long request payload',
        );
        final nextStream = service.speak('next', 'next request');

        await Future<void>.delayed(const Duration(milliseconds: 12));
        await service.stopCurrent();

        await longStream.toList();
        await nextStream.toList();

        expect(
          events.any(
            (event) =>
                event.requestId == 'long' &&
                event.type == TtsRequestEventType.requestStopped,
          ),
          isTrue,
        );

        final nextStartedIndex = events.indexWhere(
          (event) =>
              event.requestId == 'next' &&
              event.type == TtsRequestEventType.requestStarted,
        );
        expect(nextStartedIndex, isNonNegative);

        await sub.cancel();
        await service.dispose();
      },
    );

    test('requestFailed event includes output failure details', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 2),
        ),
        defaultOutput: MulticastOutput(
          outputs: [
            MemoryOutput(outputId: 'memory'),
            _AlwaysFailOutput(outputId: 'fail-output'),
          ],
          errorPolicy: MulticastOutputErrorPolicy.failFast,
        ),
      );

      TtsRequestEvent? failedEvent;
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestFailed) {
          failedEvent = event;
        }
      });

      await service.init();

      final stream = service.speak('output-fail', 'fail through output');

      await expectLater(stream.toList(), throwsA(isA<TtsError>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(failedEvent, isNotNull);
      expect(failedEvent!.outputId, 'fail-output');
      expect(failedEvent!.outputError, isNotNull);
      expect(failedEvent!.outputError!.code, TtsErrorCode.outputWriteFailed);

      await sub.cancel();
      await service.dispose();
    });

    test('initializes output session using first chunk audioSpec', () async {
      final output = _TrackingOutput(outputId: 'tracking-output');
      final service = TtsFlow(
        engine: _ChunkSpecEngine(
          negotiatedCapabilities: {PcmCapability.wav(), const Mp3Capability()},
          emittedSpec: const TtsAudioSpec.mp3(),
        ),
        defaultOutput: output,
      );

      await service.init();
      service.preferredFormat = TtsAudioFormat.pcm;

      final chunks = await service.speak('chunk-spec-init', 'hello').toList();

      expect(chunks, hasLength(1));
      expect(chunks.single, isA<TtsAudioChunk>());
      expect(
        (chunks.single as TtsAudioChunk).audioSpec.format,
        TtsAudioFormat.mp3,
      );
      expect(output.lastInitAudioSpec, isNotNull);
      expect(output.lastInitAudioSpec!.format, TtsAudioFormat.mp3);

      await service.dispose();
    });

    test(
      'fails during negotiation when multicast children have disjoint PCM',
      () async {
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 2,
            chunkDelay: const Duration(milliseconds: 2),
          ),
          defaultOutput: MulticastOutput(
            outputs: [
              _PcmOnlyOutput(outputId: 'pcm-16k', sampleRatesHz: {16000}),
              _PcmOnlyOutput(outputId: 'pcm-24k', sampleRatesHz: {24000}),
            ],
            errorPolicy: MulticastOutputErrorPolicy.failFast,
          ),
        );

        await service.init();

        final stream = service.speak('pcm-disjoint', 'disjoint constraints');

        await expectLater(
          stream.toList(),
          throwsA(
            isA<TtsError>().having(
              (error) => error.code,
              'code',
              TtsErrorCode.formatNegotiationFailed,
            ),
          ),
        );

        await service.dispose();
      },
    );

    test('continueOnError keeps pending queue after active failure', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 2),
        ),
        defaultOutput: _FailByRequestIdOutput(
          outputId: 'selective-fail',
          failingRequestIds: {'first'},
        ),
        config: const TtsFlowConfig(
          queueFailurePolicy: TtsQueueFailurePolicy.continueOnError,
        ),
      );

      final events = <TtsRequestEvent>[];
      final sub = service.requestEvents.listen(events.add);

      await service.init();

      final first = service.speak('first', 'this will fail');
      final second = service.speak('second', 'this should still run');

      await expectLater(first.toList(), throwsA(isA<TtsError>()));
      final secondChunks = await second.toList();

      expect(secondChunks, isNotEmpty);
      expect(
        events.any(
          (event) =>
              event.requestId == 'second' &&
              event.type == TtsRequestEventType.requestCompleted,
        ),
        isTrue,
      );

      await sub.cancel();
      await service.dispose();
    });

    test('pause while idle defers start until resume', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        defaultOutput: NullOutput(),
      );

      final started = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestStarted) {
          started.add(event.requestId);
        }
      });

      await service.init();

      await service.pause();
      expect(service.isPaused, isTrue);

      final first = service.speak('paused-1', 'first queued');
      final second = service.speak('paused-2', 'second queued');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(started, isEmpty);

      await service.resume();
      expect(service.isPaused, isFalse);

      await first.toList();
      await second.toList();

      expect(started, ['paused-1', 'paused-2']);

      await sub.cancel();
      await service.dispose();
    });

    test('stopCurrent forwards stopCurrent cancel reason to output', () async {
      final output = _CaptureCancelOutput();
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 8,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        defaultOutput: output,
      );

      await service.init();

      final longStream = service.speak('cancel-reason', 'long request');

      await Future<void>.delayed(const Duration(milliseconds: 12));
      await service.stopCurrent();
      await longStream.toList();

      expect(output.lastCancelReason, CancelReason.stopCurrent);
      await service.dispose();
    });

    test(
      'dispose during paused active request forwards serviceDispose reason',
      () async {
        final output = _CaptureCancelOutput();
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 20,
            chunkDelay: const Duration(milliseconds: 5),
          ),
          defaultOutput: output,
        );

        await service.init();

        final stream = service.speak(
          'dispose-paused',
          'this request should be canceled by service dispose while paused',
        );

        await Future<void>.delayed(const Duration(milliseconds: 12));
        await service.pause();
        await Future<void>.delayed(const Duration(milliseconds: 12));
        await service.dispose();

        final chunks = await stream.toList();
        expect(chunks, isNotNull);
        expect(output.lastCancelReason, CancelReason.serviceDispose);
      },
    );

    test('service exposes engine available voices and defaults', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(engineId: 'fake-engine', supportsStreaming: true),
        defaultOutput: NullOutput(),
      );

      await service.init();

      final voices = await service.getAvailableVoices();
      final defaultVoice = await service.getDefaultVoice();
      final localeDefault = await service.getDefaultVoiceForLocale('en-US');

      expect(voices, isNotEmpty);
      expect(defaultVoice.voiceId, isNotEmpty);
      expect(localeDefault.voiceId, isNotEmpty);
      expect(service.voice, isNotNull);

      service.speed = 1.1;
      service.pitch = 0.9;
      service.volume = 0.8;
      service.sampleRateHz = 24000;
      service.timeout = const Duration(seconds: 10);
      service.preferredFormat = TtsAudioFormat.pcm;
      expect(service.speed, 1.1);
      expect(service.pitch, 0.9);
      expect(service.volume, 0.8);
      expect(service.sampleRateHz, 24000);
      expect(service.timeout, const Duration(seconds: 10));

      final streamedChunks = await service
          .speak(
            'defaults-applied',
            'request uses service defaults',
            params: const {'style': 'news', 'emotion': 'calm'},
          )
          .toList();
      expect(streamedChunks, isNotEmpty);

      await service.dispose();
    });

    test('speak requires init before usage', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(engineId: 'fake-engine', supportsStreaming: true),
        defaultOutput: NullOutput(),
      );

      expect(
        () => service.speak('not-ready', 'call before init'),
        throwsStateError,
      );

      await service.dispose();
    });

    test(
      'requestCompleted is ingestion-based and playback completion is separate',
      () async {
        final output = _PlaybackAwareTestOutput(
          outputId: 'playback-aware',
          playbackCompletionDelay: const Duration(milliseconds: 30),
        );
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 2,
            chunkDelay: const Duration(milliseconds: 2),
          ),
          defaultOutput: output,
        );

        final events = <TtsRequestEvent>[];
        final sub = service.requestEvents.listen(events.add);

        await service.init();
        await service.speak('playback-split', 'hello').toList();

        await Future<void>.delayed(const Duration(milliseconds: 60));

        final completedIndex = events.indexWhere(
          (event) =>
              event.requestId == 'playback-split' &&
              event.type == TtsRequestEventType.requestCompleted,
        );
        final playbackCompletedIndex = events.indexWhere(
          (event) =>
              event.requestId == 'playback-split' &&
              event.type == TtsRequestEventType.requestPlaybackCompleted,
        );

        expect(completedIndex, isNonNegative);
        expect(playbackCompletedIndex, greaterThan(completedIndex));

        final playbackEvent =
            events[playbackCompletedIndex.clamp(0, events.length - 1)];
        expect(playbackEvent.outputId, 'playback-aware');
        expect(playbackEvent.playbackId, 'playback-playback-split');
        expect(playbackEvent.playedDuration, isNotNull);
        expect(playbackEvent.playedDuration!, greaterThan(Duration.zero));

        await sub.cancel();
        await service.dispose();
      },
    );

    test(
      'speak with output override routes audio only to override output',
      () async {
        final defaultOutput = _TrackingOutput(outputId: 'default');
        final overrideOutput = _TrackingOutput(outputId: 'override');
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 3,
            chunkDelay: const Duration(milliseconds: 2),
          ),
          defaultOutput: defaultOutput,
        );

        await service.init();

        final chunks = await service
            .speak('override-1', 'override output test', output: overrideOutput)
            .toList();

        expect(chunks, isNotEmpty);
        expect(overrideOutput.consumedChunks, isNotEmpty);
        expect(defaultOutput.consumedChunks, isEmpty);

        await service.dispose();
      },
    );

    test('no default output and no override fails request', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 2),
        ),
      );

      await service.init();

      expect(
        () => service.speak('no-output', 'missing output'),
        throwsA(
          isA<TtsError>()
              .having(
                (error) => error.code,
                'code',
                TtsErrorCode.invalidRequest,
              )
              .having((error) => error.requestId, 'requestId', 'no-output'),
        ),
      );

      await service.dispose();
    });

    test(
      'no default output with per-request override works normally',
      () async {
        final overrideOutput = _TrackingOutput(outputId: 'override');
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 3,
            chunkDelay: const Duration(milliseconds: 2),
          ),
        );

        await service.init();

        final chunks = await service
            .speak(
              'no-default-override',
              'no default, use override',
              output: overrideOutput,
            )
            .toList();

        expect(chunks, isNotEmpty);
        expect(overrideOutput.consumedChunks, isNotEmpty);

        await service.dispose();
      },
    );
  });
}

final class _AlwaysFailOutput implements TtsOutput {
  _AlwaysFailOutput({required this.outputId});

  @override
  final String outputId;

  @override
  Set<AudioCapability> get inAudioCapabilities => {PcmCapability.wav()};

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {}

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    throw const TtsError(
      code: TtsErrorCode.outputWriteFailed,
      message: 'Injected output failure.',
    );
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    throw const TtsError(
      code: TtsErrorCode.outputWriteFailed,
      message: 'Injected output failure.',
    );
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {}

  @override
  Future<void> dispose() async {}
}

final class _FailByRequestIdOutput implements TtsOutput {
  _FailByRequestIdOutput({
    required this.outputId,
    required Set<String> failingRequestIds,
  }) : _failingRequestIds = Set<String>.from(failingRequestIds);

  @override
  final String outputId;

  final Set<String> _failingRequestIds;
  TtsOutputSession? _session;

  @override
  Set<AudioCapability> get inAudioCapabilities => {PcmCapability.wav()};

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    if (session == null) {
      return;
    }
    if (_failingRequestIds.contains(session.requestId)) {
      throw const TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Injected request-specific failure.',
      );
    }
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    return InMemoryAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {}

  @override
  Future<void> dispose() async {
    _session = null;
  }
}

final class _CaptureCancelOutput implements TtsOutput {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  TtsOutputSession? _session;
  CancelReason? lastCancelReason;

  @override
  String get outputId => 'capture-cancel-output';

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability.wav(),
    const Mp3Capability(),
  };

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _buffer.clear();
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    if (chunk is! TtsAudioChunk) {
      return;
    }

    _buffer.add(chunk.bytes);
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    final bytes = _buffer.takeBytes();
    _session = null;
    return InMemoryAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      audioBytes: bytes,
      totalBytes: bytes.length,
    );
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    lastCancelReason = control.cancelReason;
    _session = null;
    _buffer.clear();
  }

  @override
  Future<void> dispose() async {
    _session = null;
    _buffer.clear();
  }
}

final class _PcmOnlyOutput implements TtsOutput {
  _PcmOnlyOutput({required this.outputId, required Set<int> sampleRatesHz})
    : _sampleRatesHz = Set<int>.from(sampleRatesHz);

  @override
  final String outputId;

  final Set<int> _sampleRatesHz;
  TtsOutputSession? _session;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability(
      sampleRatesHz: _sampleRatesHz,
      bitsPerSample: const {16},
      channels: const {1},
      encodings: const {PcmEncoding.signedInt},
    ),
  };

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {}

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    return InMemoryAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    _session = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
  }
}

final class _TrackingOutput implements TtsOutput {
  _TrackingOutput({required this.outputId});

  @override
  final String outputId;

  final List<TtsChunk> consumedChunks = [];
  TtsOutputSession? _session;
  TtsAudioSpec? lastInitAudioSpec;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability.wav(),
    const Mp3Capability(),
  };

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    lastInitAudioSpec = session.audioSpec;
    consumedChunks.clear();
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    consumedChunks.add(chunk);
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) throw StateError('No active session.');
    return InMemoryAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    _session = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
    lastInitAudioSpec = null;
  }
}

final class _ChunkSpecEngine implements TtsEngine {
  _ChunkSpecEngine({
    required Set<AudioCapability> negotiatedCapabilities,
    required this.emittedSpec,
  }) : _negotiatedCapabilities = Set<AudioCapability>.from(
         negotiatedCapabilities,
       );

  final Set<AudioCapability> _negotiatedCapabilities;
  final TtsAudioSpec emittedSpec;

  @override
  String get engineId => 'chunk-spec-engine';

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get outAudioCapabilities => _negotiatedCapabilities;

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    return const [TtsVoice(voiceId: 'default', isDefault: true)];
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return const TtsVoice(voiceId: 'default', isDefault: true);
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    return const TtsVoice(voiceId: 'default', isDefault: true);
  }

  @override
  Future<void> init() async {}

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    yield TtsAudioChunk(
      requestId: request.requestId,
      sequenceNumber: 0,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      audioSpec: emittedSpec,
      isLastChunk: true,
      timestamp: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> dispose() async {}
}

final class _PlaybackAwareTestOutput implements TtsOutput, PlaybackAwareOutput {
  _PlaybackAwareTestOutput({
    required this.outputId,
    required this.playbackCompletionDelay,
  });

  @override
  final String outputId;

  final Duration playbackCompletionDelay;
  final StreamController<TtsOutputPlaybackCompletedEvent>
  _playbackCompletedController =
      StreamController<TtsOutputPlaybackCompletedEvent>.broadcast();

  TtsOutputSession? _session;
  String? _playbackId;
  int _bytesCount = 0;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability.wav(),
    const Mp3Capability(),
  };

  @override
  Stream<TtsOutputPlaybackCompletedEvent> get playbackCompletedEvents =>
      _playbackCompletedController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _playbackId = 'playback-${session.requestId}';
    _bytesCount = 0;
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    if (chunk is! TtsAudioChunk) {
      return;
    }
    _bytesCount += chunk.bytes.length;
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    final playbackId = _playbackId;
    if (session == null || playbackId == null) {
      throw StateError('No active session.');
    }

    Future<void>.delayed(playbackCompletionDelay, () {
      if (_playbackCompletedController.isClosed) {
        return;
      }
      _playbackCompletedController.add(
        TtsOutputPlaybackCompletedEvent(
          requestId: session.requestId,
          outputId: outputId,
          playbackId: playbackId,
          playedDuration: Duration(milliseconds: _bytesCount),
        ),
      );
    });

    _session = null;
    _playbackId = null;
    return PlaybackAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      playbackId: playbackId,
    );
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    _session = null;
    _playbackId = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
    _playbackId = null;
    await _playbackCompletedController.close();
  }
}
