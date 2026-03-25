import 'dart:async';
import 'dart:developer';

import 'package:tts_flow_dart/src/base/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_contracts.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_models.dart';
import 'package:tts_flow_dart/src/service/format_negotiator.dart';
import 'package:tts_flow_dart/src/service/queue_scheduler.dart';
import 'package:tts_flow_dart/src/service/tts_events.dart';

part 'internal/tts_flow_events.dart';
part 'internal/tts_flow_request_helpers.dart';
part 'internal/tts_flow_request_runtime.dart';
part 'internal/tts_flow_runtime.dart';
part 'internal/tts_flow_state.dart';
part 'internal/tts_flow_transitions.dart';

final class TtsFlow {
  TtsFlow({
    required TtsEngine engine,
    required TtsOutput output,
    TtsFlowConfig? config,
  })  : _engine = engine,
        _output = output,
        _config = config ?? const TtsFlowConfig(),
        _options = const TtsOptions(),
        _preferredFormat =
            (config ?? const TtsFlowConfig()).preferredFormatOrder.first;

  final TtsEngine _engine;
  final TtsOutput _output;
  final TtsFlowConfig _config;
  final TtsFormatNegotiator _formatNegotiator = const TtsFormatNegotiator();
  final QueueScheduler<_QueuedRequest> _scheduler =
      QueueScheduler<_QueuedRequest>();

  final StreamController<TtsQueueEvent> _queueEventsController =
      StreamController<TtsQueueEvent>.broadcast();
  final StreamController<TtsRequestEvent> _requestEventsController =
      StreamController<TtsRequestEvent>.broadcast();

  final _TtsFlowState _state = _TtsFlowState();
  late TtsVoice _voice;
  TtsOptions _options;
  TtsAudioFormat _preferredFormat;

  Stream<TtsQueueEvent> get queueEvents => _queueEventsController.stream;
  Stream<TtsRequestEvent> get requestEvents => _requestEventsController.stream;
  bool get isPaused => _state.isPaused;
  bool get isInitialized => _state.isInitialized;

  TtsVoice get voice => _voice;

  set voice(TtsVoice value) {
    _ensureNotDisposed();
    _voice = value;
  }

  double? get speed => _options.speed;

  set speed(double? value) {
    _ensureNotDisposed();
    _options = _options.copyWith(speed: value);
  }

  double? get pitch => _options.pitch;

  set pitch(double? value) {
    _ensureNotDisposed();
    _options = _options.copyWith(pitch: value);
  }

  double? get volume => _options.volume;

  set volume(double? value) {
    _ensureNotDisposed();
    _options = _options.copyWith(volume: value);
  }

  int? get sampleRateHz => _options.sampleRateHz;

  set sampleRateHz(int? value) {
    _ensureNotDisposed();
    _options = _options.copyWith(sampleRateHz: value);
  }

  Duration? get timeout => _options.timeout;

  set timeout(Duration? value) {
    _ensureNotDisposed();
    _options = _options.copyWith(timeout: value);
  }

  TtsAudioFormat get preferredFormat => _preferredFormat;

  set preferredFormat(TtsAudioFormat value) {
    _ensureNotDisposed();
    _preferredFormat = value;
  }

  Future<void> init() async {
    _ensureNotDisposed();
    if (_state.isInitialized) {
      return;
    }

    _voice = await _engine.getDefaultVoice();
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

    final request = _buildRequest(
      requestId: requestId,
      text: text,
      params: params,
    );

    _state.unhaltOnEnqueue();

    final controller = StreamController<TtsChunk>();
    final queued = _QueuedRequest(request: request, controller: controller);
    _scheduler.enqueue(queued);

    _emitRequestEvent(
      TtsRequestEventType.requestQueued,
      requestId: request.requestId,
      state: TtsRequestState.queued,
    );
    _emitQueueEvent(TtsQueueEventType.requestEnqueued,
        requestId: request.requestId);

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
      _emitRequestEvent(
        TtsRequestEventType.requestCanceled,
        requestId: item.request.requestId,
        state: TtsRequestState.canceled,
      );
      unawaited(item.controller.close());
    }

    if (pending.isNotEmpty) {
      _emitQueueEvent(TtsQueueEventType.queueCleared);
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
    await _queueEventsController.close();
    await _requestEventsController.close();
  }

  Future<void> _awaitActiveRequestShutdown() async {
    const pollInterval = Duration(milliseconds: 10);
    const timeout = Duration(milliseconds: 500);
    final deadline = DateTime.now().add(timeout);

    while (_state.activeControl != null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
    }
  }

  TtsRequest _buildRequest({
    required String requestId,
    required String text,
    required Map<String, Object> params,
  }) {
    return TtsRequest(
      requestId: requestId,
      text: text,
      voice: _voice,
      preferredFormat: _preferredFormat,
      options: _options,
      params: Map<String, Object>.unmodifiable(
        Map<String, Object>.from(params),
      ),
    );
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

  void _emitQueueEvent(TtsQueueEventType type, {String? requestId}) {
    _emitQueueEventImpl(this, type, requestId: requestId);
  }

  void _emitRequestEvent(
    TtsRequestEventType type, {
    required String requestId,
    TtsRequestState? state,
    TtsChunk? chunk,
    TtsError? error,
    String? outputId,
    TtsError? outputError,
  }) {
    _emitRequestEventImpl(
      this,
      type,
      requestId: requestId,
      state: state,
      chunk: chunk,
      error: error,
      outputId: outputId,
      outputError: outputError,
    );
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
