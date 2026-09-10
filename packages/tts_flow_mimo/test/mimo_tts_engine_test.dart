import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_mimo/tts_flow_mimo.dart';

const _pcm = TtsAudioSpec.pcm(
  PcmDescriptor(sampleRateHz: 24000, bitsPerSample: 16, channels: 1),
);

void main() {
  test(
    'sends MiMo chat-completions PCM stream and decodes audio events',
    () async {
      late http.BaseRequest captured;
      final first = base64Encode([1, 2]);
      final second = base64Encode([3, 4, 5]);
      final client = MockClient((request) async {
        captured = request;
        final body = [
          'data: {"choices":[{"delta":{"audio":{"data":"$first"}}}]}',
          '',
          'data: {"choices":[{"delta":{"audio":{"data":"$second"}}}]}',
          '',
          'data: [DONE]',
          '',
        ].join('\n');
        return http.Response(body, 200);
      });
      final engine = MimoTtsEngine(apiKey: 'secret', httpClient: client);

      final chunks = await engine
          .synthesize(
            const TtsRequest(
              requestKey: 'mimo-1',
              text: '你好',
              voice: TtsVoice(voiceId: '冰糖'),
              params: {'mimoInstruction': '语速稍快'},
            ),
            SynthesisControl(),
            _pcm,
          )
          .cast<TtsAudioChunk>()
          .toList();

      expect(
        captured.url.toString(),
        'https://api.xiaomimimo.com/v1/chat/completions',
      );
      expect(captured.headers['authorization'], 'Bearer secret');
      final payload =
          jsonDecode((captured as http.Request).body) as Map<String, Object?>;
      expect(payload['stream'], isTrue);
      expect((payload['audio'] as Map<String, Object?>)['format'], 'pcm16');
      expect((payload['audio'] as Map<String, Object?>)['voice'], '冰糖');
      expect(payload['messages'], [
        {'role': 'user', 'content': '语速稍快'},
        {'role': 'assistant', 'content': '你好'},
      ]);
      expect(chunks.map((chunk) => chunk.bytes.toList()), [
        [1, 2],
        [3, 4, 5],
      ]);
      expect(chunks.last.isLastChunk, isTrue);
    },
  );

  test('maps an authentication response to authFailed', () async {
    final engine = MimoTtsEngine(
      apiKey: 'bad',
      httpClient: MockClient((_) async => http.Response('denied', 401)),
    );

    await expectLater(
      engine
          .synthesize(
            const TtsRequest(requestKey: 'mimo-2', text: 'hello'),
            SynthesisControl(),
            _pcm,
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
}
