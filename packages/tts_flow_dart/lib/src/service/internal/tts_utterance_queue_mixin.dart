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

part 'tts_utterance_queue_request_processor.dart';

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
