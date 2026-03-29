import 'package:test/test.dart';
import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/output/capability_intersection.dart';

void main() {
  group('intersectCapabilities – PCM', () {
    test(
      'two unconstrained PcmCapability.wav() produce a valid capability',
      () {
        final result = intersectCapabilities(
          {PcmCapability.wav()},
          {PcmCapability.wav()},
        );

        expect(result, hasLength(1));
        final cap = result.first as PcmCapability;
        // All int constraints remain unconstrained (null = any).
        expect(cap.sampleRatesHz, isNull);
        expect(cap.bitsPerSample, isNull);
        expect(cap.channels, isNull);
        // Encodings are the full set when both sides are unconstrained.
        expect(cap.encodings, containsAll(PcmEncoding.values));
      },
    );

    test('intersects overlapping sample rates', () {
      final left = PcmCapability(sampleRatesHz: {22050, 44100});
      final right = PcmCapability(sampleRatesHz: {44100, 48000});

      final result = intersectCapabilities({left}, {right});

      final cap = result.first as PcmCapability;
      expect(cap.sampleRatesHz, equals({44100}));
    });

    test('returns empty when sample rates do not overlap', () {
      final left = PcmCapability(sampleRatesHz: {22050});
      final right = PcmCapability(sampleRatesHz: {44100});

      expect(intersectCapabilities({left}, {right}), isEmpty);
    });

    test(
      'constrained side wins when the other is unconstrained (sample rate)',
      () {
        final left = PcmCapability(sampleRatesHz: {22050, 44100});
        final right = PcmCapability(); // sampleRatesHz == null

        final result = intersectCapabilities({left}, {right});

        final cap = result.first as PcmCapability;
        expect(cap.sampleRatesHz, equals({22050, 44100}));
      },
    );

    test(
      'constrained side wins when the other is unconstrained (bits per sample)',
      () {
        final left = PcmCapability(bitsPerSample: {16});
        final right = PcmCapability(); // bitsPerSample == null

        final result = intersectCapabilities({left}, {right});

        final cap = result.first as PcmCapability;
        expect(cap.bitsPerSample, equals({16}));
      },
    );

    test(
      'constrained side wins when the other is unconstrained (channels)',
      () {
        final left = PcmCapability(channels: {1});
        final right = PcmCapability(); // channels == null

        final result = intersectCapabilities({left}, {right});

        final cap = result.first as PcmCapability;
        expect(cap.channels, equals({1}));
      },
    );

    test('returns empty when bitsPerSample do not overlap', () {
      final left = PcmCapability(bitsPerSample: {16});
      final right = PcmCapability(bitsPerSample: {32});

      expect(intersectCapabilities({left}, {right}), isEmpty);
    });

    test('intersects encodings', () {
      final left = PcmCapability(
        encodings: {PcmEncoding.signedInt, PcmEncoding.float},
      );
      final right = PcmCapability(
        encodings: {PcmEncoding.float, PcmEncoding.unsignedInt},
      );

      final result = intersectCapabilities({left}, {right});

      final cap = result.first as PcmCapability;
      expect(cap.encodings, equals({PcmEncoding.float}));
    });

    test('returns empty when encodings do not overlap', () {
      final left = PcmCapability(encodings: {PcmEncoding.signedInt});
      final right = PcmCapability(encodings: {PcmEncoding.unsignedInt});

      expect(intersectCapabilities({left}, {right}), isEmpty);
    });

    test('unconstrained encodings expand to full PcmEncoding.values', () {
      final left = PcmCapability(); // encodings == null
      final right = PcmCapability(); // encodings == null

      final result = intersectCapabilities({left}, {right});

      final cap = result.first as PcmCapability;
      expect(cap.encodings, unorderedEquals(PcmEncoding.values));
    });

    test(
      'null encodings intersected with constrained yields the constraint',
      () {
        final left = PcmCapability(); // null
        final right = PcmCapability(encodings: {PcmEncoding.float});

        final result = intersectCapabilities({left}, {right});

        final cap = result.first as PcmCapability;
        expect(cap.encodings, equals({PcmEncoding.float}));
      },
    );
  });

  group('intersectCapabilities – non-PCM formats', () {
    test('mp3 + mp3 yields Mp3Capability', () {
      final result = intersectCapabilities(
        {const Mp3Capability()},
        {const Mp3Capability()},
      );

      expect(result, hasLength(1));
      expect(result.first, isA<Mp3Capability>());
    });

    test('opus + opus yields OpusCapability', () {
      final result = intersectCapabilities(
        {const OpusCapability()},
        {const OpusCapability()},
      );

      expect(result.first, isA<OpusCapability>());
    });

    test('aac + aac yields AacCapability', () {
      final result = intersectCapabilities(
        {const AacCapability()},
        {const AacCapability()},
      );

      expect(result.first, isA<AacCapability>());
    });

    test('mp3 + opus yields empty (no common format)', () {
      final result = intersectCapabilities(
        {const Mp3Capability()},
        {const OpusCapability()},
      );

      expect(result, isEmpty);
    });
  });

  group('intersectCapabilities – mixed format sets', () {
    test('left {mp3, pcm} ∩ right {pcm} = {pcm}', () {
      final result = intersectCapabilities(
        {const Mp3Capability(), PcmCapability.wav()},
        {PcmCapability.wav()},
      );

      expect(result, hasLength(1));
      expect(result.first, isA<PcmCapability>());
    });

    test('left {mp3, opus} ∩ right {mp3, pcm} = {mp3}', () {
      final result = intersectCapabilities(
        {const Mp3Capability(), const OpusCapability()},
        {const Mp3Capability(), PcmCapability.wav()},
      );

      expect(result, hasLength(1));
      expect(result.first, isA<Mp3Capability>());
    });

    test('left {mp3} ∩ right {opus, aac} = empty', () {
      final result = intersectCapabilities(
        {const Mp3Capability()},
        {const OpusCapability(), const AacCapability()},
      );

      expect(result, isEmpty);
    });
  });

  group('intersectCapabilities – edge cases', () {
    test('left empty set yields empty result', () {
      final result = intersectCapabilities({}, {const Mp3Capability()});

      expect(result, isEmpty);
    });

    test('right empty set yields empty result', () {
      final result = intersectCapabilities({const Mp3Capability()}, {});

      expect(result, isEmpty);
    });

    test('both empty sets yield empty result', () {
      expect(intersectCapabilities({}, {}), isEmpty);
    });
  });
}
