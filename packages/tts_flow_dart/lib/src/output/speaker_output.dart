import 'dart:async';

import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/playback_timeline.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';
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
  /// This stream is independent from input completion and can emit after
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

  /// Starts a new playback session for [requestKey] using [audioSpec].
  ///
  /// Returns a backend-generated playback identifier that must be passed to
  /// subsequent calls such as [appendChunk], [finalizePlayback], and
  /// [stopPlayback].
  Future<String> startPlayback({
    required String requestKey,
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

  /// Closes audio input for [playbackId].
  ///
  /// This call must not be interpreted as physical speaker completion. Backends
  /// can continue rendering buffered audio after this method returns.
  ///
  /// After input finalization, the playback session should no longer accept new
  /// audio data.
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

/// Optional [SpeakerBackend] capability for platform playback failures.
///
/// Kept separate from [SpeakerBackend] so existing backends remain source and
/// binary compatible. A failure can occur after audio input has finalized.
abstract interface class SpeakerPlaybackFailureAwareBackend {
  Stream<SpeakerPlaybackFailedEvent> get playbackFailedEvents;
}

final class SpeakerPlaybackCompletedEvent {
  const SpeakerPlaybackCompletedEvent({
    required this.requestKey,
    required this.playbackId,
    this.playedDuration,
  });

  final String requestKey;
  final String playbackId;

  /// Optional elapsed playback time as reported by the speaker backend.
  final Duration? playedDuration;
}

final class SpeakerPlaybackFailedEvent {
  const SpeakerPlaybackFailedEvent({
    required this.requestKey,
    required this.playbackId,
    required this.error,
  });

  final String requestKey;
  final String playbackId;
  final TtsError error;
}

final class SpeakerOutput implements TtsOutput, PlaybackControllableOutput {
  SpeakerOutput({
    required SpeakerBackend backend,
    this.outputId = 'speaker-output',
  }) : _backend = backend,
       _playbackCompletedController =
           StreamController<TtsOutputPlaybackCompletedEvent>.broadcast(),
       _playbackFailedController =
           StreamController<TtsOutputPlaybackFailedEvent>.broadcast() {
    _playbackCompletedSubscription = _backend.playbackCompletedEvents.listen(
      _onBackendPlaybackCompleted,
    );
    if (_backend is SpeakerPlaybackFailureAwareBackend) {
      final failureAwareBackend =
          _backend as SpeakerPlaybackFailureAwareBackend;
      _playbackFailedSubscription = failureAwareBackend.playbackFailedEvents
          .listen(_onBackendPlaybackFailed);
    }
  }

  final SpeakerBackend _backend;
  final StreamController<TtsOutputPlaybackCompletedEvent>
  _playbackCompletedController;
  final StreamController<TtsOutputPlaybackFailedEvent>
  _playbackFailedController;
  late final StreamSubscription<SpeakerPlaybackCompletedEvent>
  _playbackCompletedSubscription;
  StreamSubscription<SpeakerPlaybackFailedEvent>? _playbackFailedSubscription;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get inAudioCapabilities =>
      _backend.supportedCapabilities;

  @override
  Stream<TtsOutputPlaybackCompletedEvent> get playbackCompletedEvents =>
      _playbackCompletedController.stream;

  @override
  Stream<TtsOutputPlaybackFailedEvent> get playbackFailedEvents =>
      _playbackFailedController.stream;

  TtsOutputWriteContext? _writeContext;
  String? _playbackId;
  final Map<String, String> _playbackIdsByRequest = <String, String>{};

  /// Optional physical playback timeline supplied by the underlying backend.
  ///
  /// Consumers can use this capability with [TtsSentenceCueChunk] without
  /// depending on a specific Flutter playback implementation.
  PlaybackTimelineReporter? get timelineReporter {
    final backend = _backend;
    return backend is PlaybackTimelineReporter
        ? backend as PlaybackTimelineReporter
        : null;
  }

  @override
  Future<void> init() async {
    await _backend.init();
  }

  @override
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    if (_playbackIdsByRequest.containsKey(writeContext.requestKey)) {
      throw StateError(
        'Playback already exists for ${writeContext.requestKey}.',
      );
    }
    _writeContext = writeContext;
    _playbackId = await _backend.startPlayback(
      requestKey: writeContext.requestKey,
      audioSpec: writeContext.audioSpec,
    );
    _playbackIdsByRequest[writeContext.requestKey] = _playbackId!;
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _writeContext;
    final playbackId = _playbackId;
    if (writeContext == null || playbackId == null) {
      throw StateError('SpeakerOutput write has not started.');
    }
    if (chunk.requestKey != writeContext.requestKey) {
      throw StateError('Chunk requestKey does not match active write.');
    }

    await _backend.appendChunk(playbackId: playbackId, chunk: chunk);
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final writeContext = _writeContext;
    final playbackId = _playbackId;
    if (writeContext == null || playbackId == null) {
      throw StateError('SpeakerOutput write has not started.');
    }

    await _backend.finalizePlayback(playbackId: playbackId);
    _writeContext = null;
    _playbackId = null;

    return PlaybackAudioArtifact(
      requestKey: writeContext.requestKey,
      audioSpec: writeContext.audioSpec,
      playbackId: playbackId,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    final writeContext = _writeContext;
    final playbackId = _playbackId;
    if (playbackId != null) {
      final reason = control.cancelMessage ?? control.cancelReason?.name;
      await _backend.stopPlayback(playbackId: playbackId, reason: reason);
    }
    if (writeContext != null) {
      _playbackIdsByRequest.remove(writeContext.requestKey);
    }
    _writeContext = null;
    _playbackId = null;
  }

  @override
  bool hasActivePlayback(String requestKey) =>
      _playbackIdsByRequest.containsKey(requestKey);

  @override
  Future<void> pausePlayback(String requestKey) async {
    await _backend.pausePlayback(playbackId: _requirePlaybackId(requestKey));
  }

  @override
  Future<void> resumePlayback(String requestKey) async {
    await _backend.resumePlayback(playbackId: _requirePlaybackId(requestKey));
  }

  @override
  Future<void> stopPlayback(String requestKey) async {
    final playbackId = _requirePlaybackId(requestKey);
    await _backend.stopPlayback(playbackId: playbackId, reason: 'stopPlayback');
    _playbackIdsByRequest.remove(requestKey);
    if (_writeContext?.requestKey == requestKey) {
      _writeContext = null;
      _playbackId = null;
    }
  }

  @override
  Future<void> dispose() async {
    final playbackIds = _playbackIdsByRequest.values.toSet();
    for (final playbackId in playbackIds) {
      await _backend.stopPlayback(
        playbackId: playbackId,
        reason: CancelReason.serviceDispose.name,
      );
    }
    _playbackIdsByRequest.clear();
    _writeContext = null;
    _playbackId = null;
    await _playbackCompletedSubscription.cancel();
    await _playbackFailedSubscription?.cancel();
    await _playbackCompletedController.close();
    await _playbackFailedController.close();
    await _backend.dispose();
  }

  String _requirePlaybackId(String requestKey) {
    final playbackId = _playbackIdsByRequest[requestKey];
    if (playbackId == null) {
      throw StateError('No active playback for "$requestKey".');
    }
    return playbackId;
  }

  void _onBackendPlaybackCompleted(SpeakerPlaybackCompletedEvent event) {
    if (_playbackIdsByRequest[event.requestKey] == event.playbackId) {
      _playbackIdsByRequest.remove(event.requestKey);
    }
    _playbackCompletedController.add(
      TtsOutputPlaybackCompletedEvent(
        requestKey: event.requestKey,
        outputId: outputId,
        playbackId: event.playbackId,
        playedDuration: event.playedDuration,
      ),
    );
  }

  void _onBackendPlaybackFailed(SpeakerPlaybackFailedEvent event) {
    if (_playbackIdsByRequest[event.requestKey] == event.playbackId) {
      _playbackIdsByRequest.remove(event.requestKey);
    }
    _playbackFailedController.add(
      TtsOutputPlaybackFailedEvent(
        requestKey: event.requestKey,
        outputId: outputId,
        playbackId: event.playbackId,
        error: event.error,
      ),
    );
  }
}
