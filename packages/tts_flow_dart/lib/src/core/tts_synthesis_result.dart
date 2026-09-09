import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';

/// Terminal result of one request's synthesis and output-writing lifecycle.
///
/// This deliberately excludes physical playback completion. A speaker may
/// still have queued device audio after a [TtsSynthesisCompletedResult] is
/// available; use playback events and controls for that separate lifecycle.
sealed class TtsSynthesisResult {
  const TtsSynthesisResult({
    required this.requestKey,
    required this.utteranceId,
  });

  final String requestKey;
  final String utteranceId;
}

/// Synthesis completed and the primary output finalized successfully.
final class TtsSynthesisCompletedResult extends TtsSynthesisResult {
  const TtsSynthesisCompletedResult({
    required super.requestKey,
    required super.utteranceId,
    required this.artifact,
  });

  /// Artifact returned by [TtsOutput.finishWrite].
  final AudioArtifact artifact;
}

/// Synthesis ended before producing an output artifact.
final class TtsSynthesisStoppedResult extends TtsSynthesisResult {
  const TtsSynthesisStoppedResult({
    required super.requestKey,
    required super.utteranceId,
    required this.reason,
  });

  final TtsSynthesisStopReason reason;
}

/// Synthesis or primary-output writing failed.
final class TtsSynthesisFailedResult extends TtsSynthesisResult {
  const TtsSynthesisFailedResult({
    required super.requestKey,
    required super.utteranceId,
    required this.error,
  });

  final TtsError error;
}

/// Why a request ended without a synthesis artifact.
enum TtsSynthesisStopReason {
  /// The caller explicitly stopped this request or the active synthesis.
  requested,

  /// The caller removed this still-pending request with [TtsFlow.clearQueue].
  queueCleared,

  /// A different request failed under the queue fail-fast policy.
  queueHalted,

  /// The flow was disposed before this request completed.
  serviceDisposed,
}
