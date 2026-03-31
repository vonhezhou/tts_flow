import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter_example/xiaomi_tts.dart';

void main() {
  group('XiaomiTts', () {
    test('builds Xiaomi endpoint, headers, and body contract', () {
      final engine = XiaomiTts.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: 'test-key'),
      );

      final request = const TtsRequest(requestId: 'r1', text: 'hello xiaomi');
      final apiRequest = engine.buildApiRequest(
        request,
        const TtsAudioSpec.mp3(),
      );
      final body =
          jsonDecode(utf8.decode(apiRequest.bodyBytes)) as Map<String, dynamic>;

      expect(apiRequest.endpoint, XiaomiTts.xiaomiEndpoint);
      expect(apiRequest.headers['Authorization'], 'Bearer test-key');
      expect(body['model'], XiaomiTts.xiaomiModel);
      expect(body['stream'], isTrue);

      final messages = body['messages'] as List<dynamic>;
      expect(messages, hasLength(1));
      expect(messages.first, <String, dynamic>{
        'role': 'assistant',
        'content': 'hello xiaomi',
      });

      final audio = body['audio'] as Map<String, dynamic>;
      expect(audio['format'], 'mp3');
      expect(audio['voice'], XiaomiTts.xiaomiDefaultVoice);
    });

    test('supports mp3 and wav (pcm) format mapping', () {
      final engine = XiaomiTts.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: 'test-key'),
      );

      expect(engine.mapFormat(TtsAudioFormat.mp3), 'mp3');
      expect(engine.mapFormat(TtsAudioFormat.pcm), 'wav');
      expect(engine.outAudioCapabilities.contains(PcmCapability.wav()), isTrue);
    });

    test('parses streamed audio chunks and stops on done marker', () async {
      final engine = XiaomiTts.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: 'test-key'),
      );
      final request = const TtsRequest(requestId: 'r2', text: 'stream me');

      final streamedResponse = http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: {"choices":[{"delta":{"audio":{"data":"AQID"}}}]}\n',
          ),
          utf8.encode('{"choices":[{"delta":{"audio":{"data":"BA=="}}}]}\n'),
          utf8.encode('data: [DONE]\n'),
          utf8.encode(
            'data: {"choices":[{"delta":{"audio":{"data":"BQ=="}}}]}\n',
          ),
        ]),
        200,
      );

      final chunks = await engine
          .parseSuccessResponse(streamedResponse, request, TtsAudioFormat.mp3)
          .toList();

      expect(chunks, hasLength(2));
      expect(chunks.first, <int>[1, 2, 3]);
      expect(chunks.last, <int>[4]);
    });

    test('uses explicit voice when request specifies one', () {
      final engine = XiaomiTts.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: 'test-key'),
      );

      final request = const TtsRequest(
        requestId: 'r3',
        text: 'voice override',
        voice: TtsVoice(voiceId: 'custom_voice'),
      );

      final apiRequest = engine.buildApiRequest(
        request,
        const TtsAudioSpec.mp3(),
      );
      final body =
          jsonDecode(utf8.decode(apiRequest.bodyBytes)) as Map<String, dynamic>;
      final audio = body['audio'] as Map<String, dynamic>;

      expect(audio['voice'], 'custom_voice');
    });

    test('strips wav header when pcm is requested', () async {
      final engine = XiaomiTts.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: 'test-key'),
      );
      final request = const TtsRequest(requestId: 'r4', text: 'pcm stream');

      final wavPayload = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final wavHeader = WavHeader.fromPcmDescriptor(
        const PcmDescriptor(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
          encoding: PcmEncoding.signedInt,
        ),
        dataLengthBytes: wavPayload.length,
      ).toBytes();

      final combined = Uint8List.fromList([...wavHeader, ...wavPayload]);
      final streamedResponse = http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          utf8.encode(
            'data: {"choices":[{"delta":{"audio":{"data":"${base64Encode(combined)}"}}}]}\n',
          ),
          utf8.encode('data: [DONE]\n'),
        ]),
        200,
      );

      final chunks = await engine
          .parseSuccessResponse(streamedResponse, request, TtsAudioFormat.pcm)
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.single, wavPayload);
    });
  });
}
