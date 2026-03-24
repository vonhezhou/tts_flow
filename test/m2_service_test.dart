import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';
import 'package:test/test.dart';

void main() {
  group('M2 service', () {
    test('processes requests in FIFO order', () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        output: FakeTtsOutput(),
      );

      final started = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestStarted) {
          started.add(event.requestId);
        }
      });

      final streamA = service.speak(
        const TtsRequest(requestId: 'a', text: 'first request payload'),
      );
      final streamB = service.speak(
        const TtsRequest(requestId: 'b', text: 'second request payload'),
      );

      await streamA.toList();
      await streamB.toList();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(started, ['a', 'b']);
      await sub.cancel();
      await service.dispose();
    });

    test('clearQueue cancels pending requests only', () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 3,
          chunkDelay: const Duration(milliseconds: 10),
        ),
        output: FakeTtsOutput(),
      );

      final active = service.speak(
        const TtsRequest(requestId: 'active', text: 'active request'),
      );
      final pending = service.speak(
        const TtsRequest(requestId: 'pending', text: 'pending request'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 8));
      final clearedCount = await service.clearQueue();

      expect(clearedCount, 1);
      expect(await active.toList(), isNotEmpty);
      expect(await pending.toList(), isEmpty);

      await service.dispose();
    });

    test('stopCurrent stops active request and next request proceeds',
        () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 8,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        output: FakeTtsOutput(),
      );

      final events = <TtsRequestEvent>[];
      final sub = service.requestEvents.listen(events.add);

      final longStream = service.speak(
        const TtsRequest(
            requestId: 'long', text: 'this is a long request payload'),
      );
      final nextStream = service.speak(
        const TtsRequest(requestId: 'next', text: 'next request'),
      );

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
    });

    test('requestFailed event includes output failure details', () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 2),
        ),
        output: CompositeOutput(
          outputs: [
            MemoryOutput(outputId: 'memory'),
            _AlwaysFailOutput(outputId: 'fail-output'),
          ],
          errorPolicy: CompositeOutputErrorPolicy.failFast,
        ),
      );

      TtsRequestEvent? failedEvent;
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestFailed) {
          failedEvent = event;
        }
      });

      final stream = service.speak(
        const TtsRequest(requestId: 'output-fail', text: 'fail through output'),
      );

      await expectLater(stream.toList(), throwsA(isA<TtsError>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(failedEvent, isNotNull);
      expect(failedEvent!.outputId, 'fail-output');
      expect(failedEvent!.outputError, isNotNull);
      expect(failedEvent!.outputError!.code, TtsErrorCode.outputWriteFailed);

      await sub.cancel();
      await service.dispose();
    });

    test('continueOnError keeps pending queue after active failure', () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 2),
        ),
        output: _FailByRequestIdOutput(
          outputId: 'selective-fail',
          failingRequestIds: {'first'},
        ),
        config: const TtsServiceConfig(
          queueFailurePolicy: TtsQueueFailurePolicy.continueOnError,
        ),
      );

      final events = <TtsRequestEvent>[];
      final sub = service.requestEvents.listen(events.add);

      final first = service.speak(
        const TtsRequest(requestId: 'first', text: 'this will fail'),
      );
      final second = service.speak(
        const TtsRequest(requestId: 'second', text: 'this should still run'),
      );

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
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        output: FakeTtsOutput(),
      );

      final started = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestStarted) {
          started.add(event.requestId);
        }
      });

      await service.pauseCurrent();
      expect(service.isPaused, isTrue);

      final first = service.speak(
        const TtsRequest(requestId: 'paused-1', text: 'first queued'),
      );
      final second = service.speak(
        const TtsRequest(requestId: 'paused-2', text: 'second queued'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(started, isEmpty);

      await service.resumeCurrent();
      expect(service.isPaused, isFalse);

      await first.toList();
      await second.toList();

      expect(started, ['paused-1', 'paused-2']);

      await sub.cancel();
      await service.dispose();
    });

    test('stopCurrent forwards stopCurrent cancel reason to output', () async {
      final output = _CaptureCancelOutput();
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 8,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        output: output,
      );

      final longStream = service.speak(
        const TtsRequest(requestId: 'cancel-reason', text: 'long request'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 12));
      await service.stopCurrent();
      await longStream.toList();

      expect(output.lastCancelReason, CancelReason.stopCurrent);
      await service.dispose();
    });

    test('service exposes engine available voices and defaults', () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
        ),
        output: FakeTtsOutput(),
      );

      final voices = await service.getAvailableVoices();
      final defaultVoice = await service.getDefaultVoice();
      final localeDefault = await service.getDefaultVoiceForLocale('en-US');

      expect(voices, isNotEmpty);
      expect(defaultVoice.voiceId, isNotEmpty);
      expect(localeDefault.voiceId, isNotEmpty);

      await service.dispose();
    });
  });
}

final class _AlwaysFailOutput implements TtsOutput {
  _AlwaysFailOutput({required this.outputId});

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities => {
        const SimpleFormatCapability(format: TtsAudioFormat.wav),
      };

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
  Future<void> onCancel(SynthesisControl control) async {}

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
  Set<AudioCapability> get acceptedCapabilities => {
        const SimpleFormatCapability(format: TtsAudioFormat.wav),
      };

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
  Future<void> onCancel(SynthesisControl control) async {}

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
  Set<AudioCapability> get acceptedCapabilities => {
        const SimpleFormatCapability(format: TtsAudioFormat.wav),
        const SimpleFormatCapability(format: TtsAudioFormat.mp3),
      };

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _buffer.clear();
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
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
  Future<void> onCancel(SynthesisControl control) async {
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
