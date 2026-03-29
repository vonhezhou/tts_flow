import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('AdtsFrameHeader', () {
    test('tryParse scans input and extracts sample rate and channels', () {
      final bytes = Uint8List.fromList([
        0x00,
        0x01,
        0xFF,
        0xF1,
        0x50,
        0x80,
        0x00,
        0x00,
        0x00,
      ]);

      final header = AdtsFrameHeader.tryParse(bytes);

      expect(header, isNotNull);
      expect(header!.samplingFrequencyIndex, 4);
      expect(header.sampleRateHz, 44100);
      expect(header.channelConfig, 2);
      expect(header.channelCount, 2);
    });

    test('parse throws when no valid ADTS sync is present', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      expect(() => AdtsFrameHeader.parse(bytes), throwsFormatException);
    });

    test('reserved sampling-frequency index maps to null sampleRateHz', () {
      final bytes = Uint8List.fromList([
        0xFF,
        0xF1,
        0x3C,
        0x40,
        0x00,
        0x00,
        0x00,
      ]);

      final header = AdtsFrameHeader.parse(bytes);
      expect(header.samplingFrequencyIndex, 15);
      expect(header.sampleRateHz, isNull);
      expect(header.channelConfig, 1);
      expect(header.channelCount, 1);
    });

    test('channelCount maps channelConfig 0 to null and 7 to 8', () {
      const unspecified = AdtsFrameHeader(
        samplingFrequencyIndex: 4,
        channelConfig: 0,
      );
      const sevenOne = AdtsFrameHeader(
        samplingFrequencyIndex: 4,
        channelConfig: 7,
      );

      expect(unspecified.channelCount, isNull);
      expect(sevenOne.channelCount, 8);
    });
  });
}
