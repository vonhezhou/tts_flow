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
    test('adapts non-streaming response into ordered chunks', () async {
      final engine = OpenAiTtsEngine(
        transport: _SuccessTransport(
            Uint8List.fromList(List<int>.generate(10, (i) => i))),
        nonStreamingChunkSizeBytes: 4,
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
  });
}

final class _SuccessTransport implements OpenAiTtsTransport {
  const _SuccessTransport(this.bytes);

  final Uint8List bytes;

  @override
  Future<OpenAiTtsResponse> synthesize(OpenAiTtsRequest request) async {
    return OpenAiTtsResponse(audioBytes: bytes);
  }
}

final class _FailTransport implements OpenAiTtsTransport {
  const _FailTransport(this.error);

  final Exception error;

  @override
  Future<OpenAiTtsResponse> synthesize(OpenAiTtsRequest request) {
    return Future<OpenAiTtsResponse>.error(error);
  }
}
