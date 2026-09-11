import 'dart:convert';

import 'package:test/test.dart';
import 'package:tts_flow_azure/src/azure_speech_components.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  const ssmlBuilder = AzureSsmlBuilder(
    defaultVoiceId: 'default-voice',
    defaultVoiceLocale: 'zh-CN',
  );

  test('builds escaped SSML with optional prosody', () {
    final ssml = ssmlBuilder.build(
      const TtsRequest(
        requestKey: 'request-1',
        text: '"<&\'",',
        voice: TtsVoice(voiceId: 'voice&name', locale: 'en-US'),
        options: TtsOptions(speed: 1.25),
      ),
    );

    expect(ssml, contains('xml:lang="en-US"'));
    expect(ssml, contains('name="voice&amp;name"'));
    expect(ssml, contains('<prosody rate="125%">'));
    expect(ssml, contains('&quot;&lt;&amp;&apos;&quot;,'));
  });

  test('uses defaults without a voice or speed override', () {
    final ssml = ssmlBuilder.build(
      const TtsRequest(requestKey: 'request-2', text: 'plain'),
    );

    expect(ssml, contains('xml:lang="zh-CN"'));
    expect(ssml, contains('name="default-voice"'));
    expect(ssml, isNot(contains('<prosody')));
  });

  test('parses usable Azure voices and marks the configured default', () {
    const parser = AzureSpeechVoiceParser(
      defaultVoiceId: 'zh-CN-XiaoxiaoNeural',
    );

    final voices = parser.parse(
      jsonEncode([
        {
          'ShortName': 'zh-CN-XiaoxiaoNeural',
          'DisplayName': 'Xiaoxiao',
          'Locale': 'zh-CN',
        },
        {'DisplayName': 'Incomplete'},
      ]),
    );

    expect(voices, hasLength(1));
    expect(voices.single.isDefault, isTrue);
    expect(voices.single.locale, 'zh-CN');
  });
}
