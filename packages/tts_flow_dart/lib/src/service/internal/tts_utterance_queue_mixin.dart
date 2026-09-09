import 'dart:async';

import 'package:meta/meta.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_engine.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_flow_config.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_synthesis_result.dart';
import 'package:tts_flow_dart/src/core/tts_synthesis_admission_policy.dart';
import 'package:tts_flow_dart/src/service/format_negotiator.dart';
import 'package:tts_flow_dart/src/service/queue_scheduler.dart';
import 'package:tts_flow_dart/src/service/tts_events.dart';

import 'tts_flow_event_mixin.dart';
import 'tts_flow_state.dart';

final class QueuedRequest {
  QueuedRequest({
    required this.request,
    required this.controller,
    required this.synthesisResultCompleter,
  });

  final TtsRequest request;
  final StreamController<TtsChunk> controller;
  final Completer<TtsSynthesisResult> synthesisResultCompleter;

  void completeSynthesisResult(TtsSynthesisResult result) {
    if (!synthesisResultCompleter.isCompleted) {
      synthesisResultCompleter.complete(result);
    }
  }
}

mixin TtsUtteranceQueueMixin on TtsFlowEventBus {
  TtsEngine get engine;
  TtsOutput? get defaultOutput;
  TtsFlowConfig get config;

  @protected
  Future<void> ensureOutputInitialized(TtsOutput output);

  @protected
  void registerPlaybackControl(String requestKey, TtsOutput output);

  @protected
  void unregisterPlaybackControl(String requestKey);

  @protected
  bool hasPlaybackControl(String requestKey);

  @protected
  int get outstandingPlaybackRequestCount;

  @protected
  void releaseRequestIdentity(String requestKey);

  @protected
  final formatNegotiator = const TtsFormatNegotiator();

  @protected
  final scheduler = QueueScheduler<QueuedRequest>();

  @protected
  final state = TtsFlowState();

  final Map<String, StreamSubscription<TtsOutputPlaybackCompletedEvent>>
  _playbackCompletionSubscriptions =
      <String, StreamSubscription<TtsOutputPlaybackCompletedEvent>>{};
  final Map<String, StreamSubscription<TtsOutputPlaybackFailedEvent>>
  _playbackFailureSubscriptions =
      <String, StreamSubscription<TtsOutputPlaybackFailedEvent>>{};
  var _queueProcessingRequested = false;

  @protected
  Future<void> processQueue() async {
    if (!state.tryEnterProcessing()) {
      // A playback terminal event or a custom admission-policy refresh can
      // arrive while the current request is still unwinding. Remember it so
      // the next admission check is not lost when this processing turn exits.
      _queueProcessingRequested = true;
      return;
    }

    try {
      while (!scheduler.isEmpty && !state.isDisposed) {
        // Pause gates only the start of the next request. An already-active
        // request continues its low-latency output path unchanged.
        if (state.isPaused) {
          break;
        }

        final admissionSnapshot = TtsSynthesisAdmissionSnapshot(
          pendingRequestCount: scheduler.length,
          outstandingPlaybackRequestCount: outstandingPlaybackRequestCount,
        );
        if (!config.synthesisAdmissionPolicy.allowsNextSynthesis(
          admissionSnapshot,
        )) {
          break;
        }

        final item = scheduler.dequeue();
        final shouldStopQueue = await processQueuedRequest(item);
        if (shouldStopQueue || state.isHalted) {
          break;
        }
      }
    } finally {
      state.exitProcessing();
      final shouldProcessAgain = _queueProcessingRequested;
      _queueProcessingRequested = false;
      if (shouldProcessAgain && !scheduler.isEmpty && !state.isDisposed) {
        unawaited(processQueue());
      }
    }
  }

  @protected
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

        if (chunk is! TtsAudioChunk) {
        } else if (!outputWriteStarted) {
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

        await handleSynthesizedChunk(
          item,
          request,
          control,
          chunk,
          effectiveOutput,
        );
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

  @protected
  Future<void> handleSynthesizedChunk(
    QueuedRequest item,
    TtsRequest request,
    SynthesisControl control,
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

  @protected
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

  @protected
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

  @protected
  Future<void> disposePlaybackCompletionListeners() async {
    final subscriptions = <StreamSubscription<dynamic>>[
      ..._playbackCompletionSubscriptions.values,
      ..._playbackFailureSubscriptions.values,
    ];
    _playbackCompletionSubscriptions.clear();
    _playbackFailureSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  /// Stops forwarding physical-playback terminal events for [requestKey].
  ///
  /// A caller that explicitly stops playback has already established its
  /// terminal state, so retaining these subscriptions can otherwise leave a
  /// stale listener behind when a backend does not publish a terminal event.
  @protected
  Future<void> cancelPlaybackEventListenersForRequest(String requestKey) {
    return _cancelPlaybackEventListenersForRequest(requestKey);
  }

  Future<void> _registerPlaybackEventListeners({
    required String requestKey,
    required TtsOutput output,
  }) async {
    await _cancelPlaybackEventListenersForRequest(requestKey);

    final PlaybackControllableOutput? controllableOutput =
        output is PlaybackControllableOutput
        ? output as PlaybackControllableOutput
        : null;

    if (output case final PlaybackAwareOutput playbackAwareOutput) {
      final events = playbackAwareOutput.playbackCompletedEvents.where(
        (event) => event.requestKey == requestKey,
      );
      final subscription =
          (controllableOutput == null ? events.take(1) : events).listen(
            (event) {
              emitRequestEvent(
                TtsRequestEventType.requestPlaybackCompleted,
                requestKey: event.requestKey,
                state: TtsRequestState.completed,
                outputId: event.outputId,
                playbackId: event.playbackId,
                playedDuration: event.playedDuration,
              );
              // A matching event is the output's authoritative physical
              // terminal signal. Do not require its active-state map to have
              // been updated first: implementations may emit before clearing
              // that map, and the admission policy must not retain stale
              // playback backlog in either ordering.
              unregisterPlaybackControl(requestKey);
              unawaited(_finishPhysicalPlayback(requestKey));
            },
            onDone: () {
              _playbackCompletionSubscriptions.remove(requestKey);
            },
          );
      _playbackCompletionSubscriptions[requestKey] = subscription;
    }

    if (output case final PlaybackFailureAwareOutput failureAwareOutput) {
      final events = failureAwareOutput.playbackFailedEvents.where(
        (event) => event.requestKey == requestKey,
      );
      final subscription =
          (controllableOutput == null ? events.take(1) : events).listen(
            (event) {
              // Physical playback can fail after synthesis has already
              // been emitted. This is an independent terminal playback event,
              // not a retroactive synthesis/request state transition.
              emitRequestEvent(
                TtsRequestEventType.requestPlaybackFailed,
                requestKey: event.requestKey,
                outputId: event.outputId,
                playbackId: event.playbackId,
                error: event.error,
              );
              unregisterPlaybackControl(requestKey);
              unawaited(_finishPhysicalPlayback(requestKey));
            },
            onDone: () {
              _playbackFailureSubscriptions.remove(requestKey);
            },
          );
      _playbackFailureSubscriptions[requestKey] = subscription;
    }
  }

  Future<void> _cancelPlaybackEventListenersForRequest(
    String requestKey,
  ) async {
    await _cancelPlaybackCompletionListenerForRequest(requestKey);
    await _cancelPlaybackFailureListenerForRequest(requestKey);
  }

  bool _hasPlaybackEventListenersForRequest(String requestKey) =>
      _playbackCompletionSubscriptions.containsKey(requestKey) ||
      _playbackFailureSubscriptions.containsKey(requestKey);

  Future<void> _finishPhysicalPlayback(String requestKey) async {
    // This method is invoked from a playback stream listener. Yield once so a
    // subscription is never awaited while its own callback is still running.
    await Future<void>.microtask(() {});
    await _cancelPlaybackEventListenersForRequest(requestKey);
    releaseRequestIdentity(requestKey);
    unawaited(processQueue());
  }

  Future<void> _cancelPlaybackCompletionListenerForRequest(
    String requestKey,
  ) async {
    final subscription = _playbackCompletionSubscriptions.remove(requestKey);
    await subscription?.cancel();
  }

  Future<void> _cancelPlaybackFailureListenerForRequest(
    String requestKey,
  ) async {
    final subscription = _playbackFailureSubscriptions.remove(requestKey);
    await subscription?.cancel();
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
