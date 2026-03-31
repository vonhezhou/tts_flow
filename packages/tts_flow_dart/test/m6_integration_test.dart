import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('M6 integration', () {
    test(
      'service emits chunks with resolved format using MemoryOutput',
      () async {
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 3,
          ),
          defaultOutput: MemoryOutput(),
        );

        await service.init();
        service.preferredFormat = TtsAudioFormat.pcm;

        final chunks = await service
            .speak('i-1', 'integration sample text')
            .toList();

        expect(chunks, isNotEmpty);
        expect(chunks.every((chunk) => chunk is TtsAudioChunk), isTrue);
        expect(
          chunks.every(
            (chunk) =>
                (chunk as TtsAudioChunk).audioSpec.format == TtsAudioFormat.pcm,
          ),
          isTrue,
        );
        expect(chunks.last.isLastChunk, isTrue);

        await service.dispose();
      },
    );

    test('queue halts and cancels pending requests after failure', () async {
      final service = TtsFlow(
        engine: _FailingEngine(),
        defaultOutput: MemoryOutput(),
      );

      await service.init();

      final canceledIds = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestCanceled) {
          canceledIds.add(event.requestId);
        }
      });

      final first = service.speak('fail-1', 'this request fails');
      final second = service.speak('fail-2', 'should be canceled');

      await expectLater(first.toList(), throwsA(isA<TtsError>()));
      expect(await second.toList(), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(canceledIds, contains('fail-2'));

      await sub.cancel();
      await service.dispose();
    });

    test(
      'Multicast fanout writes file while streaming with failFast',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('uni_tts_m6_');
        try {
          final service = TtsFlow(
            engine: SineTtsEngine(
              engineId: 'fake-engine',
              supportsStreaming: true,
              chunkCount: 3,
            ),
            defaultOutput: MulticastOutput(
              outputs: [
                MemoryOutput(outputId: 'memory'),
                WavFileOutput(
                  '${tempDir.path}${Platform.pathSeparator}fanout-m6-1.wav',
                  outputId: 'file',
                ),
              ],
              errorPolicy: MulticastOutputErrorPolicy.failFast,
            ),
          );

          await service.init();
          service.preferredFormat = TtsAudioFormat.pcm;

          final chunks = await service
              .speak('fanout-m6-1', 'fanout integration request')
              .toList();

          expect(chunks, isNotEmpty);

          final file = File(
            '${tempDir.path}${Platform.pathSeparator}fanout-m6-1.wav',
          );
          expect(await file.exists(), isTrue);
          expect(await file.length(), greaterThan(0));

          await service.dispose();
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );
  });
}

final class _FailingEngine implements TtsEngine {
  @override
  String get engineId => 'failing-engine';

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get outAudioCapabilities => {const Mp3Capability()};

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    return const [TtsVoice(voiceId: 'failing-default', isDefault: true)];
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return const TtsVoice(voiceId: 'failing-default', isDefault: true);
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    return getDefaultVoice();
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    if (request.requestId == 'fail-1') {
      throw const TtsError(
        code: TtsErrorCode.networkError,
        message: 'Injected test failure.',
        requestId: 'fail-1',
      );
    }

    yield TtsAudioChunk(
      requestId: request.requestId,
      sequenceNumber: 0,
      bytes: Uint8List.fromList([1]),
      audioSpec: resolvedFormat,
      isLastChunk: true,
      timestamp: DateTime.now().toUtc(),
    );
  }
}
