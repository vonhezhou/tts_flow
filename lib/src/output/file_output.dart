import 'dart:io';

import '../core/tts_contracts.dart';
import '../core/tts_errors.dart';
import '../core/tts_models.dart';

final class FileOutput implements TtsOutput {
  FileOutput({
    required Directory outputDirectory,
    this.outputId = 'file-output',
  })  : _outputDirectory = outputDirectory,
        _state = _FileOutputSessionState();

  final Directory _outputDirectory;
  final _FileOutputSessionState _state;

  @override
  final String outputId;

  @override
  Set<TtsAudioFormat> get acceptedFormats => TtsAudioFormat.values.toSet();

  @override
  Future<void> initSession(TtsOutputSession session) async {
    await _outputDirectory.create(recursive: true);
    _state.init(
      session: session,
      tempFile: _buildTempFile(
        requestId: session.requestId,
        format: session.resolvedFormat,
      ),
    );
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _state.session;
    final sink = _state.sink;
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
    final session = _state.session;
    final tempFile = _state.tempFile;
    final sink = _state.sink;
    if (session == null || tempFile == null || sink == null) {
      throw StateError('FileOutput session is not initialized.');
    }

    try {
      await _state.flushAndCloseSink();
      final extension = _extensionForFormat(session.resolvedFormat);
      final finalPath =
          '${_outputDirectory.path}${Platform.pathSeparator}${session.requestId}.$extension';
      final targetFile = File(finalPath);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      final moved = await tempFile.rename(finalPath);
      final size = await moved.length();

      _state.clear();

      return FileOutputArtifact(
        requestId: session.requestId,
        resolvedFormat: session.resolvedFormat,
        filePath: moved.path,
        fileSizeBytes: size,
      );
    } catch (error) {
      await _state.safeCleanupTemp();
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed finalizing output file.',
        requestId: session.requestId,
        cause: error,
      );
    }
  }

  @override
  Future<void> onPause() async {}

  @override
  Future<void> onResume() async {}

  @override
  Future<void> onStop(String reason) async {
    await _state.safeCleanupTemp();
    _state.clear();
  }

  @override
  Future<void> dispose() async {
    await _state.safeCleanupTemp();
    _state.clear();
  }

  File _buildTempFile({
    required String requestId,
    required TtsAudioFormat format,
  }) {
    final extension = _extensionForFormat(format);
    final tempPath =
        '${_outputDirectory.path}${Platform.pathSeparator}$requestId.$extension.tmp';
    return File(tempPath);
  }

  String _extensionForFormat(TtsAudioFormat format) {
    switch (format) {
      case TtsAudioFormat.pcm:
        return 'pcm';
      case TtsAudioFormat.mp3:
        return 'mp3';
      case TtsAudioFormat.wav:
        return 'wav';
      case TtsAudioFormat.opus:
        return 'ogg';
      case TtsAudioFormat.aac:
        return 'aac';
    }
  }
}

final class _FileOutputSessionState {
  TtsOutputSession? session;
  File? tempFile;
  IOSink? sink;

  void init({required TtsOutputSession session, required File tempFile}) {
    this.session = session;
    this.tempFile = tempFile;
    sink = tempFile.openWrite();
  }

  Future<void> flushAndCloseSink() async {
    final activeSink = sink;
    if (activeSink == null) {
      return;
    }
    await activeSink.flush();
    await activeSink.close();
  }

  Future<void> safeCleanupTemp() async {
    final activeSink = sink;
    if (activeSink != null) {
      try {
        await activeSink.flush();
      } catch (_) {
        // No-op: cleanup continues.
      }
      try {
        await activeSink.close();
      } catch (_) {
        // No-op: cleanup continues.
      }
    }

    final activeTempFile = tempFile;
    if (activeTempFile != null && await activeTempFile.exists()) {
      try {
        await activeTempFile.delete();
      } catch (_) {
        // No-op: best-effort cleanup.
      }
    }
  }

  void clear() {
    session = null;
    tempFile = null;
    sink = null;
  }
}
