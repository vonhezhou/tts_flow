part of 'tts_utterance_queue_mixin.dart';

/// Runs one queued synthesis request from negotiation through its terminal
/// output result. Queue admission and physical-playback subscriptions remain
/// owned by [TtsUtteranceQueueMixin].
extension _TtsUtteranceQueueRequestProcessor on TtsUtteranceQueueMixin {
  Future<bool> processQueuedRequest(QueuedRequest item) async {
    final request = item.request;
    final effectiveOutput = request.output ?? defaultOutput!;

    final control = SynthesisControl();
    state.activeControl = control;
    state.activeRequestKey = request.requestKey;

    emitQueueEvent(
      TtsQueueEventType.requestDequeued,
      queueLength: scheduler.length,
      requestKey: request.requestKey,
    );
    emitRequestEvent(
      TtsRequestEventType.requestStarted,
      requestKey: request.requestKey,
      state: TtsRequestState.running,
    );

    try {
      await ensureOutputInitialized(effectiveOutput);
      await _registerPlaybackEventListeners(
        requestKey: request.requestKey,
        output: effectiveOutput,
      );

      final audioSpec = resolveAudioSpec(request, effectiveOutput);
      if (!engine.supportsSpec(audioSpec)) {
        throw TtsError(
          code: TtsErrorCode.formatNegotiationFailed,
          message:
              'Negotiated audio spec is not supported by engine "${engine.engineId}".',
          requestKey: request.requestKey,
        );
      }
      var activeAudioSpec = audioSpec;
      var outputWriteStarted = false;

      Future<void> ensureOutputWriteStarted(TtsAudioSpec spec) async {
        if (outputWriteStarted) {
          return;
        }
        if (!effectiveOutput.acceptsSpec(spec)) {
          throw TtsError(
            code: TtsErrorCode.formatNegotiationFailed,
            message:
                'Resolved audio spec is not accepted by output "${effectiveOutput.outputId}".',
            requestKey: request.requestKey,
          );
        }

        // Register before opening the output write. A playback-oriented output
        // can report a synchronous terminal event while startWrite is still
        // awaiting its backend; registering afterward would reintroduce a
        // stale association after that event has already released it.
        registerPlaybackControl(request.requestKey, effectiveOutput);
        await effectiveOutput.startWrite(
          TtsOutputWriteContext(
            requestKey: request.requestKey,
            audioSpec: spec,
            voice: request.voice,
            options: request.options,
            params: request.params,
          ),
        );
        activeAudioSpec = spec;
        outputWriteStarted = true;
      }

      await for (final chunk in engine.synthesize(
        request,
        control,
        audioSpec,
      )) {
        if (control.isCanceled) {
          break;
        }

        if (chunk is TtsAudioChunk) {
          if (!outputWriteStarted) {
            await ensureOutputWriteStarted(chunk.audioSpec);
          } else if (chunk.audioSpec != activeAudioSpec) {
            throw TtsError(
              code: TtsErrorCode.invalidRequest,
              message:
                  'Chunk audio spec changed after output writing started. '
                  'expected: $activeAudioSpec, received: ${chunk.audioSpec}',
              requestKey: request.requestKey,
            );
          }
        }

        await handleSynthesizedChunk(item, request, chunk, effectiveOutput);
        if (control.isCanceled) {
          break;
        }
      }

      if (control.isCanceled) {
        if (outputWriteStarted) {
          await effectiveOutput.cancelWrite(control);
        }
        await _cancelPlaybackEventListenersForRequest(request.requestKey);
        unregisterPlaybackControl(request.requestKey);
        emitRequestEvent(
          TtsRequestEventType.requestSynthesisStopped,
          requestKey: request.requestKey,
          state: TtsRequestState.stopped,
        );
        item.completeSynthesisResult(
          TtsSynthesisStoppedResult(
            requestKey: request.requestKey,
            utteranceId: request.utteranceId,
            reason: control.cancelReason == CancelReason.serviceDispose
                ? TtsSynthesisStopReason.serviceDisposed
                : TtsSynthesisStopReason.requested,
          ),
        );
        releaseRequestIdentity(request.requestKey);
      } else {
        if (!outputWriteStarted) {
          await ensureOutputWriteStarted(audioSpec);
        }
        final artifact = await effectiveOutput.finishWrite();
        emitRequestEvent(
          TtsRequestEventType.requestSynthesisCompleted,
          requestKey: request.requestKey,
          state: TtsRequestState.completed,
        );
        item.completeSynthesisResult(
          TtsSynthesisCompletedResult(
            requestKey: request.requestKey,
            utteranceId: request.utteranceId,
            artifact: artifact,
          ),
        );
        if (!hasPlaybackControl(request.requestKey) &&
            !_hasPlaybackEventListenersForRequest(request.requestKey)) {
          releaseRequestIdentity(request.requestKey);
        }
      }

      unawaited(item.controller.close());
      return false;
    } catch (error) {
      final failure = _mapRequestFailure(error, request);
      await _cancelPlaybackEventListenersForRequest(request.requestKey);
      unregisterPlaybackControl(request.requestKey);
      emitRequestEvent(
        TtsRequestEventType.requestSynthesisFailed,
        requestKey: request.requestKey,
        state: TtsRequestState.failed,
        error: failure.ttsError,
        outputId: failure.outputId,
        outputError: failure.outputError,
      );
      item.completeSynthesisResult(
        TtsSynthesisFailedResult(
          requestKey: request.requestKey,
          utteranceId: request.utteranceId,
          error: failure.ttsError,
        ),
      );
      releaseRequestIdentity(request.requestKey);
      item.controller.addError(failure.ttsError);
      unawaited(item.controller.close());

      if (config.queueFailurePolicy == TtsQueueFailurePolicy.failFast) {
        state.haltQueue();
        emitQueueEvent(
          TtsQueueEventType.queueHalted,
          queueLength: scheduler.length,
          requestKey: request.requestKey,
        );
        await cancelPendingAfterFailure();
        return true;
      }

      return false;
    } finally {
      state.activeControl = null;
      state.activeRequestKey = null;
    }
  }

