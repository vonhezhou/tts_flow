import 'dart:async';
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

      final chunks = await service
          .speak(
            const TtsRequest(
              requestId: 'i-1',
              text: 'integration sample text',
              preferredFormat: TtsAudioFormat.wav,
            ),
          )
          .toList();

      expect(chunks, isNotEmpty);
      expect(
          chunks.every((chunk) => chunk.format == TtsAudioFormat.wav), isTrue);
      expect(chunks.last.isLastChunk, isTrue);

      await service.dispose();
    });

    test('queue halts and cancels pending requests after failure', () async {
      final service = TtsService(
        engine: _FailingEngine(),
        output: MemoryOutput(),
      );

      final canceledIds = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestCanceled) {
          canceledIds.add(event.requestId);
        }
      });

      final first = service.speak(
        const TtsRequest(requestId: 'fail-1', text: 'this request fails'),
      );
      final second = service.speak(
        const TtsRequest(requestId: 'fail-2', text: 'should be canceled'),
      );

      await expectLater(first.toList(), throwsA(isA<TtsError>()));
      expect(await second.toList(), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(canceledIds, contains('fail-2'));

      await sub.cancel();
      await service.dispose();
    });
  });
}

final class _FailingEngine implements TtsEngine {
  @override
  String get engineId => 'failing-engine';

  @override
  bool get supportsPause => false;

  @override
  bool get supportsStreaming => true;

  @override
  Set<TtsAudioFormat> get supportedFormats => {TtsAudioFormat.mp3};

  @override
  Future<void> dispose() async {}

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    TtsControlToken controlToken,
    TtsAudioFormat resolvedFormat,
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
      format: resolvedFormat,
      isLastChunk: true,
      timestamp: DateTime.now().toUtc(),
    );
  }
}
