import 'dart:typed_data';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';
import 'package:test/test.dart';

void main() {
  group('M1 contracts', () {
    test('fake engine emits one chunk when chunkCount is 1', () async {
      final engine = FakeTtsEngine(
        engineId: 'fake-engine',
        supportsStreaming: false,
        chunkCount: 1,
      );

      final request = TtsRequest(requestId: 'r1', text: 'hello world');
      final control = TtsControlToken();

      final chunks = await engine
          .synthesize(
              request, control, TtsAudioSpec(format: TtsAudioFormat.wav))
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.first.sequenceNumber, 0);
      expect(chunks.first.isLastChunk, isTrue);
      expect(chunks.first.audioSpec.format, TtsAudioFormat.wav);
    });

    test('fake engine emits multiple ordered chunks', () async {
      final engine = FakeTtsEngine(
        engineId: 'fake-engine',
        supportsStreaming: true,
        chunkCount: 3,
      );

      final request = TtsRequest(requestId: 'r2', text: 'chunk me please');
      final control = TtsControlToken();

      final chunks = await engine
          .synthesize(
              request, control, TtsAudioSpec(format: TtsAudioFormat.mp3))
          .toList();

      expect(chunks.length, greaterThanOrEqualTo(2));
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].sequenceNumber, i);
        expect(chunks[i].audioSpec.format, TtsAudioFormat.mp3);
      }
      expect(chunks.last.isLastChunk, isTrue);
    });

    test('fake output returns memory artifact with resolved format', () async {
      final output = FakeTtsOutput();
      const session = TtsOutputSession(
        requestId: 'r3',
        audioSpec: TtsAudioSpec(format: TtsAudioFormat.pcm),
      );

      await output.initSession(session);
      await output.consumeChunk(
        TtsChunk(
          requestId: 'r3',
          sequenceNumber: 0,
          bytes: Uint8List.fromList([1, 2, 3]),
          audioSpec: TtsAudioSpec(format: TtsAudioFormat.pcm),
          isLastChunk: true,
          timestamp: DateTime.now().toUtc(),
        ),
      );

      final artifact = await output.finalizeSession();
      expect(artifact, isA<MemoryOutputArtifact>());

      final memoryArtifact = artifact as MemoryOutputArtifact;
      expect(memoryArtifact.requestId, 'r3');
      expect(memoryArtifact.audioSpec.format, TtsAudioFormat.pcm);
      expect(memoryArtifact.totalBytes, 3);
    });

    test('wav header round-trips 16-bit signed PCM WAV header', () {
      const descriptor = PcmDescriptor(
        sampleRateHz: 24000,
        bitsPerSample: 16,
        channels: 1,
        encoding: PcmEncoding.signedInt,
      );

      final wavHeader = WavHeader.fromPcmDescriptor(
        descriptor,
        dataLengthBytes: 9600,
      );
      final parsed = WavHeader.parse(wavHeader.toBytes());

      expect(parsed.toPcmDescriptor(), descriptor);
      expect(parsed.dataLengthBytes, 9600);
    });

    test('wav header parses 8-bit PCM as unsigned', () {
      const descriptor = PcmDescriptor(
        sampleRateHz: 44100,
        bitsPerSample: 8,
        channels: 2,
        encoding: PcmEncoding.unsignedInt,
      );

      final wavHeader = WavHeader.fromPcmDescriptor(
        descriptor,
        dataLengthBytes: 1000,
      );
      final parsed = WavHeader.parse(wavHeader.toBytes());

      expect(parsed.sampleRateHz, 44100);
      expect(parsed.bitsPerSample, 8);
      expect(parsed.channels, 2);
      expect(parsed.encoding, PcmEncoding.unsignedInt);
      expect(parsed.dataLengthBytes, 1000);
    });

    test('wav header round-trips float PCM WAV header', () {
      const descriptor = PcmDescriptor(
        sampleRateHz: 48000,
        bitsPerSample: 32,
        channels: 2,
        encoding: PcmEncoding.float,
      );

      final wavHeader = WavHeader.fromPcmDescriptor(
        descriptor,
        dataLengthBytes: 4096,
      );
      final parsed = WavHeader.parse(wavHeader.toBytes());

      expect(parsed.toPcmDescriptor(), descriptor);
      expect(parsed.dataLengthBytes, 4096);
    });

    test('wav header parser rejects non-wav bytes', () {
      final invalid = Uint8List(44);
      expect(
        () => WavHeader.parse(invalid),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
