import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;
import 'package:tts_flow_gemini/tts_flow_gemini.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';

import 'support/provider_playback_fixture.dart';

const _sampleAudioAsset = 'assets/audio/test_audio_yanfei.wav';
const _utteranceId = 'just-audio-jitter-regression';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Captured Gemini PCM', () {
    test('long fixture plays to completion', () async {
      final fixture = await ProviderPlaybackFixture.load(
        manifestAsset: 'assets/fixtures/gemini/long_continuous/manifest.json',
      );
      final byteCount = fixture.chunks.fold<int>(
        0,
        (sum, chunk) => sum + chunk.bytes.length,
      );
      expect(byteCount / (24000 * 2), inInclusiveRange(30, 60));
      final result = await _runReplay(
        engine: ProviderPlaybackFixtureEngine(fixture),
        playbackTimeout: const Duration(seconds: 75),
      );
      expect(result.playbackFailedEvents, isEmpty);
      expect(result.playbackCompletedEvents, hasLength(1));
      for (final waiting in result.waitingEvents) {
        expect(waiting.requestKey, result.requestKey);
      }
    }, timeout: const Timeout(Duration(seconds: 100)));

    for (final kind in ['continuous', 'jitter']) {
      test('$kind replays recorded timing and completes once', () async {
        final fixture = await ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/gemini/$kind/manifest.json',
        );
        final result = await _runReplay(
          engine: ProviderPlaybackFixtureEngine(fixture),
        );
        expect(result.playbackFailedEvents, isEmpty);
        expect(result.playbackCompletedEvents, hasLength(1));
        // 录制中的短间隔是否触发等待取决于原生启动时机，不能固定次数。
        // 每个等待都必须归属本次请求，且最终恢复到唯一的播放完成事件。
        for (final waiting in result.waitingEvents) {
          expect(waiting.requestKey, result.requestKey);
        }
        if (kind == 'jitter') {
          expect(result.waitingEvents, isNotEmpty);
        }
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
    test('invalid arrival metadata is rejected before playback', () async {
      await expectLater(
        ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/gemini/invalid/manifest.json',
        ),
        throwsFormatException,
      );
    });
  });

  test(
    'Gemini SDK mock transport plays existing PCM through TtsFlow',
    () async {
      // This is a transport simulation using the captured MiMo PCM bytes.
      // It is deliberately not represented as a live Gemini fixture.
      final fixture = await ProviderPlaybackFixture.load(
        manifestAsset: 'assets/fixtures/mimo/continuous/manifest.json',
      );
      final client = _GeminiFixtureClient(fixture);
      addTearDown(client.close);
      final result = await _runReplay(
        engine: GeminiTtsEngine(apiKey: 'offline-test-key', httpClient: client),
      );
      expect(result.playbackFailedEvents, isEmpty);
      expect(result.waitingEvents, isEmpty);
      expect(result.playbackCompletedEvents, hasLength(1));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('Synthetic Azure-format MP3 (no live Azure service)', () {
    for (final kind in ['continuous', 'jitter', 'invalid']) {
      test('$kind MP3 replay', () async {
        final fixture = await ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/azure_simulated/$kind/manifest.json',
        );
        final result = await _runReplay(
          engine: ProviderPlaybackFixtureEngine(fixture),
        );
        if (kind == 'invalid') {
          expect(result.playbackFailedEvents, hasLength(1));
          expect(result.playbackCompletedEvents, isEmpty);
        } else {
          expect(result.playbackFailedEvents, isEmpty);
          expect(result.playbackCompletedEvents, hasLength(1));
          expect(result.waitingEvents, kind == 'jitter' ? isNotEmpty : isEmpty);
        }
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  });

  group('Captured MiMo PCM', () {
    test('long fixture plays to completion', () async {
      final fixture = await ProviderPlaybackFixture.load(
        manifestAsset: 'assets/fixtures/mimo/long_continuous/manifest.json',
      );
      final bytes = fixture.chunks.fold<int>(
        0,
        (sum, chunk) => sum + chunk.bytes.length,
      );
      expect(bytes / (24000 * 2), inInclusiveRange(30, 60));
      final result = await _runReplay(
        engine: ProviderPlaybackFixtureEngine(fixture),
        playbackTimeout: const Duration(seconds: 75),
      );
      expect(result.playbackFailedEvents, isEmpty);
      expect(result.playbackCompletedEvents, hasLength(1));
      expect(result.waitingEvents, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 100)));

    for (final kind in ['continuous', 'jitter']) {
      test('$kind fixture completes with expected waiting', () async {
        final fixture = await ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/mimo/$kind/manifest.json',
        );
        final result = await _runReplay(
          engine: ProviderPlaybackFixtureEngine(fixture),
        );
        expect(result.playbackFailedEvents, isEmpty);
        expect(result.playbackCompletedEvents, hasLength(1));
        expect(result.waitingEvents, kind == 'jitter' ? isNotEmpty : isEmpty);
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
    test('invalid arrival metadata is rejected before playback', () async {
      await expectLater(
        ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/mimo/invalid/manifest.json',
        ),
        throwsFormatException,
      );
    });
  });

  group('JustAudioBackend controlled jitter', () {
    test('the PCM/WAV fixture plays through AssetAudioSource', () async {
      final player = AudioPlayer();
      addTearDown(player.dispose);
      final errors = <PlayerException>[];
      final errorSub = player.errorStream.listen(errors.add);
      addTearDown(errorSub.cancel);

      await player.setAsset(_sampleAudioAsset);
      await player.play().timeout(const Duration(seconds: 15));

      expect(errors, isEmpty);
      expect(player.processingState, ProcessingState.completed);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a complete PCM/WAV source plays to completion', () async {
      final sample = await _loadSample();
      final result = await _runReplay(
        sample: sample,
        firstChunkBytes: sample.audioBytes.length,
        delayAfterReady: Duration.zero,
      );

      expect(result.waitingEvents, isEmpty);
      expect(result.playbackFailedEvents, isEmpty);
      expect(result.playbackCompletedEvents, hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('continuous supply completes without source-list underflow', () async {
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

    test(
      'controlled source-list underflow recovers and completes once',
      () async {
        final sample = await _loadSample();
        final result = await _runReplay(
          sample: sample,
          firstChunkBytes: 4 * 1024,
          delayAfterReady: const Duration(milliseconds: 500),
        );

        expect(result.waitingEvents, hasLength(1));
        expect(result.waitingEvents.single.requestKey, result.requestKey);
        expect(result.playbackFailedEvents, isEmpty);
        expect(result.playbackCompletedEvents, hasLength(1));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

Future<_ReplayResult> _runReplay({
  Duration playbackTimeout = const Duration(seconds: 15),
  _PcmSample? sample,
  int firstChunkBytes = 0,
  Duration delayAfterReady = Duration.zero,
  TtsEngine? engine,
}) async {
  final backend = JustAudioBackend();
  final firstSourceStarted = Completer<void>();
  final waitingEvents = <JustAudioPlaybackWaitingEvent>[];
  final playbackCompletedEvents = <TtsRequestEvent>[];
  final playbackFailedEvents = <TtsRequestEvent>[];
  final playerStates = <String>[];
  final backendErrors = <JustAudioPlaybackErrorEvent>[];
  String? requestKey;

  final sourceStartedSub = backend.playbackSourceStartedStream.listen((event) {
    if (event.requestKey == requestKey &&
        event.sourceIndex == 0 &&
        !firstSourceStarted.isCompleted) {
      firstSourceStarted.complete();
    }
  });
  final waitingSub = backend.playbackWaitingStream.listen(waitingEvents.add);
  final playerStateSub = backend.player.processingStateStream.listen((state) {
    playerStates.add(state.name);
  });
  final backendErrorSub = backend.playbackErrorStream.listen(backendErrors.add);

  final service = TtsFlow(
    engine:
        engine ??
        _GatedReplayEngine(
          audioBytes: sample!.audioBytes,
          audioSpec: sample.audioSpec,
          firstChunkBytes: firstChunkBytes,
          delayAfterReady: delayAfterReady,
          firstSourceStarted: firstSourceStarted.future,
        ),
    defaultOutput: SpeakerOutput(backend: backend),
  );
  final requestSub = service.requestEvents.listen((event) {
    if (event.utteranceId != _utteranceId) {
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
    await service.init();
    try {
      final request = service.speak(
        'controlled local audio replay',
        utteranceId: _utteranceId,
      );
      requestKey = request.requestKey;
      await request.chunks.drain<void>().timeout(const Duration(seconds: 15));
    } catch (error) {
      throw StateError(
        'Replay ingestion failed: $error; '
        'states=$playerStates, errors=${_describeBackendErrors(backendErrors)}, '
        'requestFailures=${_describeRequestFailures(playbackFailedEvents)}',
      );
    }

    await _waitForPlaybackTerminalEvent(
      timeout: playbackTimeout,
      playbackCompletedEvents: playbackCompletedEvents,
      playbackFailedEvents: playbackFailedEvents,
    );

    return _ReplayResult(
      requestKey: requestKey,
      waitingEvents: List.unmodifiable(waitingEvents),
      playbackCompletedEvents: List.unmodifiable(playbackCompletedEvents),
      playbackFailedEvents: List.unmodifiable(playbackFailedEvents),
    );
  } finally {
    await requestSub.cancel();
    await waitingSub.cancel();
    await sourceStartedSub.cancel();
    await playerStateSub.cancel();
    await backendErrorSub.cancel();
    await service.dispose();
  }
}

List<String> _describeBackendErrors(List<JustAudioPlaybackErrorEvent> events) {
  return events
      .map(
        (event) =>
            '${event.error.code}:${event.error.message ?? '-'}:'
            'index=${event.error.index ?? '-'}',
      )
      .toList(growable: false);
}

List<String> _describeRequestFailures(List<TtsRequestEvent> events) {
  return events
      .map(
        (event) =>
            '${event.error?.code}:${event.error?.message ?? '-'}:'
            'cause=${event.error?.cause ?? '-'}',
      )
      .toList(growable: false);
}

Future<void> _waitForPlaybackTerminalEvent({
  required Duration timeout,
  required List<TtsRequestEvent> playbackCompletedEvents,
  required List<TtsRequestEvent> playbackFailedEvents,
}) async {
  final stopwatch = Stopwatch()..start();
  while (playbackCompletedEvents.isEmpty && playbackFailedEvents.isEmpty) {
    if (stopwatch.elapsed > timeout) {
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

final class _GeminiFixtureClient extends http.BaseClient {
  _GeminiFixtureClient(this.fixture);
  final ProviderPlaybackFixture fixture;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        _body(),
        200,
        headers: {'content-type': 'text/event-stream'},
      );

  Stream<List<int>> _body() async* {
    final clock = Stopwatch()..start();
    for (final chunk in fixture.chunks) {
      final remaining = chunk.arrivalOffset - clock.elapsed;
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      yield utf8.encode(
        'data: ${jsonEncode({
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {
                    'inlineData': {'mimeType': 'audio/L16;codec=pcm;rate=24000', 'data': base64Encode(chunk.bytes)},
                  },
                ],
              },
            },
          ],
        })}\n\n',
      );
    }
    yield utf8.encode('data: {"candidates":[{"finishReason":"STOP"}]}\n\n');
  }
}

final class _PcmSample {
  const _PcmSample({required this.audioBytes, required this.audioSpec});

  final Uint8List audioBytes;
  final TtsAudioSpec audioSpec;
}

final class _ReplayResult {
  const _ReplayResult({
    required this.requestKey,
    required this.waitingEvents,
    required this.playbackCompletedEvents,
    required this.playbackFailedEvents,
  });

  final String requestKey;
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
    required this.firstSourceStarted,
  }) : _audioBytes = Uint8List.fromList(audioBytes);

  final Uint8List _audioBytes;
  final TtsAudioSpec audioSpec;
  final int firstChunkBytes;
  final Duration delayAfterReady;
  final Future<void> firstSourceStarted;

  @override
  String get engineId => 'controlled-local-replay';

  @override
  int get maxInputCharacterCount => 0;

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
    final split = firstChunkBytes.clamp(1, _audioBytes.length).toInt();
    yield TtsAudioChunk(
      requestKey: request.requestKey,
      sequenceNumber: 0,
      bytes: Uint8List.fromList(_audioBytes.sublist(0, split)),
      audioSpec: audioSpec,
      isLastChunk: split == _audioBytes.length,
      timestamp: DateTime.now().toUtc(),
    );

    if (split == _audioBytes.length) {
      return;
    }

    await firstSourceStarted;
    if (control.isCanceled) {
      return;
    }
    await Future<void>.delayed(delayAfterReady);
    if (control.isCanceled) {
      return;
    }

    yield TtsAudioChunk(
      requestKey: request.requestKey,
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
