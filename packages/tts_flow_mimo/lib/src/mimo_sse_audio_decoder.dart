import 'dart:convert';
import 'dart:typed_data';

/// Decodes MiMo's Server-Sent Events into raw PCM audio chunks.
///
/// Input boundaries are transport-dependent, so this parser buffers text until
/// an SSE event boundary is available and also processes a final unterminated
/// event when the response stream closes.
final class MimoSseAudioDecoder {
  const MimoSseAudioDecoder();

  Stream<Uint8List> decode(Stream<List<int>> stream) async* {
    var buffered = '';
    await for (final text in stream.transform(utf8.decoder)) {
      buffered = '$buffered$text'.replaceAll('\r\n', '\n');
      while (true) {
        final boundary = buffered.indexOf('\n\n');
        if (boundary < 0) {
          break;
        }
        final event = buffered.substring(0, boundary);
        buffered = buffered.substring(boundary + 2);
        final audio = _decodeEvent(event);
        if (audio != null) {
          yield audio;
        }
      }
    }

    if (buffered.trim().isNotEmpty) {
      final audio = _decodeEvent(buffered);
      if (audio != null) {
        yield audio;
      }
    }
  }

  Uint8List? _decodeEvent(String event) {
    final data = event
        .split('\n')
        .where((line) => line.startsWith('data:'))
        .map((line) => line.substring(5).trim())
        .join('\n');
    if (data.isEmpty || data == '[DONE]') {
      return null;
    }

    final payload = jsonDecode(data);
    if (payload is! Map<String, Object?>) {
      throw const FormatException('MiMo SSE event must contain a JSON object.');
    }
    final choices = payload['choices'];
    if (choices is! List<Object?> || choices.isEmpty) {
      return null;
    }
    final firstChoice = choices.first;
    if (firstChoice is! Map<String, Object?>) {
      return null;
    }
    final delta = firstChoice['delta'];
    if (delta is! Map<String, Object?>) {
      return null;
    }
    final audio = delta['audio'];
    if (audio is! Map<String, Object?>) {
      return null;
    }
    final encoded = audio['data'];
    if (encoded is! String || encoded.isEmpty) {
      return null;
    }
    return base64Decode(encoded);
  }
}
