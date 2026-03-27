import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
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
/// Implementer expectations:
/// - Validate that each consumed chunk belongs to the active session.
/// - Preserve chunk order when writing bytes to a sink.
/// - Keep session state isolated across different request ids.
/// - Ensure [onCancelSession] and [dispose] are safe after partial writes.
abstract interface class TtsOutput {
  /// Stable identifier for this output implementation.
  String get outputId;

  /// Audio capabilities that this output can accept.
  ///
  /// The service negotiates a format by intersecting these capabilities with
  /// engine capabilities.
  Set<AudioCapability> get acceptedCapabilities;

  /// Initializes output-wide resources.
  ///
  /// Examples include creating directories, opening clients, or allocating
  /// reusable native handles.
  Future<void> init();

  /// Starts a new request-scoped output session.
  ///
  /// Implementations should reset per-request state and prepare the sink for
  /// chunks that belong to [session.requestId].
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

final class TtsOutputPlaybackCompletedEvent {
  const TtsOutputPlaybackCompletedEvent({
    required this.requestId,
    required this.outputId,
    required this.playbackId,
    this.playedDuration,
  });

  final String requestId;
  final String outputId;
  final String playbackId;

  /// Optional speaker-reported elapsed playback duration at physical
  /// completion time.
  final Duration? playedDuration;
}

extension TtsOutputCapabilities on TtsOutput {
  /// Returns true when any accepted capability can consume [spec].
  bool acceptsSpec(TtsAudioSpec spec) {
    for (final capability in acceptedCapabilities) {
      if (capability.supports(spec)) {
        return true;
      }
    }
    return false;
  }
}
