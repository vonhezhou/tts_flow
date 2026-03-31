import 'package:test/test.dart';
import 'package:tts_flow_dart/src/base/text_split.dart';

void main() {
  group('ttsSplitText', () {
    test('should return empty list for empty text', () {
      expect(ttsSplitText('', 100), isEmpty);
    });

    test('should return empty list for maxBytes <= 0', () {
      expect(ttsSplitText('Hello', 0), isEmpty);
      expect(ttsSplitText('Hello', -1), isEmpty);
    });

    test('should return single chunk for text within maxBytes', () {
      const text = 'Hello World';
      const maxBytes = 100;
      final result = ttsSplitText(text, maxBytes);
      expect(result, hasLength(1));
      expect(result.first, equals(text));
    });

    test('should split text into multiple chunks when exceeding maxBytes', () {
      const text = 'Hello World';
      // 'Hello ' is 6 bytes, 'World' is 5 bytes
      const maxBytes = 6;
      final result = ttsSplitText(text, maxBytes);
      expect(result, hasLength(2));
      expect(result[0], equals('Hello '));
      expect(result[1], equals('World'));
    });

    test('should handle HTML entities as single units', () {
      const text = 'Hello &quot;World&quot;';
      // '&quot;' is 6 bytes each
      const maxBytes = 10;
      final result = ttsSplitText(text, maxBytes);
      // 'Hello ' is 6 bytes, '&quot;' is 6 bytes (6+6=12 > 10)
      // So first chunk is 'Hello ', then '&quot;Worl' (6+4=10), then 'd&quot;'
      expect(result, hasLength(3));
      expect(result[0], equals('Hello '));
      expect(result[1], equals('&quot;Worl'));
      expect(result[2], equals('d&quot;'));
    });

    test('should handle complex characters (emojis) as single units', () {
      const text = 'Hello 🌍 World';
      // '🌍' is 4 bytes
      const maxBytes = 8;
      final result = ttsSplitText(text, maxBytes);
      // 'Hello ' is 6 bytes, '🌍' is 4 bytes (6+4=10 > 8)
      // So first chunk is 'Hello ', then '🌍 Wor' (4+4=8), then 'ld'
      expect(result, hasLength(3));
      expect(result[0], equals('Hello '));
      expect(result[1], equals('🌍 Wor'));
      expect(result[2], equals('ld'));
    });

    test('should handle single token exceeding maxBytes', () {
      const text = 'Hello';
      const maxBytes = 2;
      final result = ttsSplitText(text, maxBytes);
      // Each character is 1 byte, so combine as much as possible
      // 'He' is 2 bytes, 'll' is 2 bytes, 'o' is 1 byte
      expect(result, hasLength(3));
      expect(result[0], equals('He'));
      expect(result[1], equals('ll'));
      expect(result[2], equals('o'));
    });

    test('should handle mixed content with entities and emojis', () {
      const text = 'Hello &quot;🌍&quot; World';
      const maxBytes = 15;
      final result = ttsSplitText(text, maxBytes);
      // 'Hello &quot;' is 12 bytes, '🌍' is 4 bytes (12+4=16 > 15)
      // So first chunk is 'Hello &quot;', then '🌍&quot; Worl' (4+6+4=14), then 'd'
      expect(result, hasLength(3));
      expect(result[0], equals('Hello &quot;'));
      expect(result[1], equals('🌍&quot; Worl'));
      expect(result[2], equals('d'));
    });
  });
}
