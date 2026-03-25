part of 'package:tts_flow_dart/src/service/tts_flow.dart';

void _emitQueueEventImpl(
  TtsFlow service,
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
  TtsFlow service,
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
