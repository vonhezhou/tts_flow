import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/src/decoder/decoder_output.dart';

class _MockTtsOutput extends Mock implements TtsOutput {}

class _FakeTtsChunk extends Fake implements TtsChunk {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeTtsChunk());
    WidgetsFlutterBinding.ensureInitialized();
  });

  group('Decoder', () {
    late _MockTtsOutput mockOutput;
    late Decoder decoder;

    setUp(() {
      mockOutput = _MockTtsOutput();
      decoder = Decoder(
        outputId: 'decoder',
        output: mockOutput,
      );
    });

    test('constructor sets outputId and output', () {
      expect(decoder.outputId, 'decoder');
      expect(decoder.output, mockOutput);
    });

    group('inAudioCapabilities', () {
      test(
        'returns default capabilities when output has no PCM capabilities',
        () {
          when(() => mockOutput.inAudioCapabilities).thenReturn({
            const Mp3Capability(),
            const OpusCapability(),
          });

          final capabilities = decoder.inAudioCapabilities;

          expect(capabilities, contains(isA<PcmCapability>()));
          expect(capabilities, contains(const Mp3Capability()));
          expect(capabilities, contains(const OpusCapability()));
          expect(capabilities, contains(const AacCapability()));
        },
      );

      test('intersects PCM capabilities with output', () {
        when(() => mockOutput.inAudioCapabilities).thenReturn({
          PcmCapability(
            sampleRatesHz: {16000, 22050},
            bitsPerSample: {16},
            channels: {1},
          ),
          const Mp3Capability(),
        });

        final capabilities = decoder.inAudioCapabilities;
        final pcmCapability = capabilities.whereType<PcmCapability>().first;

        expect(pcmCapability.sampleRatesHz, contains(16000));
        expect(pcmCapability.sampleRatesHz, contains(22050));
        expect(pcmCapability.bitsPerSample, contains(16));
        expect(pcmCapability.channels, contains(1));
      });

      test('returns empty intersection when no common capabilities', () {
        when(() => mockOutput.inAudioCapabilities).thenReturn({
          PcmCapability(
            sampleRatesHz: {8000},
            bitsPerSample: {8},
            channels: {1},
          ),
        });

        final capabilities = decoder.inAudioCapabilities;
        final pcmCapability = capabilities.whereType<PcmCapability>().first;

        expect(pcmCapability.sampleRatesHz, contains(8000));
      });
    });

    group('init', () {
      test('calls output.init()', () async {
        when(() => mockOutput.init()).thenAnswer((_) async {});

        await decoder.init();

        verify(() => mockOutput.init()).called(1);
      });
    });

    group('consumeChunk', () {
      test('throws when session not initialized', () async {
        final chunk = TtsChunk(
          requestId: 'test-request',
          sequenceNumber: 0,
          bytes: Uint8List.fromList([1, 2, 3]),
          audioSpec: const TtsAudioSpec.mp3(),
          isLastChunk: false,
          timestamp: DateTime.now(),
        );

        expect(
          () => decoder.consumeChunk(chunk),
          throwsStateError,
        );
      });
    });

    group('onCancelSession', () {
      test('calls output.onCancelSession and clears state', () async {
        final control = SynthesisControl();

        when(
          () => mockOutput.onCancelSession(control),
        ).thenAnswer((_) async {});

        await decoder.onCancelSession(control);

        verify(() => mockOutput.onCancelSession(control)).called(1);
      });
    });

    group('dispose', () {
      test('calls output.dispose and clears state', () async {
        when(() => mockOutput.dispose()).thenAnswer((_) async {});

        await decoder.dispose();

        verify(() => mockOutput.dispose()).called(1);
      });
    });
  });
}