  Future<void> handleSynthesizedChunk(
    QueuedRequest item,
    TtsRequest request,
    TtsChunk chunk,
    TtsOutput effectiveOutput,
  ) async {
    // Semantic chunks (for example sentence timing) belong to the request
    // stream, not to an audio sink. This also lets an engine publish timing
    // before the first audio chunk has opened an output write.
    if (chunk is! TtsAudioChunk) {
      item.controller.add(chunk);
      emitRequestEvent(
        TtsRequestEventType.requestChunkReceived,
        requestKey: request.requestKey,
        state: TtsRequestState.running,
        chunk: chunk,
      );
      return;
    }

    await effectiveOutput.writeChunk(chunk);
    item.controller.add(chunk);
    emitRequestEvent(
      TtsRequestEventType.requestChunkReceived,
      requestKey: request.requestKey,
      state: TtsRequestState.running,
      chunk: chunk,
    );
  }

  Future<void> cancelPendingAfterFailure() async {
    final pending = scheduler.drain();
    for (final item in pending) {
      emitRequestEvent(
        TtsRequestEventType.requestCanceled,
        requestKey: item.request.requestKey,
        state: TtsRequestState.canceled,
      );
      item.completeSynthesisResult(
        TtsSynthesisStoppedResult(
          requestKey: item.request.requestKey,
          utteranceId: item.request.utteranceId,
          reason: TtsSynthesisStopReason.queueHalted,
        ),
      );
      unawaited(item.controller.close());
      releaseRequestIdentity(item.request.requestKey);
    }
  }

  TtsAudioSpec resolveAudioSpec(TtsRequest request, TtsOutput effectiveOutput) {
    return formatNegotiator.negotiateSpec(
      engineCapabilities: engine.outAudioCapabilities,
      outputCapabilities: effectiveOutput.inAudioCapabilities,
      preferredOrder: config.preferredFormatOrder,
      requestKey: request.requestKey,
      preferredFormat: request.preferredFormat,
      preferredSampleRateHz: request.options?.sampleRateHz,
    );
  }
}

_RequestFailure _mapRequestFailure(Object error, TtsRequest request) {
  final outputFailure = error is TtsOutputFailure ? error : null;
  final outputError = outputFailure?.error;
  final baseError = outputError ?? (error is TtsError ? error : null);
  final ttsError = baseError != null
      ? TtsError(
          code: baseError.code,
          message: baseError.message,
          requestKey: baseError.requestKey ?? request.requestKey,
          cause: baseError.cause,
        )
      : TtsError(
          code: TtsErrorCode.internalError,
          message: 'Request processing failed.',
          requestKey: request.requestKey,
          cause: error,
        );

  return _RequestFailure(
    ttsError: ttsError,
    outputId: outputFailure?.outputId,
    outputError: outputError,
  );
}

final class _RequestFailure {
  const _RequestFailure({
    required this.ttsError,
    required this.outputId,
    required this.outputError,
  });

  final TtsError ttsError;
  final String? outputId;
  final TtsError? outputError;
}
