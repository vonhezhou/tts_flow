import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('WavHeader', () {
    test('parse rejects unsupported format code', () {
      final bytes = WavHeader(
        sampleRateHz: 16000,
        bitsPerSample: 16,
        channels: 1,
        dataLengthBytes: 160,
      ).toBytes();

      final data = ByteData.sublistView(bytes);
      data.setUint16(20, 6, Endian.little);

      expect(() => WavHeader.parse(bytes), throwsFormatException);
    });

    test('fromPcmDescriptor preserves encoding', () {
      const descriptor = PcmDescriptor(
        sampleRateHz: 48000,
        bitsPerSample: 32,
        channels: 2,
        encoding: PcmEncoding.float,
      );
      final header = WavHeader.fromPcmDescriptor(
        descriptor,
        dataLengthBytes: 3200,
      );

      expect(header.toPcmDescriptor(), descriptor);
      expect(header.blockAlign, 8);
      expect(header.byteRate, 384000);
    });
  });
}
