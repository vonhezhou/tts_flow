import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('M3 format negotiator', () {
    const negotiator = TtsFormatNegotiator();

    test('negotiates PCM descriptor honoring preferred sample rate', () {
      final resolved = negotiator.negotiateSpec(
        engineCapabilities: {
          PcmCapability(
            sampleRatesHz: {16000, 24000, 48000},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        outputCapabilities: {
          PcmCapability(
            sampleRatesHz: {22050, 24000},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        preferredOrder: const [TtsAudioFormat.pcm],
        requestId: 'n0',
        preferredSampleRateHz: 24000,
      );

      expect(resolved.format, TtsAudioFormat.pcm);
      expect(resolved.requirePcm.sampleRateHz, 24000);
      expect(resolved.requirePcm.bitsPerSample, 16);
      expect(resolved.requirePcm.channels, 1);
    });

    test('negotiates PCM fallback sample rate when preferred not available',
        () {
      final resolved = negotiator.negotiateSpec(
        engineCapabilities: {
          PcmCapability(
            sampleRatesHz: {16000, 22050},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        outputCapabilities: {
          PcmCapability(
            sampleRatesHz: {8000, 16000, 22050},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        preferredOrder: const [TtsAudioFormat.pcm],
        requestId: 'n0b',
        preferredSampleRateHz: 24000,
      );

      expect(resolved.format, TtsAudioFormat.pcm);
      expect(resolved.requirePcm.sampleRateHz, 22050);
    });

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
        preferredOrder: const [TtsAudioFormat.pcm, TtsAudioFormat.wav],
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
        apiClient: _SuccessApiClient(
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
            TtsAudioSpec(format: TtsAudioFormat.mp3),
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
        chunks.every((chunk) => chunk.audioSpec.format == TtsAudioFormat.mp3),
        isTrue,
      );
    });

    test('maps transport auth error to authFailed', () async {
      final engine = OpenAiTtsEngine(
        apiClient: const _FailApiClient(
          OpenAiTransportException(statusCode: 401, message: 'unauthorized'),
        ),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o2', text: 'hello'),
              TtsControlToken(),
              TtsAudioSpec(format: TtsAudioFormat.mp3),
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

    test('retrying api client retries retryable failure then succeeds',
        () async {
      var attempts = 0;
      final apiClient = OpenAiRetryingApiClient(
        inner: _CallbackApiClient(() async {
          attempts++;
          if (attempts < 2) {
            throw const OpenAiTransportException(
              statusCode: 500,
              message: 'server',
            );
          }
          return _streamedResponse(
            const [
              [1, 2],
            ],
          );
        }),
        maxRetries: 2,
        initialBackoff: const Duration(milliseconds: 1),
      );

      final response = await apiClient.send(
        OpenAiApiRequest.json(body: '{"input":"hi"}'),
      );
      final chunks = await response.stream.toList();

      expect(attempts, 2);
      expect(chunks, const [
        [1, 2],
      ]);
    });

    test('retrying api client does not retry auth failure', () async {
      var attempts = 0;
      final apiClient = OpenAiRetryingApiClient(
        inner: _CallbackApiClient(() async {
          attempts++;
          throw const OpenAiTransportException(
            statusCode: 401,
            message: 'unauthorized',
          );
        }),
        maxRetries: 3,
      );

      await expectLater(
        () async {
          await apiClient.send(OpenAiApiRequest.json(body: '{"input":"hi"}'));
        },
        throwsA(isA<OpenAiTransportException>()),
      );
      expect(attempts, 1);
    });

    test('maps transport timeout to timeout error code', () async {
      final engine = OpenAiTtsEngine(
        apiClient: const _FailApiClient(
          OpenAiTransportException(statusCode: 408, message: 'timeout'),
        ),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o3', text: 'hello'),
              TtsControlToken(),
              TtsAudioSpec(format: TtsAudioFormat.mp3),
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

    test('fromClientConfig maps 401 response to authFailed', () async {
      final client = MockClient(
        (request) async => http.Response('unauthorized', 401),
      );
      final engine = OpenAiTtsEngine.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: ''),
        httpClient: client,
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o4', text: 'hello'),
              TtsControlToken(),
              TtsAudioSpec(format: TtsAudioFormat.mp3),
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

    test('engine subclass can parse JSON-envelope response with base64 audio',
        () async {
      final audioBytes = Uint8List.fromList([10, 20, 30, 40, 50]);
      final jsonBody = jsonEncode({'audio': base64Encode(audioBytes)});

      final engine = _JsonEnvelopeEngine(
        apiClient: _SuccessApiClient(
          streamChunks: [utf8.encode(jsonBody)],
        ),
      );

      final chunks = await engine
          .synthesize(
            const TtsRequest(requestId: 'j1', text: 'hello'),
            TtsControlToken(),
            TtsAudioSpec(format: TtsAudioFormat.mp3),
          )
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.bytes, audioBytes);
      expect(chunks.single.isLastChunk, isTrue);
    });
  });
}

final class _SuccessApiClient implements OpenAiApiClient {
  const _SuccessApiClient({this.streamChunks});

  final List<List<int>>? streamChunks;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) async {
    final chunks = streamChunks ??
        [
          Uint8List.fromList(List<int>.generate(10, (i) => i)),
        ];
    return _streamedResponse(chunks);
  }
}

final class _FailApiClient implements OpenAiApiClient {
  const _FailApiClient(this.error);

  final Exception error;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) {
    return Future<http.StreamedResponse>.error(error);
  }
}

final class _CallbackApiClient implements OpenAiApiClient {
  const _CallbackApiClient(this.callback);

  final Future<http.StreamedResponse> Function() callback;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) {
    return callback();
  }
}

http.StreamedResponse _streamedResponse(
  List<List<int>> chunks, {
  int statusCode = 200,
}) {
  return http.StreamedResponse(
    Stream<List<int>>.fromIterable(chunks),
    statusCode,
  );
}

/// Engine subclass that parses {"audio": "<base64>"} JSON envelopes.
final class _JsonEnvelopeEngine extends OpenAiTtsEngine {
  _JsonEnvelopeEngine({required super.apiClient});

  @override
  Stream<List<int>> parseSuccessResponse(
    http.StreamedResponse response,
    TtsRequest request,
    TtsAudioFormat resolvedFormat,
  ) async* {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      builder.add(chunk);
    }
    final body =
        jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, Object?>;
    yield base64Decode(body['audio'] as String);
  }
}
