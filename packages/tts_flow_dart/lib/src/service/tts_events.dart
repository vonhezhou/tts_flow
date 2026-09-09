import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';

enum TtsQueueEventType {
  requestEnqueued,
  requestDequeued,
  queueCleared,
  queueHalted,
}

enum TtsRequestEventType {
  requestQueued,
  requestStarted,
  requestChunkReceived,
  requestSynthesisCompleted,
  requestPlaybackCompleted,
  requestPlaybackFailed,
  requestSynthesisFailed,
  requestSynthesisStopped,
  requestPlaybackPaused,
  requestPlaybackResumed,
  requestPlaybackStopped,
  requestCanceled,
}

abstract class TtsFlowEvent {}

final class TtsQueueEvent implements TtsFlowEvent {
  const TtsQueueEvent({
    required this.type,
    required this.timestamp,
    required this.queueLength,
    this.requestKey,
    this.utteranceId,
  });

  final TtsQueueEventType type;
  final DateTime timestamp;
  final int queueLength;
  final String? requestKey;

  /// Application correlation label for [requestKey], when this event belongs
  /// to one request.
  final String? utteranceId;
}

final class TtsRequestEvent implements TtsFlowEvent {
  const TtsRequestEvent({
    required this.type,
    required this.requestKey,
    required this.utteranceId,
    required this.timestamp,
    this.state,
    this.chunk,
    this.error,
    this.outputId,
    this.outputError,
    this.playbackId,
    this.playedDuration,
  });

  final TtsRequestEventType type;
  final String requestKey;

  /// Application-supplied correlation label. Unlike [requestKey], this is
  /// allowed to be reused by multiple concrete requests.
  final String utteranceId;
  final DateTime timestamp;
  final TtsRequestState? state;
  final TtsChunk? chunk;
  final TtsError? error;
  final String? outputId;
  final TtsError? outputError;
  final String? playbackId;
  final Duration? playedDuration;
}
