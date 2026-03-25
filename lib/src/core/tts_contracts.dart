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

/// Reason associated with cancellation of an active synthesis request.
enum CancelReason {
  /// Cancellation requested explicitly via [TtsFlow.stopCurrent].
  stopCurrent,

  /// Cancellation initiated because the service is being disposed.
  serviceDispose,
}

final class TtsFlowConfig {
  const TtsFlowConfig({
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

final class SynthesisControl {
  CancelReason? _cancelReason;
  String? _cancelMessage;

  bool get isCanceled => _cancelReason != null;
  CancelReason? get cancelReason => _cancelReason;
  String? get cancelMessage => _cancelMessage;

  /// Cancels synthesis.
  ///
  /// Cancellation metadata is first-write-wins to keep cancellation cause
  /// stable when multiple callers race to cancel the same request.
  void cancel(CancelReason reason, {String? message}) {
    _cancelReason ??= reason;
    _cancelMessage ??= message;
  }
}

final class TtsOutputSession {
  const TtsOutputSession({
    required this.requestId,
    required this.audioSpec,
    required this.voice,
    required this.options,
    this.params = const {},
  });

  final String requestId;
  final TtsAudioSpec audioSpec;
  final TtsVoice? voice;
  final TtsOptions? options;
  final Map<String, Object> params;
}

sealed class AudioArtifact {
  const AudioArtifact({
    required this.requestId,
    required this.audioSpec,
  });

  final String requestId;
  final TtsAudioSpec audioSpec;
}

final class InMemoryAudioArtifact extends AudioArtifact {
  const InMemoryAudioArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.audioBytes,
    required this.totalBytes,
  });

  final Uint8List audioBytes;
  final int totalBytes;
}

final class FileAudioArtifact extends AudioArtifact {
  const FileAudioArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.filePath,
    required this.fileSizeBytes,
  });

  final String filePath;
  final int fileSizeBytes;
}

final class PlaybackAudioArtifact extends AudioArtifact {
  const PlaybackAudioArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.playbackId,
    required this.playbackDuration,
  });

  final String playbackId;
  final Duration playbackDuration;
}

final class CompositeAudioArtifact extends AudioArtifact {
  CompositeAudioArtifact({
    required super.requestId,
    required super.audioSpec,
    required Map<String, AudioArtifact> artifacts,
    required Map<String, TtsError> outputErrors,
  })  : artifacts = Map.unmodifiable(artifacts),
        outputErrors = Map.unmodifiable(outputErrors);

  final Map<String, AudioArtifact> artifacts;
  final Map<String, TtsError> outputErrors;
}

abstract interface class TtsEngine {
  String get engineId;
  bool get supportsStreaming;
  Set<AudioCapability> get supportedCapabilities;

  /// Returns voices supported by this engine.
  ///
  /// When [locale] is provided, engines should prefer returning voices that
  /// match the locale exactly (for example, en-US) or by language fallback
  /// (for example, en). Engines may return an empty list when no locale match
  /// is available.
  Future<List<TtsVoice>> getAvailableVoices({String? locale});

  /// Returns the engine default voice.
  Future<TtsVoice> getDefaultVoice();

  /// Returns a default voice for [locale] using engine-specific fallback.
  ///
  /// Engines should apply deterministic fallback, such as
  /// exact locale -> language match -> global default voice.
  Future<TtsVoice> getDefaultVoiceForLocale(String locale);

  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  );

  Future<void> dispose();
}

abstract interface class TtsOutput {
  String get outputId;
  Set<AudioCapability> get acceptedCapabilities;

  Future<void> initSession(TtsOutputSession session);
  Future<void> consumeChunk(TtsChunk chunk);
  Future<AudioArtifact> finalizeSession();

  Future<void> onCancel(SynthesisControl control);
  Future<void> dispose();
}

extension TtsEngineCapabilities on TtsEngine {
  bool supportsSpec(TtsAudioSpec spec) {
    for (final capability in supportedCapabilities) {
      if (capability.supports(spec)) {
        return true;
      }
    }
    return false;
  }
}

extension TtsOutputCapabilities on TtsOutput {
  bool acceptsSpec(TtsAudioSpec spec) {
    for (final capability in acceptedCapabilities) {
      if (capability.supports(spec)) {
        return true;
      }
    }
    return false;
  }
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
