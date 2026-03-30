import 'dart:async';

import 'package:meta/meta.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_engine.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_flow_config.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
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

  bool get isPaused => state.isPaused;
  bool get isInitialized => state.isInitialized;

  Future<void> init() async {
    _ensureNotDisposed();
    if (state.isInitialized) {
      return;
    }

    await _engine.init();
    await _defaultOutput?.init();
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

  Stream<TtsChunk> speak(
    String requestId,
    String text, {
    Map<String, Object> params = const <String, Object>{},
    TtsOutput? output,
  }) {
    _ensureReady();

    if (output == null && defaultOutput == null) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message: 'No effective output configured for request.',
        requestId: requestId,
      );
    }

    final request = buildRequest(
      requestId: requestId,
      text: text,
      params: params,
      output: output,
    );

    state.unhaltOnEnqueue();

    final controller = StreamController<TtsChunk>();
    final queued = QueuedRequest(request: request, controller: controller);
    scheduler.enqueue(queued);

    emitRequestEvent(
      TtsRequestEventType.requestQueued,
      requestId: request.requestId,
      state: TtsRequestState.queued,
    );
    emitQueueEvent(
      TtsQueueEventType.requestEnqueued,
      queueLength: scheduler.length,
      requestId: request.requestId,
    );

    unawaited(processQueue());
    return controller.stream;
  }

  Future<void> pause() async {
    _ensureReady();
    state.pauseQueue();
  }

  Future<void> resume() async {
    _ensureReady();
    state.resumeQueue();
    unawaited(processQueue());
  }

  Future<void> stopCurrent() async {
    _ensureReady();
    state.activeControl?.cancel(CancelReason.stopCurrent);
  }

  Future<int> clearQueue() async {
    _ensureNotDisposed();
    final pending = scheduler.drain();
    for (final item in pending) {
      emitRequestEvent(
        TtsRequestEventType.requestCanceled,
        requestId: item.request.requestId,
        state: TtsRequestState.canceled,
      );
      unawaited(item.controller.close());
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
    await clearQueue();
    await _awaitActiveRequestShutdown();
    await disposePlaybackCompletionListeners();
    await _engine.dispose();
    await _defaultOutput?.dispose();
    state.markDisposed();
    await eventBus.close();
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
