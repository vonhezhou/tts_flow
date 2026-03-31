import 'dart:async';

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
/// 2. [appendChunk] is called zero or more times with ordered audio chunks for
///    that playback.
/// 3. The session ends with either [finalizePlayback] (normal finish) or
///    [stopPlayback] (cancellation/interruption).
///
/// Playback control methods [pausePlayback] and [resumePlayback] are optional
/// control points for an active session and should preserve stream position.
///
/// Contract expectations for implementers:
/// - Treat [playbackId] as the stable key for all per-session state.
/// - Keep audio ordering exactly as received by [appendChunk].
/// - Reject writes after [finalizePlayback] or [stopPlayback] closes a
///   session.
/// - Ensure [init] can be safely called before playback begins.
/// - Make [dispose] release resources even when sessions are still active.
abstract interface class SpeakerBackend {
  /// Emits events when a playback stream physically finishes on the speaker.
  ///
  /// This stream is independent from ingestion completion and can emit after
  /// [finalizePlayback] has returned.
  Stream<SpeakerPlaybackCompletedEvent> get playbackCompletedEvents;

  /// Audio capabilities accepted by this backend.
  ///
  /// [SpeakerOutput] uses this value as its accepted capabilities and forwards
  /// only compatible audio streams to the backend.
  Set<AudioCapability> get supportedCapabilities;

  /// Prepares backend resources needed for playback.
  ///
  /// This method should be safe to call exactly once before any playback
  /// operation and should complete before [startPlayback].
  Future<void> init();

  /// Starts a new playback session for [requestId] using [audioSpec].
  ///
  /// Returns a backend-generated playback identifier that must be passed to
  /// subsequent calls such as [appendChunk], [finalizePlayback], and
  /// [stopPlayback].
  Future<String> startPlayback({
    required String requestId,
    required TtsAudioSpec audioSpec,
  });

  /// Appends TtsChunk [chunk] to an existing [playbackId] session.
  ///
  /// This method may be called repeatedly as chunks arrive and should preserve
  /// chunk ordering within the playback stream.
  Future<void> appendChunk({
    required String playbackId,
    required TtsChunk chunk,
  });

  /// Closes ingestion for [playbackId].
  ///
  /// This call must not be interpreted as physical speaker completion. Backends
  /// can continue rendering buffered audio after this method returns.
  ///
  /// After ingestion finalization, the playback session should no longer accept
  /// new audio data.
  Future<void> finalizePlayback({required String playbackId});

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

final class SpeakerPlaybackCompletedEvent {
  const SpeakerPlaybackCompletedEvent({
    required this.requestId,
    required this.playbackId,
    this.playedDuration,
  });

  final String requestId;
  final String playbackId;

  /// Optional elapsed playback time as reported by the speaker backend.
  final Duration? playedDuration;
}

final class SpeakerOutput implements TtsOutput, PlaybackAwareOutput {
  SpeakerOutput({
    required SpeakerBackend backend,
    this.outputId = 'speaker-output',
  }) : _backend = backend,
       _playbackCompletedController =
           StreamController<TtsOutputPlaybackCompletedEvent>.broadcast() {
    _playbackCompletedSubscription = _backend.playbackCompletedEvents.listen((
      event,
    ) {
      _playbackCompletedController.add(
        TtsOutputPlaybackCompletedEvent(
          requestId: event.requestId,
          outputId: outputId,
          playbackId: event.playbackId,
          playedDuration: event.playedDuration,
        ),
      );
    });
  }

  final SpeakerBackend _backend;
  final StreamController<TtsOutputPlaybackCompletedEvent>
  _playbackCompletedController;
  late final StreamSubscription<SpeakerPlaybackCompletedEvent>
  _playbackCompletedSubscription;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get inAudioCapabilities =>
      _backend.supportedCapabilities;

  @override
  Stream<TtsOutputPlaybackCompletedEvent> get playbackCompletedEvents =>
      _playbackCompletedController.stream;

  TtsOutputSession? _session;
  String? _playbackId;

  @override
  Future<void> init() async {
    await _backend.init();
  }

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

    await _backend.appendChunk(playbackId: playbackId, chunk: chunk);
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    final playbackId = _playbackId;
    if (session == null || playbackId == null) {
      throw StateError('SpeakerOutput session is not initialized.');
    }

    await _backend.finalizePlayback(playbackId: playbackId);
    _session = null;
    _playbackId = null;

    return PlaybackAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      playbackId: playbackId,
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
    await _playbackCompletedSubscription.cancel();
    await _playbackCompletedController.close();
    await _backend.dispose();
  }
}
