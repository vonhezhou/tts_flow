import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_openai/tts_flow_openai.dart';

const _mp3Spec = TtsAudioSpec.mp3();

void main() {
  group('OpenAiTtsEngine', () {
    test('uses the built-in catalog for the configured model', () async {
      final gptEngine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(),
        model: 'gpt-4o-mini-tts',
      );
      final tts1Engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(),
        model: 'tts-1',
      );

      final gptVoices = await gptEngine.getAvailableVoices();
      final tts1Voices = await tts1Engine.getAvailableVoices();

      expect(gptVoices, hasLength(11));
      expect(
        gptVoices.map((voice) => voice.voiceId),
        containsAll(['alloy', 'ash', 'ballad', 'coral', 'echo']),
      );
      expect((await gptEngine.getDefaultVoice()).voiceId, 'alloy');
      expect(tts1Voices, hasLength(6));
      expect(
        tts1Voices.map((voice) => voice.voiceId),
        containsAll(['alloy', 'nova', 'shimmer']),
      );
    });

    test(
      'falls back to the generic voice catalog for an unknown model',
      () async {
        final engine = OpenAiTtsEngine(
          apiClient: _SuccessApiClient(),
          model: 'unknown-model-xyz',
        );

        final voices = await engine.getAvailableVoices();

        expect(voices, isNotEmpty);
        expect(voices.any((voice) => voice.isDefault), isTrue);
      },
    );

    test('reports model-scoped voices and locale defaults', () async {
      final engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(),
        model: 'tts-1',
        voiceCatalogOverrides: {
          'tts-1': const [
            TtsVoice(voiceId: 'en', locale: 'en-US', isDefault: true),
            TtsVoice(voiceId: 'es', locale: 'es-ES'),
          ],
        },
      );

      expect((await engine.getAvailableVoices()), hasLength(2));
      expect((await engine.getDefaultVoiceForLocale('es-MX')).voiceId, 'es');
      expect((await engine.getDefaultVoiceForLocale('fr-FR')).voiceId, 'en');
    });

    test('adapts a streaming response into ordered audio chunks', () async {
      final engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(
          streamChunks: const [
            [0, 1],
            [2, 3, 4],
          ],
        ),
      );

      final chunks = await engine
          .synthesize(
            const TtsRequest(requestKey: 'request-1', text: 'hello'),
            SynthesisControl(),
            _mp3Spec,
          )
          .cast<TtsAudioChunk>()
          .toList();

      expect(chunks.map((chunk) => chunk.sequenceNumber), [0, 1]);
      expect(chunks.last.isLastChunk, isTrue);
      expect(chunks.last.bytes, Uint8List.fromList([2, 3, 4]));
      expect(
        chunks.every((chunk) => chunk.audioSpec.format == TtsAudioFormat.mp3),
        isTrue,
      );
    });

    test('maps transport failures and retries retryable requests', () async {
      final failingEngine = OpenAiTtsEngine(
        apiClient: const _FailApiClient(
          OpenAiTransportException(statusCode: 401, message: 'unauthorized'),
        ),
      );
      await expectLater(
        failingEngine
            .synthesize(
              const TtsRequest(requestKey: 'request-2', text: 'hello'),
              SynthesisControl(),
              _mp3Spec,
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

      var attempts = 0;
      final retrying = OpenAiRetryingApiClient(
        inner: _CallbackApiClient(() async {
          attempts++;
          if (attempts == 1) {
            throw const OpenAiTransportException(
              statusCode: 500,
              message: 'server error',
            );
          }
          return _streamedResponse(const [
            [1],
          ]);
        }),
        maxRetries: 1,
        initialBackoff: Duration.zero,
      );
      await retrying.send(OpenAiApiRequest.json(body: '{}'));
      expect(attempts, 2);
    });

    test('does not retry authentication failures', () async {
      var attempts = 0;
      final retrying = OpenAiRetryingApiClient(
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
        () => retrying.send(OpenAiApiRequest.json(body: '{}')),
        throwsA(isA<OpenAiTransportException>()),
      );
      expect(attempts, 1);
    });

    test('maps transport timeouts to timeout errors', () async {
      final engine = OpenAiTtsEngine(
        apiClient: const _FailApiClient(
          OpenAiTransportException(statusCode: 408, message: 'timeout'),
        ),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestKey: 'request-timeout', text: 'hello'),
              SynthesisControl(),
              _mp3Spec,
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

    test('maps a configured 401 response to authFailed', () async {
      final engine = OpenAiTtsEngine.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: ''),
        httpClient: MockClient((_) async => http.Response('unauthorized', 401)),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestKey: 'request-3', text: 'hello'),
              SynthesisControl(),
              _mp3Spec,
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

    test('supports provider-specific envelope parsing in subclasses', () async {
      final bytes = Uint8List.fromList([7, 8, 9]);
      final engine = _JsonEnvelopeEngine(
        apiClient: _SuccessApiClient(
          streamChunks: [
            utf8.encode(jsonEncode({'audio': base64Encode(bytes)})),
          ],
        ),
      );

      final chunks = await engine
          .synthesize(
            const TtsRequest(requestKey: 'request-4', text: 'hello'),
            SynthesisControl(),
            _mp3Spec,
          )
          .cast<TtsAudioChunk>()
          .toList();
      expect(chunks.single.bytes, bytes);
    });

    test('does not close an application-provided HTTP client', () async {
      final client = _CloseTrackingClient();
      final engine = OpenAiTtsEngine.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: 'test-key'),
        httpClient: client,
      );

      await engine.dispose();

      expect(client.isClosed, isFalse);
    });
  });
}

final class _CloseTrackingClient extends http.BaseClient {
  var isClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnimplementedError();
  }

  @override
  void close() {
    isClosed = true;
  }
}

final class _SuccessApiClient implements OpenAiApiClient {
  const _SuccessApiClient({this.streamChunks});

  final List<List<int>>? streamChunks;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) async {
    return _streamedResponse(
      streamChunks ??
          const [
            <int>[0],
          ],
    );
  }
}

final class _FailApiClient implements OpenAiApiClient {
  const _FailApiClient(this.error);

  final Exception error;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) =>
      Future<http.StreamedResponse>.error(error);
}

final class _CallbackApiClient implements OpenAiApiClient {
  const _CallbackApiClient(this.callback);

  final Future<http.StreamedResponse> Function() callback;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) => callback();
}

http.StreamedResponse _streamedResponse(List<List<int>> chunks) {
  return http.StreamedResponse(Stream<List<int>>.fromIterable(chunks), 200);
}

final class _JsonEnvelopeEngine extends OpenAiTtsEngine {
  _JsonEnvelopeEngine({required super.apiClient});

  @override
  Stream<List<int>> parseSuccessResponse(
    http.StreamedResponse response,
    TtsRequest request,
    TtsAudioFormat resolvedFormat,
  ) async* {
    final bytes = await response.stream.expand((chunk) => chunk).toList();
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    yield base64Decode(body['audio']! as String);
  }
}
