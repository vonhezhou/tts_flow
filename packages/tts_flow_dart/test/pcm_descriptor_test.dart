import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('PcmDescriptor', () {
    test('equality includes encoding', () {
      const a = PcmDescriptor(
        sampleRateHz: 24000,
        bitsPerSample: 16,
        channels: 1,
        encoding: PcmEncoding.signedInt,
      );
      const b = PcmDescriptor(
        sampleRateHz: 24000,
        bitsPerSample: 16,
        channels: 1,
        encoding: PcmEncoding.signedInt,
      );
      const c = PcmDescriptor(
        sampleRateHz: 24000,
        bitsPerSample: 16,
        channels: 1,
        encoding: PcmEncoding.float,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
