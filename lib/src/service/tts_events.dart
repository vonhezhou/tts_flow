import 'package:tts_flow_dart/src/core/tts_chunk.dart';

import '../core/tts_errors.dart';
import '../core/tts_request.dart';

enum TtsQueueEventType {
  requestEnqueued,
  requestDequeued,
  queueCleared,
  queueHalted
}

enum TtsRequestEventType {
  requestQueued,
  requestStarted,
  requestChunkReceived,
  requestCompleted,
  requestFailed,
  requestStopped,
  requestCanceled,
}

final class TtsQueueEvent {
  const TtsQueueEvent({
    required this.type,
    required this.timestamp,
    required this.queueLength,
    this.requestId,
  });

  final TtsQueueEventType type;
  final DateTime timestamp;
  final int queueLength;
  final String? requestId;
}

final class TtsRequestEvent {
  const TtsRequestEvent({
    required this.type,
    required this.requestId,
    required this.timestamp,
    this.state,
    this.chunk,
    this.error,
    this.outputId,
    this.outputError,
  });

  final TtsRequestEventType type;
  final String requestId;
  final DateTime timestamp;
  final TtsRequestState? state;
  final TtsChunk? chunk;
  final TtsError? error;
  final String? outputId;
  final TtsError? outputError;
}
