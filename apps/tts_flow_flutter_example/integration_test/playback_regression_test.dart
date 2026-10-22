import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';

import 'support/provider_playback_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final provider in ['mimo', 'mimo_mp3']) {
    test('$provider native pause resumes finalized audio', () async {
      final fixture = await _load(provider);
      final probe = _PlaybackProbe(ProviderPlaybackFixtureEngine(fixture));
      addTearDown(probe.dispose);
      await probe.flow.init();
      final request = probe.speak();
      await request.chunks.drain<void>();
      await probe.waitForProgress();

      await request.pausePlayback();
      expect(probe.backend.player.playing, isFalse);
      // 等待暂停回调落定，再观察位置是否保持；不要求原生时钟绝对不漂移。
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final pausedAt = probe.backend.player.position;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        (probe.backend.player.position - pausedAt).abs().inMilliseconds,
        lessThanOrEqualTo(80),
      );
      expect(
        probe.eventsOf(request, TtsRequestEventType.requestPlaybackCompleted),
        isEmpty,
      );
      expect(request.hasActivePlayback, isTrue);

      await request.resumePlayback();
      await _until(
        () =>
            probe.backend.player.position >
            pausedAt + const Duration(milliseconds: 100),
        'playback advances after resume',
      );
      await probe.waitForCompletion(request);
      expect(
        probe.eventsOf(request, TtsRequestEventType.requestPlaybackPaused),
        hasLength(1),
      );
      expect(
        probe.eventsOf(request, TtsRequestEventType.requestPlaybackResumed),
        hasLength(1),
      );
      expect(probe.failures, isEmpty);
      probe.report(request, '$provider-pause-resume');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
      '$provider native stop followed immediately by next request',
      () async {
        final fixture = await _load(provider);
        final probe = _PlaybackProbe(ProviderPlaybackFixtureEngine(fixture));
        addTearDown(probe.dispose);
        await probe.flow.init();
        final first = probe.speak();
        await first.chunks.drain<void>();
        await probe.waitForProgress();
        await first.stopPlayback();
        expect(first.hasActivePlayback, isFalse);
        // 故意重用 utteranceId，验证事件按具体 requestKey 隔离。
        final next = probe.speak();
        await next.chunks.drain<void>();
        await probe.waitForCompletion(next);
        await _until(
          () => probe.backend.player.audioSources.isEmpty,
          'completed sources are removed',
        );
        expect(first.requestKey, isNot(next.requestKey));
        expect(
          probe.eventsOf(first, TtsRequestEventType.requestPlaybackStopped),
          hasLength(1),
        );
        expect(
          probe.eventsOf(first, TtsRequestEventType.requestPlaybackCompleted),
          isEmpty,
        );
        expect(probe.failures, isEmpty);
        probe.report(next, '$provider-stop-next');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  test('long MiMo MP3 many sources recover from three supply gaps', () async {
    final fixture = await _load('mimo_mp3', kind: 'long_continuous');
    late _PlaybackProbe probe;
    final engine = _SourceGatedEngine(
      fixture,
      beforeChunk: (index) async {
        if (index == 0) return;
        // 下一块必须等上一 Source 冻结后才交付，确保测试真正切换多项 Source。
        await probe.waitForRead(index - 1);
        if ([35, 70, 105].contains(index)) {
          await probe.waitForUnderflow(index - 1);
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      },
    );
    probe = _PlaybackProbe(engine);
    addTearDown(probe.dispose);
    await probe.flow.init();
    final request = probe.speak();
    // 交付受播放门控，合成回放本身约 44 秒，不能沿用短样本的 15 秒期限。
    await request.chunks.drain<void>().timeout(const Duration(seconds: 75));
    await probe.waitForCompletion(request);
    expect(probe.failures, isEmpty);
    expect(probe.reads, hasLength(fixture.chunks.length));
    expect(probe.waits.length, greaterThanOrEqualTo(3));
    for (final index in [34, 69, 104]) {
      expect(probe.waits.any((e) => e.index == index), isTrue);
      expect(
        probe.recoveries.any((e) => e['exhaustedSource'] == index),
        isTrue,
      );
    }
    final completion = probe
        .eventsOf(request, TtsRequestEventType.requestPlaybackCompleted)
        .single;
    // 不同原生解码器对编码器裁剪元数据的解释不同；不将 FFmpeg 时长当成平台定值。
    expect(
      completion.playedDuration?.inMilliseconds,
      inInclusiveRange(30000, 60000),
    );
    probe.report(request, 'mimo-mp3-long-source-gated');
  }, timeout: const Timeout(Duration(seconds: 100)));
}

Future<ProviderPlaybackFixture> _load(
  String provider, {
  String kind = 'continuous',
}) => ProviderPlaybackFixture.load(
  manifestAsset: 'assets/fixtures/$provider/$kind/manifest.json',
);

Future<void> _until(bool Function() condition, String description) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 15)) {
      throw TimeoutException(description);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

typedef _SourceMoment = ({String requestKey, int index, Duration at});

/// 只观测测试调用和平台事件；平台读取、位置回调都不等同于实际出声。
final class _PlaybackProbe {
  _PlaybackProbe(TtsEngine engine) {
    flow = TtsFlow(
      engine: engine,
      defaultOutput: SpeakerOutput(backend: backend),
    );
    _subscriptions.add(
      flow.requestEvents.listen((event) {
        events.add(event);
        if (event.chunk is TtsAudioChunk) {
          firstChunk.putIfAbsent(event.requestKey, () => clock.elapsed);
          latestChunk[event.requestKey] = clock.elapsed;
        }
      }),
    );
    _subscriptions.add(
      backend.playbackSourceStartedStream.listen((event) {
        final now = clock.elapsed;
        reads.add((
          requestKey: event.requestKey,
          index: event.sourceIndex,
          at: now,
        ));
        for (final waiting in waits.where(
          (w) =>
              w.requestKey == event.requestKey && w.index < event.sourceIndex,
        )) {
          if (recoveries.any(
            (r) =>
                r['requestKey'] == waiting.requestKey &&
                r['exhaustedSource'] == waiting.index,
          )) {
            continue;
          }
          recoveries.add({
            'requestKey': event.requestKey,
            'exhaustedSource': waiting.index,
            'waitingToSourceReadMs': (now - waiting.at).inMicroseconds / 1000,
            'newAudioToSourceReadMs':
                (now - latestChunk[event.requestKey]!).inMicroseconds / 1000,
          });
        }
      }),
    );
    _subscriptions.add(
      backend.playbackWaitingStream.listen((event) {
        waits.add((
          requestKey: event.requestKey,
          index: event.sourceIndex,
          at: clock.elapsed,
        ));
      }),
    );
  }

  final backend = JustAudioBackend();
  late final TtsFlow flow;
  final clock = Stopwatch()..start();
  final events = <TtsRequestEvent>[];
  final reads = <_SourceMoment>[];
  final waits = <_SourceMoment>[];
  final recoveries = <Map<String, Object>>[];
  final requested = <String, Duration>{};
  final firstChunk = <String, Duration>{};
  final latestChunk = <String, Duration>{};
  final _subscriptions = <StreamSubscription<Object?>>[];

  Iterable<TtsRequestEvent> get failures => events.where(
    (e) =>
        e.type == TtsRequestEventType.requestPlaybackFailed ||
        e.type == TtsRequestEventType.requestSynthesisFailed,
  );

  Iterable<TtsRequestEvent> eventsOf(
    TtsRequestHandle request,
    TtsRequestEventType type,
  ) =>
      events.where((e) => e.requestKey == request.requestKey && e.type == type);

  TtsRequestHandle speak() {
    final start = clock.elapsed;
    final handle = flow.speak(
      'offline playback regression',
      utteranceId: 'reused-id',
    );
    requested[handle.requestKey] = start;
    return handle;
  }

  Future<void> waitForProgress() => _until(
    () =>
        backend.player.playing &&
        backend.player.position > const Duration(milliseconds: 150),
    'native position advances',
  );

  Future<void> waitForRead(int index) => _until(
    () => reads.any((e) => e.index == index),
    'source $index is requested',
  );

  Future<void> waitForUnderflow(int index) => _until(
    () => waits.any((e) => e.index == index),
    'source $index exhausts the playlist',
  );

  Future<void> waitForCompletion(TtsRequestHandle request) async {
    await _until(
      () =>
          eventsOf(
            request,
            TtsRequestEventType.requestPlaybackCompleted,
          ).isNotEmpty ||
          failures.isNotEmpty,
      'request reaches playback terminal event',
    );
    expect(failures, isEmpty);
    expect(
      eventsOf(request, TtsRequestEventType.requestPlaybackCompleted),
      hasLength(1),
    );
  }

  void report(TtsRequestHandle request, String name) {
    final firstRead = reads
        .firstWhere((e) => e.requestKey == request.requestKey)
        .at;
    final audio = firstChunk[request.requestKey]!;
    expect(firstRead, greaterThanOrEqualTo(audio));
    // 保留机器可读数据用于设备比较；不把调试模式下的单次观测作为性能 SLA。
    final metrics = <String, Object?>{
      'case': name,
      'platform': defaultTargetPlatform.name,
      'buildMode': kDebugMode
          ? 'debug'
          : (kProfileMode ? 'profile' : 'release'),
      'requestToFirstAudioMs':
          (audio - requested[request.requestKey]!).inMicroseconds / 1000,
      'firstAudioToSourceReadMs': (firstRead - audio).inMicroseconds / 1000,
      'playedDurationMs': eventsOf(
        request,
        TtsRequestEventType.requestPlaybackCompleted,
      ).single.playedDuration?.inMilliseconds,
      'sourceReadCount': reads
          .where((e) => e.requestKey == request.requestKey)
          .length,
      'recoveries': recoveries
          .where((e) => e['requestKey'] == request.requestKey)
          .toList(),
    };
    debugPrint('PLAYBACK_METRICS ${jsonEncode(metrics)}');
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await flow.dispose();
  }
}

/// 保留服务音频字节，交付时序改由 Source 请求及欠载事件门控。
final class _SourceGatedEngine with TtsEngineDefaults implements TtsEngine {
  _SourceGatedEngine(
    ProviderPlaybackFixture fixture, {
    required this.beforeChunk,
  }) : source = ProviderPlaybackFixtureEngine(fixture);
  final ProviderPlaybackFixtureEngine source;
  final Future<void> Function(int index) beforeChunk;

  @override
  String get engineId => 'source-gated-${source.engineId}';
  @override
  int get maxInputCharacterCount => source.maxInputCharacterCount;
  @override
  bool get supportsStreaming => true;
  @override
  Set<AudioCapability> get outAudioCapabilities => source.outAudioCapabilities;
  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) =>
      source.getAvailableVoices(locale: locale);
  @override
  Future<TtsVoice> getDefaultVoice() => source.getDefaultVoice();
  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) =>
      source.getDefaultVoiceForLocale(locale);
  @override
  Future<void> init() => source.init();
  @override
  Future<void> dispose() => source.dispose();

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    await for (final chunk in source.synthesize(
      request,
      control,
      resolvedFormat,
    )) {
      await beforeChunk(chunk.sequenceNumber);
      if (control.isCanceled) return;
      yield chunk;
    }
  }
}
