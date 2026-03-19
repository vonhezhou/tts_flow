import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';
import 'package:test/test.dart';

void main() {
  group('M4 memory output', () {
    test('returns bytes and resolved format', () async {
      final output = MemoryOutput();
      const session = TtsOutputSession(
        requestId: 'mem-1',
        resolvedFormat: TtsAudioFormat.wav,
      );

      await output.initSession(session);
      await output.consumeChunk(_chunk('mem-1', 0, [1, 2], TtsAudioFormat.wav));
      await output.consumeChunk(
          _chunk('mem-1', 1, [3], TtsAudioFormat.wav, isLast: true));
      final artifact = await output.finalizeSession();

      expect(artifact, isA<MemoryOutputArtifact>());
      final mem = artifact as MemoryOutputArtifact;
      expect(mem.requestId, 'mem-1');
      expect(mem.resolvedFormat, TtsAudioFormat.wav);
      expect(mem.totalBytes, 3);
      expect(mem.audioBytes, Uint8List.fromList([1, 2, 3]));
    });

    test('isolates bytes across sessions', () async {
      final output = MemoryOutput();

      await output.initSession(
        const TtsOutputSession(
            requestId: 'a', resolvedFormat: TtsAudioFormat.mp3),
      );
      await output.consumeChunk(
          _chunk('a', 0, [8, 8], TtsAudioFormat.mp3, isLast: true));
      final first = await output.finalizeSession() as MemoryOutputArtifact;

      await output.initSession(
        const TtsOutputSession(
            requestId: 'b', resolvedFormat: TtsAudioFormat.wav),
      );
      await output
          .consumeChunk(_chunk('b', 0, [7], TtsAudioFormat.wav, isLast: true));
      final second = await output.finalizeSession() as MemoryOutputArtifact;

      expect(first.audioBytes, Uint8List.fromList([8, 8]));
      expect(second.audioBytes, Uint8List.fromList([7]));
    });
  });

  group('M4 file output', () {
    test('writes temp file then finalizes atomically', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('uni_tts_file_output_');
      try {
        final output = FileOutput(outputDirectory: tempDir);
        const session = TtsOutputSession(
          requestId: 'file-1',
          resolvedFormat: TtsAudioFormat.mp3,
        );

        await output.initSession(session);
        await output
            .consumeChunk(_chunk('file-1', 0, [1, 2, 3], TtsAudioFormat.mp3));
        await output.consumeChunk(
          _chunk('file-1', 1, [4, 5], TtsAudioFormat.mp3, isLast: true),
        );

        final artifact = await output.finalizeSession();
        expect(artifact, isA<FileOutputArtifact>());

        final fileArtifact = artifact as FileOutputArtifact;
        expect(fileArtifact.requestId, 'file-1');
        expect(fileArtifact.resolvedFormat, TtsAudioFormat.mp3);
        expect(await File(fileArtifact.filePath).exists(), isTrue);
        expect(
            await File(fileArtifact.filePath).readAsBytes(), [1, 2, 3, 4, 5]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('onStop cleans up temp file', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('uni_tts_file_output_stop_');
      try {
        final output = FileOutput(outputDirectory: tempDir);
        const session = TtsOutputSession(
          requestId: 'file-2',
          resolvedFormat: TtsAudioFormat.wav,
        );

        await output.initSession(session);
        await output
            .consumeChunk(_chunk('file-2', 0, [9, 9], TtsAudioFormat.wav));
        await output.onStop('test-stop');

        final tempFiles = tempDir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.tmp'))
            .toList();
        expect(tempFiles, isEmpty);

        final finalPath = '${tempDir.path}${Platform.pathSeparator}file-2.wav';
        expect(await File(finalPath).exists(), isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('M4 composite output', () {
    test('bestEffort finalizes successful outputs and records failures',
        () async {
      final output = CompositeOutput(
        outputs: [
          MemoryOutput(outputId: 'memory'),
          _FailingTestOutput(outputId: 'failing', failOnConsume: true),
        ],
        errorPolicy: CompositeOutputErrorPolicy.bestEffort,
      );

      const session = TtsOutputSession(
        requestId: 'composite-1',
        resolvedFormat: TtsAudioFormat.wav,
      );

      await output.initSession(session);
      await output.consumeChunk(
        _chunk('composite-1', 0, [1, 2, 3], TtsAudioFormat.wav, isLast: true),
      );
      final artifact = await output.finalizeSession();

      expect(artifact, isA<CompositeOutputArtifact>());
      final composite = artifact as CompositeOutputArtifact;
      expect(composite.artifacts.keys, contains('memory'));
      expect(composite.artifacts.keys, isNot(contains('failing')));
      expect(composite.outputErrors.keys, contains('failing'));
    });

    test('failFast throws TtsOutputFailure with output id', () async {
      final output = CompositeOutput(
        outputs: [
          MemoryOutput(outputId: 'memory'),
          _FailingTestOutput(outputId: 'failing', failOnConsume: true),
        ],
        errorPolicy: CompositeOutputErrorPolicy.failFast,
      );

      const session = TtsOutputSession(
        requestId: 'composite-2',
        resolvedFormat: TtsAudioFormat.wav,
      );

      await output.initSession(session);
      await expectLater(
        output.consumeChunk(
          _chunk('composite-2', 0, [5], TtsAudioFormat.wav, isLast: true),
        ),
        throwsA(
          isA<TtsOutputFailure>().having(
            (failure) => failure.outputId,
            'outputId',
            'failing',
          ),
        ),
      );
    });
  });
}

final class _FailingTestOutput implements TtsOutput {
  _FailingTestOutput({
    required this.outputId,
    this.failOnConsume = false,
  });

  @override
  final String outputId;
  final bool failOnConsume;

  @override
  Set<TtsAudioFormat> get acceptedFormats => {TtsAudioFormat.wav};

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    if (failOnConsume) {
      throw const TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Injected consume failure.',
      );
    }
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<TtsOutputArtifact> finalizeSession() async {
    throw UnimplementedError();
  }

  @override
  Future<void> initSession(TtsOutputSession session) async {}

  @override
  Future<void> onPause() async {}

  @override
  Future<void> onResume() async {}

  @override
  Future<void> onStop(String reason) async {}
}

TtsChunk _chunk(
  String requestId,
  int seq,
  List<int> bytes,
  TtsAudioFormat format, {
  bool isLast = false,
}) {
  return TtsChunk(
    requestId: requestId,
    sequenceNumber: seq,
    bytes: Uint8List.fromList(bytes),
    format: format,
    isLastChunk: isLast,
    timestamp: DateTime.now().toUtc(),
  );
}
