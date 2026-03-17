import 'dart:io';

import '../core/tts_contracts.dart';
import '../core/tts_errors.dart';
import '../core/tts_models.dart';

final class FileOutput implements TtsOutput {
  FileOutput({
    required Directory outputDirectory,
    this.outputId = 'file-output',
  }) : _outputDirectory = outputDirectory;

  final Directory _outputDirectory;

  @override
  final String outputId;

  @override
  Set<TtsAudioFormat> get acceptedFormats => TtsAudioFormat.values.toSet();

  TtsOutputSession? _session;
  File? _tempFile;
  IOSink? _sink;

  @override
  Future<void> initSession(TtsOutputSession session) async {
    await _outputDirectory.create(recursive: true);
    _session = session;
    final extension = _extensionForFormat(session.resolvedFormat);
    final tempPath =
        '${_outputDirectory.path}${Platform.pathSeparator}${session.requestId}.$extension.tmp';
    _tempFile = File(tempPath);
    _sink = _tempFile!.openWrite();
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    final sink = _sink;
    if (session == null || sink == null) {
      throw StateError('FileOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }

    try {
      sink.add(chunk.bytes);
      await sink.flush();
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed writing chunk to output file.',
        requestId: session.requestId,
        cause: error,
      );
    }
  }

  @override
  Future<TtsOutputArtifact> finalizeSession() async {
    final session = _session;
    final tempFile = _tempFile;
    final sink = _sink;
    if (session == null || tempFile == null || sink == null) {
      throw StateError('FileOutput session is not initialized.');
    }

    try {
      await sink.flush();
      await sink.close();
      final extension = _extensionForFormat(session.resolvedFormat);
      final finalPath =
          '${_outputDirectory.path}${Platform.pathSeparator}${session.requestId}.$extension';
      final targetFile = File(finalPath);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      final moved = await tempFile.rename(finalPath);
      final size = await moved.length();

      _session = null;
      _tempFile = null;
      _sink = null;

      return FileOutputArtifact(
        requestId: session.requestId,
        resolvedFormat: session.resolvedFormat,
        filePath: moved.path,
        fileSizeBytes: size,
      );
    } catch (error) {
      await _safeCleanupTemp();
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed finalizing output file.',
        requestId: session.requestId,
        cause: error,
      );
    }
  }

  @override
  Future<void> onStop(String reason) async {
    await _safeCleanupTemp();
    _session = null;
    _tempFile = null;
    _sink = null;
  }

  @override
  Future<void> dispose() async {
    await _safeCleanupTemp();
    _session = null;
    _tempFile = null;
    _sink = null;
  }

  Future<void> _safeCleanupTemp() async {
    final sink = _sink;
    if (sink != null) {
      try {
        await sink.flush();
      } catch (_) {
        // No-op: cleanup continues.
      }
      try {
        await sink.close();
      } catch (_) {
        // No-op: cleanup continues.
      }
    }

    final tempFile = _tempFile;
    if (tempFile != null && await tempFile.exists()) {
      try {
        await tempFile.delete();
      } catch (_) {
        // No-op: best-effort cleanup.
      }
    }
  }

  String _extensionForFormat(TtsAudioFormat format) {
    switch (format) {
      case TtsAudioFormat.pcm16:
        return 'pcm';
      case TtsAudioFormat.mp3:
        return 'mp3';
      case TtsAudioFormat.wav:
        return 'wav';
      case TtsAudioFormat.oggOpus:
        return 'ogg';
      case TtsAudioFormat.aac:
        return 'aac';
    }
  }
}
