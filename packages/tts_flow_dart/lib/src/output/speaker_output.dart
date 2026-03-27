import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';

/// Backend contract used by [SpeakerOutput] to stream audio to a speaker
/// implementation.
///
/// Typical lifecycle for one synthesis request:
/// 1. [startPlayback] is called once with the request metadata and returns a
///    backend-owned playback identifier.
/// 2. [appendAudio] is called zero or more times with ordered audio chunks for
///    that playback.
/// 3. The session ends with either [completePlayback] (normal finish) or
///    [stopPlayback] (cancellation/interruption).
///
/// Playback control methods [pausePlayback] and [resumePlayback] are optional
/// control points for an active session and should preserve stream position.
///
/// Contract expectations for implementers:
/// - Treat [playbackId] as the stable key for all per-session state.
/// - Keep audio ordering exactly as received by [appendAudio].
/// - Reject writes after [completePlayback] or [stopPlayback] closes a session.
/// - Make [dispose] release resources even when sessions are still active.
abstract interface class SpeakerBackend {
  /// Audio capabilities accepted by this backend.
  ///
  /// [SpeakerOutput] uses this value as its accepted capabilities and forwards
  /// only compatible audio streams to the backend.
  Set<AudioCapability> get supportedCapabilities;

  /// Starts a new playback session for [requestId] using [audioSpec].
  ///
  /// Returns a backend-generated playback identifier that must be passed to
  /// subsequent calls such as [appendAudio], [completePlayback], and
  /// [stopPlayback].
  Future<String> startPlayback({
    required String requestId,
    required TtsAudioSpec audioSpec,
  });

  /// Appends synthesized audio [bytes] to an existing [playbackId] session.
  ///
  /// This method may be called repeatedly as chunks arrive and should preserve
  /// chunk ordering within the playback stream.
  Future<void> appendAudio({
    required String playbackId,
    required List<int> bytes,
  });

  /// Completes [playbackId] and returns the final playback duration.
  ///
  /// After completion, the playback session is considered closed and should no
  /// longer accept new audio data.
  Future<Duration> completePlayback({required String playbackId});

  /// Stops [playbackId] before normal completion.
  ///
  /// [reason] can be used for diagnostics or user-facing cancellation context.
  Future<void> stopPlayback({required String playbackId, String? reason});

  /// Pauses output for [playbackId] while preserving current playback state.
  Future<void> pausePlayback({required String playbackId});

  /// Resumes a paused [playbackId] session.
  Future<void> resumePlayback({required String playbackId});

  /// Releases backend resources and clears any active playback state.
  Future<void> dispose();
}

final class SpeakerOutput implements TtsOutput {
  SpeakerOutput({
    required SpeakerBackend backend,
    this.outputId = 'speaker-output',
  }) : _backend = backend;

  final SpeakerBackend _backend;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities =>
      _backend.supportedCapabilities;

  TtsOutputSession? _session;
  String? _playbackId;

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _playbackId = await _backend.startPlayback(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
    );
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    final playbackId = _playbackId;
    if (session == null || playbackId == null) {
      throw StateError('SpeakerOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }

    await _backend.appendAudio(playbackId: playbackId, bytes: chunk.bytes);
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    final playbackId = _playbackId;
    if (session == null || playbackId == null) {
      throw StateError('SpeakerOutput session is not initialized.');
    }

    final duration = await _backend.completePlayback(playbackId: playbackId);
    _session = null;
    _playbackId = null;

    return PlaybackAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      playbackId: playbackId,
      playbackDuration: duration,
    );
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    final playbackId = _playbackId;
    if (playbackId != null) {
      final reason = control.cancelMessage ?? control.cancelReason?.name;
      await _backend.stopPlayback(playbackId: playbackId, reason: reason);
    }
    _session = null;
    _playbackId = null;
  }

  @override
  Future<void> dispose() async {
    final control = SynthesisControl()..cancel(CancelReason.serviceDispose);
    await onCancelSession(control);
    await _backend.dispose();
  }
}
