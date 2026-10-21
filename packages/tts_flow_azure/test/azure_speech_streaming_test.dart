import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tts_flow_azure/tts_flow_azure.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

const _request = TtsRequest(requestKey: 'azure-offline', text: 'Fixture test.');
const _config = AzureSpeechConfig(
  subscriptionKey: 'fake-key',
  region: 'eastasia',
);

void main() {
  test(
    'preserves HTTP chunks, request identity, sequence, and final marker',
    () async {
      final engine = AzureSpeechTtsEngine(
        config: _config,
        httpClient: _StreamClient(
          (_) async => http.StreamedResponse(
            Stream.fromIterable([
              [1, 2],
              [3],
              [4, 5],
            ]),
            200,
          ),
        ),
      );
      addTearDown(engine.dispose);
      final chunks = await engine
          .synthesize(_request, SynthesisControl(), const TtsAudioSpec.mp3())
          .cast<TtsAudioChunk>()
          .toList();
      expect(chunks.map((c) => c.bytes), [
        [1, 2],
        [3],
        [4, 5],
      ]);
      expect(chunks.map((c) => c.sequenceNumber), [0, 1, 2]);
      expect(chunks.map((c) => c.isLastChunk), [false, false, true]);
      expect(
        chunks.every(
          (c) =>
              c.requestKey == _request.requestKey &&
              c.audioSpec == const TtsAudioSpec.mp3(),
        ),
        isTrue,
      );
    },
  );

  test('emits audio before the HTTP response finishes', () async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    final firstAudio = Completer<TtsAudioChunk>();
    final engine = AzureSpeechTtsEngine(
      config: _config,
      httpClient: _StreamClient(
        (_) async => http.StreamedResponse(body.stream, 200),
      ),
    );
    addTearDown(engine.dispose);
    final finished = engine
        .synthesize(_request, SynthesisControl(), const TtsAudioSpec.mp3())
        .cast<TtsAudioChunk>()
        .map((chunk) {
          if (!firstAudio.isCompleted) firstAudio.complete(chunk);
          return chunk;
        })
        .toList();
    body.add([1, 2]);
    body.add([3, 4]);
    try {
      final chunk = await firstAudio.future.timeout(const Duration(seconds: 2));
      expect(chunk.bytes, [1, 2]);
      expect(chunk.isLastChunk, isFalse);
    } finally {
      await body.close();
    }
    expect((await finished).last.isLastChunk, isTrue);
  });

  test(
    'cancellation suppresses subsequent audio and completion marker',
    () async {
      final control = SynthesisControl();
      Stream<List<int>> body() async* {
        yield [1];
        yield [2];
        control.cancel(CancelReason.stopCurrent);
        yield [3];
      }

      final engine = AzureSpeechTtsEngine(
        config: _config,
        httpClient: _StreamClient(
          (_) async => http.StreamedResponse(body(), 200),
        ),
      );
      addTearDown(engine.dispose);
      final chunks = await engine
          .synthesize(_request, control, const TtsAudioSpec.mp3())
          .cast<TtsAudioChunk>()
          .toList();
      expect(chunks.map((c) => c.bytes), [
        [1],
      ]);
      expect(chunks.single.isLastChunk, isFalse);
    },
  );

  for (final entry in {
    403: TtsErrorCode.authFailed,
    429: TtsErrorCode.networkError,
    500: TtsErrorCode.networkError,
    408: TtsErrorCode.timeout,
    504: TtsErrorCode.timeout,
  }.entries) {
    test('maps HTTP ${entry.key} to ${entry.value.name}', () async {
      final engine = AzureSpeechTtsEngine(
        config: _config,
        httpClient: _StreamClient(
          (_) async => http.StreamedResponse(Stream.value([0xff]), entry.key),
        ),
      );
      addTearDown(engine.dispose);
      await expectLater(
        engine
            .synthesize(_request, SynthesisControl(), const TtsAudioSpec.mp3())
            .toList(),
        throwsA(
          isA<TtsError>()
              .having((e) => e.code, 'code', entry.value)
              .having((e) => e.requestKey, 'requestKey', _request.requestKey),
        ),
      );
    });
  }

  test('request deadline is reported as timeout', () async {
    final response = Completer<http.StreamedResponse>();
    final engine = AzureSpeechTtsEngine(
      config: const AzureSpeechConfig(
        subscriptionKey: 'fake-key',
        region: 'eastasia',
        requestTimeout: Duration(milliseconds: 10),
      ),
      httpClient: _StreamClient((_) => response.future),
    );
    addTearDown(engine.dispose);
    await expectLater(
      engine
          .synthesize(_request, SynthesisControl(), const TtsAudioSpec.mp3())
          .toList(),
      throwsA(
        isA<TtsError>().having((e) => e.code, 'code', TtsErrorCode.timeout),
      ),
    );
  });

  test(
    'unsupported format is rejected without sending an HTTP request',
    () async {
      var sends = 0;
      final engine = AzureSpeechTtsEngine(
        config: _config,
        httpClient: _StreamClient((_) async {
          sends++;
          throw StateError('Unexpected request');
        }),
      );
      addTearDown(engine.dispose);
      await expectLater(
        engine
            .synthesize(
              _request,
              SynthesisControl(),
              TtsAudioSpec.pcm(const PcmDescriptor.s16Mono24KHz()),
            )
            .toList(),
        throwsA(
          isA<TtsError>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.formatNegotiationFailed,
          ),
        ),
      );
      expect(sends, 0);
    },
  );
}

final class _StreamClient extends http.BaseClient {
  _StreamClient(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}
