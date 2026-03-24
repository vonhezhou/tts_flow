import 'dart:async';
import 'dart:typed_data';

import 'tts_errors.dart';
import 'tts_models.dart';

enum TtsQueueFailurePolicy {
  /// fail active request and
  /// cancel all pending requests on first failure
  failFast,

  /// skip failed request and continue with next pending request
  continueOnError,
}

enum TtsPauseBufferPolicy {
  /// Buffer chunks received from the engine during a pause and flush them
  /// to the output when the request is resumed.
  buffered,

  /// Pass chunks directly to the output even while paused.
  passthrough,
}

final class TtsServiceConfig {
  const TtsServiceConfig({
    this.preferredFormatOrder = const [
      TtsAudioFormat.mp3,
      TtsAudioFormat.opus,
      TtsAudioFormat.aac,
      TtsAudioFormat.wav,
      TtsAudioFormat.pcm,
    ],
    this.queueFailurePolicy = TtsQueueFailurePolicy.failFast,
    this.pauseBufferPolicy = TtsPauseBufferPolicy.buffered,
    this.pauseBufferMaxBytes = 10 * 1024 * 1024,
  });

  final List<TtsAudioFormat> preferredFormatOrder;
  final TtsQueueFailurePolicy queueFailurePolicy;

  /// Determines how chunks produced by the engine are handled during pause.
  final TtsPauseBufferPolicy pauseBufferPolicy;

  /// Maximum number of bytes to accumulate in the pause buffer before logging
  /// a warning. Chunks continue to buffer beyond this limit and are not
  /// dropped.
  final int pauseBufferMaxBytes;
}

final class TtsControlToken {
  bool _stopped = false;

  bool get isStopped => _stopped;

  void stop() {
    _stopped = true;
  }
}

final class TtsOutputSession {
  const TtsOutputSession({
    required this.requestId,
    required this.audioSpec,
  });

  final String requestId;
  final TtsAudioSpec audioSpec;
}

sealed class TtsOutputArtifact {
  const TtsOutputArtifact({
    required this.requestId,
    required this.audioSpec,
  });

  final String requestId;
  final TtsAudioSpec audioSpec;
}

final class MemoryOutputArtifact extends TtsOutputArtifact {
  const MemoryOutputArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.audioBytes,
    required this.totalBytes,
  });

  final Uint8List audioBytes;
  final int totalBytes;
}

final class FileOutputArtifact extends TtsOutputArtifact {
  const FileOutputArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.filePath,
    required this.fileSizeBytes,
  });

  final String filePath;
  final int fileSizeBytes;
}

final class SpeakerOutputArtifact extends TtsOutputArtifact {
  const SpeakerOutputArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.playbackId,
    required this.playbackDuration,
  });

  final String playbackId;
  final Duration playbackDuration;
}

final class CompositeOutputArtifact extends TtsOutputArtifact {
  CompositeOutputArtifact({
    required super.requestId,
    required super.audioSpec,
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
  Set<TtsAudioFormat> get supportedFormats;

  Stream<TtsChunk> synthesize(
    TtsRequest request,
    TtsControlToken controlToken,
    TtsAudioSpec resolvedFormat,
  );

  /// Called when the service is paused.
  Future<void> onPause();

  /// Called when the service is resumed.
  Future<void> onResume();

  Future<void> dispose();
}

abstract interface class TtsOutput {
  String get outputId;
  Set<TtsAudioFormat> get acceptedFormats;

  Future<void> initSession(TtsOutputSession session);
  Future<void> consumeChunk(TtsChunk chunk);
  Future<TtsOutputArtifact> finalizeSession();

  /// Called when the service is paused.
  Future<void> onPause();

  /// Called when the service is resumed.
  Future<void> onResume();

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
