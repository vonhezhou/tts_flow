import 'dart:async';
import 'dart:developer' as dev;

import '../core/tts_contracts.dart';
import '../core/tts_errors.dart';
import '../core/tts_models.dart';
import 'format_negotiator.dart';
import 'queue_scheduler.dart';
import 'tts_events.dart';

final class TtsService {
  TtsService({
    required TtsEngine engine,
    required TtsOutput output,
    TtsServiceConfig? config,
  })  : _engine = engine,
        _output = output,
        _config = config ?? const TtsServiceConfig(),
        _options = const TtsOptions(),
        _preferredFormat =
            (config ?? const TtsServiceConfig()).preferredFormatOrder.first;

  final TtsEngine _engine;
  final TtsOutput _output;
  final TtsServiceConfig _config;
  final TtsFormatNegotiator _formatNegotiator = const TtsFormatNegotiator();
  final QueueScheduler<_QueuedRequest> _scheduler =
      QueueScheduler<_QueuedRequest>();

  final StreamController<TtsQueueEvent> _queueEventsController =
      StreamController<TtsQueueEvent>.broadcast();
  final StreamController<TtsRequestEvent> _requestEventsController =
      StreamController<TtsRequestEvent>.broadcast();

  _ServiceLifecycle _lifecycle = _ServiceLifecycle.created;
  _QueueActivity _queueActivity = _QueueActivity.idle;
  _QueueMode _queueMode = _QueueMode.running;
  SynthesisControl? _activeControl;
  final List<TtsChunk> _pauseBuffer = [];
  int _pauseBufferBytes = 0;
  late TtsVoice _voice;
  TtsOptions _options;
  TtsAudioFormat _preferredFormat;

  Stream<TtsQueueEvent> get queueEvents => _queueEventsController.stream;
  Stream<TtsRequestEvent> get requestEvents => _requestEventsController.stream;
  bool get isPaused => _queueMode == _QueueMode.paused;
  bool get isInitialized => _lifecycle == _ServiceLifecycle.initialized;

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
    if (_lifecycle == _ServiceLifecycle.initialized) {
      return;
    }

    _voice = await _engine.getDefaultVoice();
    _lifecycle = _ServiceLifecycle.initialized;
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

