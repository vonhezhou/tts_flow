import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';
import 'package:test/test.dart';

void main() {
  group('M6 integration', () {
    test('service emits chunks with resolved format using MemoryOutput',
        () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 3,
        ),
        output: MemoryOutput(),
      );

      await service.init();
      service.preferredFormat = TtsAudioFormat.wav;

      final chunks =
          await service.speak('i-1', 'integration sample text').toList();

      expect(chunks, isNotEmpty);
      expect(
          chunks.every((chunk) => chunk.audioSpec.format == TtsAudioFormat.wav),
          isTrue);
      expect(chunks.last.isLastChunk, isTrue);

      await service.dispose();
    });

    test('queue halts and cancels pending requests after failure', () async {
      final service = TtsService(
        engine: _FailingEngine(),
        output: MemoryOutput(),
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

    test('composite fanout writes file while streaming with failFast',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('uni_tts_m6_');
      try {
        final service = TtsService(
          engine: FakeTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 3,
          ),
          output: MulticastOutput(
            outputs: [
              MemoryOutput(outputId: 'memory'),
              FileOutput(outputId: 'file', outputDirectory: tempDir),
            ],
            errorPolicy: CompositeOutputErrorPolicy.failFast,
          ),
        );

        await service.init();
        service.preferredFormat = TtsAudioFormat.wav;

        final chunks = await service
            .speak('fanout-m6-1', 'fanout integration request')
            .toList();

        expect(chunks, isNotEmpty);

        final file =
            File('${tempDir.path}${Platform.pathSeparator}fanout-m6-1.wav');
        expect(await file.exists(), isTrue);
        expect(await file.length(), greaterThan(0));

        await service.dispose();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}

final class _FailingEngine implements TtsEngine {
  @override
  String get engineId => 'failing-engine';

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get supportedCapabilities => {
        const SimpleFormatCapability(format: TtsAudioFormat.mp3),
      };

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    return const [
      TtsVoice(voiceId: 'failing-default', isDefault: true),
    ];
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

    yield TtsChunk(
      requestId: request.requestId,
      sequenceNumber: 0,
      bytes: Uint8List.fromList([1]),
      audioSpec: resolvedFormat,
      isLastChunk: true,
      timestamp: DateTime.now().toUtc(),
    );
  }
}
