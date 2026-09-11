import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tts_flow_azure/tts_flow_azure.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  const config = AzureSpeechConfig(
    subscriptionKey: 'test-key',
    region: 'eastasia',
  );

  test('sends SSML and streams Azure MP3 response bytes', () async {
    late http.BaseRequest captured;
    final engine = AzureSpeechTtsEngine(
      config: config,
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response.bytes([1, 2, 3, 4], 200);
      }),
    );

    final chunks = await engine
        .synthesize(
          const TtsRequest(
            requestKey: 'azure-1',
            text: 'Use <safe> & sound',
            voice: TtsVoice(voiceId: 'en-US-AvaNeural', locale: 'en-US'),
            options: TtsOptions(speed: 1.25),
          ),
          SynthesisControl(),
          const TtsAudioSpec.mp3(),
        )
        .cast<TtsAudioChunk>()
        .toList();

    expect(
      captured.url.toString(),
      'https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1',
    );
    expect(captured.headers['ocp-apim-subscription-key'], 'test-key');
    expect(
      captured.headers['content-type'],
      startsWith('application/ssml+xml'),
    );
    expect(
      captured.headers['x-microsoft-outputformat'],
      'audio-24khz-48kbitrate-mono-mp3',
    );
    final ssml = (captured as http.Request).body;
    expect(ssml, contains('xml:lang="en-US"'));
    expect(ssml, contains('name="en-US-AvaNeural"'));
    expect(ssml, contains('rate="125%"'));
    expect(ssml, contains('Use &lt;safe&gt; &amp; sound'));
    expect(chunks.single.bytes, [1, 2, 3, 4]);
    expect(chunks.single.isLastChunk, isTrue);
  });

  test('loads, caches, and filters the Azure voice list', () async {
    var requests = 0;
    final engine = AzureSpeechTtsEngine(
      config: config,
      httpClient: MockClient((request) async {
        requests++;
        expect(
          request.url.toString(),
          'https://eastasia.tts.speech.microsoft.com/cognitiveservices/voices/list',
        );
        return http.Response(
          jsonEncode([
            {
              'ShortName': 'zh-CN-XiaoxiaoNeural',
              'DisplayName': 'Xiaoxiao',
              'Locale': 'zh-CN',
            },
            {
              'ShortName': 'en-US-AvaNeural',
              'DisplayName': 'Ava',
              'Locale': 'en-US',
            },
          ]),
          200,
        );
      }),
    );

    final chinese = await engine.getAvailableVoices(locale: 'zh');
    final all = await engine.getAvailableVoices();

    expect(chinese.map((voice) => voice.voiceId), ['zh-CN-XiaoxiaoNeural']);
    expect(all, hasLength(2));
    expect(all.first.isDefault, isTrue);
    expect(requests, 1);
  });

  test('maps Azure authorization failures to authFailed', () async {
    final engine = AzureSpeechTtsEngine(
      config: config,
      httpClient: MockClient((_) async => http.Response('denied', 401)),
    );

    await expectLater(
      engine
          .synthesize(
            const TtsRequest(requestKey: 'azure-2', text: 'hello'),
            SynthesisControl(),
            const TtsAudioSpec.mp3(),
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

  test('does not close an application-provided HTTP client', () async {
    final client = _CloseTrackingClient();
    final engine = AzureSpeechTtsEngine(config: config, httpClient: client);

    await engine.dispose();

    expect(client.isClosed, isFalse);
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
