import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_gemini/tts_flow_gemini.dart';

const _request = TtsRequest(requestKey: 'gemini-offline', text: '你好，TtsFlow。');

String _event(Map<String, Object?> body) => 'data: ${jsonEncode(body)}\r\n\r\n';
String _audio(
  List<int> bytes, {
  String mime = 'audio/L16;codec=pcm;rate=24000',
}) => _event({
  'candidates': [
    {
      'content': {
        'role': 'model',
        'parts': [
          {
            'inlineData': {'mimeType': mime, 'data': base64Encode(bytes)},
          },
        ],
      },
    },
  ],
});
final _stop = _event({
  'candidates': [
    {'finishReason': 'STOP'},
  ],
});

GeminiTtsEngine _engine(String sse, {int status = 200}) {
  final client = _Client(
    (_) async => http.StreamedResponse(
      // Split every byte: also splits UTF-8, CRLF, JSON and base64 boundaries.
      Stream.fromIterable(utf8.encode(sse).map((b) => [b])),
      status,
    ),
  );
  final engine = GeminiTtsEngine(apiKey: 'fake-key', httpClient: client);
  addTearDown(engine.dispose);
  return engine;
}

Future<List<TtsAudioChunk>> _synthesize(
  GeminiTtsEngine engine, {
  SynthesisControl? control,
}) => engine
    .synthesize(
      _request,
      control ?? SynthesisControl(),
      GeminiTtsEngine.audioSpec,
    )
    .cast<TtsAudioChunk>()
    .toList();

Matcher _error(TtsErrorCode code) => throwsA(
  isA<TtsError>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.requestKey, 'requestKey', _request.requestKey),
);

