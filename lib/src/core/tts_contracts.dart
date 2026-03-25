import 'package:tts_flow_dart/src/core/audio_spec.dart';

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
