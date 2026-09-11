import 'dart:convert';

import 'package:test/test.dart';
import 'package:tts_flow_mimo/src/mimo_sse_audio_decoder.dart';

void main() {
  const decoder = MimoSseAudioDecoder();

  test('decodes fragmented CRLF events and ignores terminal markers', () async {
    final payload = _audioEvent([1, 2, 3]);
    final stream = Stream<List<int>>.fromIterable([
      utf8.encode('data: ${payload.substring(0, 12)}'),
      utf8.encode('${payload.substring(12)}\r\n\r\ndata: [DONE]\r\n\r\n'),
    ]);

    final chunks = await decoder.decode(stream).toList();

    expect(chunks, hasLength(1));
    expect(chunks.single, [1, 2, 3]);
  });

  test(
    'decodes the final event when the stream has no trailing blank line',
    () async {
      final stream = Stream<List<int>>.value(
        utf8.encode('data: ${_audioEvent([4, 5])}'),
      );

      final chunks = await decoder.decode(stream).toList();

      expect(chunks.single, [4, 5]);
    },
  );

  test('ignores non-audio events', () async {
    final stream = Stream<List<int>>.value(
      utf8.encode('data: {"choices":[{"delta":{"content":"ready"}}]}\n\n'),
    );

    await expectLater(decoder.decode(stream), emitsDone);
  });
}

String _audioEvent(List<int> bytes) {
  return jsonEncode({
    'choices': [
      {
        'delta': {
          'audio': {'data': base64Encode(bytes)},
        },
      },
    ],
  });
}
