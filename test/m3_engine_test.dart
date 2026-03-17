import 'dart:typed_data';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';
import 'package:test/test.dart';

void main() {
  group('M3 format negotiator', () {
    const negotiator = TtsFormatNegotiator();

    test('uses request preferred format when available', () {
      final resolved = negotiator.negotiate(
        engineFormats: {TtsAudioFormat.mp3, TtsAudioFormat.wav},
        outputFormats: {TtsAudioFormat.mp3},
        preferredOrder: const [TtsAudioFormat.wav, TtsAudioFormat.mp3],
        requestId: 'n1',
        preferredFormat: TtsAudioFormat.mp3,
      );

      expect(resolved, TtsAudioFormat.mp3);
    });

    test('uses deterministic fallback order when preferred not available', () {
      final resolved = negotiator.negotiate(
        engineFormats: {TtsAudioFormat.aac, TtsAudioFormat.wav},
        outputFormats: {TtsAudioFormat.aac, TtsAudioFormat.wav},
        preferredOrder: const [TtsAudioFormat.pcm16, TtsAudioFormat.wav],
        requestId: 'n2',
      );

      expect(resolved, TtsAudioFormat.wav);
    });

    test('throws formatNegotiationFailed when intersection is empty', () {
      expect(
        () => negotiator.negotiate(
          engineFormats: {TtsAudioFormat.mp3},
          outputFormats: {TtsAudioFormat.wav},
          preferredOrder: const [TtsAudioFormat.wav],
          requestId: 'n3',
        ),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.formatNegotiationFailed,
          ),
        ),
      );
    });
  });

  group('M3 OpenAI engine adapter', () {
    test('adapts streaming response into ordered chunks', () async {
      final engine = OpenAiTtsEngine(
        transport: _SuccessTransport(
          Uint8List.fromList(List<int>.generate(10, (i) => i)),
          streamChunks: const [
            [0, 1, 2, 3],
            [4, 5, 6],
            [7, 8, 9],
          ],
        ),
      );

      final chunks = await engine
          .synthesize(
            const TtsRequest(requestId: 'o1', text: 'hello'),
            TtsControlToken(),
            TtsAudioFormat.mp3,
          )
          .toList();

      expect(chunks, hasLength(3));
      expect(chunks[0].sequenceNumber, 0);
      expect(chunks[1].sequenceNumber, 1);
      expect(chunks[2].sequenceNumber, 2);
      expect(chunks[0].bytes, Uint8List.fromList([0, 1, 2, 3]));
      expect(chunks[1].bytes, Uint8List.fromList([4, 5, 6]));
      expect(chunks[2].bytes, Uint8List.fromList([7, 8, 9]));
      expect(chunks[2].isLastChunk, isTrue);
      expect(
          chunks.every((chunk) => chunk.format == TtsAudioFormat.mp3), isTrue);
    });

    test('maps transport auth error to authFailed', () async {
      final engine = OpenAiTtsEngine(
        transport: const _FailTransport(
          OpenAiTransportException(statusCode: 401, message: 'unauthorized'),
        ),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o2', text: 'hello'),
              TtsControlToken(),
              TtsAudioFormat.mp3,
            )
            .toList(),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.authFailed,
          ),
        ),
      );
    });

    test('retrying transport retries retryable failure then succeeds',
        () async {
      var attempts = 0;
      final transport = OpenAiRetryingTransport(
        inner: _CallbackTransport(() async {
          attempts++;
          if (attempts < 2) {
            throw const OpenAiTransportException(
                statusCode: 500, message: 'server');
          }
          return [1, 2];
        }),
        maxRetries: 2,
        initialBackoff: const Duration(milliseconds: 1),
      );

      final chunks = await transport
          .synthesize(
            const OpenAiTtsRequest(
              text: 'hi',
              voiceId: 'alloy',
              format: TtsAudioFormat.mp3,
            ),
          )
          .toList();

      expect(attempts, 2);
      expect(chunks, const [
        [1, 2]
      ]);
    });

    test('retrying transport does not retry auth failure', () async {
      var attempts = 0;
      final transport = OpenAiRetryingTransport(
        inner: _CallbackTransport(() async {
          attempts++;
          throw const OpenAiTransportException(
              statusCode: 401, message: 'unauthorized');
        }),
        maxRetries: 3,
      );

      await expectLater(
        () async {
          await transport
              .synthesize(
                const OpenAiTtsRequest(
                  text: 'hi',
                  voiceId: 'alloy',
                  format: TtsAudioFormat.mp3,
                ),
              )
              .drain<void>();
        },
        throwsA(isA<OpenAiTransportException>()),
      );
      expect(attempts, 1);
    });

    test('maps transport timeout to timeout error code', () async {
      final engine = OpenAiTtsEngine(
        transport: const _FailTransport(
          OpenAiTransportException(statusCode: 408, message: 'timeout'),
        ),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o3', text: 'hello'),
              TtsControlToken(),
              TtsAudioFormat.mp3,
            )
            .toList(),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.timeout,
          ),
        ),
      );
    });

    test(
        'fromClientConfig wires default transport and maps missing key to authFailed',
        () async {
      final engine = OpenAiTtsEngine.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: ''),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o4', text: 'hello'),
              TtsControlToken(),
              TtsAudioFormat.mp3,
            )
            .toList(),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.authFailed,
          ),
        ),
      );
    });
  });
}

final class _SuccessTransport implements OpenAiTtsTransport {
  const _SuccessTransport(this.bytes, {this.streamChunks});

  final Uint8List bytes;
  final List<List<int>>? streamChunks;

  @override
  Stream<List<int>> synthesize(OpenAiTtsRequest request) async* {
    final chunks = streamChunks ?? [bytes];
    for (final chunk in chunks) {
      yield chunk;
    }
  }
}

final class _FailTransport implements OpenAiTtsTransport {
  const _FailTransport(this.error);

  final Exception error;

  @override
  Stream<List<int>> synthesize(OpenAiTtsRequest request) {
    return Stream<List<int>>.error(error);
  }
}

final class _CallbackTransport implements OpenAiTtsTransport {
  const _CallbackTransport(this.callback);

  final Future<List<int>> Function() callback;

  @override
  Stream<List<int>> synthesize(OpenAiTtsRequest request) async* {
    yield await callback();
  }
}
