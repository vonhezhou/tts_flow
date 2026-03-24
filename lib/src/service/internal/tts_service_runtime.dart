part of 'package:flutter_uni_tts/src/service/tts_service.dart';

Future<void> _processQueueImpl(TtsService service) async {
  if (!service._state.tryEnterProcessing()) {
    return;
  }

  try {
    while (!service._scheduler.isEmpty && !service._state.isDisposed) {
      // Pause gates starting the next request. Active request handling
      // continues in-loop using buffering/passthrough policy.
      if (service._state.isPaused) {
        break;
      }

      final item = service._scheduler.dequeue();
      final shouldStopQueue = await _processQueuedRequestImpl(service, item);
      if (shouldStopQueue || service._state.isHalted) {
        break;
      }
    }
  } finally {
    service._state.exitProcessing();
  }
}

Future<void> _flushPauseBufferImpl(
  TtsService service,
  _QueuedRequest item,
  TtsRequest request,
  SynthesisControl control,
) async {
  final toFlush = List<TtsChunk>.of(service._state.pauseBuffer);
  service._state.clearPauseBuffer();
  for (final chunk in toFlush) {
    if (control.isCanceled) {
      break;
    }
    await service._output.consumeChunk(chunk);
    item.controller.add(chunk);
    service._emitRequestEvent(
      TtsRequestEventType.requestChunkReceived,
      requestId: request.requestId,
      state: TtsRequestState.running,
      chunk: chunk,
    );
  }
}
