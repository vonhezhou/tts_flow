import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';

/// Output contract that consumes synthesized chunks and produces a final audio
/// artifact.
///
/// Typical output lifecycle per request:
/// 1. [init] is called once for output-wide setup.
/// 2. [initSession] starts request-scoped state.
/// 3. [consumeChunk] is called zero or more times in sequence order.
/// 4. Complete with [finalizeSession] or abort via [onCancelSession].
/// 5. [dispose] releases output resources at shutdown.
///
/// When an output is passed to [TtsFlow] as its default output or as a
/// request-level override, that flow owns the output lifecycle. It initializes
/// the output before its first session and disposes it when the flow is
/// disposed. Do not share the same output instance between flows.
///
/// For one flow, ingestion sessions are strictly serial: the flow will not
/// call [initSession] for the next request until the current request has
/// finished with [finalizeSession] or [onCancelSession]. An implementation only
/// needs one active ingestion session; it does not need a concurrent session
/// map or an audio-processing scheduler.
///
/// Implementer expectations:
/// - Validate that each consumed chunk belongs to the active session.
/// - Preserve chunk order when writing bytes to a sink.
/// - Reject a second [initSession] while the current session is active.
/// - Ensure [onCancelSession] and [dispose] are safe after partial writes.
abstract interface class TtsOutput {
  /// Stable identifier for this output implementation.
  String get outputId;

  /// Audio capabilities that this output can accept.
  ///
  /// The service negotiates a format by intersecting these capabilities with
  /// engine capabilities.
  Set<AudioCapability> get inAudioCapabilities;

  /// Initializes output-wide resources.
  ///
  /// Examples include creating directories, opening clients, or allocating
  /// reusable native handles.
  Future<void> init();

  /// Starts a new request-scoped output session.
  ///
  /// The preceding session is always terminal before this call. Implementations
  /// should prepare one active sink for chunks that belong to
  /// [session.requestKey].
  Future<void> initSession(TtsOutputSession session);

  /// Consumes one synthesized [chunk] for the active session.
  ///
  /// Chunks are provided in sequence order and should be written in that same
  /// order to preserve audio integrity.
  Future<void> consumeChunk(TtsChunk chunk);

  /// Finalizes the active session and returns its resulting [AudioArtifact].
  ///
  /// After this call, session state should be closed and not accept additional
  /// chunks.
  Future<AudioArtifact> finalizeSession();

  /// Cancels the active session using [control] as cancellation context.
  ///
  /// Implementations should stop writes promptly, release session resources,
  /// and be resilient when no active session exists.
  Future<void> onCancelSession(SynthesisControl control);

  /// Releases output resources and any active session state.
  Future<void> dispose();
}

/// Optional output capability that emits physical playback completion events.
///
/// Implement this on outputs that can distinguish ingestion completion from
/// device playback completion.
abstract interface class PlaybackAwareOutput {
  Stream<TtsOutputPlaybackCompletedEvent> get playbackCompletedEvents;
}

/// Optional output capability that emits physical playback failures.
///
/// A playback failure is deliberately separate from synthesis/output ingestion
/// failure: it can arrive after [TtsOutput.finalizeSession] has completed, and
/// must not retroactively turn a completed synthesis request into a failed one.
abstract interface class PlaybackFailureAwareOutput {
  Stream<TtsOutputPlaybackFailedEvent> get playbackFailedEvents;
}

/// Optional output capability for physical playback control.
///
/// Implementations keep a request-to-playback association until physical
/// playback completes, fails, or is stopped. They must also implement the
/// completion and failure event capabilities so callers can observe terminal
/// playback state. This capability does not require, or promise, concurrent
/// speaker mixing: it only keeps control and observation available after the
/// serial ingestion session has ended.
abstract interface class PlaybackControllableOutput
    implements PlaybackAwareOutput, PlaybackFailureAwareOutput {
  /// Whether [requestKey] still has physical playback that can be controlled.
  bool hasActivePlayback(String requestKey);

  Future<void> pausePlayback(String requestKey);
  Future<void> resumePlayback(String requestKey);
  Future<void> stopPlayback(String requestKey);
}

final class TtsOutputPlaybackCompletedEvent {
  const TtsOutputPlaybackCompletedEvent({
    required this.requestKey,
    required this.outputId,
    required this.playbackId,
    this.playedDuration,
  });

  final String requestKey;
  final String outputId;
  final String playbackId;

  /// Optional speaker-reported elapsed playback duration at physical
  /// completion time.
  final Duration? playedDuration;
}

final class TtsOutputPlaybackFailedEvent {
  const TtsOutputPlaybackFailedEvent({
    required this.requestKey,
    required this.outputId,
    required this.playbackId,
    required this.error,
  });

  final String requestKey;
  final String outputId;
  final String playbackId;

  /// Failure reported by the physical playback implementation.
  final TtsError error;
}

extension TtsOutputCapabilities on TtsOutput {
  /// Returns true when any accepted capability can consume [spec].
  bool acceptsSpec(TtsAudioSpec spec) {
    for (final capability in inAudioCapabilities) {
      if (capability.supports(spec)) {
        return true;
      }
    }
    return false;
  }
}