    if (_queueMode == _QueueMode.halted) {
      _queueMode = _QueueMode.running;
    }

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
    if (_queueMode != _QueueMode.halted) {
      _queueMode = _QueueMode.paused;
    }
  }

  Future<void> resume() async {
    _ensureReady();
    if (_queueMode == _QueueMode.paused) {
      _queueMode = _QueueMode.running;
    }
    unawaited(_processQueue());
  }

  Future<void> stopCurrent() async {
    _ensureReady();
    _activeControl?.cancel(CancelReason.stopCurrent);
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
    if (_lifecycle == _ServiceLifecycle.disposed) {
      return;
    }

    _activeControl?.cancel(CancelReason.serviceDispose);
    await clearQueue();
    await _engine.dispose();
    await _output.dispose();
    _pauseBuffer.clear();
    _pauseBufferBytes = 0;
    _queueActivity = _QueueActivity.idle;
    _queueMode = _QueueMode.running;
    _lifecycle = _ServiceLifecycle.disposed;
    await _queueEventsController.close();
    await _requestEventsController.close();
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
    if (_queueActivity == _QueueActivity.processing ||
        _lifecycle == _ServiceLifecycle.disposed) {
      return;
    }
    _queueActivity = _QueueActivity.processing;

    try {
      while (!_scheduler.isEmpty && _lifecycle != _ServiceLifecycle.disposed) {
        // Pause gates starting the next request. Active request handling
        // continues in-loop using buffering/passthrough policy.
        if (_queueMode == _QueueMode.paused) {
          break;
        }

        final item = _scheduler.dequeue();
        final request = item.request;
        final control = SynthesisControl();
        _activeControl = control;

        _emitQueueEvent(TtsQueueEventType.requestDequeued,
            requestId: request.requestId);
        _emitRequestEvent(
          TtsRequestEventType.requestStarted,
          requestId: request.requestId,
          state: TtsRequestState.running,
        );

        try {
          final audioSpec = _resolveAudioSpec(request);
          await _output.initSession(
            TtsOutputSession(
              requestId: request.requestId,
              audioSpec: audioSpec,
              voice: request.voice,
              options: request.options,
              params: request.params,
            ),
          );

          await for (final chunk
              in _engine.synthesize(request, control, audioSpec)) {
            if (control.isCanceled) {
              break;
            }
            // Flush any buffered chunks before processing new ones post-resume.
            if (_pauseBuffer.isNotEmpty && _queueMode != _QueueMode.paused) {
              await _flushPauseBuffer(item, request, control);
              if (control.isCanceled) break;
            }
            if (_queueMode == _QueueMode.paused &&
                _config.pauseBufferPolicy == TtsPauseBufferPolicy.buffered) {
              _pauseBuffer.add(chunk);
              final newBytes = _pauseBufferBytes + chunk.bytes.length;
              if (_pauseBufferBytes <= _config.pauseBufferMaxBytes &&
                  newBytes > _config.pauseBufferMaxBytes) {
                dev.log(
                  'TTS pause buffer exceeded ${_config.pauseBufferMaxBytes} '
                  'bytes (current: $newBytes); chunks continue to accumulate.',
                  name: 'flutter_uni_tts',
                  level: 900,
                );
              }
              _pauseBufferBytes = newBytes;
              continue;
            }
            await _output.consumeChunk(chunk);
            item.controller.add(chunk);
            _emitRequestEvent(
              TtsRequestEventType.requestChunkReceived,
              requestId: request.requestId,
              state: TtsRequestState.running,
              chunk: chunk,
            );
          }
          // Engine stream exhausted. If it finished while still paused,
          // wait for resume and then flush the remaining buffer.
          if (!control.isCanceled && _pauseBuffer.isNotEmpty) {
            while (_queueMode == _QueueMode.paused &&
                _lifecycle != _ServiceLifecycle.disposed &&
                !control.isCanceled) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (!control.isCanceled) {
              await _flushPauseBuffer(item, request, control);
            }
          }

          if (control.isCanceled) {
            await _output.onCancel(control);
            _emitRequestEvent(
              TtsRequestEventType.requestStopped,
              requestId: request.requestId,
              state: TtsRequestState.stopped,
            );
          } else {
            await _output.finalizeSession();
            _emitRequestEvent(
              TtsRequestEventType.requestCompleted,
              requestId: request.requestId,
              state: TtsRequestState.completed,
            );
          }

          unawaited(item.controller.close());
        } catch (error) {
          final failure = _mapRequestFailure(error, request);
          _emitRequestEvent(
            TtsRequestEventType.requestFailed,
            requestId: request.requestId,
            state: TtsRequestState.failed,
            error: failure.ttsError,
            outputId: failure.outputId,
            outputError: failure.outputError,
          );
          item.controller.addError(failure.ttsError);
          unawaited(item.controller.close());

          if (_config.queueFailurePolicy == TtsQueueFailurePolicy.failFast) {
            _queueMode = _QueueMode.halted;
            _emitQueueEvent(TtsQueueEventType.queueHalted,
                requestId: request.requestId);
            await _cancelPendingAfterFailure();
            break;
          }
        } finally {
          _activeControl = null;
          _pauseBuffer.clear();
          _pauseBufferBytes = 0;
        }

        if (_queueMode == _QueueMode.halted) {
          break;
        }
      }
    } finally {
      _queueActivity = _QueueActivity.idle;
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

  Future<void> _cancelPendingAfterFailure() async {
    final pending = _scheduler.drain();
    for (final item in pending) {
      _emitRequestEvent(
        TtsRequestEventType.requestCanceled,
        requestId: item.request.requestId,
        state: TtsRequestState.canceled,
      );
      unawaited(item.controller.close());
    }
  }

  TtsAudioSpec _resolveAudioSpec(TtsRequest request) {
    return _formatNegotiator.negotiateSpec(
      engineCapabilities: _engine.supportedCapabilities,
      outputCapabilities: _output.acceptedCapabilities,
      preferredOrder: _config.preferredFormatOrder,
      requestId: request.requestId,
      preferredFormat: request.preferredFormat,
      preferredSampleRateHz: request.options?.sampleRateHz,
    );
  }

  Future<void> _flushPauseBuffer(
    _QueuedRequest item,
    TtsRequest request,
    SynthesisControl control,
  ) async {
    final toFlush = List<TtsChunk>.of(_pauseBuffer);
    _pauseBuffer.clear();
    _pauseBufferBytes = 0;
    for (final chunk in toFlush) {
      if (control.isCanceled) break;
      await _output.consumeChunk(chunk);
      item.controller.add(chunk);
      _emitRequestEvent(
        TtsRequestEventType.requestChunkReceived,
        requestId: request.requestId,
        state: TtsRequestState.running,
        chunk: chunk,
      );
    }
  }

  void _emitQueueEvent(TtsQueueEventType type, {String? requestId}) {
    _queueEventsController.add(
      TtsQueueEvent(
        type: type,
        requestId: requestId,
        timestamp: DateTime.now().toUtc(),
        queueLength: _scheduler.length,
      ),
    );
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
    _requestEventsController.add(
      TtsRequestEvent(
        type: type,
        requestId: requestId,
        timestamp: DateTime.now().toUtc(),
        state: state,
        chunk: chunk,
        error: error,
        outputId: outputId,
        outputError: outputError,
      ),
    );
  }

  void _ensureNotDisposed() {
    if (_lifecycle == _ServiceLifecycle.disposed) {
      throw StateError('TtsService is disposed.');
    }
  }

  void _ensureReady() {
    _ensureNotDisposed();
    if (_lifecycle != _ServiceLifecycle.initialized) {
      throw StateError('TtsService is not initialized. Call init() first.');
    }
  }
}

enum _ServiceLifecycle {
  created,
  initialized,
  disposed,
}

enum _QueueActivity {
  idle,
  processing,
}

enum _QueueMode {
  running,
  paused,
  halted,
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
