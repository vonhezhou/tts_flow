import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';

const _sampleAudioAsset = 'assets/audio/test_audio_yanfei.wav';
const _requestId = 'just-audio-jitter-regression';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('JustAudioBackend controlled jitter', () {
    testWidgets('continuous supply completes without source-list underflow', (
      tester,
    ) async {
      final sample = await _loadSample();
      final result = await _runReplay(
        sample: sample,
        firstChunkBytes: 32 * 1024,
        delayAfterReady: const Duration(milliseconds: 30),
      );

      expect(result.waitingEvents, isEmpty);
      expect(result.playbackFailedEvents, isEmpty);
      expect(result.playbackCompletedEvents, hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets(
      'controlled source-list underflow recovers and completes once',
      (tester) async {
        final sample = await _loadSample();
        final result = await _runReplay(
          sample: sample,
          firstChunkBytes: 4 * 1024,
          delayAfterReady: const Duration(milliseconds: 500),
        );

        expect(result.waitingEvents, hasLength(1));
        expect(result.waitingEvents.single.requestId, _requestId);
        expect(result.playbackFailedEvents, isEmpty);
        expect(result.playbackCompletedEvents, hasLength(1));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

Future<_ReplayResult> _runReplay({
  required _PcmSample sample,
  required int firstChunkBytes,
  required Duration delayAfterReady,
}) async {
  final backend = JustAudioBackend();
  final playerReady = Completer<void>();
  final waitingEvents = <JustAudioPlaybackWaitingEvent>[];
  final playbackCompletedEvents = <TtsRequestEvent>[];
  final playbackFailedEvents = <TtsRequestEvent>[];

  final readySub = backend.player.processingStateStream.listen((state) {
    if (state.name == 'ready' && !playerReady.isCompleted) {
      playerReady.complete();
    }
  });
  final waitingSub = backend.playbackWaitingStream.listen(waitingEvents.add);

  final service = TtsFlow(
    engine: _GatedReplayEngine(
      audioBytes: sample.audioBytes,
      audioSpec: sample.audioSpec,
      firstChunkBytes: firstChunkBytes,
      delayAfterReady: delayAfterReady,
      playerReady: playerReady.future,
    ),
    defaultOutput: SpeakerOutput(backend: backend),
  );
  final requestSub = service.requestEvents.listen((event) {
    if (event.requestId != _requestId) {
      return;
    }
    switch (event.type) {
      case TtsRequestEventType.requestPlaybackCompleted:
        playbackCompletedEvents.add(event);
      case TtsRequestEventType.requestPlaybackFailed:
        playbackFailedEvents.add(event);
      default:
        break;
    }
  });

  try {
    // Preserve the native playback pipeline while keeping the regression run
    // silent; assertions use player telemetry rather than human listening.
    await backend.player.setVolume(0);
    await service.init();
    await service
        .speak(_requestId, 'controlled local audio replay')
        .drain<void>()
        .timeout(const Duration(seconds: 15));

    await _waitForPlaybackTerminalEvent(
      playbackCompletedEvents: playbackCompletedEvents,
      playbackFailedEvents: playbackFailedEvents,
    );

    return _ReplayResult(
      waitingEvents: List.unmodifiable(waitingEvents),
      playbackCompletedEvents: List.unmodifiable(playbackCompletedEvents),
      playbackFailedEvents: List.unmodifiable(playbackFailedEvents),
    );
  } finally {
    await requestSub.cancel();
    await waitingSub.cancel();
    await readySub.cancel();
    await service.dispose();
  }
}

Future<void> _waitForPlaybackTerminalEvent({
  required List<TtsRequestEvent> playbackCompletedEvents,
  required List<TtsRequestEvent> playbackFailedEvents,
}) async {
  final stopwatch = Stopwatch()..start();
  while (playbackCompletedEvents.isEmpty && playbackFailedEvents.isEmpty) {
    if (stopwatch.elapsed > const Duration(seconds: 15)) {
      throw TimeoutException('Timed out waiting for physical playback end.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<_PcmSample> _loadSample() async {
  final assetData = await rootBundle.load(_sampleAudioAsset);
  final wavBytes = Uint8List.fromList(
    assetData.buffer.asUint8List(
      assetData.offsetInBytes,
      assetData.lengthInBytes,
    ),
  );
  final header = WavHeader.parse(Uint8List.fromList(wavBytes.sublist(0, 44)));
  return _PcmSample(
    audioBytes: Uint8List.fromList(wavBytes.sublist(44)),
    audioSpec: TtsAudioSpec.pcm(header.toPcmDescriptor()),
  );
}

final class _PcmSample {
  const _PcmSample({required this.audioBytes, required this.audioSpec});

  final Uint8List audioBytes;
  final TtsAudioSpec audioSpec;
}

final class _ReplayResult {
  const _ReplayResult({
    required this.waitingEvents,
    required this.playbackCompletedEvents,
    required this.playbackFailedEvents,
  });

  final List<JustAudioPlaybackWaitingEvent> waitingEvents;
  final List<TtsRequestEvent> playbackCompletedEvents;
  final List<TtsRequestEvent> playbackFailedEvents;
}

final class _GatedReplayEngine with TtsEngineDefaults implements TtsEngine {
  _GatedReplayEngine({
    required Uint8List audioBytes,
    required this.audioSpec,
    required this.firstChunkBytes,
    required this.delayAfterReady,
    required this.playerReady,
  }) : _audioBytes = Uint8List.fromList(audioBytes);

  final Uint8List _audioBytes;
  final TtsAudioSpec audioSpec;
  final int firstChunkBytes;
  final Duration delayAfterReady;
  final Future<void> playerReady;

  @override
  String get engineId => 'controlled-local-replay';

  @override
  int get maxInputByteSize => 0;

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get outAudioCapabilities {
    final descriptor = audioSpec.requirePcm;
    return {
      PcmCapability(
        sampleRatesHz: {descriptor.sampleRateHz},
        bitsPerSample: {descriptor.bitsPerSample},
        channels: {descriptor.channels},
        encodings: {descriptor.encoding},
      ),
    };
  }

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    return const [TtsVoice(voiceId: 'controlled-replay', isDefault: true)];
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return const TtsVoice(voiceId: 'controlled-replay', isDefault: true);
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) => getDefaultVoice();

  @override
  Future<void> init() async {}

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    if (audioSpec != resolvedFormat) {
      throw StateError('The replay engine received an unexpected audio spec.');
    }
    final split = firstChunkBytes.clamp(1, _audioBytes.length - 1).toInt();
    yield TtsAudioChunk(
      requestId: request.requestId,
      sequenceNumber: 0,
      bytes: Uint8List.fromList(_audioBytes.sublist(0, split)),
      audioSpec: audioSpec,
      isLastChunk: false,
      timestamp: DateTime.now().toUtc(),
    );

    await playerReady;
    if (control.isCanceled) {
      return;
    }
    await Future<void>.delayed(delayAfterReady);
    if (control.isCanceled) {
      return;
    }

    yield TtsAudioChunk(
      requestId: request.requestId,
      sequenceNumber: 1,
      bytes: Uint8List.fromList(_audioBytes.sublist(split)),
      audioSpec: audioSpec,
      isLastChunk: true,
      timestamp: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> dispose() async {}
}
