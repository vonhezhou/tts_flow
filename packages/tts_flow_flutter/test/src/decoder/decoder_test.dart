import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/src/decoder/decoder_output.dart';

class _MockTtsOutput extends Mock implements TtsOutput {}

class _FakeTtsChunk extends Fake implements TtsChunk {}

final class _RecordingConverter {
  Uint8List? receivedInput;
  TtsAudioSpec? receivedInputSpec;
  PcmDescriptor? receivedOutputPcm;

  Future<Uint8List> convertToPcm({
    required Uint8List input,
    required TtsAudioSpec inputSpec,
    required PcmDescriptor outputPcm,
  }) async {
    receivedInput = input;
    receivedInputSpec = inputSpec;
    receivedOutputPcm = outputPcm;
    return Uint8List.fromList([9, 8, 7, 6]);
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeTtsChunk());
    registerFallbackValue(
      const TtsOutputWriteContext(
        requestKey: 'fallback-request',
        audioSpec: TtsAudioSpec.mp3(),
        voice: null,
        options: null,
      ),
    );
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

    group('resolveAudioSpecForTest', () {
      test(
        'returns default capabilities when output has no PCM capabilities',
        () {
          when(() => mockOutput.inAudioCapabilities).thenReturn({
            const Mp3Capability(),
            const OpusCapability(),
          });

          /// should throw

          expect(
            () => decoder.resolveAudioSpecForTest('test-request'),
            throwsA(
              (Object e) =>
                  e is TtsError &&
                  e.code == TtsErrorCode.formatNegotiationFailed,
            ),
          );
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

        final pcmCapability = decoder
            .resolveAudioSpecForTest('test-request')
            .pcm;
        expect(pcmCapability, isNotNull);
        expect(pcmCapability!.sampleRateHz, 22050);
        expect(pcmCapability.bitsPerSample, 16);
        expect(pcmCapability.channels, 1);
      });

      test('returns empty intersection when no common capabilities', () {
        when(() => mockOutput.inAudioCapabilities).thenReturn({
          PcmCapability(
            sampleRatesHz: {8000},
            bitsPerSample: {8},
            channels: {1},
          ),
        });

        final pcmCapability = decoder
            .resolveAudioSpecForTest('test-request')
            .pcm;

        expect(pcmCapability, isNotNull);
        expect(pcmCapability!.sampleRateHz, 8000);
        expect(pcmCapability.bitsPerSample, 8);
        expect(pcmCapability.channels, 1);
      });
    });

    group('init', () {
      test('calls output.init()', () async {
        when(() => mockOutput.init()).thenAnswer((_) async {});

        await decoder.init();

        verify(() => mockOutput.init()).called(1);
      });
    });

    group('writeChunk', () {
      test('throws when session not initialized', () async {
        final chunk = TtsAudioChunk(
          requestKey: 'test-request',
          sequenceNumber: 0,
          bytes: Uint8List.fromList([1, 2, 3]),
          audioSpec: const TtsAudioSpec.mp3(),
          isLastChunk: false,
          timestamp: DateTime.now(),
        );

        expect(
          () => decoder.writeChunk(chunk),
          throwsStateError,
        );
      });

      test(
        'buffers encoded chunks and converts their complete payload once',
        () async {
          final converter = _RecordingConverter();
          decoder = Decoder(
            outputId: 'decoder',
            output: mockOutput,
            converter: converter.convertToPcm,
          );
          const outputPcm = PcmDescriptor(
            sampleRateHz: 24000,
            bitsPerSample: 16,
            channels: 1,
          );
          when(() => mockOutput.inAudioCapabilities).thenReturn({
            PcmCapability(
              sampleRatesHz: {outputPcm.sampleRateHz},
              bitsPerSample: {outputPcm.bitsPerSample},
              channels: {outputPcm.channels},
              encodings: {outputPcm.encoding},
            ),
          });
          when(() => mockOutput.startWrite(any())).thenAnswer((_) async {});
          when(() => mockOutput.writeChunk(any())).thenAnswer((_) async {});
          when(() => mockOutput.finishWrite()).thenAnswer(
            (_) async => InMemoryAudioArtifact(
              requestKey: 'request-1',
              audioSpec: const TtsAudioSpec.pcm(outputPcm),
              audioBytes: Uint8List(0),
              totalBytes: 0,
            ),
          );

          await decoder.startWrite(
            const TtsOutputWriteContext(
              requestKey: 'request-1',
              audioSpec: TtsAudioSpec.mp3(),
              voice: null,
              options: null,
            ),
          );
          await decoder.writeChunk(
            TtsAudioChunk(
              requestKey: 'request-1',
              sequenceNumber: 0,
              bytes: Uint8List.fromList([1, 2]),
              audioSpec: const TtsAudioSpec.mp3(),
              isLastChunk: false,
              timestamp: DateTime(2026),
            ),
          );
          await decoder.writeChunk(
            TtsAudioChunk(
              requestKey: 'request-1',
              sequenceNumber: 1,
              bytes: Uint8List.fromList([3, 4]),
              audioSpec: const TtsAudioSpec.mp3(),
              isLastChunk: true,
              timestamp: DateTime(2026, 1, 1, 0, 0, 1),
            ),
          );

          verifyNever(() => mockOutput.writeChunk(any()));
          await decoder.finishWrite();

          expect(converter.receivedInput, Uint8List.fromList([1, 2, 3, 4]));
          expect(converter.receivedInputSpec, const TtsAudioSpec.mp3());
          expect(converter.receivedOutputPcm, outputPcm);
          final written =
              verify(() => mockOutput.writeChunk(captureAny())).captured.single
                  as TtsAudioChunk;
          expect(written.bytes, Uint8List.fromList([9, 8, 7, 6]));
          expect(written.audioSpec, const TtsAudioSpec.pcm(outputPcm));
          expect(written.sequenceNumber, 1);
          expect(written.isLastChunk, isTrue);
        },
      );

      test(
        'rejects encoded input beyond its bounded conversion buffer',
        () async {
          decoder = Decoder(
            outputId: 'decoder',
            output: mockOutput,
            maxBufferedBytes: 3,
          );
          when(() => mockOutput.inAudioCapabilities).thenReturn({
            PcmCapability.wav(),
          });
          when(() => mockOutput.startWrite(any())).thenAnswer((_) async {});

          await decoder.startWrite(
            const TtsOutputWriteContext(
              requestKey: 'request-1',
              audioSpec: TtsAudioSpec.mp3(),
              voice: null,
              options: null,
            ),
          );

          await expectLater(
            decoder.writeChunk(
              TtsAudioChunk(
                requestKey: 'request-1',
                sequenceNumber: 0,
                bytes: Uint8List.fromList([1, 2, 3, 4]),
                audioSpec: const TtsAudioSpec.mp3(),
                isLastChunk: true,
                timestamp: DateTime(2026),
              ),
            ),
            throwsA(isA<StateError>()),
          );
        },
      );
    });

    group('cancelWrite', () {
      test('calls output.cancelWrite and clears state', () async {
        final control = SynthesisControl();

        when(
          () => mockOutput.cancelWrite(control),
        ).thenAnswer((_) async {});

        await decoder.cancelWrite(control);

        verify(() => mockOutput.cancelWrite(control)).called(1);
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
