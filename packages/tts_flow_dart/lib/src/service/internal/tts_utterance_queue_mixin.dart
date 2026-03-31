import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_engine.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_flow_config.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/service/format_negotiator.dart';
import 'package:tts_flow_dart/src/service/queue_scheduler.dart';
import 'package:tts_flow_dart/src/service/tts_events.dart';

import 'tts_flow_event_mixin.dart';
import 'tts_flow_state.dart';

final _log = Logger('tts_flow_dart');

final class QueuedRequest {
  const QueuedRequest({required this.request, required this.controller});

  final TtsRequest request;
  final StreamController<TtsChunk> controller;
}

mixin TtsUtteranceQueueMixin on TtsFlowEventBus {
  TtsEngine get engine;
  TtsOutput? get defaultOutput;
  TtsFlowConfig get config;

  @protected
  final formatNegotiator = const TtsFormatNegotiator();

  @protected
  final scheduler = QueueScheduler<QueuedRequest>();

  @protected
  final state = TtsFlowState();

  final Map<String, StreamSubscription<TtsOutputPlaybackCompletedEvent>>
  _playbackCompletionSubscriptions =
      <String, StreamSubscription<TtsOutputPlaybackCompletedEvent>>{};

  @protected
  Future<void> processQueue() async {
    if (!state.tryEnterProcessing()) {
      return;
    }

    try {
      while (!scheduler.isEmpty && !state.isDisposed) {
        // Pause gates starting the next request. Active request handling
        // continues in-loop using buffering/passthrough policy.
        if (state.isPaused) {
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
    }
  }

  @protected
  Future<void> flushPauseBufferImpl(
    QueuedRequest item,
    TtsRequest request,
    SynthesisControl control,
    TtsOutput effectiveOutput,
  ) async {
    final toFlush = List<TtsChunk>.of(state.pauseBuffer);
    state.clearPauseBuffer();

    for (final chunk in toFlush) {
      if (control.isCanceled) {
        break;
      }
      await effectiveOutput.consumeChunk(chunk);
      item.controller.add(chunk);
      emitRequestEvent(
        TtsRequestEventType.requestChunkReceived,
        requestId: request.requestId,
        state: TtsRequestState.running,
        chunk: chunk,
      );
    }
  }

  @protected
  Future<bool> processQueuedRequest(QueuedRequest item) async {
    final request = item.request;
    final effectiveOutput = request.output ?? defaultOutput!;

    _registerPlaybackCompletionListener(
      requestId: request.requestId,
      output: effectiveOutput,
    );

    final control = SynthesisControl();
    state.activeControl = control;

    emitQueueEvent(
      TtsQueueEventType.requestDequeued,
      queueLength: scheduler.length,
      requestId: request.requestId,
    );
    emitRequestEvent(
      TtsRequestEventType.requestStarted,
      requestId: request.requestId,
      state: TtsRequestState.running,
    );

    try {
      final audioSpec = resolveAudioSpec(request, effectiveOutput);
      if (!engine.supportsSpec(audioSpec)) {
        throw TtsError(
          code: TtsErrorCode.formatNegotiationFailed,
          message:
              'Negotiated audio spec is not supported by engine "${engine.engineId}".',
          requestId: request.requestId,
        );
      }
      var activeAudioSpec = audioSpec;
      var outputSessionInitialized = false;

      Future<void> ensureOutputSessionInitialized(TtsAudioSpec spec) async {
        if (outputSessionInitialized) {
          return;
        }
        if (!effectiveOutput.acceptsSpec(spec)) {
          throw TtsError(
            code: TtsErrorCode.formatNegotiationFailed,
            message:
                'Resolved audio spec is not accepted by output "${effectiveOutput.outputId}".',
            requestId: request.requestId,
          );
        }

        await effectiveOutput.initSession(
          TtsOutputSession(
            requestId: request.requestId,
            audioSpec: spec,
            voice: request.voice,
            options: request.options,
            params: request.params,
          ),
        );
        activeAudioSpec = spec;
        outputSessionInitialized = true;
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
        } else if (!outputSessionInitialized) {
          await ensureOutputSessionInitialized(chunk.audioSpec);
        } else if (chunk.audioSpec != activeAudioSpec) {
          throw TtsError(
            code: TtsErrorCode.invalidRequest,
            message:
                'Chunk audio spec changed after session initialization. '
                'expected: $activeAudioSpec, received: ${chunk.audioSpec}',
            requestId: request.requestId,
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

      if (!control.isCanceled && state.pauseBuffer.isNotEmpty) {
        while (state.isPaused && !state.isDisposed && !control.isCanceled) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (!control.isCanceled) {
          await flushPauseBufferImpl(item, request, control, effectiveOutput);
        }
      }

      if (control.isCanceled) {
        if (outputSessionInitialized) {
          await effectiveOutput.onCancelSession(control);
        }
        await _cancelPlaybackCompletionListenerForRequest(request.requestId);
        emitRequestEvent(
          TtsRequestEventType.requestStopped,
          requestId: request.requestId,
          state: TtsRequestState.stopped,
        );
      } else {
        if (!outputSessionInitialized) {
          await ensureOutputSessionInitialized(audioSpec);
        }
        await effectiveOutput.finalizeSession();
        emitRequestEvent(
          TtsRequestEventType.requestCompleted,
          requestId: request.requestId,
          state: TtsRequestState.completed,
        );
      }

      unawaited(item.controller.close());
      return false;
    } catch (error) {
      final failure = _mapRequestFailure(error, request);
      await _cancelPlaybackCompletionListenerForRequest(request.requestId);
      emitRequestEvent(
        TtsRequestEventType.requestFailed,
        requestId: request.requestId,
        state: TtsRequestState.failed,
        error: failure.ttsError,
        outputId: failure.outputId,
        outputError: failure.outputError,
      );
      item.controller.addError(failure.ttsError);
      unawaited(item.controller.close());

      if (config.queueFailurePolicy == TtsQueueFailurePolicy.failFast) {
        state.haltQueue();
        emitQueueEvent(
          TtsQueueEventType.queueHalted,
          queueLength: scheduler.length,
          requestId: request.requestId,
        );
        await cancelPendingAfterFailure();
        return true;
      }

      return false;
    } finally {
      state.activeControl = null;
      state.clearPauseBuffer();
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
    // Flush buffered chunks before handling fresh chunks after resume.
    if (state.pauseBuffer.isNotEmpty && !state.isPaused) {
      await flushPauseBufferImpl(item, request, control, effectiveOutput);
      if (control.isCanceled) {
        return;
      }
    }

    if (state.isPaused &&
        config.pauseBufferPolicy == TtsPauseBufferPolicy.buffered) {
      state.pauseBuffer.add(chunk);
      if (chunk is TtsAudioChunk) {
        final newBytes = state.pauseBufferBytes + chunk.bytes.length;
        if (state.pauseBufferBytes <= config.pauseBufferMaxBytes &&
            newBytes > config.pauseBufferMaxBytes) {
          _log.warning(
            'TTS pause buffer exceeded ${config.pauseBufferMaxBytes} '
            'bytes (current: $newBytes); chunks continue to accumulate.',
          );
        }
        state.pauseBufferBytes = newBytes;
      }
      return;
    }

    await effectiveOutput.consumeChunk(chunk);
    item.controller.add(chunk);
    emitRequestEvent(
      TtsRequestEventType.requestChunkReceived,
      requestId: request.requestId,
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
        requestId: item.request.requestId,
        state: TtsRequestState.canceled,
      );
      unawaited(item.controller.close());
    }
  }

  @protected
  TtsAudioSpec resolveAudioSpec(TtsRequest request, TtsOutput effectiveOutput) {
    return formatNegotiator.negotiateSpec(
      engineCapabilities: engine.outAudioCapabilities,
      outputCapabilities: effectiveOutput.inAudioCapabilities,
      preferredOrder: config.preferredFormatOrder,
      requestId: request.requestId,
      preferredFormat: request.preferredFormat,
      preferredSampleRateHz: request.options?.sampleRateHz,
    );
  }

  @protected
  Future<void> disposePlaybackCompletionListeners() async {
    final subscriptions = _playbackCompletionSubscriptions.values.toList();
    _playbackCompletionSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  void _registerPlaybackCompletionListener({
    required String requestId,
    required TtsOutput output,
  }) {
    if (output is! PlaybackAwareOutput) {
      return;
    }
    final playbackAwareOutput = output as PlaybackAwareOutput;

    unawaited(_cancelPlaybackCompletionListenerForRequest(requestId));

    final subscription = playbackAwareOutput.playbackCompletedEvents
        .where((event) => event.requestId == requestId)
        .take(1)
        .listen(
          (event) {
            emitRequestEvent(
              TtsRequestEventType.requestPlaybackCompleted,
              requestId: event.requestId,
              state: TtsRequestState.completed,
              outputId: event.outputId,
              playbackId: event.playbackId,
              playedDuration: event.playedDuration,
            );
          },
          onDone: () {
            _playbackCompletionSubscriptions.remove(requestId);
          },
        );

    _playbackCompletionSubscriptions[requestId] = subscription;
  }

  Future<void> _cancelPlaybackCompletionListenerForRequest(
    String requestId,
  ) async {
    final subscription = _playbackCompletionSubscriptions.remove(requestId);
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
          requestId: baseError.requestId ?? request.requestId,
          cause: baseError.cause,
        )
      : TtsError(
          code: TtsErrorCode.internalError,
          message: 'Request processing failed.',
          requestId: request.requestId,
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
