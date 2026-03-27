import 'dart:async';

import 'package:meta/meta.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/service/tts_events.dart';

mixin TtsFlowEventBus {
  @protected
  StreamController<TtsFlowEvent> get eventBus;

  void emitQueueEvent(
    TtsQueueEventType type, {
    required int queueLength,
    String? requestId,
  }) {
    eventBus.add(
      TtsQueueEvent(
        type: type,
        requestId: requestId,
        timestamp: DateTime.now().toUtc(),
        queueLength: queueLength,
      ),
    );
  }

  void emitRequestEvent(
    TtsRequestEventType type, {
    required String requestId,
    TtsRequestState? state,
    TtsChunk? chunk,
    TtsError? error,
    String? outputId,
    TtsError? outputError,
    String? playbackId,
    Duration? playedDuration,
  }) {
    eventBus.add(
      TtsRequestEvent(
        type: type,
        requestId: requestId,
        timestamp: DateTime.now().toUtc(),
        state: state,
        chunk: chunk,
        error: error,
        outputId: outputId,
        outputError: outputError,
        playbackId: playbackId,
        playedDuration: playedDuration,
      ),
    );
  }
}
