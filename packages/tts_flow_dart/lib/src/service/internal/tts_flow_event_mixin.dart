import 'dart:async';

import 'package:meta/meta.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/service/tts_events.dart';

mixin TtsFlowEventBus {
  @protected
  StreamController<TtsFlowEvent> get eventBus;

  @protected
  String? utteranceIdForRequestKey(String requestKey);

  @protected
  void onRequestEventEmitted(TtsRequestEvent event);

  void emitQueueEvent(
    TtsQueueEventType type, {
    required int queueLength,
    String? requestKey,
  }) {
    eventBus.add(
      TtsQueueEvent(
        type: type,
        requestKey: requestKey,
        utteranceId: requestKey == null
            ? null
            : utteranceIdForRequestKey(requestKey),
        timestamp: DateTime.now().toUtc(),
        queueLength: queueLength,
      ),
    );
  }

  void emitRequestEvent(
    TtsRequestEventType type, {
    required String requestKey,
    TtsRequestState? state,
    TtsChunk? chunk,
    TtsError? error,
    String? outputId,
    TtsError? outputError,
    String? playbackId,
    Duration? playedDuration,
  }) {
    final event = TtsRequestEvent(
      type: type,
      requestKey: requestKey,
      utteranceId: utteranceIdForRequestKey(requestKey) ?? requestKey,
      timestamp: DateTime.now().toUtc(),
      state: state,
      chunk: chunk,
      error: error,
      outputId: outputId,
      outputError: outputError,
      playbackId: playbackId,
      playedDuration: playedDuration,
    );
    eventBus.add(event);
    onRequestEventEmitted(event);
  }
}
