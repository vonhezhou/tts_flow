import 'dart:async';

import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_synthesis_result.dart';
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
    required this.synthesisResult,
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
  ///
  /// This is a single-subscription stream. The handle itself is a view of the
  /// same stream, so listen through either this property or the handle, never
  /// both. Attach one listener promptly after [TtsFlow.speak] when handing the
  /// request to an application-owned realtime processing system.
  ///
  /// This stream deliberately is not an application-level fanout API. Use
  /// [MulticastOutput] for backpressure-coupled outputs, [PrioritizedOutput]
  /// for playback-first auxiliary observers, or implement application-owned
  /// fanout with its own buffering and delivery policy.
  final Stream<TtsChunk> chunks;

  /// Lifecycle events for this request only, including events emitted before
  /// the caller subscribes. This is a single-subscription stream.
  final Stream<TtsRequestEvent> events;

  /// Terminal synthesis and output-writing result for this request.
  ///
  /// This future always completes with a [TtsSynthesisResult], including when
  /// synthesis stops or fails. It does not wait for physical speaker playback.
  final Future<TtsSynthesisResult> synthesisResult;

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