void main() {
  test(
    'default voice is multilingual and locale lookup needs no network',
    () async {
      final engine = _engine('');
      expect((await engine.getDefaultVoice()).voiceId, 'Kore');
      expect((await engine.getDefaultVoiceForLocale('zh-CN')).voiceId, 'Kore');
      expect(
        (await engine.getAvailableVoices(
          locale: 'zh-CN',
        )).map((v) => v.voiceId),
        ['Kore', 'Puck', 'Zephyr'],
      );
      expect(engine.outAudioCapabilities, hasLength(1));
    },
  );

  test('decodes every audio part within a candidate', () async {
    final chunks = await _synthesize(
      _engine(
        _event({
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {
                    'inlineData': {
                      'mimeType': 'audio/L16;rate=24000',
                      'data': 'AQI=',
                    },
                  },
                  {
                    'inlineData': {
                      'mimeType': 'audio/L16;rate=24000',
                      'data': 'AwQ=',
                    },
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        }),
      ),
    );
    expect(chunks.map((c) => c.bytes), [
      [1, 2],
      [3, 4],
    ]);
    expect(chunks.last.isLastChunk, isTrue);
  });

  test('idle HTTP stream deadline maps to timeout', () async {
    final body = StreamController<List<int>>();
    final engine = GeminiTtsEngine(
      apiKey: 'fake-key',
      requestTimeout: const Duration(milliseconds: 10),
      httpClient: _Client((_) async => http.StreamedResponse(body.stream, 200)),
    );
    addTearDown(engine.dispose);
    try {
      await expectLater(_synthesize(engine), _error(TtsErrorCode.timeout));
    } finally {
      await body.close();
    }
  });

  test(
    'SDK sends audio-only request and selected voice with API-key header',
    () async {
      late http.Request captured;
      final engine = GeminiTtsEngine(
        apiKey: 'fake-key',
        httpClient: _Client((r) async {
          captured = r as http.Request;
          return http.StreamedResponse(
            Stream.value(utf8.encode(_audio([1, 2]) + _stop)),
            200,
          );
        }),
      );
      addTearDown(engine.dispose);
      final chunks = await engine
          .synthesize(
            const TtsRequest(
              requestKey: 'voice',
              text: 'Hello',
              voice: TtsVoice(voiceId: 'Puck'),
            ),
            SynthesisControl(),
            GeminiTtsEngine.audioSpec,
          )
          .cast<TtsAudioChunk>()
          .toList();
      expect(
        captured.url.path,
        '/v1beta/models/gemini-3.1-flash-tts-preview:streamGenerateContent',
      );
      expect(captured.url.queryParameters['alt'], 'sse');
      expect(captured.url.queryParameters.containsKey('key'), isFalse);
      expect(captured.headers['x-goog-api-key'], 'fake-key');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['contents'][0]['parts'][0]['text'], 'Hello');
      expect(body['generationConfig']['responseModalities'], ['AUDIO']);
      expect(
        body['generationConfig']['speechConfig']['voiceConfig']['prebuiltVoiceConfig']['voiceName'],
        'Puck',
      );
      expect(chunks.single.isLastChunk, isTrue);
    },
  );

  test(
    'handles fragmented SSE, multiple parts, and usage-only events',
    () async {
      final chunks = await _synthesize(
        _engine(
          _event({
                'usageMetadata': {'totalTokenCount': 1},
              }) +
              _audio([1, 2]) +
              _audio([3, 4]) +
              _stop,
        ),
      );
      expect(chunks.map((c) => c.bytes), [
        [1, 2],
        [3, 4],
      ]);
      expect(chunks.map((c) => c.sequenceNumber), [0, 1]);
      expect(chunks.map((c) => c.isLastChunk), [false, true]);
      expect(
        chunks.every((c) => c.audioSpec == GeminiTtsEngine.audioSpec),
        isTrue,
      );
    },
  );

  test('SDK streams audio before the HTTP body closes', () async {
    final body = StreamController<List<int>>();
    final engine = GeminiTtsEngine(
      apiKey: 'fake-key',
      httpClient: _Client((_) async => http.StreamedResponse(body.stream, 200)),
    );
    addTearDown(engine.dispose);
    final first = Completer<TtsAudioChunk>();
    final done = engine
        .synthesize(_request, SynthesisControl(), GeminiTtsEngine.audioSpec)
        .cast<TtsAudioChunk>()
        .map((c) {
          if (!first.isCompleted) first.complete(c);
          return c;
        })
        .toList();
    body.add(utf8.encode(_audio([1, 2]) + _audio([3, 4])));
    try {
      expect(
        (await first.future.timeout(const Duration(seconds: 2))).isLastChunk,
        isFalse,
      );
    } finally {
      body.add(utf8.encode(_stop));
      await body.close();
    }
    expect((await done).last.isLastChunk, isTrue);
  });

  for (final entry in {
    400: TtsErrorCode.invalidRequest,
    401: TtsErrorCode.authFailed,
    403: TtsErrorCode.authFailed,
    429: TtsErrorCode.networkError,
    500: TtsErrorCode.networkError,
    504: TtsErrorCode.timeout,
  }.entries) {
    test('maps HTTP ${entry.key} without retry', () async {
      var sends = 0;
      final engine = GeminiTtsEngine(
        apiKey: 'fake-key',
        httpClient: _Client((_) async {
          sends++;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'error': {'code': entry.key, 'message': 'test error'},
                }),
              ),
            ),
            entry.key,
          );
        }),
      );
      addTearDown(engine.dispose);
      await expectLater(_synthesize(engine), _error(entry.value));
      expect(sends, 1);
    });
  }

  for (final entry in {
    'WAV container': _audio([1, 2], mime: 'audio/wav') + _stop,
    'wrong sample rate': _audio([1, 2], mime: 'audio/L16;rate=16000') + _stop,
    'odd PCM sample': _audio([1]) + _stop,
    'truncated response': _audio([1, 2]),
    'no audio': _stop,
    'blocked generation': _event({
      'candidates': [
        {'finishReason': 'SAFETY'},
      ],
    }),
    'corrupt base64': _audio([1, 2]).replaceAll('AQI=', '!!!!') + _stop,
  }.entries) {
    test('rejects ${entry.key}', () async {
      await expectLater(
        _synthesize(_engine(entry.value)),
        _error(TtsErrorCode.unsupportedFormat),
      );
    });
  }

  test('rejects unsupported format before calling provider', () async {
    final engine = _engine('');
    await expectLater(
      engine
          .synthesize(_request, SynthesisControl(), const TtsAudioSpec.mp3())
          .toList(),
      _error(TtsErrorCode.formatNegotiationFailed),
    );
  });

  test('cancellation suppresses remaining PCM and completion marker', () async {
    final control = SynthesisControl();
    final chunks = <TtsAudioChunk>[];
    await for (final chunk
        in _engine(_audio([1, 2]) + _audio([3, 4]) + _stop)
            .synthesize(_request, control, GeminiTtsEngine.audioSpec)
            .cast<TtsAudioChunk>()) {
      chunks.add(chunk);
      control.cancel(CancelReason.stopCurrent);
    }
    expect(chunks, hasLength(1));
    expect(chunks.single.isLastChunk, isFalse);
  });

  test('header deadline maps to timeout', () async {
    final engine = GeminiTtsEngine(
      apiKey: 'fake-key',
      requestTimeout: const Duration(milliseconds: 10),
      httpClient: _Client((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.StreamedResponse(const Stream.empty(), 200);
      }),
    );
    addTearDown(engine.dispose);
    await expectLater(_synthesize(engine), _error(TtsErrorCode.timeout));
  });

  test('keeps caller-owned HTTP client open', () async {
    final client = _Client((_) async => throw StateError('unused'));
    final engine = GeminiTtsEngine(apiKey: 'fake-key', httpClient: client);
    await engine.dispose();
    expect(client.closed, isFalse);
  });

  test(
    'TtsFlow negotiates PCM and writes decoded audio to WAV offline',
    () async {
      final dir = await Directory.systemTemp.createTemp('gemini-tts-test-');
      addTearDown(() => dir.delete(recursive: true));
      final output = File('${dir.path}/speech.wav');
      final flow = TtsFlow(
        engine: _engine(_audio([1, 2]) + _audio([3, 4]) + _stop),
        defaultOutput: WavFileOutput(output.path),
      );
      addTearDown(flow.dispose);
      await flow.init();
      final handle = flow.speak('Offline fixture.');
      await handle.chunks.drain<void>();
      final bytes = await output.readAsBytes();
      expect(bytes.sublist(44), [1, 2, 3, 4]);
      expect(
        WavHeader.parse(bytes.sublist(0, 44)).toPcmDescriptor(),
        const PcmDescriptor.s16Mono24KHz(),
      );
    },
  );
}

final class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
  @override
  void close() => closed = true;
}
