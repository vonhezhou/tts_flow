
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/src/decoder/decoder_output.dart';

import 'package:flutter/material.dart';

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

    group('acceptedCapabilities', () {
      test('returns default capabilities when output has no PCM capabilities',
          () {
        when(() => mockOutput.acceptedCapabilities).thenReturn({
          const Mp3Capability(),
          const OpusCapability(),
        });

        final capabilities = decoder.acceptedCapabilities;

        expect(capabilities, contains(isA<PcmCapability>()));
        expect(capabilities, contains(const Mp3Capability()));
        expect(capabilities, contains(const OpusCapability()));
        expect(capabilities, contains(const AacCapability()));
      });

      test('intersects PCM capabilities with output', () {
        when(() => mockOutput.acceptedCapabilities).thenReturn({
          PcmCapability(
            sampleRatesHz: {16000, 22050},
            bitsPerSample: {16},
            channels: {1},
          ),
          const Mp3Capability(),
        });

        final capabilities = decoder.acceptedCapabilities;
        final pcmCapability =
            capabilities.whereType<PcmCapability>().first;

        expect(pcmCapability.sampleRatesHz, contains(16000));
        expect(pcmCapability.sampleRatesHz, contains(22050));
        expect(pcmCapability.bitsPerSample, contains(16));
        expect(pcmCapability.channels, contains(1));
      });

      test('returns empty intersection when no common capabilities', () {
        when(() => mockOutput.acceptedCapabilities).thenReturn({
          PcmCapability(
            sampleRatesHz: {8000},
            bitsPerSample: {8},
            channels: {1},
          ),
        });

        final capabilities = decoder.acceptedCapabilities;
        final pcmCapability =
            capabilities.whereType<PcmCapability>().first;

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

    group('initSession', () {
      test('initializes session and negotiates PCM format', () async {
        final session = TtsOutputSession(
          requestId: 'test-request',
          audioSpec: const TtsAudioSpec.mp3(),
          voice: null,
          options: null,
        );

        when(() => mockOutput.acceptedCapabilities).thenReturn({
          PcmCapability(
            sampleRatesHz: {16000, 22050},
            bitsPerSample: {16},
            channels: {1},
          ),
        });
        when(() => mockOutput.initSession(session)).thenAnswer((_) async {});

        await decoder.initSession(session);

        verify(() => mockOutput.initSession(session)).called(1);
      });

      test('uses default PCM format when output has no PCM capabilities',
          () async {
        final session = TtsOutputSession(
          requestId: 'test-request',
          audioSpec: const TtsAudioSpec.mp3(),
          voice: null,
          options: null,
        );

        when(() => mockOutput.acceptedCapabilities).thenReturn({
          const Mp3Capability(),
        });
        when(() => mockOutput.initSession(session)).thenAnswer((_) async {});

        await decoder.initSession(session);

        verify(() => mockOutput.initSession(session)).called(1);
      });
    });

    group('consumeChunk', () {
      test('buffers chunk bytes', () async {
        final session = TtsOutputSession(
          requestId: 'test-request',
          audioSpec: const TtsAudioSpec.mp3(),
          voice: null,
          options: null,
        );

        when(() => mockOutput.acceptedCapabilities).thenReturn({
          PcmCapability(
            sampleRatesHz: {16000},
            bitsPerSample: {16},
            channels: {1},
          ),
        });
        when(() => mockOutput.initSession(session)).thenAnswer((_) async {});

        await decoder.initSession(session);

        final chunk = TtsChunk(
          requestId: 'test-request',
          sequenceNumber: 0,
          bytes: Uint8List.fromList([1, 2, 3]),
          audioSpec: const TtsAudioSpec.mp3(),
          isLastChunk: false,
          timestamp: DateTime.now(),
        );

        await decoder.consumeChunk(chunk);
      });

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

      test('throws when chunk requestId does not match session', () async {
        final session = TtsOutputSession(
          requestId: 'test-request',
          audioSpec: const TtsAudioSpec.mp3(),
          voice: null,
          options: null,
        );

        when(() => mockOutput.acceptedCapabilities).thenReturn({
          PcmCapability(
            sampleRatesHz: {16000},
            bitsPerSample: {16},
            channels: {1},
          ),
        });
        when(() => mockOutput.initSession(session)).thenAnswer((_) async {});

        await decoder.initSession(session);

        final chunk = TtsChunk(
          requestId: 'different-request',
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

    group('finalizeSession', () {
      test('throws when session not initialized', () async {
        expect(
          () => decoder.finalizeSession(),
          throwsStateError,
        );
      });
    });

    group('onCancelSession', () {
      test('calls output.onCancelSession and clears state', () async {
        final control = SynthesisControl();

        when(() => mockOutput.onCancelSession(control))
            .thenAnswer((_) async {});

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


