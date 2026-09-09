import 'dart:async';

import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/service/tts_events.dart';

/// A handle for one concrete synthesis request.
///
/// The handle owns the framework-generated [requestKey]. The caller-provided
/// [utteranceId] is retained for application correlation and is included in
/// every request event.
final class TtsRequestHandle extends StreamView<TtsChunk> {
  TtsRequestHandle({
    required this.requestKey,
    required this.utteranceId,
    required this.chunks,
    required this.events,
    required Future<void> Function() stopSynthesis,
    required Future<void> Function() pausePlayback,
    required Future<void> Function() resumePlayback,
    required Future<void> Function() stopPlayback,
    required bool Function() hasActivePlayback,
  }) : _stopSynthesis = stopSynthesis,
       _pausePlayback = pausePlayback,
       _resumePlayback = resumePlayback,
       _stopPlayback = stopPlayback,
       _hasActivePlayback = hasActivePlayback,
       super(chunks);

  /// Opaque, flow-local identifier for this request instance.
  final String requestKey;

  /// Application correlation label supplied to `TtsFlow.speak`.
  final String utteranceId;

  /// Chunks produced by synthesis for this request.
  final Stream<TtsChunk> chunks;

  /// Lifecycle events for this request only, including events emitted before
  /// the caller subscribes. This is a single-subscription stream.
  final Stream<TtsRequestEvent> events;

  final Future<void> Function() _stopSynthesis;
  final Future<void> Function() _pausePlayback;
  final Future<void> Function() _resumePlayback;
  final Future<void> Function() _stopPlayback;
  final bool Function() _hasActivePlayback;

  /// Stops this request whether it is queued or actively synthesizing.
  ///
  /// This does not stop audio already handed to a physical playback backend.
  Future<void> stopSynthesis() => _stopSynthesis();

  bool get hasActivePlayback => _hasActivePlayback();

  Future<void> pausePlayback() => _pausePlayback();
  Future<void> resumePlayback() => _resumePlayback();
  Future<void> stopPlayback() => _stopPlayback();
}
