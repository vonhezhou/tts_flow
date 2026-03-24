part of 'package:flutter_uni_tts/src/service/tts_service.dart';

void _emitQueueEventImpl(
  TtsService service,
  TtsQueueEventType type, {
  String? requestId,
}) {
  service._queueEventsController.add(
    TtsQueueEvent(
      type: type,
      requestId: requestId,
      timestamp: DateTime.now().toUtc(),
      queueLength: service._scheduler.length,
    ),
  );
}

void _emitRequestEventImpl(
  TtsService service,
  TtsRequestEventType type, {
  required String requestId,
  TtsRequestState? state,
  TtsChunk? chunk,
  TtsError? error,
  String? outputId,
  TtsError? outputError,
}) {
  service._requestEventsController.add(
    TtsRequestEvent(
      type: type,
      requestId: requestId,
      timestamp: DateTime.now().toUtc(),
      state: state,
      chunk: chunk,
      error: error,
      outputId: outputId,
      outputError: outputError,
    ),
  );
}
