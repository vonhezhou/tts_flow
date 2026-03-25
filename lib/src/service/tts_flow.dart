import 'dart:async';
import 'dart:developer';

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
import 'package:tts_flow_dart/src/core/tts_voice.dart';
import 'package:tts_flow_dart/src/service/format_negotiator.dart';
import 'package:tts_flow_dart/src/service/queue_scheduler.dart';
import 'package:tts_flow_dart/src/service/tts_events.dart';

import 'internal/tts_flow_event_mixin.dart';
import 'internal/tts_options_mixin.dart';

part 'internal/tts_flow_request_helpers.dart';
part 'internal/tts_flow_request_runtime.dart';
part 'internal/tts_flow_runtime.dart';
part 'internal/tts_flow_state.dart';

final class TtsFlow with TtsOptionsMixin, TtsFlowEventBus {
  TtsFlow({
    required TtsEngine engine,
    required TtsOutput output,
    TtsFlowConfig config = const TtsFlowConfig(),
  })  : _engine = engine,
        _output = output,
        _config = config,
        options = const TtsOptions(),
        preferredFormat = config.preferredFormatOrder.first;

  final TtsEngine _engine;
  final TtsOutput _output;
  final TtsFlowConfig _config;
  final _formatNegotiator = const TtsFormatNegotiator();
  final _scheduler = QueueScheduler<_QueuedRequest>();

  final _state = _TtsFlowState();

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

  bool get isPaused => _state.isPaused;
  bool get isInitialized => _state.isInitialized;

  Future<void> init() async {
    _ensureNotDisposed();
    if (_state.isInitialized) {
      return;
    }

    voice = await _engine.getDefaultVoice();

    _state.markInitialized();
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
    String text, [
    Map<String, Object> params = const <String, Object>{},
  ]) {
    _ensureReady();

    final request = buildRequest(
      requestId: requestId,
      text: text,
      params: params,
    );

    _state.unhaltOnEnqueue();

    final controller = StreamController<TtsChunk>();
    final queued = _QueuedRequest(request: request, controller: controller);
    _scheduler.enqueue(queued);

    emitRequestEvent(
      TtsRequestEventType.requestQueued,
      requestId: request.requestId,
      state: TtsRequestState.queued,
    );
    emitQueueEvent(
      TtsQueueEventType.requestEnqueued,
      queueLength: _scheduler.length,
      requestId: request.requestId,
    );

    unawaited(_processQueue());
    return controller.stream;
  }

  Future<void> pause() async {
    _ensureReady();
    _state.pauseQueue();
  }

  Future<void> resume() async {
    _ensureReady();
    _state.resumeQueue();
    unawaited(_processQueue());
  }

  Future<void> stopCurrent() async {
    _ensureReady();
    _state.activeControl?.cancel(CancelReason.stopCurrent);
  }

  Future<int> clearQueue() async {
    _ensureNotDisposed();
    final pending = _scheduler.drain();
    for (final item in pending) {
      emitRequestEvent(
        TtsRequestEventType.requestCanceled,
        requestId: item.request.requestId,
        state: TtsRequestState.canceled,
      );
      unawaited(item.controller.close());
    }

    if (pending.isNotEmpty) {
      emitQueueEvent(TtsQueueEventType.queueCleared,
          queueLength: _scheduler.length);
    }
    return pending.length;
  }

  Future<void> dispose() async {
    if (_state.isDisposed) {
      return;
    }

    _state.activeControl?.cancel(CancelReason.serviceDispose);
    await clearQueue();
    await _awaitActiveRequestShutdown();
    await _engine.dispose();
    await _output.dispose();
    _state.markDisposed();
    await eventBus.close();
  }

  Future<void> _awaitActiveRequestShutdown() async {
    const pollInterval = Duration(milliseconds: 10);
    const timeout = Duration(milliseconds: 500);
    final deadline = DateTime.now().add(timeout);

    while (_state.activeControl != null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<void> _processQueue() async {
    return _processQueueImpl(this);
  }

  _RequestFailure _mapRequestFailure(Object error, TtsRequest request) {
    return _mapRequestFailureImpl(error, request);
  }

  Future<void> _cancelPendingAfterFailure() async {
    return _cancelPendingAfterFailureImpl(this);
  }

  TtsAudioSpec _resolveAudioSpec(TtsRequest request) {
    return _resolveAudioSpecImpl(this, request);
  }

  Future<void> _flushPauseBuffer(
    _QueuedRequest item,
    TtsRequest request,
    SynthesisControl control,
  ) async {
    return _flushPauseBufferImpl(this, item, request, control);
  }

  void _ensureNotDisposed() {
    _state.ensureNotDisposed();
  }

  void _ensureReady() {
    _state.ensureReady();
  }
}

final class _QueuedRequest {
  const _QueuedRequest({required this.request, required this.controller});

  final TtsRequest request;
  final StreamController<TtsChunk> controller;
}
