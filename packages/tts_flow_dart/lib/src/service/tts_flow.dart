import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_engine.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_flow_config.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_request_handle.dart';
import 'package:tts_flow_dart/src/core/tts_synthesis_result.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';
import 'package:tts_flow_dart/src/service/internal/tts_utterance_queue_mixin.dart';
import 'package:tts_flow_dart/src/service/tts_events.dart';

import 'internal/tts_flow_event_mixin.dart';
import 'internal/tts_options_mixin.dart';

final class TtsFlow
    with TtsOptionsMixin, TtsFlowEventBus, TtsUtteranceQueueMixin {
  TtsFlow({
    required TtsEngine engine,
    TtsOutput? defaultOutput,
    TtsFlowConfig config = const TtsFlowConfig(),
  }) : _engine = engine,
       _defaultOutput = defaultOutput,
       _config = config,
       options = const TtsOptions(),
       preferredFormat = config.preferredFormatOrder.first;

  final TtsEngine _engine;
  final TtsOutput? _defaultOutput;
  final TtsFlowConfig _config;
  final _managedOutputs = HashSet<TtsOutput>.identity();
  final _outputInitializations = HashMap<TtsOutput, Future<void>>.identity();
  final _playbackOutputs = <String, TtsOutput>{};
  final _utteranceIdsByRequestKey = <String, String>{};
  final _requestEventControllers =
      <String, StreamController<TtsRequestEvent>>{};
  var _nextRequestKey = 0;

  @override
  TtsEngine get engine => _engine;

  @override
  TtsOutput? get defaultOutput => _defaultOutput;

  @override
  TtsFlowConfig get config => _config;

  @protected
  @override
  final eventBus = StreamController<TtsFlowEvent>.broadcast();

  @protected
  @override
  TtsOptions options;

  @override
  TtsAudioFormat preferredFormat;

  @override
  late TtsVoice voice;

  Stream<TtsQueueEvent> get queueEvents => eventBus.stream
      .where((event) => event is TtsQueueEvent)
      .cast<TtsQueueEvent>();
  Stream<TtsRequestEvent> get requestEvents => eventBus.stream
      .where((event) => event is TtsRequestEvent)
      .cast<TtsRequestEvent>();

  @override
  @protected
  String? utteranceIdForRequestKey(String requestKey) =>
      _utteranceIdsByRequestKey[requestKey];

  @override
  @protected
  void onRequestEventEmitted(TtsRequestEvent event) {
    _requestEventControllers[event.requestKey]?.add(event);
  }

  bool get isQueuePaused => state.isPaused;
  bool get isInitialized => state.isInitialized;

  bool _hasActivePlayback(String requestKey) {
    final output = _playbackOutputs[requestKey];
    final PlaybackControllableOutput? controllableOutput =
        output is PlaybackControllableOutput
        ? output as PlaybackControllableOutput
        : null;
    return controllableOutput?.hasActivePlayback(requestKey) ?? false;
  }

  Future<void> init() async {
    _ensureNotDisposed();
    if (state.isInitialized) {
      return;
    }

    await _engine.init();
    final defaultOutput = _defaultOutput;
    if (defaultOutput != null) {
      await ensureOutputInitialized(defaultOutput);
    }
    voice = await _engine.getDefaultVoice();

    state.markInitialized();
  }

  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    _ensureNotDisposed();
    return _engine.getAvailableVoices(locale: locale);
  }

  Future<TtsVoice> getDefaultVoice() async {
    _ensureNotDisposed();
    return _engine.getDefaultVoice();
  }

  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    _ensureNotDisposed();
    return _engine.getDefaultVoiceForLocale(locale);
  }

  /// Enqueues [text] and returns the handle for this concrete request.
  ///
  /// [utteranceId] is an application correlation label and may be reused.
  /// The flow always generates an independent, opaque [TtsRequestHandle.requestKey]
  /// for pipeline routing and controls.
  TtsRequestHandle speak(
    String text, {
    String? utteranceId,
    Map<String, Object> params = const <String, Object>{},
    TtsOutput? output,
  }) {
    _ensureReady();

    final requestKey = 'request-${++_nextRequestKey}';
    final resolvedUtteranceId = utteranceId ?? requestKey;

    if (engine.maxInputByteSize > 0 && text.length > engine.maxInputByteSize) {
      throw TtsError(
        code: TtsErrorCode.maxInputByteSizeExceeded,
        message: 'Text length exceeds maximum allowed byte size.',
        requestKey: requestKey,
      );
    }

    if (output == null && defaultOutput == null) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message: 'No effective output configured for request.',
        requestKey: requestKey,
      );
    }

    final request = buildRequest(
      requestKey: requestKey,
      utteranceId: resolvedUtteranceId,
      text: text,
      params: params,
      output: output,
    );

    state.unhaltOnEnqueue();
    _utteranceIdsByRequestKey[requestKey] = resolvedUtteranceId;
    final requestEvents = StreamController<TtsRequestEvent>();
    _requestEventControllers[requestKey] = requestEvents;

    final controller = StreamController<TtsChunk>();
    final synthesisResultCompleter = Completer<TtsSynthesisResult>();
    final queued = QueuedRequest(
      request: request,
      controller: controller,
      synthesisResultCompleter: synthesisResultCompleter,
    );
    scheduler.enqueue(queued);

    emitRequestEvent(
      TtsRequestEventType.requestQueued,
      requestKey: request.requestKey,
      state: TtsRequestState.queued,
    );
    emitQueueEvent(
      TtsQueueEventType.requestEnqueued,
      queueLength: scheduler.length,
      requestKey: request.requestKey,
    );

    unawaited(processQueue());
    return TtsRequestHandle(
      requestKey: requestKey,
      utteranceId: resolvedUtteranceId,
      chunks: controller.stream,
      events: requestEvents.stream,
      synthesisResult: synthesisResultCompleter.future,
      stopSynthesis: () => _stopSynthesis(requestKey),
      pausePlayback: () => _pausePlayback(requestKey),
      resumePlayback: () => _resumePlayback(requestKey),
      stopPlayback: () => _stopPlayback(requestKey),
      hasActivePlayback: () => _hasActivePlayback(requestKey),
    );
  }

  /// Prevents the queue from starting another synthesis request.
  Future<void> pauseQueue() async {
    _ensureReady();
    state.pauseQueue();
  }

  /// Allows queued synthesis requests to start again.
  Future<void> resumeQueue() async {
    _ensureReady();
    state.resumeQueue();
    unawaited(processQueue());
  }

  /// Re-evaluates whether the configured synthesis admission policy permits
  /// another pending request to begin.
  ///
  /// A custom policy can call this after its own external state changes. This
  /// does not resume a queue paused through [pauseQueue].
  Future<void> refreshSynthesisAdmission() async {
    _ensureReady();
    await processQueue();
  }

  /// Cancels the synthesis request currently being produced by the engine.
  ///
  /// This does not control audio that has already been finalized for physical
  /// playback. Use the corresponding `TtsRequestHandle.stopPlayback()` for
  /// that separate lifecycle.
  Future<void> stopActiveSynthesis() async {
    _ensureReady();
    state.activeControl?.cancel(CancelReason.stopCurrent);
  }

  Future<void> _stopSynthesis(String requestKey) async {
    _ensureReady();
    if (state.activeRequestKey == requestKey) {
      state.activeControl?.cancel(CancelReason.stopCurrent);
      return;
    }

    final queued = scheduler.removeFirstWhere(
      (item) => item.request.requestKey == requestKey,
    );
    if (queued == null) {
      return;
    }

    emitRequestEvent(
      TtsRequestEventType.requestSynthesisStopped,
      requestKey: requestKey,
      state: TtsRequestState.stopped,
    );
    queued.completeSynthesisResult(
      TtsSynthesisStoppedResult(
        requestKey: requestKey,
        utteranceId: queued.request.utteranceId,
        reason: TtsSynthesisStopReason.requested,
      ),
    );
    unawaited(queued.controller.close());
    releaseRequestIdentity(requestKey);
  }

  Future<void> _pausePlayback(String requestKey) async {
    final output = _requirePlaybackOutput(requestKey);
    await (output as PlaybackControllableOutput).pausePlayback(requestKey);
    emitRequestEvent(
      TtsRequestEventType.requestPlaybackPaused,
      requestKey: requestKey,
      outputId: output.outputId,
    );
  }

  Future<void> _resumePlayback(String requestKey) async {
    final output = _requirePlaybackOutput(requestKey);
    await (output as PlaybackControllableOutput).resumePlayback(requestKey);
    emitRequestEvent(
      TtsRequestEventType.requestPlaybackResumed,
      requestKey: requestKey,
      outputId: output.outputId,
    );
  }

  Future<void> _stopPlayback(String requestKey) async {
    final output = _requirePlaybackOutput(requestKey);
    await (output as PlaybackControllableOutput).stopPlayback(requestKey);
    await cancelPlaybackEventListenersForRequest(requestKey);
    unregisterPlaybackControl(requestKey);
    emitRequestEvent(
      TtsRequestEventType.requestPlaybackStopped,
      requestKey: requestKey,
      outputId: output.outputId,
    );
    releaseRequestIdentity(requestKey);
    unawaited(processQueue());
  }

  Future<int> clearQueue() => _clearQueue(TtsSynthesisStopReason.queueCleared);

  Future<int> _clearQueue(TtsSynthesisStopReason reason) async {
    _ensureNotDisposed();
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
          reason: reason,
        ),
      );
      unawaited(item.controller.close());
      releaseRequestIdentity(item.request.requestKey);
    }

    if (pending.isNotEmpty) {
      emitQueueEvent(
        TtsQueueEventType.queueCleared,
        queueLength: scheduler.length,
      );
    }
    return pending.length;
  }

  Future<void> dispose() async {
    if (state.isDisposed) {
      return;
    }

    state.activeControl?.cancel(CancelReason.serviceDispose);
    await _clearQueue(TtsSynthesisStopReason.serviceDisposed);
    await _awaitActiveRequestShutdown();
    await disposePlaybackCompletionListeners();
    await _engine.dispose();
    await _disposeManagedOutputs();
    _playbackOutputs.clear();
    _utteranceIdsByRequestKey.clear();
    for (final controller in _requestEventControllers.values) {
      // A request event stream is single-subscription. Its close future waits
      // for a listener that may never have been attached, so disposal must not
      // wait for it after output resources are already released.
      unawaited(controller.close());
    }
    _requestEventControllers.clear();
    state.markDisposed();
    await eventBus.close();
  }

  /// Initializes [output] at most once for this flow.
  ///
  /// `TtsFlow` owns every output passed to it, including request-level output
  /// overrides, and disposes those outputs when the flow is disposed.
  @override
  @protected
  Future<void> ensureOutputInitialized(TtsOutput output) async {
    _managedOutputs.add(output);

    final existingInitialization = _outputInitializations[output];
    if (existingInitialization != null) {
      await existingInitialization;
      return;
    }

    final initialization = Future<void>.sync(output.init);
    _outputInitializations[output] = initialization;
    try {
      await initialization;
    } catch (_) {
      if (identical(_outputInitializations[output], initialization)) {
        _outputInitializations.remove(output);
      }
      rethrow;
    }
  }

  @override
  @protected
  void registerPlaybackControl(String requestKey, TtsOutput output) {
    if (output is PlaybackControllableOutput) {
      _playbackOutputs[requestKey] = output;
    }
  }

  @override
  @protected
  void unregisterPlaybackControl(String requestKey) {
    _playbackOutputs.remove(requestKey);
  }

  @override
  @protected
  bool hasPlaybackControl(String requestKey) =>
      _playbackOutputs.containsKey(requestKey);

  @override
  @protected
  int get outstandingPlaybackRequestCount => _playbackOutputs.length;

  @override
  @protected
  void releaseRequestIdentity(String requestKey) {
    _utteranceIdsByRequestKey.remove(requestKey);
    final controller = _requestEventControllers.remove(requestKey);
    if (controller != null) {
      unawaited(controller.close());
    }
  }

  TtsOutput _requirePlaybackOutput(String requestKey) {
    _ensureReady();
    final output = _playbackOutputs[requestKey];
    final PlaybackControllableOutput? controllableOutput =
        output is PlaybackControllableOutput
        ? output as PlaybackControllableOutput
        : null;
    if (output == null || controllableOutput == null) {
      throw StateError('No active controllable playback for "$requestKey".');
    }
    if (!controllableOutput.hasActivePlayback(requestKey)) {
      _playbackOutputs.remove(requestKey);
      throw StateError('Playback is no longer active for "$requestKey".');
    }
    return output;
  }

  Future<void> _disposeManagedOutputs() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    for (final output in _managedOutputs) {
      try {
        await output.dispose();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _managedOutputs.clear();
    _outputInitializations.clear();

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _awaitActiveRequestShutdown() async {
    const pollInterval = Duration(milliseconds: 10);
    const timeout = Duration(milliseconds: 500);
    final deadline = DateTime.now().add(timeout);

    while (state.activeControl != null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
    }
  }

  void _ensureNotDisposed() {
    state.ensureNotDisposed();
  }

  void _ensureReady() {
    state.ensureReady();
  }
}
