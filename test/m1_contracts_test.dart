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
          .synthesize(request, control, TtsAudioFormat.wav)
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.first.sequenceNumber, 0);
      expect(chunks.first.isLastChunk, isTrue);
      expect(chunks.first.format, TtsAudioFormat.wav);
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
          .synthesize(request, control, TtsAudioFormat.mp3)
          .toList();

      expect(chunks.length, greaterThanOrEqualTo(2));
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].sequenceNumber, i);
        expect(chunks[i].format, TtsAudioFormat.mp3);
      }
      expect(chunks.last.isLastChunk, isTrue);
    });

    test('fake output returns memory artifact with resolved format', () async {
      final output = FakeTtsOutput();
      const session = TtsOutputSession(
        requestId: 'r3',
        resolvedFormat: TtsAudioFormat.pcm16,
      );

      await output.initSession(session);
      await output.consumeChunk(
        TtsChunk(
          requestId: 'r3',
          sequenceNumber: 0,
          bytes: Uint8List.fromList([1, 2, 3]),
          format: TtsAudioFormat.pcm16,
          isLastChunk: true,
          timestamp: DateTime.now().toUtc(),
        ),
      );

      final artifact = await output.finalizeSession();
      expect(artifact, isA<MemoryOutputArtifact>());

      final memoryArtifact = artifact as MemoryOutputArtifact;
      expect(memoryArtifact.requestId, 'r3');
      expect(memoryArtifact.resolvedFormat, TtsAudioFormat.pcm16);
      expect(memoryArtifact.totalBytes, 3);
    });
  });
}
