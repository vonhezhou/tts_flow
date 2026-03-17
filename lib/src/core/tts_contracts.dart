import 'dart:async';
import 'dart:typed_data';

import 'tts_errors.dart';
import 'tts_models.dart';

final class TtsServiceConfig {
  const TtsServiceConfig({
    this.preferredFormatOrder = const [
      TtsAudioFormat.mp3,
      TtsAudioFormat.oggOpus,
      TtsAudioFormat.aac,
      TtsAudioFormat.wav,
      TtsAudioFormat.pcm16,
    ],
  });

  final List<TtsAudioFormat> preferredFormatOrder;
}

final class TtsControlToken {
  bool _stopped = false;
  bool _paused = false;

  bool get isStopped => _stopped;
  bool get isPaused => _paused;

  void stop() {
    _stopped = true;
  }

  void pause() {
    _paused = true;
  }

  void resume() {
    _paused = false;
  }
}

final class TtsOutputSession {
  const TtsOutputSession({
    required this.requestId,
    required this.resolvedFormat,
  });

  final String requestId;
  final TtsAudioFormat resolvedFormat;
}

sealed class TtsOutputArtifact {
  const TtsOutputArtifact({
    required this.requestId,
    required this.resolvedFormat,
  });

  final String requestId;
  final TtsAudioFormat resolvedFormat;
}

final class MemoryOutputArtifact extends TtsOutputArtifact {
  const MemoryOutputArtifact({
    required super.requestId,
    required super.resolvedFormat,
    required this.audioBytes,
    required this.totalBytes,
  });

  final Uint8List audioBytes;
  final int totalBytes;
}

final class FileOutputArtifact extends TtsOutputArtifact {
  const FileOutputArtifact({
    required super.requestId,
    required super.resolvedFormat,
    required this.filePath,
    required this.fileSizeBytes,
  });

  final String filePath;
  final int fileSizeBytes;
}

final class SpeakerOutputArtifact extends TtsOutputArtifact {
  const SpeakerOutputArtifact({
    required super.requestId,
    required super.resolvedFormat,
    required this.playbackId,
    required this.playbackDuration,
  });

  final String playbackId;
  final Duration playbackDuration;
}

final class CompositeOutputArtifact extends TtsOutputArtifact {
  CompositeOutputArtifact({
    required super.requestId,
    required super.resolvedFormat,
    required Map<String, TtsOutputArtifact> artifacts,
    required Map<String, TtsError> outputErrors,
  })  : artifacts = Map.unmodifiable(artifacts),
        outputErrors = Map.unmodifiable(outputErrors);

  final Map<String, TtsOutputArtifact> artifacts;
  final Map<String, TtsError> outputErrors;
}

abstract interface class TtsEngine {
  String get engineId;
  bool get supportsStreaming;
  bool get supportsPause;
  Set<TtsAudioFormat> get supportedFormats;

  Stream<TtsChunk> synthesize(
    TtsRequest request,
    TtsControlToken controlToken,
    TtsAudioFormat resolvedFormat,
  );

  Future<void> dispose();
}

abstract interface class TtsOutput {
  String get outputId;
  Set<TtsAudioFormat> get acceptedFormats;

  Future<void> initSession(TtsOutputSession session);
  Future<void> consumeChunk(TtsChunk chunk);
  Future<TtsOutputArtifact> finalizeSession();
  Future<void> onStop(String reason);
  Future<void> dispose();
}

Never throwAsTtsError(Object error, {String? requestId}) {
  if (error is TtsError) {
    throw error;
  }
  throw TtsError(
    code: TtsErrorCode.internalError,
    message: 'Unexpected error during TTS operation.',
    requestId: requestId,
    cause: error,
  );
}
