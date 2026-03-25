part of 'package:tts_flow_dart/src/service/tts_flow.dart';

Future<bool> _processQueuedRequestImpl(
  TtsFlow service,
  _QueuedRequest item,
) async {
  final request = item.request;
  final control = SynthesisControl();
  service._state.activeControl = control;

  service._emitQueueEvent(TtsQueueEventType.requestDequeued,
      requestId: request.requestId);
  service._emitRequestEvent(
    TtsRequestEventType.requestStarted,
    requestId: request.requestId,
    state: TtsRequestState.running,
  );

  try {
    final audioSpec = service._resolveAudioSpec(request);
    await service._output.initSession(
      TtsOutputSession(
        requestId: request.requestId,
        audioSpec: audioSpec,
        voice: request.voice,
        options: request.options,
        params: request.params,
      ),
    );

    await for (final chunk
        in service._engine.synthesize(request, control, audioSpec)) {
      if (control.isCanceled) {
        break;
      }
      await _handleSynthesizedChunk(service, item, request, control, chunk);
      if (control.isCanceled) {
        break;
      }
    }

    if (!control.isCanceled && service._state.pauseBuffer.isNotEmpty) {
      while (service._state.isPaused &&
          !service._state.isDisposed &&
          !control.isCanceled) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!control.isCanceled) {
        await service._flushPauseBuffer(item, request, control);
      }
    }

    if (control.isCanceled) {
      await service._output.onCancel(control);
      service._emitRequestEvent(
        TtsRequestEventType.requestStopped,
        requestId: request.requestId,
        state: TtsRequestState.stopped,
      );
    } else {
      await service._output.finalizeSession();
      service._emitRequestEvent(
        TtsRequestEventType.requestCompleted,
        requestId: request.requestId,
        state: TtsRequestState.completed,
      );
    }

    unawaited(item.controller.close());
    return false;
  } catch (error) {
    final failure = service._mapRequestFailure(error, request);
    service._emitRequestEvent(
      TtsRequestEventType.requestFailed,
      requestId: request.requestId,
      state: TtsRequestState.failed,
      error: failure.ttsError,
      outputId: failure.outputId,
      outputError: failure.outputError,
    );
    item.controller.addError(failure.ttsError);
    unawaited(item.controller.close());

    if (service._config.queueFailurePolicy == TtsQueueFailurePolicy.failFast) {
      service._state.haltQueue();
      service._emitQueueEvent(TtsQueueEventType.queueHalted,
          requestId: request.requestId);
      await service._cancelPendingAfterFailure();
      return true;
    }

    return false;
  } finally {
    service._state.activeControl = null;
    service._state.clearPauseBuffer();
  }
}

Future<void> _handleSynthesizedChunk(
  TtsFlow service,
  _QueuedRequest item,
  TtsRequest request,
  SynthesisControl control,
  TtsChunk chunk,
) async {
  // Flush buffered chunks before handling fresh chunks after resume.
  if (service._state.pauseBuffer.isNotEmpty && !service._state.isPaused) {
    await service._flushPauseBuffer(item, request, control);
    if (control.isCanceled) {
      return;
    }
  }

  if (service._state.isPaused &&
      service._config.pauseBufferPolicy == TtsPauseBufferPolicy.buffered) {
    service._state.pauseBuffer.add(chunk);
    final newBytes = service._state.pauseBufferBytes + chunk.bytes.length;
    if (service._state.pauseBufferBytes <=
            service._config.pauseBufferMaxBytes &&
        newBytes > service._config.pauseBufferMaxBytes) {
      log(
        'TTS pause buffer exceeded ${service._config.pauseBufferMaxBytes} '
        'bytes (current: $newBytes); chunks continue to accumulate.',
        name: 'tts_flow_dart',
        level: 900,
      );
    }
    service._state.pauseBufferBytes = newBytes;
    return;
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
