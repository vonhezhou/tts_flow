import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('TtsFormatNegotiator', () {
    final negotiator = const TtsFormatNegotiator();

    group('resolvePcmDescriptor', () {
      test('returns null when no PCM capabilities', () {
        final engineCapabilities = {const Mp3Capability()};
        final outputCapabilities = {const OpusCapability()};

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
          preferredSampleRateHz: 24000,
        );

        expect(result, isNull);
      });

      test('returns null when no compatible encodings', () {
        final engineCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };
        final outputCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.unsignedInt},
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
          preferredSampleRateHz: 24000,
        );

        expect(result, isNull);
      });

      test('returns null when no compatible sample rates', () {
        final engineCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };
        final outputCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {48000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
          preferredSampleRateHz: 24000,
        );

        expect(result, isNull);
      });

      test('returns null when no compatible bits per sample', () {
        final engineCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };
        final outputCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000},
            bitsPerSample: {24},
            channels: {1},
          ),
        };

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
          preferredSampleRateHz: 24000,
        );

        expect(result, isNull);
      });

      test('returns null when no compatible channels', () {
        final engineCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };
        final outputCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {2},
          ),
        };

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
          preferredSampleRateHz: 24000,
        );

        expect(result, isNull);
      });

      test('returns descriptor with preferred sample rate', () {
        final engineCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000, 48000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };
        final outputCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000, 48000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
          preferredSampleRateHz: 24000,
        );

        expect(result, isNotNull);
        expect(result!.sampleRateHz, 24000);
        expect(result.bitsPerSample, 16);
        expect(result.channels, 1);
        expect(result.encoding, PcmEncoding.signedInt);
      });

      test('returns descriptor with maximum sample rate when no preferred', () {
        final engineCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000, 48000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };
        final outputCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt},
            sampleRatesHz: {24000, 48000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
        );

        expect(result, isNotNull);
        expect(result!.sampleRateHz, 48000);
        expect(result.bitsPerSample, 16);
        expect(result.channels, 1);
        expect(result.encoding, PcmEncoding.signedInt);
      });

      test('returns descriptor with preferred encoding order', () {
        final engineCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt, PcmEncoding.unsignedInt, PcmEncoding.float},
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };
        final outputCapabilities = {
          PcmCapability(
            encodings: {PcmEncoding.signedInt, PcmEncoding.unsignedInt, PcmEncoding.float},
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
        );

        expect(result, isNotNull);
        expect(result!.encoding, PcmEncoding.signedInt);
      });

      test('returns descriptor with open-ended capabilities', () {
        final engineCapabilities = {PcmCapability()};
        final outputCapabilities = {PcmCapability()};

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
          preferredSampleRateHz: 24000,
        );

        expect(result, isNull);
      });

      test('returns descriptor with mixed open and discrete capabilities', () {
        final engineCapabilities = {
          PcmCapability(
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1},
          ),
        };
        final outputCapabilities = {PcmCapability()};

        final result = negotiator.resolvePcmDescriptor(
          engineCapabilities: engineCapabilities,
          outputCapabilities: outputCapabilities,
          preferredSampleRateHz: 24000,
        );

        expect(result, isNotNull);
        expect(result!.sampleRateHz, 24000);
        expect(result.bitsPerSample, 16);
        expect(result.channels, 1);
      });
    });
  });
}
